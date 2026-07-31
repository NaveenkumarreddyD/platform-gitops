# Vault authentication

Vault is temporary. It uses Kubernetes authentication with two roles:

| Role | Service account | Namespace | Policy |
|---|---|---|---|
| `mas-gitops` | Argo CD repo-server SA | `openshift-gitops` | Read `secret/mas/*` |
| `mas-gitops-writer` | `postsync-ibm-sls-update-sm-sa` | `mas-drgitopsapp-sls` | Write instance SLS registration |
| `mas-gitops-writer` | `postsync-ibm-dro-update-sm-sa` | `ibm-software-central` | Write cluster DRO registration |

`mas-gitops-policy.hcl` is read-only. `mas-gitops-writer-policy.hcl` is restricted
to the two generated registration paths. The exact role creation commands are in
`INSTALL.md`.

Do not store initialization keys, unseal keys, or the root token in Kubernetes or Git.
Until a supported auto-unseal mechanism is available, an authorized operator must
unseal each Vault pod after a restart.
