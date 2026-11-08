# Fix pack: how each baseline control is fixed

The fixes delivered with the **AWS Security Baseline Check** (service S8). The scan report links every failing
control to one of three kinds of fix, in this order of preference:

1. **Terraform** - an input of [`modules/security-baseline`](../modules/security-baseline). Reviewable, repeatable, reversible.
2. **Script or CLI** - dry-run-first scripts in [`scripts/`](scripts) or a single AWS CLI command to review and run.
3. **Console** - only where no safe API exists (root user MFA) or a human decision is needed.

The client applies every fix. The audit role is read-only and never changes anything.

```hcl
module "security_baseline" {
  source = "git::https://github.com/ObaidAbdullah16/aws-foundation.git//modules/security-baseline?ref=v1.0.0"

  name_prefix        = "acme"
  cloudtrail         = true   # LD-01 (cents a month)
  guardduty          = true   # LD-02 (a few dollars a month)
  monthly_budget_usd = 300    # LD-05
  alert_emails       = ["cto@example.com"]
}
```

Free controls are on by default: S3 account Block Public Access, EBS encryption by default, no public EBS snapshots,
IMDSv2 for new instances, password policy, IAM Access Analyzer and ECR scan on push. See
[`modules/security-baseline/examples/client`](../modules/security-baseline/examples/client) for a two-region set-up.

## Identity and access

| Control | Severity | Fix |
|---|---|---|
| **ID-01** Root user is protected (MFA on, no access keys) | critical | Console: Sign in as root > Security credentials > assign an MFA device (passkey or hardware key); delete any root access keys. In AWS Organizations, turn on centralized root access management for member accounts. |
| **ID-02** Every console user has MFA | high | CLI: `aws iam list-virtual-mfa-devices  # find users without a device, then enable MFA for each, or move people to IAM Identity Center`<br>Console: IAM > Users > (user) > Security credentials > Assign MFA device. |
| **ID-03** Access keys are rotated and unused keys removed | high | CLI: `aws iam update-access-key --user-name <user> --access-key-id <key> --status Inactive` |
| **ID-04** People get permissions through groups, roles or SSO - not attached to users | medium | CLI: `aws iam detach-user-policy --user-name <user> --policy-arn <arn>`<br>Console: Prefer IAM Identity Center: one login per person, permission sets per job, no long-lived keys. |
| **ID-05** Full administrator rights are limited to a break-glass role | high | CLI: `aws iam list-entities-for-policy --policy-arn arn:aws:iam::aws:policy/AdministratorAccess`<br>Console: Replace AdministratorAccess with job-based policies (PowerUserAccess, ReadOnlyAccess, or service-scoped). Keep one MFA-protected break-glass role. |
| **ID-06** Password policy requires long, non-reused passwords | low | Terraform: `module.security_baseline: iam_password_policy = true`<br>CLI: `aws iam update-account-password-policy --minimum-password-length 14 --password-reuse-prevention 24 --require-symbols --require-numbers --require-uppercase-characters --require-lowercase-characters` |
| **ID-07** IAM Access Analyzer watches for external access | medium | Terraform: `module.security_baseline: access_analyzer = true`<br>CLI: `aws accessanalyzer create-analyzer --analyzer-name account-analyzer --type ACCOUNT` |

## Logging and detection

| Control | Severity | Fix |
|---|---|---|
| **LD-01** CloudTrail records every region, with tamper-evident, private logs | critical | Terraform: `module.security_baseline: cloudtrail = true`<br>CLI: `aws cloudtrail create-trail --name org-trail --s3-bucket-name <bucket> --is-multi-region-trail --enable-log-file-validation` |
| **LD-02** GuardDuty threat detection is on | high | Terraform: `module.security_baseline: guardduty = true`<br>CLI: `aws guardduty create-detector --enable --finding-publishing-frequency FIFTEEN_MINUTES` |
| **LD-03** AWS Config records configuration changes | medium | Terraform: `module.security_baseline: config_recorder = true`<br>Console: AWS Config > Get started > record all resources > deliver to the CloudTrail logs bucket. |
| **LD-04** Log groups keep logs for at least a year | medium | CLI: `bash aws-foundation/fix-pack/scripts/set-log-retention.sh --days 365` |
| **LD-05** Spend alerts would catch abuse within a day | medium | Terraform: `module.security_baseline: monthly_budget_usd = <amount>, alert_emails = [...]  (or aws-bill-doctor/terraform/budget-guard)` |

## Data protection

| Control | Severity | Fix |
|---|---|---|
| **DA-01** S3 Block Public Access is on for the whole account | critical | Terraform: `module.security_baseline: s3_account_public_access_block = true`<br>CLI: `aws s3control put-public-access-block --account-id <account> --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true` |
| **DA-02** No bucket is public | critical | CLI: `aws s3api put-public-access-block --bucket <bucket> --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true` |
| **DA-03** Data is encrypted by default (S3 and EBS) | medium | Terraform: `module.security_baseline: ebs_encryption_by_default = true`<br>CLI: `aws ec2 enable-ebs-encryption-by-default --region <region>` |
| **DA-04** Databases are encrypted, private, backed up and protected from deletion | high | CLI: `aws rds modify-db-instance --db-instance-identifier <db> --backup-retention-period 7 --deletion-protection --no-publicly-accessible --apply-immediately` |
| **DA-05** No snapshot is public | critical | Terraform: `module.security_baseline: ebs_snapshot_block_public_access = true`<br>CLI: `aws ec2 modify-snapshot-attribute --snapshot-id <snap> --attribute createVolumePermission --operation-type remove --group-names all` |

## Network and compute

| Control | Severity | Fix |
|---|---|---|
| **NC-01** No SSH, RDP or database port is open to the whole internet | critical | CLI: `aws ec2 revoke-security-group-ingress --group-id <sg> --protocol tcp --port 22 --cidr 0.0.0.0/0` |
| **NC-02** Default security groups allow no traffic | low | Terraform: `module.security_baseline: default_security_group_vpc_ids = ["vpc-..."]` |
| **NC-03** Instances require IMDSv2 | high | Terraform: `module.security_baseline: ec2_imdsv2_default = true`<br>CLI: `bash aws-foundation/fix-pack/scripts/require-imdsv2.sh --regions <region>` |
| **NC-04** Only intended instances have public IP addresses | medium | Console: Move workloads to private subnets behind a load balancer; reach them with SSM Session Manager. Keep a public IP only where it is intended, and note it in the report. |

## Secrets and pipelines

| Control | Severity | Fix |
|---|---|---|
| **SP-01** No secrets in Lambda variables, EC2 user data or launch templates | critical | Console: Move each value to Secrets Manager or SSM Parameter Store (SecureString), read it at runtime, then rotate it - it must be treated as exposed. |
| **SP-02** Secrets Manager secrets rotate automatically | medium | CLI: `aws secretsmanager rotate-secret --secret-id <id> --rotation-lambda-arn <arn> --rotation-rules AutomaticallyAfterDays=90` |
| **SP-03** CI/CD logs in with short-lived OIDC credentials, not stored keys | high | Terraform: `gha-hardening-kit/terraform/github-oidc-role (service S2)`<br>Console: Create an OIDC role trusted only by your repository's main branch or a protected environment, switch the workflow to role-to-assume, then delete the old access key. |
| **SP-04** Container images are scanned on push and tags are immutable | low | Terraform: `module.security_baseline: ecr_scan_on_push = true`<br>CLI: `aws ecr put-image-tag-mutability --repository-name <repo> --image-tag-mutability IMMUTABLE` |

## Before applying anything

- **DA-01** blocks public buckets account-wide. A bucket that must serve files publicly should sit behind CloudFront
  with origin access control; check with `aws s3api get-bucket-policy-status` first.
- **NC-02** removes every rule from default security groups. Run `aws ec2 describe-network-interfaces --filters
  Name=group-id,Values=<sg>` to confirm nothing uses them.
- **NC-03** on existing instances: test one instance first; very old SDKs and agents only speak IMDSv1.
- **LD-03** (Config) is billed per configuration item; agree it with the client before enabling.
