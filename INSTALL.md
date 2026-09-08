# Install MAS (GitOps + AWS Secrets Manager)

Deploy branches: `platform-gitops`@`main`, `mas-gitops-config`@`main`, `ibm-mas-gitops`@`8.5.0-jdbc-patch`.
Replace `<cluster>` / `<instance>` / `<pub>` / `<reader>` with your values.

## 1. Prerequisites
```bash
oc whoami
oc get argocd openshift-gitops -n openshift-gitops                 # OpenShift GitOps installed

# Internal ingress CA trust (DRO/SLS need it). Must be non-empty:
oc get cm custom-ca -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' | head -c1 || \
  oc create cm custom-ca -n openshift-config --from-file=ca-bundle.crt=/path/to/internal-root-ca.pem \
    --dry-run=client -o yaml | oc apply -f -
```

## 2. Seed secrets into AWS Secrets Manager
```bash
PW=$(cat <inst>.pwd.txt)
openssl pkcs12 -in <inst>.pfx -clcerts -nokeys -passin "pass:$PW" | openssl x509 -out tls.crt
cp <inst>.decrypted.key tls.key
cat SubCA.cer RootCA.cer | tr -d '\r' > ca-chain.crt

export REGION=us-east-1 CLUSTER=<cluster> INSTANCE=<instance>
export ENTITLEMENT_KEY='<ibm-key>' LICENSE_FILE=./entitlement.lic
export MONGO_ADMIN_PASSWORD='<pw>' SLS_MONGO_PASSWORD='<pw>'
export JDBC_USERNAME=maximo JDBC_PASSWORD='<pw>' JDBC_URL='jdbc:oracle:thin:@//db:1521/SVC'
export TLS_CRT=$PWD/tls.crt TLS_KEY=$PWD/tls.key CA_CHAIN=$PWD/ca-chain.crt
export PUBLISHER_AWS_ACCESS_KEY_ID=AKIA<pub> PUBLISHER_AWS_SECRET_ACCESS_KEY='<secret>'
# S3 attachments only: export POWERSCALE_S3_SUBCA="$(cat subca.pem)" POWERSCALE_S3_ROOTCA="$(cat rootca.pem)"
./scripts/seed-aws-secrets.sh
```

## 3. Put keys + repo credential into OpenShift
```bash
oc -n openshift-gitops create secret generic gitlab-gitops-group-repo-creds \
  --from-literal=type=git --from-literal=url=https://gitlab.lac1.biz/gitops \
  --from-literal=username='<deploy-user>' --from-literal=password='<deploy-token>' \
  --dry-run=client -o yaml | oc label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml | oc apply -f -

oc create secret generic aws-static-credentials -n openshift-gitops \
  --from-literal=region=us-east-1 --from-literal=aws_access_key_id=AKIA<reader> --from-literal=aws_secret_access_key=<secret>

for ns in openshift-gitops mongo-gitops; do
  oc create ns $ns 2>/dev/null || true
  oc create secret generic aws-static-credentials-publisher -n $ns \
    --from-literal=region=us-east-1 --from-literal=aws_access_key_id=AKIA<pub> --from-literal=aws_secret_access_key=<secret>
done
```

## 4. Render config and push
```bash
cd ../mas-gitops-config
# new cluster: cp envs/example.env.example envs/<cluster>.env and edit identity/attachment vars
./render.sh <cluster>
git add -A && git commit -m "render <cluster>" && git push        # promote to GitLab main
cd ../platform-gitops
./scripts/preflight-consistency.sh <cluster>
```

## 5. Bootstrap (in order)
```bash
./bootstrap/00-prereqs.sh   <cluster>
./bootstrap/05-operators.sh <cluster>
oc wait --for=condition=Established crd/certificates.cert-manager.io --timeout=10m
./bootstrap/20-mongodb.sh   <cluster>
./bootstrap/30-mas.sh       <cluster>
```

## 6. Verify
```bash
./scripts/status.sh <cluster>
oc get suites.core.mas.ibm.com -A
oc get job -A | grep update-sm                                     # SLS/DRO publish jobs Completed
oc get manageapps,manageworkspaces -n mas-<instance>-manage
oc get route -n mas-<instance>-manage                             # ...manage.../maximo opens
```
