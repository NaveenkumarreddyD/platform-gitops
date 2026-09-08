# Operational scripts

| Script | Purpose |
|---|---|
| `preflight-consistency.sh <env>` | Read-only cross-repository identity, release, and secret-prefix check |
| `status.sh <env>` | Read-only Argo CD, AWS authentication, MongoDB, and MAS status |
| `capture-manage-crypto.sh <env>` | Save generated Manage encryption keys using the caller's federated AWS session |
| `seed-aws-secrets.sh` | Create/update all AWS Secrets Manager secrets for one instance (env-driven, idempotent) |
| `teardown-cluster.sh <cluster> <instance>` | Ordered, orphan-safe teardown of one MAS instance (Argo apps → CRs → operators sub+CSV → namespaces). `--dry-run` previews. |

The numbered files in `../bootstrap` are the install wrappers. `seed-aws-secrets.sh`
prepares the secrets those wrappers rely on. Teardown can be done via `teardown-cluster.sh`
(local dev) or the reviewed GitOps procedure in `../UNINSTALL.md` (recommended).

PowerScale S3 attachment configuration remains an application-level Manage procedure;
see `mas-gitops-config/docs/manage-attachments-powerscale-s3.md`.
