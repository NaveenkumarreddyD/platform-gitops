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
# 2. init/unseal Vault, load static secrets, render config, and prepare Mongo prerequisites:
./scripts/install-gated.sh ../mas-config-repo/envs/<cluster>.env
# 3. manually sync IBM MAS account-root only after preflight passes
./scripts/sync-mas-account-root.sh ../mas-config-repo/envs/<cluster>.env
# 4. after SLS initializes, sync runtime registration
./scripts/sync-runtime-registration.sh ../mas-config-repo/envs/<cluster>.env
```
Full procedure: [`docs/SETUP-GUIDE.md`](docs/SETUP-GUIDE.md). Architecture: [`docs/STRUCTURE.md`](docs/STRUCTURE.md).

## Add a cluster
Copy `gitops/envs/_example/` to `gitops/envs/<cluster>/`, fill `common.yaml` + `values.yaml`,
then `./bootstrap/apply.sh <cluster>`. No template edits.
