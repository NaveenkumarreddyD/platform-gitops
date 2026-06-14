#!/usr/bin/env bash
set -euo pipefail
# ============================================================================
# install-all.sh — one-shot, end-to-end MAS GitOps bring-up.
#
# Chains every step from loaded-Vault to a verified platform, waiting for each
# async precondition along the way (the individual scripts already block on
# MongoDB/SLS/DRO readiness). This collapses the old multi-command hand-off
# (deploy -> prepare-prereqs -> sync-mas-account-root -> sync-jdbc-config ->
# sync-runtime-registration -> enable-bas-config -> verify) into a single
# command, WITHOUT removing the safety waits.
#
# Prerequisites (same as before):
#   - Vault initialized + unsealed (run scripts/init-vault.sh once), and:
#       export VAULT_TOKEN=<root/admin>
#   - secret material exported for load-secrets:
#       IBM_ENTITLEMENT_KEY, MAS_LICENSE_FILE, MAS_LICENSE_ID,
#       JDBC_USERNAME, JDBC_PASSWORD, JDBC_URL  (+ JDBC_CA_CRT if SSL)
#
# Usage:
#   ./scripts/install-all.sh [options] ../mas-config-repo/envs/drroc4.env
#
# Options:
#   --yes            non-interactive: auto-confirm config commits/pushes
#   --no-push        render + commit locally but do not push (implies manual push)
#   --skip-bas       do not enable BAS/DRO Suite config even if DRO is present
#   --init-vault     run scripts/init-vault.sh first (still prints/saves keys)
#   --from <step>    resume at a step: deploy|prereqs|account-root|jdbc|
#                    registration|bas|verify
#   --until <step>   stop AFTER this step (e.g. --until prereqs reproduces the
#                    old install-gated.sh: prerequisites only, MAS not started)
#   -h, --help       show this help
# ============================================================================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

YES=0; NO_PUSH=0; SKIP_BAS=0; DO_INIT=0; FROM=""; UNTIL=""; ENVFILE=""
PASS_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)     YES=1; PASS_ARGS+=(--yes); shift ;;
    --no-push)    NO_PUSH=1; PASS_ARGS+=(--no-push); shift ;;
    --skip-bas)   SKIP_BAS=1; shift ;;
    --init-vault) DO_INIT=1; shift ;;
    --from)       FROM="$2"; shift 2 ;;
    --until)      UNTIL="$2"; shift 2 ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *)            ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: install-all.sh [options] <path/to/cluster.env>}"
[[ -f "$ENVFILE" ]] || { echo "ERROR: env file not found: $ENVFILE" >&2; exit 2; }

# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
DRO_NS="${DRO_NAMESPACE:-ibm-software-central}"

# step ordering for --from resume
STEPS=(deploy prereqs account-root jdbc registration bas verify)
START_IDX=0
END_IDX=$(( ${#STEPS[@]} - 1 ))
idx_of(){ local t="$1"; for i in "${!STEPS[@]}"; do [[ "${STEPS[$i]}" == "$t" ]] && { echo "$i"; return 0; }; done; return 1; }
if [[ -n "$FROM" ]];  then START_IDX="$(idx_of "$FROM")"  || { echo "ERROR: --from must be one of: ${STEPS[*]}"  >&2; exit 2; }; fi
if [[ -n "$UNTIL" ]]; then END_IDX="$(idx_of "$UNTIL")"   || { echo "ERROR: --until must be one of: ${STEPS[*]}" >&2; exit 2; }; fi
should_run(){ # arg: step name -> true if within [START_IDX, END_IDX]
  local i; i="$(idx_of "$1")" || return 1
  [[ "$i" -ge "$START_IDX" && "$i" -le "$END_IDX" ]]
}
banner(){ printf '\n############################################################\n# %s\n############################################################\n' "$*"; }

[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; }

# ----- optional: initialize + unseal Vault -----
if [[ "$DO_INIT" == 1 ]]; then
  banner "0. Initialize + unseal Vault"
  bash scripts/init-vault.sh
  echo ">> NOTE: if init-vault printed a fresh root token, re-export VAULT_TOKEN before continuing."
fi

# ----- 1. env validation -----
banner "1. Environment validation"
./scripts/check-env.sh "$ENVFILE"

# ----- 2. deploy: vault auth + load secrets + render + commit/push -----
if should_run deploy; then
  banner "2. Vault auth, load static secrets, render + commit config"
  ./scripts/deploy.sh "${PASS_ARGS[@]}" "$ENVFILE"
fi

# ----- 3. mongo prerequisites + full preflight -----
if should_run prereqs; then
  banner "3. MongoDB prerequisites + full Vault preflight"
  ./scripts/prepare-prereqs.sh "$ENVFILE"
fi

# ----- 4. sync MAS account-root (starts Core/SLS/Manage) -----
if should_run account-root; then
  banner "4. Sync IBM MAS account-root (Core / SLS / Manage)"
  ./scripts/sync-mas-account-root.sh "$ENVFILE"
fi

# ----- 5. sync locally-owned JDBC config after MAS CRDs exist -----
if should_run jdbc; then
  banner "5. Sync JDBC config after MAS CRDs exist"
  ./scripts/sync-jdbc-config.sh "$ENVFILE"
fi

# ----- 6. SLS/DRO runtime registration -> Vault -----
if should_run registration; then
  banner "6. Sync SLS/DRO runtime registration into Vault"
  ./scripts/sync-runtime-registration.sh "$ENVFILE"
fi

# ----- 7. enable BAS/DRO Suite config (only if DRO present) -----
if should_run bas; then
  if [[ "$SKIP_BAS" == 1 ]]; then
    banner "7. BAS/DRO Suite config — SKIPPED (--skip-bas)"
  else
    banner "7. Enable BAS/DRO Suite config"
    if ./scripts/enable-bas-config.sh "${PASS_ARGS[@]}" "$ENVFILE"; then
      echo ">> BAS config enabled."
    else
      echo ">> WARN: BAS config not enabled (DRO values may not be in Vault yet)."
      echo ">>       Re-run later:  ./scripts/enable-bas-config.sh ${PASS_ARGS[*]} $ENVFILE"
    fi
  fi
fi

# ----- 8. verify -----
if should_run verify; then
  banner "8. Verify platform"
  ./scripts/status-summary.sh "$ENVFILE" || true
  ./scripts/app-diagnostics.sh "$ENVFILE" || true
  ./scripts/verify-platform.sh || true
fi

cat <<MSG

############################################################
 install-all complete for cluster=$CLUSTER_ID instance=$INSTANCE_ID
 Watch convergence:
   oc get applications -n ${ARGO_NS:-openshift-gitops} -w
############################################################
MSG
