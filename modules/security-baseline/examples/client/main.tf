# Example: the fix pack for a client account (home region + one more region).
# Free controls are on by default; this client also chose CloudTrail, GuardDuty and a budget.
provider "aws" {
  region = "ap-south-1"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

module "security_baseline" {
  source = "../.."

  name_prefix        = "acme"
  cloudtrail         = true
  guardduty          = true
  monthly_budget_usd = 300
  alert_emails       = ["cto@example.com"]
}

# Second region: regional controls only (the trail is multi-region already).
module "security_baseline_us_east_1" {
  source    = "../.."
  providers = { aws = aws.us_east_1 }

  name_prefix          = "acme"
  manage_account_level = false
  guardduty            = true
}

output "controls_fixed" {
  value = module.security_baseline.controls_fixed
}
