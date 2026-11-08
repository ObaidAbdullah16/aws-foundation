#!/usr/bin/env bash
# Stop the AWS foundation. Do this last: every other project must be down first.
#
#   bash scripts/down.sh          # removes roles, budgets, guardrails and CloudTrail;
#                                 # keeps the state bucket and the CloudTrail log archive (cents a month)
#   bash scripts/down.sh --all    # removes those too - nothing of the foundation is left
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
exec bash "$HERE/destroy.sh" "$@"
