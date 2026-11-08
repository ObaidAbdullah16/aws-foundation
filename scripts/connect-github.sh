#!/usr/bin/env bash
# Copies each deploy role ARN into its GitHub repository as Actions variables
# (AWS_ROLE_ARN, AWS_REGION) and creates the "aws" environment.
# Requires: gh (logged in), terraform (foundation already applied).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/../_setup/config.env}"
# shellcheck disable=SC1090
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
: "${GITHUB_OWNER:=ObaidAbdullah16}"

log() { printf '\033[1;34m[connect]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
command -v gh >/dev/null || die "gh is not installed"
command -v jq >/dev/null || die "jq is not installed"
gh auth status >/dev/null 2>&1 || die "Run: gh auth login"

ROLES_JSON="$(terraform -chdir="$ROOT/terraform" output -json deploy_role_arns)"
REGION="$(terraform -chdir="$ROOT/terraform" output -raw region)"

for repo in $(jq -r 'keys[]' <<<"$ROLES_JSON"); do
  arn="$(jq -r --arg r "$repo" '.[$r]' <<<"$ROLES_JSON")"
  full="${GITHUB_OWNER}/${repo}"
  if ! gh repo view "$full" >/dev/null 2>&1; then
    log "skip ${full} (repository not found - run _setup/publish-to-github.sh first)"
    continue
  fi
  gh variable set AWS_ROLE_ARN --repo "$full" --body "$arn" >/dev/null
  gh variable set AWS_REGION --repo "$full" --body "$REGION" >/dev/null
  # The AWS role trusts any job that uses the "aws" environment, so the environment
  # itself must only accept the main branch (otherwise a workflow run on another
  # branch, e.g. via "Run workflow", could assume the role).
  gh api --method PUT "repos/${full}/environments/aws" --input - >/dev/null <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
  if ! gh api "repos/${full}/environments/aws/deployment-branch-policies" \
      --jq '.branch_policies[].name' 2>/dev/null | grep -qx main; then
    gh api --method POST "repos/${full}/environments/aws/deployment-branch-policies" \
      -f name=main -f type=branch >/dev/null
  fi
  log "${full}: AWS_ROLE_ARN set, environment 'aws' ready (main branch only)"
done
log "All repositories connected. Workflows can now log in to AWS with OIDC (no access keys)."
