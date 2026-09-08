# MAS Uninstall — GitOps-safe (IBM-recommended)

For a **GitOps** install you must **detach Argo CD first**, then use IBM's supported
`mas uninstall`, then verify no leftovers. Cluster **`drroc4`**, instance **`drgitopsapp`**.

Order: **detach Argo CD → `mas uninstall` → verify/clean.**

---

## Step 1 — Detach Argo CD (stop it re-syncing)
Delete the Argo CD Applications **without cascade** (strip the finalizer so they don't hang, and
leave the workloads in place for `mas uninstall` to remove). Delete the **account-root first** so it
stops regenerating children.

```bash
ARGO_NS=openshift-gitops

# why: kill the generator first, or it recreates the child apps.
oc patch application ibm-mas-account-root -n $ARGO_NS --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
oc delete application ibm-mas-account-root -n $ARGO_NS --wait=false 2>/dev/null || true

# why: detach every MAS app for this cluster (non-cascade = workloads stay, Argo stops managing).
for app in $(oc get applications -n $ARGO_NS -o name | grep drroc4); do
  oc patch $app -n $ARGO_NS --type merge -p '{"metadata":{"finalizers":null}}'
  oc delete $app -n $ARGO_NS --wait=false
done

# why: confirm nothing MAS-related is left syncing.
oc get applications -n $ARGO_NS | grep -E 'drroc4|account-root' || echo "detached: no MAS apps"
```
> Pure-GitOps alternative to Step 1: remove the instance + cluster config from the
> `mas-gitops-config` repo, `./render.sh drroc4`, push — the root app prunes the children.
> Deleting the Application objects (above) is more reliable and is what makes `mas uninstall` safe.

## Ownership — what MAS owns vs what YOU own
- **MAS owns** (remove with `mas uninstall`): Core, apps (Manage), **SLS**, **DRO** (+ their OLM operators).
- **YOU own** (remove via platform-gitops, NOT the mas cli): **MongoDB** (operator + CA + publish job)
  and **cert-manager** — you installed these in `20-mongodb.sh` / `05-operators.sh`. MAS only *uses* them.
- `mas uninstall --uninstall-mongodb/--uninstall-cert-manager` targets IBM's *own* Mongo/cert-manager
  install — **not yours** — so do NOT use those flags. Remove yours in Step 2b.

**Order:** MAS first (it depends on Mongo) → MongoDB → cert-manager **last** (it underpins the Mongo CA).

## Step 2 — Uninstall MAS only (+ SLS/DRO) with the supported CLI
```bash
# why: you must be logged in; the CLI drives the official MAS uninstall pipeline on THIS cluster.
oc login <api-url> -u <user>

# why: removes MAS core + apps + SLS + DRO (and cleans their CSVs). NOT mongo/cert-manager — those are yours.
docker run -ti --rm --pull always quay.io/ibmmas/cli mas uninstall \
  --mas-instance-id drgitopsapp \
  --uninstall-sls \
  --uninstall-dro \
  --no-confirm
# podman works too. If quay.io is blocked, use your internal mirror of quay.io/ibmmas/cli.
# Mongo data is preserved regardless (you own Mongo). Interactive form: run with no flags.
```

## Step 2b — Remove MongoDB + cert-manager (yours) — ONLY for a full wipe
Skip this if you plan to reinstall MAS on the same cluster (keep Mongo + cert-manager in place).
```bash
# why: remove YOUR MongoDB (operator + CA + publish job) after MAS is gone.
oc delete mongodbcommunity --all -n mongo-gitops --wait=false 2>/dev/null || true
oc delete subscription -n mongo-gitops --all 2>/dev/null || true
for c in $(oc get csv -n mongo-gitops -o name 2>/dev/null); do oc delete $c -n mongo-gitops; done
oc delete ns mongo-gitops --wait=false 2>/dev/null || true

# why: cert-manager LAST, and only if nothing else on the cluster uses it.
#      (Mongo CA, and possibly other workloads, depend on it — check first.)
oc get certificates,issuers,clusterissuers -A | grep -v mongo    # anything else using cert-manager?
# if clear, remove the cert-manager operator (adjust ns/name to your install):
# oc delete subscription cert-manager -n cert-manager 2>/dev/null || true
# for c in $(oc get csv -n cert-manager -o name); do oc delete $c -n cert-manager; done
```

## Step 3 — Verify no leftovers (the stuff that breaks the next install)
```bash
# why: orphaned CSVs deadlock the next OLM install (your DRO issue). Expect NONE.
oc get csv -A | grep -iE 'ibm-mas|data-reporter|metrics|ibm-sls|mongodb' || echo "no MAS CSVs"

# why: namespaces stuck Terminating hold the instance name. Expect NONE.
oc get ns | grep -E 'mas-drgitopsapp|ibm-software-central|mongo-gitops' || echo "no MAS namespaces"

# why: one-shot report of both, plus force-clears anything stuck.
./scripts/teardown-cluster.sh drroc4 drgitopsapp --dry-run
```

## Step 4 — Remove residual Argo CD config (only if NOT reinstalling)
```bash
oc delete appproject mas -n openshift-gitops 2>/dev/null || true
# repo cred / AWS keys — keep them if you plan to reinstall:
# oc delete secret gitlab-gitops-group-repo-creds aws-static-credentials aws-static-credentials-publisher -n openshift-gitops
```

---

## If `mas uninstall` isn't usable (no quay access / air-gapped)
Your `teardown-cluster.sh` does the same ordered teardown manually and is safe to use instead of
Step 2 (it deletes each operator's Subscription + CSV together, so no orphans, and force-clears
stuck finalizers):
```bash
./scripts/teardown-cluster.sh drroc4 drgitopsapp --dry-run   # preview
./scripts/teardown-cluster.sh drroc4 drgitopsapp             # do it
```
This is the non-IBM-tool fallback; the IBM-recommended path is Step 1 → `mas uninstall` → verify.
