#!/usr/bin/env bash
set -euo pipefail
# Enable the MAS SLSCfg only after the dedicated SLS registration values have
# been harvested into Vault. This avoids AVP ComparisonError on first account-root sync.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

ASSUME_YES=0
ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help)
      echo "usage: enable-sls-config.sh [--yes] <path/to/cluster.env>"
      exit 0
      ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: enable-sls-config.sh [--yes] <path/to/cluster.env>}"
CONFIG_REPO="${CONFIG_REPO:-$(cd "$(dirname "$ENVFILE")/.." && pwd)}"
CLUSTER="$(basename "$ENVFILE" .env)"

# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${ACCOUNT_ID:?}"; : "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
KV="${KV_MOUNT:-secret}"; VAULT_NS="${VAULT_NS:-vault}"; VAULT_POD="${VAULT_POD:-vault-0}"; VADDR="${VADDR:-http://127.0.0.1:8200}"
[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; }
assert_repo_fresh   # refuse to run a stale platform-gitops clone

IP="$ACCOUNT_ID/$CLUSTER_ID/$INSTANCE_ID"
field() {
  oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c \
    "export VAULT_ADDR=$VADDR VAULT_TOKEN='$VAULT_TOKEN'; vault kv get -field='$2' $KV/$1" 2>/dev/null
}

echo ">> verifying SLS registration values exist in Vault before enabling SLSCfg"
REQUIRE_SLS_REGISTRATION=true ./scripts/preflight-vault.sh --phase full "$ENVFILE" >/dev/null
for k in registration_key url ca.crt; do
  [[ -n "$(field "$IP/sls" "$k")" ]] || { echo "ERROR: missing $KV/$IP/sls#$k. Run sync-runtime-registration.sh --sls-only first."; exit 1; }
done
# ca.crt must be a REAL PEM, not empty/garbage — an invalid CA here is exactly what produces
# SLSCfg RegistrationFailed / CERTIFICATE_VERIFY_FAILED. Gate the enable on a valid cert so the
# SLSCfg only ever renders with trustworthy material (official model harvests ca before the config syncs).
field "$IP/sls" ca.crt | grep -q "BEGIN CERTIFICATE" || {
  echo "ERROR: $KV/$IP/sls#ca.crt is not a valid PEM. Re-run the SLS harvest: ./scripts/sync-runtime-registration.sh --sls-only $ENVFILE" >&2; exit 1; }

echo ">> waiting for MAS config CRD slscfgs.config.mas.ibm.com"
wait_crd slscfgs.config.mas.ibm.com 1800

# Declarative: SLSCfg is rendered from the start (no ENABLE_SLS_CONFIG toggle, no flag-flip, no
# mid-deploy commit). This script only CONVERGES it: the harvested registration was verified above;
# now re-render the SLSCfg with the current Vault CA and bounce the slscfg controller until it registers.

SLS_APP="${INSTANCE_ID}-sls-system.${CLUSTER_ID}"

# Generate + sync the SLSCfg app (NOT the suite app). The suite app's sync op blocks on FULL Suite
# health (mongo AND sls), which isn't ready at this stage — waiting on it here is the deadlock.
# enable-sls's only job is to land a Ready SLSCfg; the Suite convergence is verified by the caller.
echo ">> refreshing account-root so the SLSCfg app ($SLS_APP) is generated"
hard_refresh_app ibm-mas-account-root
sync_parent_until_child_exists ibm-mas-account-root "$SLS_APP" 600
sync_app_oc "$SLS_APP" false || true

CORE_NS="mas-${INSTANCE_ID}-core"

# Re-render the SLSCfg with the CURRENT Vault CA, then bounce the slscfg controller until it
# registers. The slscfg controller caches its TLS verify: if it first tried to register before the
# served SLS CA was in Vault, it cached a CERTIFICATE_VERIFY_FAILED and a single wait never recovers
# (you'd have to bounce entitymgr-slscfg by hand). Retry bounce-and-wait (same pattern as mongocfg)
# so SLS converges deterministically. Relies on the SLS registration + served-CA already being
# harvested into Vault (sync-runtime-registration --sls-only, which the caller/mas-install runs first).
echo ">> re-rendering SLSCfg with current Vault CA, then bouncing entitymgr-slscfg until registered"
hard_refresh_app "$SLS_APP"
sync_app_oc "$SLS_APP" false || true
bounce_until_ready "$CORE_NS" 'entitymgr-slscfg' \
  slscfgs.config.mas.ibm.com "${INSTANCE_ID}-sls-system" "$CORE_NS" 4 300

# Now that SLSCfg is Ready, bounce the Suite operator so SLSIntegrationReady picks it up.
SUITE_POD="$(oc get pod -n "$CORE_NS" --no-headers 2>/dev/null | awk '/entitymgr-suite/ {print $1; exit}')"
if [[ -n "$SUITE_POD" ]]; then
  echo ">> deleting pod/$SUITE_POD so the Suite re-reads the now-Ready SLSCfg (SLSIntegrationReady)"
  oc delete pod "$SUITE_POD" -n "$CORE_NS" --ignore-not-found
fi
echo ">> SLS config enabled and SLSCfg Ready."
