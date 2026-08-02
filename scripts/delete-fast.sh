#!/usr/bin/env bash
set -euo pipefail
# Teardown of ONE platform-gitops cluster/instance, aligned with the official IBM
# MAS GitOps model:
#   * IBM stamps every generated Application with labels (environment/cluster/instance)
#     and every ApplicationSet with environment=<account>. Selection below uses those
#     LABELS first (name patterns are only a fallback), so apps are found even when
#     names drift — the classic "teardown deleted nothing" failure.
#   * ApplicationSets are deleted BEFORE Applications (an appset left alive regenerates
#     its apps the moment Argo CD resumes).
#   * Official orderly teardown is config-file removal + prune sync + PostDelete hooks
#     (see ibm-gitops/docs/orchestration.md). This script is the FAST path for a full recreate: Argo CD
#     is paused, so PostDelete hooks cannot run — instead the MAS CR finalizers are
#     stripped and the namespaces are removed directly. Do not use it to remove a single
#     app from a running install; remove the config file and prune-sync for that.
#
# Order:
#   1. pause Argo CD DURABLY (ArgoCD CR replicas=0; the operator re-pins plain scale)
#   2. discover + delete ApplicationSets, then Applications (label-selected)
#   3. purge OLM in target namespaces (subs -> installplans -> CSVs -> operatorgroups)
#   4. strip CR finalizers, force-delete pods, clear PVCs (wait), THEN delete namespaces
#   5. sweep orphaned CSVs and cluster-scoped leftovers (catalog, instance RBAC)
#   6. verify by re-querying the same label selectors
# Argo CD controllers are restored on exit.
#
# Usage:
#   ./scripts/delete-fast.sh [--confirm] [--only <comp[,comp]>] [--include-vault] [--include-crds] [--all-mas] <cluster.env | cluster-name>
#   --only <comp,...>  Delete ONLY the named component(s) instead of the whole instance.
#                      Components: vault | mongodb | operators | mas  (comma/space separated).
#                        --only vault          just Vault  (app + namespace + PVCs + reclaimed PVs)
#                        --only mongodb        just the Mongo operator + instance + its namespace
#                        --only mas            just the IBM-generated MAS tree (keeps vault + mongodb)
#                        --only vault,mongodb  both, in one pass
#                      Default (no --only): the full instance = mas + mongodb (+ vault with --include-vault).
#                      Cluster-scoped MAS cleanup (operator catalog, instance RBAC, CRDs) runs
#                      ONLY when 'mas' is in scope, so a --only vault/mongodb run can't touch it.
#   --include-crds ALSO deletes the *.mas.ibm.com / *.sls.ibm.com CRDs. These are cluster-wide and
#   shared by every MAS instance, so they are PRESERVED by default; only pass it when NO other
#   instance uses them (e.g. tearing the whole cluster down). Requires 'mas' in scope.
#   (omit target if CLUSTER_ID/INSTANCE_ID are exported). Without --confirm it is a DRY
#   RUN that queries the cluster and prints exactly what WOULD be deleted.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

usage(){ cat <<'EOF'
delete-fast.sh — fast teardown of one platform-gitops cluster/instance (for a clean recreate).

USAGE
  ./scripts/delete-fast.sh [OPTIONS] <cluster.env | cluster-name>
  (target may be omitted if CLUSTER_ID and INSTANCE_ID are exported)

OPTIONS
  --confirm             Actually delete. Without it, this is a DRY RUN (prints what WOULD go).
  --only <comp[,comp]>  Delete ONLY the named component(s): vault | mongodb | operators | mas
  --include-vault       Also delete Vault (default teardown preserves it). Ignored with --only.
  --include-crds        Also delete the cluster-wide *.mas.ibm.com / *.sls.ibm.com CRDs
                        (only with 'mas' in scope; shared by every instance — preserved by default).
  --all-mas             Discover EVERY MAS instance namespace, not just this one ('mas' scope).
  -h, --help            This help.

EXAMPLES
  ./scripts/delete-fast.sh doc4                        # dry run: full instance (mas + mongodb)
  ./scripts/delete-fast.sh --confirm doc4              # delete the full instance
  ./scripts/delete-fast.sh --only vault --confirm doc4 # tear down ONLY Vault (app + ns + PVCs + PVs)
  ./scripts/delete-fast.sh --only mongodb --confirm doc4
  ./scripts/delete-fast.sh --only vault,mongodb --confirm doc4
  ./scripts/delete-fast.sh --confirm --include-vault --include-crds doc4   # nuke everything

Default (no --only) = mas + mongodb (+ vault with --include-vault). Cluster-scoped MAS cleanup
(operator catalog, instance RBAC, CRDs) runs ONLY when 'mas' is in scope.
EOF
}
CONFIRM=0; INCLUDE_VAULT=0; ALL_MAS=0; INCLUDE_CRDS=0; ONLY=""; ENVARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM=1; shift ;;
    --only) ONLY="${2:?--only needs a component list (vault|mongodb|operators|mas)}"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    --include-vault) INCLUDE_VAULT=1; shift ;;
    --all-mas) ALL_MAS=1; shift ;;   # discover EVERY MAS instance namespace, not just this one
    --include-crds) INCLUDE_CRDS=1; shift ;;   # ALSO delete the MAS CRDs (cluster-wide! removes them for EVERY instance)
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) ENVARG="$1"; shift ;;
  esac
done

# ---- Resolve target from explicit path, bare cluster name, or exported vars ----------
ENVFILE=""
if [[ -n "$ENVARG" && -f "$ENVARG" ]]; then
  ENVFILE="$ENVARG"
elif [[ -n "$ENVARG" ]]; then
  for d in "$ROOT/.." "$ROOT/../.." "$ROOT/../../.."; do
    for repo in mas-gitops-config; do
      [[ -f "$d/$repo/envs/${ENVARG}.env" ]] && { ENVFILE="$d/$repo/envs/${ENVARG}.env"; break 2; }
    done
  done
  [[ -n "$ENVFILE" ]] || { echo "ERROR: no env file found for '$ENVARG'." >&2; exit 2; }
fi
[[ -n "$ENVFILE" ]] && { echo ">> using env: $ENVFILE"; set -a; . "$ENVFILE"; set +a; }
: "${ACCOUNT_ID:=mas}"
: "${CLUSTER_ID:?set CLUSTER_ID or pass a cluster/env}"; : "${INSTANCE_ID:?}"
# Mongo namespace: read it from the SINGLE SOURCE OF TRUTH (platform env values, the same
# mongo.namespace the gitops.mongoNs helper renders) rather than deriving mongo-<instance>,
# which would miss a custom/common name (e.g. mongo-gitops) and orphan the namespace.
if [[ -z "${MONGO_NS:-}" ]]; then
  _pv="$ROOT/gitops/envs/${CLUSTER_ID}/values.yaml"
  MONGO_NS="$(grep -oE 'namespace: *[A-Za-z0-9._-]+' "$_pv" 2>/dev/null | head -1 | sed -E 's/.*: *//')"
  MONGO_NS="${MONGO_NS:-mongo-${INSTANCE_ID}}"   # last-resort fallback if the file/value is absent
fi
DRO_NAMESPACE="${DRO_NAMESPACE:-ibm-software-central}"

# --- Component selection --------------------------------------------------------------
# Default preserves historical behavior: the full instance (mas + its mongodb; vault only with
# --include-vault). --only restricts the teardown to the named component(s), so the same fast/safe
# path (delete the Application FIRST so selfHeal can't resurrect it, then strip finalizers + delete
# the namespace + reclaim its PVs) applies to a single layer too.
if [[ -n "$ONLY" ]]; then
  IFS=', ' read -r -a COMPONENTS <<< "$ONLY"
else
  COMPONENTS=( mas mongodb ); [[ "$INCLUDE_VAULT" == 1 ]] && COMPONENTS+=( vault )
fi
for c in "${COMPONENTS[@]}"; do case "$c" in
  vault|mongodb|operators|mas) ;;
  *) echo "ERROR: unknown component '$c' (want: vault | mongodb | operators | mas)" >&2; exit 2 ;;
esac; done
want_comp(){ local q="$1" c; for c in "${COMPONENTS[@]}"; do [[ "$c" == "$q" ]] && return 0; done; return 1; }

# job-cleaner is IBM's account-level Job GC (chart 000-job-cleaner, fixed ns "job-cleaner")
NS_LIST=()
want_comp mas && NS_LIST+=( "mas-${INSTANCE_ID}-core" "mas-${INSTANCE_ID}-manage" \
          "mas-${INSTANCE_ID}-sls" "mas-${INSTANCE_ID}-syncres" "mas-${INSTANCE_ID}-pipelines" \
          "$DRO_NAMESPACE" "job-cleaner" )
want_comp mongodb   && NS_LIST+=( "$MONGO_NS" )
want_comp vault     && NS_LIST+=( vault )
want_comp operators && NS_LIST+=( cert-manager cert-manager-operator )   # shared infra — only via --only operators
if [[ "$ALL_MAS" == 1 ]] && want_comp mas; then
  while read -r n; do [[ -n "$n" ]] && NS_LIST+=( "$n" ); done \
    < <(oc get ns -o name 2>/dev/null | sed 's#namespace/##' \
        | grep -iE '^mas-|^mongo-|^db2u-|^ibm-sls$|^ibm-software-central$|^job-cleaner$')
fi
# dedupe (portable — avoids `mapfile`, which is absent on bash 3.2 / macOS)
_ns_uniq=(); while IFS= read -r n; do [[ -n "$n" ]] && _ns_uniq+=( "$n" ); done \
  < <(printf '%s\n' "${NS_LIST[@]}" | awk 'NF' | sort -u)
NS_LIST=( "${_ns_uniq[@]}" )

# ---- Discover what actually exists (labels first — the official selectors) -----------
# ApplicationSets: account root stamps environment=<account>; name patterns as fallback.
discover_appsets(){
  { oc get applicationsets -n "$ARGO_NS" -l "environment=${ACCOUNT_ID}" -o name 2>/dev/null
    oc get applicationsets -n "$ARGO_NS" -o name 2>/dev/null \
      | grep -E "appset\.(${ACCOUNT_ID}|${CLUSTER_ID})$|(${CLUSTER_ID}|${INSTANCE_ID})"; } \
    | sed 's#.*/##' | sort -u
}
# Applications per component. IBM-generated MAS apps carry cluster=<clusterId>; the decoupled
# platform components are fixed names (vault, mongodb, mongodb-operator, operators) plus the
# account root ibm-mas-account-root. One env per cluster, so the cluster label is safe.
comp_apps(){
  case "$1" in
    vault)     printf '%s\n' vault ;;
    mongodb)   printf '%s\n' mongodb mongodb-operator ;;
    operators) printf '%s\n' operators ;;
    mas)       { oc get applications -n "$ARGO_NS" -l "cluster=${CLUSTER_ID}" -o name 2>/dev/null
                 oc get applications -n "$ARGO_NS" -o name 2>/dev/null \
                   | grep -E "/ibm-mas-account-root$|${INSTANCE_ID}"; } | sed 's#.*/##' ;;
  esac
}
# Only delete an app that actually exists (keeps the dry-run summary honest).
APPS="$(for c in "${COMPONENTS[@]}"; do comp_apps "$c"; done | awk 'NF' | sort -u \
        | while read -r a; do oc get application "$a" -n "$ARGO_NS" >/dev/null 2>&1 && echo "$a"; done)"
# ApplicationSets only exist for the MAS tree (account root stamps environment=<account>).
APPSETS="$(want_comp mas && discover_appsets || true)"

echo
echo "Target: account=$ACCOUNT_ID cluster=$CLUSTER_ID instance=$INSTANCE_ID"
echo "Components: ${COMPONENTS[*]}$([[ -n "$ONLY" ]] && echo '  (--only)' )"
want_comp operators && echo "  NOTE: 'operators' also removes the cert-manager namespaces (shared cluster infra)."
echo "ApplicationSets found ($(echo "$APPSETS" | grep -c . || true)):"
echo "${APPSETS:-  (none)}" | sed 's/^/  /'
echo "Applications found ($(echo "$APPS" | grep -c . || true)):"
echo "${APPS:-  (none)}" | sed 's/^/  /'
echo "Namespaces targeted:"; printf '  %s\n' "${NS_LIST[@]}"
echo "Vault: $(want_comp vault && echo INCLUDED || echo preserved)"
# MAS CRDs are cluster-scoped and SHARED by every instance on the cluster, so they are preserved
# by default. --include-crds removes them (only safe when NO other MAS instance uses them).
mas_crds(){ oc get crd -o name 2>/dev/null | grep -E '\.mas\.ibm\.com$|\.sls\.ibm\.com$' | sed 's#.*/##'; }
if [[ "$INCLUDE_CRDS" == 1 ]]; then
  echo "MAS CRDs: WILL BE DELETED (cluster-wide — removes these types for EVERY instance):"
  mas_crds | sed 's/^/    /' || echo "    (none)"
else
  echo "MAS CRDs: preserved (pass --include-crds to also delete them cluster-wide)"
fi

if [[ -z "$APPS" && -z "$APPSETS" ]]; then
  echo
  echo "WARNING: no Applications or ApplicationSets matched cluster=$CLUSTER_ID / instance=$INSTANCE_ID."
  echo "         Either the install is already gone, oc is not logged in, or the IDs in the env"
  echo "         file do not match what is deployed. Check:  oc get applications -n $ARGO_NS --show-labels"
fi

if [[ "$CONFIRM" != 1 ]]; then
  echo
  echo "DRY RUN — nothing deleted. Re-run with --confirm to delete the above."
  exit 0
fi

say(){ printf '\n=== %s ===\n' "$*"; }

# ---- Restore Argo controllers on exit no matter what ---------------------------------
SCALE_FILE="$(mktemp)"; ARGOCD_CR=""
cleanup(){
  if [[ -n "$ARGOCD_CR" ]]; then
    oc patch "$ARGOCD_CR" -n "$ARGO_NS" --type=merge \
      -p '{"spec":{"controller":{"replicas":1},"applicationSet":{"replicas":1}}}' >/dev/null 2>&1 || true
  fi
  if [[ -s "$SCALE_FILE" ]]; then
    say "Restoring Argo CD controllers"
    while read -r k n r; do [[ -n "$k" ]] && oc scale "$k/$n" -n "$ARGO_NS" --replicas="${r:-1}" >/dev/null 2>&1 || true; done < "$SCALE_FILE"
  fi
  rm -f "$SCALE_FILE"
}
trap cleanup EXIT

say "1. Pause Argo CD controllers DURABLY (so nothing regenerates during teardown)"
oc get deploy,statefulset -n "$ARGO_NS" \
  -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
  | while read -r k n r; do
      case "$n" in
        *application-controller*|*applicationset-controller*)
          echo "${k,,} $n ${r:-1}" >> "$SCALE_FILE"
          oc scale "${k,,}/$n" -n "$ARGO_NS" --replicas=0 >/dev/null 2>&1 || true ;;
      esac
    done
# The OpenShift GitOps operator re-pins controller replicas, so scale alone reverts in
# seconds. Setting replicas=0 on the ArgoCD CR is honored; restored on exit.
ARGOCD_CR="$(oc get argocd -n "$ARGO_NS" -o name 2>/dev/null | head -1)"
if [[ -n "$ARGOCD_CR" ]]; then
  oc patch "$ARGOCD_CR" -n "$ARGO_NS" --type=merge \
    -p '{"spec":{"controller":{"replicas":0},"applicationSet":{"replicas":0}}}' >/dev/null 2>&1 || true
  echo "  paused $ARGOCD_CR (controller + applicationSet replicas=0)"
fi

say "2. Delete ApplicationSets FIRST (they regenerate Applications), then Applications"
while read -r a; do
  [[ -z "$a" ]] && continue
  oc patch applicationset "$a" -n "$ARGO_NS" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  oc delete applicationset "$a" -n "$ARGO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "  deleted applicationset/$a"
done <<< "$APPSETS"
while read -r a; do
  [[ -z "$a" ]] && continue
  oc patch application "$a" -n "$ARGO_NS" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  oc delete application "$a" -n "$ARGO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "  deleted application/$a"
done <<< "$APPS"
# brief wait so the API actually drops them before namespace teardown begins
for _ in 1 2 3 4 5 6; do
  left="$(oc get applications -n "$ARGO_NS" -l "cluster=${CLUSTER_ID}" -o name 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$left" == "0" ]] && break
  sleep 5
done

say "3. Purge OLM operators in target namespaces BEFORE deleting the namespaces"
# OLM-safe order: Subscription (stop OLM managing) -> InstallPlans -> CSVs -> OperatorGroup.
# Doing this pre-namespace-delete is what prevents the stale-operator "@existing ...
# constraints not satisfiable" wedge on the NEXT install. Finalizers stripped FIRST —
# a Failed CSV keeps its finalizer and a later force-finalize would orphan it in etcd.
for ns in "${NS_LIST[@]}"; do
  oc get ns "$ns" >/dev/null 2>&1 || continue
  for kind in subscriptions.operators.coreos.com installplans.operators.coreos.com \
              clusterserviceversions.operators.coreos.com operatorgroups.operators.coreos.com; do
    oc get "$kind" -n "$ns" -o name 2>/dev/null | while read -r o; do
      oc patch "$o" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done
    oc delete "$kind" --all -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  echo "  purged OLM artifacts in $ns"
done

say "4. Strip CR finalizers, force-delete pods, clear PVCs, THEN delete namespaces (parallel)"
MAS_CRDS="suites.core.mas.ibm.com workspaces.core.mas.ibm.com manageapps.apps.mas.ibm.com \
manageworkspaces.apps.mas.ibm.com healthapps.apps.mas.ibm.com mongocfgs.config.mas.ibm.com \
slscfgs.config.mas.ibm.com jdbccfgs.config.mas.ibm.com bascfgs.config.mas.ibm.com \
kafkacfgs.config.mas.ibm.com licenseservices.sls.ibm.com \
mongodbcommunity.mongodbcommunity.mongodb.com db2uclusters.db2u.databases.ibm.com \
db2uinstances.db2u.databases.ibm.com operandrequests.operator.ibm.com \
truststores.truststore-mgr.ibm.com"
for ns in "${NS_LIST[@]}"; do
  oc get ns "$ns" >/dev/null 2>&1 || continue
  (
    set +e   # a single failed oc call (e.g. CRD not installed) must not abort this subshell
    for crd in $MAS_CRDS; do
      oc get "$crd" -n "$ns" -o name 2>/dev/null | while read -r o; do
        [[ -n "$o" ]] && oc patch "$o" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      done || true
    done
    # FORCE-DELETE PODS FIRST. kubernetes.io/pvc-protection re-adds a PVC's finalizer while any pod
    # still mounts it, and a hung CSI (isilon) unmount leaves pods stuck Terminating — so a PVC
    # finalizer strip done before the pods are gone just gets undone. Kill pods, THEN the strip sticks.
    oc delete pod --all -n "$ns" --grace-period=0 --force >/dev/null 2>&1 || true
    # Now clear the PVCs (reclaim=Delete then removes their PVs).
    oc get pvc -n "$ns" -o name 2>/dev/null | while read -r p; do
      oc patch "$p" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done || true
    oc delete pvc --all -n "$ns" --grace-period=0 --force >/dev/null 2>&1 || true
    # WAIT for the PVCs to actually disappear before deleting the namespace. Deleting (and later
    # force-finalizing) a namespace while its PVCs still carry finalizers strands them as un-addressable
    # GHOST PVCs — their namespace is gone, so `oc patch pvc -n <ns>` fails with "namespace not found".
    for _ in $(seq 1 12); do
      [[ -z "$(oc get pvc -n "$ns" -o name 2>/dev/null)" ]] && break
      oc get pvc -n "$ns" -o name 2>/dev/null | while read -r p; do   # re-strip if pvc-protection re-added it
        oc patch "$p" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      done || true
      sleep 5
    done
    oc delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    echo "  deleting namespace/$ns"
  ) &
done
wait

say "5. Force-finalize any namespace still Terminating"
sleep 10
for _ in $(seq 1 18); do
  remaining=0
  for ns in "${NS_LIST[@]}"; do
    oc get ns "$ns" >/dev/null 2>&1 || continue
    remaining=1
    # NEVER force-finalize a namespace that still has PVCs — that is exactly what orphans them into
    # un-addressable ghosts. Clear any lingering pods + PVC finalizers first, then force-finalize.
    oc delete pod --all -n "$ns" --grace-period=0 --force >/dev/null 2>&1 || true
    oc get pvc -n "$ns" -o name 2>/dev/null | while read -r p; do
      oc patch "$p" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done || true
    oc get ns "$ns" -o json 2>/dev/null \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); d.get("spec",{}).pop("finalizers",None); sys.stdout.write(json.dumps(d))' 2>/dev/null \
      | oc replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
  done
  [[ "$remaining" == 0 ]] && break
  sleep 5
done

say "5c. Reclaim PVs that belonged to the deleted namespaces"
# reclaimPolicy=Delete usually removes the PV when its PVC goes, but a PV can hang Released
# (or Bound to a now-gone PVC) if the CSI delete stalls — the exact Vault PV wedge we hit.
# Strip the pv-protection finalizer on any PV whose claimRef is one of our namespaces, then
# delete it. (This is why single-component teardown of Vault now cleans its storage too.)
for pv in $(oc get pv -o json 2>/dev/null \
            | python3 -c 'import sys,json
nsl=set(sys.argv[1:])
for pv in json.load(sys.stdin).get("items",[]):
    cr=(pv.get("spec",{}) or {}).get("claimRef",{}) or {}
    if cr.get("namespace") in nsl: print(pv["metadata"]["name"])' "${NS_LIST[@]}" 2>/dev/null); do
  [[ -z "$pv" ]] && continue
  oc patch pv "$pv" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  oc delete pv "$pv" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "  reclaimed pv/$pv"
done

if want_comp mas; then
  say "5b. Sweep ORPHANED MAS operator CSVs/subs (namespace force-finalized under them)"
  # If a CSV still references a now-deleted namespace, recreate the ns, strip finalizers,
  # delete the objects, then re-delete the ns — without a live ns the strip cannot land.
  for ns in $(oc get csv -A -o custom-columns='NS:.metadata.namespace' --no-headers 2>/dev/null \
                | grep -iE '^mas-|^mongo-|^db2u-|^ibm-sls$|^ibm-software-central$|^job-cleaner$' | sort -u); do
    oc get ns "$ns" >/dev/null 2>&1 || oc create namespace "$ns" >/dev/null 2>&1 || true
    for o in $(oc get csv,subscription,installplan,operatorgroup -n "$ns" -o name 2>/dev/null); do
      oc patch "$o" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done
    oc delete csv,subscription,installplan,operatorgroup --all -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
    oc delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    oc get ns "$ns" -o json 2>/dev/null \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); d.get("spec",{}).pop("finalizers",None); sys.stdout.write(json.dumps(d))' 2>/dev/null \
      | oc replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
    echo "  swept orphaned OLM objects in $ns"
  done

  say "6. Clean cluster-scoped leftovers"
  # The IBM operator catalog lives in openshift-marketplace and is not owned by any of the
  # deleted namespaces; the instance RBAC chart can leave cluster roles/bindings behind.
  oc delete catalogsource ibm-operator-catalog -n openshift-marketplace --ignore-not-found >/dev/null 2>&1 || true
  for kind in clusterrole clusterrolebinding; do
    oc get "$kind" -o name 2>/dev/null | grep -E "${INSTANCE_ID}|application-admin" \
      | while read -r o; do
          oc delete "$o" --ignore-not-found >/dev/null 2>&1 || true
          echo "  deleted $o"
        done || true
  done
else
  say "5b/6. Cluster-scoped MAS cleanup skipped ('mas' not in --only scope)"
fi

if [[ "$INCLUDE_CRDS" == 1 ]] && want_comp mas; then
  say "6b. Delete MAS CRDs (cluster-wide — you passed --include-crds)"
  # Two passes: a dying MAS operator can re-register a CRD after the first sweep, so re-sweep
  # to catch stragglers (e.g. managedeployments.apps.mas.ibm.com).
  for pass in 1 2; do
    for c in $(mas_crds); do
      oc patch crd "$c" --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      oc delete crd "$c" --ignore-not-found --wait=false >/dev/null 2>&1 || true
      [[ "$pass" == 1 ]] && echo "  deleted crd/$c"
    done
    [[ "$pass" == 1 ]] && sleep 5
  done
  left="$(mas_crds)"; [[ -n "$left" ]] && { echo "  still present (delete manually):"; echo "$left" | sed 's/^/    oc delete crd /'; }
elif [[ "$INCLUDE_CRDS" == 1 ]]; then
  say "6b. MAS CRDs preserved (--include-crds needs 'mas' in scope; not deleting them here)"
else
  say "6b. MAS CRDs preserved (re-run with --include-crds — and 'mas' in scope — to remove them)"
fi

say "7. Verify (same selectors as discovery)"
echo "ApplicationSets:"; oc get applicationsets -n "$ARGO_NS" 2>/dev/null | grep -E "${ACCOUNT_ID}|${CLUSTER_ID}" || echo "  none"
echo "Applications (label cluster=${CLUSTER_ID}):"
oc get applications -n "$ARGO_NS" -l "cluster=${CLUSTER_ID}" 2>/dev/null | grep -v '^NAME' || echo "  none"
echo "Applications (name match):"; oc get applications -n "$ARGO_NS" 2>/dev/null | grep -E "${CLUSTER_ID}|${INSTANCE_ID}" || echo "  none"
echo "Namespaces still present:"; oc get ns 2>/dev/null \
  | grep -E "^($(printf '%s|' "${NS_LIST[@]}" | sed 's/|$//')) " || echo "  none"
echo "PVs still bound to those namespaces:"
oc get pv -o json 2>/dev/null | python3 -c 'import sys,json
nsl=set(sys.argv[1:])
found=[pv["metadata"]["name"] for pv in json.load(sys.stdin).get("items",[])
       if ((pv.get("spec",{}) or {}).get("claimRef",{}) or {}).get("namespace") in nsl]
print("\n".join("  "+n for n in found) if found else "  none")' "${NS_LIST[@]}" 2>/dev/null || echo "  none"
echo "Operator residue:"
oc get csv,subscription -A 2>/dev/null \
  | grep -E "$(printf '%s|' "${NS_LIST[@]}" | sed 's/|$//')" \
  | grep -iE 'mas|sls|mongo|truststore|data-reporter|metric|db2' || echo "  none"
want_comp mas && { echo "MAS CRDs:"; mas_crds | sed 's/^/  /' | grep . || echo "  none"; }
echo
echo "Teardown complete (cluster=$CLUSTER_ID instance=$INSTANCE_ID, components='${COMPONENTS[*]}', crds=$([[ $INCLUDE_CRDS == 1 ]] && want_comp mas && echo deleted || echo preserved))."
if want_comp mas; then
  echo "Reinstall: follow INSTALL.md from section 3 (bootstrap) — or section 7/8 if Vault was preserved."
else
  echo "Redeploy just this layer: re-run its bootstrap script (e.g. ./bootstrap/10-vault.sh $CLUSTER_ID)."
fi
