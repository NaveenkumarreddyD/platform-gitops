#!/usr/bin/env bash
set -euo pipefail
# MAS install — PART 2 of 2: SLS + JDBC + (DRO/BAS) + Suite Ready + Manage.
# Run after mas-prep.sh, once the Suite exists and SystemDatabaseReady=True.
#
#   ./scripts/mas-install.sh --yes ../mas-config-repo/envs/drroc4.env
#
# Each wait has a timeout and dumps diagnostics on failure (no infinite hangs). Re-runnable.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

YES=0; ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    -h|--help) echo "usage: mas-install.sh [--yes] <path/to/cluster.env>"; exit 0 ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: mas-install.sh [--yes] <path/to/cluster.env>}"
[[ -f "$ENVFILE" ]] || { echo "ERROR: env file not found: $ENVFILE" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"; : "${WORKSPACE_ID:?}"
CORE_NS="mas-${INSTANCE_ID}-core"
YES_ARGS=(); [[ "$YES" == 1 ]] && YES_ARGS+=(--yes)
is_true(){ [[ "${1:-}" =~ ^([1]|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss])$ ]]; }
banner(){ printf '\n############################################################\n# %s\n############################################################\n' "$*"; }

banner "6b. Reconcile Mongo CA into the Suite's MongoCfg (now that the cascade created it)"
# The cascade creates mongocfg/slscfg AFTER mas-prep's reconcile ran, so they can render with a
# stale CA and report InvalidConfiguration. Re-run it here, when the CRs exist, to re-render with
# the live CA and bounce entitymgr-mongocfg so SystemDatabaseReady goes True. Idempotent.
./scripts/reconcile-mongo-dependent-configs.sh "$ENVFILE"

banner "7. Harvest SLS registration and enable SLSCfg"
./scripts/sync-runtime-registration.sh --sls-only "$ENVFILE"
./scripts/enable-sls-config.sh "${YES_ARGS[@]}" "$ENVFILE"
wait_resource_ready slscfgs.config.mas.ibm.com "${INSTANCE_ID}-sls-system" "$CORE_NS" 1800

banner "8. Sync JdbcCfg"
./scripts/sync-jdbc-config.sh "$ENVFILE"
wait_resource_ready jdbccfgs.config.mas.ibm.com "${INSTANCE_ID}-jdbc-system" "$CORE_NS" 1800

if is_true "${GITOPS_OWNS_DRO:-true}"; then
  banner "9. Harvest DRO registration and enable BASCfg"
  ./scripts/sync-runtime-registration.sh --dro-only "$ENVFILE"
  ./scripts/enable-bas-config.sh "${YES_ARGS[@]}" "$ENVFILE"
  wait_resource_ready bascfgs.config.mas.ibm.com "${INSTANCE_ID}-bas-system" "$CORE_NS" 1800
else
  banner "9. DRO/BAS skipped (GITOPS_OWNS_DRO=false)"
  echo ">> Enable later: set GITOPS_OWNS_DRO=true, re-render/push, then re-run this script."
fi

banner "10. Wait for Suite Ready"
wait_resource_ready mongocfgs.config.mas.ibm.com "${INSTANCE_ID}-mongo-system" "$CORE_NS" 1800
wait_suite_ready "$INSTANCE_ID" "$CORE_NS" 3600

banner "11. Enable Manage"
./scripts/enable-manage.sh "${YES_ARGS[@]}" "$ENVFILE"

banner "12. Summary + verify"
./scripts/status-summary.sh "$ENVFILE" || true
./scripts/verify-install.sh "$ENVFILE"

cat <<MSG

Done: cluster=$CLUSTER_ID instance=$INSTANCE_ID. Watch Manage:
  oc get pods -n mas-${INSTANCE_ID}-manage -w
MSG
