#!/usr/bin/env bash
# Shows whether the foundation is up, what it created, and what every project has in AWS.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need aws terraform jq

ACCOUNT_ID="$(account_id)"
STATE="$(state_bucket_name)"
if ! aws s3api head-bucket --bucket "$STATE" >/dev/null 2>&1; then
  echo "aws-foundation: DOWN (no state bucket) - start it with: bash scripts/up.sh"
  exit 0
fi
tf_init
n="$(terraform -chdir="$TF_DIR" state list 2>/dev/null | grep -vc '^data\.' || true)"
if [[ "${n:-0}" -gt 0 ]]; then
  echo "aws-foundation: UP ($n resources, ~\$0/month: CloudTrail log storage is cents)"
else
  echo "aws-foundation: DOWN (kept: state bucket s3://$STATE$(aws s3api head-bucket --bucket "$(logs_bucket_name)" >/dev/null 2>&1 && echo " and log archive s3://$(logs_bucket_name)"))"
fi

echo "== Identity"
aws sts get-caller-identity --query '[Account, Arn]' --output text | sed 's/^/  /'

echo "== Deploy roles (one per GitHub repository)"
if is_project_account; then
  echo "  none - project account: GitHub Actions cannot log in to AWS here (projects run from your laptop)"
else
  aws iam list-roles --query "Roles[?starts_with(RoleName, 'gha-')].[RoleName,CreateDate]" --output text | sed 's/^/  /'
fi

echo "== Project roles and their permissions boundary (every one should show gha-workload-boundary)"
for prefix in shipit incidentscribe kubeops restore-drill serverforge; do
  aws iam list-roles --query "Roles[?starts_with(RoleName, '${prefix}')].RoleName" --output text | tr '\t' '\n' |
    while read -r role; do
      [[ -n "$role" ]] || continue
      boundary="$(aws iam get-role --role-name "$role" --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text)"
      printf '  %-40s %s\n' "$role" "${boundary##*/}"
    done
done

echo "== Budgets"
aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
  --query 'Budgets[].[BudgetName,BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount,CalculatedSpend.ForecastedSpend.Amount]' \
  --output table 2>/dev/null || echo "  (none)"

echo "== Projects with resources in AWS (Terraform state in s3://$STATE)"
busy="$(other_projects_with_resources)"
if [[ -n "$busy" ]]; then
  while read -r key count; do printf '  %-45s %s resources\n' "$key" "$count"; done <<<"$busy"
else
  echo "  none - every project is down"
fi
