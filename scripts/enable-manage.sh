#!/usr/bin/env bash
set -euo pipefail
# Enable Manage only after the IBM-required system configs and Suite are Ready.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

ASSUME_YES=0
ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help)
      echo "usage: enable-manage.sh [--yes] <path/to/cluster.env>"
      exit 0
      ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: enable-manage.sh [--yes] <path/to/cluster.env>}"
CONFIG_REPO="${CONFIG_REPO:-$(cd "$(dirname "$ENVFILE")/.." && pwd)}"
CLUSTER="$(basename "$ENVFILE" .env)"

# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"; : "${WORKSPACE_ID:?}"
CORE_NS="mas-${INSTANCE_ID}-core"

echo ">> verifying Suite config prerequisites before enabling Manage"
wait_crd suites.core.mas.ibm.com 1800
wait_crd mongocfgs.config.mas.ibm.com 1800
wait_crd slscfgs.config.mas.ibm.com 1800
wait_crd jdbccfgs.config.mas.ibm.com 1800
wait_crd bascfgs.config.mas.ibm.com 1800

for spec in \
  "mongocfgs.config.mas.ibm.com ${INSTANCE_ID}-mongo-system" \
  "slscfgs.config.mas.ibm.com ${INSTANCE_ID}-sls-system" \
  "jdbccfgs.config.mas.ibm.com ${INSTANCE_ID}-jdbc-system" \
  "bascfgs.config.mas.ibm.com ${INSTANCE_ID}-bas-system"; do
  set -- $spec
  kind="$1"; name="$2"
  echo ">> waiting for $CORE_NS/$kind/$name before enabling Manage"
  wait_resource_ready "$kind" "$name" "$CORE_NS" 1800
done

echo ">> waiting for $CORE_NS/suite/$INSTANCE_ID before enabling Manage"
wait_suite_ready "$INSTANCE_ID" "$CORE_NS" 3600

echo ">> enabling ENABLE_MANAGE=true in $ENVFILE"
if grep -q '^ENABLE_MANAGE=' "$ENVFILE"; then
  perl -0pi -e 's/^ENABLE_MANAGE=.*/ENABLE_MANAGE=true/m' "$ENVFILE"
else
  printf '\nENABLE_MANAGE=true\n' >> "$ENVFILE"
fi

(
  cd "$CONFIG_REPO"
  python3 render.py "$CLUSTER"
  git add "envs/$CLUSTER.env" "mas/$CLUSTER"
  if git diff --cached --quiet; then
    echo ">> Manage already enabled; no config commit needed."
  else
    git --no-pager diff --cached --stat
    if [[ "$ASSUME_YES" == "1" ]]; then
      a=y
    else
      read -r -p "Commit and push Manage config changes? [y/N] " a
    fi
    if [[ "$a" == y ]]; then
      git commit -m "enable Manage for $CLUSTER"
      git push
    else
      echo "ERROR: Manage config not pushed; account-root cannot pick it up." >&2
      exit 1
    fi
  fi
)

echo ">> refreshing account-root so Manage apps are generated"

MANAGE_APP="manage.${CLUSTER_ID}.${INSTANCE_ID}"
WORKSPACE_APP="${WORKSPACE_ID}.manage.${CLUSTER_ID}.${INSTANCE_ID}"

sync_parent_until_child_exists ibm-mas-account-root "$MANAGE_APP" 900
sync_app_oc "$MANAGE_APP" false
wait_app_synced_idle "$MANAGE_APP" 3600

echo ">> waiting for ManageWorkspace CRD before syncing workspace"
wait_crd manageworkspaces.apps.mas.ibm.com 3600

sync_parent_until_child_exists ibm-mas-account-root "$WORKSPACE_APP" 900
sync_app_oc "$WORKSPACE_APP" false

echo ">> Manage enabled. Watch:"
echo "   oc get applications -n $ARGO_NS | grep -E 'manage\\.${CLUSTER_ID}\\.${INSTANCE_ID}|${WORKSPACE_ID}'"
echo "   oc get pods -n mas-${INSTANCE_ID}-manage -w"
