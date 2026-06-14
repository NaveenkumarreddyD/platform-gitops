#!/usr/bin/env bash
set -euo pipefail
# Sync the locally-owned non-SSL JdbcCfg only after MAS Suite has registered
# config.mas.ibm.com CRDs. This prevents Argo from failing before the CRD exists.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"
ENVFILE="${1:?usage: sync-jdbc-config.sh <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
CORE_NS="mas-${INSTANCE_ID}-core"
APP="${INSTANCE_ID}-jdbc-system"

echo ">> waiting for MAS config CRDs before syncing $APP"
wait_crd jdbccfgs.config.mas.ibm.com 1800
wait_crd suites.core.mas.ibm.com 1800

oc get ns "$CORE_NS" >/dev/null
hard_refresh_app "$APP"
sync_app_oc "$APP" true
wait_app_synced_healthy "$APP" 900

echo ">> JDBC config synced. Hard-refreshing Manage workspace app if present."
for app in $(oc get applications -n "$ARGO_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  | grep -E "\\.manage\\.${CLUSTER_ID}\\.${INSTANCE_ID}$" || true); do
  hard_refresh_app "$app"
done
