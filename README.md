# platform-gitops (IBM-aligned, hub-and-spoke, HashiCorp Vault)

One management cluster runs ArgoCD + one Vault + ONE Account Root Application that deploys MAS to
every registered Target (spoke) cluster. This matches IBM's documented architecture, using Vault
(via the ArgoCD Vault Plugin) instead of AWS Secrets Manager.

## One-time management-cluster setup
1. Install Red Hat OpenShift GitOps.
2. Patch the ArgoCD CR so repo-server runs the AVP sidecar and mounts the `cmp-plugin` ConfigMap
   (see docs/ADD-CLUSTER.md - prerequisites).
3. Edit `values-management.yaml` (repos, vault host) and apply `bootstrap.yaml`.
4. Initialise/unseal Vault, then run `vault/setup-vault.sh` (KV v2 + k8s auth role `mas-gitops`).
5. Apply `repo-secrets/*.yaml`.
6. Sync the `management-bootstrap` app, then the `ibm-mas-account-root` app.

## Adding clusters
See **docs/ADD-CLUSTER.md** - the per-cluster runbook.
