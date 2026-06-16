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

echo ">> waiting for MAS config CRD slscfgs.config.mas.ibm.com"
wait_crd slscfgs.config.mas.ibm.com 1800

echo ">> enabling ENABLE_SLS_CONFIG=true in $ENVFILE"
if grep -q '^ENABLE_SLS_CONFIG=' "$ENVFILE"; then
  perl -0pi -e 's/^ENABLE_SLS_CONFIG=.*/ENABLE_SLS_CONFIG=true/m' "$ENVFILE"
else
  printf '\nENABLE_SLS_CONFIG=true\n' >> "$ENVFILE"
fi

(
  cd "$CONFIG_REPO"
  python3 render.py "$CLUSTER"
  git add "envs/$CLUSTER.env" "mas/$CLUSTER"
  if git diff --cached --quiet; then
    echo ">> SLS config already enabled; no config commit needed."
  else
    git --no-pager diff --cached --stat
    if [[ "$ASSUME_YES" == "1" ]]; then
      a=y
    else
      read -r -p "Commit and push SLS config changes? [y/N] " a
    fi
    if [[ "$a" == y ]]; then
      git commit -m "enable SLS config for $CLUSTER"
      git push
    else
      echo "ERROR: SLS config not pushed; account-root cannot pick it up." >&2
      exit 1
    fi
  fi
)

SUITE_APP="suite.${CLUSTER_ID}.${INSTANCE_ID}"

echo ">> refreshing account-root so application/$SUITE_APP picks up SLSCfg"
echo ">> syncing $SUITE_APP"
sync_parent_until_child_exists ibm-mas-account-root "$SUITE_APP" 600
sync_app_oc "$SUITE_APP" true
wait_app_synced_healthy "$SUITE_APP" 1200
