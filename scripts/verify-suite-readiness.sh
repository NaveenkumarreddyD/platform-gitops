#!/usr/bin/env bash
set -euo pipefail
# Fail-fast gate that explains WHY a Suite is not Ready, one condition at a time,
# instead of letting `wait_suite_ready` block for an hour and then print raw YAML.
#
# It checks the Suite's required conditions in dependency order and, for the two
# that are routinely fixable from this repo, points at (or optionally runs) the
# remediation script. This is the guard that would have turned the long
# "timeout waiting for suite ... health=Degraded" into an immediate, named cause.
#
#   ./verify-suite-readiness.sh [--fix] <path/to/cluster.env>
#     --fix   attempt the obvious remediation (mongo CA reconcile) automatically
#
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

FIX=0; ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix) FIX=1; shift ;;
    -h|--help) echo "usage: verify-suite-readiness.sh [--fix] <path/to/cluster.env>"; exit 0 ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: verify-suite-readiness.sh [--fix] <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
CORE_NS="mas-${INSTANCE_ID}-core"
SUITE="$INSTANCE_ID"

oc get suite "$SUITE" -n "$CORE_NS" >/dev/null 2>&1 || {
  echo "ERROR: suite/$SUITE not found in $CORE_NS yet. Run account-root sync first." >&2
  exit 2
}

cond() { oc get suite "$SUITE" -n "$CORE_NS" -o jsonpath="{.status.conditions[?(@.type=='$1')].status}" 2>/dev/null || true; }
why()  { oc get suite "$SUITE" -n "$CORE_NS" -o jsonpath="{.status.conditions[?(@.type=='$1')].reason}{': '}{.status.conditions[?(@.type=='$1')].message}" 2>/dev/null || true; }

echo "== suite/$SUITE in $CORE_NS =="
dump_cr_conditions suite "$SUITE" "$CORE_NS"
echo

fail=0

# 1. Mongo (keystone). InvalidConfiguration here almost always means a stale Mongo CA.
if [[ "$(cond SystemDatabaseReady)" != "True" ]]; then
  echo "BLOCKER  SystemDatabaseReady -> $(why SystemDatabaseReady)"
  echo "         cause: Suite cannot verify MongoDB (CA in Vault disagrees with live Mongo cert)."
  if [[ "$FIX" == 1 ]]; then
    echo "         --fix: running reconcile-mongo-dependent-configs.sh"
    ./scripts/reconcile-mongo-dependent-configs.sh "$ENVFILE"
  else
    echo "         fix:   ./scripts/reconcile-mongo-dependent-configs.sh $ENVFILE"
  fi
  fail=1
else
  echo "OK       SystemDatabaseReady"
fi

# 2. SLS. InvalidConfiguration / uninitialized = registration was never harvested into Vault.
if [[ "$(cond SLSIntegrationReady)" != "True" ]]; then
  echo "BLOCKER  SLSIntegrationReady -> $(why SLSIntegrationReady)"
  echo "         cause: SLSCfg rendered without registration values; harvest SLS into Vault, then enable."
  echo "         fix:   ./scripts/sync-runtime-registration.sh --sls-only $ENVFILE && ./scripts/enable-sls-config.sh --yes $ENVFILE"
  fail=1
else
  echo "OK       SLSIntegrationReady"
fi

# 3. BAS. NotConfigured is EXPECTED until the BAS stage; only flag a real misconfig.
bas="$(cond BASIntegrationReady)"; basreason="$(why BASIntegrationReady)"
if [[ "$bas" != "True" ]]; then
  if [[ "$basreason" == NotConfigured* ]]; then
    echo "PENDING  BASIntegrationReady -> NotConfigured (expected until enable-bas-config.sh)"
  else
    echo "BLOCKER  BASIntegrationReady -> $basreason"
    echo "         fix:   ./scripts/sync-runtime-registration.sh --dro-only $ENVFILE && ./scripts/enable-bas-config.sh --yes $ENVFILE"
    fail=1
  fi
else
  echo "OK       BASIntegrationReady"
fi

echo
if [[ "$fail" -eq 0 ]]; then
  echo "VERIFY-SUITE-READINESS: all required conditions satisfiable; safe to wait for Suite Ready."
else
  echo "VERIFY-SUITE-READINESS: blockers above must be cleared before the Suite can go Ready."
  dump_operator_logs "$CORE_NS" 'entitymgr-suite' 300
  exit 1
fi
