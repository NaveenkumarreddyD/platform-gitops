#!/usr/bin/env bash
set -euo pipefail
ENVFILE="${1:?usage: status-summary.sh <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
MONGO_NS="${MONGO_NS:?MONGO_NS must be set in the env file; it MUST equal gitops/envs/<cluster>/values.yaml mongo.namespace}"
MONGO_CR="${MONGO_CR:-${INSTANCE_ID}-mongo}"

echo "== Argo CD Applications =="
oc get application -n "$ARGO_NS" \
  "platform-${CLUSTER_ID}" \
  "mongodb-community-operator-${INSTANCE_ID}" \
  "mongodb-ce-${INSTANCE_ID}" \
  "vault-sync-mongo-${INSTANCE_ID}" \
  "ibm-mas-account-root" \
  "${INSTANCE_ID}-jdbc-system" \
  "vault-sync-sls-${INSTANCE_ID}" \
  "vault-sync-dro-${INSTANCE_ID}" \
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
oc get ns 2>/dev/null | grep -E "mas-${INSTANCE_ID}|${MONGO_NS}" || true

echo
echo "== MAS API resources present =="
oc api-resources 2>/dev/null | grep -Ei 'suites|manageapps|manageworkspaces|jdbccfgs|slscfgs|licenseservices' || true
