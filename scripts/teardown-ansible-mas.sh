#!/usr/bin/env bash
# =============================================================================
# Tear down ALL Ansible-installed IBM MAS / Manage + dependencies, ending with a
# clean cluster: no MAS, no SLS, no Mongo, no DRO, no cert-manager, no Grafana,
# no IBM operator catalog, no leftover CRDs/namespaces/webhooks.
#
# DRY-RUN by default — prints what it WOULD delete. Add --confirm to execute.
# Requires: cluster-admin (oc whoami can-i delete crd) + oc logged in.
#
#   ./teardown-ansible-mas.sh                 # dry run (safe)
#   ./teardown-ansible-mas.sh --confirm        # actually delete
#
# EDIT the CONFIG block to match your cluster before running.
# =============================================================================
set -uo pipefail

# ----------------------------- CONFIG ----------------------------------------
INSTANCES="drmasapp"            # space-separated MAS instance ids installed by Ansible
SLS_NS="ibm-sls"               # shared SLS ns (or mas-<inst>-sls if dedicated)
MONGO_NS="mongoce"             # MongoDB Community namespace
DRO_NS="ibm-software-central"  # Data Reporter Operator namespace
GRAFANA_NS="grafana"           # Ansible Grafana namespace
CERTMGR_OPERATOR_NS="cert-manager-operator"
CERTMGR_NS="cert-manager"
CATALOG_NS="openshift-marketplace"
CATALOG_NAME="ibm-operator-catalog"
# CRD suffixes we own/remove (scoped — we never touch core k8s/openshift CRDs)
CRD_MATCH='mas.ibm.com|sls.ibm.com|apps.mas|internal.mas|dro.ibm.com|datareporter|mongodbcommunity.mongodb.com|grafana.integreatly.org'
REMOVE_CERT_MANAGER_CRDS="yes"  # set "no" to keep cert-manager.io CRDs
# -----------------------------------------------------------------------------

CONFIRM="${1:-}"; EXEC=0; [ "$CONFIRM" = "--confirm" ] && EXEC=1
banner(){ echo; echo "========== $* =========="; }
run(){ if [ "$EXEC" = 1 ]; then echo "+ $*"; eval "$@"; else echo "[dry-run] $*"; fi; }

command -v oc >/dev/null || { echo "ERROR: oc not on PATH"; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged in (oc login ...)"; exit 1; }
if ! oc auth can-i delete crd >/dev/null 2>&1; then echo "ERROR: need cluster-admin"; exit 1; fi

if [ "$EXEC" = 1 ]; then
  echo "!!! DESTRUCTIVE: this will PERMANENTLY delete MAS/Manage, SLS, Mongo, DRO,"
  echo "!!! cert-manager and Grafana on cluster: $(oc whoami --show-server 2>/dev/null)"
  echo "!!! Instances: $INSTANCES   (data loss is irreversible — backups done?)"
  read -r -p "Type ERASE to proceed: " ANS; [ "$ANS" = "ERASE" ] || { echo "aborted."; exit 1; }
else
  echo ">>> DRY-RUN (no changes). Re-run with --confirm to execute."
fi

# clear finalizers on a stuck resource
unstick(){ local kind="$1" name="$2" ns="${3:-}"
  if [ -n "$ns" ]; then run "oc patch $kind $name -n $ns --type=merge -p '{\"metadata\":{\"finalizers\":[]}}' 2>/dev/null || true"
  else run "oc patch $kind $name --type=merge -p '{\"metadata\":{\"finalizers\":[]}}' 2>/dev/null || true"; fi; }
# force-delete a Terminating namespace via the finalize subresource
unstick_ns(){ local ns="$1"
  oc get ns "$ns" >/dev/null 2>&1 || return 0
  run "oc get ns $ns -o json | python3 -c 'import sys,json; d=json.load(sys.stdin); d[\"spec\"][\"finalizers\"]=[]; print(json.dumps(d))' | oc replace --raw /api/v1/namespaces/$ns/finalize -f - 2>/dev/null || true"; }

banner "PHASE 0  recommended FIRST: IBM mas uninstall CLI"
cat <<'TXT'
The supported uninstaller removes Core/apps/SLS/Mongo/DRO/common-services/catalog in order:
    mas uninstall --mas-instance-id <inst> --skip-grafana=false
(run from the ibmmas/cli container or `pip install mas-cli`). If you already ran it and the
cluster is still dirty, this script finishes the job. To skip the CLI and do everything here,
just continue — the phases below are self-sufficient.
TXT

banner "PHASE 1  delete MAS app + suite CRs (operators still running to honor finalizers)"
for inst in $INSTANCES; do
  CORE="mas-${inst}-core"; MANAGE="mas-${inst}-manage"
  # app workspaces/apps first, then Suite
  for k in manageworkspaces.apps.mas.ibm.com manageapps.apps.mas.ibm.com iots.apps.mas.ibm.com \
           monitorapps.apps.mas.ibm.com healthapps.apps.mas.ibm.com predictapps.apps.mas.ibm.com \
           optimizerapps.apps.mas.ibm.com assistapps.apps.mas.ibm.com visualinspectionapps.apps.mas.ibm.com; do
    run "oc delete $k --all -n $MANAGE --ignore-not-found --timeout=180s 2>/dev/null || true"
  done
  run "oc delete suites.core.mas.ibm.com $inst -n $CORE --ignore-not-found --timeout=300s 2>/dev/null || true"
done

banner "PHASE 2  delete dependency operands (SLS / Mongo / DRO)"
run "oc delete licenseservices.sls.ibm.com --all -n $SLS_NS --ignore-not-found --timeout=180s 2>/dev/null || true"
run "oc delete mongodbcommunity.mongodbcommunity.mongodb.com --all -n $MONGO_NS --ignore-not-found --timeout=180s 2>/dev/null || true"
run "oc delete datareporters.dro.ibm.com --all -n $DRO_NS --ignore-not-found --timeout=120s 2>/dev/null || true"

banner "PHASE 3  delete Grafana (operand + operator)"
run "oc delete grafanadashboards.grafana.integreatly.org,grafanadatasources.grafana.integreatly.org,grafanas.grafana.integreatly.org --all -n $GRAFANA_NS --ignore-not-found 2>/dev/null || true"

banner "PHASE 4  remove OLM subscriptions + CSVs + operatorgroups in all target namespaces"
NSLIST="$SLS_NS $MONGO_NS $DRO_NS $GRAFANA_NS $CERTMGR_OPERATOR_NS"
for inst in $INSTANCES; do NSLIST="$NSLIST mas-${inst}-core mas-${inst}-manage mas-${inst}-iot mas-${inst}-monitor mas-${inst}-pipelines mas-${inst}-sls"; done
for ns in $NSLIST; do
  oc get ns "$ns" >/dev/null 2>&1 || continue
  run "oc delete subscriptions.operators.coreos.com --all -n $ns --ignore-not-found 2>/dev/null || true"
  run "oc delete clusterserviceversions.operators.coreos.com --all -n $ns --ignore-not-found 2>/dev/null || true"
  run "oc delete operatorgroups.operators.coreos.com --all -n $ns --ignore-not-found 2>/dev/null || true"
done

banner "PHASE 5  remove cert-manager (operand + operator)  [cluster-wide dependency]"
run "oc delete certificates.cert-manager.io,issuers.cert-manager.io,clusterissuers.cert-manager.io --all --all-namespaces --ignore-not-found 2>/dev/null || true"
run "oc delete subscriptions.operators.coreos.com --all -n $CERTMGR_OPERATOR_NS --ignore-not-found 2>/dev/null || true"
run "oc delete clusterserviceversions.operators.coreos.com --all -n $CERTMGR_OPERATOR_NS --ignore-not-found 2>/dev/null || true"

banner "PHASE 6  delete namespaces (force-clear finalizers if stuck Terminating)"
for ns in $NSLIST $CERTMGR_NS; do
  oc get ns "$ns" >/dev/null 2>&1 || continue
  run "oc delete ns $ns --ignore-not-found --timeout=120s 2>/dev/null || true"
  unstick_ns "$ns"
done

banner "PHASE 7  delete IBM/MAS/Mongo/Grafana CRDs"
for crd in $(oc get crd -o name 2>/dev/null | grep -E "$CRD_MATCH" || true); do run "oc delete $crd --ignore-not-found 2>/dev/null || true"; done
if [ "$REMOVE_CERT_MANAGER_CRDS" = "yes" ]; then
  for crd in $(oc get crd -o name 2>/dev/null | grep -E 'cert-manager.io' || true); do run "oc delete $crd --ignore-not-found 2>/dev/null || true"; done
fi

banner "PHASE 8  cluster-scoped leftovers: webhooks + IBM operator catalog"
for w in $(oc get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null | grep -Ei 'mas|sls|cert-manager|grafana|mongodb|dro' || true); do run "oc delete $w --ignore-not-found 2>/dev/null || true"; done
run "oc delete catalogsource $CATALOG_NAME -n $CATALOG_NS --ignore-not-found 2>/dev/null || true"
# common-services (only if present and you want it gone)
run "oc delete ns ibm-common-services --ignore-not-found --timeout=120s 2>/dev/null || true"; unstick_ns ibm-common-services

banner "PHASE 9  VERIFY (should all be empty)"
echo "-- MAS/SLS/grafana/cert-manager namespaces --"; oc get ns 2>/dev/null | grep -Ei 'mas-|ibm-sls|mongoce|grafana|cert-manager|ibm-software-central|ibm-common' || echo "   none"
echo "-- IBM/MAS/grafana CRDs --"; oc get crd 2>/dev/null | grep -Ei "$CRD_MATCH|cert-manager.io" || echo "   none"
echo "-- IBM operator catalog --"; oc get catalogsource -n $CATALOG_NS 2>/dev/null | grep -i ibm-operator-catalog || echo "   none"
echo "-- leftover CSVs --"; oc get csv -A 2>/dev/null | grep -Ei 'ibm-mas|ibm-sls|cert-manager|grafana|mongodb|dro' || echo "   none"
echo; echo "Done.  (dry-run = $([ $EXEC = 1 ] && echo NO || echo YES))"
