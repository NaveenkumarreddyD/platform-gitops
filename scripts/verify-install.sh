#!/usr/bin/env bash
set -euo pipefail
# Verify the IBM-aligned MAS install from Argo apps down to MAS/Manage CRs.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

ENVFILE="${1:?usage: verify-install.sh <path/to/cluster.env>}"
[[ -f "$ENVFILE" ]] || { echo "ERROR: env file not found: $ENVFILE" >&2; exit 2; }

# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"; : "${WORKSPACE_ID:?}"
CORE_NS="mas-${INSTANCE_ID}-core"
MANAGE_NS="mas-${INSTANCE_ID}-manage"
DRO_NS="${DRO_NAMESPACE:-ibm-software-central}"
fail=0

ok(){ printf '  PASS  %s\n' "$1"; }
no(){ printf '  FAIL  %s\n' "$1"; fail=1; }
warn(){ printf '  WARN  %s\n' "$1"; }

app_clean() {
  local app="${1:?app name}" sync="" health="" op=""
  sync="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  op="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
  if [[ "$sync" == "Synced" && "$health" == "Healthy" && "$op" != "Failed" ]]; then
    ok "application/$app Synced/Healthy"
  else
    no "application/$app sync=${sync:-missing} health=${health:-missing} op=${op:-none}"
    print_app_diagnostics "$app" || true
  fi
}

resource_ready_check() {
  local resource="${1:?resource}" name="${2:?name}" namespace="${3:?namespace}" status=""
  status="$(resource_status "$resource" "$name" "$namespace")"
  [[ "$status" == "Ready" ]] && ok "$namespace/$resource/$name Ready" || no "$namespace/$resource/$name status=${status:-missing}"
}

csv_contains() {
  local namespace="${1:?namespace}" pattern="${2:?pattern}" label="${3:?label}"
  if oc get csv -n "$namespace" --no-headers 2>/dev/null | awk '{print $1}' | grep -Eq "$pattern"; then
    ok "$label"
  else
    warn "$label not found; current CSVs: $(oc get csv -n "$namespace" --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  fi
}

echo "== Argo CD applications =="
for app in \
  "platform-${CLUSTER_ID}" \
  "ibm-mas-account-root" \
  "suite.${CLUSTER_ID}.${INSTANCE_ID}" \
  "${INSTANCE_ID}-jdbc-system" \
  "${INSTANCE_ID}-bas-system.${CLUSTER_ID}" \
  "manage.${CLUSTER_ID}.${INSTANCE_ID}" \
  "${WORKSPACE_ID}.manage.${CLUSTER_ID}.${INSTANCE_ID}"; do
  app_clean "$app"
done

echo
echo "== MAS system config CRs =="
resource_ready_check mongocfgs.config.mas.ibm.com "${INSTANCE_ID}-mongo-system" "$CORE_NS"
resource_ready_check slscfgs.config.mas.ibm.com "${INSTANCE_ID}-sls-system" "$CORE_NS"
resource_ready_check jdbccfgs.config.mas.ibm.com "${INSTANCE_ID}-jdbc-system" "$CORE_NS"
resource_ready_check bascfgs.config.mas.ibm.com "${INSTANCE_ID}-bas-system" "$CORE_NS"
resource_ready_check suite "$INSTANCE_ID" "$CORE_NS"

echo
echo "== Manage =="
resource_ready_check manageapps.apps.mas.ibm.com "$INSTANCE_ID" "$MANAGE_NS"
resource_ready_check manageworkspaces.apps.mas.ibm.com "${INSTANCE_ID}-${WORKSPACE_ID}" "$MANAGE_NS"
oc get secret "${WORKSPACE_ID}-manage-encryptionsecret" -n "$MANAGE_NS" -o jsonpath='{.data}' 2>/dev/null | grep -q . \
  && ok "${MANAGE_NS}/secret/${WORKSPACE_ID}-manage-encryptionsecret contains data" \
  || no "${MANAGE_NS}/secret/${WORKSPACE_ID}-manage-encryptionsecret missing data"

echo
echo "== DRO/BAS =="
oc get ns "$DRO_NS" >/dev/null 2>&1 && ok "namespace/$DRO_NS exists" || no "namespace/$DRO_NS missing"
oc get route -n "$DRO_NS" 2>/dev/null | grep -qiE 'data-reporter|dro' && ok "DRO route exists" || no "DRO route missing"

echo
echo "== Target versions =="
csv_contains "$CORE_NS" "ibm-mas.*8\\.11\\.26|ibm-mas\\.v8\\.11\\.26" "MAS target ${MAS_TARGET_VERSION:-8.11.26}"
csv_contains "$MANAGE_NS" "ibm-mas-manage.*8\\.7\\.24|ibm-mas-manage\\.v8\\.7\\.24" "Manage target ${MANAGE_TARGET_VERSION:-8.7.24}"

echo
if [[ "$fail" -eq 0 ]]; then
  echo "VERIFY-INSTALL: passed."
else
  echo "VERIFY-INSTALL: failures above."
  exit 1
fi
