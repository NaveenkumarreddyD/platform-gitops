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

echo ">> enabling ENABLE_BAS_CONFIG=true in $ENVFILE"
set_env_true() {
  local key="${1:?env key}"
  if grep -q "^${key}=" "$ENVFILE"; then
    perl -0pi -e "s/^${key}=.*/${key}=true/m" "$ENVFILE"
  else
    printf '\n%s=true\n' "$key" >> "$ENVFILE"
  fi
}
set_env_true ENABLE_BAS_CONFIG
set_env_true MAS_FEATURE_USAGE
set_env_true MAS_DEPLOYMENT_PROGRESSION
set_env_true MAS_USABILITY_METRICS
set_env_true MAS_CONTRACT_PERFORMANCE

(
  cd "$CONFIG_REPO"
  python3 render.py "$CLUSTER"
  git add "envs/$CLUSTER.env" "mas/$CLUSTER"
  if git diff --cached --quiet; then
    echo ">> BAS config already enabled; no config commit needed."
  else
    git --no-pager diff --cached --stat
    if [[ "$ASSUME_YES" == "1" ]]; then
      a=y
    else
      read -r -p "Commit and push BAS config changes? [y/N] " a
    fi
    if [[ "$a" == y ]]; then
      git commit -m "enable BAS config for $CLUSTER"
      git push
      wait_config_repo_published "$CONFIG_REPO" "$CLUSTER" 300
    else
      echo "ERROR: BAS config not pushed; account-root cannot pick it up." >&2
      exit 1
    fi
  fi
)

echo ">> refreshing and syncing account-root so bas-system is generated"
sync_parent_until_child_exists ibm-mas-account-root "${INSTANCE_ID}-bas-system.${CLUSTER_ID}" 900
hard_refresh_app "${INSTANCE_ID}-bas-system.${CLUSTER_ID}"
sync_app_oc "${INSTANCE_ID}-bas-system.${CLUSTER_ID}" false
wait_app_synced_healthy "${INSTANCE_ID}-bas-system.${CLUSTER_ID}" 1200
echo ">> waiting for mas-${INSTANCE_ID}-core/bascfgs.config.mas.ibm.com/${INSTANCE_ID}-bas-system Ready"
wait_resource_ready bascfgs.config.mas.ibm.com "${INSTANCE_ID}-bas-system" "mas-${INSTANCE_ID}-core" 1800
echo ">> BAS config enabled and Ready."
