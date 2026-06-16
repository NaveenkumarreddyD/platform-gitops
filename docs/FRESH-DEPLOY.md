# Fresh MAS + Manage Deployment (drroc4 / drgitopsapp)

End-to-end steps for a brand-new install on a clean cluster, using HashiCorp Vault + the
staged installer. Replace `drroc4` (cluster) / `drgitopsapp` (instance) and the config-repo
path (`../mas-config-repo`) with your own if different.

Order in one line:
**prereqs → Vault platform → Vault auth → load secrets+cert → `stage.sh --all` → verify.**

---

## 0. Prerequisites (do these before anything)

- `oc` logged in to the target cluster **as cluster-admin**.
- **OpenShift GitOps** operator installed (namespace `openshift-gitops`).
- CLI tools on the bastion: `oc`, `helm`, `git`, `python3`, `jq`, `openssl`.
- **Private repo creds** for ArgoCD: copy the example and fill in a GitLab PAT so Argo can
  read the platform/source/config repos:
  ```bash
  cp bootstrap/00-prereqs/repo-creds/gitlab-group-repo-creds.example.yaml \
     bootstrap/00-prereqs/repo-creds/gitlab-group-repo-creds.yaml
  # edit it: set the GitLab URL + username + PAT
  ```
- **Per-cluster gitops values** exist: `gitops/envs/drroc4/common.yaml` + `values.yaml` (already present for drroc4).
- **Config repo** cloned next to platform-gitops, with `envs/drroc4.env` filled in
  (version pins, IDs, domain, namespaces). Its git remote must point at the GitLab repo ArgoCD reads.
- **Inputs you must have on hand:**
  - IBM entitlement key
  - MAS `license.dat` file (raw entitlement text)
  - Oracle JDBC username / password / URL (non-SSL `jdbc:oracle:thin:@//host:1521/SVC`)
  - The **MAS public TLS certificate as a PFX** (this cluster uses manual cert management),
    with SANs covering the MAS route hosts (`admin.`, `api.`, `auth.`, `home.`, `<workspace>.home.`).

---

## 1. Platform + Vault bootstrap (one-time per cluster)

This applies the day-0 prereqs, patches ArgoCD (AVP sidecar **and** MAS custom-resource
healthchecks), deploys the app-of-apps root, brings up Vault, and initializes/unseals it.

```bash
cd platform-gitops
./scripts/setup-vault-platform.sh --store-k8s-secret drroc4
```

`--store-k8s-secret` saves the Vault unseal keys + root token into a Kubernetes Secret so you
don't lose them. Retrieve the root token when it finishes:

```bash
# the secret name is printed by the script; typically in ns/vault
oc get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' | base64 -d ; echo
```

> Re-installs later must **reuse** this Vault — do not delete Vault PVCs or rerun this as a reset.

---

## 2. Vault auth for AVP

```bash
export VAULT_TOKEN='<root token from step 1>'
./scripts/setup-vault-auth.sh        # k8s auth + reader/writer roles (auto-detects repo-server SA)
```

---

## 3. Load the static secrets + public certificate into Vault

Export the inputs (the loader auto-generates superuser, manage-crypto, and mongo/sls-mongo
passwords and reuses them on re-runs):

```bash
export VAULT_TOKEN='<root token>'
export IBM_ENTITLEMENT_KEY='...'
export MAS_LICENSE_FILE='/path/to/license.dat'
export MAS_LICENSE_ID='...'                       # optional
export JDBC_USERNAME='...'
export JDBC_PASSWORD='...'
export JDBC_URL='jdbc:oracle:thin:@//host:1521/SERVICE'
# export JDBC_CA_CRT=/path/ca.pem                 # ONLY for TCPS; omit for non-SSL Oracle
```

Load the MAS public certificate (manual cert management — required before the Suite reconciles):

```bash
export PFX_PASSWORD='<pfx password, if any>'
./scripts/load-mas-public-cert.sh ../mas-config-repo/envs/drroc4.env /path/to/mas-public-cert.pfx
./scripts/preflight-public-cert.sh ../mas-config-repo/envs/drroc4.env   # expect PASS x3
```

(The static secrets themselves are written by the `vault` stage in step 4 — you just need the
env vars above exported in the same shell.)

---

## 4. Staged install

One command runs everything in order; each stage verifies the **real** CR condition and stops
with diagnostics if it can't:

```bash
./scripts/stage.sh --all --yes ../mas-config-repo/envs/drroc4.env
```

Stage order and what each proves:

```
preflight     tools / cluster / Vault / secret + version knobs set
vault         Vault auth + load static secrets + render & push config   -> static secrets valid
cert          MAS public cert present in Vault                          -> tls/key/ca decode to PEM
mongo         dedicated MongoDB up + Mongo CA published                 -> Mongo CA secret exists
account-root  sync IBM MAS account-root                                 -> Suite CR + config CRDs exist
catalog       operator catalog carries MAS/SLS/Manage channels          -> version availability gate
mongo-verify  reconcile Mongo CA                                        -> Suite SystemDatabaseReady=True
sls           harvest SLS registration -> Vault; enable SLSCfg          -> SLSCfg Ready + SLSIntegrationReady
jdbc          sync system JdbcCfg                                       -> JdbcCfg Ready
bas           harvest DRO -> Vault; enable BASCfg                       -> BASCfg Ready + BASIntegrationReady
suite         wait for Suite Ready                                      -> Suite Ready
manage        enable Manage                                             -> ManageApp + ManageWorkspace Ready
verify        full verify-install (CSV versions == env target versions)
```

If a stage fails, fix the cause it prints, then re-run just that stage and continue:

```bash
./scripts/stage.sh --only sls ../mas-config-repo/envs/drroc4.env       # re-run one
./scripts/stage.sh --from mongo-verify ../mas-config-repo/envs/drroc4.env  # resume from here
```

`stage.sh --all` resumes from the last completed stage automatically (checkpoint in
`.install-state/drroc4.done`). Use `--force` to redo everything.

> Timing note: the `manage` stage is long (Manage config can take a few hours) — this is normal.

---

## 5. Verify

```bash
./scripts/stage.sh --only verify ../mas-config-repo/envs/drroc4.env
./scripts/status-summary.sh        ../mas-config-repo/envs/drroc4.env
```

Watch Manage come up:

```bash
oc get suite drgitopsapp -n mas-drgitopsapp-core \
  -o custom-columns=STATUS:.status.status,SYSTEMDB:.status.conditions[?(@.type=="SystemDatabaseReady")].status,SLS:.status.conditions[?(@.type=="SLSIntegrationReady")].status,BAS:.status.conditions[?(@.type=="BASIntegrationReady")].status,READY:.status.conditions[?(@.type=="Ready")].status
oc get pods -n mas-drgitopsapp-manage -w
```

---

## Teardown (to start over)

```bash
# pauses Argo controllers during cleanup and ALWAYS restores them at the end
./scripts/delete-gitops-platform.sh --confirm --include-vault ../mas-config-repo/envs/drroc4.env
rm -f .install-state/drroc4.done     # so the next --all runs every stage fresh
```

---

## Key facts

- **Versions** are pinned in `envs/drroc4.env`: `MAS_CATALOG_VERSION` (master pin) +
  `MAS_CHANNEL`/`SLS_CHANNEL`/`MAS_APP_CHANNEL` + `MAS_TARGET_VERSION`/`MANAGE_TARGET_VERSION`.
  The `catalog` stage fails if the catalog can't serve them; `verify` fails if the live CSVs differ.
- **Secrets** never leave Vault — rendered config contains only AVP `<path:secret/data/...>` references.
- **IBM charts are never modified** — all adaptation lives in platform-gitops + the config repo.
