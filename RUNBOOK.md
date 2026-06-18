# MAS GitOps install runbook (drroc4 / drgitopsapp)

The complete, ordered install. Four phases. Each step says what it does, how to verify it,
and what to do if it's stuck. **Golden rule (the thing that bites): harvest before bounce.**
Whenever a `*Cfg` is `RegistrationFailed` / `InvalidConfiguration`, the cause is an empty Vault
registration path — run the **harvest** (`sync-runtime-registration` / `sync-mongo-ca`) then the
`enable-*-config`, NOT `reconcile` alone. `reconcile` only bounces controllers; it cannot register
against an empty Vault path.

Run everything from `~/gitlab/platform-gitops`. Config repo is `../mas-gitops-config`.

---

## Phase 0 — Prereqs (once)

```bash
# bastion clones must hold the latest fixes (mongo image pin, delete-fast, env cleanup, self-heal)
cd ~/gitlab/platform-gitops   && git pull && git log --oneline -3
cd ~/gitlab/mas-gitops-config && git pull && git log --oneline -3
oc whoami            # cluster-admin
oc get ns | grep -E 'drgitops|mongo-drgitops|ibm-software-central|^vault\b' || echo "clean"
```

Inputs on hand: IBM entitlement key, MAS `license.dat`, Oracle JDBC user/pass/URL, MAS public cert `.pfx`.

---

## Phase 1 — Bootstrap + platform apps (Vault, unseal, MongoDB)

One command. It runs `bootstrap/apply.sh` (prereqs + AVP sidecar + MAS healthchecks + the
app-of-apps **root**), then deploys + initializes Vault. The root app then generates the platform
children automatically: **Vault (wave 10) → Mongo operator (wave 20) → MongoDB CR (wave 25)**.

```bash
./scripts/setup-vault-platform.sh --store-k8s-secret drroc4
# capture the root token
oc get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' | base64 -d; echo
```

`--store-k8s-secret` initializes Vault and stores the unseal keys in `secret/vault-unseal-keys`.
Auto-unseal CronJob is opt-in: set `enable.vaultUnseal: true` + `vault.autoUnseal.enabled` in
`gitops/envs/drroc4/values.yaml`, or run `./scripts/setup-vault-autounseal.sh` after init.

**Verify:**
```bash
oc get pods -n vault                                   # vault-0 Running (sealed=0 after unseal)
oc get mongodbcommunity,sts,po -n mongo-drgitops        # mongo Running 7.0.23; pods 2/2
oc get sts -n mongo-drgitops -o jsonpath='{.items[0].spec.template.spec.containers[?(@.name=="mongod")].image}'; echo
#   -> quay.io/ibmmas/mongo:7.0.23-ubi8-20250817T080412Z   (full tag, NOT bare :7.0.23)
```
If mongo is `ImagePullBackOff` on a bare `:7.0.23` tag, the bastion is missing the image-pin
commit — `git pull` (Phase 0) and re-sync `mongodb-ce-drgitopsapp`.

---

## Phase 2 — Vault config (AVP auth)

```bash
export VAULT_TOKEN='<root token from Phase 1>'
./scripts/setup-vault-auth.sh
```
Sets up the Kubernetes auth role + policies AVP uses to read secrets. **Verify:** the script ends
clean; later, any `<path:...>` ref resolving (Phase 3 preflight) proves auth works.

---

## Phase 3 — Load secrets + certs into Vault

```bash
export IBM_ENTITLEMENT_KEY='...'
export MAS_LICENSE_FILE='/path/to/license.dat'
export JDBC_USERNAME='...' JDBC_PASSWORD='...' JDBC_URL='jdbc:oracle:thin:@//host:1521/SVC'
export PFX_PASSWORD='<pfx pw if any>'

./scripts/load-secrets.sh            ../mas-gitops-config/envs/drroc4.env
./scripts/load-mas-public-cert.sh    ../mas-gitops-config/envs/drroc4.env /path/to/mas-public-cert.pfx
./scripts/preflight-public-cert.sh   ../mas-gitops-config/envs/drroc4.env     # expect PASS x3
```
`load-secrets.sh` auto-generates the **mongo + sls-mongo + manage-crypto** secrets — this is what
makes the mongo app render later. **Verify the mongo path exists** (its absence = no mongo CR):
```bash
oc exec -n vault vault-0 -- sh -c "VAULT_TOKEN='$VAULT_TOKEN' vault kv get secret/mas/drroc4/drgitopsapp/mongo"
```

> Crypto note: `drroc4.env` has `MANAGE_AUTO_GENERATE_ENCRYPTION_KEYS=true` (fresh DB). For the
> **reused DEMAS DB**, set it `false` and put the original keys at
> `secret/mas/drroc4/drgitopsapp/manage-crypto` (`cryptoKey`/`cryptoxKey`) BEFORE Phase 4.

---

## Phase 4 — MAS install (sync root + harvests)

One command runs the whole MAS layer in the correct order:

```bash
./scripts/install-ibm-way.sh --yes ../mas-gitops-config/envs/drroc4.env
```

`install-ibm-way.sh` = `mas-prep.sh` + `mas-install.sh`. **Let it run to completion — do not Ctrl-C.**
Every wait is bounded and dumps diagnostics; nothing hangs silently. Internal order:

| Step | What it does | Fixes |
|------|--------------|-------|
| prep | account-root sync → Mongo CA → Vault → MongoCfg | mongo wiring |
| 6b | wait LicenseService CR → reconcile (bounce SLS+mongocfg) | SLS LicenseService Ready |
| **7** | **`sync-runtime-registration --sls-only` (harvest SLS url/key/CA → Vault)** → `enable-sls-config` | **`SLSIntegrationReady`** |
| 7b | reconcile (bounce suite) | `SystemDatabaseReady` |
| 8 | `sync-jdbc-config` | JDBC |
| **9** | **`sync-runtime-registration --dro-only` (harvest DRO → Vault)** → `enable-bas-config` | **`BASIntegrationReady`** |
| 10 | wait Suite Ready | Suite converges |
| 11 | `enable-manage` → `backup-manage-secrets` | Manage + crypto backup |

**Verify the end state:**
```bash
oc get suites.core.mas.ibm.com   -A    # STATUS=Ready; SYSTEMDB/SLS/UDS/ROUTES=Ready
oc get slscfgs.config.mas.ibm.com -A    # STATUS=Ready, REGISTERED=Success
oc get jdbccfgs,bascfgs,mongocfgs.config.mas.ibm.com -A   # all Ready
oc get po -n mas-drgitopsapp-manage     # ui/cron/mea/report/jms bundles Running
```

---

## Self-orchestration (no manual harvest/bounce in a normal deploy)

The `vault-sync-{sls,dro,mongo}` Applications are in-cluster ArgoCD **PostSync hook Jobs** that run
automatically during reconcile. Each Job: (1) **harvests** the runtime registration/CA into Vault,
(2) hard-**refreshes** the consuming config app so AVP re-renders the CR, and (3) **bounces** the MAS
controllers that cache their TLS/registration context, retrying until the config CR reports Ready:

| Job | harvests | bounces (auto) | fixes |
|-----|----------|----------------|-------|
| vault-sync-sls | SLS url/key/CA → `…/sls` | `entitymgr-slscfg`, `entitymgr-suite`, `ibm-sls-controller-manager` | SLS registration / `SLSIntegrationReady` |
| vault-sync-dro | DRO token/CA → `…/dro` | `entitymgr-bascfg`, `milestonesapi`, `adoptionusageapi` | BAS + the Manage **milestone 401** |
| vault-sync-mongo | live Mongo CA → `…/mongo` | `entitymgr-mongocfg`, `entitymgr-suite` | `SystemDatabaseReady` |

So a clean deploy is just **Phase 1 → 4**; the harvest+bounce that used to be manual now happens
inside the cluster. The scripts below remain only as a **fallback** if you ever need to force it.

## Manual fallback — harvest, THEN bounce

`reconcile` alone bounces controllers against whatever is in Vault. If the Vault registration path
is empty, registration fails forever. Always harvest first.

**SLS `RegistrationFailed`:**
```bash
# 1. confirm the gap
oc exec -n vault vault-0 -- sh -c "VAULT_TOKEN='$VAULT_TOKEN' vault kv get secret/mas/drroc4/drgitopsapp/sls"
# 2. harvest (runs vault-sync-sls; needs the sls-suite-registration CM present in the sls ns)
./scripts/sync-runtime-registration.sh --sls-only ../mas-gitops-config/envs/drroc4.env
# 3. re-render + bounce until registered
./scripts/enable-sls-config.sh --yes ../mas-gitops-config/envs/drroc4.env
oc get slscfgs.config.mas.ibm.com -A
```

**BAS/DRO `InvalidConfiguration`:**
```bash
./scripts/sync-runtime-registration.sh --dro-only ../mas-gitops-config/envs/drroc4.env
./scripts/enable-bas-config.sh --yes ../mas-gitops-config/envs/drroc4.env
```

**Mongo `SystemDatabaseReady=False` / MongoCfg not verified:**
```bash
./scripts/sync-mongo-ca.sh                       ../mas-gitops-config/envs/drroc4.env   # harvest live Mongo CA
./scripts/reconcile-mongo-dependent-configs.sh   ../mas-gitops-config/envs/drroc4.env   # then bounce
```

**Teardown (full recreate):**
```bash
./scripts/delete-fast.sh --confirm --include-vault drroc4
```
