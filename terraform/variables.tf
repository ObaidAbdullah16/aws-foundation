variable "aws_region" {
  description = "Home region for all projects (a project account can only use its own Region)."
  type        = string
  default     = "ap-southeast-2"
}

variable "github_owner" {
  description = "GitHub user or organisation that owns the project repositories."
  type        = string
  default     = "ObaidAbdullah16"
}

variable "owner_tag" {
  description = "Value of the Owner tag put on every resource."
  type        = string
  default     = "obaid"
}

variable "alert_email" {
  description = "Email address that receives budget alerts. You must confirm the AWS subscription email once."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget for the whole account (USD)."
  type        = number
  default     = 10
}

variable "daily_budget_usd" {
  description = "Daily cost budget (USD). Catches a forgotten ECS/RDS/EKS stack within a day."
  type        = number
  default     = 1
}

variable "project_account" {
  description = <<-EOT
    true for an account made with the new AWS sign-up ("projects": Free plan, one Region, no root user).
    AWS blocks some things there: creating an OIDC identity provider (so no GitHub deploy roles),
    IAM Access Analyzer and GuardDuty. The scripts set this from AWS_ACCOUNT_TYPE in _setup/config.env.
  EOT
  type        = bool
  default     = false
}

variable "enable_github_oidc" {
  description = "Create the GitHub Actions OIDC provider and one deploy role per repository. Not possible in a project account."
  type        = bool
  default     = true
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set false if your account already has one (bootstrap.sh detects this)."
  type        = bool
  default     = true
}

variable "enable_account_guardrails" {
  description = "Turn on the free guardrails of the security baseline: S3 Block Public Access, EBS encryption by default, no public EBS snapshots, IMDSv2 for new instances, password policy, IAM Access Analyzer, ECR scan on push."
  type        = bool
  default     = true
}

variable "enable_cloudtrail" {
  description = "Multi-region CloudTrail trail with log-file validation into a private bucket (logs kept 365 days). Management events are free; storage costs cents a month."
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = "GuardDuty threat detection in the home region. Free for 30 days, then roughly $1-4 a month for an account this size."
  type        = bool
  default     = false
}

variable "create_anomaly_monitor" {
  description = "Create a Cost Anomaly Detection monitor. AWS allows only one SERVICE monitor per account and new accounts often get one automatically, so this is off by default."
  type        = bool
  default     = false
}

variable "projects" {
  description = <<-EOT
    One GitHub Actions deploy role per repository.
    managed_policies: AWS managed policy names to attach.
    iam_prefixes: the role may create/manage IAM roles and policies whose names start with these prefixes (and pass them to services).
  EOT
  type = map(object({
    managed_policies = list(string)
    iam_prefixes     = list(string)
  }))
  default = {
    "shipit-platform" = {
      managed_policies = ["PowerUserAccess"]
      iam_prefixes     = ["shipit"]
    }
    "incidentscribe-ai" = {
      managed_policies = ["PowerUserAccess"]
      iam_prefixes     = ["incidentscribe"]
    }
    "restore-drill-kit" = {
      managed_policies = ["PowerUserAccess"]
      iam_prefixes     = ["restore-drill"]
    }
    "kubeops-sre-lab" = {
      managed_policies = ["PowerUserAccess"]
      iam_prefixes     = ["kubeops"]
    }
    "portfolio" = {
      managed_policies = ["PowerUserAccess"]
      iam_prefixes     = []
    }
    "aws-bill-doctor" = {
      # Cost scan + security baseline check of this account (read-only).
      managed_policies = ["ReadOnlyAccess", "SecurityAudit"]
      iam_prefixes     = []
    }
    "serverforge" = {
      # Creates a VPC and two small EC2 instances (no IAM roles).
      managed_policies = ["PowerUserAccess"]
      iam_prefixes     = []
    }
    "gha-hardening-kit" = {
      # Zero permissions on purpose: the OIDC demo only calls sts:GetCallerIdentity,
      # which needs no IAM permission. It proves "no long-lived keys" without any risk.
      managed_policies = []
      iam_prefixes     = []
    }
  }

  validation {
    # A prefix like "g", "gha" or "gha-x" would let a project edit the deploy roles
    # (gha-<repo>) or the permissions boundary (gha-workload-boundary).
    condition     = alltrue([for p in flatten([for cfg in values(var.projects) : cfg.iam_prefixes]) : length(p) >= 3 && !startswith("gha-", p) && !startswith(p, "gha-")])
    error_message = "Each iam_prefix must be at least 3 characters and must not overlap with \"gha-\" (the deploy roles and the boundary use that prefix)."
  }
}
