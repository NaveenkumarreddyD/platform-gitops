# MAS on OpenShift via GitOps + AWS Secrets Manager — End-to-End

The end-to-end install. Final setup: `main` deploy branches, IBM's **native** SLS/DRO publisher,
required publisher key, and the cluster trust prereq.

## Architecture (3 repos, read by Argo CD)
| Repo | Deploy ref | Role |
|---|---|---|
| `platform-gitops` | **`main`** | bootstrap scripts + Argo CD/AVP wiring + MongoDB + cert-manager + account-root |
| `mas-gitops-config` | **`main`** | per-cluster/instance config, rendered by `render.sh` |
| `ibm-mas-gitops` (fork) | **`8.5.0-jdbc-patch`** | stock IBM 8.5.0 + ONE JDBC-nonSSL patch |

- Secrets live **only** in AWS Secrets Manager under `<account>/<cluster>[/<instance>]`, read by
  the argocd-vault-plugin sidecar (`AVP_TYPE=awssecretsmanager`) using a **static AWS key**.
- SLS/DRO generated secrets are published back to AWS SM by **IBM's native `postsync-update-sm` jobs**
  (`run_sync_hooks: true`), using the **publisher** key. (The old custom publisher Deployment is gone.)
- Repo URLs in config point at `gitlab.lac1.biz/gitops/...`; you push to GitHub and promote to GitLab.

---

## Secrets reference
**You seed (into AWS SM):** `entitlement`, `license`, `mongo`, `sls-mongo`, `jdbc-system`,
`certs/public`, **`publisher`** (required), and — S3 only — `manage-cos`; reuse-DB only — `manage-crypto`.

**Auto-created (do NOT seed):**
- `…/<instance>/mongo#ca.crt` — cert-manager CA + the Mongo-CA publish job
- `…/<instance>/sls` and `<account>/<cluster>/dro` — **IBM's native postsync-update-sm jobs**

---

## Step 0 — Cluster prerequisites (do these ONCE per cluster)
```bash
oc version && helm version && jq --version && aws --version && openssl version
oc whoami

# (a) OpenShift GitOps (Argo CD) operator must be installed:
oc get argocd openshift-gitops -n openshift-gitops

# (b) INTERNAL CA TRUST — required so DRO/MAS trust the self-signed *.apps.<cluster>.lac1.biz ingress.
#     The cluster Proxy references a trust bundle ConfigMap; it MUST contain a non-empty ca-bundle.crt
#     with your internal root CA. Verify:
oc get proxy cluster -o jsonpath='trustedCA={.spec.trustedCA.name}{"\n"}'         # e.g. custom-ca
oc get cm custom-ca -n openshift-config -o jsonpath='ca-bundle.crt bytes={.data.ca-bundle\.crt}' | wc -c
#     If empty/missing, populate it (use your internal root CA PEM):
#     oc create cm custom-ca -n openshift-config --from-file=ca-bundle.crt=/path/to/internal-root-ca.pem \
#       --dry-run=client -o yaml | oc apply -f -
```
> Skipping (b) is the #1 silent failure: DRO/SLS registration fails later with a TLS-trust error.
> cert-manager and the Isilon CSI driver are installed/expected too (05-operators handles cert-manager).

## Step 1 — Seed all secrets into AWS Secrets Manager
```bash
# certs from your .pfx (public TLS)
PW=$(cat <inst>.pwd.txt)
openssl pkcs12 -in <inst>.pfx -clcerts -nokeys -passin "pass:$PW" | openssl x509 -out tls.crt
cp <inst>.decrypted.key tls.key
cat SubCA.cer RootCA.cer | tr -d '\r' > ca-chain.crt

# (S3 only) split the PowerScale CA bundle
# tr -d '\r' < spire-chain.cer > s3-chain.pem; awk '/BEGIN CERT/{n++}{print > ("s3-ca-"n".pem")}' s3-chain.pem
# export POWERSCALE_S3_SUBCA="$(cat s3-ca-1.pem)" POWERSCALE_S3_ROOTCA="$(cat s3-ca-2.pem)"

export REGION=us-east-1 CLUSTER=<cluster> INSTANCE=<instance>
export ENTITLEMENT_KEY='<ibm-key>' LICENSE_FILE=./entitlement.lic
export MONGO_ADMIN_PASSWORD='<32-char>' SLS_MONGO_PASSWORD='<32-char>'
export JDBC_USERNAME=maximo JDBC_PASSWORD='<pw>' JDBC_URL='jdbc:oracle:thin:@//db:1521/SVC'
export TLS_CRT=$PWD/tls.crt TLS_KEY=$PWD/tls.key CA_CHAIN=$PWD/ca-chain.crt
# REQUIRED now — the write-scoped publisher key IBM's SLS/DRO jobs use:
export PUBLISHER_AWS_ACCESS_KEY_ID=AKIA<pub> PUBLISHER_AWS_SECRET_ACCESS_KEY='<secret>'
./scripts/seed-aws-secrets.sh
```

## Step 2 — Put the AWS keys + repo credential into OpenShift
```bash
# git credential for the private repos
oc -n openshift-gitops create secret generic gitlab-gitops-group-repo-creds \
  --from-literal=type=git --from-literal=url=https://gitlab.lac1.biz/gitops \
  --from-literal=username='<deploy-user>' --from-literal=password='<deploy-token>' \
  --dry-run=client -o yaml | oc label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml | oc apply -f -

# READER key — Argo CD/AVP reads AWS secrets
oc create secret generic aws-static-credentials -n openshift-gitops \
  --from-literal=region=us-east-1 --from-literal=aws_access_key_id=AKIA<reader> --from-literal=aws_secret_access_key=<secret>

# PUBLISHER key — needed in BOTH namespaces (Mongo-CA job runs in mongo-gitops; SLS/DRO in-cluster)
for ns in openshift-gitops mongo-gitops; do
  oc create ns $ns 2>/dev/null || true
  oc create secret generic aws-static-credentials-publisher -n $ns \
    --from-literal=region=us-east-1 --from-literal=aws_access_key_id=AKIA<pub> --from-literal=aws_secret_access_key=<secret>
done
```

## Step 3 — Configure the instance, render, push
```bash
cd ../mas-gitops-config
# new cluster: cp envs/example.env.example envs/<cluster>.env and set ACCOUNT_ID/CLUSTER_ID/INSTANCE_ID/
# WORKSPACE_ID/MAS_DOMAIN/MANAGE_ATTACHMENT_PROVIDER (filestorage | s3-migration | s3) etc.
./render.sh <cluster>
git add -A && git commit -m "render <cluster>" && git push        # then promote GitHub main -> GitLab main
cd ../platform-gitops
./scripts/preflight-consistency.sh <cluster>
```

## Step 4 — Bootstrap in order (each gates the next)
```bash
./bootstrap/00-prereqs.sh   <cluster>     # Argo CD + AVP sidecar (AWS lookups work)
./bootstrap/05-operators.sh <cluster>     # cert-manager (+ operators)
oc wait --for=condition=Established crd/certificates.cert-manager.io --timeout=10m
./bootstrap/20-mongodb.sh   <cluster>     # MongoDB + CA; waits until mongo#ca.crt is published
./bootstrap/30-mas.sh       <cluster>     # account-root -> Suite, SLS, DRO, Manage, workspace
```

## Step 5 — Verify
```bash
./scripts/status.sh <cluster>
oc get certificate -n mongo-gitops                      # mongo-ca + -server Ready
oc get suites.core.mas.ibm.com -A                       # Suite Ready
# IBM native publisher: the write-back jobs run and populate AWS SM
oc get job -A | grep update-sm                          # Completed
aws secretsmanager get-secret-value --region $REGION --secret-id $CLUSTER/$CLUSTER/dro --query SecretString --output text | jq keys
oc get manageapps,manageworkspaces -n mas-<instance>-manage
oc get route -n mas-<instance>-manage                   # ...manage.../maximo opens with a valid cert
```
**Done** when apps are Healthy, cfgs Ready, Suite + ManageWorkspace Ready, and the route opens.

---

## Key design points
- **Deploy branches are `main`** (platform-gitops + mas-gitops-config); IBM fork stays `8.5.0-jdbc-patch`.
- **IBM-native SLS/DRO publisher** (`run_sync_hooks: true`): SLS/DRO secrets are written to AWS SM by IBM's `postsync-update-sm` jobs; MAS reads them with `| base64decode` for the CAs.
- **Publisher key is required** (`PUBLISHER_AWS_*` → seeded `publisher` secret → `sm.aws_*` in the DRO/SLS charts).
- **Cluster trust prereq (Step 0b)** is mandatory for the self-signed ingress.

## If something looks stuck
- App Synced but nothing created → AVP rendered nothing: `oc logs deploy/openshift-gitops-repo-server -c avp-helm`.
- DRO/SLS never register → check Step 0b (`custom-ca` / `ca-bundle.crt`) and the `update-sm` job logs.
- Operator Subscription stuck Progressing, no InstallPlan → orphaned CSV from a prior install; delete it.
- Teardown → `UNINSTALL.md` (config-removal + prune) or `scripts/teardown-cluster.sh`.
