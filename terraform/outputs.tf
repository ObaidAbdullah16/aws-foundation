output "account_id" {
  value = local.account_id
}

output "region" {
  value = var.aws_region
}

output "state_bucket" {
  description = "S3 bucket that stores Terraform state for every project."
  value       = local.state_bucket
}

output "github_oidc_provider_arn" {
  description = "Empty in a project account (GitHub Actions cannot log in to AWS there)."
  value       = local.oidc_provider_arn
}

output "deploy_role_arns" {
  description = "Repository name => IAM role ARN. scripts/connect-github.sh copies these into each repo as the AWS_ROLE_ARN variable."
  value       = { for repo, role in aws_iam_role.deploy : repo => role.arn }
}

output "workload_boundary_arn" {
  description = "Permissions boundary every project role must carry (projects find it by its name, gha-workload-boundary)."
  value       = aws_iam_policy.workload_boundary.arn
}

output "security_baseline" {
  description = "Baseline controls this account now meets, and where its CloudTrail logs go."
  value = {
    controls_fixed = module.baseline.controls_fixed
    logs_bucket    = module.baseline.logs_bucket
  }
}
