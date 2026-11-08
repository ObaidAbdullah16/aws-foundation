# Security baseline: the fix pack behind the AWS Security Baseline Check (service S8).
# Each block names the control it fixes. Free controls are on by default; controls with a
# running cost (CloudTrail storage, GuardDuty, Config) are off until you choose them.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.region
  trail     = var.manage_account_level && var.cloudtrail
  bucket    = "${var.name_prefix}-logs-${local.account}-${local.region}"
  trail_arn = "arn:${local.partition}:cloudtrail:${local.region}:${local.account}:trail/${var.name_prefix}-trail"
}

# ---------------------------------------------------------------- DA-01 account-wide S3 Block Public Access
resource "aws_s3_account_public_access_block" "this" {
  count = var.manage_account_level && var.s3_account_public_access_block ? 1 : 0

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------- DA-03 / DA-05 / NC-03 regional EC2 defaults
resource "aws_ebs_encryption_by_default" "this" {
  count   = var.ebs_encryption_by_default ? 1 : 0
  enabled = true
}

resource "aws_ebs_snapshot_block_public_access" "this" {
  count = var.ebs_snapshot_block_public_access ? 1 : 0
  state = "block-all-sharing"
}

resource "aws_ec2_instance_metadata_defaults" "this" {
  count = var.ec2_imdsv2_default ? 1 : 0

  http_tokens                 = "required"
  http_put_response_hop_limit = 2 # containers on the instance still reach the metadata service
  http_endpoint               = "enabled"
}

# ---------------------------------------------------------------- ID-06 password policy, ID-07 Access Analyzer
resource "aws_iam_account_password_policy" "this" {
  #checkov:skip=CKV_AWS_9:Forced expiry is no longer recommended (NIST SP 800-63B, CIS since v1.5): length and no reuse instead
  count = var.manage_account_level && var.iam_password_policy ? 1 : 0

  minimum_password_length        = 14
  password_reuse_prevention      = 24
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
}

resource "aws_accessanalyzer_analyzer" "this" {
  count = var.access_analyzer ? 1 : 0

  analyzer_name = "${var.name_prefix}-external-access-${local.region}"
  type          = "ACCOUNT"
}

# ---------------------------------------------------------------- SP-04 ECR scan on push
resource "aws_ecr_registry_scanning_configuration" "this" {
  count     = var.ecr_scan_on_push ? 1 : 0
  scan_type = "BASIC"

  rule {
    scan_frequency = "SCAN_ON_PUSH"
    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}

# ---------------------------------------------------------------- LD-01 CloudTrail into a private logs bucket
resource "aws_s3_bucket" "logs" {
  #checkov:skip=CKV_AWS_18:This is the access-log destination itself; logging it into itself would loop
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles cost; log-file validation and versioning protect integrity
  #checkov:skip=CKV2_AWS_62:No consumer needs object notifications for audit logs
  #checkov:skip=CKV_AWS_145:SSE-S3 is used to avoid KMS charges; CloudTrail digests detect tampering
  count  = local.trail ? 1 : 0
  bucket = local.bucket
}

resource "aws_s3_bucket_public_access_block" "logs" {
  count                   = local.trail ? 1 : 0
  bucket                  = aws_s3_bucket.logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  count  = local.trail ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  count  = local.trail ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  count  = local.trail ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  count  = local.trail ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  rule {
    id     = "retain-then-expire"
    status = "Enabled"
    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = var.log_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "logs" {
  count = local.trail ? 1 : 0

  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs[0].arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs[0].arn}/AWSLogs/${local.account}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  dynamic "statement" {
    for_each = var.config_recorder ? [1] : []
    content {
      sid       = "ConfigAclCheck"
      actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
      resources = [aws_s3_bucket.logs[0].arn]
      principals {
        type        = "Service"
        identifiers = ["config.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account]
      }
    }
  }

  dynamic "statement" {
    for_each = var.config_recorder ? [1] : []
    content {
      sid       = "ConfigWrite"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.logs[0].arn}/config/AWSLogs/${local.account}/Config/*"]
      principals {
        type        = "Service"
        identifiers = ["config.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account]
      }
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs[0].arn, "${aws_s3_bucket.logs[0].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  count  = local.trail ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  policy = data.aws_iam_policy_document.logs[0].json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

resource "aws_cloudtrail" "this" {
  #checkov:skip=CKV_AWS_35:SSE-S3 on the bucket instead of a KMS key (cost); log-file validation is on
  #checkov:skip=CKV_AWS_252:No SNS topic: GuardDuty and budgets are the alerting path in this baseline
  #checkov:skip=CKV2_AWS_10:CloudWatch Logs delivery is optional and billed; the S3 trail is the record
  count = local.trail ? 1 : 0

  name                          = "${var.name_prefix}-trail"
  s3_bucket_name                = aws_s3_bucket.logs[0].id
  is_multi_region_trail         = var.cloudtrail_multi_region
  include_global_service_events = true
  enable_log_file_validation    = true
  enable_logging                = true

  depends_on = [aws_s3_bucket_policy.logs]
}

# ---------------------------------------------------------------- LD-02 GuardDuty
resource "aws_guardduty_detector" "this" {
  #checkov:skip=CKV2_AWS_3:Small standalone accounts; an organisation-wide delegated admin is the next step for multi-account clients
  count                        = var.guardduty ? 1 : 0
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

# ---------------------------------------------------------------- LD-03 AWS Config
resource "aws_iam_service_linked_role" "config" {
  count            = var.config_recorder && var.create_config_service_linked_role ? 1 : 0
  aws_service_name = "config.amazonaws.com"
}

resource "aws_config_configuration_recorder" "this" {
  #checkov:skip=CKV2_AWS_48:All supported resources are recorded; global types only in the home region (avoids duplicates)
  count    = var.config_recorder ? 1 : 0
  name     = "${var.name_prefix}-recorder"
  role_arn = "arn:${local.partition}:iam::${local.account}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"

  recording_group {
    all_supported                 = true
    include_global_resource_types = var.manage_account_level
  }

  depends_on = [aws_iam_service_linked_role.config]

  lifecycle {
    precondition {
      condition     = local.trail
      error_message = "config_recorder needs cloudtrail = true (Config delivers to the same logs bucket)."
    }
  }
}

resource "aws_config_delivery_channel" "this" {
  count          = var.config_recorder ? 1 : 0
  name           = "${var.name_prefix}-delivery"
  s3_bucket_name = aws_s3_bucket.logs[0].id
  s3_key_prefix  = "config"

  depends_on = [aws_config_configuration_recorder.this, aws_s3_bucket_policy.logs]
}

resource "aws_config_configuration_recorder_status" "this" {
  count      = var.config_recorder ? 1 : 0
  name       = aws_config_configuration_recorder.this[0].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

# ---------------------------------------------------------------- LD-05 spend alerts
resource "aws_budgets_budget" "monthly" {
  count        = var.manage_account_level && var.monthly_budget_usd > 0 && length(var.alert_emails) > 0 ? 1 : 0
  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [{ t = 80, type = "ACTUAL" }, { t = 100, type = "ACTUAL" }, { t = 100, type = "FORECASTED" }]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.t
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = var.alert_emails
    }
  }
}

# ---------------------------------------------------------------- NC-02 default security groups allow nothing
resource "aws_default_security_group" "locked" {
  for_each = toset(var.default_security_group_vpc_ids)
  vpc_id   = each.value
  # No ingress or egress blocks: Terraform removes every rule from the default group.
}
