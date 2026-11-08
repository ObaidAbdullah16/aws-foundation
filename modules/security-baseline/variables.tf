variable "name_prefix" {
  description = "Prefix for named resources (trail, logs bucket, analyzer, recorder)."
  type        = string
  default     = "baseline"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.name_prefix))
    error_message = "name_prefix: 2-31 lowercase letters, digits or hyphens."
  }
}

variable "manage_account_level" {
  description = "Manage account-wide settings (IAM password policy, S3 account Block Public Access, the multi-region trail). Set false for the 2nd, 3rd... region of the same account."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- free controls (on by default)
variable "s3_account_public_access_block" {
  description = "DA-01: S3 Block Public Access for the whole account. Breaks deliberately public buckets: serve them through CloudFront instead."
  type        = bool
  default     = true
}

variable "ebs_encryption_by_default" {
  description = "DA-03: encrypt every new EBS volume and snapshot in this region."
  type        = bool
  default     = true
}

variable "ebs_snapshot_block_public_access" {
  description = "DA-05: block public sharing of EBS snapshots in this region."
  type        = bool
  default     = true
}

variable "ec2_imdsv2_default" {
  description = "NC-03: new instances in this region require IMDSv2 (hop limit 2, so containers keep working). Existing instances need modify-instance-metadata-options."
  type        = bool
  default     = true
}

variable "iam_password_policy" {
  description = "ID-06: 14+ characters, all character classes, no reuse of the last 24 passwords."
  type        = bool
  default     = true
}

variable "access_analyzer" {
  description = "ID-07: IAM Access Analyzer for external access (free)."
  type        = bool
  default     = true
}

variable "ecr_scan_on_push" {
  description = "SP-04: basic image scanning on push for every ECR repository (free)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- controls with a running cost (off unless chosen)
variable "cloudtrail" {
  description = "LD-01: multi-region trail with log-file validation into a private, encrypted, versioned bucket. Management events in one trail are free; storage costs cents a month for small accounts."
  type        = bool
  default     = false
}

variable "cloudtrail_multi_region" {
  description = "Make the trail multi-Region (recommended). Set false for accounts limited to one Region, such as projects from the new AWS sign-up."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Days to keep CloudTrail (and Config) logs. 365 matches LD-04 and the DPDP one-year expectation."
  type        = number
  default     = 365
  validation {
    condition     = var.log_retention_days >= 90
    error_message = "Keep logs for at least 90 days (365 recommended)."
  }
}

variable "guardduty" {
  description = "LD-02: GuardDuty threat detection in this region. 30-day free trial, then usually a few dollars a month for a small account."
  type        = bool
  default     = false
}

variable "config_recorder" {
  description = "LD-03: AWS Config recorder for all supported resources, delivering to the logs bucket (needs cloudtrail = true). Billed per configuration item recorded."
  type        = bool
  default     = false
}

variable "create_config_service_linked_role" {
  description = "Create AWSServiceRoleForConfig. Set false if the account already has it (the apply fails with 'has been taken')."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "LD-05: monthly cost budget with alerts at 80% and 100% (actual) and 100% (forecast). 0 = no budget. Alert-only budgets are free."
  type        = number
  default     = 0
}

variable "alert_emails" {
  description = "Who receives budget alerts."
  type        = list(string)
  default     = []
}

variable "default_security_group_vpc_ids" {
  description = "NC-02: remove every rule from the default security group of these VPCs. Check nothing uses those groups first."
  type        = list(string)
  default     = []
}
