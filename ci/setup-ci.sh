#!/usr/bin/env bash
# One-time CI setup for gateway-infra's apply-routes workflow.
#
#   ci/setup-ci.sh            IAM users + GitHub environments "plan" / "production" + secrets + variables
#   ci/setup-ci.sh network    after the platform stack is applied: set VPC_ID, VPC_LINK_SUBNET_IDS, INTERNAL_LISTENER_ARN
#
# Needs: gh (logged in as the repo owner), aws CLI (admin creds for account 923832452634), python.
# Secrets are piped straight from AWS / the generator into `gh secret set`; nothing secret is printed.
set -euo pipefail

REPO="likhith5697/gateway-infra"
ACCOUNT="923832452634"
PLAN_USER="gateway-ci-plan"
APPLY_USER="gateway-ci-apply"
JWT_ISSUER_DEFAULT="https://auth.gateway.local"
HERE="$(cd "$(dirname "$0")" && pwd)"
# The Windows aws.exe can't read Git Bash paths (/c/...); give it C:/... there. No-op on Linux/macOS.
POLICY_DIR="$(cygpath -m "$HERE/iam" 2>/dev/null || echo "$HERE/iam")"
LOCAL_JWT_FILE="${HOME}/.gateway-jwt-secret"   # outside any repo; so you can mint test tokens with make_token.py

GH="$(command -v gh || true)"
[[ -n "$GH" ]] || GH="/c/Program Files/GitHub CLI/gh.exe"
gh_() { "$GH" "$@"; }

# --- preflight ---------------------------------------------------------------------------------
gh_ auth status >/dev/null 2>&1 || { echo "ABORT: gh is not logged in. Run: gh auth login" >&2; exit 1; }
acct="$(aws sts get-caller-identity --query Account --output text)"
[[ "$acct" == "$ACCOUNT" ]] || { echo "ABORT: AWS credentials are for $acct, expected $ACCOUNT" >&2; exit 1; }
gh_ repo view "$REPO" --json name >/dev/null

# --- 'network' subcommand: wire edge inputs from platform outputs ----------------------------------
if [[ "${1:-}" == "network" ]]; then
  out="$(terraform -chdir="$HERE/../platform" output -json)"
  get() { python -c "import json,sys; v=json.load(sys.stdin)['$1']['value']; print(json.dumps(v) if isinstance(v,list) else v, end='')" <<<"$out"; }
  gh_ variable set VPC_ID                --env plan -R "$REPO" --body "$(get vpc_id)"
  gh_ variable set VPC_LINK_SUBNET_IDS   --env plan -R "$REPO" --body "$(get vpc_link_subnet_ids)"
  gh_ variable set INTERNAL_LISTENER_ARN --env plan -R "$REPO" --body "$(get internal_listener_arn)"
  echo "Set VPC_ID, VPC_LINK_SUBNET_IDS, INTERNAL_LISTENER_ARN on environment 'plan'."
  exit 0
fi

# --- 1. IAM users (dedicated, least privilege; NOT your admin user) ---------------------------------
ensure_user() {
  aws iam get-user --user-name "$1" >/dev/null 2>&1 || \
    aws iam create-user --user-name "$1" --tags Key=Project,Value=gateway Key=Purpose,Value=github-actions >/dev/null
  echo "IAM user $1: ok"
}
ensure_user "$PLAN_USER"
aws iam attach-user-policy --user-name "$PLAN_USER" --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
aws iam put-user-policy --user-name "$PLAN_USER" --policy-name terraform-state-lock \
  --policy-document "file://$POLICY_DIR/plan-state-lock.json"

ensure_user "$APPLY_USER"
# Customer-managed policy (inline user policies are capped at 2048 bytes; this one is ~3.3 KB).
# Re-runs publish a new default version and prune old ones (IAM keeps at most 5).
APPLY_POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/gateway-ci-apply-edge"
if aws iam get-policy --policy-arn "$APPLY_POLICY_ARN" >/dev/null 2>&1; then
  for v in $(aws iam list-policy-versions --policy-arn "$APPLY_POLICY_ARN" \
               --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$APPLY_POLICY_ARN" --version-id "$v"
  done
  aws iam create-policy-version --policy-arn "$APPLY_POLICY_ARN" --set-as-default \
    --policy-document "file://$POLICY_DIR/apply-edge.json" >/dev/null
else
  aws iam create-policy --policy-name gateway-ci-apply-edge \
    --description "GitHub Actions apply job for gateway-infra/edge" \
    --policy-document "file://$POLICY_DIR/apply-edge.json" >/dev/null
fi
aws iam attach-user-policy --user-name "$APPLY_USER" --policy-arn "$APPLY_POLICY_ARN"
echo "IAM policy gateway-ci-apply-edge: attached to $APPLY_USER"

# --- 2. GitHub environments -------------------------------------------------------------------------
MY_ID="$(gh_ api user --jq .id)"

gh_ api -X PUT "repos/$REPO/environments/plan" --input - >/dev/null <<EOF
{ "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
EOF

# Required reviewer = you. prevent_self_review must be false on a solo repo, or nobody could approve.
gh_ api -X PUT "repos/$REPO/environments/production" --input - >/dev/null <<EOF
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [ { "type": "User", "id": $MY_ID } ],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
EOF

for env in plan production; do
  existing="$(gh_ api "repos/$REPO/environments/$env/deployment-branch-policies" --jq '.branch_policies[].name' || true)"
  grep -qx main <<<"$existing" || \
    gh_ api -X POST "repos/$REPO/environments/$env/deployment-branch-policies" -f name=main -f type=branch >/dev/null
  echo "environment $env: ok (deployments from main only)"
done

# --- 3. AWS keys -> environment secrets (rotated: old keys deleted, new key never printed) -----------
keys_to_env() {
  local user="$1" env="$2" json
  for k in $(aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name "$user" --access-key-id "$k"
  done
  json="$(aws iam create-access-key --user-name "$user" --output json)"
  python -c "import json,sys; print(json.load(sys.stdin)['AccessKey']['AccessKeyId'], end='')" <<<"$json" \
    | gh_ secret set AWS_ACCESS_KEY_ID --env "$env" -R "$REPO"
  python -c "import json,sys; print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'], end='')" <<<"$json" \
    | gh_ secret set AWS_SECRET_ACCESS_KEY --env "$env" -R "$REPO"
  json=""
  echo "environment $env: AWS keys for $user set"
}
keys_to_env "$PLAN_USER" plan
keys_to_env "$APPLY_USER" production

# --- 4. Generated secrets ------------------------------------------------------------------------------
PLAN_KEY="$(python -c 'import secrets; print(secrets.token_urlsafe(48), end="")')"
printf '%s' "$PLAN_KEY" | gh_ secret set PLAN_ENCRYPTION_KEY --env plan -R "$REPO"
printf '%s' "$PLAN_KEY" | gh_ secret set PLAN_ENCRYPTION_KEY --env production -R "$REPO"
PLAN_KEY=""
echo "PLAN_ENCRYPTION_KEY: set (same value in both environments)"

# JWT secret: GitHub secrets are write-only, so keep a local copy for minting test tokens.
if [[ ! -s "$LOCAL_JWT_FILE" ]]; then
  ( umask 077; python -c 'import secrets; print(secrets.token_urlsafe(48), end="")' > "$LOCAL_JWT_FILE" )
fi
# On Windows, umask doesn't restrict access; set an ACL so only the current user can read it.
if command -v icacls.exe >/dev/null 2>&1; then
  MSYS2_ARG_CONV_EXCL='*' icacls.exe "$(cygpath -w "$LOCAL_JWT_FILE")" /inheritance:r /grant:r "${USERNAME}:(R,W)" >/dev/null
fi
gh_ secret set JWT_SECRET --env plan -R "$REPO" < "$LOCAL_JWT_FILE"
echo "JWT_SECRET: set (local copy: $LOCAL_JWT_FILE, readable only by you)"

# --- 5. Variables -----------------------------------------------------------------------------------------
gh_ variable set JWT_ISSUER           --env plan -R "$REPO" --body "${JWT_ISSUER:-$JWT_ISSUER_DEFAULT}"
gh_ variable set ENABLE_CUSTOM_DOMAIN --env plan -R "$REPO" --body "false"
echo "Variables JWT_ISSUER, ENABLE_CUSTOM_DOMAIN: set"
echo
echo "Done. Still TODO after the paid session's platform apply:  ci/setup-ci.sh network"
