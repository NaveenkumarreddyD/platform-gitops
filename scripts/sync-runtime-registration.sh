#!/usr/bin/env bash
set -euo pipefail
# Run after ibm-mas-account-root has created the dedicated SLS LicenseService.
# This syncs the SLS/DRO registration job Application and hard-refreshes consumers.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"
ENVFILE="${1:?usage: sync-runtime-registration.sh <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
SLS_NS="${SLS_NS:-mas-${INSTANCE_ID}-sls}"

echo ">> waiting for LicenseService in $SLS_NS to initialize..."
i=0
until oc get licenseservice -n "$SLS_NS" -o jsonpath='{.items[0].status.initialized}' 2>/dev/null | grep -qi true; do
  (( i += 15 ))
  [[ "$i" -ge 1800 ]] && { echo "ERROR: timeout waiting for SLS initialized"; oc get licenseservice -n "$SLS_NS" 2>/dev/null || true; exit 1; }
  sleep 15
done

sync_app_oc "vault-registration-sync-${INSTANCE_ID}" true
wait_app_synced_healthy "vault-registration-sync-${INSTANCE_ID}" 1200

hard_refresh_app "${INSTANCE_ID}-sls-system.${CLUSTER_ID}"
hard_refresh_app "${INSTANCE_ID}-bas-system.${CLUSTER_ID}"
echo ">> runtime registration sync requested."
