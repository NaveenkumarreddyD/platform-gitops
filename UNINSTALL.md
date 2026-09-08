# MAS Uninstall — GitOps (official mechanism)

MAS runs in OpenShift via **OpenShift GitOps (Argo CD)**, config in **`mas-gitops-config`**,
`auto_delete: false`. Cluster **`drroc4`**, instance **`drgitopsapp`**, workspace **`drgitopswks`**.

**Official GitOps removal = delete the config from the config repo, then Sync-with-Prune.**
The `ibm-mas/gitops` charts ship **PostDelete hooks** that clean the Suite-owned CRs (MongoCfg,
DRO MarketplaceConfig) that Argo CD cannot prune — so config-removal is the clean path.

> `mas uninstall` (CLI) is the imperative alternative, used only after detaching Argo CD. For a
> GitOps install, the steps below are the recommended, GitOps-native way.

## What each part covers
- **A + B** = remove the **complete MAS application** (Core/Suite, Manage, SLS, DRO, workspaces, catalog) — IBM-recommended GitOps mechanism.
- **C** = MongoDB + cert-manager + operators — **your platform-gitops layer**, NOT part of IBM's MAS uninstall. Skip it if you plan to reinstall.

---

## A — Delete the MAS instance (drgitopsapp)

**A1. Remove the instance config from the config repo** (do NOT re-run `render.sh` — it regenerates them):
```bash
cd ~/Documents/mas/mas-gitops-config
git rm -r drroc4/drroc4/drgitopsapp/     # instance-base + suite + suite-configs + masapp-configs + manage-install + workspaces + sls
git commit -m "remove MAS instance drgitopsapp" && git push
```

**A2. Refresh the instance root so it re-renders without the config:**
```bash
oc annotate application instance.drroc4.drgitopsapp -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

**A3. Sync-with-Prune each MAS child app (leaf-first).** `auto_delete: false` → nothing prunes on its
own; this triggers it and fires the PostDelete hooks.
```bash
ARGO_NS=openshift-gitops

# discover the instance's child apps (all drgitopsapp apps EXCEPT the instance-root)
CHILDREN=$(oc get applications -n $ARGO_NS -o name | grep drgitopsapp | grep -v '/instance\.drroc4\.drgitopsapp$')
echo "will prune:"; echo "$CHILDREN"

for app in $CHILDREN; do
  echo ">> pruning $app"
  oc patch $app -n $ARGO_NS --type merge -p '{"operation":{"sync":{"prune":true}}}'
done

# watch them drain (Manage takes longest)
oc get applications -n $ARGO_NS | grep drgitopsapp
oc get pods -n mas-drgitopsapp-manage 2>/dev/null | tail
```

**A4. Prune, then delete, the instance root app** (ApplicationSet-generated → must delete explicitly):
```bash
oc patch application instance.drroc4.drgitopsapp -n $ARGO_NS --type merge -p '{"operation":{"sync":{"prune":true}}}'
oc delete application instance.drroc4.drgitopsapp -n $ARGO_NS
```

---

## B — Delete the cluster layer (DRO, operator catalog)
Skip B if reinstalling soon and you want to keep the operator catalog (faster reinstall).

**B1. Remove the cluster config:**
```bash
cd ~/Documents/mas/mas-gitops-config
git rm drroc4/drroc4/ibm-dro.yaml drroc4/drroc4/ibm-operator-catalog.yaml drroc4/drroc4/ibm-mas-cluster-base.yaml
git commit -m "remove drroc4 cluster MAS config" && git push
```

**B2. Sync-with-Prune the cluster apps, then delete the cluster root:**
```bash
ARGO_NS=openshift-gitops
oc annotate application cluster.drroc4 -n $ARGO_NS argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true
# DRO first — its 032-ibm-dro-cleanup PostDelete hook clears the MarketplaceConfig that blocks uninstall
oc patch application dro.drroc4 -n $ARGO_NS --type merge -p '{"operation":{"sync":{"prune":true}}}'
# then any other cluster apps for drroc4 (except the cluster-root)
for app in $(oc get applications -n $ARGO_NS -o name | grep '\.drroc4$' | grep -v '/cluster\.drroc4$'); do
  oc patch $app -n $ARGO_NS --type merge -p '{"operation":{"sync":{"prune":true}}}'
done
oc delete application cluster.drroc4 -n $ARGO_NS 2>/dev/null || true
```

---

## C — Platform layer (MongoDB, cert-manager, operators) — ONLY for a full wipe
**Skip this entirely if you are reinstalling MAS on the same cluster** — bootstrap reuses these.
Not part of IBM's MAS uninstall; these are your platform-gitops apps. cert-manager **last**.
```bash
ARGO_NS=openshift-gitops
# MongoDB (operator + CA + instance)
oc patch application mongodb -n $ARGO_NS --type merge -p '{"operation":{"sync":{"prune":true}}}'
oc delete application mongodb mongodb-operator -n $ARGO_NS
oc delete ns mongo-gitops --wait=false 2>/dev/null || true

# cert-manager LAST, only if nothing else uses it
oc get certificates,issuers,clusterissuers -A | grep -v mongo    # anything else using it?
oc delete application operators -n $ARGO_NS 2>/dev/null || true
# oc delete ns cert-manager cert-manager-operator --wait=false
```

---

## VERIFY — MAS gone, platform intact, no orphans
```bash
echo "== MAS CRs / namespaces / apps (expect none) =="
oc get suite,manageapp,manageworkspace,workspace.core.mas.ibm.com -A 2>/dev/null || echo "  no MAS CRs"
oc get ns | grep 'mas-drgitopsapp' || echo "  no MAS namespaces"
oc get applications -n openshift-gitops | grep -E 'drgitopsapp|\.drroc4$' || echo "  no MAS apps"

echo "== orphaned OLM operators in shared ns (MUST clear before reinstall) =="
oc get sub,csv -n ibm-software-central | grep -iE 'data-reporter|metrics' || echo "  none"
# if a CSV remains with no owning Subscription:  oc delete csv <name> -n ibm-software-central

echo "== KEPT for reinstall (expect present) =="
oc get application mongodb -n openshift-gitops 2>/dev/null
oc get mongodbcommunity -n mongo-gitops 2>/dev/null
oc get csv -n cert-manager-operator 2>/dev/null | grep cert-manager
```

---

## Notes
- **A + B removes the complete MAS application.** MAS **CRDs** remain (harmless, reused on reinstall).
- **The one gotcha:** DRO/metrics OLM operators in `ibm-software-central` can leave an **orphaned CSV**
  (the "constraints not satisfiable / CSV not referenced by a subscription" deadlock). The VERIFY step
  catches it — clear it before reinstalling.
- **`auto_delete: false`** is why every removal needs an explicit Sync-with-Prune. If it were `true`,
  deleting config alone would auto-prune (dev only; risky for prod).
- **Reinstall:** restore the instance config (`./render.sh drroc4` in mas-gitops-config → push); the
  account-root regenerates everything against the surviving Mongo + cert-manager.

## References
- ibm-mas/gitops — docs/orchestration.md (prune + PostDelete teardown hooks)
- ibm-mas/gitops — docs/accountrootmanifest.md (`auto_delete` behavior)
- MAS CLI — `mas uninstall` (imperative alternative)
