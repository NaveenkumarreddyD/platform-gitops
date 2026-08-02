# IBM MAS installation (per cluster)

Run the steps in order. Examples use **drroc4** — for another env, replace `drroc4/drroc4`
(account/cluster) and `drrocapp` (instance). Each env is its own cluster with its own account;
Vault paths are `secret/<account>/<cluster>/[<instance>]/...`. The Vault policy files wildcard the
account, so step 6 is identical for every env.

## 1. Prerequisites

- Tools: `oc`, `helm`, `git`, `openssl`, `jq`.
- Cluster: OpenShift 4.17-4.21, OpenShift GitOps installed (`openshift-gitops`), `isilon` storage class, image pull +
  egress to GitHub/`get.helm.sh` (or use the internal-image AVP patch), DNS for
  `vault.apps.drroc4.lac1.biz`, Oracle reachable.
- All three repos pushed to GitLab on the pinned branches:

| Repo | GitLab branch |
|---|---|
| `platform-gitops` | `main` |
| `mas-gitops-config` | `main` |
| `ibm-mas-gitops` | `8.4.0-vault-patch` |

```bash
git ls-remote https://gitlab.lac1.biz/gitops/platform-gitops.git  refs/heads/main
git ls-remote https://gitlab.lac1.biz/gitops/mas-gitops-config.git refs/heads/main
git ls-remote https://gitlab.lac1.biz/gitops/ibm-mas-gitops.git    refs/heads/8.4.0-vault-patch
```

## 2. Validate

```bash
./scripts/preflight-consistency.sh drroc4       # must print PASS
helm template platform gitops \
  -f gitops/envs/drroc4/common.yaml -f gitops/envs/drroc4/values.yaml --set component=all >/dev/null
```

## 3. Bootstrap Argo CD

Create the GitLab repo credential (the `repo-creds` label is required, or Git fetch fails).
Export the deploy-token creds (this shell only), then apply:

```bash
export GITLAB_USER='...'
export GITLAB_TOKEN='...'
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-gitops-group-repo-creds
  namespace: openshift-gitops
  labels: { argocd.argoproj.io/secret-type: repo-creds }
type: Opaque
stringData:
  type: git
  url: https://gitlab.lac1.biz/gitops
  username: "${GITLAB_USER}"
  password: "${GITLAB_TOKEN}"
EOF
unset GITLAB_TOKEN

./bootstrap/00-prereqs.sh drroc4
```

(Restricted cluster: apply `bootstrap/argocd-cr-avp-sidecar-patch-internal-image.example.yaml`
before `00-prereqs.sh`.)

> Operators, Vault, MongoDB, and MAS are independent apps — run their scripts in order (below).
> Each refuses to run until its prerequisite is met. `./scripts/status.sh drroc4` shows all of them.

## 4. Operators (cert-manager)

```bash
./bootstrap/05-operators.sh drroc4       # installs cert-manager; waits for its CRDs
```

(Cluster already has cert-manager? Set `enable.certManager: false` in
`gitops/envs/drroc4/values.yaml`; still run this step so it verifies the existing CRDs.)

## 5. Deploy Vault, then init + unseal

```bash
./bootstrap/10-vault.sh drroc4
oc get pods -n vault -w                   # wait for vault-0/1/2
```

Initialize once (the output is the only copy of the root token + unseal keys):

```bash
umask 077
oc exec -n vault vault-0 -- env \
  VAULT_ADDR=https://127.0.0.1:8200 \
  VAULT_CACERT=/vault/userconfig/service-ca-bundle/service-ca.crt \
  VAULT_TLS_SERVER_NAME=vault-active.vault.svc \
  vault operator init -key-shares=5 -key-threshold=3 -format=json > "$HOME/vault-init-drroc4.json"

export VAULT_ROOT_TOKEN="$(jq -r '.root_token'     "$HOME/vault-init-drroc4.json")"
export UNSEAL_KEY_1="$(jq -r '.unseal_keys_b64[0]' "$HOME/vault-init-drroc4.json")"
export UNSEAL_KEY_2="$(jq -r '.unseal_keys_b64[1]' "$HOME/vault-init-drroc4.json")"
export UNSEAL_KEY_3="$(jq -r '.unseal_keys_b64[2]' "$HOME/vault-init-drroc4.json")"
```

Unseal all pods (retries while followers join Raft):

```bash
for pod in vault-0 vault-1 vault-2; do
  echo "== $pod =="
  for attempt in $(seq 1 30); do
    if oc exec -n vault "$pod" -- env VAULT_ADDR=https://127.0.0.1:8200 \
         VAULT_CACERT=/vault/userconfig/service-ca-bundle/service-ca.crt \
         VAULT_TLS_SERVER_NAME=vault-active.vault.svc \
         vault status -format=json 2>/dev/null | grep -qE '"sealed":[[:space:]]*false'; then
      echo "  unsealed"; break
    fi
    for key in "$UNSEAL_KEY_1" "$UNSEAL_KEY_2" "$UNSEAL_KEY_3"; do
      oc exec -n vault "$pod" -- env VAULT_ADDR=https://127.0.0.1:8200 \
        VAULT_CACERT=/vault/userconfig/service-ca-bundle/service-ca.crt \
        VAULT_TLS_SERVER_NAME=vault-active.vault.svc \
        vault operator unseal "$key" >/dev/null 2>&1 || true
    done
    sleep 5
  done
done
```

Move `vault-init-drroc4.json` to secure escrow — never commit it or store it in a cluster Secret.

## 6. Configure Vault auth

```bash
./bootstrap/11-vault-config.sh drroc4     # kv-v2 + k8s auth + policies + roles (uses $VAULT_ROOT_TOKEN)
```

## 7. Seed secrets

Export your inputs (this shell only), then run the seed script — it derives every Vault path
from the env files, generates the Mongo CA, and does all the `vkv` puts:

```bash
export IBM_ENTITLEMENT_KEY='...'
export LICENSE_FILE='/secure/path/license.dat'
export JDBC_USER='...'  JDBC_PASS='...'  JDBC_URL='jdbc:oracle:thin:@//host:1521/SERVICE'

./bootstrap/seed-secrets.sh drroc4
```

Optional exports (before running it):

| Export | Purpose |
|---|---|
| `MAS_TLS_CRT_FILE` `MAS_TLS_KEY_FILE` `MAS_CA_FILE` | provide a real MAS public cert; if unset, the script seeds a **self-signed placeholder** (Manage requires a cert — it can't self-sign) |
| `MONGO_CA_CRT_FILE` `MONGO_CA_KEY_FILE` | bring your own Mongo CA instead of generating one |
| `MONGO_HOST` / `MAS_DOMAIN` | override the derived Mongo host / MAS domain |
| `ROTATE_MONGO_PASSWORDS=true` | deliberately replace both Mongo passwords; omitted means preserve existing values |

It does **not** seed `dro`/`sls` — the patched IBM Jobs write those in step 9. `certs/public` is
**always** seeded (real cert if you export `MAS_TLS_*`, otherwise a self-signed placeholder). To swap
in the real cert later, re-run the seed with `MAS_TLS_*`/`MAS_CA_FILE` exported, then
`oc annotate application manage.<cluster>.<instance> -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite`.

Verify, then move the PKI to escrow:

```bash
./bootstrap/12-vault-verify.sh drroc4     # must print PASS; uses read-only Kubernetes auth
```

## 8. Deploy MongoDB

```bash
./bootstrap/20-mongodb.sh drroc4          # selects the operator for the live OCP version, then waits for Running
```

## 9. Deploy MAS

```bash
./bootstrap/30-mas.sh drroc4              # refuses unless Mongo is Running + Vault verified
./scripts/status.sh drroc4                # watch the whole stack
```

IBM's sync waves install DRO, SLS, Suite, configs, Workspace, and Manage; the post-sync Jobs
write SLS/DRO registration into Vault. Don't hand-create those resources.

## 10. Done when

- All Argo CD Applications are `Synced` + `Healthy`.
- `MongoCfg`, `SlsCfg`, `JdbcCfg`, `BasCfg`, `Suite`, `Workspace`, `ManageApp`, `ManageWorkspace` are Ready.
- The MAS/Manage routes serve the expected public cert and a login works.

```bash
oc exec -n vault vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 \
  VAULT_CACERT=/vault/userconfig/service-ca-bundle/service-ca.crt \
  VAULT_TLS_SERVER_NAME=vault-active.vault.svc VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv get secret/drroc4/drroc4/dro
oc exec -n vault vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 \
  VAULT_CACERT=/vault/userconfig/service-ca-bundle/service-ca.crt \
  VAULT_TLS_SERVER_NAME=vault-active.vault.svc VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv get secret/drroc4/drroc4/drrocapp/sls
```

After install, stop using the root token for day-2 work and keep the unseal shares separated.
