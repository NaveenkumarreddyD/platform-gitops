# Automation — one-shot bring-up, sequence, and Vault auto-unseal

This repo deploys IBM MAS on OpenShift with **ArgoCD + HashiCorp Vault** (via the Argo CD Vault
Plugin), as the on-prem / non-IBM replacement for IBM's AWS-Secrets-Manager-backed flow. This page
documents how much of the bring-up is automated, the exact deployment **sequence**, and the
opt-in **auto-unseal**.

## Why some steps are scripts and not pure ArgoCD

IBM's reference GitOps is "no-touch": push config + register secrets, and ArgoCD does the rest using
**Automated Sync Policies + Sync Waves + Custom Resource Healthchecks + Resource Hooks**
(see IBM's [Deployment Orchestration](https://ibm-mas.github.io/gitops/main/orchestration/)). The
two pieces that make later waves *wait* for MAS CRs are (a) custom resource healthchecks registered
in ArgoCD, and (b) PostSync hook Jobs that write runtime-generated registration into the secrets
backend — IBM's `08-postsync-update-sm_Job` writes to **AWS Secrets Manager**.

This repo targets clusters with **no AWS**, so:

- The AWS PostSync registration jobs are disabled (`run_sync_hooks: false` on SLS), and the
  equivalent harvest-into-Vault is done by the in-cluster **`workloads/vault-sync`** Jobs, driven by
  `scripts/sync-runtime-registration.sh`.
- Rather than rely solely on registered CR healthchecks, the bring-up is gated by readiness-polling
  scripts. `scripts/install-all.sh` chains them so the operator runs **one command**, while the
  internal waits preserve correct ordering (Mongo Running, SLS initialized, DRO present, …).

> Going fully hands-off later: flip `accountRoot.autoSync` / `registrationSync.autoSync` to `true`
> in `gitops/values.yaml` and register the MAS Custom Resource Healthchecks in ArgoCD. AVP retries
> until Vault has the values, so ArgoCD self-orders. The orchestrator below is the lower-risk path.

## The deployment sequence (validated against IBM wave order)

```
DAY-0 (once)            bootstrap/apply.sh         CA trust, RBAC, AppProject, AVP (CMP + creds +
                                                   repo-server sidecar), then the root app only.

VAULT (once)            init-vault.sh              init on vault-0, unseal all raft nodes, save keys.
                                                   --store-k8s-secret also seeds auto-unseal keys.

install-all.sh, in order — each step blocks on its precondition:
 1 check-env            tools, oc login, env vars, secret inputs, Vault reachable
 2 deploy              setup-vault-auth -> load-secrets -> static preflight -> render -> commit/push
 3 prereqs             repo-server restart -> sync Mongo operator/CR -> WAIT Mongo Running ->
                       publish Mongo CA into Vault -> full Vault preflight
 4 account-root        full preflight -> sync ibm-mas-account-root -> WAIT Synced/Healthy
                       (this is what starts MAS Core / SLS / Manage generation)
 5 registration       WAIT LicenseService initialized -> WAIT DRO route+secret ->
                       sync vault-registration-sync (in-cluster jobs harvest SLS+DRO -> Vault)
 6 bas                verify dro#url/api_token/ca.crt in Vault -> enable BAS -> resync account-root
 7 verify             status summary + AVP/health checks
```

Platform ArgoCD sync-waves (local to `gitops/`): `-20` root, `-10` AVP, `10` Vault,
`11` vault-unseal (opt-in), `19` Mongo SCC, `20` Mongo operator, `25` Mongo CR, `28` mongo→Vault,
`30` account-root, `40` JDBC, `50` registration-sync. Grafana is disabled by default.
Inside `account-root`, IBM's chart applies its own cluster-apps (cert-manager → operator catalog →
DRO → SLS) before instance-apps (MongoCfg → Suite → Manage), each with healthcheck-gated waves.

## One-shot orchestrator: `scripts/install-all.sh`

```bash
export VAULT_TOKEN=<root/admin>
export IBM_ENTITLEMENT_KEY=... MAS_LICENSE_FILE=/path/license.dat MAS_LICENSE_ID=... \
       JDBC_USERNAME=... JDBC_PASSWORD=... JDBC_URL='jdbc:oracle:thin:@//host:1521/SVC'

./scripts/install-all.sh --yes ../mas-config-repo/envs/drroc4.env
```

Options:

| Flag | Effect |
|---|---|
| `--yes` | non-interactive (auto-confirm the rendered-config commit/push) |
| `--no-push` | render + commit locally, don't push (you push manually) |
| `--skip-bas` | don't enable BAS/DRO Suite config |
| `--init-vault` | run `init-vault.sh` first (still saves/prints keys) |
| `--from <step>` | resume at `deploy\|prereqs\|account-root\|jdbc\|registration\|bas\|verify` |
| `--until <step>` | stop after a step — `--until prereqs` reproduces the old `install-gated.sh` |

Idempotent: every sub-step is safe to re-run, so a failed run resumes with `--from`.

## Vault auto-unseal (opt-in)

HashiCorp Vault OSS seals on every pod restart. With no AWS/Azure/GCP KMS and no second "transit"
Vault, this repo provides an in-cluster unsealer: a CronJob in `ns/vault` that sweeps each raft node
and unseals any that report `sealed=true`, using keys from a Kubernetes Secret.

Enable it:

```bash
# 1. seed the keys Secret (either flag at init time, or after the fact):
bash scripts/init-vault.sh --store-k8s-secret           # at init
#   or, if already initialized:
bash scripts/setup-vault-autounseal.sh --keys-file ./vault-init-keys.json

# 2. turn the Application on and sync the platform root:
#    gitops/values.yaml (or per-env):  enable.vaultUnseal: true   vault.autoUnseal.enabled: true
git commit -am "enable vault auto-unseal" && git push
oc annotate application platform-<cluster> -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
```

Default sweep is every 2 minutes (`vault.autoUnseal.schedule`). The CronJob talks to each node over
the in-cluster `vault-internal` headless service; no `pods/exec` RBAC needed.

**Security trade-off:** unseal keys live in a Kubernetes Secret in `ns/vault`. That is the pragmatic
OSS option and removes the manual unseal step, but it is weaker custody than an HSM/KMS auto-unseal
seal. For HSM-grade custody, configure a `seal "transit"` (or cloud KMS) stanza on the Vault server
instead and leave `enable.vaultUnseal: false`. See Appendix A of `SETUP-GUIDE.md` for VM-Vault.

## Irreducible manual seams

1. **Private repo token** — only needed when the GitHub repos are private; supply once in `bootstrap/00-prereqs/repo-creds/`.
2. **Vault root/unseal keys capture** — `init-vault.sh` generates them; a human must store them
   securely. Auto-unseal then handles subsequent restarts, but first capture stays manual.

Manage crypto keys are not a manual input in this flow. `load-secrets.sh` creates them once,
stores them in Vault, and reuses the stored values on later runs.
