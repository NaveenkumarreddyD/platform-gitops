# Bootstrap — decoupled component install

Run these in order, per cluster (each asserts its prerequisite and prints the next step).
There is no app-of-apps and no `installStage`; ordering is enforced by the scripts.

```text
00-prereqs.sh <env>       GitLab CA, RBAC, AppProject, AVP plugin, ArgoCD CR patches   (once per cluster)
05-operators.sh <env>     OLM operators: cert-manager (+ grafana-operator if enabled) → waits for CRDs
10-vault.sh <env>         deploy Vault           → then init + unseal (manual, INSTALL.md §4)
11-vault-config.sh <env>  kv-v2 + k8s auth + policies + roles   (needs VAULT_ROOT_TOKEN)
seed-secrets.sh <env>     seed static secrets from EXPORTED vars (derives all Vault paths)
12-vault-verify.sh <env>  READ-ONLY: assert every required secret is seeded
20-mongodb.sh <env>       deploy MongoDB         → waits for Running (needs cert-manager CRDs)
30-mas.sh <env>           deploy MAS             → refuses unless Mongo Running + Vault verified
```

cert-manager is installed here (component 05), early and decoupled, because MongoDB's Issuer/
Certificate and MAS both need it. It mirrors IBM's own operator (openshift-cert-manager-operator,
stable-v1, cert-manager-operator namespace). Add more OLM operators via the reusable
`workloads/operators` chart — see `gitops/values.yaml` (`certManagerOperator`, `grafanaOperator`).

Seeding the actual secret material (§V.4) stays manual — the values are per-cluster and the
Vault unseal shares must never live in the cluster. `../scripts/status.sh <env>` shows all
three components at a glance.

Create repository credentials directly in OpenShift; the committed file under
`00-prereqs/repo-creds/` is an example and must never contain a real token.

`argocd-cr-avp-sidecar-patch.yaml` downloads AVP and Helm during repo-server startup,
so it requires outbound access to GitHub and `get.helm.sh`. For restricted clusters,
build an approved internal image containing both binaries and customize
`argocd-cr-avp-sidecar-patch-internal-image.example.yaml`.
