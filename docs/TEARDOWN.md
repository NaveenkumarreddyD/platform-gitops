# Tear down Ansible-installed MAS -> clean cluster

End state: no MAS/Manage, no SLS, no Mongo, no DRO, **no cert-manager, no Grafana**, no IBM
operator catalog, no leftover CRDs/namespaces/webhooks. Cluster is greenfield for a fresh GitOps bring-up.

## 0. Back up first (irreversible)
- Manage business DB (Db2/Oracle) — outside the cluster, back it up your usual way.
- SLS: `ansible localhost -m include_role -a name=ibm.mas_devops.sls -e sls_action=backup -e mas_backup_dir=...`
  (saves license + registration so you can restore later).
- Any PVC data you care about (Mongo, attachments on PowerScale).

## 1. Supported uninstall (do this first)
Preferred — IBM `mas` CLI (handles Core, apps, SLS, Mongo, DRO, common-services, catalog in order):
```
mas uninstall --mas-instance-id drmasapp
```
Or the Ansible roles you already use:
```
ansible localhost -m include_role -a name=ibm.mas_devops.suite_app_uninstall -e mas_instance_id=drmasapp -e mas_app_id=manage
ansible localhost -m include_role -a name=ibm.mas_devops.suite_uninstall     -e mas_instance_id=drmasapp
ansible localhost -m include_role -a name=ibm.mas_devops.sls          -e sls_action=uninstall
ansible localhost -m include_role -a name=ibm.mas_devops.mongodb      -e mongodb_action=uninstall
ansible localhost -m include_role -a name=ibm.mas_devops.cert_manager -e cert_manager_action=uninstall
```

## 2. Finish the job + remove cert-manager/Grafana/leftovers
IBM's uninstall frequently leaves namespaces stuck Terminating, orphan CRDs, webhooks, and the
catalog. Run the sweep (dry-run first, then confirm):
```
./teardown-ansible-mas.sh            # dry-run: shows exactly what it will delete
# edit the CONFIG block (instance ids, namespaces) to match your cluster, then:
./teardown-ansible-mas.sh --confirm  # asks you to type ERASE
```
It deletes app/suite CRs, SLS/Mongo/DRO operands, Grafana CRs, all Subscriptions/CSVs/OperatorGroups
in the target namespaces, cert-manager operand+operator, the namespaces (force-clearing finalizers if
they hang), the IBM/MAS/Mongo/Grafana (+cert-manager.io) CRDs, MAS/cert-manager/grafana webhooks, and
the `ibm-operator-catalog` CatalogSource — then prints a verification summary.

## 3. Verify clean
```
oc get ns | grep -Ei 'mas-|ibm-sls|mongoce|grafana|cert-manager|ibm-software-central|ibm-common'  # none
oc get crd | grep -Ei 'mas.ibm.com|sls.ibm.com|grafana.integreatly|cert-manager.io'              # none
oc get catalogsource -n openshift-marketplace | grep ibm-operator-catalog                         # none
oc get csv -A | grep -Ei 'ibm-mas|ibm-sls|cert-manager|grafana'                                    # none
```

## 4. After the wipe — flip GitOps to greenfield
The cluster no longer has the Ansible-provided shared prereqs, so GitOps must install them now:
- `mas-gitops-config/envs/<cluster>.env`: set `SHARED_CLUSTER=false` (or clear `SHARED_CLUSTER_SKIP`)
  so `render.py` stops skipping `redhat-cert-manager.yaml` and `ibm-dro.yaml`, and re-render.
- The catalog (`ibm-operator-catalog.yaml`) is rendered by GitOps anyway — it will recreate the
  CatalogSource at your pinned tag.
- Then bootstrap per your runbook: `platform-gitops/bootstrap/apply.sh <env>`.

## Notes
- Scope: the script only deletes resources matching MAS/SLS/Mongo/DRO/cert-manager/Grafana — it does
  not touch core OpenShift CRDs or other workloads.
- Shared cluster: this removes shared deps (cert-manager, catalog), so any other instance on the
  cluster goes down too. That's intended here (full reset to greenfield).
