# IBM MAS GitOps on Vault — Gap Analysis & End-to-End Runbook

Scope: your three repos (`platform-gitops`, `ibm-mas-gitops` pinned 8.0.0, `mas-config-repo`) reviewed against IBM's official `ibm-mas/gitops` flow, adapted to **HashiCorp Vault + ArgoCD Vault Plugin (AVP)** instead of AWS Secrets Manager, and hardened with everything we hit bringing up `drgitopsapp` on `drroc4`. Goal: a repeatable, low-touch process for the next clusters.

---

## 1. TL;DR

What you already have is good and close to IBM-aligned: a hub-and-spoke single config repo, an env-driven renderer (`render.py`) that fails on unset vars, correct config **templates** (the mongo/SLS cert shapes are right in the `.tpl` — the bug we hit was in committed *rendered* output that had drifted, which re-rendering fixes), a working AVP sidecar/CMP setup, and a documented `setup.md`.

The gaps are concentrated in three places:

1. **Vault k8s auth is not durable** — `setup-vault-auth.sh` used a 24h `token_reviewer_jwt`, which is exactly what expired and 403'd every sync. This is the #1 production landmine. **Fixed** in the new `vault-auth/setup-vault-auth.sh`.
2. **The SLS registration harvest is AWS-only** — the chart's `100-ibm-sls/.../07-postsync-update-sm_Job.yaml` writes the registration key/CA to AWS Secrets Manager (`$aws_secret := "aws"`). On Vault it's a no-op, so `sls#registration_key/url/ca.crt` never gets populated and `sls-system` can't render. **Automated** in `scripts/harvest-sls-registration.sh`.
3. **No preflight / no cache-refresh discipline** — missing or mis-encoded Vault keys surface one ArgoCD `ComparisonError` at a time, and Vault changes don't invalidate ArgoCD's git-keyed cache. **Addressed** by `scripts/preflight-vault.sh` and a repo-server-restart step baked into the orchestrator.

Manual-effort verdict: per *new cluster* you can get down to **edit one env file + provide secret material + run one command** (`deploy-cluster.sh`). The one unavoidable mid-flow manual gate is harvesting SLS registration after LicenseService goes Ready — unless you use a centralized SLS, which removes it entirely (see §6).

---

## 2. Gap analysis

Priority: **P0** = breaks/blocks deploy or recurs unpredictably · **P1** = manual toil / fragility · **P2** = hygiene.

| # | Pri | Area | Gap (vs official / vs what we hit) | Fix in this kit |
|---|-----|------|-------------------------------------|-----------------|
| 1 | P0 | Vault auth | `token_reviewer_jwt` from `oc create token --duration=24h` expires → AVP 403 → all syncs fail ~a day later | `vault-auth/setup-vault-auth.sh` omits reviewer JWT (uses live client token + `auth-delegator`); optional non-expiring dedicated reviewer SA |
| 2 | P0 | SLS | AWS-only postsync never populates `sls#registration_key/url/ca` on Vault | `scripts/harvest-sls-registration.sh` reads LicenseService/ConfigMap/TLS secret → writes Vault |
| 3 | P0 | Encoding | Recurring `illegal base64` (entitlement), folded-scalar (license), escaped-`\n` CA (`InvalidByte`) | Loader uses correct per-field encodings + `@file` CAs; preflight validates them |
| 4 | P0 | Cache | Vault value changes don't invalidate ArgoCD cache (keyed by git revision) → stale renders | repo-server `rollout restart` step in orchestrator + harvest/update scripts |
| 5 | P1 | Secrets update | Loader uses `vault kv put` everywhere; a later single-key `put` wipes the secret (we lost sls-mongo creds this way) | `scripts/update-vault-ca.sh` uses `kv patch`; runbook rule: put=initial, patch=updates |
| 6 | P1 | Manual toil | Mongo creds/host/CA exported by hand though they already exist on-cluster | Loader `AUTO_MONGO=1` derives them from `mas-mongo-ce` |
| 7 | P1 | Preflight | Missing secrets only surface as per-app ComparisonErrors after sync | `scripts/preflight-vault.sh` validates the whole set before sync |
| 8 | P0 | Coexistence | Cluster singletons (operator-catalog, DRO, cert-manager) already owned by the Ansible MAS on this cluster; GitOps re-owning/pruning them is destructive | §6 guardrails: disable those cluster-apps, never `prune` on shared singletons, pin catalog `v9-240625` |
| 9 | P1 | Bootstrap config | `values.yaml` has `repoServerServiceAccount: default` + `vault.host: CHANGE_ME` + a `generator.repo_url` (`mas-gitops-config`) that differs from the actual repo (`mas-config-repo`) | §4 sets these explicitly; setup script auto-detects the real repo-server SA |
| 10 | P2 | Drift | Committed rendered output can drift from templates (root cause of the mongo-cert bug) | Treat `mas/<cluster>/` as generated; re-render, never hand-edit; optional CI check (§8) |
| 11 | P2 | License | Own-SLS "No Features": your RLKS/FlexLM file isn't bound to this SLS's Server ID | §6 decision: bind license to this SLS **or** point at centralized licensed SLS (recommended) |

---

## 3. The encoding table (definitive — keep this handy)

The single most error-prone thing. How a value must be stored in Vault depends on how the consuming chart emits it:

| Vault value | Consumed by | Chart sink | Store as |
|-------------|-------------|-----------|----------|
| `entitlement#image_pull_secret_b64` | operator-catalog, SLS, suite | `data:.dockerconfigjson` (no `b64enc`) | **base64** of `{"auths":{"cp.icr.io":{"auth":base64("cp:KEY")}}}` |
| `license#license_file` | SLS entitlement | `stringData: entitlement: >-` (folded scalar) | **base64 -w0** of `license.dat` |
| `*/superuser`, `*/manage-crypto`, creds `username`/`password`, `jdbc_url`, `sls#registration_key`/`url` | various | plain `stringData` / CR string field | **plain text** |
| any `ca.crt` (mongo, sls-mongo, jdbc, sls) | MongoCfg/SlsCfg/jdbc via `toYaml` | CR spec multiline | **real multiline PEM** (use `@file`; never escaped `\n`) |

CR shape gotchas (already correct in your `.tpl`, keep them that way):
- **MongoCfg** wants `certificates:` as a **top-level array** `[{alias: ca, crt: <path>}]`, sibling of `config:` — not nested under `config:`.
- **SlsCfg** (sls-system) wants `ca: { crt: <path> }` — an object, **not** a `certificates` array. Opposite shape from MongoCfg.
- **SLS LicenseService** `mongo_spec.certificates:` is an **array** `[{alias, crt}]` (like MongoCfg).

---

## 4. End-to-end from zero — Part A: hub bootstrap (once per management cluster)

This is the one-time setup of the ArgoCD hub + Vault + AVP. After this, new clusters are Part B.

**A1. Git trust + repo credentials**
```bash
oc apply -f platform-gitops/bootstrap/00-gitlab-ca-configmap.yaml
oc apply -f platform-gitops/bootstrap/01-argocd-cluster-admin-rbac.yaml
oc apply -f <your real repo-creds secret>           # from repo-creds/gitlab-group-repo-creds.example.yaml
oc rollout restart deploy/openshift-gitops-repo-server -n openshift-gitops
```

**A2. Fix bootstrap values** in `platform-gitops/charts/app-of-apps/values.yaml`:
- `vault.host:` → real Vault route host (was `CHANGE_ME`).
- `generator.repo_url:` → your actual config repo `…/mas-config-repo.git` (file said `mas-gitops-config` — confirm and make them match, or ArgoCD globs an empty repo).
- `repoServerServiceAccount:` → leave as-is; the auth script auto-detects the real SA (`openshift-gitops-argocd-repo-server` on stock OpenShift GitOps).

**A3. Deploy platform app-of-apps + Vault server**
```bash
oc apply -f platform-gitops/bootstrap/02-platform-app-of-apps.yaml
# sync platform-app-of-apps, then hashicorp-vault-server
```

**A4. Init + unseal Vault** (HA: init on `vault-0`, join + unseal `vault-1/2`)
```bash
oc exec -n vault vault-0 -- vault operator init      # save unseal keys + root token SECURELY
# unseal each pod; join 1 and 2 to 0
export VAULT_TOKEN='<root-or-admin>'
```

**A5. Vault auth + policy for AVP — use the DURABLE script**
```bash
cp <kit>/vault-auth/setup-vault-auth.sh   platform-gitops/vault-auth/setup-vault-auth.sh
export VAULT_TOKEN='<root-or-admin>'
./platform-gitops/vault-auth/setup-vault-auth.sh         # omits expiring reviewer JWT
# (security wants an explicit reviewer identity? DEDICATED_REVIEWER=1 ./setup-vault-auth.sh)
```

**A6. AVP credentials + sidecar + CMP**
```bash
oc apply -f platform-gitops/argocd/argocd-vault-plugin-credentials.example.yaml   # filled in
oc apply -f platform-gitops/argocd/cmp-plugin-configmap.yaml
oc patch argocd openshift-gitops -n openshift-gitops --type merge \
  --patch-file platform-gitops/argocd/argocd-cr-avp-sidecar-patch.yaml
oc rollout restart deploy/openshift-gitops-repo-server -n openshift-gitops
./platform-gitops/vault-auth/test-avp.sh
```

Hub is ready. You do **not** repeat A1–A6 per cluster.

---

## 4b. End-to-end from zero — Part B: per cluster (the repeatable bit)

Everything that changes between clusters lives in **one file**: `envs/<cluster>.env`. Fill the `CHANGE_ME`s (`API_HOST`, `MAS_DOMAIN`, `SLS_CHANNEL`, `SLS_MONGO_HOST`, DRO contact, etc.).

Then, with secret material exported (or sourced from a secrets env you keep out of git):

```bash
export VAULT_TOKEN='<vault admin>'
# secret env: IBM_ENTITLEMENT_KEY, MAS_LICENSE_FILE, MAS_SUPERUSER_PASSWORD,
#   JDBC_*, MANAGE_CRYPTO*_KEY, SLS_MONGO_*  (MONGO_* auto-derived with AUTO_MONGO=1)
AUTO_MONGO=1 ./deploy-cluster.sh <cluster> --load
```

`deploy-cluster.sh` does: render → load secrets → (you commit+push) → preflight → register/refresh account-root → print bottom-up status. Then the two Vault-specific gates:

1. Sync order is bottom-up: **configs → suite → workspace → manage**. ArgoCD sync-waves enforce most of it; sync `…-mongo-system` and `…-sls-system` configs first, confirm they verify, then the suite.
2. **Own-SLS only:** once `LicenseService` is `Ready`, harvest registration (the AWS-job replacement), then sync sls-system:
```bash
./scripts/harvest-sls-registration.sh envs/<cluster>.env
oc rollout restart deploy/openshift-gitops-repo-server -n openshift-gitops
oc annotate application <instance>-sls-system.<cluster> -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
```

---

## 5. Manual-effort: before → after (per new cluster)

| Step | Before | After |
|------|--------|-------|
| Per-cluster values | scattered edits across rendered YAML | 1 env file |
| Render config | manual | `render.py` (in orchestrator) |
| Mongo creds/CA | hand-export 4 values | `AUTO_MONGO=1` derives from cluster |
| Secret encodings | hand-built, error-prone | loader encodes correctly + preflight verifies |
| Catch missing secrets | one ArgoCD error at a time | `preflight-vault.sh` up front |
| Vault auth renewal | re-run after 24h expiry | never (durable) |
| SLS registration | manual lookup + write | `harvest-sls-registration.sh` |
| Sync + cache | manual clicking, stale renders | orchestrator + restart step |

Net: **one env file + secret material + one command**, with a single manual gate (SLS harvest) that disappears if you centralize SLS.

---

## 6. Coexistence & SLS decisions (this cluster has an Ansible MAS already)

**Cluster singletons — do NOT let GitOps re-own these** (Ansible owns them on `drroc4`):
- `cluster-applications/000-ibm-operator-catalog` — leave to Ansible; if GitOps manages it, pin **exactly** `v9-240625-amd64` so it can't bump the catalog under the running instance.
- `cluster-applications/030-ibm-dro` (+ `032` cleanup) — DRO is Ansible-owned; disable the GitOps DRO app. Your `mas/drroc4/ibm-dro.yaml` carries the empty `sm:` block fix for render, but don't sync/own it.
- `cluster-applications/010-redhat-cert-manager` — leave to Ansible.

Guardrails: keep `prune: false` on anything touching shared singletons (your account-root `autoSync: false` already helps), scope GitOps to the **instance** apps for `drgitopsapp`, and never point two controllers at the same CR.

**SLS — pick one:**
- *Option A (own SLS):* requires an IBM license bound to **this** SLS's Server ID. Today the file is an RLKS/FlexLM daemon config (SERVER/VENDOR, no INCREMENT/FEATURE) → "No Features". Get IBM to issue/bind, then harvest.
- *Option B (centralized SLS — recommended):* point `drgitopsapp` at the already-licensed Ansible SLS. Load that SLS's `registration_key/url/ca` into `…/sls`, **skip** the own-SLS app and the harvest step entirely. Fewer moving parts, no second license, no harvest gate.

---

## 7. AWS → Vault adaptations (what the official charts assume vs what you do)

| Official (AWS SM) | On Vault |
|-------------------|----------|
| `AVP_TYPE=awssecretsmanager`, IRSA | `AVP_TYPE=vault`, `AVP_AUTH_TYPE=k8s`, role `mas-gitops` |
| `<path:.../sls>` resolves from SM | `<path:secret/data/mas/...#key>` (kv-v2; note the `data/` segment) |
| postsync jobs write generated values back to SM (SLS reg, cert-manager, DRO token) | those jobs are **no-ops**; harvest SLS registration with our script; nothing should *read* the cert-manager/DRO SM values because those subsystems are Ansible-owned here |
| `cluster-applications/000-image-mirroring` ECR token CronJob | not used on-prem; leave disabled |
| SM auto-versioning | Vault: **`put` = full write (initial), `patch` = single-key update**; CAs as real PEM |

---

## 8. Script reference (all in this kit)

- `vault-auth/setup-vault-auth.sh` — durable k8s auth (replaces the expiring-token version). Idempotent.
- `load-secrets.sh.tpl` — improved loader (render.py fills it). `@file` CAs, correct encodings, `AUTO_MONGO=1`.
- `scripts/preflight-vault.sh <env>` — validates every required key + encoding before sync.
- `scripts/harvest-sls-registration.sh <env>` — Vault replacement for the AWS SLS postsync.
- `scripts/update-vault-ca.sh <path> <field> <pem|--literal v>` — patch-safe single-key update.
- `deploy-cluster.sh <cluster> [--load] [--no-sync]` — orchestrator.

Optional CI guard (prevents the rendered-drift class of bug): a pipeline job that runs `render.py --all` and fails if `git diff --exit-code mas/` is non-empty — i.e. committed output must equal a fresh render.

---

## 9. Troubleshooting quick table

| Symptom | Cause | Action |
|---------|-------|--------|
| AVP 403 "permission denied" after ~1 day | expired `token_reviewer_jwt` | re-run durable `setup-vault-auth.sh` (then it never recurs) |
| `ComparisonError` "missing Vault value …#key" | secret/key absent or `put` overwrote it | `preflight-vault.sh`; restore with `kv patch` |
| `illegal base64 … at input byte 36` | raw entitlement JWT stored | store base64 dockerconfigjson |
| SLS secret matches but "No Features" | license not bound to this SLS Server ID | §6 SLS decision |
| CA error `InvalidByte(.., 92)` (backslash) | escaped-`\n` PEM | re-store real PEM via `update-vault-ca.sh … <pem>` |
| Vault value changed but app still stale | ArgoCD cache keyed by git revision | `rollout restart deploy/openshift-gitops-repo-server` + hard refresh |
| MongoCfg rejected: "certificates must be array" | `certificates` nested under `config` | re-render (template is correct); top-level array |
| Triage all apps | — | `oc get applications -n openshift-gitops -o json \| jq -r '.items[]\|select(.metadata.name\|test("<inst>\|<cluster>"))\|"\(.metadata.name) \(.status.sync.status) \(.status.health.status)"'` |
