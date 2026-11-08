#!/usr/bin/env bash
# NC-03: require IMDSv2 on EXISTING instances (the baseline module covers new ones).
# Dry run by default. Test one instance first: very old SDKs and agents only speak IMDSv1.
#
#   bash require-imdsv2.sh --regions ap-south-1              # list instances that still allow IMDSv1
#   bash require-imdsv2.sh --regions ap-south-1 --apply      # require tokens, hop limit 2
set -euo pipefail

usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; }

APPLY=0
REGIONS="$(aws configure get region 2>/dev/null || true)"
while [ $# -gt 0 ]; do
  case "$1" in
    --regions) REGIONS="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done
[ -n "$REGIONS" ] || { echo "no region: pass --regions or set a default region" >&2; exit 2; }

count=0
for region in ${REGIONS//,/ }; do
  for id in $(aws ec2 describe-instances --region "$region" \
      --filters Name=metadata-options.http-tokens,Values=optional Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query 'Reservations[].Instances[].InstanceId' --output text); do
    if [ "$APPLY" = 1 ]; then
      aws ec2 modify-instance-metadata-options --region "$region" --instance-id "$id" \
        --http-tokens required --http-put-response-hop-limit 2 --http-endpoint enabled >/dev/null
      echo "required IMDSv2: $region $id"
    else
      echo "allows IMDSv1:   $region $id"
    fi
    count=$((count + 1))
  done
done
[ "$APPLY" = 1 ] || echo "Dry run: $count instance(s) still allow IMDSv1. Re-run with --apply after testing one."
