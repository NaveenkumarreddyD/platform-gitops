# Operational scripts

| Script | Purpose |
|---|---|
| `preflight-consistency.sh <env>` | Read-only cross-repository identity, release, and secret-prefix check |
| `status.sh <env>` | Read-only Argo CD, AWS authentication, MongoDB, and MAS status |
| `capture-manage-crypto.sh <env>` | Save generated Manage encryption keys using the caller's federated AWS session |

The numbered files in `../bootstrap` are the only install wrappers. Teardown and
recovery are deliberately documented as reviewed operator procedures instead of hidden
behind destructive scripts.

PowerScale S3 attachment configuration remains an application-level Manage procedure;
see `mas-gitops-config/docs/manage-attachments-powerscale-s3.md`.
