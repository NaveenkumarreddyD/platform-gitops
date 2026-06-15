#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# Drive the platform prerequisites up to the manual MAS account-root gate.
#
# This script is intentionally limited to Vault/Mongo prerequisites:
#   - hard-refreshes the platform and Mongo Applications
#   - syncs Mongo operator / Mongo CR / Mongo CA sync using oc
#   - waits for MongoDBCommunity to become Running
#   - writes Mongo CA into Vault
#   - runs full Vault preflight
#
# It does NOT sync ibm-mas-account-root.
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"
ENVFILE="${1:?usage: prepare-prereqs.sh <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
MONGO_NS="${MONGO_NS:?MONGO_NS must be set in the env file; it MUST equal gitops/envs/<cluster>/values.yaml mongo.namespace}"
MONGO_CR="${MONGO_CR:-${INSTANCE_ID}-mongo}"
[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; }

apps=(
  "platform-${CLUSTER_ID}"
  "mongodb-community-operator-${INSTANCE_ID}"
  "mongodb-ce-${INSTANCE_ID}"
  "vault-sync-mongo-${INSTANCE_ID}"
)

say(){ printf '\n=== %s ===\n' "$*"; }
wait_mongo_running(){
  local timeout="${1:-1800}" i=0 phase=""
  while :; do
    phase="$(oc get mongodbcommunity "$MONGO_CR" -n "$MONGO_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" =~ ^([Rr]unning|Running)$ ]] && { echo ">> MongoDBCommunity $MONGO_NS/$MONGO_CR Running"; return 0; }
    (( i += 15 ))
    [[ "$i" -ge "$timeout" ]] && {
      echo "ERROR: timeout waiting for MongoDBCommunity $MONGO_NS/$MONGO_CR Running (phase=$phase)" >&2
      oc get mongodbcommunity -n "$MONGO_NS" 2>/dev/null || true
      oc get pods -n "$MONGO_NS" 2>/dev/null || true
      return 1
    }
    sleep 15
  done
}

say "1/6 Static Vault preflight"
./scripts/preflight-vault.sh --phase static "$ENVFILE"

say "2/6 Restart repo-server so AVP re-reads Vault/auth config"
oc rollout restart deploy/openshift-gitops-repo-server -n "$ARGO_NS"
oc rollout status deploy/openshift-gitops-repo-server -n "$ARGO_NS" --timeout=180s

say "3/6 Refresh/sync platform and Mongo Applications"
for app in "${apps[@]}"; do hard_refresh_app "$app"; done
sync_app_oc "platform-${CLUSTER_ID}" true
wait_app_synced_healthy "platform-${CLUSTER_ID}" 1200
sync_app_oc "mongodb-community-operator-${INSTANCE_ID}" true
wait_app_synced_healthy "mongodb-community-operator-${INSTANCE_ID}" 1200
sync_app_oc "mongodb-ce-${INSTANCE_ID}" true

say "4/6 Wait for dedicated MongoDB"
wait_mongo_running 1800

say "5/6 Publish Mongo CA into Vault"
./scripts/sync-mongo-ca.sh "$ENVFILE"
hard_refresh_app "mongodb-ce-${INSTANCE_ID}"
hard_refresh_app "vault-sync-mongo-${INSTANCE_ID}"

say "6/6 Full Vault preflight"
./scripts/preflight-vault.sh --phase full "$ENVFILE"

cat <<MSG

============================================================
Prerequisites are ready. MAS account-root remains manual.
Next:
    ./scripts/sync-mas-account-root.sh $ENVFILE

For the IBM-aligned flow, continue with:
    ./scripts/install-ibm-way.sh --yes $ENVFILE

Or step manually:
    ./scripts/sync-mas-account-root.sh $ENVFILE
    ./scripts/sync-runtime-registration.sh --sls-only $ENVFILE
    ./scripts/enable-sls-config.sh --yes $ENVFILE
    ./scripts/sync-jdbc-config.sh $ENVFILE
    ./scripts/sync-runtime-registration.sh --dro-only $ENVFILE
    ./scripts/enable-bas-config.sh --yes $ENVFILE
    ./scripts/enable-manage.sh --yes $ENVFILE
============================================================
MSG
