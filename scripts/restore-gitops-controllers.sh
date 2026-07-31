#!/usr/bin/env bash
set -euo pipefail
# Restore the OpenShift GitOps controllers if a teardown left them paused (e.g. delete-fast.sh
# was hard-killed before its restore trap ran). delete-fast.sh pauses Argo CD TWO ways:
#   1. patches the ArgoCD CR (spec.controller.replicas / spec.applicationSet.replicas = 0)
#   2. oc-scales the controller Deployments/StatefulSets to 0
# The OpenShift GitOps operator RE-PINS the workload replicas from the ArgoCD CR, so a plain
# `oc scale` is reverted within seconds. This script therefore restores the ArgoCD CR FIRST,
# then scales the workloads, then waits for them to be Ready.
#
#   ./scripts/restore-gitops-controllers.sh                 # restore to replicas=1
#   ./scripts/restore-gitops-controllers.sh --replicas 2    # force a specific count
#   ARGO_NS=openshift-gitops ./scripts/restore-gitops-controllers.sh
#
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"   # provides ARGO_NS (default openshift-gitops)

REPLICAS=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --replicas) REPLICAS="${2:?--replicas needs a number}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "ignoring unexpected arg: $1" >&2; shift ;;
  esac
done

oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged in (oc login ...)" >&2; exit 1; }
oc get ns "$ARGO_NS" >/dev/null 2>&1 || { echo "ERROR: namespace/$ARGO_NS not found" >&2; exit 1; }

# 1. Restore the ArgoCD CR replicas FIRST (this is what the operator honors; without it the
#    operator scales the workloads back to 0 no matter what `oc scale` does below).
ARGOCD_CR="$(oc get argocd -n "$ARGO_NS" -o name 2>/dev/null | head -1)"
if [[ -n "$ARGOCD_CR" ]]; then
  echo ">> restoring $ARGOCD_CR: controller.replicas=$REPLICAS, applicationSet.replicas=$REPLICAS"
  oc patch "$ARGOCD_CR" -n "$ARGO_NS" --type=merge \
    -p "{\"spec\":{\"controller\":{\"replicas\":$REPLICAS},\"applicationSet\":{\"replicas\":$REPLICAS}}}" >/dev/null 2>&1 \
    || echo "   WARN: could not patch $ARGOCD_CR (continuing with oc scale)"
else
  echo ">> no ArgoCD CR found in $ARGO_NS; relying on oc scale only"
fi

# 2. Discover the controller workloads and scale them (belt-and-suspenders; the operator
#    reconciles them from the CR above, but this makes the restore immediate).
declare -a TARGETS=()   # "kind name"
while read -r kind name _; do
  [[ -n "$kind" && -n "$name" ]] || continue
  TARGETS+=("${kind,,} $name")
done < <(oc get deploy,statefulset -n "$ARGO_NS" \
          -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
          | grep -E 'application-controller|applicationset-controller')

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "NOTE: no application-controller/applicationset-controller workloads found yet."
  echo "      The operator will recreate them from the restored ArgoCD CR — re-check with:"
  echo "        oc get pods -n $ARGO_NS | grep -E 'application(set)?-controller'"
  exit 0
fi

for t in "${TARGETS[@]}"; do
  read -r kind name <<<"$t"
  echo ">> scaling $kind/$name -> replicas=$REPLICAS"
  oc scale "$kind/$name" -n "$ARGO_NS" --replicas="$REPLICAS" >/dev/null 2>&1 || true
done

echo ">> waiting up to 120s for controllers to become ready"
ok=1
for t in "${TARGETS[@]}"; do
  read -r kind name <<<"$t"
  [[ "$REPLICAS" -ge 1 ]] || continue
  elapsed=0; ready=0
  while (( elapsed < 120 )); do
    ready="$(oc get "$kind/$name" -n "$ARGO_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    [[ "${ready:-0}" -ge 1 ]] && break
    sleep 5; (( elapsed += 5 ))
  done
  if [[ "${ready:-0}" -ge 1 ]]; then
    echo "   READY  $kind/$name (readyReplicas=$ready)"
  else
    echo "   NOT READY  $kind/$name after 120s (readyReplicas=${ready:-0})"; ok=0
  fi
done

if [[ "$ok" -ne 1 ]]; then
  cat >&2 <<MSG

WARNING: a controller did not come back within 120s. Confirm the ArgoCD CR no longer pins
replicas to 0 and check the operator:
  oc get $ARGOCD_CR -n $ARGO_NS -o jsonpath='{.spec.controller.replicas}{" "}{.spec.applicationSet.replicas}{"\n"}'
  oc get pods -n $ARGO_NS | grep -E 'application(set)?-controller|gitops-operator'
MSG
  exit 1
fi

echo ">> OpenShift GitOps controllers restored. Argo CD will resume reconciling."
