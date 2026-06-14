#!/usr/bin/env bash
set -euo pipefail
# Approve the pinned Grafana operator InstallPlan, wait for its CRDs, then sync
# the Grafana operand app. Uses oc only.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"
ENVFILE="${1:?usage: sync-grafana.sh <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"
APP="grafana-${CLUSTER_ID}"

./scripts/approve-grafana-installplan.sh

echo ">> waiting for Grafana operator CRDs"
wait_crd grafanas.grafana.integreatly.org 1200
wait_crd grafanadatasources.grafana.integreatly.org 1200
wait_crd grafanadashboards.grafana.integreatly.org 1200

hard_refresh_app "$APP"
sync_app_oc "$APP" true
wait_app_synced_healthy "$APP" 900
