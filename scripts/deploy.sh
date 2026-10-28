#!/usr/bin/env bash
# Deploys the centralized ingress pattern with the AWS CLI.
#
#   ./deploy.sh [--app NAME] [--cloudfront] [--firewall] [--waf] [--logging]
#
# Run it once per application. The shared stacks (ingress-core, waf) are created on the
# first run and left unchanged by later runs. Choose --cloudfront once, before the first
# app: it decides whether the ALB subnets are private (CloudFront VPC origin) or public.
set -euo pipefail

APP="app1"
CLOUDFRONT="false"
FIREWALL="false"
WAF="false"
LOGGING="false"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
TAGS="project=blog3-privatelink-ingress"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/templates"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --cloudfront) CLOUDFRONT="true"; shift ;;
    --firewall) FIREWALL="true"; shift ;;
    --waf) WAF="true"; shift ;;
    --logging) LOGGING="true"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

deploy() { # stack template region [parameter overrides...]
  local stack="$1" template="$2" region="$3"; shift 3
  echo "==> $stack ($region)"
  aws cloudformation deploy --region "$region" --stack-name "$stack" \
    --template-file "$DIR/$template" --capabilities CAPABILITY_IAM \
    --tags "$TAGS" --no-fail-on-empty-changeset \
    ${1:+--parameter-overrides "$@"}
}
output() { # stack region key
  aws cloudformation describe-stacks --region "$2" --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$3'].OutputValue" --output text
}

# 1. Networking team: shared ingress VPC (once)
deploy pattern-ingress-core ingress-core.yaml "$REGION" \
  EnableCloudFront="$CLOUDFRONT" EnableNetworkFirewall="$FIREWALL" EnableLogging="$LOGGING"

# 2. Networking team: web ACLs (optional). CloudFront-scope web ACLs only exist in us-east-1.
WEB_ACL_ARGS=()
if [[ "$WAF" == "true" ]]; then
  if [[ "$CLOUDFRONT" == "true" ]]; then
    deploy pattern-waf-cloudfront waf.yaml us-east-1 Scope=CLOUDFRONT EnableLogging="$LOGGING"
    WEB_ACL_ARGS+=("CloudFrontWebAclArn=$(output pattern-waf-cloudfront us-east-1 WebAclArn)")
  else
    deploy pattern-waf-regional waf.yaml "$REGION" Scope=REGIONAL EnableLogging="$LOGGING"
    WEB_ACL_ARGS+=("RegionalWebAclArn=$(output pattern-waf-regional "$REGION" WebAclArn)")
  fi
fi

# 3. Application team: isolated workload VPC and endpoint service
deploy "pattern-workload-$APP" workload.yaml "$REGION" AppName="$APP"

# 4. Networking team: endpoint, ALB and (optionally) CloudFront for this application
if [[ "$CLOUDFRONT" == "true" ]]; then
  PREFIX_LIST="$(aws ec2 describe-managed-prefix-lists --region "$REGION" \
    --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
    --query 'PrefixLists[0].PrefixListId' --output text)"
  ACCESS_ARGS=("CloudFrontPrefixListId=$PREFIX_LIST")
else
  # Only your current public IP address may reach the internet-facing ALB.
  ACCESS_ARGS=("AllowedCidr=$(curl -fsS https://checkip.amazonaws.com)/32")
fi
deploy "pattern-ingress-$APP" ingress-app.yaml "$REGION" AppName="$APP" \
  "${ACCESS_ARGS[@]}" ${WEB_ACL_ARGS[@]+"${WEB_ACL_ARGS[@]}"}

URL="$(output "pattern-ingress-$APP" "$REGION" Url)"
echo
echo "Deployed. Test it with:  curl $URL"
