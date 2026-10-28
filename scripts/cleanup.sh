#!/usr/bin/env bash
# Deletes everything deploy.sh created, in reverse order.
#
#   ./cleanup.sh [APP ...]        (default: app1)
#
# Per-application stacks go first because an endpoint service cannot be deleted while an
# endpoint is connected to it. The shared stacks are deleted last.
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
APPS=("$@")
[[ ${#APPS[@]} -eq 0 ]] && APPS=("app1")

exists() { # stack region
  aws cloudformation describe-stacks --region "$2" --stack-name "$1" >/dev/null 2>&1
}
remove() { # stack region
  if exists "$1" "$2"; then
    echo "==> Deleting $1 ($2)"
    aws cloudformation delete-stack --region "$2" --stack-name "$1"
    aws cloudformation wait stack-delete-complete --region "$2" --stack-name "$1"
  else
    echo "==> $1 ($2) not found, skipping"
  fi
}

for app in "${APPS[@]}"; do remove "pattern-ingress-$app" "$REGION"; done
for app in "${APPS[@]}"; do remove "pattern-workload-$app" "$REGION"; done
remove pattern-waf-cloudfront us-east-1
remove pattern-waf-regional "$REGION"
remove pattern-ingress-core "$REGION"
echo "Done."
