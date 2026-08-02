# IBM MAS platform GitOps

Deploys a fresh IBM MAS installation on OpenShift with HashiCorp Vault as the temporary
secrets backend (until AWS Secrets Manager). Argo CD reconciles; operators run the numbered
bootstrap scripts and administer Vault manually while it is the temporary backend.

## Repositories

| Repository | Responsibility | Branch |
|---|---|---|
| `platform-gitops` | Operators (cert-manager), Vault, MongoDB, bootstrap, IBM account root | `mas-vault-deploy` |
| `mas-gitops-config` | IBM cluster + instance configuration (per-account) | `mas-vault-deploy` |
| `ibm-mas-gitops` | IBM release + temporary Vault/JDBC compatibility patch | `8.4.0-vault-patch` |

## Decoupled components

No app-of-apps, no `installStage`. Operators, Vault, MongoDB, and MAS are **independent** Argo CD
Applications, each deployed by its own numbered script and coupled only through Vault secret paths:

```text
00-prereqs → 05-operators → 10-vault → 11-vault-config → seed-secrets → 12-vault-verify → 20-mongodb → 30-mas
```

Each script asserts its prerequisite and refuses to run early. `./scripts/status.sh <env>` shows
every component at a glance. Any layer can be redeployed on its own.

## Layout

```text
bootstrap/   Numbered install scripts + seed-secrets + one-time Argo CD resources/patches
gitops/      Component Helm chart (--set component=…) + per-env values (envs/<cluster>/)
workloads/   MongoDB, OLM operators (cert-manager/grafana), and Grafana charts
vault-auth/  Least-privilege Vault policies
scripts/     status, preflight, teardown
```

Start with [INSTALL.md](INSTALL.md); use [RUNBOOK.md](RUNBOOK.md) for troubleshooting and recovery.

## Temporary Vault workaround

IBM MAS GitOps `8.4.0` supports AWS Secrets Manager. Until that is available, the internal
`8.4.0-vault-patch` branch changes only the SLS/DRO runtime write-back (to Vault instead of AWS SM)
and the external Oracle JDBC SSL toggle — see `PATCH.md` in that repository. Revert to an
unmodified IBM release when AWS Secrets Manager and Oracle TCPS are available.
