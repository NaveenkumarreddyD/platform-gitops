#!/usr/bin/env bash
set -euo pipefail
# Run after ibm-mas-account-root has created the dedicated SLS and optionally DRO runtime services.
# SLS and DRO are intentionally separate so SLSCfg can be enabled without waiting for DRO/BAS.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

MODE="all"; ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sls-only|--sls) MODE="sls"; shift ;;
    --dro-only|--dro) MODE="dro"; shift ;;
    -h|--help)
      echo "usage: sync-runtime-registration.sh [--sls-only|--dro-only] <path/to/cluster.env>"
      exit 0
      ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: sync-runtime-registration.sh [--sls-only|--dro-only] <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
SLS_NS="${SLS_NS:-mas-${INSTANCE_ID}-sls}"
DRO_NS="${DRO_NAMESPACE:-ibm-software-central}"

sync_sls() {
  echo ">> waiting for LicenseService in $SLS_NS to initialize..."
  wait_crd licenseservices.sls.ibm.com 1800
  i=0
  until {
    initialized="$(oc get licenseservices.sls.ibm.com -n "$SLS_NS" -o jsonpath='{.items[0].status.initialized}' 2>/dev/null || true)"
    registration_key="$(oc get licenseservices.sls.ibm.com -n "$SLS_NS" -o jsonpath='{.items[0].status.registrationKey}' 2>/dev/null || true)"
    [[ "$initialized" =~ ^([Tt]rue|[Ii]nitialized|[Rr]eady)$ || -n "$registration_key" ]]
  }; do
    (( i += 15 ))
    [[ "$i" -ge 1800 ]] && { echo "ERROR: timeout waiting for SLS initialized"; oc get licenseservices.sls.ibm.com -n "$SLS_NS" 2>/dev/null || true; exit 1; }
    sleep 15
  done

  echo ">> waiting for sls-suite-registration ConfigMap in $SLS_NS"
  i=0
  until {
    cm_registration_key="$(oc get cm sls-suite-registration -n "$SLS_NS" -o jsonpath='{.data.registrationKey}' 2>/dev/null || true)"
    cm_url="$(oc get cm sls-suite-registration -n "$SLS_NS" -o jsonpath='{.data.url}' 2>/dev/null || true)"
    cm_ca="$(oc get cm sls-suite-registration -n "$SLS_NS" -o jsonpath='{.data.ca}' 2>/dev/null || true)"
    [[ -n "$cm_registration_key" && -n "$cm_url" && "$cm_ca" == *"BEGIN CERTIFICATE"* ]]
  }; do
    (( i += 15 ))
    [[ "$i" -ge 1800 ]] && {
      echo "ERROR: timeout waiting for sls-suite-registration with registrationKey, url, and ca in $SLS_NS"
      oc get licenseservices.sls.ibm.com -n "$SLS_NS" -o yaml 2>/dev/null | \
        grep -iA8 -B2 'MongoDB\|registration\|initialized\|conditions:\|message:\|reason:\|status:\|type:' || true
      oc get cm sls-suite-registration -n "$SLS_NS" -o yaml 2>/dev/null || true
      exit 1
    }
    sleep 15
  done

  sync_app_oc "vault-sync-sls-${INSTANCE_ID}" true
  wait_app_synced_healthy "vault-sync-sls-${INSTANCE_ID}" 1200

  hard_refresh_app "suite.${CLUSTER_ID}.${INSTANCE_ID}"
  echo ">> SLS registration sync completed."
}

sync_dro() {
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

  sync_app_oc "vault-sync-dro-${INSTANCE_ID}" true
  wait_app_synced_healthy "vault-sync-dro-${INSTANCE_ID}" 1200

  hard_refresh_app "${INSTANCE_ID}-bas-system.${CLUSTER_ID}"
  echo ">> DRO registration sync completed."
}

case "$MODE" in
  sls) sync_sls ;;
  dro) sync_dro ;;
  all)
    sync_sls
    if oc get application "vault-sync-dro-${INSTANCE_ID}" -n "$ARGO_NS" >/dev/null 2>&1; then
      sync_dro
    else
      echo ">> vault-sync-dro-${INSTANCE_ID} is not present; skipping DRO registration."
      echo ">> Enable DRO later, then run: $0 --dro-only $ENVFILE"
    fi
    ;;
esac
