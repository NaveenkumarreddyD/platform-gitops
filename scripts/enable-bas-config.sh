#!/usr/bin/env bash
set -euo pipefail
# Enable BAS/DRO Suite config only after DRO runtime values exist in Vault.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

ASSUME_YES=0
ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help)
      echo "usage: enable-bas-config.sh [--yes] <path/to/cluster.env>"
      exit 0
      ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: enable-bas-config.sh [--yes] <path/to/cluster.env>}"
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

echo ">> verifying DRO values exist in Vault before enabling BAS"
for k in url api_token ca.crt; do
  [[ -n "$(field "$IP/dro" "$k")" ]] || { echo "ERROR: missing $KV/$IP/dro#$k. Run sync-runtime-registration.sh first."; exit 1; }
done
# ca.crt must be a REAL PEM (the DRO reencrypt route serves the ingress cert, not the kube CA —
# an invalid/empty CA here is what causes BASCfg CERTIFICATE_VERIFY_FAILED). The harvest's served-CA
# fallback should have written the chain that validates the route; gate the enable on a real cert.
field "$IP/dro" ca.crt | grep -q "BEGIN CERTIFICATE" || {
  echo "ERROR: $KV/$IP/dro#ca.crt is not a valid PEM. Re-run the DRO harvest: ./scripts/sync-runtime-registration.sh --dro-only $ENVFILE" >&2; exit 1; }

# Declarative: BASCfg is rendered from the start (no ENABLE_BAS_CONFIG toggle, no flag-flip, no
# mid-deploy commit). This script only CONVERGES it: the harvested DRO registration was verified
# above; now re-render the BASCfg and bounce the bascfg controller until it registers.

BAS_APP="${INSTANCE_ID}-bas-system.${CLUSTER_ID}"
CORE_NS="mas-${INSTANCE_ID}-core"

# Generate + converge the BASCfg. Re-render it with the current Vault DRO values, then
# bounce_until_ready the bascfg controller (same deterministic pattern as slscfg/mongocfg) — the
# controller caches its DRO TLS verify, so a single wait can't recover from a cached failure.
echo ">> generating + converging the BASCfg ($BAS_APP)"
hard_refresh_app ibm-mas-account-root
sync_parent_until_child_exists ibm-mas-account-root "$BAS_APP" 900
hard_refresh_app "$BAS_APP"
sync_app_oc "$BAS_APP" false || true
bounce_until_ready "$CORE_NS" 'entitymgr-bascfg' \
  bascfgs.config.mas.ibm.com "${INSTANCE_ID}-bas-system" "$CORE_NS" 4 300

# BASCfg Ready -> bounce the Suite so BASIntegrationReady picks it up.
SUITE_POD="$(oc get pod -n "$CORE_NS" --no-headers 2>/dev/null | awk '/entitymgr-suite/ {print $1; exit}')"
if [[ -n "$SUITE_POD" ]]; then
  echo ">> deleting pod/$SUITE_POD so the Suite re-reads the now-Ready BASCfg (BASIntegrationReady)"
  oc delete pod "$SUITE_POD" -n "$CORE_NS" --ignore-not-found
fi
echo ">> BAS config enabled and BASCfg Ready."
