#!/usr/bin/env bash
set -euo pipefail
# One-time durable Vault platform setup.
#
# Use this for first cluster bootstrap or Vault repair. Normal MAS re-installs should NOT
# delete/recreate Vault; they should reuse the existing Vault data, auth roles, and secrets.
#
# Usage:
#   ./scripts/setup-vault-platform.sh [--store-k8s-secret] <cluster>
#
# Example:
#   ./scripts/setup-vault-platform.sh --store-k8s-secret drroc4

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

STORE_ARGS=()
CLUSTER_ID_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --store-k8s-secret) STORE_ARGS+=(--store-k8s-secret); shift ;;
    -h|--help)
      echo "usage: setup-vault-platform.sh [--store-k8s-secret] <cluster>"
      exit 0
      ;;
    *) CLUSTER_ID_ARG="$1"; shift ;;
  esac
done
CLUSTER_ID_ARG="${CLUSTER_ID_ARG:?usage: setup-vault-platform.sh [--store-k8s-secret] <cluster>}"

echo ">> applying platform bootstrap for $CLUSTER_ID_ARG"
"$ROOT/bootstrap/apply.sh" "$CLUSTER_ID_ARG"

# The root app generates child Applications asynchronously, so the Vault app is NOT
# present the instant apply.sh returns. Wait for ArgoCD to generate it (refreshing the
# root app as needed) instead of erroring on a race.
ROOT_APP="platform-${CLUSTER_ID_ARG}"
echo ">> waiting for ArgoCD to generate hashicorp-vault-server from $ROOT_APP"
if ! sync_parent_until_child_exists "$ROOT_APP" hashicorp-vault-server 600; then
  echo "ERROR: hashicorp-vault-server Application was not generated within timeout." >&2
  echo "       Check gitops/envs/$CLUSTER_ID_ARG values (enable.vault) and the health of" >&2
  echo "       application/$ROOT_APP:  oc get application $ROOT_APP -n $ARGO_NS" >&2
  exit 1
fi
echo ">> syncing durable Vault Application"
hard_refresh_app hashicorp-vault-server
sync_app_oc hashicorp-vault-server false

echo ">> waiting for Vault pods"
# Vault's StatefulSet uses the OnDelete update strategy, so `oc rollout status` does not apply.
# Also a freshly-deployed Vault is sealed/uninitialized (so pods may be 0/1 Ready) — we only
# need vault-0 to be Running so init-vault can exec into it. Wait on pod phase, not readiness.
vault_wait=0
until [[ "$(oc get pod vault-0 -n vault -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]]; do
  (( vault_wait += 10 ))
  if [[ "$vault_wait" -ge 600 ]]; then
    echo "ERROR: vault-0 not Running after 600s" >&2
    oc get pod -n vault 2>/dev/null || true
    exit 1
  fi
  echo ">> waiting for vault-0 to be Running (${vault_wait}s)"
  sleep 10
done
echo ">> vault-0 is Running"

echo ">> initialize/unseal only if Vault is not initialized"
bash "$ROOT/scripts/init-vault.sh" "${STORE_ARGS[@]}"

cat <<MSG

Vault platform setup checked.

If Vault was newly initialized, export the root/admin token printed above and run:
  ./scripts/setup-vault-auth.sh

For normal MAS reinstall/recreate, do not rerun this as a reset and do not delete Vault PVCs.
Run:
  ./scripts/install-ibm-way.sh --yes ../mas-gitops-config/envs/${CLUSTER_ID_ARG}.env
MSG
