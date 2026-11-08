# security-baseline

Terraform module that fixes the account-level controls of the **AWS Security Baseline Check** (service S8).
It is the fix pack clients apply after the scan, and `aws-foundation` uses it for this account too.

```hcl
module "security_baseline" {
  source = "git::https://github.com/ObaidAbdullah16/aws-foundation.git//modules/security-baseline?ref=v1.0.0"

  name_prefix = "acme"
  cloudtrail  = true          # optional, see costs
}
```

Requires Terraform >= 1.6 (or OpenTofu) and AWS provider >= 6.0. Apply it once per region; for every region
after the first set `manage_account_level = false` (see `examples/client`).

| Input | Default | Control | Cost |
|---|---|---|---|
| `s3_account_public_access_block` | `true` | DA-01 account-wide S3 Block Public Access | free |
| `ebs_encryption_by_default` | `true` | DA-03 encrypt new EBS volumes and snapshots | free |
| `ebs_snapshot_block_public_access` | `true` | DA-05 no public EBS snapshots | free |
| `ec2_imdsv2_default` | `true` | NC-03 new instances require IMDSv2 (hop limit 2) | free |
| `iam_password_policy` | `true` | ID-06 14+ characters, no reuse of the last 24 | free |
| `access_analyzer` | `true` | ID-07 IAM Access Analyzer (external access) | free |
| `ecr_scan_on_push` | `true` | SP-04 basic scan on push for every repository | free |
| `cloudtrail` | `false` | LD-01 multi-region trail, log-file validation, private versioned bucket | cents/month for small accounts |
| `log_retention_days` | `365` | LD-04 / DPDP one year | - |
| `guardduty` | `false` | LD-02 threat detection | free 30 days, then a few $/month |
| `config_recorder` | `false` | LD-03 configuration history (needs `cloudtrail`) | per configuration item |
| `monthly_budget_usd`, `alert_emails` | `0`, `[]` | LD-05 budget alerts at 80/100% actual and 100% forecast | free |
| `default_security_group_vpc_ids` | `[]` | NC-02 empty the default security groups | free |
| `manage_account_level` | `true` | password policy, S3 account block, trail, budget: home region only | - |

Outputs: `logs_bucket`, `trail_arn`, `access_analyzer_arn`, `guardduty_detector_id` and `controls_fixed`
(the control IDs this configuration addresses, for the retest notes).

What a module cannot fix - root MFA, existing users' MFA and keys, public resources that already exist,
secrets in Lambda variables - is listed with CLI and console steps in [`../../fix-pack`](../../fix-pack).

## Read before applying

- `s3_account_public_access_block` breaks buckets that are public on purpose. Serve them through CloudFront.
- `default_security_group_vpc_ids` removes every rule from those default groups. Check nothing uses them.
- `ec2_imdsv2_default` changes the default for **new** instances only; `fix-pack/scripts/require-imdsv2.sh` handles existing ones.
- Destroying the module turns the controls off again (the trail bucket is kept unless empty).
