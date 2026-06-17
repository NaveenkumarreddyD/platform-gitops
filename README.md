# platform-gitops

GitOps control plane for IBM MAS on on-prem OpenShift, using **ArgoCD** + **HashiCorp Vault**
(via the Argo CD Vault Plugin). App-of-apps pattern: one root Application generates everything.
This README is the single source of truth — there are no other top-level guides.

## Layout
```
bootstrap/   day-0 seed (run once per cluster): prereqs, AVP sidecar + MAS healthchecks,
             AppProject, app-of-apps root. apply.sh <cluster>. (see bootstrap/README.md)
gitops/      app-of-apps generator (self-healing). templates/root/ = root app;
             templates/apps/<domain>/app-NN-*.yaml = children. Per-cluster values in envs/<cluster>/.
workloads/   charts the Applications deploy: operators, mongodb, jdbc, vault-sync.
scripts/     imperative glue GitOps can't do (Vault auth, load secrets, runtime registration,
             staged MAS install). install-ibm-way.sh is the IBM-aligned orchestrator.
vault-auth/  Vault k8s-auth setup + policies. (see vault-auth/setup-vault-auth.md)
```

## Versions (pinned in the config repo `envs/<cluster>.env`)
The operator catalog tag is the master pin for every MAS version. For `drroc4`:
`MAS_CATALOG_VERSION=v9-250925-amd64` → **core 8.11.26 / Manage 8.7.24 / SLS 3.12.2**.
`check-env.sh` fails fast if the tag and the `*_TARGET_VERSION` pins disagree.

## Fresh deploy (drroc4 / drgitopsapp)

Prereqs: `oc` logged in as cluster-admin; OpenShift GitOps operator installed; ArgoCD repo
creds filled in (`bootstrap/00-prereqs/repo-creds/`); the config repo cloned next door with
`envs/drroc4.env` complete; inputs on hand (IBM entitlement key, MAS `license.dat`, Oracle
JDBC user/pass/URL, MAS public cert as `.pfx`).

```bash
# 1. Bootstrap + Vault (one step — setup-vault-platform.sh runs bootstrap/apply.sh itself,
#    then brings Vault up. Do NOT also run apply.sh separately.)
./scripts/setup-vault-platform.sh --store-k8s-secret drroc4
oc get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' | base64 -d; echo

# 2. Vault auth for AVP
export VAULT_TOKEN='<root token from step 1>'
./scripts/setup-vault-auth.sh

# 3. Load static secrets + public cert into Vault
export IBM_ENTITLEMENT_KEY='...' MAS_LICENSE_FILE='/path/license.dat'
export JDBC_USERNAME='...' JDBC_PASSWORD='...' JDBC_URL='jdbc:oracle:thin:@//host:1521/SVC'
export PFX_PASSWORD='<pfx pw if any>'
./scripts/load-mas-public-cert.sh ../mas-gitops-config/envs/drroc4.env /path/mas-public-cert.pfx
./scripts/preflight-public-cert.sh ../mas-gitops-config/envs/drroc4.env   # expect PASS x3

# 4. Install — secrets/config/Mongo/account-root, then SLS, JDBC, Suite Ready, Manage.
#    (= mas-prep.sh + mas-install.sh; run those two separately if you want a checkpoint.)
./scripts/install-ibm-way.sh --yes ../mas-gitops-config/envs/drroc4.env
```

The installer follows the IBM order — Mongo → SLS → JDBC → Suite Ready → Manage — waits for
real MAS CR readiness at each step, and runs `verify-install.sh` (asserts CSVs == the target
versions). DRO/BAS is intentionally **skipped** when `GITOPS_OWNS_DRO=false`.

### Enable DRO + BAS (optional, after Manage)
```bash
# config env: GITOPS_OWNS_DRO=true  -> render + push (cascade deploys DRO)
# gitops/envs/drroc4/values.yaml: dro.syncEnabled=true  -> re-run ./bootstrap/apply.sh drroc4
./scripts/sync-runtime-registration.sh --dro-only ../mas-gitops-config/envs/drroc4.env
./scripts/enable-bas-config.sh --yes ../mas-gitops-config/envs/drroc4.env
```

## Day-2 helpers
- `./scripts/refresh-config.sh drroc4` — force ArgoCD to pull the latest commit now (otherwise
  auto-picked up in ~60–120s; the poll is tuned via the bootstrap healthchecks patch).
- `./scripts/delete-fast.sh --confirm drroc4` — fast scoped teardown (add `--include-vault`
  to wipe Vault too). Accepts a bare cluster name; `--help` for details.

Safety nets baked in: every entry script runs `assert_repo_fresh` (refuses to run a stale clone),
and `mas-prep.sh` runs `check-env.sh` (blocks on catalog↔version mismatch) before any change.

## Add a cluster
Copy `gitops/envs/_example/` to `gitops/envs/<cluster>/`, fill `common.yaml` + `values.yaml`,
add `envs/<cluster>.env` in the config repo, then `./scripts/setup-vault-platform.sh --store-k8s-secret <cluster>`.
