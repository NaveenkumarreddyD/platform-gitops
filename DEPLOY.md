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

## MAS Install Or Recreate

For normal MAS install, reinstall, or Manage recreate, reuse the existing Vault:

```bash
./scripts/install-ibm-way.sh --yes ../mas-gitops-config/envs/drroc4.env
```

The installer runs this order and waits at each gate:

```text
Vault auth/static secret refresh
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

The installer is safe to rerun after a transient failure or MAS resource recreate:

```bash
./scripts/install-ibm-way.sh --yes ../mas-gitops-config/envs/drroc4.env
```

It uses hard refreshes, explicit syncs, and direct CR readiness checks, so it does not depend on
Argo CD's default repo polling delay.
