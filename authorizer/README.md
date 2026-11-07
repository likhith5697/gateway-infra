# authorizer: Lambda authorizer for the HTTP API

Python 3.12, standard library only (`make zip`, then deploy `build/authorizer.zip`; no layers). Configure it as a **REQUEST** authorizer with **payload format 2.0** and **simple responses**, identity source `$request.header.Authorization`.

| | |
|---|---|
| Handler | `handler.lambda_handler` |
| Env vars | `JWT_SECRET` (HS256 key), `JWT_ISSUER` (required `iss` value) |
| Returns | `{"isAuthorized": true}` or `{"isAuthorized": false}` |

## What it checks (in order)

1. **Header:** the event has exactly one `Authorization` header, of the form `Bearer <JWT>` (scheme is case-insensitive, single space).
2. **Format:** the token is at most 8 KB, has exactly 3 non-empty base64url segments, and its header is a JSON object with no duplicate keys.
3. **Algorithm:** `alg` is exactly `HS256`. `none`, `None`, `HS512`, `RS256` and a missing alg are all rejected. Tokens with a `crit` header are rejected.
4. **Signature:** an HMAC-SHA256 signature, compared in constant time, is checked **before** any claim is read.
5. **Expiry:** `exp` is required, must be numeric, and must not have passed (30 s clock skew allowed). If `nbf` is present, it must already have arrived.
6. **Issuer:** `iss` must exactly equal `JWT_ISSUER`.

**Fails closed:** a missing env var, missing header, malformed token, odd event shape or any exception returns `false`.
**Logging:** only a reason code (`denied reason=expired`) or `authorized sub=<sub>`. The token, header, secret and event are never logged; a test enforces this.

## Build

```bash
make zip      # -> build/authorizer.zip (handler.py only, reproducible)
make test     # 60 unit tests
make clean    # delete build/
```

The zip is **reproducible**: fixed timestamps, fixed file modes, and CRLF normalised to LF. The same `handler.py` always gives the same bytes, on Windows or Linux, so Terraform only redeploys when the code really changes. `zip` isn't needed; `package.py` uses Python's `zipfile`. `build/` is gitignored.

## How Terraform consumes the zip

Terraform only **reads** the file; `make zip` must run first. A stack (for example a future `gateway-infra/gateway/`) would do:

```hcl
locals {
  authorizer_zip = "${path.module}/../authorizer/build/authorizer.zip"
}

resource "aws_lambda_function" "authorizer" {
  function_name = "gateway-authorizer"
  role          = aws_iam_role.authorizer.arn # basic execution role (CloudWatch Logs only)
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"     # file handler.py, function lambda_handler
  architectures = ["arm64"]
  memory_size   = 128
  timeout       = 3

  filename         = local.authorizer_zip                   # Terraform uploads this file
  source_code_hash = filebase64sha256(local.authorizer_zip) # the code changed -> redeploy; unchanged -> no-op

  environment {
    variables = {
      JWT_ISSUER = var.jwt_issuer
      JWT_SECRET = var.jwt_secret # sensitive variable; prefer Secrets Manager for anything real
    }
  }
}

resource "aws_apigatewayv2_authorizer" "lambda" {
  api_id                            = aws_apigatewayv2_api.gateway.id
  name                              = "jwt-hs256"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true # matches {"isAuthorized": bool}
  identity_sources                  = ["$request.header.Authorization"]
  authorizer_result_ttl_in_seconds  = 300
}

resource "aws_lambda_permission" "apigw_invoke_authorizer" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.gateway.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.lambda.id}"
}

# The authorizer ID then goes into the routes module: every auth = "custom" route uses it.
module "routes" {
  source        = "github.com/likhith5697/platform-templates//modules/api-gateway-routes?ref=v0.1.0"
  authorizer_id = aws_apigatewayv2_authorizer.lambda.id
  # api_id, vpc_link_id, listener_arn, routes = yamldecode(...)
}
```

**Flow:** `make zip` → `terraform plan` hashes the zip with `filebase64sha256` → if the hash differs from what's deployed, `apply` uploads the new zip to Lambda; otherwise nothing changes.

**Gotchas:**
- **Run `make zip` before `terraform plan`.** `filebase64sha256()` fails at plan time if the file is missing, e.g. on a fresh clone or in CI. In CI: `make -C authorizer zip && terraform -chdir=gateway plan`.
- **Don't commit the zip.** It's a build artifact, rebuilt from `handler.py`, and because the build is reproducible every machine produces the same hash.
- **Secret in state.** Whatever you pass as `JWT_SECRET` ends up in Terraform state. The state bucket is encrypted and private, but the cleaner option is to store the secret in Secrets Manager and have the Lambda read it at startup.
- **Alternative:** the `hashicorp/archive` provider's `archive_file` data source can zip `handler.py` inside Terraform with no Makefile step. The Makefile keeps packaging testable, and identical across local runs and CI.

## Mint tokens for manual testing

```bash
export JWT_SECRET='<the same secret as the Lambda>' JWT_ISSUER='https://auth.example.local'
python make_token.py                       # valid, 1 hour
python make_token.py --ttl -60             # expired
python make_token.py --iss https://evil    # wrong issuer
python make_token.py --alg none            # unsigned, must be rejected

curl -H "Authorization: Bearer $(python make_token.py)" https://<api-id>.execute-api.us-east-2.amazonaws.com/orders
```

## Notes

- **Secret:** use a random secret of at least 32 bytes (`python -c "import secrets; print(secrets.token_urlsafe(48))"`). In AWS, keep it in Secrets Manager or SSM SecureString rather than a plain env var for anything real.
- **Caching:** API Gateway caches authorizer results per token for the configured TTL. Keep the TTL short (e.g. 300 s) so expired tokens stop working promptly.
- **Scope:** HS256 means anyone who can mint tokens also holds the verification key. For third-party identity providers, use RS256 with JWKS, or API Gateway's built-in JWT authorizer.
