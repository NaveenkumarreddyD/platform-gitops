# MAS Install — Steps in Order

Cluster **`drroc4`**, instance **`drgitopsapp`**, workspace **`drgitopswks`**.
Branches: `platform-gitops`@`static-keys`, `mas-gitops-config`@`codex/aws-secrets-manager`, `ibm-mas-gitops`@`8.5.0-jdbc-patch`.

> The other team creates the **AWS IAM user** and gives you two keys: a **reader** key and a **publisher** key. You do every step below.

---

## Step 0 — Prereqs
```bash
# why: these tools are used by the scripts, and Argo CD must already be installed.
oc version && helm version && jq --version && aws --version && openssl version
oc whoami
oc get argocd openshift-gitops -n openshift-gitops
```

## Step 1 — Prepare the certificate files
```bash
# why: the seed script needs the public TLS cert as PEM files (from your .pfx bundle).
PW=$(cat drgitopsapp.apps.drroc4.pwd.txt)
openssl pkcs12 -in drgitopsapp.apps.drroc4.pfx -clcerts -nokeys -passin "pass:$PW" | openssl x509 -out tls.crt
cp drgitopsapp.apps.drroc4.decrypted.key tls.key
cat SubCA.cer RootCA.cer > ca-chain.crt

# why: a bad SAN (e.g. /maximo) breaks the Manage route later — check it now.
openssl x509 -in tls.crt -noout -ext subjectAltName
```

## Step 2 — (S3 only) Prepare the PowerScale S3 CA certs
```bash
# why: S3 attachments need the storage CA trusted; split the chain into SubCA + RootCA.
tr -d '\r' < /etc/pki/ca-trust/source/anchors/spire-chain.cer > s3-chain.pem   # strip Windows CRLF
awk '/BEGIN CERT/{n++} {print > ("s3-ca-" n ".pem")}' s3-chain.pem

# why: identify which file is the intermediate vs the root (root has subject == issuer).
for f in s3-ca-*.pem; do echo "$f"; openssl x509 -in "$f" -noout -subject -issuer; done

# why: seed script reads these two vars for the manage-cos secret (edit filenames to match above).
export POWERSCALE_S3_SUBCA="$(cat s3-ca-1.pem)"     # intermediate (subject != issuer)
export POWERSCALE_S3_ROOTCA="$(cat s3-ca-2.pem)"    # root (subject == issuer)
```

## Step 3 — Seed all secrets into AWS Secrets Manager
```bash
# why: MAS reads every secret from AWS at sync time — they must exist before you bootstrap.
export REGION=us-east-1 CLUSTER=drroc4 INSTANCE=drgitopsapp
export ENTITLEMENT_KEY='<ibm-entitlement-key>' LICENSE_FILE=./entitlement.lic
export MONGO_ADMIN_PASSWORD='<32-char>' SLS_MONGO_PASSWORD='<32-char>'
export JDBC_USERNAME=maximo JDBC_PASSWORD='<pw>' JDBC_URL='jdbc:oracle:thin:@//db:1521/MAXPDB'
export TLS_CRT=$PWD/tls.crt TLS_KEY=$PWD/tls.key CA_CHAIN=$PWD/ca-chain.crt
# POWERSCALE_S3_SUBCA / POWERSCALE_S3_ROOTCA already exported in Step 2 (S3 only)
./scripts/seed-aws-secrets.sh
# note: mongo#ca.crt, sls, and dro are NOT seeded here — they are created automatically during install.
```

## Step 4 — Put the two keys (+ repo credential) into OpenShift
```bash
# why: Argo CD needs a git credential to pull your private repos.
oc -n openshift-gitops create secret generic gitlab-gitops-group-repo-creds \
  --from-literal=type=git --from-literal=url=https://gitlab.lac1.biz/gitops \
  --from-literal=username='<deploy-user>' --from-literal=password='<deploy-token>' \
  --dry-run=client -o yaml | oc label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml | oc apply -f -

# why: Argo CD reads AWS secrets with the READER key.
oc create secret generic aws-static-credentials -n openshift-gitops \
  --from-literal=region=us-east-1 \
  --from-literal=aws_access_key_id=AKIA<reader> --from-literal=aws_secret_access_key=<reader-secret>

# why: the PUBLISHER key writes back generated secrets, and is needed in BOTH namespaces
#      (openshift-gitops for SLS/DRO, mongo-gitops for the Mongo-CA publish job).
for ns in openshift-gitops mongo-gitops; do
  oc create ns $ns 2>/dev/null || true
  oc create secret generic aws-static-credentials-publisher -n $ns \
    --from-literal=region=us-east-1 \
    --from-literal=aws_access_key_id=AKIA<pub> --from-literal=aws_secret_access_key=<pub-secret>
done
```

## Step 5 — Set the instance config (incl. S3 mode), render, push
```bash
# why: choose the attachment mode. s3-migration = NFS mounted + S3 configured (during migration).
#      edit mas-gitops-config/envs/drroc4.env ->  MANAGE_ATTACHMENT_PROVIDER=s3-migration
cd ../mas-gitops-config

# why: fill the templates with drroc4 values and push, so Argo CD pulls the rendered manifests.
./render.sh drroc4
git add -A && git commit -m "render drroc4" && git push

# why: catch id / branch mismatches before anything is applied.
cd ../platform-gitops
./scripts/preflight-consistency.sh drroc4
```

## Step 6 — Bootstrap in order (each step gates the next)
```bash
# why: wire Argo CD + the AVP sidecar so <path:> placeholders resolve from AWS.
./bootstrap/00-prereqs.sh drroc4

# why: install cert-manager + operators — MongoDB and MAS need their CRDs.
./bootstrap/05-operators.sh drroc4
oc wait --for=condition=Established crd/certificates.cert-manager.io --timeout=10m

# why: MongoDB + its CA; this step WAITS until mongo#ca.crt is published so MAS can trust it.
./bootstrap/20-mongodb.sh drroc4

# why: deploy MAS — the account root fans out into Suite, SLS, DRO, Manage, workspace.
./bootstrap/30-mas.sh drroc4
```

## Step 7 — Verify
```bash
# why: confirm every layer is up.
./scripts/status.sh drroc4
oc get certificate -n mongo-gitops                     # mongo-ca + -server = Ready
oc get suites.core.mas.ibm.com -A                      # Suite Ready
oc get manageapps,manageworkspaces -n mas-drgitopsapp-manage
oc get route -n mas-drgitopsapp-manage                 # ...manage.../maximo opens with a valid cert
```

## Step 8 — (S3 only) Finish the migration, later
```bash
# why: after Manage is up, copy existing NFS attachments to S3, then go S3-only.
# 1. run IBM's Manage attachment-migration job (NFS -> PowerScale S3)
# 2. set MANAGE_ATTACHMENT_PROVIDER=s3 in envs/drroc4.env
./render.sh drroc4 && git -C ../mas-gitops-config commit -am "s3 only" && git -C ../mas-gitops-config push
```
