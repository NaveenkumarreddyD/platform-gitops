#!/usr/bin/env bash
set -euo pipefail
# FAST + clean teardown of ONE platform-gitops cluster/instance.
# Pauses Argo CD, force-deletes the cluster's apps/appsets, deletes the target namespaces in
# parallel, strips finalizers ONLY on the known MAS/operator CRs, then force-finalizes any
# straggler namespace via the /finalize API (removes it + everything in it instantly). Restores
# Argo controllers on exit.
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
SCALE_FILE="$(mktemp)"
cleanup(){
  if [[ -s "$SCALE_FILE" ]]; then
    say "Restoring Argo CD controllers"
    while read -r k n r; do [[ -n "$k" ]] && oc scale "$k/$n" -n "$ARGO_NS" --replicas="${r:-1}" >/dev/null 2>&1 || true; done < "$SCALE_FILE"
  fi
  rm -f "$SCALE_FILE"
}
trap cleanup EXIT

say "1. Pause Argo CD controllers (so nothing recreates during teardown)"
oc get deploy,statefulset -n "$ARGO_NS" \
  -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
  | while read -r k n r; do
      case "$n" in
        *application-controller*|*applicationset-controller*)
          echo "${k,,} $n ${r:-1}" >> "$SCALE_FILE"
          oc scale "${k,,}/$n" -n "$ARGO_NS" --replicas=0 >/dev/null 2>&1 || true ;;
      esac
    done

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
    for crd in $MAS_CRDS; do
      oc get "$crd" -n "$ns" -o name 2>/dev/null | while read -r o; do
        [[ -n "$o" ]] && oc patch "$o" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      done
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
echo ""
echo "Fast delete complete (cluster=$CLUSTER_ID instance=$INSTANCE_ID, vault=$([[ $INCLUDE_VAULT == 1 ]] && echo deleted || echo preserved))."
