output "logs_bucket" {
  description = "Bucket that receives CloudTrail (and Config) logs, or null."
  value       = local.trail ? aws_s3_bucket.logs[0].id : null
}

output "trail_arn" {
  value = local.trail ? aws_cloudtrail.this[0].arn : null
}

output "access_analyzer_arn" {
  value = var.access_analyzer ? aws_accessanalyzer_analyzer.this[0].arn : null
}

output "guardduty_detector_id" {
  value = var.guardduty ? aws_guardduty_detector.this[0].id : null
}

output "controls_fixed" {
  description = "Baseline control IDs this configuration addresses (for the retest notes)."
  value = compact([
    var.manage_account_level && var.s3_account_public_access_block ? "DA-01" : "",
    var.ebs_encryption_by_default ? "DA-03" : "",
    var.ebs_snapshot_block_public_access ? "DA-05" : "",
    var.ec2_imdsv2_default ? "NC-03 (new instances)" : "",
    var.manage_account_level && var.iam_password_policy ? "ID-06" : "",
    var.access_analyzer ? "ID-07" : "",
    var.ecr_scan_on_push ? "SP-04 (scan on push)" : "",
    local.trail ? "LD-01" : "",
    var.guardduty ? "LD-02" : "",
    var.config_recorder ? "LD-03" : "",
    var.monthly_budget_usd > 0 ? "LD-05" : "",
    length(var.default_security_group_vpc_ids) > 0 ? "NC-02" : "",
  ])
}
