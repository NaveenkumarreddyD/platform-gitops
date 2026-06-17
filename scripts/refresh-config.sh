#!/usr/bin/env bash
set -euo pipefail
# Force ArgoCD to pull the latest Config Repository commit NOW for one cluster/instance,
# instead of waiting for the ~3-minute git poll. Hard-refreshes the account-root and every
# Application belonging to the cluster/instance, so a mid-deployment commit is picked up
# immediately. Read-only w.r.t. your data: it only triggers refreshes (autoSync then applies).
#
# Usage:
#   ./scripts/refresh-config.sh drroc4                                   # by cluster name
#   ./scripts/refresh-config.sh ../mas-gitops-config/envs/drroc4.env     # by env file
#   (or omit the target if CLUSTER_ID/INSTANCE_ID are exported)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

usage(){ sed -n '3,13p' "$0"; }
ENVARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) ENVARG="$1"; shift ;;
  esac
done

# Resolve target from explicit path, bare cluster name, or exported vars (same as delete script).
ENVFILE=""
if [[ -n "$ENVARG" && -f "$ENVARG" ]]; then
  ENVFILE="$ENVARG"
elif [[ -n "$ENVARG" ]]; then
  for d in "$ROOT/.." "$ROOT/../.." "$ROOT/../../.."; do
    for repo in mas-gitops-config mas-config-repo; do
      cand="$d/$repo/envs/${ENVARG}.env"
      [[ -f "$cand" ]] && { ENVFILE="$cand"; break 2; }
    done
  done
  [[ -n "$ENVFILE" ]] || { echo "ERROR: no env file found for '$ENVARG'." >&2; exit 2; }
fi
if [[ -n "$ENVFILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENVFILE"; set +a
fi
: "${CLUSTER_ID:?set CLUSTER_ID or pass a cluster/env}"; : "${INSTANCE_ID:?}"

echo ">> hard-refreshing ibm-mas-account-root + all apps for cluster=$CLUSTER_ID instance=$INSTANCE_ID"
n=0
for app in ibm-mas-account-root $(oc get applications -n "$ARGO_NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E "(${CLUSTER_ID}|${INSTANCE_ID})" || true); do
  oc get application "$app" -n "$ARGO_NS" >/dev/null 2>&1 || continue
  hard_refresh_app "$app"
  echo "   refreshed $app"
  n=$((n+1))
done
echo ">> requested refresh on $n application(s). ArgoCD re-reads git within seconds; autoSync then applies."
