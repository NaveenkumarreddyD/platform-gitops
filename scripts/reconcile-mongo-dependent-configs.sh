#!/usr/bin/env bash
set -euo pipefail
# Reconcile MAS resources that consume the dedicated Mongo CA.
# Run after account-root has generated MAS/SLS Applications, and any time Mongo CA
# was rotated/recreated. This avoids stale AVP render/controller-cache failures.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

ENVFILE="${1:?usage: reconcile-mongo-dependent-configs.sh <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
CORE_NS="mas-${INSTANCE_ID}-core"
SLS_NS="${SLS_NS:-mas-${INSTANCE_ID}-sls}"

delete_first_pod_matching() {
  local namespace="${1:?namespace}" pattern="${2:?pattern}" pod=""
  pod="$(oc get pod -n "$namespace" --no-headers 2>/dev/null | awk -v pat="$pattern" '$1 ~ pat {print $1; exit}')"
  if [[ -n "$pod" ]]; then
    echo ">> deleting pod/$pod in $namespace so the controller re-reads rendered config"
    oc delete pod "$pod" -n "$namespace" --ignore-not-found
  else
    echo ">> no pod matching /$pattern/ found in $namespace"
  fi
}

sync_if_exists() {
  local app="${1:?app name}" prune="${2:-false}" wait_mode="${3:-healthy}"
  if oc get application "$app" -n "$ARGO_NS" >/dev/null 2>&1; then
    sync_app_oc "$app" "$prune"
    if [[ "$wait_mode" == "healthy" ]]; then
      wait_app_synced_healthy "$app" 1200
    else
      wait_app_synced_idle "$app" 1200
    fi
  else
    echo ">> application/$app is not present yet; skipping"
  fi
}

wait_license_service_ready() {
  local timeout="${1:-1800}" elapsed=0 status="" initialized="" registration_key=""
  while :; do
    status="$(oc get licenseservices.sls.ibm.com -n "$SLS_NS" -o jsonpath='{.items[0].status.status}' 2>/dev/null || true)"
    initialized="$(oc get licenseservices.sls.ibm.com -n "$SLS_NS" -o jsonpath='{.items[0].status.initialized}' 2>/dev/null || true)"
    registration_key="$(oc get licenseservices.sls.ibm.com -n "$SLS_NS" -o jsonpath='{.items[0].status.registrationKey}' 2>/dev/null || true)"
    if [[ "$status" == "Ready" && ( "$initialized" =~ ^([Tt]rue|[Ii]nitialized|[Rr]eady)$ || -n "$registration_key" ) ]]; then
      echo ">> LicenseService in $SLS_NS is Ready"
      return 0
    fi
    if (( elapsed == 0 || elapsed % 60 == 0 )); then
      echo ">> waiting for LicenseService in $SLS_NS Ready (status=${status:-missing}, initialized=${initialized:-missing}, registrationKey=${registration_key:+present}, elapsed=${elapsed}s)"
      oc get licenseservices.sls.ibm.com -n "$SLS_NS" 2>/dev/null || true
    fi
    (( elapsed += 15 ))
    [[ "$elapsed" -ge "$timeout" ]] && {
      echo "ERROR: timeout waiting for LicenseService in $SLS_NS Ready" >&2
      oc get licenseservices.sls.ibm.com -n "$SLS_NS" -o yaml 2>/dev/null | \
        grep -iA8 -B2 'MongoDB\|registration\|initialized\|conditions:\|message:\|reason:\|status:\|type:' || true
      return 1
    }
    sleep 15
  done
}

echo ">> syncing live Mongo CA into Vault"
./scripts/sync-mongo-ca.sh "$ENVFILE"

echo ">> re-rendering MAS MongoCfg from updated Vault CA"
sync_if_exists "${INSTANCE_ID}-mongo-system.${CLUSTER_ID}" false healthy
delete_first_pod_matching "$CORE_NS" 'entitymgr-mongocfg'
wait_resource_ready mongocfgs.config.mas.ibm.com "${INSTANCE_ID}-mongo-system" "$CORE_NS" 1800

echo ">> re-rendering SLS LicenseService from updated Vault CA"
sync_if_exists "sls.${CLUSTER_ID}.${INSTANCE_ID}" false healthy
delete_first_pod_matching "$SLS_NS" 'ibm-sls-controller-manager'
if oc get licenseservices.sls.ibm.com -n "$SLS_NS" >/dev/null 2>&1; then
  wait_license_service_ready 1800
fi

echo ">> refreshing Suite after Mongo/SLS dependencies"
hard_refresh_app "suite.${CLUSTER_ID}.${INSTANCE_ID}"
if oc get slscfgs.config.mas.ibm.com "${INSTANCE_ID}-sls-system" -n "$CORE_NS" >/dev/null 2>&1; then
  delete_first_pod_matching "$CORE_NS" 'entitymgr-slscfg'
fi

echo ">> Mongo-dependent MAS config reconciliation completed."
