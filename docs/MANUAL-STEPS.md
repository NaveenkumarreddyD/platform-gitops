# Manual step-by-step deployment (no auto-gates)

Run each step yourself, glance at the check, then run the next. Nothing here blocks
waiting on ArgoCD health — **you** are the gate. Use this instead of `stage.sh --all`
when you want full control. (`stage.sh` still works if you prefer automation.)

Cluster `drroc4`, instance `drgitopsapp`, config repo `../mas-config-repo`. Run from `platform-gitops/`.

> Before you start: `git pull` both repos on this box. Stale scripts caused most past failures.

---

## Step 1 — Bootstrap + Vault (one-time per cluster)

```bash
./scripts/setup-vault-platform.sh --store-k8s-secret drroc4
export VAULT_TOKEN="$(python3 -c "import json;print(json.load(open('vault-init-keys.json'))['root_token'])")"
./scripts/setup-vault-auth.sh
```
Check (don't proceed until both look right):
```bash
oc get pods -n vault                         # vault-0/1/2 Running
oc exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 vault status | grep -E 'Initialized|Sealed'
```

## Step 2 — Load secrets + public cert into Vault

```bash
export IBM_ENTITLEMENT_KEY='...'
export MAS_LICENSE_FILE='/path/license.dat'  MAS_LICENSE_ID='...'
export JDBC_USERNAME='...' JDBC_PASSWORD='...' JDBC_URL='jdbc:oracle:thin:@//host:1521/SVC'
export PFX_PASSWORD='<if any>'

./scripts/load-secrets.sh           ../mas-config-repo/envs/drroc4.env
./scripts/load-mas-public-cert.sh   ../mas-config-repo/envs/drroc4.env /path/cert.pfx
```
Check:
```bash
./scripts/preflight-vault.sh --phase static ../mas-config-repo/envs/drroc4.env   # all PASS
```

## Step 3 — Render + push config

```bash
( cd ../mas-config-repo && python3 render.py drroc4 && git add -A && git commit -m "deploy drroc4" && git push )
```
Check: commit pushed; ArgoCD will pick it up within ~3 min.

## Step 4 — Mongo prerequisites + CA

```bash
./scripts/prepare-prereqs.sh ../mas-config-repo/envs/drroc4.env
```
Check:
```bash
oc get mongodbcommunity -A                   # Running
./scripts/preflight-vault.sh --phase full ../mas-config-repo/envs/drroc4.env | grep -i mongo
```

## Step 5 — Account-root: generate the Suite (you watch the cascade)

```bash
oc annotate application ibm-mas-account-root -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
oc patch application ibm-mas-account-root -n openshift-gitops --type merge \
  -p '{"operation":{"initiatedBy":{"username":"oc"},"sync":{}}}'
```
Watch until the Suite CR appears (Ctrl-C when it does):
```bash
watch -n 15 'oc get applications -n openshift-gitops | grep -E "cluster\.drroc4|instance|suite\.drroc4"; \
  echo ---; oc get suite -n mas-drgitopsapp-core 2>/dev/null'
```
Proceed when `suite/drgitopsapp` exists. If `cluster.drroc4` is stuck OutOfSync, nudge it:
`oc patch application cluster.drroc4 -n openshift-gitops --type merge -p '{"operation":{"sync":{}}}'`

## Step 6 — Make the Suite verify MongoDB

```bash
./scripts/sync-mongo-ca.sh ../mas-config-repo/envs/drroc4.env
oc delete pod -n mas-drgitopsapp-core $(oc get pods -n mas-drgitopsapp-core -o name | grep ibm-mas-operator)
```
Check:
```bash
oc get suite drgitopsapp -n mas-drgitopsapp-core \
  -o jsonpath='{.status.conditions[?(@.type=="SystemDatabaseReady")].status}{"\n"}'   # want True
```

## Step 7 — SLS: harvest registration + enable

```bash
./scripts/sync-runtime-registration.sh --sls-only ../mas-config-repo/envs/drroc4.env
./scripts/enable-sls-config.sh --yes              ../mas-config-repo/envs/drroc4.env
```
Check:
```bash
oc get slscfg -n mas-drgitopsapp-core           # STATUS Ready, REGISTERED True
```

## Step 8 — JDBC (system DB for Manage)

```bash
./scripts/sync-jdbc-config.sh ../mas-config-repo/envs/drroc4.env
```
Check:
```bash
oc get jdbccfg -n mas-drgitopsapp-core          # Ready
```

## Step 9 — Suite Ready, then Manage

```bash
oc get suite drgitopsapp -n mas-drgitopsapp-core \
  -o custom-columns=STATUS:.status.status,SYSTEMDB:.status.conditions[?(@.type=="SystemDatabaseReady")].status,SLS:.status.conditions[?(@.type=="SLSIntegrationReady")].status
# when SYSTEMDB+SLS are True:
./scripts/enable-manage.sh --yes ../mas-config-repo/envs/drroc4.env
```
Check (Manage config can take a few hours — this is normal):
```bash
oc get manageapp,manageworkspace -n mas-drgitopsapp-manage
oc get pods -n mas-drgitopsapp-manage
```

## Step 10 — Verify

```bash
./scripts/verify-install.sh   ../mas-config-repo/envs/drroc4.env
./scripts/status-summary.sh   ../mas-config-repo/envs/drroc4.env
```

---

## Notes

- DRO/BAS is **off** for this run (`GITOPS_OWNS_DRO=false`) so it can't block the cascade. Add it after MAS is up (create `ibm-software-central` + `redhat-marketplace-pull-secret` with the entitlement key, set `GITOPS_OWNS_DRO=true`, re-render/push, then `./scripts/sync-runtime-registration.sh --dro-only` + `./scripts/enable-bas-config.sh`).
- The `platform-drroc4` root app will show **OutOfSync/Syncing parked at the jdbc wave** the whole time — that's expected and harmless. These steps sync the child apps directly; the root app settles after Step 8.
- Any step is safe to re-run. If a script's internal wait runs long, Ctrl-C and check status manually — the action it performs is idempotent.
