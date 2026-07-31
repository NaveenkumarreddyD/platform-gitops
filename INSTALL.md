# IBM MAS installation (per cluster)

Run the steps in order. Examples use **drroc4** — for another env, replace `drroc4/drroc4`
(account/cluster) and `drgitopsapp` (instance). Each env is its own cluster with its own account;
Vault paths are `secret/<account>/<cluster>/[<instance>]/...`. The Vault policy files wildcard the
account, so step 6 is identical for every env.

## 1. Prerequisites

- Tools: `oc`, `helm`, `git`, `openssl`, `jq`.
- Cluster: OpenShift GitOps installed (`openshift-gitops`), `isilon` storage class, image pull +
  egress to GitHub/`get.helm.sh` (or use the internal-image AVP patch), DNS for
  `vault.apps.drroc4.lac1.biz`, Oracle reachable.
- All three repos pushed to GitLab on the pinned branches:

| Repo | GitLab branch |
|---|---|
| `platform-gitops` | `mas-vault-deploy` |
| `mas-config-repo` | `mas-vault-deploy` |
| `ibm-mas-gitops` | `8.4.0-vault-patch` |

```bash
git ls-remote https://gitlab.lac1.biz/gitops/platform-gitops.git  refs/heads/mas-vault-deploy
git ls-remote https://gitlab.lac1.biz/gitops/mas-gitops-config.git refs/heads/mas-vault-deploy
git ls-remote https://gitlab.lac1.biz/gitops/ibm-mas-gitops.git    refs/heads/8.4.0-vault-patch
```

## 2. Validate

```bash
./scripts/preflight-consistency.sh drroc4       # must print PASS
helm template platform gitops \
  -f gitops/envs/drroc4/common.yaml -f gitops/envs/drroc4/values.yaml --set component=all >/dev/null
```

## 3. Bootstrap Argo CD

Create the GitLab repo credential (the `repo-creds` label is required, or Git fetch fails):

```bash
read -rp 'GitLab deploy-token username: ' GITLAB_USER
read -rsp 'GitLab deploy token: ' GITLAB_TOKEN; echo
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
`gitops/envs/drroc4/values.yaml` and skip this step.)

## 5. Deploy Vault, then init + unseal

```bash
./bootstrap/10-vault.sh drroc4
oc get pods -n vault -w                   # wait for vault-0/1/2
```

Initialize once (the output is the only copy of the root token + unseal keys):

```bash
umask 077
oc exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
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
    if oc exec -n vault "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 \
         vault status -format=json 2>/dev/null | grep -qE '"sealed":[[:space:]]*false'; then
      echo "  unsealed"; break
    fi
    for key in "$UNSEAL_KEY_1" "$UNSEAL_KEY_2" "$UNSEAL_KEY_3"; do
      oc exec -n vault "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 \
        vault operator unseal "$key" >/dev/null 2>&1 || true
    done
    sleep 5
  done
done
```

Move `vault-init-drroc4.json` to secure escrow — never commit it or store it in a cluster Secret.

## 6. Configure Vault auth

```bash
oc adm policy add-cluster-role-to-user system:auth-delegator -z vault -n vault
./bootstrap/11-vault-config.sh drroc4     # kv-v2 + k8s auth + policies + roles (uses $VAULT_ROOT_TOKEN)
```

## 7. Seed secrets

```bash
vkv(){ oc exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
       VAULT_TOKEN="$VAULT_ROOT_TOKEN" vault kv put "$@"; }
```

Do **not** seed the `dro` or `sls` paths — the patched IBM Jobs write those during step 9.

Entitlement + license:

```bash
read -rsp 'IBM entitlement key: ' IBM_ENTITLEMENT_KEY; echo
ENTITLEMENT_B64="$(printf '{"auths":{"cp.icr.io":{"auth":"%s"}}}' \
  "$(printf 'cp:%s' "$IBM_ENTITLEMENT_KEY" | base64 | tr -d '\r\n')" | base64 | tr -d '\r\n')"
unset IBM_ENTITLEMENT_KEY
vkv secret/drroc4/drroc4/entitlement image_pull_secret_b64="$ENTITLEMENT_B64"
vkv secret/drroc4/drroc4/drgitopsapp/license license_file="$(cat /secure/path/license.dat)"
```

Oracle JDBC:

```bash
read -rp  'Oracle username: ' JDBC_USER
read -rsp 'Oracle password: ' JDBC_PASS; echo
read -rp  'Oracle JDBC URL: ' JDBC_URL
vkv secret/drroc4/drroc4/drgitopsapp/jdbc-system username="$JDBC_USER" password="$JDBC_PASS" jdbc_url="$JDBC_URL"
```

MongoDB CA (generated once) + credentials:

```bash
umask 077; mkdir -p "$HOME/mas-drroc4-pki"
openssl genrsa -out "$HOME/mas-drroc4-pki/mongo-ca.key" 4096
openssl req -x509 -new -nodes -key "$HOME/mas-drroc4-pki/mongo-ca.key" -sha256 -days 3650 \
  -subj '/CN=drgitopsapp-mongo-ca' -out "$HOME/mas-drroc4-pki/mongo-ca.crt"
MONGO_CA_PEM="$(cat "$HOME/mas-drroc4-pki/mongo-ca.crt")"
MONGO_PW="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
SLS_MONGO_PW="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"

vkv secret/drroc4/drroc4/drgitopsapp/mongo-ca \
  tls_crt_b64="$(base64 < "$HOME/mas-drroc4-pki/mongo-ca.crt" | tr -d '\r\n')" \
  tls_key_b64="$(base64 < "$HOME/mas-drroc4-pki/mongo-ca.key" | tr -d '\r\n')"
vkv secret/drroc4/drroc4/drgitopsapp/mongo \
  username=admin password="$MONGO_PW" \
  host=drgitopsapp-mongo-svc.mongo-gitops.svc.cluster.local ca.crt="$MONGO_CA_PEM"
vkv secret/drroc4/drroc4/drgitopsapp/sls-mongo \
  username=slsmongo password="$SLS_MONGO_PW" ca.crt="$MONGO_CA_PEM"
```

MAS public certificate (from the supplied PFX):

```bash
openssl pkcs12 -in /secure/path/mas-public.pfx -clcerts -nokeys -out "$HOME/mas-drroc4-pki/mas-tls.crt"
openssl pkcs12 -in /secure/path/mas-public.pfx -nocerts -nodes  -out "$HOME/mas-drroc4-pki/mas-tls.key"
openssl pkcs12 -in /secure/path/mas-public.pfx -cacerts -nokeys -out "$HOME/mas-drroc4-pki/mas-ca.crt"
vkv secret/drroc4/drroc4/drgitopsapp/certs/public \
  tls_crt_b64="$(base64 < "$HOME/mas-drroc4-pki/mas-tls.crt" | tr -d '\r\n')" \
  tls_key_b64="$(base64 < "$HOME/mas-drroc4-pki/mas-tls.key" | tr -d '\r\n')" \
  ca_crt_b64="$(base64 < "$HOME/mas-drroc4-pki/mas-ca.crt" | tr -d '\r\n')"
```

Verify, then move the PKI to escrow:

```bash
./bootstrap/12-vault-verify.sh drroc4     # must print PASS
```

## 8. Deploy MongoDB

```bash
./bootstrap/20-mongodb.sh drroc4          # wait until phase is Running
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
oc exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN="$VAULT_ROOT_TOKEN" vault kv get secret/drroc4/drroc4/dro
oc exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN="$VAULT_ROOT_TOKEN" vault kv get secret/drroc4/drroc4/drgitopsapp/sls
```

After install, stop using the root token for day-2 work and keep the unseal shares separated.
