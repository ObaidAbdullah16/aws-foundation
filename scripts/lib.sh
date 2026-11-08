#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables defined here are used by the scripts that source it
# Shared settings and helpers for the foundation scripts (bootstrap, destroy, up, down, status).
# Sourced, not executed. Settings come from ../_setup/config.env or the environment.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TF_DIR="$ROOT/terraform"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/../_setup/config.env}"
# shellcheck disable=SC1090
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

: "${AWS_REGION:=ap-southeast-2}"
: "${AWS_ACCOUNT_TYPE:=classic}"  # project = new AWS sign-up: no GitHub OIDC, laptop only
: "${GITHUB_OWNER:=ObaidAbdullah16}"
: "${MONTHLY_BUDGET_USD:=10}"
: "${DAILY_BUDGET_USD:=1}"
: "${AUTO_APPROVE:=0}"          # 1 = apply/destroy without the "yes" prompt
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
[[ -n "${AWS_PROFILE:-}" ]] && export AWS_PROFILE

log()  { printf '\033[1;34m[foundation]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "$c is not installed (run: bash _setup/install-tools-wsl.sh)"; done; }

account_id() {
  aws sts get-caller-identity --query Account --output text 2>/dev/null \
    || die "AWS CLI is not logged in. Run: bash _setup/aws-login.sh   (Guide 01, 'Your daily AWS login')"
}

is_project_account() { [[ "$AWS_ACCOUNT_TYPE" == project ]]; }

state_bucket_name() { echo "tfstate-$(account_id)-${AWS_REGION}"; }
logs_bucket_name()  { echo "foundation-logs-$(account_id)-${AWS_REGION}"; }

tf_init() {
  terraform -chdir="$TF_DIR" init -input=false -reconfigure \
    -backend-config="bucket=$(state_bucket_name)" \
    -backend-config="key=aws-foundation/terraform.tfstate" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="use_lockfile=true" \
    -backend-config="encrypt=true" >/dev/null
}

in_state() { terraform -chdir="$TF_DIR" state list 2>/dev/null | grep -qxF "$1"; }

# The CloudTrail log archive. `down` keeps it (your audit history); `down --all` deletes it.
LOGS_RESOURCES=(
  'module.baseline.aws_s3_bucket.logs[0]'
  'module.baseline.aws_s3_bucket_public_access_block.logs[0]'
  'module.baseline.aws_s3_bucket_ownership_controls.logs[0]'
  'module.baseline.aws_s3_bucket_versioning.logs[0]'
  'module.baseline.aws_s3_bucket_server_side_encryption_configuration.logs[0]'
  'module.baseline.aws_s3_bucket_lifecycle_configuration.logs[0]'
  'module.baseline.aws_s3_bucket_policy.logs[0]'
)

# Variables Terraform needs for plan, apply, import and destroy.
tf_vars() {
  local oidc="${1:-true}"
  TF_VARS=(
    -var "aws_region=${AWS_REGION}"
    -var "github_owner=${GITHUB_OWNER}"
    -var "alert_email=${ALERT_EMAIL:-unused@example.com}"
    -var "monthly_budget_usd=${MONTHLY_BUDGET_USD}"
    -var "daily_budget_usd=${DAILY_BUDGET_USD}"
    -var "create_github_oidc_provider=${oidc}"
    -var "project_account=$(is_project_account && echo true || echo false)"
  )
}

# Empty a bucket completely: every object version and delete marker.
empty_bucket() {
  local b="$1"
  aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 || return 0
  log "Emptying s3://$b (all versions)"
  python3 - "$b" <<'PY'
import json, subprocess, sys
bucket = sys.argv[1]
def aws(*args):
    return subprocess.run(["aws", *args], check=True, capture_output=True, text=True).stdout
token = None
while True:
    args = ["s3api", "list-object-versions", "--bucket", bucket, "--max-items", "1000", "--output", "json"]
    if token:
        args += ["--starting-token", token]
    page = json.loads(aws(*args) or "{}")
    objs = [{"Key": o["Key"], "VersionId": o["VersionId"]} for o in page.get("Versions", []) + page.get("DeleteMarkers", [])]
    for i in range(0, len(objs), 1000):
        aws("s3api", "delete-objects", "--bucket", bucket, "--delete", json.dumps({"Objects": objs[i:i + 1000], "Quiet": True}))
    token = page.get("NextToken")
    if not token:
        break
PY
}

# Empty a bucket, then delete it.
delete_bucket_completely() {
  local b="$1"
  aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 || return 0
  empty_bucket "$b"
  aws s3api delete-bucket --bucket "$b"
  log "Deleted s3://$b"
}

# Which other projects still have resources in the shared state bucket?
# Prints "<state key> <number of resources>" for each one that is not empty.
other_projects_with_resources() {
  local b key n
  b="$(state_bucket_name)"
  aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 || return 0
  for key in $(aws s3api list-objects-v2 --bucket "$b" --query 'Contents[].Key' --output text 2>/dev/null | tr '\t' '\n'); do
    [[ "$key" == aws-foundation/* || "$key" == "None" || "$key" != *.tfstate ]] && continue
    n="$(aws s3 cp "s3://$b/$key" - 2>/dev/null | jq '[.resources[]? | select(.mode == "managed")] | length' 2>/dev/null || echo 0)"
    [[ "${n:-0}" -gt 0 ]] && echo "$key $n"
  done
  return 0
}
