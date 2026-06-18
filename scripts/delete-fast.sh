#!/usr/bin/env bash
set -euo pipefail
# FAST + clean teardown of ONE platform-gitops cluster/instance.
# Order matters so NOTHING survives or gets recreated:
#   1. pause Argo CD DURABLY (scale + ArgoCD CR replicas=0, since the operator re-pins scale)
#   2. force-delete the cluster's apps/appsets (so nothing regenerates)
#   3. purge OLM operators in the target namespaces (subscriptions->installplans->CSVs->operatorgroups)
#      — this is what prevents stale operators (e.g. ibm-metrics-operator) lingering and wedging
#      OLM resolution on the NEXT install with an "@existing ... constraints not satisfiable" error
#   4. strip MAS/operator CR finalizers, delete namespaces, force-finalize stragglers
#   5. clean cluster-scoped leftovers
# Restores Argo controllers on exit.
#
# Usage:
#   ./scripts/delete-fast.sh [--confirm] [--include-vault] <cluster.env | cluster-name>
#   (omit target if CLUSTER_ID/INSTANCE_ID are exported). Without --confirm it's a DRY RUN.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"

usage(){ sed -n '3,12p' "$0"; }
CONFIRM=0; INCLUDE_VAULT=0; ENVARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM=1; shift ;;
    --include-vault) INCLUDE_VAULT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) ENVARG="$1"; shift ;;
  esac
done

# Resolve target from explicit path, bare cluster name, or exported vars.
ENVFILE=""
if [[ -n "$ENVARG" && -f "$ENVARG" ]]; then
  ENVFILE="$ENVARG"
elif [[ -n "$ENVARG" ]]; then
  for d in "$ROOT/.." "$ROOT/../.." "$ROOT/../../.."; do
    for repo in mas-gitops-config mas-config-repo; do
      [[ -f "$d/$repo/envs/${ENVARG}.env" ]] && { ENVFILE="$d/$repo/envs/${ENVARG}.env"; break 2; }
    done
  done
  [[ -n "$ENVFILE" ]] || { echo "ERROR: no env file found for '$ENVARG'." >&2; exit 2; }
fi
[[ -n "$ENVFILE" ]] && { echo ">> using env: $ENVFILE"; set -a; . "$ENVFILE"; set +a; }
: "${CLUSTER_ID:?set CLUSTER_ID or pass a cluster/env}"; : "${INSTANCE_ID:?}"
MONGO_NS="${MONGO_NS:-mongo-${INSTANCE_ID}}"; DRO_NAMESPACE="${DRO_NAMESPACE:-ibm-software-central}"

NS_LIST=( "mas-${INSTANCE_ID}-core" "mas-${INSTANCE_ID}-manage" "mas-${INSTANCE_ID}-sls" \
          "mas-${INSTANCE_ID}-syncres" "$MONGO_NS" "$DRO_NAMESPACE" )
[[ "$INCLUDE_VAULT" == 1 ]] && NS_LIST+=( vault )

if [[ "$CONFIRM" != 1 ]]; then
  echo "DRY RUN — nothing deleted. Would fast-delete:"
  echo "  cluster=$CLUSTER_ID instance=$INSTANCE_ID"
  printf '  ns: %s\n' "${NS_LIST[*]}"
  echo "  vault: $([[ $INCLUDE_VAULT == 1 ]] && echo INCLUDED || echo preserved)"
  echo "Re-run with --confirm to delete."
  exit 0
fi

say(){ printf '\n=== %s ===\n' "$*"; }

# Restore Argo controllers on exit no matter what.
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

say "1. Pause Argo CD controllers DURABLY (so nothing recreates during teardown)"
oc get deploy,statefulset -n "$ARGO_NS" \
  -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
  | while read -r k n r; do
      case "$n" in
        *application-controller*|*applicationset-controller*)
          echo "${k,,} $n ${r:-1}" >> "$SCALE_FILE"
          oc scale "${k,,}/$n" -n "$ARGO_NS" --replicas=0 >/dev/null 2>&1 || true ;;
      esac
    done
# The OpenShift GitOps operator re-pins the controller replicas, so `oc scale` alone is reverted
# within seconds. Set replicas=0 on the ArgoCD CR too (the operator honors this); restored on exit.
ARGOCD_CR="$(oc get argocd -n "$ARGO_NS" -o name 2>/dev/null | head -1)"
if [[ -n "$ARGOCD_CR" ]]; then
  oc patch "$ARGOCD_CR" -n "$ARGO_NS" --type=merge \
    -p '{"spec":{"controller":{"replicas":0},"applicationSet":{"replicas":0}}}' >/dev/null 2>&1 || true
  echo "  paused $ARGOCD_CR (controller + applicationSet replicas=0)"
fi

say "2. Force-delete this cluster's Argo apps + appsets"
for kind in applications applicationsets; do
  oc get "$kind" -n "$ARGO_NS" -o name 2>/dev/null | sed 's#.*/##' \
    | { grep -E "${CLUSTER_ID}|${INSTANCE_ID}|^platform-${CLUSTER_ID}\$|^hashicorp-vault-server\$" || true; } \
    | while read -r a; do
        [[ -z "$a" ]] && continue
        [[ "$a" == hashicorp-vault-server && "$INCLUDE_VAULT" != 1 ]] && continue
        oc patch "$kind" "$a" -n "$ARGO_NS" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        oc delete "$kind" "$a" -n "$ARGO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
        echo "  deleted $kind/$a"
      done
done

say "2b. Purge OLM operators in target namespaces BEFORE deleting the namespaces"
# Delete in OLM-safe order: Subscription first (so OLM stops managing/reinstalling), then the
# pending InstallPlans, then the CSVs (the actual operator), then the OperatorGroup. Doing this
# before the namespace delete guarantees no operator lingers/gets reinstalled — which is what
# caused the stale ibm-metrics-operator "@existing" OLM resolution conflict on reinstall.
# Scoped to the MAS-owned namespaces only; openshift-marketplace platform operators are untouched.
for ns in "${NS_LIST[@]}"; do
  oc get ns "$ns" >/dev/null 2>&1 || continue
  for kind in subscriptions.operators.coreos.com installplans.operators.coreos.com \
              clusterserviceversions.operators.coreos.com operatorgroups.operators.coreos.com; do
    oc delete "$kind" --all -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  echo "  purged OLM artifacts in $ns"
done

say "3. Strip MAS/operator CR finalizers + delete namespaces (parallel)"
MAS_CRDS="suites.core.mas.ibm.com manageapps.apps.mas.ibm.com manageworkspaces.apps.mas.ibm.com \
healthapps.apps.mas.ibm.com mongocfgs.config.mas.ibm.com slscfgs.config.mas.ibm.com \
jdbccfgs.config.mas.ibm.com bascfgs.config.mas.ibm.com kafkacfgs.config.mas.ibm.com \
licenseservices.sls.ibm.com mongodbcommunity.mongodbcommunity.mongodb.com \
db2uclusters.db2u.databases.ibm.com db2uinstances.db2u.databases.ibm.com \
operandrequests.operator.ibm.com truststores.truststore-mgr.ibm.com"
for ns in "${NS_LIST[@]}"; do
  oc get ns "$ns" >/dev/null 2>&1 || continue
  (
    set +e   # teardown: a single failed oc call (e.g. CRD type not installed) must NOT abort this subshell
    for crd in $MAS_CRDS; do
      oc get "$crd" -n "$ns" -o name 2>/dev/null | while read -r o; do
        [[ -n "$o" ]] && oc patch "$o" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      done || true
    done
    oc delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    echo "  deleting namespace/$ns"
  ) &
done
wait

say "4. Force-finalize any namespace still Terminating (removes it + contents instantly)"
sleep 10
for _ in $(seq 1 18); do
  remaining=0
  for ns in "${NS_LIST[@]}"; do
    oc get ns "$ns" >/dev/null 2>&1 || continue
    remaining=1
    oc get ns "$ns" -o json 2>/dev/null \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); d.get("spec",{}).pop("finalizers",None); sys.stdout.write(json.dumps(d))' 2>/dev/null \
      | oc replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
  done
  [[ "$remaining" == 0 ]] && break
  sleep 5
done

say "5. Clean cluster-scoped leftovers we created"
oc delete catalogsource ibm-operator-catalog -n openshift-marketplace --ignore-not-found >/dev/null 2>&1 || true
oc delete clusterrole        "${INSTANCE_ID}-jdbc-system-await-crd" --ignore-not-found >/dev/null 2>&1 || true
oc delete clusterrolebinding "${INSTANCE_ID}-jdbc-system-await-crd" --ignore-not-found >/dev/null 2>&1 || true

say "6. Verify"
echo "Argo apps for cluster:"; oc get applications -n "$ARGO_NS" 2>/dev/null | grep -E "${CLUSTER_ID}|${INSTANCE_ID}" || echo "  none"
echo "Namespaces:"; oc get ns 2>/dev/null | grep -E "mas-${INSTANCE_ID}|${MONGO_NS}|^${DRO_NAMESPACE}\b$( [[ $INCLUDE_VAULT == 1 ]] && echo '|^vault\b' )" || echo "  none"
echo "Operator residue (CSVs/subscriptions in MAS/DRO ns — should be gone with the namespaces):"
oc get csv,subscription -A 2>/dev/null \
  | grep -E "$(printf '%s|' "${NS_LIST[@]}" | sed 's/|$//')" \
  | grep -iE 'mas|sls|mongo|truststore|data-reporter|metric|db2' || echo "  none"
echo ""
echo "Fast delete complete (cluster=$CLUSTER_ID instance=$INSTANCE_ID, vault=$([[ $INCLUDE_VAULT == 1 ]] && echo deleted || echo preserved))."
