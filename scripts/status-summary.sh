#!/usr/bin/env bash
set -euo pipefail
ENVFILE="${1:?usage: status-summary.sh <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
WORKSPACE_ID="${WORKSPACE_ID:-}"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
MONGO_NS="${MONGO_NS:?MONGO_NS must be set in the env file; it MUST equal gitops/envs/<cluster>/values.yaml mongo.namespace}"
MONGO_CR="${MONGO_CR:-${INSTANCE_ID}-mongo}"
DRO_NS="${DRO_NAMESPACE:-ibm-software-central}"
CORE_NS="mas-${INSTANCE_ID}-core"

echo "== Argo CD Applications =="
oc get application -n "$ARGO_NS" \
  "platform-${CLUSTER_ID}" \
  "mongodb-community-operator-${INSTANCE_ID}" \
  "mongodb-ce-${INSTANCE_ID}" \
  "vault-sync-mongo-${INSTANCE_ID}" \
  "ibm-mas-account-root" \
  "${INSTANCE_ID}-jdbc-system" \
  "${INSTANCE_ID}-bas-system.${CLUSTER_ID}" \
  "vault-sync-sls-${INSTANCE_ID}" \
  "vault-sync-dro-${INSTANCE_ID}" \
  "suite.${CLUSTER_ID}.${INSTANCE_ID}" \
  "manage.${CLUSTER_ID}.${INSTANCE_ID}" \
  "${WORKSPACE_ID}.manage.${CLUSTER_ID}.${INSTANCE_ID}" \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,OP:.status.operationState.phase 2>/dev/null || true

echo
echo "== Argo CD Applications needing attention =="
oc get application -n "$ARGO_NS" \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,OP:.status.operationState.phase \
  | awk 'NR==1 || $2!="Synced" || $3!="Healthy" || $4=="Failed"' || true

echo
echo "== Vault =="
oc get pods -n vault 2>/dev/null || true

echo
echo "== Mongo =="
oc get mongodbcommunity "$MONGO_CR" -n "$MONGO_NS" 2>/dev/null || true
oc get pods -n "$MONGO_NS" 2>/dev/null || true

echo
echo "== MAS namespaces =="
oc get ns 2>/dev/null | grep -E "mas-${INSTANCE_ID}|${MONGO_NS}|${DRO_NS}" || true

echo
echo "== MAS API resources present =="
oc api-resources 2>/dev/null | grep -Ei 'suites|manageapps|manageworkspaces|mongocfgs|jdbccfgs|slscfgs|bascfgs|licenseservices' || true

echo
echo "== MAS system configs =="
oc get mongocfgs,slscfgs,jdbccfgs,bascfgs -n "$CORE_NS" 2>/dev/null || true

echo
echo "== Suite =="
oc get suite "$INSTANCE_ID" -n "$CORE_NS" 2>/dev/null || true
oc get suite "$INSTANCE_ID" -n "$CORE_NS" -o yaml 2>/dev/null | \
  grep -iA6 -B2 'BasIntegrationReady\|IncompleteConfiguration\|Required condition\|message:\|reason:\|type:' || true

echo
echo "== DRO =="
oc get pods,route -n "$DRO_NS" 2>/dev/null || true

echo
echo "== Manage =="
oc get manageapps,manageworkspaces -A 2>/dev/null || true
oc get pods -n "mas-${INSTANCE_ID}-manage" 2>/dev/null || true
