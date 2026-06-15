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

## Quick start (per cluster, once)

For `drroc4`, use the staged bring-up first: [`docs/STAGED-RUNBOOK.md`](docs/STAGED-RUNBOOK.md).
It keeps each dependency gated, but treats DRO/BAS as required before Manage because MAS Suite
readiness depends on `BasIntegrationReady` in this topology.

```bash
# 1. fill in real repo creds: bootstrap/00-prereqs/repo-creds/
./bootstrap/apply.sh <nroc4|roc4|drroc4>      # applies ONLY the root app; ArgoCD generates the rest

# 2. init + unseal Vault once (--store-k8s-secret seeds the auto-unseal keys Secret):
bash scripts/init-vault.sh --store-k8s-secret
export VAULT_TOKEN=<root-token-it-prints>
export IBM_ENTITLEMENT_KEY=... MAS_LICENSE_FILE=/path/license.dat MAS_LICENSE_ID=... \
       JDBC_USERNAME=... JDBC_PASSWORD=... JDBC_URL=...

# 3. ONE command: secrets -> render -> Mongo -> account-root -> SLSCfg ->
#    JdbcCfg -> DRO/BAS -> Suite Ready -> Manage:
./scripts/install-ibm-way.sh --yes ../mas-gitops-config/envs/<cluster>.env
```
Prerequisites-only: `./scripts/deploy.sh --yes <env>` followed by `./scripts/prepare-prereqs.sh <env>`.
Resume after a transient failure by rerunning `install-ibm-way.sh`; each stage is guarded by
readiness checks and idempotent syncs.

Full procedure: [`docs/SETUP-GUIDE.md`](docs/SETUP-GUIDE.md). One-shot + auto-unseal:
[`docs/AUTOMATION.md`](docs/AUTOMATION.md). Architecture: [`docs/STRUCTURE.md`](docs/STRUCTURE.md).

## Add a cluster
Copy `gitops/envs/_example/` to `gitops/envs/<cluster>/`, fill `common.yaml` + `values.yaml`,
then `./bootstrap/apply.sh <cluster>`. No template edits.
