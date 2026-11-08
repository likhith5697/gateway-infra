#!/usr/bin/env bash
# Render routes.yaml into Gateway API HTTPRoutes and apply them to the EKS cluster.
#
# Usage:  scripts/apply-httproutes.sh [--dry-run] <path/to/routes.yaml>
#   --dry-run   render + print + server-side dry run (the API server validates, nothing is saved)
# Env:    PLATFORM_TEMPLATES   checkout of platform-templates (default: ../platform-templates next to this repo)
#         CLUSTER_NAME         EKS cluster kubectl must point at (default: gateway)
set -euo pipefail

usage() { echo "usage: $0 [--dry-run] <routes.yaml>" >&2; exit 2; }

# --- 1. Parse arguments ---------------------------------------------------------------------------
DRY_RUN=0
ROUTES_FILE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage ;;
    -*) echo "unknown flag: $arg" >&2; usage ;;
    *) [[ -z "$ROUTES_FILE" ]] || usage; ROUTES_FILE="$arg" ;;
  esac
done
[[ -n "$ROUTES_FILE" ]] || usage
[[ -f "$ROUTES_FILE" ]] || { echo "ABORT: routes file not found: $ROUTES_FILE" >&2; exit 1; }

# --- 2. Find the renderer ----------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM_TEMPLATES="${PLATFORM_TEMPLATES:-$REPO_ROOT/../platform-templates}"
RENDERER="$PLATFORM_TEMPLATES/render_httproutes.py"
[[ -f "$RENDERER" ]] || { echo "ABORT: $RENDERER not found (set PLATFORM_TEMPLATES)" >&2; exit 1; }
PYTHON="$(python3 -c 'print("python3")' 2>/dev/null || echo python)"   # Windows: python3 may be a Store stub
CLUSTER_NAME="${CLUSTER_NAME:-gateway}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 3. Render (the renderer validates first and refuses invalid input) -------------------------------
"$PYTHON" "$RENDERER" "$ROUTES_FILE" -o "$WORK/rendered.yaml"

# --- 4. Add the ownership label to every HTTPRoute -------------------------------------------------------
"$PYTHON" - "$WORK/rendered.yaml" "$WORK/labeled.yaml" <<'EOF'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
for d in docs:
    d.setdefault("metadata", {}).setdefault("labels", {})["managed-by"] = "routes-repo"
with open(sys.argv[2], "w", encoding="utf-8") as f:
    yaml.safe_dump_all(docs, f, sort_keys=False, explicit_start=True, default_flow_style=False)
print(f"{len(docs)} HTTPRoute(s) rendered and labeled managed-by=routes-repo", file=sys.stderr)
EOF

# --- 5. Show exactly what will be sent ----------------------------------------------------------------
echo "----- rendered HTTPRoutes ($ROUTES_FILE) -----"
cat "$WORK/labeled.yaml"
echo "----------------------------------------------"

# --- 6. Safety gate: only the EKS cluster -------------------------------------------------------------
CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
echo "kubectl current-context: ${CONTEXT:-<none>}"
# EKS contexts look like arn:aws:eks:<region>:<account>:cluster/<name>; require that exact suffix,
# so "gateway-prod", "my-gateway" or an AKS context can never pass.
if [[ "$CONTEXT" != *":cluster/${CLUSTER_NAME}" ]]; then
  echo "ABORT: current context does not contain EKS cluster '${CLUSTER_NAME}' (expected ...:cluster/${CLUSTER_NAME})." >&2
  echo "       Run: aws eks update-kubeconfig --region us-east-2 --name ${CLUSTER_NAME}" >&2
  exit 1
fi

# --- 7. Apply (or server-side dry run) ------------------------------------------------------------------
if [[ "$DRY_RUN" == "1" ]]; then
  kubectl apply --dry-run=server -f "$WORK/labeled.yaml"
  echo "DRY RUN: validated by the API server; nothing was changed."
else
  kubectl apply -f "$WORK/labeled.yaml"
  kubectl get httproute -A -l managed-by=routes-repo
fi
