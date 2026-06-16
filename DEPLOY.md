# Easy MAS Deployment

This is the supported deployment path for `drroc4`.

## Prerequisites

- `oc` logged in as cluster-admin
- OpenShift GitOps installed in `openshift-gitops`
- `helm`, `git`, `python3`, `jq`, `openssl`
- Existing Vault is initialized/unsealed, with root/admin token available
- Required secret inputs exported:

```bash
export VAULT_TOKEN='<vault root/admin token>'
export IBM_ENTITLEMENT_KEY='...'
export MAS_LICENSE_FILE='/path/license.dat'
export MAS_LICENSE_ID='...'
export JDBC_USERNAME='...'
export JDBC_PASSWORD='...'
export JDBC_URL='jdbc:oracle:thin:@//host:1521/SVC'
```

## One-Time Platform Vault Setup

```bash
./scripts/setup-vault-platform.sh --store-k8s-secret drroc4
export VAULT_TOKEN='<vault root/admin token>'
./scripts/setup-vault-auth.sh
```

Run this once per cluster. Do not delete Vault PVCs or recreate Vault for a MAS reinstall.

### Load the MAS public certificate (manual cert management)

This cluster runs MAS with **manual certificate management**, so you MUST load the public
route certificate into Vault before installing. If you skip this, `<instanceId>-cert-public`
renders empty and the Suite operator's "Get Public Route certificates and key" task fails
with a NoneType error and aborts the entire Suite reconcile (catalogmgr stuck `Init:0/1`,
`mas-mongo-config` / `mas-mongo-credentials` / `<instance>-sls-cfg` never created, Suite
stuck `IncompleteConfiguration`).

```bash
export VAULT_TOKEN='<vault root/admin token>'
export PFX_PASSWORD='<pfx password if any>'
./scripts/load-mas-public-cert.sh ../mas-gitops-config/envs/drroc4.env /path/to/mas-public-cert.pfx
# verify:
./scripts/preflight-public-cert.sh ../mas-gitops-config/envs/drroc4.env
```

The installer also runs `preflight-public-cert.sh` automatically before account-root and
will stop with this instruction if the cert is missing.

## Controlling which versions deploy

Three knobs in the cluster env file decide what gets installed:

```bash
MAS_CHANNEL=8.11.x            # ibm-mas operator subscription channel
SLS_CHANNEL=3.x              # ibm-sls operator subscription channel
MAS_APP_CHANNEL=8.7.x         # ibm-mas-manage operator subscription channel
MAS_TARGET_VERSION=8.11.26    # exact MAS CSV to expect/verify
MANAGE_TARGET_VERSION=8.7.24  # exact Manage CSV to expect/verify
```

How they combine:

- The **operator-catalog image** (set in the config repo / account-root) determines which CSVs exist at all.
- The **channels** select the stream the Subscriptions follow.
- The **target versions** are what we assert is actually installed.

These are now enforced automatically:

- `check-env` (preflight stage) fails if any of the five are unset.
- The `catalog` stage runs `check-olm-catalog.sh` after account-root and **fails fast if the catalog does not carry the requested channels** — so you never silently get the wrong version or an unresolvable Subscription.
- The `verify` stage checks the live MAS and Manage CSVs match `MAS_TARGET_VERSION` / `MANAGE_TARGET_VERSION`.

To move to a new version: bump the catalog image (config repo) and the channel/target-version values, push, then re-run the affected stages.

## MAS Install Or Recreate (staged)

The install is split into named, idempotent **stages**, each of which does
`preflight -> apply -> verify`. A stage proves its own real outcome (the CR condition,
not just "Argo Synced") and, if it fails, stops immediately, dumps the relevant CR
conditions + operator log, and prints the exact fix. You then re-run just that stage.

Run everything (resumes from the last completed stage on re-run):

```bash
./scripts/stage.sh --all --yes ../mas-gitops-config/envs/drroc4.env
# (./scripts/install-ibm-way.sh --yes <env> is a thin wrapper around the same thing)
```

Stage order and what each verifies:

```text
preflight     tools, cluster access, Vault, secret inputs
vault         Vault auth + static secrets + render/push config   -> static secrets well-formed
cert          MAS public cert present in Vault (manual cert mgmt) -> tls/key/ca decode to PEM
mongo         MongoDB prereqs + publish Mongo CA                  -> Mongo CA secret exists
account-root  sync IBM MAS account-root                          -> Suite CR + config CRDs exist
mongo-verify  reconcile Mongo CA                                 -> Suite SystemDatabaseReady=True
sls           harvest SLS registration; enable SLSCfg            -> SLSCfg Ready + SLSIntegrationReady
jdbc          sync system JdbcCfg                                -> JdbcCfg Ready
bas           harvest DRO; enable BASCfg                         -> BASCfg Ready + BASIntegrationReady
suite         wait for Suite Ready                               -> Suite Ready
manage        enable Manage                                      -> ManageApp + ManageWorkspace Ready
verify        full verify-install
```

### Run, inspect, or re-run individual stages

```bash
./scripts/stage.sh --list                                   # show all stages
./scripts/stage.sh --only sls          ../mas-gitops-config/envs/drroc4.env   # one stage
./scripts/stage.sh --from mongo-verify ../mas-gitops-config/envs/drroc4.env   # from here to the end
./scripts/stage.sh --from sls --to bas ../mas-gitops-config/envs/drroc4.env   # a range
./scripts/stage.sh --all --force       ../mas-gitops-config/envs/drroc4.env   # ignore checkpoint, redo all
```

Checkpoint state lives in `.install-state/<cluster>.done`. `--all` skips stages already
recorded there; `--only`/`--from` always run what you ask for.

## Verify

```bash
./scripts/stage.sh --only verify ../mas-gitops-config/envs/drroc4.env
./scripts/status-summary.sh        ../mas-gitops-config/envs/drroc4.env
```

## Re-run

Safe to rerun after a transient failure or a MAS resource recreate — it resumes from the
checkpoint and each stage uses hard refreshes, explicit syncs, and direct CR readiness
checks, so it does not depend on Argo CD's default repo polling delay:

```bash
./scripts/stage.sh --all --yes ../mas-gitops-config/envs/drroc4.env
```
