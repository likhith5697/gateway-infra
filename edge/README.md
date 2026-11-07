# edge: public HTTP API, Lambda authorizer, VPC Link

The public entry point. Requests flow:

```
client ──► API Gateway HTTP API ($default stage, throttled)
             │  route from routes.yaml ("GET /orders/{id}")
             │  auth: custom ──► Lambda authorizer (JWT HS256) ──► allow / deny
             ▼
           VPC Link (private subnets) ──► internal LB listener ──► cluster gateway ──► orders pods
```

State: same S3 bucket and lock table as `cluster/`, separate key `edge/terraform.tfstate`.

## Resources

| File | Creates |
|---|---|
| `main.tf` | HTTP API, `$default` stage (auto-deploy, 10 rps / 20 burst throttle), VPC Link + its security group (egress to the VPC only), and the **api-gateway-routes** module from `platform-templates@v0.1.0` fed by `yamldecode(file(var.routes_file))`. |
| `authorizer.tf` | Lambda authorizer from `../authorizer/build/authorizer.zip`, its IAM role (can only write its own logs), a 7-day log group, the API Gateway REQUEST authorizer (payload 2.0, simple responses, 300 s cache), and the invoke permission scoped to this API's authorizer. |
| `domain.tf` | **Only when `enable_custom_domain = true`:** Route53 zone (looked up, or created with `create_hosted_zone`), ACM certificate for `api.<domain_name>` with DNS validation, API Gateway custom domain (REGIONAL, TLS 1.2) + mapping to `$default`, and an alias A record. |
| `outputs.tf` | `invoke_url` (custom domain if enabled, else execute-api), `execute_api_url`, `name_servers`, `route_keys`, `authorizer_function_name`. |

## Custom domain (optional, off by default)

With `enable_custom_domain = false` (the default), nothing in `domain.tf` is created and you call the `https://<id>.execute-api.us-east-2.amazonaws.com` URL.

To serve `https://api.example.com`:

```hcl
# terraform.tfvars
enable_custom_domain = true
domain_name          = "example.com"
create_hosted_zone   = false   # true if the domain's DNS isn't in Route53 yet
```

- **You must own the domain.** Registering one costs ~$10–15/year, and free-plan credits may not cover domain registration.
- **DNS already in Route53:** keep `create_hosted_zone = false`; the existing zone is looked up.
- **Domain at another registrar:** set `create_hosted_zone = true`, apply, then copy the `name_servers` output into your registrar's NS settings. Certificate validation waits until that's done; if it times out, re-run `apply`.
- **Free-plan check:** Route53, ACM and API Gateway in us-east-2 are all allowed for this account (IAM policy simulation). The certificate is in **us-east-2**, the same region as the API, as REGIONAL endpoints require.
- **Cost:** ACM public certificates are free. A Route53 hosted zone is $0.50/month, plus $0.40 per million queries; alias queries to API Gateway are free.
- **The execute-api URL keeps working** alongside the custom domain.

**Guards:**
- **Routes:** `plan` fails if any route has `auth` other than `custom`, as a backstop to CI's validator.
- **Secret length:** `jwt_secret` must be at least 32 characters.

## Inputs from the cluster session

| Variable | Where it comes from |
|---|---|
| `vpc_id` | `module.vpc.vpc_id` in cluster/ |
| `vpc_link_subnet_ids` | `module.vpc.private_subnets` in cluster/ |
| `internal_listener_arn` | The internal ALB/NLB listener in front of the cluster's gateway (created in the cluster session) |

## Apply (in a cluster session; uses credits)

```bash
make -C ../authorizer zip                              # 1. build the Lambda zip (must exist before plan)
python ../../platform-templates/validate_routes.py ../../routes-repo/routes.yaml   # 2. validate routes

cp terraform.tfvars.example terraform.tfvars           # 3. fill in IDs, issuer, secret
terraform init -backend-config=../cluster/backend.hcl  # 4. same bucket/table as cluster
terraform plan -out=tfplan
terraform apply tfplan

curl -H "Authorization: Bearer $(python ../authorizer/make_token.py)" "$(terraform output -raw invoke_url)/orders"
```

**Destroy edge before cluster:** `terraform destroy` here first, because the VPC Link uses the cluster's subnets.

## CI: `.github/workflows/apply-routes.yml`

Triggered by `repository_dispatch` type **`trigger-apply`** (sent by platform-templates `trigger-apply.yml`) with `client_payload: {repo, sha}`.

| Job | What it does |
|---|---|
| `verify` | Rejects the event unless `repo == likhith5697/routes-repo` and `sha` is a full 40-hex commit SHA. Only the SHA is used after this point. |
| `plan` (env `plan`) | Checks out routes-repo **at that SHA** and requires it to be on routes-repo `main`. Checks out platform-templates **@v0.1.0** (and verifies the tag's commit), **re-runs `validate_routes.py`**, builds the authorizer zip, runs `terraform plan -out=tfplan`, writes the plan to the job summary, then encrypts and uploads plan + zip + lock file as an artifact. |
| `apply` (env `production`) | Waits for **manual approval**, downloads and decrypts the bundle, and runs `terraform apply tfplan`, with no re-plan and no variables. Skipped when the plan has no changes. |

### Why plan and apply are separate jobs

1. **The approval gate works at the job level.** A GitHub Environment with required reviewers pauses a whole *job* before it starts. With plan and apply in one job, you'd approve before seeing the plan, or the apply would run unreviewed.
2. **What you approve is exactly what gets applied.** The apply job uses the saved plan file from the artifact, not a fresh plan. If state changed in between (someone else applied, or AWS drifted), Terraform refuses the stale plan instead of applying something nobody reviewed.
3. **Least privilege.** The `plan` environment holds credentials that only need to read AWS and lock state. The powerful write credentials live only in `production`, and are released only after a human approves.
4. **Audit trail.** The run shows who approved, when, and the exact plan they saw in the summary.

### Hardening

- **The payload is untrusted.** Its values are passed via `env:` (never interpolated into scripts) and checked with exact matches and regexes.
- **Only merged code:** the SHA must be on routes-repo `main`, so a token holder can't apply a fork or an unmerged branch.
- **Validation is re-run here** from a pinned platform-templates version, never trusting the caller's CI. The tag's commit is verified too, in case the tag is ever moved.
- **The plan file contains `jwt_secret` in plain text,** and artifacts on public repos are downloadable, so the bundle is **AES-256 encrypted** with `PLAN_ENCRYPTION_KEY` and kept for 5 days.
- **Pinned actions:** all actions are pinned to full commit SHAs, and Terraform to 1.14.6.
- **No overlapping runs:** `concurrency: edge-apply` prevents two applies at once.

### One-time setup (repo Settings → Environments)

| Environment | Protection | Secrets | Variables |
|---|---|---|---|
| `plan` | none | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (read-only + state lock), `JWT_SECRET`, `PLAN_ENCRYPTION_KEY` | `VPC_ID`, `VPC_LINK_SUBNET_IDS` (JSON list), `INTERNAL_LISTENER_ARN`, `JWT_ISSUER`, optional `ENABLE_CUSTOM_DOMAIN`, `DOMAIN_NAME` |
| `production` | **Required reviewers: you**; deployment branch: `main` only | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (write), `PLAN_ENCRYPTION_KEY` (same value) | none |

The AWS keys are stored secrets because the free plan blocks the OIDC provider. Use dedicated IAM users with scoped policies, not `likhith-admin`, and rotate them.

## Cost (all near $0 at test volumes)

| Item | Price | Free tier |
|---|---|---|
| HTTP API | $1.00 / million requests | 1M requests/month free (12 months) |
| Lambda authorizer | per invocation + ms; cached for 300 s | 1M requests/month free |
| VPC Link (HTTP API) | no hourly charge | n/a |
| CloudWatch Logs | $0.50/GB ingested, 7-day retention | 5 GB free |

The internal load balancer it targets is the one fixed cost (~$0.02/hr). It belongs to the cluster session, not this stack.

## Test (no AWS, nothing created)

```bash
make -C ../authorizer zip
terraform init -backend=false && terraform validate
terraform test     # 6 tests with a mocked AWS provider, using ../../routes-repo/routes.yaml
```

## Notes

- **The JWT secret ends up in state and in Lambda environment config.** The state bucket is encrypted and private. For anything real, store it in Secrets Manager and have the Lambda read it at startup.
- **Module upgrades are deliberate:** bump `?ref=v0.1.0` and run `terraform init -upgrade`.
