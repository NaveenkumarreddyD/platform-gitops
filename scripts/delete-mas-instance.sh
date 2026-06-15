#!/usr/bin/env bash
set -euo pipefail
# Delete one MAS GitOps instance safely.
#
# This intentionally leaves Vault, OpenShift GitOps, AVP, cert-manager, and shared operators alone.
# By default it deletes only the MAS instance namespaces and Argo CD Applications for the instance.
#
# Usage:
#   ./scripts/delete-mas-instance.sh --confirm ../mas-gitops-config/envs/drroc4.env
#   ./scripts/delete-mas-instance.sh --confirm --include-mongo ../mas-gitops-config/envs/drroc4.env
#   ./scripts/delete-mas-instance.sh --confirm --include-mongo --include-dro ../mas-gitops-config/envs/drroc4.env

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

CONFIRM=0
INCLUDE_MONGO=0
INCLUDE_DRO=0
ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM=1; shift ;;
    --include-mongo) INCLUDE_MONGO=1; shift ;;
    --include-dro) INCLUDE_DRO=1; shift ;;
    -h|--help)
      sed -n '1,14p' "$0"
      exit 0
      ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: delete-mas-instance.sh --confirm <path/to/cluster.env>}"
[[ -f "$ENVFILE" ]] || { echo "ERROR: env file not found: $ENVFILE" >&2; exit 2; }

# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
MONGO_NS="${MONGO_NS:-mongo-${INSTANCE_ID}}"
DRO_NAMESPACE="${DRO_NAMESPACE:-ibm-software-central}"

if [[ "$CONFIRM" != "1" ]]; then
  cat <<MSG
Dry run only. Nothing was deleted.

Will target instance:
  cluster:  $CLUSTER_ID
  instance: $INSTANCE_ID

Run with --confirm to delete MAS instance resources.
Add --include-mongo to delete dedicated Mongo namespace: $MONGO_NS
Add --include-dro only if DRO is dedicated to this instance: $DRO_NAMESPACE
MSG
  exit 0
fi

TARGET_NAMESPACES=(
  "mas-${INSTANCE_ID}-core"
  "mas-${INSTANCE_ID}-manage"
  "mas-${INSTANCE_ID}-sls"
  "mas-${INSTANCE_ID}-syncres"
)
[[ "$INCLUDE_MONGO" == "1" ]] && TARGET_NAMESPACES+=("$MONGO_NS")
[[ "$INCLUDE_DRO" == "1" ]] && TARGET_NAMESPACES+=("$DRO_NAMESPACE")

say(){ printf '\n=== %s ===\n' "$*"; }

patch_finalizers_for_resource(){
  local resource="$1" namespace="$2"
  oc get "$resource" -n "$namespace" -o name 2>/dev/null | while read -r obj; do
    [[ -n "$obj" ]] || continue
    oc patch "$obj" -n "$namespace" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  done
}

patch_finalizers_in_namespace(){
  local namespace="$1"
  oc get ns "$namespace" >/dev/null 2>&1 || return 0
  echo ">> removing finalizers in namespace/$namespace"
  while read -r resource; do
    [[ -n "$resource" ]] || continue
    patch_finalizers_for_resource "$resource" "$namespace"
  done < <(oc api-resources --verbs=list --namespaced -o name 2>/dev/null)
}

delete_all_in_namespace(){
  local namespace="$1"
  oc get ns "$namespace" >/dev/null 2>&1 || return 0
  echo ">> deleting namespaced resources in namespace/$namespace"
  while read -r resource; do
    [[ -n "$resource" ]] || continue
    oc delete "$resource" --all -n "$namespace" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done < <(oc api-resources --verbs=list --namespaced -o name 2>/dev/null)
}

say "1. Stop Argo CD from reconciling this instance"
oc get applications -n "$ARGO_NS" -o name 2>/dev/null \
  | grep -E "(${INSTANCE_ID}|${CLUSTER_ID}\\.${INSTANCE_ID}|${INSTANCE_ID}\\.${CLUSTER_ID}|${CLUSTER_ID}.*${INSTANCE_ID}|${MONGO_NS})" \
  | sort -u \
  | while read -r app; do
      name="${app#application.argoproj.io/}"
      echo ">> deleting application/$name"
      oc patch "$app" -n "$ARGO_NS" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      oc delete "$app" -n "$ARGO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done

if [[ "$INCLUDE_DRO" == "1" ]]; then
  oc get applications -n "$ARGO_NS" -o name 2>/dev/null \
    | grep -E "(dro\\.${CLUSTER_ID}|ibm-dro|${DRO_NAMESPACE})" \
    | sort -u \
    | while read -r app; do
        name="${app#application.argoproj.io/}"
        echo ">> deleting DRO application/$name"
        oc patch "$app" -n "$ARGO_NS" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        oc delete "$app" -n "$ARGO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
      done
fi

say "2. Remove MAS CR finalizers"
for ns in "${TARGET_NAMESPACES[@]}"; do
  oc get ns "$ns" >/dev/null 2>&1 || continue
  for resource in \
    suite.core.mas.ibm.com \
    manageapp.apps.mas.ibm.com \
    manageworkspace.apps.mas.ibm.com \
    jdbccfg.config.mas.ibm.com \
    slscfg.config.mas.ibm.com \
    mongocfg.config.mas.ibm.com \
    bascfg.config.mas.ibm.com \
    licenseservice.sls.ibm.com \
    mongodbcommunity.mongodbcommunity.mongodb.com; do
    patch_finalizers_for_resource "$resource" "$ns"
  done
done

say "3. Remove finalizers from all remaining namespaced resources"
for ns in "${TARGET_NAMESPACES[@]}"; do
  patch_finalizers_in_namespace "$ns"
done

say "4. Delete all resources before deleting namespaces"
for ns in "${TARGET_NAMESPACES[@]}"; do
  delete_all_in_namespace "$ns"
done

say "5. Delete target namespaces"
for ns in "${TARGET_NAMESPACES[@]}"; do
  if oc get ns "$ns" >/dev/null 2>&1; then
    echo ">> deleting namespace/$ns"
    oc patch ns "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    oc delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
done

say "6. Current status"
oc get applications -n "$ARGO_NS" 2>/dev/null | grep -E "${INSTANCE_ID}|${MONGO_NS}|${DRO_NAMESPACE}" || echo "No matching Argo CD Applications"
oc get ns 2>/dev/null | grep -E "mas-${INSTANCE_ID}|${MONGO_NS}|${DRO_NAMESPACE}" || echo "No matching namespaces"
oc get suite,manageapp,manageworkspace,jdbccfg,slscfg,mongocfg,bascfg -A 2>/dev/null | grep "$INSTANCE_ID" || echo "No matching MAS CRs"

cat <<MSG

If any namespace remains Terminating, wait 1-2 minutes and rerun the same command.
Do not delete Vault for a MAS/Manage recreate.
MSG
