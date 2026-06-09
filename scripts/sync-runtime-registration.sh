#!/usr/bin/env bash
set -euo pipefail
# Run after ibm-mas-account-root has created the dedicated SLS and DRO runtime services.
# This syncs the SLS/DRO registration job Application and hard-refreshes consumers.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"
ENVFILE="${1:?usage: sync-runtime-registration.sh <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
SLS_NS="${SLS_NS:-mas-${INSTANCE_ID}-sls}"
DRO_NS="${DRO_NAMESPACE:-ibm-software-central}"
DRO_SYNC_REQUIRED="${DRO_SYNC_REQUIRED:-true}"

echo ">> waiting for LicenseService in $SLS_NS to initialize..."
i=0
until {
  initialized="$(oc get licenseservice -n "$SLS_NS" -o jsonpath='{.items[0].status.initialized}' 2>/dev/null || true)"
  registration_key="$(oc get licenseservice -n "$SLS_NS" -o jsonpath='{.items[0].status.registrationKey}' 2>/dev/null || true)"
  [[ "$initialized" =~ ^([Tt]rue|[Ii]nitialized|[Rr]eady)$ || -n "$registration_key" ]]
}; do
  (( i += 15 ))
  [[ "$i" -ge 1800 ]] && { echo "ERROR: timeout waiting for SLS initialized"; oc get licenseservice -n "$SLS_NS" 2>/dev/null || true; exit 1; }
  sleep 15
done

if [[ "$DRO_SYNC_REQUIRED" =~ ^(1|true|yes)$ ]]; then
  echo ">> waiting for DRO runtime material in $DRO_NS..."
  i=0
  until oc get route -n "$DRO_NS" 2>/dev/null | grep -qiE 'data-reporter|dro'; do
    (( i += 15 ))
    [[ "$i" -ge 1800 ]] && { echo "ERROR: timeout waiting for DRO route in $DRO_NS"; oc get route -n "$DRO_NS" 2>/dev/null || true; exit 1; }
    sleep 15
  done
  i=0
  until oc get secret -n "$DRO_NS" -o name 2>/dev/null | grep -qiE 'data-reporter|dro'; do
    (( i += 15 ))
    [[ "$i" -ge 1800 ]] && { echo "ERROR: timeout waiting for DRO secret in $DRO_NS"; oc get secret -n "$DRO_NS" 2>/dev/null || true; exit 1; }
    sleep 15
  done
fi

sync_app_oc "vault-registration-sync-${INSTANCE_ID}" true
wait_app_synced_healthy "vault-registration-sync-${INSTANCE_ID}" 1200

hard_refresh_app "${INSTANCE_ID}-sls-system.${CLUSTER_ID}"
hard_refresh_app "${INSTANCE_ID}-bas-system.${CLUSTER_ID}"
echo ">> runtime registration sync requested."
