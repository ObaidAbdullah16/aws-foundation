#!/usr/bin/env bash
# Removes the foundation (deploy roles, OIDC provider if Terraform made it, budgets, guardrails, CloudTrail).
# Run it only after every other project is fully down - the deploy roles are what their
# Control and Auto-stop workflows use. scripts/down.sh calls this.
#
#   bash scripts/destroy.sh          # keeps the Terraform state bucket and the CloudTrail log archive (cents a month)
#   bash scripts/destroy.sh --all    # deletes those too: nothing of the foundation is left
#   FORCE=1 bash scripts/destroy.sh  # skip the "other projects are still up" check (not recommended)
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need aws terraform jq python3

ALL=0
for a in "$@"; do
  case "$a" in
    --all) ALL=1 ;;
    *) die "unknown option: $a (use --all or nothing)" ;;
  esac
done

STATE="$(state_bucket_name)"
LOGS="$(logs_bucket_name)"
aws s3api head-bucket --bucket "$STATE" >/dev/null 2>&1 || { log "No state bucket s3://$STATE - the foundation is not set up. Nothing to do."; exit 0; }

# 1. Refuse while other projects still have resources (their stop buttons need the deploy roles)
busy="$(other_projects_with_resources)"
if [[ -n "$busy" && "${FORCE:-0}" != "1" ]]; then
  warn "These projects still have resources in AWS:"
  while read -r line; do printf '    %s\n' "$line" >&2; done <<<"$busy"
  die "Stop them first (bash _setup/projects.sh status all shows how), e.g. 'bash _setup/projects.sh down shipit --all'. FORCE=1 skips this check."
fi

if [[ "$ALL" == 1 ]]; then
  echo "This deletes the deploy roles (if any), budgets, guardrails, CloudTrail, the CloudTrail log archive"
  echo "s3://$LOGS and the Terraform state bucket s3://$STATE. Nothing of the foundation is left."
else
  echo "This deletes the deploy roles (if any), budgets, guardrails and CloudTrail."
  echo "Kept (cents a month): the state bucket s3://$STATE and the log archive s3://$LOGS."
fi
if [[ "$AUTO_APPROVE" != "1" ]]; then
  read -r -p "Type 'destroy' to continue: " answer
  [[ "$answer" == "destroy" ]] || { echo "Cancelled."; exit 0; }
fi

tf_init
CREATE_OIDC=false
in_state 'aws_iam_openid_connect_provider.github[0]' && CREATE_OIDC=true
tf_vars "$CREATE_OIDC"

# 2. Keep the log archive out of the destroy (default), so your audit history stays
if [[ "$ALL" != 1 ]]; then
  for r in "${LOGS_RESOURCES[@]}"; do
    if in_state "$r"; then terraform -chdir="$TF_DIR" state rm "$r" >/dev/null; fi
  done
else
  # --all: stop CloudTrail first, so nothing new lands in the archive, then empty it
  # (Terraform cannot delete a bucket that still holds objects).
  if in_state 'module.baseline.aws_cloudtrail.this[0]'; then
    log "Deleting the CloudTrail trail first"
    terraform -chdir="$TF_DIR" destroy -input=false -auto-approve "${TF_VARS[@]}" \
      -target='module.baseline.aws_cloudtrail.this[0]' >/dev/null
  fi
  empty_bucket "$LOGS"
fi

# 3. Destroy everything else Terraform manages
repos="$(terraform -chdir="$TF_DIR" output -json deploy_role_arns 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)"
log "terraform destroy"
terraform -chdir="$TF_DIR" destroy -input=false -auto-approve "${TF_VARS[@]}"

# 4. Disconnect GitHub: without AWS_ROLE_ARN the AWS workflows (Deploy, Control, nightly Auto-stop)
#    are skipped instead of failing every night against a role that no longer exists.
if [[ -n "$repos" ]] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  for r in $repos; do
    gh variable delete AWS_ROLE_ARN --repo "${GITHUB_OWNER}/${r}" >/dev/null 2>&1 || true
  done
  log "Disconnected GitHub: removed AWS_ROLE_ARN from the repositories (scripts/up.sh connects them again)"
elif [[ -n "$repos" ]]; then
  warn "gh is not logged in: delete the variable AWS_ROLE_ARN in each repository by hand, or the nightly Auto-stop runs will fail"
fi

if [[ "$ALL" == 1 ]]; then
  delete_bucket_completely "$LOGS"      # only if Terraform did not already delete it
  rm -rf "$TF_DIR/.terraform" "$TF_DIR/.terraform.lock.hcl"
  delete_bucket_completely "$STATE"
  log "The foundation is completely gone. To start again: bash scripts/up.sh"
else
  log "Foundation removed. Kept: s3://$STATE and s3://$LOGS (cents a month)."
  log "Start again any time with: bash scripts/up.sh   (it re-adopts the kept log archive)"
fi
