#!/usr/bin/env bash
set -euo pipefail
# Destructive full cleanup for one platform-gitops cluster/instance.
#
# Deletes Argo CD Applications for the cluster and MAS instance, strips finalizers from
# target namespaces, deletes resources, then deletes namespaces. Vault is preserved unless
# --include-vault is passed.
#
# Usage:
#   ./scripts/delete-gitops-platform.sh --confirm ../mas-gitops-config/envs/drroc4.env
#   ./scripts/delete-gitops-platform.sh --confirm --include-vault ../mas-gitops-config/envs/drroc4.env

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

CONFIRM=0
INCLUDE_VAULT=0
ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM=1; shift ;;
    --include-vault) INCLUDE_VAULT=1; shift ;;
    -h|--help)
      sed -n '1,13p' "$0"
      exit 0
      ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: delete-gitops-platform.sh --confirm <path/to/cluster.env>}"
[[ -f "$ENVFILE" ]] || { echo "ERROR: env file not found: $ENVFILE" >&2; exit 2; }

# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
MONGO_NS="${MONGO_NS:-mongo-${INSTANCE_ID}}"
DRO_NAMESPACE="${DRO_NAMESPACE:-ibm-software-central}"

if [[ "$CONFIRM" != "1" ]]; then
  cat <<MSG
Dry run only. Nothing was deleted.

Will delete GitOps platform/instance resources for:
  cluster:  $CLUSTER_ID
  instance: $INSTANCE_ID
  mongo ns: $MONGO_NS
  DRO ns:   $DRO_NAMESPACE

Vault is preserved unless --include-vault is passed.
MSG
  exit 0
fi

TARGET_NAMESPACES=(
  "mas-${INSTANCE_ID}-core"
  "mas-${INSTANCE_ID}-manage"
  "mas-${INSTANCE_ID}-sls"
  "mas-${INSTANCE_ID}-syncres"
  "$MONGO_NS"
  "$DRO_NAMESPACE"
)
[[ "$INCLUDE_VAULT" == "1" ]] && TARGET_NAMESPACES+=("vault")

say(){ printf '\n=== %s ===\n' "$*"; }

CONTROLLER_SCALE_FILE="$(mktemp)"
cleanup(){
  if [[ -s "$CONTROLLER_SCALE_FILE" ]]; then
    say "Restoring OpenShift GitOps controllers"
    while read -r kind name replicas; do
      [[ -n "$kind" && -n "$name" && -n "$replicas" ]] || continue
      oc scale "$kind/$name" -n "$ARGO_NS" --replicas="$replicas" >/dev/null 2>&1 || true
    done < "$CONTROLLER_SCALE_FILE"
  fi
  rm -f "$CONTROLLER_SCALE_FILE"
}
trap cleanup EXIT

pause_argocd_controllers(){
  echo ">> pausing Application and ApplicationSet controllers so resources cannot be recreated"
  oc get deploy,statefulset -n "$ARGO_NS" -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
    | while read -r kind name replicas; do
        [[ -n "$kind" && -n "$name" ]] || continue
        case "$name" in
          *application-controller*|*applicationset-controller*)
            echo "${kind,,} $name ${replicas:-1}" >> "$CONTROLLER_SCALE_FILE"
            oc scale "${kind,,}/$name" -n "$ARGO_NS" --replicas=0 >/dev/null 2>&1 || true
            ;;
        esac
      done
}

app_matches(){
  local name="$1"
  [[ "$name" == "platform-${CLUSTER_ID}" ]] && return 0
  [[ "$name" == "hashicorp-vault-server" && "$INCLUDE_VAULT" == "1" ]] && return 0
  [[ "$name" == *"${CLUSTER_ID}"* ]] && return 0
  [[ "$name" == *"${INSTANCE_ID}"* ]] && return 0
  [[ "$name" == *"${MONGO_NS}"* ]] && return 0
  [[ "$name" == *"${DRO_NAMESPACE}"* ]] && return 0
  return 1
}

matching_apps(){
  oc get applications -n "$ARGO_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r name; do
        [[ -n "$name" ]] || continue
        app_matches "$name" && echo "$name"
      done
}

matching_appsets(){
  oc get applicationsets.argoproj.io -n "$ARGO_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r name; do
        [[ -n "$name" ]] || continue
        app_matches "$name" && echo "$name"
      done
}

delete_matching_appsets(){
  local name
  while read -r name; do
    [[ -n "$name" ]] || continue
    echo ">> deleting applicationset/$name"
    oc patch applicationset "$name" -n "$ARGO_NS" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    oc delete applicationset "$name" -n "$ARGO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done < <(matching_appsets)
}

delete_app_cascade(){
  local name="$1"
  echo ">> cascade deleting application/$name"
  if command -v argocd >/dev/null 2>&1; then
    argocd app terminate-op "$name" >/dev/null 2>&1 || true
    argocd app delete "$name" --cascade --propagation-policy background --yes >/dev/null 2>&1 && return 0
  fi

  oc patch application "$name" -n "$ARGO_NS" --type=merge \
    -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io/background"]}}' >/dev/null 2>&1 || true
  oc delete application "$name" -n "$ARGO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

force_delete_app(){
  local name="$1"
  echo ">> force deleting stuck application/$name"
  oc patch application "$name" -n "$ARGO_NS" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  oc delete application "$name" -n "$ARGO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

delete_matching_apps_once(){
  local deleted=0 name
  while read -r name; do
    [[ -n "$name" ]] || continue
    delete_app_cascade "$name"
    deleted=1
  done < <(matching_apps)
  [[ "$deleted" == "1" ]]
}

force_delete_matching_apps_once(){
  local deleted=0 name
  while read -r name; do
    [[ -n "$name" ]] || continue
    force_delete_app "$name"
    deleted=1
  done < <(matching_apps)
  [[ "$deleted" == "1" ]]
}

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
  oc patch ns "$namespace" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
}

finalize_namespace(){
  local namespace="$1"
  oc get ns "$namespace" >/dev/null 2>&1 || return 0
  oc patch ns "$namespace" --type=json -p='[{"op":"remove","path":"/spec/finalizers"}]' >/dev/null 2>&1 || true
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

say "1. Stop Argo CD reconciliation"
pause_argocd_controllers
delete_matching_appsets
for _ in $(seq 1 6); do
  if delete_matching_apps_once; then
    sleep 10
  else
    break
  fi
done

if [[ -n "$(matching_apps)" ]]; then
  echo ">> some Applications are still present; forcing Application finalizer removal"
  for _ in $(seq 1 3); do
    if force_delete_matching_apps_once; then
      sleep 5
    else
      break
    fi
  done
fi

say "2. Remove finalizers from MAS and platform resources"
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
  patch_finalizers_in_namespace "$ns"
done

say "3. Delete all resources before deleting namespaces"
for ns in "${TARGET_NAMESPACES[@]}"; do
  delete_all_in_namespace "$ns"
done

say "4. Delete target namespaces"
for ns in "${TARGET_NAMESPACES[@]}"; do
  if oc get ns "$ns" >/dev/null 2>&1; then
    echo ">> deleting namespace/$ns"
    oc patch ns "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    finalize_namespace "$ns"
    oc delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
done

say "5. Verification"
remaining_apps="$(oc get applications -n "$ARGO_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E "(${CLUSTER_ID}|${INSTANCE_ID}|${MONGO_NS}|${DRO_NAMESPACE}|hashicorp-vault-server)" || true)"
if [[ -n "$remaining_apps" ]]; then
  echo "Remaining matching Argo CD Applications:"
  echo "$remaining_apps"
else
  echo "No matching Argo CD Applications"
fi

remaining_ns="$(oc get ns 2>/dev/null | grep -E "mas-${INSTANCE_ID}|${MONGO_NS}|${DRO_NAMESPACE}|vault" || true)"
if [[ -n "$remaining_ns" ]]; then
  echo "Remaining matching namespaces:"
  echo "$remaining_ns"
else
  echo "No matching namespaces"
fi

remaining_crs="$(oc get suite,manageapp,manageworkspace,jdbccfg,slscfg,mongocfg,bascfg -A 2>/dev/null | grep "$INSTANCE_ID" || true)"
if [[ -n "$remaining_crs" ]]; then
  echo "Remaining matching MAS CRs:"
  echo "$remaining_crs"
else
  echo "No matching MAS CRs"
fi

cat <<MSG

If anything remains Terminating, wait 1-2 minutes and rerun this script.
MSG
