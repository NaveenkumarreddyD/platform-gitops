# Easy MAS Deployment

This is the supported deployment path for `drroc4`.

## Prerequisites

- `oc` logged in as cluster-admin
- OpenShift GitOps installed in `openshift-gitops`
- `helm`, `git`, `python3`, `jq`, `openssl`
- Vault root/admin token available after init
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

## Day 0

```bash
./bootstrap/apply.sh drroc4
bash scripts/init-vault.sh --store-k8s-secret
```

Export the printed Vault token, then run the installer.

## Install

```bash
./scripts/install-ibm-way.sh --yes ../mas-gitops-config/envs/drroc4.env
```

The installer runs this order and waits at each gate:

```text
Vault/static secrets
MongoDB + Mongo CA
MAS account-root
SLS registration + SLSCfg
JdbcCfg
DRO registration + BASCfg
Suite Ready
ManageApp + ManageWorkspace
Verification
```

## Verify

```bash
./scripts/verify-install.sh ../mas-gitops-config/envs/drroc4.env
./scripts/status-summary.sh ../mas-gitops-config/envs/drroc4.env
```

## Re-run

The installer is safe to rerun after a transient failure:

```bash
./scripts/install-ibm-way.sh --yes ../mas-gitops-config/envs/drroc4.env
```

It uses hard refreshes, explicit syncs, and direct CR readiness checks, so it does not depend on
Argo CD's default repo polling delay.
