#!/usr/bin/env bash
set -euo pipefail
# MAS install — PART 1 of 2: secrets + config + cert + Mongo + account-root.
# Run after Vault is up (setup-vault-platform.sh + setup-vault-auth.sh) and after you've
# exported IBM_ENTITLEMENT_KEY / MAS_LICENSE_FILE / JDBC_* and loaded the public cert.
#
#   ./scripts/mas-prep.sh --yes ../mas-config-repo/envs/drroc4.env
#
# When this finishes: check the Suite exists and SystemDatabaseReady=True, then run mas-install.sh.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

YES=0; ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    -h|--help) echo "usage: mas-prep.sh [--yes] <path/to/cluster.env>"; exit 0 ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: mas-prep.sh [--yes] <path/to/cluster.env>}"
[[ -f "$ENVFILE" ]] || { echo "ERROR: env file not found: $ENVFILE" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
assert_repo_fresh   # refuse to run a stale platform-gitops clone
CORE_NS="mas-${INSTANCE_ID}-core"
YES_ARGS=(); [[ "$YES" == 1 ]] && YES_ARGS+=(--yes)
is_true(){ [[ "${1:-}" =~ ^([1]|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss])$ ]]; }
banner(){ printf '\n############################################################\n# %s\n############################################################\n' "$*"; }

banner "1. Validate tools, cluster access, Vault, secret inputs, versions"
CHECK_SECRET_INPUTS=true ./scripts/check-env.sh "$ENVFILE"

banner "2. Vault auth + load static secrets + render & push MAS config"
./scripts/deploy.sh "${YES_ARGS[@]}" "$ENVFILE"

banner "2b. Hard-refresh the cascade so AVP re-renders with the just-loaded secrets"
# With accountRoot.autoSync, bootstrap may have generated the cascade (operator-catalog, etc.)
# BEFORE step 2 wrote the secrets, leaving cached AVP 'Could not find secrets' errors. Bust them.
hard_refresh_cluster_apps "$CLUSTER_ID" "$INSTANCE_ID"

banner "3. Verify MAS public certificate is in Vault (manual cert management)"
if is_true "${MAS_MANUAL_CERT_MGMT:-true}"; then
  ./scripts/preflight-public-cert.sh "$ENVFILE"
else
  echo ">> MAS_MANUAL_CERT_MGMT=false; skipping public cert check."
fi

banner "4. MongoDB prerequisites + publish Mongo CA"
./scripts/prepare-prereqs.sh "$ENVFILE"

banner "5. Sync MAS account-root (generates Suite + child apps)"
./scripts/sync-mas-account-root.sh "$ENVFILE"

banner "6. Reconcile Mongo CA so the Suite can verify MongoDB"
./scripts/reconcile-mongo-dependent-configs.sh "$ENVFILE"

cat <<MSG

############################################################
# PREP COMPLETE for $INSTANCE_ID.
# Check before continuing:
#   oc get suite $INSTANCE_ID -n $CORE_NS -o custom-columns=\\
#     STATUS:.status.status,SYSTEMDB:.status.conditions[?(@.type=="SystemDatabaseReady")].status
# When the Suite exists and SystemDatabaseReady=True, run part 2:
#   ./scripts/mas-install.sh ${YES_ARGS[*]} $ENVFILE
############################################################
MSG
