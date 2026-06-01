# platform-repo deployment notes

This repo is applied to the Management OpenShift cluster running OpenShift GitOps/ArgoCD.

## Required manual first steps

1. Create ArgoCD repository secret for the platform repo itself:

```bash
oc apply -f repo-secrets/platform-repo-secret.example.yaml
```

Use a real GitLab deploy token, but do not commit the real secret.

2. Create repository secrets for the MAS config repo and IBM source mirror:

```bash
oc apply -f repo-secrets/config-repo-secret.yaml
oc apply -f repo-secrets/source-repo-secret.yaml
```

3. Update `values-management.yaml` with real repo URLs and Vault host.

4. Apply bootstrap:

```bash
oc apply -f bootstrap.yaml
```

## Sync sequence

1. Sync `hashicorp-vault-server`.
2. Initialize and unseal Vault.
3. Run `vault/setup-vault.sh`.
4. Patch OpenShift GitOps ArgoCD CR for AVP:

```bash
oc patch argocd openshift-gitops -n openshift-gitops --type merge --patch-file argocd/argocd-cr-avp-sidecar-patch.yaml
```

5. Register target clusters:

```bash
cluster-registration/register-cluster.sh drroc4 <drroc4-context>
cluster-registration/register-cluster.sh roc4 <roc4-context>
```

6. Load MAS secrets into Vault from config-repo generated scripts.
7. Manually sync `ibm-mas-account-root`.
