# platform-gitops

GitOps control plane for IBM MAS on on-prem OpenShift, using **ArgoCD** + **HashiCorp Vault**
(via the Argo CD Vault Plugin). App-of-apps pattern: one root Application generates everything.

## Layout
```
bootstrap/   day-0 seed (the ONLY manual step): prereqs, AVP enablement, AppProject. apply.sh.
gitops/      app-of-apps generator (self-healing). templates/root-application.yaml + one
             app-NN-*.yaml per workload. Per-cluster values under envs/<cluster>/.
workloads/   the charts the Applications deploy: operators, mongodb, jdbc, vault-sync, grafana.
scripts/     imperative glue GitOps can't do (Vault auth, load secrets, harvest registration).
vault-auth/  Vault k8s-auth setup + policies.
docs/        SETUP-GUIDE.md (run-each-step) and STRUCTURE.md (architecture).
```

## Quick start (per cluster, once)
```bash
# 1. fill in real repo creds: bootstrap/00-prereqs/repo-creds/
./bootstrap/apply.sh <nroc4|roc4|drroc4>      # applies ONLY the root app; ArgoCD generates the rest
# 2. init/unseal Vault, load prerequisite secrets, and wait for MongoDB Running, then:
./scripts/setup-vault-auth.sh
./scripts/load-secrets.sh ../mas-config-repo/envs/<cluster>.env
./scripts/preflight-vault.sh ../mas-config-repo/envs/<cluster>.env
# 3. manually sync IBM MAS account-root only after preflight passes
argocd app sync ibm-mas-account-root
```
Full procedure: [`docs/SETUP-GUIDE.md`](docs/SETUP-GUIDE.md). Architecture: [`docs/STRUCTURE.md`](docs/STRUCTURE.md).

## Add a cluster
Copy `gitops/envs/_example/` to `gitops/envs/<cluster>/`, fill `common.yaml` + `values.yaml`,
then `./bootstrap/apply.sh <cluster>`. No template edits.
