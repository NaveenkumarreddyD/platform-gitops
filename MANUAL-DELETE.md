# MAS Manual Delete — every step (GitOps, all layers)

Full manual teardown of cluster **`drroc4`**, instance **`drgitopsapp`**. No CLI/scripts.
Run top to bottom. Order matters: **detach Argo → CRs → operators(sub+CSV) → namespaces → cluster-scoped → verify.**

```bash
# ---- set these once, used by every step ----
export ARGO_NS=openshift-gitops
export INSTANCE=drgitopsapp
export MONGO_NS=mongo-gitops
export DRO_NS=ibm-software-central
# all mas-<instance>-* namespaces (core, manage, sls, syncres, ...) discovered live:
export MAS_NS="$(oc get ns -o name | sed 's#namespace/##' | grep "^mas-${INSTANCE}" | tr '\n' ' ')"
echo "MAS namespaces: $MAS_NS"
```

---

## STEP 1 — Detach Argo CD (delete all Applications, non-cascade)
Kill the generator first, then every app for this cluster. Non-cascade = workloads stay for us to
remove in order (avoids Argo racing finalizers).
```bash
# account-root first (it regenerates children)
oc patch application ibm-mas-account-root -n $ARGO_NS --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
oc delete  application ibm-mas-account-root -n $ARGO_NS --wait=false 2>/dev/null || true

# every remaining app for this cluster (MAS + platform: operators, mongodb, mongodb-operator)
for app in $(oc get applications -n $ARGO_NS -o name | grep -E 'drroc4|mongodb|operators'); do
  oc patch $app -n $ARGO_NS --type merge -p '{"metadata":{"finalizers":null}}'
  oc delete $app -n $ARGO_NS --wait=false
done

# confirm none left managing anything
oc get applications -n $ARGO_NS
```

## STEP 2 — Delete MAS application CRs (Manage), leaf → root
```bash
for ns in $MAS_NS; do
  oc delete manageworkspace --all -n $ns --wait=false 2>/dev/null || true
  oc delete manageapp       --all -n $ns --wait=false 2>/dev/null || true
done
```

## STEP 3 — Delete MAS core CRs (Workspace, Suite)
```bash
for ns in $MAS_NS; do
  oc delete workspace.core.mas.ibm.com --all -n $ns --wait=false 2>/dev/null || true
  oc delete suite.core.mas.ibm.com     --all -n $ns --wait=false 2>/dev/null || true
done
```

## STEP 4 — Delete SLS and DRO CRs
```bash
# discover exact kinds if names differ:
oc get licenseservice -A 2>/dev/null; oc get datareporter -A 2>/dev/null
for ns in $MAS_NS; do
  oc delete licenseservice --all -n $ns --wait=false 2>/dev/null || true
done
oc delete datareporter --all -n $DRO_NS --wait=false 2>/dev/null || true
```

## STEP 5 — Wait, then force-clear any CR stuck Terminating
```bash
sleep 90
for kind in manageworkspace manageapp workspace.core.mas.ibm.com suite.core.mas.ibm.com \
            licenseservice datareporter; do
  for ns in $MAS_NS $DRO_NS; do
    for o in $(oc get $kind -n $ns -o name 2>/dev/null); do
      oc patch $o -n $ns --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done
  done
done
```

## STEP 6 — Delete MongoDB + cert-manager CRs (platform layer)
```bash
# MongoDB instance CR
oc delete mongodbcommunity --all -n $MONGO_NS --wait=false 2>/dev/null || true
sleep 20
for o in $(oc get mongodbcommunity -n $MONGO_NS -o name 2>/dev/null); do
  oc patch $o -n $MONGO_NS --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
done

# cert-manager Certificates/Issuers created for Mongo (do NOT remove cert-manager itself yet)
oc delete certificate,issuer -n $MONGO_NS --all --wait=false 2>/dev/null || true
```

## STEP 7 — Delete operators (Subscription + CSV TOGETHER = no orphans)
This is the step that prevents the orphaned-CSV deadlock. Do it for every MAS + platform namespace.
Skip OLM-copied CSVs (they belong to global operators).
```bash
purge_ops () {  # usage: purge_ops <namespace>
  local ns="$1"; oc get ns "$ns" >/dev/null 2>&1 || return 0
  echo ">> operators in $ns"
  for s in $(oc get subscription -n $ns -o name 2>/dev/null); do oc delete $s -n $ns --wait=false; done
  for c in $(oc get csv -n $ns -o json 2>/dev/null \
             | jq -r '.items[] | select(.metadata.annotations["olm.copiedFrom"]==null) | .metadata.name'); do
    oc delete csv $c -n $ns --wait=false
  done
  for og in $(oc get operatorgroup -n $ns -o name 2>/dev/null); do oc delete $og -n $ns --wait=false; done
}

for ns in $MAS_NS $DRO_NS $MONGO_NS; do purge_ops $ns; done
```

## STEP 8 — Delete the namespaces (force-clear if stuck Terminating)
```bash
for ns in $MAS_NS $DRO_NS $MONGO_NS; do
  oc delete ns $ns --wait=false 2>/dev/null || true
done
sleep 90
for ns in $MAS_NS $DRO_NS $MONGO_NS; do
  if [ "$(oc get ns $ns -o jsonpath='{.status.phase}' 2>/dev/null)" = "Terminating" ]; then
    oc get ns $ns -o json | jq 'del(.spec.finalizers)' \
      | oc replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
  fi
done
```

## STEP 9 — Delete cluster-scoped leftovers
```bash
# DRO ClusterRoleBindings (known names)
oc delete clusterrolebinding manager-cluster-monitoring-binding metric-state-view-binding \
  reporter-cluster-monitoring-binding 2>/dev/null || true

# anything MAS-labelled with this instance
for kind in clusterrolebinding clusterrole clusterissuer.cert-manager.io \
            validatingwebhookconfiguration mutatingwebhookconfiguration; do
  for o in $(oc get $kind -l "mas.ibm.com/instanceId=${INSTANCE}" -o name 2>/dev/null); do
    oc delete $o 2>/dev/null || true
  done
done
```

## STEP 10 — (FULL WIPE ONLY) remove cert-manager — LAST, and only if unused
```bash
# check nothing else on the cluster still uses cert-manager
oc get certificates,issuers,clusterissuers -A 2>/dev/null
# if clear, remove its operator (adjust ns to your install: cert-manager-operator):
for s in $(oc get subscription -n cert-manager-operator -o name 2>/dev/null); do oc delete $s -n cert-manager-operator; done
for c in $(oc get csv -n cert-manager-operator -o json 2>/dev/null | jq -r '.items[] | select(.metadata.annotations["olm.copiedFrom"]==null) | .metadata.name'); do
  oc delete csv $c -n cert-manager-operator 2>/dev/null || true
done
oc delete ns cert-manager cert-manager-operator --wait=false 2>/dev/null || true
```

## STEP 11 — Verify clean (must be empty before any reinstall)
```bash
echo "== orphaned/leftover MAS CSVs (expect none) =="
oc get csv -A | grep -iE 'ibm-mas|data-reporter|metrics|ibm-sls|mongodb|ibm-truststore' || echo "  none"

echo "== leftover namespaces (expect none) =="
oc get ns | grep -E "mas-${INSTANCE}|ibm-software-central|mongo-gitops" || echo "  none"

echo "== leftover MAS CRDs (optional to remove) =="
oc get crd | grep -E 'mas.ibm.com|sls.ibm.com|apps.ibm.com|mongodbcommunity' || echo "  none"
```

## STEP 12 — (only if NOT reinstalling) Argo CD config + secrets
```bash
oc delete appproject mas -n $ARGO_NS 2>/dev/null || true
# oc delete secret gitlab-gitops-group-repo-creds aws-static-credentials aws-static-credentials-publisher -n $ARGO_NS
# oc delete secret aws-static-credentials-publisher -n $MONGO_NS
```

---

### Notes
- **Reinstalling on the same cluster?** Stop after Step 9 — keep cert-manager (Step 10) and the Argo
  secrets (Step 12) so bootstrap can reuse them.
- **`jq` required** for Steps 7 and 8. If missing: `oc get csv -n <ns>` and delete non-copied ones by hand.
- If a delete hangs, it's a finalizer — the force-clear patches (Steps 5, 6, 8) handle it.
