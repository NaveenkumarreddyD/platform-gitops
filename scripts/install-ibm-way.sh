#!/usr/bin/env bash
set -euo pipefail
# IBM-aligned staged install:
#   platform prereqs -> account-root -> SLSCfg -> JdbcCfg -> DRO/BAS -> Suite Ready -> Manage.
#
# This script intentionally treats BAS/DRO as a required pre-Manage gate for this topology because
# MAS 8.11 reports Suite Ready only after BasIntegrationReady when contract/performance reporting is
# enabled by the IBM chart defaults.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

YES=0
ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    -h|--help)
      echo "usage: install-ibm-way.sh [--yes] <path/to/cluster.env>"
      exit 0
      ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: install-ibm-way.sh [--yes] <path/to/cluster.env>}"
[[ -f "$ENVFILE" ]] || { echo "ERROR: env file not found: $ENVFILE" >&2; exit 2; }

# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"; : "${WORKSPACE_ID:?}"
CORE_NS="mas-${INSTANCE_ID}-core"
YES_ARGS=()
[[ "$YES" == 1 ]] && YES_ARGS+=(--yes)

banner(){ printf '\n############################################################\n# %s\n############################################################\n' "$*"; }

banner "1. Validate local tools, cluster access, Vault, and secret inputs"
CHECK_SECRET_INPUTS=true ./scripts/check-env.sh "$ENVFILE"

banner "2. Configure Vault auth, load static secrets, render and push MAS config"
./scripts/deploy.sh "${YES_ARGS[@]}" "$ENVFILE"

banner "3. Prepare MongoDB prerequisites and publish Mongo CA"
./scripts/prepare-prereqs.sh "$ENVFILE"

banner "4. Sync MAS account-root"
./scripts/sync-mas-account-root.sh "$ENVFILE"

banner "5. Harvest SLS registration and enable SLSCfg"
./scripts/sync-runtime-registration.sh --sls-only "$ENVFILE"
./scripts/enable-sls-config.sh "${YES_ARGS[@]}" "$ENVFILE"
wait_resource_ready slscfgs.config.mas.ibm.com "${INSTANCE_ID}-sls-system" "$CORE_NS" 1800

banner "6. Sync JdbcCfg"
./scripts/sync-jdbc-config.sh "$ENVFILE"
wait_resource_ready jdbccfgs.config.mas.ibm.com "${INSTANCE_ID}-jdbc-system" "$CORE_NS" 1800

banner "7. Harvest DRO registration and enable BASCfg"
./scripts/sync-runtime-registration.sh --dro-only "$ENVFILE"
./scripts/enable-bas-config.sh "${YES_ARGS[@]}" "$ENVFILE"
wait_resource_ready bascfgs.config.mas.ibm.com "${INSTANCE_ID}-bas-system" "$CORE_NS" 1800

banner "8. Wait for Suite Ready"
wait_resource_ready mongocfgs.config.mas.ibm.com "${INSTANCE_ID}-mongo-system" "$CORE_NS" 1800
wait_suite_ready "$INSTANCE_ID" "$CORE_NS" 3600

banner "9. Enable Manage"
./scripts/enable-manage.sh "${YES_ARGS[@]}" "$ENVFILE"

banner "10. Summary"
./scripts/status-summary.sh "$ENVFILE" || true

cat <<MSG

IBM-aligned install flow completed for cluster=$CLUSTER_ID instance=$INSTANCE_ID.
Watch Manage:
  oc get applications -n $ARGO_NS | grep -E 'manage\\.${CLUSTER_ID}\\.${INSTANCE_ID}|${WORKSPACE_ID}'
  oc get pods -n mas-${INSTANCE_ID}-manage -w
MSG
