# IBM MAS platform GitOps

This repository is a thin App-of-Apps wrapper for a fresh IBM MAS installation on
OpenShift. Argo CD performs reconciliation; operators run only the documented day-0
commands and manually administer Vault while it is the temporary secret backend.

## Repositories

| Repository | Responsibility | Required revision |
|---|---|---|
| `platform-gitops` | Vault, MongoDB, bootstrap, and the IBM account root | `main` after this change is merged |
| `mas-gitops-config` | Direct IBM cluster and instance configuration | `main` |
| `ibm-mas-gitops` | IBM release plus the temporary Vault/JDBC compatibility patch | `8.4.0-vault-patch` |

## Install stages

| Stage | Applications created |
|---|---|
| `secrets` | Vault only |
| `database` | Vault, MongoDB operator, and MongoDB instance |
| `mas` | Previous stages plus IBM's account root and optional Grafana |

The stage is set in `gitops/envs/drroc4/values.yaml`. IBM's own account, cluster,
and instance roots handle the MAS order after the `mas` stage begins.

## Layout

```text
bootstrap/   One-time Argo CD resources and CR patches
gitops/      Staged App-of-Apps Helm chart
workloads/   Small MongoDB, Grafana, and optional operator charts
vault-auth/  Least-privilege Vault policies and role documentation
scripts/     Legacy recovery/diagnostic utilities; not used by INSTALL.md
```

Start with [INSTALL.md](INSTALL.md). Use [RUNBOOK.md](RUNBOOK.md) only for status,
troubleshooting, and recovery.

## Temporary divergence

IBM MAS GitOps `8.4.0` supports AWS Secrets Manager. Until AWS access is available,
the internal `8.4.0-vault-patch` branch changes only SLS/DRO runtime write-back and
the external Oracle JDBC SSL toggle. See `PATCH.md` in that repository. Revert to an
unmodified IBM release when AWS Secrets Manager and Oracle TCPS are available.
