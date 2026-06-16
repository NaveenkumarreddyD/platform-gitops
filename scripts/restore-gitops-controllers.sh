#!/usr/bin/env bash
set -euo pipefail
# Restore the OpenShift GitOps controllers that delete-gitops-platform.sh paused
# (when run with --leave-controllers-paused). Scales the application-controller and
# applicationset-controller back to their original replica counts, waits for them to
# become ready, and warns if the GitOps operator is pinning them back to 0.
#
#   ./scripts/restore-gitops-controllers.sh                 # restore from saved state, or default to 1
#   ./scripts/restore-gitops-controllers.sh --replicas 1    # force a replica count
#   ARGO_NS=openshift-gitops ./scripts/restore-gitops-controllers.sh
#
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"   # provides ARGO_NS (default openshift-gitops)

FORCE_REPLICAS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --replicas) FORCE_REPLICAS="${2:?--replicas needs a number}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "ignoring unexpected arg: $1" >&2; shift ;;
  esac
done

STATE_DIR="$ROOT/.install-state"
SCALE_FILE="$STATE_DIR/gitops-controllers.scale"

oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged in (oc login ...)" >&2; exit 1; }
oc get ns "$ARGO_NS" >/dev/null 2>&1 || { echo "ERROR: namespace/$ARGO_NS not found" >&2; exit 1; }

scale_to() { # kind name replicas
  local kind="$1" name="$2" replicas="$3"
  oc get "$kind/$name" -n "$ARGO_NS" >/dev/null 2>&1 || { echo "   (skip: $kind/$name not found)"; return 0; }
  echo ">> scaling $kind/$name -> replicas=$replicas"
  oc scale "$kind/$name" -n "$ARGO_NS" --replicas="$replicas" >/dev/null 2>&1 || true
}

declare -a TARGETS=()   # "kind name replicas"

if [[ -n "$FORCE_REPLICAS" ]]; then
  # discover the controllers and force the given count
  while read -r kind name _; do
    [[ -n "$kind" && -n "$name" ]] || continue
    TARGETS+=("${kind,,} $name $FORCE_REPLICAS")
  done < <(oc get deploy,statefulset -n "$ARGO_NS" \
            -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
            | grep -E 'application-controller|applicationset-controller')
elif [[ -s "$SCALE_FILE" ]]; then
  echo ">> restoring from saved state: $SCALE_FILE"
  while read -r kind name replicas; do
    [[ -n "$kind" && -n "$name" ]] || continue
    TARGETS+=("$kind $name ${replicas:-1}")
  done < "$SCALE_FILE"
else
  echo ">> no saved state file; discovering controllers and restoring to replicas=1"
  while read -r kind name _; do
    [[ -n "$kind" && -n "$name" ]] || continue
    TARGETS+=("${kind,,} $name 1")
  done < <(oc get deploy,statefulset -n "$ARGO_NS" \
            -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
            | grep -E 'application-controller|applicationset-controller')
fi

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "ERROR: found no application-controller/applicationset-controller workloads in $ARGO_NS." >&2
  echo "       If they were paused via the ArgoCD CR, edit it instead:" >&2
  echo "         oc edit argocd -n $ARGO_NS   # set controller/applicationSet replicas back" >&2
  exit 1
fi

for t in "${TARGETS[@]}"; do
  # shellcheck disable=SC2086
  scale_to $t
done

echo ">> waiting up to 120s for controllers to become ready"
ok=1
for t in "${TARGETS[@]}"; do
  read -r kind name replicas <<<"$t"
  [[ "${replicas:-1}" -ge 1 ]] || continue
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

WARNING: a controller did not come back. The OpenShift GitOps operator likely pins the
replica count via the ArgoCD CR, so 'oc scale' gets reverted. Set it in the CR instead:
  oc edit argocd -n $ARGO_NS
  # restore: spec.controller.replicas and spec.applicationSet.replicas (or remove the 0 override)
MSG
  exit 1
fi

# success: drop the saved state so it isn't reused
rm -f "$SCALE_FILE" 2>/dev/null || true
echo ">> OpenShift GitOps controllers restored. Argo CD will resume reconciling."
