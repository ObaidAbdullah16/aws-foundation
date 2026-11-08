data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition
  oidc_host    = "token.actions.githubusercontent.com"
  state_bucket = "tfstate-${local.account_id}-${var.aws_region}"

  # A project account (new AWS sign-up) cannot create OIDC providers: no GitHub deploy roles there.
  github_oidc       = var.enable_github_oidc && !var.project_account
  deploy_projects   = local.github_oidc ? var.projects : {}
  oidc_provider_arn = !local.github_oidc ? "" : (var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn)

  # Flatten project -> managed policy pairs for for_each
  policy_attachments = merge([
    for repo, cfg in local.deploy_projects : {
      for p in cfg.managed_policies : "${repo}|${p}" => { repo = repo, policy = p }
    }
  ]...)

  projects_with_iam = { for repo, cfg in local.deploy_projects : repo => cfg if length(cfg.iam_prefixes) > 0 }

  # Every role a project creates must carry this permissions boundary (see below).
  boundary_name = "gha-workload-boundary"
  boundary_arn  = "arn:${local.partition}:iam::${local.account_id}:policy/${local.boundary_name}"
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC provider (one per AWS account)
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count = local.github_oidc && var.create_github_oidc_provider ? 1 : 0

  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
  # thumbprint_list is no longer required: AWS validates GitHub's certificate with its own trust store.
}

data "aws_iam_openid_connect_provider" "github" {
  count = local.github_oidc && !var.create_github_oidc_provider ? 1 : 0
  url   = "https://${local.oidc_host}"
}

# ---------------------------------------------------------------------------
# One deploy role per repository: gha-<repo>
# Only the main branch, or jobs that use the "aws" environment, can assume it
# (connect-github.sh restricts that environment to the main branch).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "trust" {
  for_each = local.deploy_projects

  statement {
    sid     = "GitHubOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values = [
        "repo:${var.github_owner}/${each.key}:ref:refs/heads/main",
        "repo:${var.github_owner}/${each.key}:environment:aws",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each = local.deploy_projects

  name                 = "gha-${each.key}"
  description          = "GitHub Actions deploy role for ${var.github_owner}/${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  max_session_duration = 3600

  tags = {
    Project = each.key
  }
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = local.policy_attachments

  role       = aws_iam_role.deploy[each.value.repo].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value.policy}"
}

# ---------------------------------------------------------------------------
# Permissions boundary for roles that projects create (ECS task roles, Lambda
# roles, EKS roles). A boundary is a ceiling: a role can only use permissions
# that both its own policies AND the boundary allow. This one allows everything
# except changing IAM, Organizations and account settings, so a role created by
# a deploy role can never be more powerful than the deploy role itself.
#
# Without it, prefix-scoped IAM is NOT enough: a compromised workflow could
# create "shipit-x", attach AdministratorAccess, trust itself, and assume it.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "workload_boundary" {
  # A boundary is a ceiling, not a grant: these checks read it as if it gave permissions.
  #checkov:skip=CKV_AWS_107:Permissions boundary, grants nothing on its own
  #checkov:skip=CKV_AWS_108:Permissions boundary, grants nothing on its own
  #checkov:skip=CKV_AWS_109:Permissions boundary, grants nothing on its own
  #checkov:skip=CKV_AWS_110:Permissions boundary; it removes IAM writes, the escalation path
  #checkov:skip=CKV_AWS_111:Permissions boundary, grants nothing on its own
  statement {
    sid         = "EverythingExceptIamOrgAndAccountChanges"
    effect      = "Allow"
    not_actions = ["iam:*", "organizations:*", "account:*"]
    resources   = ["*"]
  }

  statement {
    sid       = "IamReadsAndServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:Get*", "iam:List*", "iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = local.boundary_name
  description = "Permissions boundary for roles created by GitHub Actions deploy roles: no IAM, Organizations or account changes."
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

# PowerUserAccess cannot touch IAM. Projects that create task/Lambda roles get
# IAM rights limited to roles/policies whose names start with their prefix, and
# every role they create or give permissions to must carry the boundary above.
data "aws_iam_policy_document" "scoped_iam" {
  for_each = local.projects_with_iam

  statement {
    sid    = "GrantOnlyToRolesWithTheBoundary"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy",
      "iam:CreateRole",
      "iam:PutRolePermissionsBoundary",
      "iam:PutRolePolicy",
    ]
    resources = [for p in each.value.iam_prefixes : "arn:${local.partition}:iam::${local.account_id}:role/${p}*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid    = "ManagePrefixedRolesAndPolicies"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListPolicyVersions",
      "iam:ListRolePolicies",
      "iam:PassRole",
      "iam:TagPolicy",
      "iam:TagRole",
      "iam:UntagPolicy",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
    ]
    resources = flatten([
      for p in each.value.iam_prefixes : [
        "arn:${local.partition}:iam::${local.account_id}:role/${p}*",
        "arn:${local.partition}:iam::${local.account_id}:policy/${p}*",
      ]
    ])
  }

  statement {
    sid    = "ManagePrefixedInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]
    resources = [for p in each.value.iam_prefixes : "arn:${local.partition}:iam::${local.account_id}:instance-profile/${p}*"]
  }

  statement {
    sid       = "ReadOnlyIamLookups"
    effect    = "Allow"
    actions   = ["iam:ListRoles", "iam:ListPolicies", "iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviders"]
    resources = ["*"]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "rds.amazonaws.com",
        "eks.amazonaws.com",
        "eks-nodegroup.amazonaws.com",
        "autoscaling.amazonaws.com",
        "spot.amazonaws.com",
        "ops.apigateway.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "NeverRemoveOrRewriteTheBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }

  statement {
    sid    = "NeverChangeTheBoundaryPolicy"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = [local.boundary_arn]
  }
}

resource "aws_iam_role_policy" "scoped_iam" {
  for_each = local.projects_with_iam

  name   = "scoped-iam-${each.key}"
  role   = aws_iam_role.deploy[each.key].id
  policy = data.aws_iam_policy_document.scoped_iam[each.key].json
}

# ---------------------------------------------------------------------------
# Security baseline: the same module clients get as the S8 fix pack
# (../modules/security-baseline). Free guardrails on; CloudTrail on (cents a month);
# GuardDuty and AWS Config off unless you choose them (they cost money every month).
# ---------------------------------------------------------------------------
module "baseline" {
  source = "../modules/security-baseline"

  name_prefix                      = "foundation"
  s3_account_public_access_block   = var.enable_account_guardrails
  ebs_encryption_by_default        = var.enable_account_guardrails
  ebs_snapshot_block_public_access = var.enable_account_guardrails
  ec2_imdsv2_default               = var.enable_account_guardrails
  iam_password_policy              = var.enable_account_guardrails
  # IAM Access Analyzer and GuardDuty are not available in a project account (new AWS sign-up).
  access_analyzer  = var.enable_account_guardrails && !var.project_account
  ecr_scan_on_push = var.enable_account_guardrails
  cloudtrail       = var.enable_cloudtrail
  # A project account only works in one Region, so its trail covers that Region (no multi-Region trail).
  cloudtrail_multi_region = !var.project_account
  guardduty               = var.enable_guardduty && !var.project_account
  # Budgets for this account live in budget.tf.
}

# The two guardrails used to be defined here; keep their state when upgrading.
moved {
  from = aws_s3_account_public_access_block.this
  to   = module.baseline.aws_s3_account_public_access_block.this
}

moved {
  from = aws_ebs_encryption_by_default.this
  to   = module.baseline.aws_ebs_encryption_by_default.this
}
