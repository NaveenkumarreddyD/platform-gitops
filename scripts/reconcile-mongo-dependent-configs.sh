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
# Bounce-and-wait WITH RETRY: the mongocfg controller caches its TLS verify, and a single bounce
# can race the re-rendered CR (bounce before the corrected CA lands -> still fails). Retry until Ready.
# GUARD: only bounce/wait if the MongoCfg CR actually exists. The CA harvest above can legitimately
# run EARLY (right after the dedicated Mongo is up, e.g. mas-prep) — before the instance cascade has
# generated the MAS MongoCfg. Without this guard, bounce_until_ready idles ~16min on a missing CR.
if oc get mongocfgs.config.mas.ibm.com "${INSTANCE_ID}-mongo-system" -n "$CORE_NS" >/dev/null 2>&1; then
  bounce_until_ready "$CORE_NS" 'entitymgr-mongocfg' \
    mongocfgs.config.mas.ibm.com "${INSTANCE_ID}-mongo-system" "$CORE_NS" 4 240
else
  echo ">> MongoCfg ${INSTANCE_ID}-mongo-system not present yet (instance cascade has not generated it)."
  echo ">> The Mongo CA is now in Vault; the MongoCfg will pick it up when the instance is deployed."
  echo ">> Re-run this reconcile after the MAS instance/core operators exist to bounce + verify it."
fi

# Drive the wave-100 SLS LicenseService to Ready. sync-mongo-ca above already wrote the live Mongo CA
# to Vault and re-synced the sls app. The SLS controller caches its Mongo TLS verify on first connect
# (before the CA was mounted), so it parks at Failure=True (Argo: Degraded) and a single bounce can
# race the re-render. Bounce-retry until Ready — the same deterministic pattern as mongocfg/slscfg.
# GUARD: skip if the LicenseService CR doesn't exist yet (the wave-100 sls app may not be generated
# when this runs early, e.g. mas-prep). Do NOT wait for the sls app to be "healthy" before bouncing —
# it is Degraded precisely BECAUSE the bounce hasn't happened yet, so that wait would deadlock.
if oc get licenseservices.sls.ibm.com -n "$SLS_NS" >/dev/null 2>&1; then
  echo ">> driving the SLS LicenseService to Ready (bounce-retry; controller caches its Mongo TLS verify)"
  sls_ready=0
  for attempt in 1 2 3 4 5; do
    delete_first_pod_matching "$SLS_NS" 'ibm-sls-controller-manager'
    if wait_license_service_ready 360; then sls_ready=1; break; fi
    echo ">> SLS LicenseService not Ready after bounce $attempt/5; retrying"
  done
  [[ "$sls_ready" == 1 ]] || { echo "ERROR: SLS LicenseService never reached Ready after 5 bounces" >&2; exit 1; }
else
  echo ">> SLS LicenseService not present yet (wave-100 sls app not generated); skipping the bounce."
  echo ">> mas-install step 6b waits for the CR, then re-runs this reconcile to drive it Ready."
fi

echo ">> refreshing Suite after Mongo/SLS dependencies"
hard_refresh_app "suite.${CLUSTER_ID}.${INSTANCE_ID}"
delete_first_pod_matching "$CORE_NS" 'entitymgr-suite'
if oc get slscfgs.config.mas.ibm.com "${INSTANCE_ID}-sls-system" -n "$CORE_NS" >/dev/null 2>&1; then
  delete_first_pod_matching "$CORE_NS" 'entitymgr-slscfg'
fi

# A green mongocfg only proves the MongoCfg controller is happy; the SUITE verifies
# Mongo separately (SystemDatabaseReady). That check used to be skipped here, so a stale
# CA surfaced much later as the opaque Suite error "MongoDB configuration was unable to be
# verified". Confirm it now, with one extra entitymgr-suite bounce, before declaring success.
if [[ "${SKIP_SUITE_SYSTEMDB_WAIT:-false}" == "true" ]]; then
  echo ">> SKIP_SUITE_SYSTEMDB_WAIT=true: mongocfg is Ready and the live Mongo CA is in Vault."
  echo ">> (Suite SystemDatabaseReady is verified LATER, after SLSCfg is enabled — the Suite cannot"
  echo ">>  reach SystemDatabaseReady until SLS is configured, because catalogmgr needs the SLS"
  echo ">>  secret to start, and the Suite waits on its core components. Verifying here would deadlock.)"
elif oc get suite "$INSTANCE_ID" -n "$CORE_NS" >/dev/null 2>&1; then
  echo ">> verifying Suite can actually read MongoDB (SystemDatabaseReady); bouncing entitymgr-suite as needed"
  # The Suite runs its OWN Mongo verify and caches the result, so after the MongoCfg CA is fixed it
  # needs a bounce to re-verify. Bounce -> wait (tolerating the 'ApplyingConfiguration' transitional
  # state, which wait_suite_condition treats as not-yet-True) -> retry. Each wait is generous because a
  # bounce restarts the Suite's full reconcile (~210 tasks). This removes the manual-bounce step.
  sysdb_ready=0
  for attempt in 1 2 3; do
    delete_first_pod_matching "$CORE_NS" 'entitymgr-suite'
    if wait_suite_condition "$INSTANCE_ID" "$CORE_NS" SystemDatabaseReady 900; then sysdb_ready=1; break; fi
    echo ">> SystemDatabaseReady still not True after bounce attempt $attempt/3; retrying"
  done
  if [[ "$sysdb_ready" != 1 ]]; then
    echo "ERROR: Suite cannot verify MongoDB (SystemDatabaseReady not True). Two common causes:" >&2
    echo "  1. Stale Mongo CA: live Mongo cert disagrees with" >&2
    echo "     ${KV_MOUNT:-secret}/${ACCOUNT_ID:-<account>}/$CLUSTER_ID/$INSTANCE_ID/mongo#ca.crt (recreated Mongo?)." >&2
    echo "  2. The Suite reconcile aborted UPSTREAM (e.g. missing public cert -> 'Get Public Route" >&2
    echo "     certificates' NoneType failure), so mas-mongo-config/mas-mongo-credentials were never" >&2
    echo "     created. In that case this is a symptom: read the operator log above and fix the" >&2
    echo "     upstream failure first (often: ./scripts/load-mas-public-cert.sh <env> <cert.pfx>)." >&2
    exit 1
  fi
fi

echo ">> Mongo-dependent MAS config reconciliation completed."
