#!/usr/bin/env bash
# Start (or update) the AWS foundation in one go: state bucket + Terraform (roles, budgets,
# guardrails, CloudTrail), then connect every published GitHub repository to its deploy role.
# Safe to run as often as you like.
#
#   bash scripts/up.sh                 # asks "yes" before Terraform changes anything
#   AUTO_APPROVE=1 bash scripts/up.sh  # no prompt
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need aws terraform jq python3

bash "$HERE/bootstrap.sh"

if is_project_account; then
  log "GitHub stays disconnected from AWS (project account): start, stop and deploy the projects from this laptop."
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  bash "$HERE/connect-github.sh"
else
  warn "GitHub CLI not logged in: skipped connect-github.sh. Run 'gh auth login', then: bash scripts/connect-github.sh"
fi
log "Foundation is up. Check it any time with: bash scripts/status.sh"
