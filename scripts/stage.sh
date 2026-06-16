#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# Staged MAS installer/dispatcher.
#
# WHY: the old single-shot install hid real failures (AVP cert wiring, Mongo CA,
# SLS CA) deep inside one long run. This splits the install into named, idempotent
# stages. Each stage does: preflight (assert prerequisites) -> apply (do the work)
# -> verify (prove the REAL outcome: the CR condition, not just "Argo Synced").
# A stage that fails stops the run immediately, dumps the relevant CR conditions and
# operator logs, and prints the exact remediation command. You fix it, then re-run
# just that stage. Completed stages are checkpointed so --all resumes where it left off.
#
# USAGE:
#   ./scripts/stage.sh --list
#   ./scripts/stage.sh --all [--yes] [--force] <env>      # run all, resume from checkpoint
#   ./scripts/stage.sh --only sls [--yes] <env>           # run one stage
#   ./scripts/stage.sh --from mongo [--to suite] [--yes] <env>
#
# Stages reuse the existing per-task scripts; nothing is rewritten.
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

STAGES=(preflight vault cert mongo account-root catalog mongo-verify sls jdbc bas suite manage verify)

declare -A DESC=(
  [preflight]="local tools, cluster access, Vault, secret inputs (check-env.sh)"
  [vault]="Vault auth + static secrets + render & push MAS config (deploy.sh)"
  [cert]="assert MAS public certificate is loaded in Vault (manual cert mgmt)"
  [mongo]="MongoDB prerequisites + publish Mongo CA (prepare-prereqs.sh)"
  [account-root]="sync IBM MAS account-root; generate Suite and child apps"
  [catalog]="verify operator catalog carries the desired MAS/SLS/Manage channels (version gate)"
  [mongo-verify]="reconcile Mongo CA and verify Suite SystemDatabaseReady=True"
  [sls]="harvest SLS registration into Vault; enable & register SLSCfg"
  [jdbc]="sync the system JdbcCfg"
  [bas]="harvest DRO registration; enable BASCfg"
  [suite]="wait for Suite Ready"
  [manage]="enable Manage (ManageApp + ManageWorkspace)"
  [verify]="full verify-install (incl. CSV versions match env target versions)"
)

# Per-stage remediation hint shown on failure (in addition to the diagnostics the
# lib helpers already dump).
declare -A REMEDY=(
  [cert]="load it: export VAULT_TOKEN=...; ./scripts/load-mas-public-cert.sh <env> <cert.pfx>"
  [catalog]="desired version not in catalog: confirm MAS_CHANNEL/SLS_CHANNEL/MAS_APP_CHANNEL in the env match the operator-catalog image tag; the catalog source may still be importing (re-run to keep waiting)"
  [mongo-verify]="stale Mongo CA or upstream Suite failure; read the operator log above. Re-run: ./scripts/stage.sh --only mongo-verify <env>"
  [sls]="SLS CA/registration mismatch; check cm/sls-suite-registration ca vs the SLS serving cert, then re-run: ./scripts/stage.sh --only sls <env>"
)

# ---- args ------------------------------------------------------------------
MODE="all"; ONLY=""; FROM=""; TO=""; FORCE=0; YES=0; ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) MODE="list"; shift ;;
    --all) MODE="all"; shift ;;
    --only) MODE="only"; ONLY="${2:?--only needs a stage}"; shift 2 ;;
    --from) MODE="range"; FROM="${2:?--from needs a stage}"; shift 2 ;;
    --to) TO="${2:?--to needs a stage}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) ENVFILE="$1"; shift ;;
  esac
done

if [[ "$MODE" == "list" ]]; then
  echo "Stages (in order):"
  for s in "${STAGES[@]}"; do printf '  %-13s %s\n' "$s" "${DESC[$s]}"; done
  exit 0
fi

ENVFILE="${ENVFILE:?usage: stage.sh [--all|--only <s>|--from <s> [--to <s>]] [--yes] [--force] <env>}"
[[ -f "$ENVFILE" ]] || { echo "ERROR: env file not found: $ENVFILE" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
CORE_NS="mas-${INSTANCE_ID}-core"
MANAGE_NS="mas-${INSTANCE_ID}-manage"
MONGO_NS="${MONGO_NS:-}"
YES_ARGS=(); [[ "$YES" == 1 ]] && YES_ARGS+=(--yes)

STATE_DIR="$ROOT/.install-state"; mkdir -p "$STATE_DIR"
DONE_FILE="$STATE_DIR/$(basename "$ENVFILE" .env).done"; touch "$DONE_FILE"
is_done(){ grep -qxF "$1" "$DONE_FILE" 2>/dev/null; }
mark_done(){ is_done "$1" || echo "$1" >> "$DONE_FILE"; }

valid_stage(){ for s in "${STAGES[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }
index_of(){ local i=0; for s in "${STAGES[@]}"; do [[ "$s" == "$1" ]] && { echo "$i"; return; }; ((i++)); done; echo -1; }

banner(){ printf '\n========================================================\n# STAGE: %s — %s\n========================================================\n' "$1" "${DESC[$1]:-}"; }

# ---- per-stage apply+verify -----------------------------------------------
# Each function: assert preflight, run the work, then verify the real outcome.
# Any failing command aborts the stage (run under set -e in a subshell by the runner).
do_stage() {
  local s="$1"
  case "$s" in
    preflight)
      CHECK_SECRET_INPUTS="${CHECK_SECRET_INPUTS:-true}" ./scripts/check-env.sh "$ENVFILE"
      ;;
    vault)
      ./scripts/deploy.sh "${YES_ARGS[@]}" "$ENVFILE"
      echo ">> verify: static secrets well-formed in Vault"
      ./scripts/preflight-vault.sh --phase static "$ENVFILE"
      ;;
    cert)
      # preflight==verify here: the cert must already be in Vault (load is manual).
      ./scripts/preflight-public-cert.sh "$ENVFILE"
      ;;
    mongo)
      ./scripts/prepare-prereqs.sh "$ENVFILE"
      echo ">> verify: a Mongo CA secret exists in $MONGO_NS"
      [[ -n "$MONGO_NS" ]] || { echo "ERROR: MONGO_NS not set in env" >&2; exit 1; }
      local mcr="${MONGO_CR:-${INSTANCE_ID}-mongo}" found=0
      for sec in "${mcr}-ca" "${mcr}-server-cert"; do
        oc get secret "$sec" -n "$MONGO_NS" >/dev/null 2>&1 && { echo ">> found secret/$sec"; found=1; break; }
      done
      [[ "$found" == 1 ]] || { echo "ERROR: no Mongo CA secret in $MONGO_NS; is the dedicated Mongo Ready?" >&2; exit 1; }
      ;;
    account-root)
      ./scripts/sync-mas-account-root.sh "$ENVFILE"
      echo ">> verify: Suite CR generated and config CRDs registered"
      wait_crd suites.core.mas.ibm.com 1800
      wait_crd slscfgs.config.mas.ibm.com 1800
      oc get suite "$INSTANCE_ID" -n "$CORE_NS" >/dev/null 2>&1 \
        || { echo "ERROR: suite/$INSTANCE_ID not created by account-root" >&2; exit 1; }
      ;;
    catalog)
      # Version gate: the IBM operator catalog (created by account-root) must expose the
      # exact channels named in the env, or Suite/SLS/Manage subscriptions resolve to the
      # wrong version (or not at all). check-olm-catalog waits for the catalog and asserts
      # the channel heads exist for ibm-mas / ibm-sls / ibm-mas-manage.
      ./scripts/check-olm-catalog.sh "$ENVFILE"
      ;;
    mongo-verify)
      ./scripts/reconcile-mongo-dependent-configs.sh "$ENVFILE"
      echo ">> verify: Suite SystemDatabaseReady=True"
      wait_suite_condition "$INSTANCE_ID" "$CORE_NS" SystemDatabaseReady 1200
      ;;
    sls)
      ./scripts/sync-runtime-registration.sh --sls-only "$ENVFILE"
      ./scripts/enable-sls-config.sh "${YES_ARGS[@]}" "$ENVFILE"
      echo ">> verify: SLSCfg Ready and Suite SLSIntegrationReady=True"
      wait_resource_ready slscfgs.config.mas.ibm.com "${INSTANCE_ID}-sls-system" "$CORE_NS" 1800
      wait_suite_condition "$INSTANCE_ID" "$CORE_NS" SLSIntegrationReady 900
      ;;
    jdbc)
      ./scripts/sync-jdbc-config.sh "$ENVFILE"
      echo ">> verify: JdbcCfg Ready"
      wait_resource_ready jdbccfgs.config.mas.ibm.com "${INSTANCE_ID}-jdbc-system" "$CORE_NS" 1800
      ;;
    bas)
      ./scripts/sync-runtime-registration.sh --dro-only "$ENVFILE"
      ./scripts/enable-bas-config.sh "${YES_ARGS[@]}" "$ENVFILE"
      echo ">> verify: BASCfg Ready and Suite BASIntegrationReady=True"
      wait_resource_ready bascfgs.config.mas.ibm.com "${INSTANCE_ID}-bas-system" "$CORE_NS" 1800
      wait_suite_condition "$INSTANCE_ID" "$CORE_NS" BASIntegrationReady 900
      ;;
    suite)
      echo ">> verify: Suite Ready"
      wait_resource_ready mongocfgs.config.mas.ibm.com "${INSTANCE_ID}-mongo-system" "$CORE_NS" 1800
      wait_suite_ready "$INSTANCE_ID" "$CORE_NS" 3600
      ;;
    manage)
      ./scripts/enable-manage.sh "${YES_ARGS[@]}" "$ENVFILE"
      echo ">> verify: ManageApp + ManageWorkspace Ready"
      wait_resource_ready manageapps.apps.mas.ibm.com "$INSTANCE_ID" "$MANAGE_NS" 3600
      wait_resource_ready manageworkspaces.apps.mas.ibm.com "${INSTANCE_ID}-${WORKSPACE_ID:?}" "$MANAGE_NS" 3600
      ;;
    verify)
      ./scripts/verify-install.sh "$ENVFILE"
      ;;
    *) echo "ERROR: unknown stage '$s'" >&2; exit 2 ;;
  esac
}

on_fail() {
  local s="$1"
  echo >&2
  echo "########################################################" >&2
  echo "# STAGE FAILED: $s" >&2
  echo "#   ${DESC[$s]:-}" >&2
  [[ -n "${REMEDY[$s]:-}" ]] && echo "#   remediation: ${REMEDY[$s]}" >&2
  echo "#   after fixing, re-run just this stage:" >&2
  echo "#     ./scripts/stage.sh --only $s ${YES_ARGS[*]} $ENVFILE" >&2
  echo "########################################################" >&2
}

run_one() {
  local s="$1"
  banner "$s"
  set +e
  ( set -e; do_stage "$s" )
  local rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then on_fail "$s"; exit 1; fi
  mark_done "$s"
  echo ">> STAGE OK: $s"
}

# ---- build the list of stages to run --------------------------------------
to_run=()
case "$MODE" in
  only)
    valid_stage "$ONLY" || { echo "ERROR: unknown stage '$ONLY' (see --list)" >&2; exit 2; }
    to_run=("$ONLY")
    ;;
  range)
    valid_stage "$FROM" || { echo "ERROR: unknown --from stage '$FROM'" >&2; exit 2; }
    local_to="${TO:-${STAGES[-1]}}"
    valid_stage "$local_to" || { echo "ERROR: unknown --to stage '$local_to'" >&2; exit 2; }
    fi_idx="$(index_of "$FROM")"; ti_idx="$(index_of "$local_to")"
    (( fi_idx <= ti_idx )) || { echo "ERROR: --from is after --to" >&2; exit 2; }
    for i in "${!STAGES[@]}"; do (( i >= fi_idx && i <= ti_idx )) && to_run+=("${STAGES[$i]}"); done
    ;;
  all)
    for s in "${STAGES[@]}"; do
      if [[ "$FORCE" == 0 ]] && is_done "$s"; then
        echo ">> skip (already done): $s   [--force to re-run]"
      else
        to_run+=("$s")
      fi
    done
    ;;
esac

[[ "${#to_run[@]}" -eq 0 ]] && { echo "Nothing to do (all selected stages already complete). Use --force to re-run."; exit 0; }

echo ">> will run: ${to_run[*]}"
for s in "${to_run[@]}"; do run_one "$s"; done

echo
echo "DONE. Completed stages recorded in $DONE_FILE"
echo "Next: ./scripts/stage.sh --list   |   re-run one: ./scripts/stage.sh --only <stage> $ENVFILE"
