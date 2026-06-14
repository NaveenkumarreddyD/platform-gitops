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

## Quick path (greenfield drroc4) — prerequisite gate before MAS

Sections 0–8 are the detailed reference. For a clean cluster the whole bring-up is:

```bash
cd platform-gitops
# [gate 1] if the GitHub repos are private, create Argo CD repo credentials
# in bootstrap/00-prereqs/repo-creds/. Public repos need no repo credential.

bash bootstrap/apply.sh drroc4                 # prereqs + AVP sidecar + root app (generates children)

# [gate 2] init + unseal Vault (3-node raft) — one helper does all nodes, prints the token.
# --store-k8s-secret also seeds the auto-unseal keys Secret so future restarts self-unseal.
bash scripts/init-vault.sh --store-k8s-secret
export VAULT_TOKEN=<root_token_it_prints>
export IBM_ENTITLEMENT_KEY=... MAS_LICENSE_FILE=/path/license.dat MAS_LICENSE_ID=... \
       JDBC_USERNAME=... JDBC_PASSWORD=... JDBC_URL='jdbc:oracle:thin:@//host:1521/SVC'

# ONE command does the rest, each step waiting for its precondition:
#   secrets -> render/push -> Mongo prereqs + Mongo CA -> account-root (Core/SLS/Manage) ->
#   gated JDBC config -> gated Grafana -> SLS/DRO registration -> BAS -> verify.
bash scripts/install-all.sh --yes ../mas-config-repo/envs/drroc4.env

oc get applications -n openshift-gitops -w     # watch it converge in wave order
```

Need the old "prerequisites only, do not start MAS" gate? `install-all.sh --until prereqs <env>`
stops right before account-root. Resume a partial run with `--from <step>`. See `docs/AUTOMATION.md`.

`install-all.sh` chains environment checks, `deploy.sh`, and `prepare-prereqs.sh`. `deploy.sh`
configures Vault auth, loads static secrets, runs static preflight, renders MAS config, and commits
only `mas/<cluster>` rendered files. `prepare-prereqs.sh` waits for MongoDB, publishes Mongo CA into
Vault, and runs the full preflight. The MAS `ibm-mas-account-root` Application is intentionally
manual. Do not sync it until Vault contains entitlement, license, Mongo credentials/CA, SLS Mongo
credentials/CA, and JDBC credentials.

---

## 0. Prerequisites

On your workstation: `oc` (logged in to drroc4 as cluster-admin), `helm` 3.x, `git`, `jq`, `openssl`.
On the cluster (kept from teardown): OpenShift GitOps (ArgoCD) operator running in `openshift-gitops`.

Have ready:
- IBM entitlement key (`IBM_ENTITLEMENT_KEY`)
- MAS license file (`license.dat`) and its License ID
- Oracle JDBC: username / password / URL (non-SSL here; `jdbc.sslEnabled: false`)
- Repos reachable by ArgoCD's repo-server:
  `https://github.com/NaveenkumarreddyD/platform-gitops.git`,
  `https://github.com/NaveenkumarreddyD/mas-config-repo.git`, and
  `https://github.com/ibm-mas/gitops.git`.

---

## 1. Prepare credentials (the only thing to fill in before bootstrap)

If your GitHub repos are private, add an Argo CD repo credential secret before bootstrap.
Public repos do not need this step. The old GitLab credential example is retained only as a template:
```bash
cd platform-gitops
cp bootstrap/00-prereqs/repo-creds/gitlab-group-repo-creds.example.yaml \
   bootstrap/00-prereqs/repo-creds/gitlab-group-repo-creds.yaml
$EDITOR bootstrap/00-prereqs/repo-creds/gitlab-group-repo-creds.yaml      # convert URL/token for your GitHub org if needed
```
Everything else day-0 — CA trust, RBAC, the `mas` AppProject, and the **full AVP enablement**
(CMP plugin, Vault credentials, and the repo-server sidecar patch; the Vault reviewer grant is done by setup-vault-auth.sh) — lives in
`bootstrap/` and is applied for you by `apply.sh` in §3. There is no separate AVP step and no
`argocd/` folder anymore. AVP can't reach Vault until §4–§5; the secret-consuming Applications
retry until then.

---

## 2. Configure platform-gitops (edit, commit, push — before bootstrap)

**2.1 `gitops/values.yaml` — verify repo defaults:**
- `generator.repo_url:` must point to your **actual** config repo:
  `https://github.com/NaveenkumarreddyD/mas-config-repo.git`.
  If this URL is wrong, `account-root` globs an empty repo and no MAS config deploys.
- Confirm `platform.repo_url` points at `NaveenkumarreddyD/platform-gitops.git`.
- Confirm `source.repo_url` points at IBM's official `https://github.com/ibm-mas/gitops.git`
  with the pinned `source.revision`.

(The old `repoServerServiceAccount` knob is gone — the token-review RBAC in `bootstrap/00-prereqs/`
already binds the correct `openshift-gitops-argocd-repo-server` SA.)

**2.2 Per-env values** (already set for drroc4 — verify):
- `gitops/envs/drroc4/common.yaml`: `clusterId: drroc4`, `storageClass: isilon`,
  `vault.host: vault.apps.drroc4.lac1.biz`.
- `gitops/envs/drroc4/values.yaml`: `instanceId: drgitopsapp`, `mongo.namespace: mongo-drgitops`,
  `mongo.version: 6.0.12`, `jdbc.sslEnabled: false`, `dro.namespace: ibm-software-central`,
  `dro.syncEnabled: true`, `sls.syncEnabled: true`. The registration-sync Application stays manual,
  so these values only declare what to harvest after SLS/DRO exist; they do not auto-run the harvest.

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
(`platform-drroc4`) via `--set rootOnly=true`. ArgoCD syncs the root app, which **generates** the child
Applications plus prerequisite resources and self-heals them. Sync-wave order:

```
-20 platform-drroc4 (root)   -10 AVP config   10 Vault   19 Mongo SCC prereq
 20 Mongo operator (Helm)   25 Mongo CR   28 mongo→Vault gate   30 account-root (manual)
 40 JDBC Application (manual after MAS config CRDs exist)
 50 SLS/DRO sync (manual after SLS/DRO exist)
 55 grafana-operator   60 Grafana Application (manual after Grafana CRDs exist)
```
Early waves (AVP, Vault) go first. Secret-consuming automated waves such as Mongo CR 25 can sit
in `ComparisonError`/retry until Vault is initialized and loaded in §4–§5 — expected.
JDBC and the Grafana operand are not automated; their scripts sync them only after the CRDs exist.
`ibm-mas-account-root` is created by the root app but has no automated sync policy by default, so
MAS Core/SLS/Manage do not start until you manually sync it. The JDBC and Grafana operand
Applications are also manual because their CRs must not sync before their operators register CRDs.
`vault-registration-sync-*` is manual by default; sync it after SLS initializes.

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

After loading, let `prepare-prereqs.sh` restart the repo-server, sync/refresh the Mongo prerequisite
Applications, wait for MongoDB to become Running, and publish the Mongo CA:
```bash
bash scripts/prepare-prereqs.sh ../mas-config-repo/envs/drroc4.env
```

---

## 6. Deploy MAS config (render + commit `mas-config-repo`)

`account-root` (wave 30) discovers each `mas/<cluster>/` directory in the config repo and deploys
it after you manually sync `ibm-mas-account-root`. So you render + commit, wait for prerequisites,
then sync account-root.

**6.1 Fill `mas-config-repo/envs/drroc4.env`** — the `CHANGE_ME`s: `CLUSTER_URL`, `MAS_DOMAIN`,
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
./scripts/preflight-vault.sh --phase full ../mas-config-repo/envs/drroc4.env
./scripts/sync-mas-account-root.sh ../mas-config-repo/envs/drroc4.env
```

> **Greenfield note (changed from the old Ansible-coexistence model):** this cluster was wiped,
> so cert-manager, DRO, and the operator catalog are now **GitOps-owned**, not Ansible-owned.
> The old "don't let GitOps own the singletons" guardrail no longer applies. Just keep the
> catalog pinned to `v9-240625-amd64`.

---

## 7. Runtime gates after account-root

**7.1 Mongo CA → Vault** is handled before account-root by `prepare-prereqs.sh`. Manual fallback:
```bash
oc get mongodbcommunity -n mongo-drgitops          # wait for Phase: Running
export VAULT_TOKEN='<vault admin>'
./scripts/sync-mongo-ca.sh ../mas-config-repo/envs/drroc4.env   # writes mongo#ca.crt + sls-mongo#ca.crt, hard-refreshes
```

**7.2 Sync JDBC after MAS config CRDs exist**
```bash
./scripts/sync-jdbc-config.sh ../mas-config-repo/envs/drroc4.env
```
This waits for `jdbccfgs.config.mas.ibm.com` and then syncs `drgitopsapp-jdbc-system`.

**7.3 Approve the Grafana operator InstallPlan and sync Grafana**
```bash
./scripts/sync-grafana.sh ../mas-config-repo/envs/drroc4.env
```
This approves only `grafana-operator.v5.21.2`, waits for Grafana CRDs, then syncs `grafana-drroc4`.
Do NOT approve any v5.22.x plan until the cluster is on OCP >= 4.19.

**7.4 SLS/DRO registration sync** (after `LicenseService` is Ready)
```bash
./scripts/sync-runtime-registration.sh ../mas-config-repo/envs/drroc4.env
```
If you point at a centralized/licensed SLS instead, load that SLS's `registration_key/url/ca` into
`secret/mas/drroc4/drgitopsapp/sls` and skip this harvest step.

---

## 8. Verify

```bash
./scripts/verify-platform.sh
./scripts/app-diagnostics.sh ../mas-config-repo/envs/drroc4.env
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

No template edits. `scripts/deploy.sh ../mas-config-repo/envs/<cluster>.env` chains Vault auth,
secret loading, preflight, render, and config commit once the env file and secret material are ready.

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
| `license#license_file is base64-encoded` | license.dat was stored encoded | re-run `load-secrets.sh`; it stores raw license text |
| CA error `InvalidByte(..,92)` | escaped `\n` PEM | re-store real multiline PEM via `update-vault-ca.sh` |
| Grafana operator stuck Pending/Replacing | v5.22.x CRD on OCP < 4.19 | keep the v5.21.2 Manual pin; approve only the 5.21.2 InstallPlan |
| `drgitopsapp-jdbc-system` failed with missing `JdbcCfg` kind | JDBC app synced before MAS config CRDs existed | run `sync-jdbc-config.sh`; the app is now manual/gated |
| `grafana-drroc4` failed with missing Grafana kind | Grafana operand synced before Grafana CRDs existed | run `sync-grafana.sh`; the app is now manual/gated |
| No MAS config deploys | `generator.repo_url` ≠ real repo | fix the URL in `gitops/envs/<cluster>/common.yaml`, re-sync account-root |
| Mongo/SLS Cfg "certificates" shape error | hand-edited rendered output | re-render `mas-config-repo`; never hand-edit `mas/<cluster>/` |
