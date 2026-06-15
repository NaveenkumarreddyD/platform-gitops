# platform-gitops

GitOps control plane for IBM MAS on on-prem OpenShift, using **ArgoCD** + **HashiCorp Vault**
(via the Argo CD Vault Plugin). App-of-apps pattern: one root Application generates everything.

## Layout
```
bootstrap/   day-0 seed (the ONLY manual step): prereqs, AVP enablement, AppProject. apply.sh.
gitops/      app-of-apps generator (self-healing). templates/root/ for the root app and
             templates/apps/<domain>/app-NN-*.yaml for children. Per-cluster values under envs/<cluster>/.
workloads/   the charts the Applications deploy: operators, mongodb, jdbc, vault-sync,
             vault-unseal (opt-in auto-unseal). Grafana is disabled by default.
scripts/     imperative glue GitOps can't do (Vault auth, load secrets, runtime registration).
             install-ibm-way.sh is the supported IBM-aligned orchestrator.
vault-auth/  Vault k8s-auth setup + policies.
docs/        SETUP-GUIDE.md (step reference), AUTOMATION.md (one-shot flow), STRUCTURE.md.
```

## Quick Start

For `drroc4`, use the easy deployment guide: [`DEPLOY.md`](DEPLOY.md).

```bash
./bootstrap/apply.sh drroc4
bash scripts/init-vault.sh --store-k8s-secret
./scripts/install-ibm-way.sh --yes ../mas-gitops-config/envs/drroc4.env
```

The installer follows the IBM order: Mongo, SLS, JDBC, DRO/BAS, Suite Ready, then Manage.
It waits for actual MAS CR readiness and verifies the final state.

Detailed procedure: [`DEPLOY.md`](DEPLOY.md). Architecture: [`docs/STRUCTURE.md`](docs/STRUCTURE.md).

## Add a cluster
Copy `gitops/envs/_example/` to `gitops/envs/<cluster>/`, fill `common.yaml` + `values.yaml`,
then `./bootstrap/apply.sh <cluster>`. No template edits.
