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

if oc get application hashicorp-vault-server -n "$ARGO_NS" >/dev/null 2>&1; then
  echo ">> syncing durable Vault Application"
  hard_refresh_app hashicorp-vault-server
  sync_app_oc hashicorp-vault-server false
else
  echo "ERROR: hashicorp-vault-server Application was not generated." >&2
  echo "       Check gitops/envs/$CLUSTER_ID_ARG values and enable.vault." >&2
  exit 1
fi

echo ">> waiting for Vault pods"
oc rollout status statefulset/vault -n vault --timeout=600s

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
