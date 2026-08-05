# Manual install (no bootstrap scripts)

The literal `oc` / `helm` / `vault` commands the `bootstrap/*.sh` scripts run, for when you
want to drive the install by hand or understand exactly what each step does. Same order,
same result as `INSTALL.md` — this just expands the wrappers.

> **The one idea:** the component steps do **not** install apps directly. Each renders a tiny
> Argo CD `Application` object (`helm template … --set component=<name>`) and `oc apply`s it;
> **Argo CD** then pulls the real chart/config from GitLab, resolves Vault secrets via the AVP
> sidecar, and deploys everything. Your commands drop the pointer and then **wait + assert**.

Examples use env **doc4** (`account=doc4`, `cluster=doc4`, `instance=docapp`, mongo ns
`mongo-gitops`). Replace those for another env. Vault paths are
`secret/<account>/<cluster>[/<instance>]`.

You still need, from the repo: the `gitops/` Helm chart, the `bootstrap/00-prereqs/*.yaml`
assets, the `bootstrap/argocd-cr-*.yaml` patches, and the `vault-auth/*.hcl` policies. Only
the `.sh` wrappers are being replaced.

---

## Setup — paste once (variables + helpers)

```bash
cd ~/platform-gitops
export ENV=doc4 ARGO_NS=openshift-gitops VAULT_NS=vault
export ACCOUNT=doc4 CLUSTER=doc4 INSTANCE=docapp
export MONGO_NS=mongo-gitops
export SLS_NS=mas-${INSTANCE}-sls DRO_NS=ibm-software-central
export VP=secret/$ACCOUNT/$CLUSTER/$INSTANCE      # instance path
export VC=secret/$ACCOUNT/$CLUSTER                # cluster path
COMMON=gitops/envs/$ENV/common.yaml
VALUES=gitops/envs/$ENV/values.yaml

# ac = "apply component": render the Argo CD Application pointer and apply it (== apply_component)
ac(){ helm template platform gitops -f "$COMMON" -f "$VALUES" --set component="$1" "${@:2}" | oc apply -f -; }

# v / vi = run the vault CLI inside vault-0 (HTTP) (vi = stdin variant for policy files)
v(){  oc exec    -n $VAULT_NS vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 ${VAULT_ROOT_TOKEN:+VAULT_TOKEN=$VAULT_ROOT_TOKEN} vault "$@"; }
vi(){ oc exec -i -n $VAULT_NS vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_ROOT_TOKEN vault "$@"; }
```

`ac`, `v`, `vi` mirror `apply_component`, `vault_exec`, `vault_exec_stdin` in
`bootstrap/lib-bootstrap.sh`.

---

## Phase 0 — prereqs (`00-prereqs.sh`)

One-time per cluster. Prepares Argo CD itself; deploys no component.

```bash
# GitLab repo credential (Argo CD reads GitLab). Needs the deploy token.
export GITLAB_USER='...' GITLAB_TOKEN='...'
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

# prereq assets: GitLab CA, cluster-admin RBAC, AppProject, AVP CMP plugin
oc apply -f bootstrap/00-prereqs/00-gitlab-ca-configmap.yaml
oc apply -f bootstrap/00-prereqs/01-argocd-cluster-admin-rbac.yaml
oc apply -f bootstrap/00-prereqs/02-argo-project.yaml
oc apply -f bootstrap/00-prereqs/03-avp-cmp-plugin.yaml

# patch Argo CD (MAS CR health checks + AVP sidecar), then roll the repo-server
oc patch argocd $ARGO_NS -n $ARGO_NS --type merge --patch-file bootstrap/argocd-cr-healthchecks-patch.yaml
oc patch argocd $ARGO_NS -n $ARGO_NS --type merge --patch-file bootstrap/argocd-cr-avp-sidecar-patch.yaml
oc rollout status deploy/openshift-gitops-repo-server -n $ARGO_NS --timeout=10m
```

---

## Phase 1 — operators / cert-manager (`05-operators.sh`)

cert-manager must exist before MongoDB and MAS (both issue certs through it).

```bash
ac operators
oc wait --for=condition=Established crd/certificates.cert-manager.io --timeout=5m
oc get csv -n cert-manager-operator | grep -i cert-manager
```

Grafana is `false` for doc4 — skip its block. If enabled, wait for
`crd/grafanas.grafana.integreatly.org` (Manual InstallPlan approval), then `ac grafana`.

---

## Phase 2 — deploy Vault (`10-vault.sh`)

Vault comes up **empty + sealed**; init/unseal is Phase 3.

```bash
ac vault
oc rollout status statefulset/vault -n $VAULT_NS --timeout=5m || true
oc get pods -n $VAULT_NS
```
Vault runs **HTTP** (non-TLS); the UI Route uses edge TLS at the router, so no
`destinationCACertificate` / service-ca wiring is needed.

---

## Phase 3 — init + unseal (manual — the shares must never live in the cluster)

Init **once**, to a fresh filename. Never point `vault operator init` at an existing keys
file — a failed redirect truncates it.

```bash
umask 077
oc exec -n $VAULT_NS vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
  vault operator init -key-shares=5 -key-threshold=3 -format=json > "$HOME/vault-init-$ENV.json"
test -s "$HOME/vault-init-$ENV.json" && jq -e .root_token "$HOME/vault-init-$ENV.json" >/dev/null && echo "OK saved" || echo "INIT FAILED"

export VAULT_ROOT_TOKEN="$(jq -r .root_token     "$HOME/vault-init-$ENV.json")"
K1="$(jq -r .unseal_keys_b64[0] "$HOME/vault-init-$ENV.json")"
K2="$(jq -r .unseal_keys_b64[1] "$HOME/vault-init-$ENV.json")"
K3="$(jq -r .unseal_keys_b64[2] "$HOME/vault-init-$ENV.json")"

# unseal all three (retries while followers join Raft)
for pod in vault-0 vault-1 vault-2; do
  for a in $(seq 1 30); do
    oc exec -n $VAULT_NS $pod -- env VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null | grep -qE '"sealed":[[:space:]]*false' && break
    for k in "$K1" "$K2" "$K3"; do
      oc exec -n $VAULT_NS $pod -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal "$k" >/dev/null 2>&1 || true
    done
    sleep 5
  done
done
```

Move `vault-init-$ENV.json` to secure escrow — never commit it or store it in a cluster Secret.

---

## Phase 4 — configure Vault auth (`11-vault-config.sh`)

Needs `VAULT_ROOT_TOKEN` (exported in Phase 3).

```bash
v secrets enable -path=secret kv-v2 || true
v auth enable kubernetes || true
v write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

vi policy write mas-gitops        - < vault-auth/mas-gitops-policy.hcl
vi policy write mas-gitops-writer - < vault-auth/mas-gitops-writer-policy.hcl

# bind the ACTUAL repo-server SA (usually 'default' on OpenShift GitOps) — wrong name => AVP 403
REPO_SA="$(oc get pods -n $ARGO_NS -l app.kubernetes.io/name=openshift-gitops-repo-server -o jsonpath='{.items[0].spec.serviceAccountName}')"; REPO_SA="${REPO_SA:-default}"
v write auth/kubernetes/role/mas-gitops \
  bound_service_account_names=$REPO_SA bound_service_account_namespaces=$ARGO_NS policies=mas-gitops ttl=20m
v write auth/kubernetes/role/mas-gitops-writer \
  bound_service_account_names=postsync-ibm-sls-update-sm-sa,postsync-ibm-dro-update-sm-sa \
  bound_service_account_namespaces=$SLS_NS,$DRO_NS policies=mas-gitops-writer ttl=20m
```

The `@/var/run/secrets/...` files resolve **inside vault-0** (that's where the CLI runs).

---

## Phase 5 — seed secrets (`seed-secrets.sh`)

```bash
export IBM_ENTITLEMENT_KEY='...'  LICENSE_FILE='/secure/license.dat'
export JDBC_USER='...' JDBC_PASS='...' JDBC_URL='jdbc:oracle:thin:@//host:1521/SVC'
PKI=~/mas-$CLUSTER-pki; mkdir -p "$PKI"; umask 077

# entitlement (double-base64 dockerconfigjson) + license + jdbc
ENT_B64="$(printf '{"auths":{"cp.icr.io":{"auth":"%s"}}}' "$(printf 'cp:%s' "$IBM_ENTITLEMENT_KEY" | base64 | tr -d '\r\n')" | base64 | tr -d '\r\n')"
v kv put $VC/entitlement image_pull_secret_b64="$ENT_B64"
v kv put $VP/license     license_file="$(cat "$LICENSE_FILE")"
v kv put $VP/jdbc-system username="$JDBC_USER" password="$JDBC_PASS" jdbc_url="$JDBC_URL"

# Mongo CA (generate once) -> mongo-ca, mongo, sls-mongo
openssl genrsa -out "$PKI/mongo-ca.key" 4096
openssl req -x509 -new -nodes -key "$PKI/mongo-ca.key" -sha256 -days 3650 -subj "/CN=${INSTANCE}-mongo-ca" -out "$PKI/mongo-ca.crt"
v kv put $VP/mongo-ca tls_crt_b64="$(base64 < "$PKI/mongo-ca.crt" | tr -d '\r\n')" tls_key_b64="$(base64 < "$PKI/mongo-ca.key" | tr -d '\r\n')"
MONGO_HOST="${INSTANCE}-mongo-svc.${MONGO_NS}.svc.cluster.local"
v kv put $VP/mongo     username=admin    password="$(openssl rand -hex 24 | cut -c1-24)" host="$MONGO_HOST" ca.crt="$(cat "$PKI/mongo-ca.crt")"
v kv put $VP/sls-mongo username=slsmongo password="$(openssl rand -hex 24 | cut -c1-24)" ca.crt="$(cat "$PKI/mongo-ca.crt")"

# certs/public — Manage requires a public cert (can't self-sign). Real cert if you have one,
# else this self-signed placeholder (browsers warn until you swap it).
MAS_DOMAIN="${INSTANCE}.apps.${CLUSTER}.lac1.biz"
openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days 825 \
  -keyout "$PKI/mas-tls.key" -out "$PKI/mas-tls.crt" \
  -subj "/CN=${MAS_DOMAIN}" -addext "subjectAltName=DNS:${MAS_DOMAIN},DNS:*.${MAS_DOMAIN}"
v kv put $VP/certs/public \
  tls_crt_b64="$(base64 < "$PKI/mas-tls.crt" | tr -d '\r\n')" \
  tls_key_b64="$(base64 < "$PKI/mas-tls.key" | tr -d '\r\n')" \
  ca_crt_b64="$(base64 < "$PKI/mas-tls.crt" | tr -d '\r\n')"
```

For a **real** MAS cert, put `tls_crt_b64` / `tls_key_b64` / `ca_crt_b64` from your real files
instead of the self-signed block, then hard-refresh the `manage` Application.

The seed script also **preserves** existing Mongo passwords / certs on re-run (it only
generates when absent). By hand, re-run these puts only when you intend to overwrite.

---

## Phase 6 — verify (`12-vault-verify.sh`)

```bash
for pf in \
  $VC/entitlement#image_pull_secret_b64 \
  $VP/license#license_file \
  $VP/jdbc-system#username $VP/jdbc-system#password $VP/jdbc-system#jdbc_url \
  $VP/mongo-ca#tls_crt_b64 $VP/mongo-ca#tls_key_b64 \
  $VP/mongo#username $VP/mongo#password $VP/mongo#host $VP/mongo#ca.crt \
  $VP/sls-mongo#username $VP/sls-mongo#password \
  $VP/certs/public#tls_crt_b64 $VP/certs/public#tls_key_b64 $VP/certs/public#ca_crt_b64 ; do
  p="${pf%%#*}"; f="${pf##*#}"
  v kv get -field="$f" "$p" >/dev/null 2>&1 && echo "OK   $pf" || echo "MISS $pf"
done
```

All `OK` = green light. Any `MISS` = re-seed that path before Phase 7/8.

---

## Phase 7 — MongoDB (`20-mongodb.sh`)

```bash
# operator version by OpenShift version: 4.17/4.18->1.4.0  4.19->1.6.1  4.20->1.8.0  4.21->1.9.1
oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
MONGO_OP=1.4.0     # <-- set to match the line above

ac mongodb-operator --set-string mongoOperator.version="$MONGO_OP"
oc wait --for=condition=Established crd/mongodbcommunity.mongodbcommunity.mongodb.com --timeout=5m
oc rollout status deployment/mongodb-kubernetes-operator -n $MONGO_NS --timeout=10m

ac mongodb-instance
oc -n $MONGO_NS wait --for=jsonpath='{.status.phase}'=Running mongodbcommunity/${INSTANCE}-mongo --timeout=15m
oc get mongodbcommunity,pods -n $MONGO_NS
```

---

## Phase 8 — MAS (`30-mas.sh`)

Gate: MongoDB `Running` (Phase 7) + Vault verified (Phase 6).

```bash
ac mas
oc get applications -n $ARGO_NS -l app.kubernetes.io/part-of=mas-platform
./scripts/status.sh $ENV 2>/dev/null || true
```

`ac mas` applies **one** Application (the account-root); IBM's ApplicationSets fan it out into
the full MAS tree (DRO, SLS, Suite, configs, Workspace, Manage). The post-sync jobs write
SLS/DRO registration back into Vault.

---

## Gotchas the scripts handle for you

- **Init once, fresh filename** — `vault operator init` at an existing keys file truncates it.
- **Vault is HTTP** — every vault call uses `VAULT_ADDR=http://…:8200`, no `VAULT_CACERT` / `VAULT_TLS_SERVER_NAME`
  (the serving cert only covers `vault-active`).
- **Bind the real repo-server SA** (Phase 4) or AVP returns 403 at MAS sync.
- **Don't start Phase 7/8** until Phase 6 is all `OK` — AVP resolves those paths at sync time,
  and a missing one fails MAS hours in.
- **Escrow** `vault-init-$ENV.json` and `~/mas-$CLUSTER-pki`; take a Raft snapshot after seeding
  (see `RUNBOOK.md` → "Vault backup").
