# Staged MAS + Manage Bring-Up

This is the safer drroc4 path. Each phase creates only resources whose prerequisites already exist.
For this MAS 8.11 topology, DRO/BAS is treated as a required pre-Manage gate because Suite readiness
depends on `BasIntegrationReady` when IBM chart defaults enable contract/performance reporting.

Initial config gates in `mas-gitops-config/envs/drroc4.env`:

```bash
ENABLE_SLS_CONFIG=false
ENABLE_MANAGE=false
ENABLE_BAS_CONFIG=false
GITOPS_OWNS_DRO=true
```

Initial platform gate in `platform-gitops/gitops/envs/drroc4/values.yaml`:

```yaml
dro: { namespace: ibm-software-central, syncEnabled: true }
```

## One Command Path

After `./bootstrap/apply.sh drroc4`, Vault init/unseal, and exporting the required secret inputs,
run:

```bash
./scripts/install-ibm-way.sh --yes ../mas-gitops-config/envs/drroc4.env
```

This runs the supported order:

```text
Vault/static secrets -> Mongo -> account-root -> SLS registration -> SLSCfg ->
JdbcCfg -> DRO registration -> BASCfg -> Suite Ready -> Manage
```

## 0. Clean-State Check

```bash
oc get applications,applicationsets -n openshift-gitops | grep -E 'drroc4|drgitopsapp' || true
oc get ns | grep -E 'drgitopsapp|mongo-drgitops|ibm-software-central' || true
oc get subscription,csv,installplan,operatorgroup -A | grep -E 'drgitopsapp|ibm-software-central' || true
```

Do not reinstall until those commands are empty.

## 1. Push First-Stage Config

From `mas-gitops-config`:

```bash
python3 render.py drroc4
git add envs/drroc4.env render.py base/instance/ibm-mas-suite-configs.yaml.tpl mas/drroc4
git commit -m "stage drroc4 MAS install"
git push
```

From `platform-gitops`:

```bash
git add gitops/envs/drroc4/values.yaml gitops/templates/apps/50-runtime-sync scripts
git commit -m "stage drroc4 runtime gates"
git push
```

Push these to the GitLab repos Argo CD reads, not only to a local mirror.

## 2. Bootstrap Platform + Vault

```bash
cd platform-gitops
./bootstrap/apply.sh drroc4

bash scripts/init-vault.sh --store-k8s-secret
export VAULT_TOKEN='<root token from init-vault>'
```

Load static secret material:

```bash
export IBM_ENTITLEMENT_KEY='...'
export MAS_LICENSE_FILE='/path/license.dat'
export MAS_LICENSE_ID='...'
export JDBC_USERNAME='...'
export JDBC_PASSWORD='...'
export JDBC_URL='jdbc:oracle:thin:@//host:1521/SVC'

./scripts/deploy.sh --yes ../mas-gitops-config/envs/drroc4.env
./scripts/prepare-prereqs.sh ../mas-gitops-config/envs/drroc4.env
```

This stops with Vault, MongoDB, Mongo CA, static secrets, and first-stage MAS config ready.

## 3. Start MAS Foundation Only

```bash
./scripts/sync-mas-account-root.sh ../mas-gitops-config/envs/drroc4.env
./scripts/check-olm-catalog.sh ../mas-gitops-config/envs/drroc4.env
```

Expected first-stage generated scope:

- IBM operator catalog
- Suite/Core operator
- DRO/Data Reporter
- dedicated SLS
- workspace
- MongoCfg only

Not expected yet:

- SLSCfg
- BASCfg
- ManageApp
- ManageWorkspace

Watch:

```bash
oc get applications -n openshift-gitops | grep -E 'drroc4|drgitopsapp'
oc get licenseservice -n mas-drgitopsapp-sls
```

## 4. Harvest SLS Registration, Then Enable SLSCfg

After `licenseservice/sls` has a registration key:

```bash
./scripts/sync-runtime-registration.sh --sls-only ../mas-gitops-config/envs/drroc4.env
./scripts/enable-sls-config.sh --yes ../mas-gitops-config/envs/drroc4.env
```

This writes `secret/mas/drroc4/drgitopsapp/sls` in Vault, flips `ENABLE_SLS_CONFIG=true`,
renders/commits/pushes config, and syncs `drgitopsapp-sls-system.drroc4`.

## 5. Sync JDBC

After Suite has registered MAS config CRDs:

```bash
./scripts/sync-jdbc-config.sh ../mas-gitops-config/envs/drroc4.env
```

Verify the three system configs exist:

```bash
oc get mongocfgs,slscfgs,jdbccfgs -n mas-drgitopsapp-core
```

## 6. Harvest DRO Registration, Then Enable BASCfg

After DRO has a route and token:

```bash
./scripts/sync-runtime-registration.sh --dro-only ../mas-gitops-config/envs/drroc4.env
./scripts/enable-bas-config.sh --yes ../mas-gitops-config/envs/drroc4.env
```

Verify all system configs and Suite are Ready:

```bash
oc get mongocfgs,slscfgs,jdbccfgs,bascfgs -n mas-drgitopsapp-core
oc get suite drgitopsapp -n mas-drgitopsapp-core
```

## 7. Enable Manage

```bash
./scripts/enable-manage.sh --yes ../mas-gitops-config/envs/drroc4.env
```

Watch:

```bash
oc get applications -n openshift-gitops | grep -E 'manage.drroc4.drgitopsapp|drgitopswks'
oc get pods -n mas-drgitopsapp-manage -w
```

## Diagnostics

```bash
./scripts/status-summary.sh ../mas-gitops-config/envs/drroc4.env
./scripts/app-diagnostics.sh ../mas-gitops-config/envs/drroc4.env
./scripts/preflight-vault.sh --phase full ../mas-gitops-config/envs/drroc4.env
```

If OLM fails, inspect the exact namespace:

```bash
oc get subscription,csv,installplan,operatorgroup -A | grep -E 'drgitopsapp|ibm-software-central'
oc describe subscription <name> -n <namespace>
```
