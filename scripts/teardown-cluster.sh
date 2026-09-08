#!/usr/bin/env bash
# teardown-cluster.sh — clean, ordered teardown of one MAS GitOps instance.
#
# Fixes the two problems that bite a naive "delete the Argo app" teardown:
#   1. ORPHANED CSVs — deleting an Argo Application removes the Subscription but
#      NOT the CSV (OLM owns the CSV, not Argo). The leftover CSV then deadlocks
#      the next install ("clusterserviceversion ... not referenced by a subscription").
#      -> We delete Subscription + its CSV TOGETHER, in the operator's namespace.
#   2. FINALIZER HANGS — MAS/Mongo CRs and namespaces stick in Terminating when the
#      operator is deleted before the CR. -> We delete CRs BEFORE operators, wait,
#      then force-clear finalizers on anything still stuck.
#
# Order (top-down): Argo apps -> MAS CRs -> operators(sub+csv) -> namespaces -> cluster-scoped.
#
# Usage:
#   ./scripts/teardown-cluster.sh <cluster> <instance> [--dry-run] [--yes] [--remove-crds]
# Examples:
#   ./scripts/teardown-cluster.sh drroc4 drgitopsapp --dry-run     # show what WOULD be deleted
#   ./scripts/teardown-cluster.sh drroc4 drgitopsapp               # prompts before deleting
#   ./scripts/teardown-cluster.sh drroc4 drgitopsapp --yes         # no prompt
#
# It NEVER touches shared platform operators (OpenShift GitOps, Pipelines, Dell CSM)
# or the openshift-* namespaces. It only removes this MAS instance's footprint.

set -uo pipefail   # deliberately NOT -e: teardown must continue past "not found"

CLUSTER="${1:?usage: $0 <cluster> <instance> [--dry-run] [--yes] [--remove-crds]}"
INSTANCE="${2:?usage: $0 <cluster> <instance> [--dry-run] [--yes] [--remove-crds]}"
shift 2
DRY=false; YES=false; RM_CRDS=false
for a in "$@"; do case "$a" in
  --dry-run) DRY=true;;
  --yes)     YES=true;;
  --remove-crds) RM_CRDS=true;;
  *) echo "unknown flag: $a"; exit 2;;
esac; done

ARGO_NS=openshift-gitops
WAIT_SECS=90            # how long to let graceful CR deletion run before force-clearing

say(){ echo -e ">> $*"; }
run(){ if $DRY; then echo "   DRY: $*"; else eval "$@"; fi; }

# ---- namespaces owned by THIS instance (auto-discovered + the shared operator ns) ----
mapfile -t INSTANCE_NS < <(oc get ns -o name 2>/dev/null | sed 's#namespace/##' | grep -E "^mas-${INSTANCE}(-|$)")
# Shared operator namespaces this instance created. Remove from this list any that
# other instances on the cluster also use (multi-tenant), so you don't delete theirs.
SHARED_NS=( ibm-software-central mongo-gitops )
ALL_NS=( "${INSTANCE_NS[@]}" "${SHARED_NS[@]}" )

# ---------- helpers ----------
ns_exists(){ oc get ns "$1" >/dev/null 2>&1; }

# Delete every Subscription + its (non-copied) CSV + OperatorGroup in a namespace.
# This is the orphan-proof operator purge: sub and csv go together.
purge_operators(){
  local ns="$1"; ns_exists "$ns" || return 0
  say "purge operators in $ns (subscriptions -> real CSVs -> operatorgroups)"
  local s
  for s in $(oc get subscription -n "$ns" -o name 2>/dev/null); do
    run "oc delete $s -n $ns --ignore-not-found --wait=false"
  done
  # Only delete CSVs actually installed here — skip OLM-copied CSVs (annotation
  # olm.copiedFrom), which belong to global operators like gitops/pipelines/dell.
  local c
  for c in $(oc get csv -n "$ns" -o json 2>/dev/null \
             | jq -r '.items[] | select(.metadata.annotations["olm.copiedFrom"]==null) | .metadata.name' 2>/dev/null); do
    run "oc delete csv $c -n $ns --ignore-not-found --wait=false"
  done
  local og
  for og in $(oc get operatorgroup -n "$ns" -o name 2>/dev/null); do
    run "oc delete $og -n $ns --ignore-not-found --wait=false"
  done
}

# Force-clear finalizers on every object of a kind in a namespace (unstick Terminating).
unstick_kind(){
  local kind="$1" ns="$2"; ns_exists "$ns" || return 0
  local o
  for o in $(oc get "$kind" -n "$ns" -o name 2>/dev/null); do
    run "oc patch $o -n $ns --type=merge -p '{\"metadata\":{\"finalizers\":null}}' 2>/dev/null || true"
  done
}

# ---------- preview ----------
say "TARGET: cluster=$CLUSTER instance=$INSTANCE  (dry-run=$DRY)"
say "Namespaces to remove:"
printf '     %s\n' "${ALL_NS[@]:-<none found>}"
say "Argo apps to remove:"
oc get applications -n "$ARGO_NS" -o name 2>/dev/null | grep -E "(^|/).*($CLUSTER|account-root)" | sed 's/^/     /' || true
echo
if ! $DRY && ! $YES; then
  read -r -p "Type the cluster name '$CLUSTER' to confirm teardown: " ans
  [[ "$ans" == "$CLUSTER" ]] || { echo "aborted."; exit 1; }
fi

# ================= PHASE 1 — stop Argo CD recreating anything =================
# Strip the resources-finalizer so the app deletes instantly WITHOUT cascade
# (we tear resources down ourselves, in order). Then delete the app object.
say "PHASE 1: delete Argo CD applications for $CLUSTER (no cascade)"
for app in $(oc get applications -n "$ARGO_NS" -o name 2>/dev/null | grep -E "(^|/).*($CLUSTER|account-root)"); do
  run "oc patch $app -n $ARGO_NS --type=merge -p '{\"metadata\":{\"finalizers\":null}}' 2>/dev/null || true"
  run "oc delete $app -n $ARGO_NS --ignore-not-found --wait=false"
done

# ================= PHASE 2 — delete MAS CRs (operators still alive) =================
# Leaf -> root, so each controller can run its own cleanup before we remove it.
say "PHASE 2: delete MAS custom resources (leaf -> root)"
CR_KINDS=(
  manageworkspace.apps.mas.ibm.com
  manageapp.apps.mas.ibm.com
  iotworkspace.apps.mas.ibm.com
  monitorworkspace.apps.mas.ibm.com
  workspace.core.mas.ibm.com
  suite.core.mas.ibm.com
  licenseservice.sls.ibm.com
  datareporter.apps.ibm.com
  mongodbcommunity.mongodbcommunity.mongodb.com
)
for kind in "${CR_KINDS[@]}"; do
  for ns in "${ALL_NS[@]}"; do
    ns_exists "$ns" || continue
    for o in $(oc get "$kind" -n "$ns" -o name 2>/dev/null); do
      run "oc delete $o -n $ns --ignore-not-found --wait=false"
    done
  done
done

# give the controllers time to finish, then force-clear anything still Terminating
say "PHASE 2b: wait ${WAIT_SECS}s, then force-clear stuck CR finalizers"
$DRY || sleep "$WAIT_SECS"
for kind in "${CR_KINDS[@]}"; do
  for ns in "${ALL_NS[@]}"; do unstick_kind "$kind" "$ns"; done
done

# ================= PHASE 3 — operators (sub + csv together = no orphans) =================
say "PHASE 3: purge operators (orphan-proof: subscription + CSV together)"
for ns in "${ALL_NS[@]}"; do purge_operators "$ns"; done

# ================= PHASE 4 — namespaces =================
say "PHASE 4: delete namespaces"
for ns in "${ALL_NS[@]}"; do
  ns_exists "$ns" || continue
  run "oc delete ns $ns --ignore-not-found --wait=false"
done
say "PHASE 4b: wait ${WAIT_SECS}s, then force-clear namespaces stuck Terminating"
$DRY || sleep "$WAIT_SECS"
for ns in "${ALL_NS[@]}"; do
  ns_exists "$ns" || continue
  if [[ "$(oc get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Terminating" ]]; then
    # clear both metadata AND spec finalizers (the "kubernetes" spec finalizer needs the /finalize subresource)
    run "oc patch ns $ns --type=merge -p '{\"metadata\":{\"finalizers\":null}}' 2>/dev/null || true"
    run "oc get ns $ns -o json 2>/dev/null | jq 'del(.spec.finalizers)' | oc replace --raw \"/api/v1/namespaces/$ns/finalize\" -f - >/dev/null 2>&1 || true"
  fi
done

# ================= PHASE 5 — cluster-scoped leftovers =================
say "PHASE 5: sweep cluster-scoped objects for this instance"
# DRO/metrics ClusterRoleBindings (safe, MAS-specific names)
for crb in manager-cluster-monitoring-binding metric-state-view-binding reporter-cluster-monitoring-binding; do
  run "oc delete clusterrolebinding $crb --ignore-not-found"
done
# Anything MAS labelled with this instance (CRBs, ClusterRoles, ClusterIssuers, webhooks)
for kind in clusterrolebinding clusterrole clusterissuer.cert-manager.io \
            validatingwebhookconfiguration mutatingwebhookconfiguration; do
  for o in $(oc get "$kind" -l "mas.ibm.com/instanceId=${INSTANCE}" -o name 2>/dev/null); do
    run "oc delete $o --ignore-not-found"
  done
done

# ================= PHASE 6 — optional: remove CRDs (pristine cluster) =================
if $RM_CRDS; then
  say "PHASE 6: remove MAS/Mongo/DRO CRDs (--remove-crds)"
  for crd in $(oc get crd -o name 2>/dev/null | grep -E 'mas\.ibm\.com|sls\.ibm\.com|apps\.ibm\.com|mongodbcommunity\.mongodb\.com'); do
    run "oc patch $crd --type=merge -p '{\"metadata\":{\"finalizers\":null}}' 2>/dev/null || true"
    run "oc delete $crd --ignore-not-found"
  done
fi

# ================= VERIFY — prove there are no orphans / leftovers =================
say "VERIFY: leftovers that would break the next install"
echo "  -- namespaces still present:"
for ns in "${ALL_NS[@]}"; do ns_exists "$ns" && echo "     STILL HERE: $ns"; done
echo "  -- orphaned CSVs (CSV with no owning Subscription) cluster-wide:"
if command -v jq >/dev/null 2>&1; then
  oc get csv -A -o json 2>/dev/null | jq -r '
    .items[]
    | select((.metadata.annotations["olm.copiedFrom"]) == null)
    | select((.metadata.ownerReferences // []) | length == 0)
    | "     ORPHAN: \(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null | grep -E 'data-reporter|metrics|ibm-mas|ibm-sls|mongodb' || echo "     (none for MAS/Mongo/DRO)"
fi
say "done."
