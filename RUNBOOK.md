# MAS GitOps operations runbook

Use this after [INSTALL.md](INSTALL.md).

> **Security note.** AWS authentication uses a **long-lived static access key stored in the
> cluster** — the `aws-static-credentials` and `aws-static-credentials-publisher` Secrets in
> `openshift-gitops`. This is the simple bootstrap approach and is what production security
> policy usually wants to avoid. Keep each key least-privileged, rotate it on a schedule, and
> delete any key that is exposed.

## Quick status

```bash
./scripts/status.sh <env>
oc get applications -n openshift-gitops
oc get pods -n mongo-gitops
oc get licenseservices.sls.ibm.com -A
oc get mongocfgs,slscfgs,jdbccfgs,bascfgs.config.mas.ibm.com -A
oc get suites.core.mas.ibm.com -A
oc get workspaces.core.mas.ibm.com -A
oc get manageapps,manageworkspaces -A
```

## AWS secret substitution fails

```bash
oc describe secret aws-static-credentials -n openshift-gitops
oc get deployment openshift-gitops-repo-server -n openshift-gitops
oc logs deployment/openshift-gitops-repo-server -n openshift-gitops \
  -c avp-helm --tail=200
oc exec -n openshift-gitops deployment/openshift-gitops-repo-server \
  -c avp-helm -- printenv AVP_TYPE AWS_REGION AWS_ACCESS_KEY_ID
```

Confirm the plugin is AWS and can resolve a real secret, without displaying any value.
The sidecar image has no `aws` CLI, so verify through AVP rather than `aws sts`:

```bash
oc exec -n openshift-gitops deployment/openshift-gitops-repo-server \
  -c avp-helm -- printenv AVP_TYPE AWS_REGION
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: t\nstringData:\n  u: <path:mas/<account>/<cluster>/<instance>/jdbc-system#username>\n' \
  | oc exec -i -n openshift-gitops deployment/openshift-gitops-repo-server \
  -c avp-helm -- argocd-vault-plugin generate -
```

Check the following:

- The `aws-static-credentials` Secret exists and its `region`, `aws_access_key_id`, and
  `aws_secret_access_key` values are correct and not expired or deactivated.
- The IAM access key can read the exact `mas/<account>/<cluster>/...` secret ARN.
- Customer-managed KMS keys allow this IAM user to decrypt through Secrets Manager.
- Egress to Secrets Manager is allowed.
- The secret exists and the JSON field has the exact case used by the placeholder.

After correcting AWS or credential data, restart the repo-server when its mounted
Secret or configuration changed:

```bash
oc rollout restart deployment/openshift-gitops-repo-server -n openshift-gitops
oc rollout status deployment/openshift-gitops-repo-server \
  -n openshift-gitops --timeout=10m
```

For a value-only change in Secrets Manager, a hard refresh is enough:

```bash
oc annotate application <application> -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Rotate the AWS access key

Rotate the reader key on a schedule. Create a new access key for the reader IAM user,
update the Secret, roll the repo-server, confirm substitution works, then delete the old
key in AWS:

```bash
oc create secret generic aws-static-credentials -n openshift-gitops \
  --from-literal=region=us-east-1 \
  --from-literal=aws_access_key_id=AKIANEWKEYIDXXXXXXXX \
  --from-literal=aws_secret_access_key=newsecret \
  --dry-run=client -o yaml | oc apply -f -
oc rollout restart deployment/openshift-gitops-repo-server -n openshift-gitops
oc rollout status deployment/openshift-gitops-repo-server \
  -n openshift-gitops --timeout=10m
```

Run the substitution check above, then delete the superseded access key in AWS. Rotate the
publisher key the same way against `aws-static-credentials-publisher` (in **both** `openshift-gitops`
and `mongo-gitops`) and re-seed the AWS SM `publisher` secret; then re-sync the DRO/SLS apps so
IBM's `postsync-update-sm` jobs re-run with the new key.

## DRO or SLS registration is missing

SLS/DRO generated secrets are published to AWS SM by IBM's **native `postsync-update-sm` jobs**
(`run_sync_hooks: true`), which run on each Argo CD sync. Check the jobs and their source resources:

```bash
oc get job -A | grep update-sm                       # postsync-ibm-dro-update-sm / postsync-ibm-sls-update-sm
oc logs job/<postsync-...-update-sm-job> -n <ns> --tail=200
# source resources the jobs read (confirm they exist, don't print values):
oc get route ibm-data-reporter -n ibm-software-central
oc get secret ibm-data-reporter-operator-api-token -n ibm-software-central
oc get configmap sls-suite-registration -n mas-<instance>-sls
```

The jobs run on **sync**, not on a timer. After fixing credentials / IAM / the source resource,
re-sync the DRO or SLS app to re-run the job:

```bash
oc annotate application dro.<cluster> -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
```

If a job fails with a **TLS / x509 "unknown authority"** error reaching the DRO/SLS route, the
cluster doesn't trust the internal ingress CA — populate `ca-bundle.crt` in the Proxy's trust
ConfigMap (`openshift-config/custom-ca`) with your internal root CA.

Verify the expected AWS fields (IBM's native layout — **bare path, IBM field names**):

```bash
aws secretsmanager get-secret-value --region "$AWS_REGION" \
  --secret-id "<account>/<cluster>/dro" --query SecretString --output text |
jq -e 'has("dro_url") and has("dro_api_token") and has("dro_ca_b64enc")'

aws secretsmanager get-secret-value --region "$AWS_REGION" \
  --secret-id "<account>/<cluster>/<instance>/sls" --query SecretString --output text |
jq -e 'has("registration_key") and has("ca_b64")'
```

## MongoDB is not Running

```bash
oc get mongodbcommunity -n mongo-gitops -o yaml
oc get pods,pvc,certificate,secret -n mongo-gitops
oc logs deployment/mongodb-kubernetes-operator -n mongo-gitops --tail=200
oc get events -n mongo-gitops --sort-by=.lastTimestamp
```

Confirm the storage class provisions the PVCs, the operator version matches the live
OpenShift version, and the `mongo-ca`, `mongo`, and `sls-mongo` fields follow the
encoding rules in `INSTALL.md`.

## A MAS configuration is not Ready

```bash
oc describe mongocfg <instance>-mongo-system -n mas-<instance>-core
oc describe slscfg <instance>-sls-system -n mas-<instance>-core
oc describe jdbccfg <instance>-jdbc-system -n mas-<instance>-core
oc describe bascfg <instance>-bas-system -n mas-<instance>-core
```

- `MongoCfg`: confirm host, user, password, and CA.
- `SlsCfg`: confirm the generated SLS secret and URL.
- `JdbcCfg`: confirm Oracle reachability and the JDBC URL.
- `BasCfg`: confirm the cluster-level DRO secret and API token.

## Certificate problems

Every `*_b64` field must decode exactly once to valid PEM:

```bash
printf '%s' '<tls_crt_b64>' | base64 -d |
openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Check the Suite and Manage certificate Secrets and the certificate presented by each route:

```bash
oc get secrets -n mas-<instance>-core | grep cert
oc get secrets -n mas-<instance>-manage | grep cert
openssl s_client -connect <route-host>:443 -servername <route-host> </dev/null 2>/dev/null |
openssl x509 -noout -subject -issuer -dates
```

## Manage is not Ready

```bash
oc describe suite <instance> -n mas-<instance>-core
oc get manageapp,manageworkspace -n mas-<instance>-manage
oc describe manageapp <instance> -n mas-<instance>-manage
oc describe manageworkspace <instance>-<workspace> -n mas-<instance>-manage
oc get pods,events -n mas-<instance>-manage
```

For a fresh database, `autoGenerateEncryptionKeys` may be true. A cloned or reused
database must use its original Manage encryption keys. Store captured keys in the
`manage-crypto` AWS secret before rebuilding the environment.

## Secret backup and rollback

Use AWS Secrets Manager versioning and the approved AWS backup policy. Before a material
change, record the current version ID:

```bash
aws secretsmanager list-secret-version-ids --region "$AWS_REGION" \
  --secret-id '<secret-id>'
```

Rollback moves the `AWSCURRENT` stage to the known-good version:

```bash
aws secretsmanager update-secret-version-stage --region "$AWS_REGION" \
  --secret-id '<secret-id>' \
  --version-stage AWSCURRENT \
  --move-to-version-id '<known-good-version-id>' \
  --remove-from-version-id '<bad-version-id>'
```

Hard-refresh the affected Argo CD application after rollback. Database, attachment, and
Manage encryption-key recovery still require their own coordinated backups; secret
version rollback does not restore application data.
