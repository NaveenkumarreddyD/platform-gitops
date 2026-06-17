#!/usr/bin/env bash
set -euo pipefail
# MAS install — PART 2 of 2: SLS + JDBC + (DRO/BAS) + Suite Ready + Manage.
# Run after mas-prep.sh, once the Suite exists and MongoCfg is Ready. (SystemDatabaseReady is NOT
# required up front — it can't go True until SLS is enabled, so this script enables SLS first, then
# verifies SystemDatabaseReady. This avoids the catalogmgr->SLS deadlock.)
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
assert_repo_fresh   # refuse to run a stale platform-gitops clone
CORE_NS="mas-${INSTANCE_ID}-core"
YES_ARGS=(); [[ "$YES" == 1 ]] && YES_ARGS+=(--yes)
is_true(){ [[ "${1:-}" =~ ^([1]|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss])$ ]]; }
banner(){ printf '\n############################################################\n# %s\n############################################################\n' "$*"; }

banner "6b. Mongo CA -> Vault + drive the wave-100 SLS LicenseService to Ready (unblocks wave 130)"
# The wave-100 SLS LicenseService caches its Mongo TLS verify on first connect and parks at
# Failure=True (Argo: Degraded). That blocks the ENTIRE cascade — wave 130 (MongoCfg/SLSCfg/BASCfg)
# is NOT generated until the sls app is Healthy. So we must clear it here, deterministically:
#   1. wait for the LicenseService CR to be created (wave 100 sync), then
#   2. run the idempotent reconcile, which writes the live Mongo CA to Vault and bounce-retries the
#      SLS controller until the LicenseService is Ready.
# Suite SystemDatabaseReady is deferred (skip) — it can't pass until SLS is configured (catalogmgr
# needs the SLS secret to start, and the Suite gates on its core components -> deadlock if verified
# here). It is verified later in 7b once SLSCfg is Ready. All steps are idempotent / re-runnable.
SLS_NS="mas-${INSTANCE_ID}-sls"
e=0
until [[ -n "$(oc get licenseservices.sls.ibm.com -n "$SLS_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; do
  (( e >= 1200 )) && { echo "ERROR: SLS LicenseService CR was never created (wave-100 sls app not synced)." >&2
    echo "Check: oc get application sls.${CLUSTER_ID}.${INSTANCE_ID} -n ${ARGO_NS:-openshift-gitops}" >&2; exit 1; }
  echo ">> waiting for the wave-100 SLS LicenseService CR to be created (${e}s)"; sleep 15; (( e += 15 ))
done
SKIP_SUITE_SYSTEMDB_WAIT=true ./scripts/reconcile-mongo-dependent-configs.sh "$ENVFILE"

banner "7. Harvest SLS registration into Vault, then converge the (already-rendered) SLSCfg"
# Declarative: SLSCfg is rendered from the START (ENABLE_SLS_CONFIG=true) — no mid-deploy enable or
# git commit. SLS is up now, so harvest its registration + served CA into Vault; enable-sls-config
# then finds no config change (idempotent, no commit) and just re-renders + bounce_until_ready the
# slscfg controller until it registers. Done BEFORE the SystemDatabaseReady gate so SLSCfg ->
# drgitopsapp-sls-cfg -> catalogmgr can start -> the Suite converges (no catalogmgr<->SLS deadlock).
./scripts/sync-runtime-registration.sh --sls-only "$ENVFILE"
./scripts/enable-sls-config.sh "${YES_ARGS[@]}" "$ENVFILE"
wait_resource_ready slscfgs.config.mas.ibm.com "${INSTANCE_ID}-sls-system" "$CORE_NS" 1800

banner "7b. Now verify the Suite can read MongoDB (SystemDatabaseReady) — SLS is up, no deadlock"
# With SLSCfg Ready, catalogmgr starts and the Suite can converge. This runs the deterministic
# bounce-retry SystemDatabaseReady verify (the part skipped in 6b).
./scripts/reconcile-mongo-dependent-configs.sh "$ENVFILE"

banner "8. Sync JdbcCfg"
./scripts/sync-jdbc-config.sh "$ENVFILE"
wait_resource_ready jdbccfgs.config.mas.ibm.com "${INSTANCE_ID}-jdbc-system" "$CORE_NS" 1800

banner "9. Harvest DRO registration and converge BASCfg (DRO is always deployed; BASCfg rendered up front)"
# Declarative: DRO is always deployed and BASCfg renders from the start. Harvest the DRO
# registration + served CA into Vault, then converge (bounce_until_ready bascfg). The Suite
# requires BASIntegrationReady, so this must complete before Suite Ready.
./scripts/sync-runtime-registration.sh --dro-only "$ENVFILE"
./scripts/enable-bas-config.sh "${YES_ARGS[@]}" "$ENVFILE"
wait_resource_ready bascfgs.config.mas.ibm.com "${INSTANCE_ID}-bas-system" "$CORE_NS" 1800

banner "10. Wait for Suite Ready"
wait_resource_ready mongocfgs.config.mas.ibm.com "${INSTANCE_ID}-mongo-system" "$CORE_NS" 1800
wait_suite_ready "$INSTANCE_ID" "$CORE_NS" 3600

banner "11. Wait for Manage to converge (rendered declaratively; account-root auto-generates it)"
./scripts/enable-manage.sh "${YES_ARGS[@]}" "$ENVFILE"

banner "11b. Back up auto-generated Manage crypto keys + admin superuser into Vault (DR/reproducibility)"
# When MANAGE_AUTO_GENERATE_ENCRYPTION_KEYS=true, MAS mints the crypto keys itself; capture them
# (and the operator-generated admin superuser) into Vault so a reinstall/DR can reuse them. Non-fatal.
./scripts/backup-manage-secrets.sh "$ENVFILE" \
  || echo ">> WARN: manage-secrets backup skipped/failed (non-fatal). Re-run later: ./scripts/backup-manage-secrets.sh $ENVFILE"

banner "12. Summary + verify"
./scripts/status-summary.sh "$ENVFILE" || true
./scripts/verify-install.sh "$ENVFILE"

cat <<MSG

Done: cluster=$CLUSTER_ID instance=$INSTANCE_ID. Watch Manage:
  oc get pods -n mas-${INSTANCE_ID}-manage -w
MSG
