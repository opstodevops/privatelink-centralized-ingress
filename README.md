# Centralized internet ingress for isolated workloads with AWS PrivateLink

Sample code for the blog post [Centralize internet ingress for isolated workloads with AWS PrivateLink](docs/blog-post.md).

A shared ingress VPC, owned by a networking team, delivers internet traffic to isolated workload VPCs through AWS PrivateLink. Each workload VPC has no internet gateway and no NAT gateway. Amazon CloudFront (with a VPC origin), AWS WAF, and AWS Network Firewall are optional layers in the ingress VPC.

```
Internet -> CloudFront (optional, + AWS WAF) -> ALB (+ AWS WAF without CloudFront)
         -> Network Firewall (optional) -> interface VPC endpoint
         == AWS PrivateLink ==> NLB + endpoint service -> application (workload VPC)
```

The architecture diagram source is [`docs/architecture.drawio`](docs/architecture.drawio).

## Repository layout

| Path | Owner | Purpose |
|---|---|---|
| `templates/ingress-core.yaml` | Networking team | Ingress VPC, subnets, optional Network Firewall and logging. Publishes `/pattern/ingress/*` to Parameter Store. Deploy once. |
| `templates/waf.yaml` | Networking team | AWS WAF web ACL. `Scope=CLOUDFRONT` in `us-east-1`, or `Scope=REGIONAL` in the ingress Region. |
| `templates/workload.yaml` | Application team | Isolated workload VPC, stub application, NLB, and endpoint service. Deploy once per application. |
| `templates/ingress-app.yaml` | Networking team | Interface endpoint, ALB, target registration, optional CloudFront distribution. Deploy once per application. |
| `scripts/deploy.sh` | | Deploys the stacks in order with the AWS CLI. |
| `scripts/cleanup.sh` | | Deletes the stacks in reverse order. |

## Prerequisites

- AWS CLI version 2, configured with credentials that can create the resources in the templates, including IAM roles.
- `bash` and `curl`.
- A Region that supports [CloudFront VPC origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html) if you use `--cloudfront`. The default Availability Zone IDs (`usw2-az1`, `usw2-az2`) are for `us-west-2`. For another Region, deploy `ingress-core.yaml` with the `AzId1` and `AzId2` parameters.

## Deploy

```bash
export AWS_REGION=us-west-2

# Core path: internet-facing ALB restricted to your current public IP address
./scripts/deploy.sh

# Full path: CloudFront VPC origin, AWS WAF, Network Firewall, and logging
./scripts/deploy.sh --cloudfront --waf --firewall --logging

# Another application on the same ingress VPC (use the same flags as the first run)
./scripts/deploy.sh --app app2
```

Choose `--cloudfront` on the first run. It decides whether the ALB subnets are public or private, and you can't switch an existing application between the two modes in place.

Measured in `us-west-2`: about 7 minutes for the core path and about 26 minutes for the full path.

## Test

```bash
URL=$(aws cloudformation describe-stacks --stack-name pattern-ingress-app1 \
  --query "Stacks[0].Outputs[?OutputKey=='Url'].OutputValue" --output text)

curl -s "$URL"                                              # JSON from the stub application
curl -s -o /dev/null -w "%{http_code}\n" -A badbot "$URL"   # 403 with --waf
curl -s -o /dev/null -w "%{http_code}\n" "${URL}blocked"    # 502 with --firewall
```

## Clean up

```bash
./scripts/cleanup.sh app1        # list every application you deployed
```

Cleanup of the full path takes about 18 minutes.

## Security considerations

This is sample code for testing, not a production configuration:

- Traffic uses HTTP between the viewer-facing layer and the ALB. CloudFront uses its default `*.cloudfront.net` certificate and redirects viewers to HTTPS, but the CloudFront-to-ALB hop is HTTP. Without CloudFront, the ALB listens on HTTP only and is reachable from your current public IP address only. For production, add your own domain and AWS Certificate Manager certificates, an HTTPS listener on the ALB, and an `https-only` VPC origin.
- The stub application has no authentication.
- Log groups keep logs for 7 days and use the default CloudWatch Logs encryption.

## Cost

The stacks create billed resources: load balancers, interface endpoints, an EC2 instance, and, when turned on, Network Firewall endpoints, AWS WAF web ACLs, a CloudFront distribution, and CloudWatch Logs. Use the [AWS Pricing Calculator](https://calculator.aws/) for an estimate, and run `cleanup.sh` when you finish.

## License

To be added before publishing.
