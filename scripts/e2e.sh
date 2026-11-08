#!/usr/bin/env bash
# End-to-end check of the public API: API Gateway -> Lambda authorizer -> VPC Link -> NLB -> Envoy -> orders.
#
# Usage:  scripts/e2e.sh <api-url>          e.g. scripts/e2e.sh "$(terraform -chdir=edge output -raw invoke_url)"
# Env:    JWT_SECRET   HS256 secret (default: contents of ~/.gateway-jwt-secret, written by ci/setup-ci.sh)
#         JWT_ISSUER   must match the Lambda's JWT_ISSUER (default: https://auth.gateway.local)
# Prints PASS/FAIL per check; exits 1 if any check fails. Tokens and the secret are never printed.
set -uo pipefail   # no -e: a failing check must not stop the remaining checks

[[ $# -eq 1 ]] || { echo "usage: $0 <api-url>" >&2; exit 2; }
API="${1%/}"   # strip trailing slash

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAKE_TOKEN="$REPO_ROOT/authorizer/make_token.py"
PYTHON="$(python3 -c 'print("python3")' 2>/dev/null || echo python)"
JWT_ISSUER="${JWT_ISSUER:-https://auth.gateway.local}"
if [[ -z "${JWT_SECRET:-}" ]]; then
  [[ -s "$HOME/.gateway-jwt-secret" ]] || { echo "ABORT: set JWT_SECRET or create ~/.gateway-jwt-secret" >&2; exit 2; }
  JWT_SECRET="$(cat "$HOME/.gateway-jwt-secret")"
fi
export JWT_SECRET JWT_ISSUER   # passed to make_token.py via env, never on the command line (visible in ps)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s  (%s)\n' "$1" "$2"; FAILS=$((FAILS + 1)); }

# call METHOD PATH [TOKEN] [JSON_BODY] -> sets $CODE and writes the body to $WORK/body
call() {
  local method="$1" path="$2" token="${3:-}" data="${4:-}"
  local args=(-s -o "$WORK/body" -w '%{http_code}' --max-time 15 -X "$method")
  [[ -n "$token" ]] && args+=(-H "Authorization: Bearer $token")
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" --data "$data")
  : > "$WORK/body"   # always exists, even when the connection fails
  CODE="$(curl "${args[@]}" "$API$path" 2>/dev/null)" || CODE="000"
}
json() { "$PYTHON" -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "$WORK/body" 2>/dev/null; }

echo "Target: $API"
VALID="$("$PYTHON" "$MAKE_TOKEN" --ttl 300)"     || { echo "ABORT: could not mint a token" >&2; exit 2; }
EXPIRED="$("$PYTHON" "$MAKE_TOKEN" --ttl -3600)" || { echo "ABORT: could not mint a token" >&2; exit 2; }
echo "Minted a valid and an expired token (not shown)."
echo

# 1. No token: API Gateway rejects before the authorizer runs (401); 403 is also a denial.
call GET /orders
if [[ "$CODE" == "401" || "$CODE" == "403" ]]; then pass "no token is denied (HTTP $CODE)"
else fail "no token is denied" "got HTTP $CODE, want 401/403"; fi

# 2. Expired token: the authorizer returns isAuthorized=false -> 403.
call GET /orders "$EXPIRED"
if [[ "$CODE" == "401" || "$CODE" == "403" ]]; then pass "expired token is denied (HTTP $CODE)"
else fail "expired token is denied" "got HTTP $CODE, want 401/403"; fi

# 3. Valid token: POST /orders creates an order.
ITEM="e2e-$(date +%s)-$RANDOM"
call POST /orders "$VALID" "{\"item\":\"$ITEM\",\"quantity\":2}"
ORDER_ID="$(json "d['id']")"
if [[ "$CODE" == "201" && "$ORDER_ID" =~ ^[0-9]+$ ]]; then
  pass "valid token: POST /orders (HTTP 201, id=$ORDER_ID)"
else
  fail "valid token: POST /orders" "got HTTP $CODE, body: $(head -c 200 "$WORK/body")"
fi

REPLICA_HINT="orders keeps data in memory per pod; with 2 replicas a read can hit the other pod. For e2e: kubectl -n orders scale deploy/orders --replicas=1"

# 4. Valid token: GET /orders lists orders, including the one just created.
call GET /orders "$VALID"
if [[ "$CODE" == "200" ]] && [[ "$(json "any(o.get('item')=='$ITEM' for o in d)")" == "True" ]]; then
  pass "valid token: GET /orders (HTTP 200, new order listed)"
elif [[ "$CODE" == "200" ]]; then
  fail "valid token: GET /orders" "HTTP 200 but new order missing; $REPLICA_HINT"
else
  fail "valid token: GET /orders" "got HTTP $CODE"
fi

# 5. Valid token: GET /orders/{id} returns that order (exercises the {id} route + HTTPRoute regex).
if [[ -n "$ORDER_ID" ]]; then
  call GET "/orders/$ORDER_ID" "$VALID"
  if [[ "$CODE" == "200" && "$(json "d.get('item')")" == "$ITEM" ]]; then
    pass "valid token: GET /orders/$ORDER_ID (HTTP 200, same order)"
  elif [[ "$CODE" == "404" ]]; then
    fail "valid token: GET /orders/{id}" "HTTP 404 from the app; $REPLICA_HINT"
  else
    fail "valid token: GET /orders/{id}" "got HTTP $CODE"
  fi
else
  fail "valid token: GET /orders/{id}" "skipped: POST did not return an id"
fi

# 6. Unknown path (no route in routes.yaml): API Gateway answers 404, even with a valid token.
call GET "/does-not-exist-$RANDOM" "$VALID"
if [[ "$CODE" == "404" ]]; then pass "unknown path returns 404"
else fail "unknown path returns 404" "got HTTP $CODE"; fi

echo
if [[ "$FAILS" -eq 0 ]]; then echo "ALL CHECKS PASSED"; exit 0; fi
echo "$FAILS CHECK(S) FAILED"; exit 1
