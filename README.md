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
             install-all.sh is the one-shot orchestrator that chains them all.
vault-auth/  Vault k8s-auth setup + policies.
docs/        SETUP-GUIDE.md (step reference), AUTOMATION.md (one-shot flow), STRUCTURE.md.
```

## Quick start (per cluster, once)

For `drroc4`, use the staged bring-up first: [`docs/STAGED-RUNBOOK.md`](docs/STAGED-RUNBOOK.md).
It keeps SLSCfg, Manage, and DRO/BAS behind manual gates so OLM/catalog or runtime-secret issues do
not cascade through the whole MAS tree.

```bash
# 1. fill in real repo creds: bootstrap/00-prereqs/repo-creds/
./bootstrap/apply.sh <nroc4|roc4|drroc4>      # applies ONLY the root app; ArgoCD generates the rest

# 2. init + unseal Vault once (--store-k8s-secret seeds the auto-unseal keys Secret):
bash scripts/init-vault.sh --store-k8s-secret
export VAULT_TOKEN=<root-token-it-prints>
export IBM_ENTITLEMENT_KEY=... MAS_LICENSE_FILE=/path/license.dat MAS_LICENSE_ID=... \
       JDBC_USERNAME=... JDBC_PASSWORD=... JDBC_URL=...

# 3. ONE command: secrets -> render -> Mongo -> account-root ->
#    SLS/DRO registration -> BAS -> verify (each step waits for its precondition):
./scripts/install-all.sh --yes ../mas-gitops-config/envs/<cluster>.env
```
Prerequisites-only (old `install-gated.sh` behaviour): `./scripts/install-all.sh --until prereqs <env>`.
Resume after a transient failure: `./scripts/install-all.sh --from registration <env>`.

Full procedure: [`docs/SETUP-GUIDE.md`](docs/SETUP-GUIDE.md). One-shot + auto-unseal:
[`docs/AUTOMATION.md`](docs/AUTOMATION.md). Architecture: [`docs/STRUCTURE.md`](docs/STRUCTURE.md).

## Add a cluster
Copy `gitops/envs/_example/` to `gitops/envs/<cluster>/`, fill `common.yaml` + `values.yaml`,
then `./bootstrap/apply.sh <cluster>`. No template edits.
