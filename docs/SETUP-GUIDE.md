# MAS GitOps — Complete Setup Guide (drroc4, greenfield)

End-to-end bring-up of a **greenfield** cluster with `platform-gitops` (the engine + platform
workloads) and `mas-config-repo` (the MAS CRs). Reflects the current state: 3-tier layout
(`bootstrap` / `gitops` / `workloads`), self-managing root, dedicated per-instance MongoDB,
Grafana operator pinned for **OCP 4.18**, and in-cluster Vault (VM-Vault deltas in Appendix A).

Example values used throughout: cluster `drroc4`, instance `drgitopsapp`, account `mas`,
storageClass `isilon`, Vault route `vault.apps.drroc4.lac1.biz`.

> **Two ground rules for Vault + ArgoCD**
> 1. ArgoCD caches rendered manifests by **git revision, not Vault**. After *any* Vault value
>    change: `oc rollout restart deploy/openshift-gitops-repo-server -n openshift-gitops` + hard-refresh the app.
> 2. In `load-secrets`: **`vault kv put` = initial write, `vault kv patch` = single-key update.**
>    A `put` on an existing path wipes the other keys.

---

## Quick path (greenfield drroc4) — 2 commands + 3 manual seams

Sections 0–8 are the detailed reference. For a clean cluster the whole bring-up is:

```bash
cd platform-gitops
# [seam 1] fill the GitLab group token:
#   cp bootstrap/00-prereqs/repo-creds/gitlab-group-repo-creds.example.yaml \
#      bootstrap/00-prereqs/repo-creds/gitlab-group-repo-creds.yaml   (+ real url/token)

bash bootstrap/apply.sh drroc4                 # prereqs + AVP sidecar + root app (generates 9 children)

# [seam 2] init + unseal Vault (3-node raft) — one helper does all nodes, prints the token:
bash scripts/init-vault.sh
export VAULT_TOKEN=<root_token_it_prints>

# the rest in one command — Vault auth + load secrets + preflight + render config + commit/push:
bash scripts/deploy.sh ../mas-config-repo/envs/drroc4.env

# [seam 3] approve the Grafana 5.21.2 InstallPlan once (Manual pin for OCP 4.18):
oc get installplan -A | grep grafana
oc patch installplan <name> -n <ns> --type merge -p '{"spec":{"approved":true}}'

oc get applications -n openshift-gitops -w     # watch it converge in wave order
```

`deploy.sh` wraps `setup-vault-auth.sh` → `load-secrets.sh` → `preflight-vault.sh` → `render.py` → commit.
The Mongo/SLS CA sync and SLS/DRO registration run automatically as **PostSync Jobs** once their
dependencies are Ready — no manual harvest step in the happy path (§7 covers the manual fallbacks).
The three seams above are the only genuinely-manual touches: a Git token, the Vault unseal keys, and
one operator approval.

---

## 0. Prerequisites

On your workstation: `oc` (logged in to drroc4 as cluster-admin), `helm` 3.x, `git`, `jq`, `openssl`.
On the cluster (kept from teardown): OpenShift GitOps (ArgoCD) operator running in `openshift-gitops`.

Have ready:
- IBM entitlement key (`IBM_ENTITLEMENT_KEY`)
- MAS license file (`license.dat`) and its License ID
- Oracle JDBC: username / password / URL (non-SSL here; `jdbc.sslEnabled: false`)
- Both repos pushed to GitLab and reachable by ArgoCD's repo-server.

---

## 1. Prepare credentials (the only thing to fill in before bootstrap)

Copy the repo-creds example to a real file and add your GitLab token so ArgoCD can pull the repos:
```bash
cd platform-gitops
cp bootstrap/00-prereqs/repo-creds/gitlab-group-repo-creds.example.yaml \
   bootstrap/00-prereqs/repo-creds/gitlab-group-repo-creds.yaml
$EDITOR bootstrap/00-prereqs/repo-creds/gitlab-group-repo-creds.yaml      # real URL + token
```
Everything else day-0 — CA trust, RBAC, the `mas` AppProject, and the **full AVP enablement**
(CMP plugin, Vault credentials, and the repo-server sidecar patch; the Vault reviewer grant is done by setup-vault-auth.sh) — lives in
`bootstrap/` and is applied for you by `apply.sh` in §3. There is no separate AVP step and no
`argocd/` folder anymore. AVP can't reach Vault until §4–§5; the secret-consuming Applications
retry until then.

---

## 2. Configure platform-gitops (edit, commit, push — before bootstrap)

**2.1 `gitops/values.yaml` — fix two known defaults:**
- `generator.repo_url:` → your **actual** config repo. It currently reads
  `…/mas-gitops-config.git`; set it to `…/mas-config-repo.git` (or rename the repo to match).
  If these disagree, `account-root` globs an empty repo and no MAS config deploys.
- Confirm `platform.repo_url` / `source.repo_url` point at your GitLab mirrors.

(The old `repoServerServiceAccount` knob is gone — the token-review RBAC in `bootstrap/00-prereqs/`
already binds the correct `openshift-gitops-argocd-repo-server` SA.)

**2.2 Per-env values** (already set for drroc4 — verify):
- `gitops/envs/drroc4/common.yaml`: `clusterId: drroc4`, `storageClass: isilon`,
  `vault.host: vault.apps.drroc4.lac1.biz`.
- `gitops/envs/drroc4/values.yaml`: `instanceId: drgitopsapp`, `mongo.namespace: mongo-drgitops`,
  `mongo.version: 6.0.12`, `jdbc.sslEnabled: false`, `dro.namespace: ibm-software-central`,
  `dro.syncEnabled: false` (flip to true once DRO is Running there), `sls.syncEnabled: true`.

**2.3 Air-gap check** (see Appendix B): the `hashicorp-vault-server` and
`mongodb-community-operator` Applications pull upstream Helm charts. If drroc4 can't reach
`helm.releases.hashicorp.com` / `mongodb.github.io`, mirror them and repoint
`vault.chartRepo` / `mongoOperator.repo` first.

```bash
git add -A && git commit -m "drroc4 platform config" && git push
```

---

## 3. Bootstrap — apply the root app (day-0, once)

```bash
./bootstrap/apply.sh drroc4
```
This applies `00-prereqs/` (CA, RBAC, the `mas` AppProject, repo creds, AVP creds + CMP plugin),
patches the repo-server with the AVP sidecar and restarts it, then applies **only the root app**
(`platform-drroc4`) via `--set rootOnly=true`. ArgoCD syncs the root app, which **generates** the 9 child
Applications and self-heals. Sync-wave order:

```
-20 platform-drroc4 (root)   -10 AVP config   10 Vault   20 Mongo operator (Helm)
 25 Mongo CR   28 mongo→Vault gate   30 account-root   40 JDBC
 50 SLS/DRO sync   55 grafana-operator   60 Grafana
```
Early waves (AVP, Vault) go first. The secret-consuming waves (Mongo CR 25, JDBC 40, …) will sit
in `ComparisonError`/retry until Vault is initialized and loaded in §4–§5 — expected.

```bash
oc get applications -n openshift-gitops
```

---

## 4. Initialize Vault + auth (once)

**4.1 Init + unseal** (HA raft, 3 pods; init on vault-0, unseal all, save keys securely)
```bash
oc exec -n vault vault-0 -- vault operator init       # SAVE unseal keys + root token
# unseal vault-0, vault-1, vault-2 (3 keys each); 1 & 2 auto-join the raft cluster
export VAULT_TOKEN='<root-or-admin-token>'
```

**4.2 Durable Kubernetes auth + policy + role** (do NOT use a 24h reviewer token — that's the
landmine that 403's every sync a day later; this script avoids it)
```bash
./scripts/setup-vault-auth.sh        # creates kv-v2 at secret/, policy + role "mas-gitops"
```
The AVP credentials secret (`AVP_AUTH_TYPE: k8s`, role `mas-gitops`) was already applied in §1.2,
so once the role exists AVP authentication starts working.

---

## 5. Load secrets into Vault

`load-secrets.sh` reads the **config-repo** env file and generates-once + writes every secret
(entitlement, license, superuser, manage-crypto, mongo/sls-mongo creds + host, jdbc). Mongo/SLS
CAs come later (§7) once the dedicated Mongo is Ready.

```bash
export VAULT_TOKEN='<vault admin>'
export IBM_ENTITLEMENT_KEY='...'           \
       MAS_LICENSE_FILE='/path/license.dat' MAS_LICENSE_ID='...' \
       JDBC_USERNAME='...' JDBC_PASSWORD='...' JDBC_URL='jdbc:oracle:thin:@//host:1521/SVC'
./scripts/load-secrets.sh ../mas-config-repo/envs/drroc4.env
./scripts/preflight-vault.sh ../mas-config-repo/envs/drroc4.env    # sls CA WARN is normal pre-sync
```

After loading, restart the repo-server so ArgoCD re-renders with the now-present secrets:
```bash
oc rollout restart deploy/openshift-gitops-repo-server -n openshift-gitops
```
Mongo operator → Mongo CR → JDBC waves should now go Healthy.

---

## 6. Deploy MAS config (render + commit `mas-config-repo`)

`account-root` (wave 30) discovers each `mas/<cluster>/` directory in the config repo and deploys
it. So you render + commit; ArgoCD does the rest.

**6.1 Fill `mas-config-repo/envs/drroc4.env`** — the `CHANGE_ME`s: `API_HOST`, `MAS_DOMAIN`,
`SLS_MONGO_HOST`, DRO contact, etc. Channels/catalog are already pinned
(`MAS_CHANNEL=8.11.x`, `MAS_APP_CHANNEL=8.7.x`, `SLS_CHANNEL=3.x`, catalog `v9-240625-amd64`),
and `SHARED_CLUSTER_SKIP=` is empty so cert-manager + DRO render (greenfield — see note below).

**6.2 Render + commit**
```bash
cd ../mas-config-repo
python3 render.py drroc4
git add -A && git commit -m "drroc4 MAS config" && git push
cd ../platform-gitops
oc annotate application ibm-mas-account-root -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
```

> **Greenfield note (changed from the old Ansible-coexistence model):** this cluster was wiped,
> so cert-manager, DRO, and the operator catalog are now **GitOps-owned**, not Ansible-owned.
> The old "don't let GitOps own the singletons" guardrail no longer applies. Just keep the
> catalog pinned to `v9-240625-amd64`.

---

## 7. Mid-flow gates (run as each dependency becomes Ready)

**7.1 Mongo CA → Vault** (after the dedicated Mongo is Ready)
```bash
oc get mongodbcommunity -n mongo-drgitops          # wait for Phase: Running
export VAULT_TOKEN='<vault admin>'
./scripts/sync-mongo-ca.sh ../mas-config-repo/envs/drroc4.env   # writes mongo#ca.crt + sls-mongo#ca.crt, hard-refreshes
```

**7.2 Approve the Grafana operator InstallPlan** (Manual pin for OCP < 4.19)
```bash
oc get installplan -n platform-operators
oc patch installplan <the-v5.21.2-plan> -n platform-operators --type merge -p '{"spec":{"approved":true}}'
# Do NOT approve any v5.22.x plan until the cluster is on OCP >= 4.19.
```

**7.3 SLS registration harvest** (own-SLS only; after `LicenseService` is Ready)
```bash
./scripts/harvest-sls-registration.sh ../mas-config-repo/envs/drroc4.env   # writes sls#registration_key/url/ca
oc rollout restart deploy/openshift-gitops-repo-server -n openshift-gitops
oc annotate application drgitopsapp-sls-system -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
```
If you point at a centralized/licensed SLS instead, load that SLS's `registration_key/url/ca` into
`secret/mas/drroc4/drgitopsapp/sls` and skip this harvest step.

---

## 8. Verify

```bash
./scripts/verify-platform.sh
oc get applications -n openshift-gitops -o json | jq -r \
  '.items[] | select(.metadata.name|test("drroc4|drgitopsapp"))
   | "\(.metadata.name)\t\(.status.sync.status)\t\(.status.health.status)"' | column -t
```
Expected end state: all Applications `Synced` + `Healthy`; Suite → ManageWorkspace → Manage Ready;
Grafana route reachable.

---

## 9. The next cluster (the repeatable bit)

Hub setup (§1) is done once. Per new cluster:
1. `gitops/envs/<cluster>/`: copy `_example/` to `common.yaml` + `values.yaml`.
2. `mas-config-repo/envs/<cluster>.env` (the ~6 values that differ).
3. `./bootstrap/apply.sh <env>` → Vault init/auth/load (§4–§5) → render+commit config (§6) → gates (§7).

No template edits. `scripts/deploy-cluster.sh <cluster> --load` chains render → load → preflight →
status for you once the env file + secret material are in place.

---

## Appendix A — Vault on a separate VM (instead of in-cluster)

Set in `gitops/values.yaml` (or per-env): `enable.vault: false`, keep `enable.avp: true`,
and `vault.addr: https://vault.lac1.biz:8200`. Then choose an auth method:

- **Kubernetes auth (recommended if the VM can reach the cluster API).** Smallest change — no repo
  edits beyond `vault.addr`. On the VM, configure the `kubernetes` auth method with the cluster API
  URL, the cluster CA, and a `token_reviewer_jwt` from a cluster SA bound to `system:auth-delegator`.
- **AppRole (if the VM is isolated from the cluster API).** Change the AVP creds secret to
  `AVP_AUTH_TYPE: approle` + `AVP_ROLE_ID`/`AVP_SECRET_ID`, switch `vault-write.sh` + the sync job
  template to `auth/approle/login`, and mount a secret with the RoleID/SecretID. Drop the
  `argocd-repo-server-tokenreview` CRB (unneeded).

Either way: the VM Vault serves HTTPS from your internal CA, so add `VAULT_CACERT` to the AVP creds
secret and mount the same CA into the sync jobs, or every `<path:>` lookup fails on cert verify.
`vault.addr` feeds both AVP and the sync jobs — set it once, it's consumed twice. Skip §4.1's
in-cluster init/unseal; the VM Vault is initialized on the VM.

---

## Appendix B — Air-gap (upstream Helm charts)

Vault and the Mongo operator pull upstream charts (`helm.releases.hashicorp.com`,
`mongodb.github.io`). If unreachable from ArgoCD: **mirror** both into your internal Helm
registry and repoint `vault.chartRepo` + `mongoOperator.repo`, or **vendor** them as local
`workloads/vault/` + `workloads/mongodb-operator/` charts. Everything else points at your own
repos already.

---

## Appendix C — Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| AVP 403 ~a day after setup | expiring reviewer JWT | re-run durable `setup-vault-auth.sh` |
| `ComparisonError: missing Vault value …#key` | secret absent / `put` overwrote it | `preflight-vault.sh`; restore via `update-vault-ca.sh` / `kv patch` |
| Vault value changed but app stale | cache keyed by git revision | `rollout restart` repo-server + hard refresh |
| `illegal base64 … byte 36` | raw entitlement stored | store base64 dockerconfigjson (loader does this) |
| CA error `InvalidByte(..,92)` | escaped `\n` PEM | re-store real multiline PEM via `update-vault-ca.sh` |
| Grafana operator stuck Pending/Replacing | v5.22.x CRD on OCP < 4.19 | keep the v5.21.2 Manual pin; approve only the 5.21.2 InstallPlan |
| No MAS config deploys | `generator.repo_url` ≠ real repo | fix the URL in `common-values.yaml`, re-sync account-root |
| Mongo/SLS Cfg "certificates" shape error | hand-edited rendered output | re-render `mas-config-repo`; never hand-edit `mas/<cluster>/` |
