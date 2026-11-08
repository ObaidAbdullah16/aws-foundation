#!/usr/bin/env bash
# Creates the Terraform state bucket (if missing) and applies the foundation stack.
# Safe to run again at any time: every step is idempotent. scripts/up.sh runs it for you.
#
# Usage:
#   bash scripts/bootstrap.sh                       # reads ../_setup/config.env (ALERT_EMAIL=...)
#   AUTO_APPROVE=1 bash scripts/bootstrap.sh        # no "yes" prompt
#   ALERT_EMAIL=you@example.com bash scripts/bootstrap.sh
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need aws terraform jq python3
[[ -n "${ALERT_EMAIL:-}" ]] || die "Set ALERT_EMAIL in _setup/config.env (the address that receives budget alerts)."

ACCOUNT_ID="$(account_id)"
BUCKET="$(state_bucket_name)"
log "Account ${ACCOUNT_ID}, region ${AWS_REGION}, state bucket ${BUCKET}"

# 1. State bucket ------------------------------------------------------------
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  log "State bucket already exists"
else
  log "Creating state bucket"
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
fi
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration \
  '{"Rules":[{"ID":"expire-old-state-versions","Status":"Enabled","Filter":{},"NoncurrentVersionExpiration":{"NoncurrentDays":90},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}'

# 2. Terraform init ------------------------------------------------------------
log "terraform init"
tf_init

# 3. Reuse an existing GitHub OIDC provider (e.g. from an older project) --------
#    If Terraform already manages it, keep managing it.
CREATE_OIDC=true
if is_project_account; then
  log "Project account (new AWS sign-up): AWS does not allow a GitHub OIDC provider here, so no deploy roles are created."
elif ! in_state 'aws_iam_openid_connect_provider.github[0]'; then
  if aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text \
     | tr '\t' '\n' | grep -q 'token.actions.githubusercontent.com'; then
    CREATE_OIDC=false
    log "Found an existing GitHub OIDC provider; reusing it"
  fi
fi
tf_vars "$CREATE_OIDC"

# 4. A CloudTrail log archive kept by an earlier `down`: adopt it again ----------
LOGS="$(logs_bucket_name)"
if [[ "${ENABLE_CLOUDTRAIL:-true}" != "false" ]] && aws s3api head-bucket --bucket "$LOGS" >/dev/null 2>&1 \
   && ! in_state "${LOGS_RESOURCES[0]}"; then
  log "Re-adopting the CloudTrail log archive kept by the last 'down': s3://$LOGS"
  for r in "${LOGS_RESOURCES[@]}"; do
    terraform -chdir="$TF_DIR" import -input=false "${TF_VARS[@]}" "$r" "$LOGS" >/dev/null \
      || warn "could not import $r (Terraform will try to create it)"
  done
fi

# 5. Apply -------------------------------------------------------------------------
log "terraform apply"
approve=(); [[ "$AUTO_APPROVE" == "1" ]] && approve=(-auto-approve)
terraform -chdir="$TF_DIR" apply -input=false "${approve[@]}" "${TF_VARS[@]}"

if is_project_account; then
  log "Done: state bucket, budgets, guardrails and CloudTrail are in place."
else
  log "Done. Deploy roles:"
  terraform -chdir="$TF_DIR" output -json deploy_role_arns
  log "Next: bash scripts/connect-github.sh   (copies the role ARNs into each GitHub repo; scripts/up.sh does it for you)"
fi
log "Check your inbox and confirm the AWS Budgets notification email if asked."
