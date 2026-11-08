#!/usr/bin/env bash
# LD-04: give CloudWatch log groups a retention period of at least N days.
# Dry run by default: prints what it would change. Add --apply to change it.
#
#   bash set-log-retention.sh --days 365 --regions ap-south-1,us-east-1            # dry run
#   bash set-log-retention.sh --days 365 --regions ap-south-1 --apply
#   bash set-log-retention.sh --days 365 --include-never-expire --apply            # also cap "never expire" (cost, S1 LOGS-001)
set -euo pipefail

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; }

DAYS=365
APPLY=0
NEVER=0
REGIONS="$(aws configure get region 2>/dev/null || true)"
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --regions) REGIONS="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --include-never-expire) NEVER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

ALLOWED="1 3 5 7 14 30 60 90 120 150 180 365 400 545 731 1096 1827 2192 2557 2922 3288 3653"
case " $ALLOWED " in *" $DAYS "*) ;; *) echo "--days must be one of: $ALLOWED" >&2; exit 2 ;; esac
[ -n "$REGIONS" ] || { echo "no region: pass --regions or set a default region" >&2; exit 2; }

changed=0
for region in ${REGIONS//,/ }; do
  while IFS=$'\t' read -r name days; do
    [ -n "$name" ] || continue
    if [ "$days" = "None" ]; then
      [ "$NEVER" = 1 ] || continue
      why="never expires"
    elif [ "$days" -lt "$DAYS" ]; then
      why="kept $days days"
    else
      continue
    fi
    if [ "$APPLY" = 1 ]; then
      aws logs put-retention-policy --region "$region" --log-group-name "$name" --retention-in-days "$DAYS"
      echo "set   $region $name ($why) -> $DAYS days"
    else
      echo "would set $region $name ($why) -> $DAYS days"
    fi
    changed=$((changed + 1))
  done < <(aws logs describe-log-groups --region "$region" --query 'logGroups[].[logGroupName,retentionInDays]' --output text)
done

[ "$APPLY" = 1 ] || echo "Dry run: $changed log group(s) would change. Re-run with --apply."
