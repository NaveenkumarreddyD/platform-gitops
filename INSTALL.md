# IBM MAS installation with AWS Secrets Manager

This is the supported fresh-install procedure. The IBM source is the unmodified official
`ibm-mas/gitops` release `8.4.2`, pinned so a later upstream release cannot change a
running installation unexpectedly.

Examples use `drroc4`. Replace it with the required environment name.

## 1. Architecture and access

The on-premises workloads authenticate to AWS with an IAM access key whose secret half is
held in One Identity Safeguard. An AWS `credential_process` calls Safeguard's
Application-to-Application (A2A) API over mutual TLS, fetches the secret access key, and
hands the AWS SDK short-cached static credentials:

```text
repo-server A2A client cert -> Safeguard A2A (read registration)  -> read IAM key  -> manifest generation
publisher  A2A client cert -> Safeguard A2A (write registration) -> write IAM key -> generated SLS/DRO secrets
```

A long-lived AWS access key still exists, but it is stored and rotated inside One Identity
Safeguard, never in the cluster. Do not store `AWS_SECRET_ACCESS_KEY` in an OpenShift
Secret. There is no Roles Anywhere, trust anchor, profile, or X.509-to-STS exchange.

Create these resources:

1. An IAM user with an access key for Argo CD manifest generation (read).
2. A separate IAM user with an access key for generated SLS/DRO registration (write).
   Separate users keep least privilege intact.
3. For each IAM user, register its access key as a Safeguard **managed account** and
   configure Safeguard to **auto-rotate** that key on a schedule. Safeguard-side rotation
   is what keeps a long-lived key acceptable.
4. A Safeguard **A2A registration** per workload: the managed account holding the AWS
   secret access key, an A2A API key, and a client certificate the workload presents for
   mutual TLS. Use a separate registration for the reader and the publisher.

Store only the AWS access key **ID** in the cluster (a public identifier). The secret half
is retrieved from Safeguard at run time and cached for `credentialTtlSeconds`; a short TTL
makes the SDK re-fetch periodically so Safeguard-side key rotation is picked up.

The read policy needs `secretsmanager:GetSecretValue` and
`secretsmanager:DescribeSecret` on:

```text
arn:aws:secretsmanager:<region>:<aws-account>:secret:mas/<account>/<cluster>/*
```

The publisher policy needs only `secretsmanager:CreateSecret`,
`secretsmanager:DescribeSecret`, `secretsmanager:GetSecretValue`, and
`secretsmanager:PutSecretValue` on these two resources. AWS appends characters to a
secret ARN, so retain the final wildcard:

```text
arn:aws:secretsmanager:<region>:<aws-account>:secret:mas/<account>/<cluster>/dro-??????
arn:aws:secretsmanager:<region>:<aws-account>:secret:mas/<account>/<cluster>/<instance>/sls-??????
```

Do not grant the publisher `DeleteSecret`, `ListSecrets`, or access to deployment
credentials. Scope each IAM user's policy to only the secrets and actions it needs.

If the secrets use a customer-managed KMS key, allow `kms:Decrypt` to the read user and
the minimum encrypt/data-key permissions required by Secrets Manager to the publisher.
Restrict both with `kms:ViaService=secretsmanager.<region>.amazonaws.com`.

Allow HTTPS egress from the repo-server and publisher to the regional Secrets Manager
endpoint and to the Safeguard A2A appliance URL.

For on-premises clusters, prefer **interface VPC endpoints (AWS PrivateLink)** over public
egress so no AWS traffic leaves the AWS network. The AWS services support them:
`com.amazonaws.<region>.sts` and `com.amazonaws.<region>.secretsmanager` (plus
`com.amazonaws.<region>.kms` for a CMK). Reach them over Direct Connect or VPN, and resolve
the service DNS to the private endpoint IPs from on-premises (Route 53 Resolver inbound
endpoint). When using endpoints, gate access with `aws:SourceVpce` on the secret and KMS
policies rather than `aws:SourceIp` — the source-IP condition is not evaluated for requests
that arrive through a VPC endpoint.

The strongest posture is to let Safeguard broker the credential and rely on its rotation
and audit trail. Because a real AWS access key exists, key rotation, least-privilege IAM,
KMS encryption, private VPC endpoints, and CloudTrail all matter more, not less.

Argo CD caches generated manifests after substitution. Restrict access to the repo-server,
Redis, Argo CD API/UI, and application manifests to the same administrative boundary as
the referenced secrets.

References:

- https://docs.aws.amazon.com/sdkref/latest/guide/feature-process-credentials.html
- One Identity Safeguard Application-to-Application (A2A) service documentation.

## 2. Required tools and repositories

Required locally: `oc`, `helm`, `git`, `openssl`, `jq`, and Python 3.

Required repositories:

| Repository | Source |
|---|---|
| Platform | your `platform-gitops` repository |
| Configuration | your `mas-gitops-config` repository |
| IBM MAS GitOps | `https://github.com/ibm-mas/gitops.git`, tag `8.4.2` |

The IBM repository is read directly from GitHub. Do not apply local patches to it.

Create the GitLab repository credential for the two private repositories:

```bash
oc -n openshift-gitops create secret generic gitlab-gitops-group-repo-creds \
  --from-literal=type=git \
  --from-literal=url=https://gitlab.lac1.biz/gitops \
  --from-literal=username='<deploy-user>' \
  --from-literal=password='<deploy-token>' \
  --dry-run=client -o yaml |
oc label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml |
oc apply -f -
```

## 3. Configure the workload identity

Create the non-secret reader settings. `accessKeyId` is the AWS access key ID (public);
its secret half comes from Safeguard. `safeguardA2aUrl` is the full A2A retrieval URL, and
`credentialTtlSeconds` is how long the SDK caches before re-fetching:

```bash
oc -n openshift-gitops create configmap aws-secrets-manager-auth \
  --from-literal=region='<aws-region>' \
  --from-literal=safeguardA2aUrl='https://safeguard.corp.example/service/a2a/v4/Credentials?type=Password' \
  --from-literal=accessKeyId='<reader-access-key-id>' \
  --from-literal=credentialTtlSeconds='900' \
  --dry-run=client -o yaml | oc apply -f -
```

Create the reader A2A identity Secret from the client certificate, its unencrypted key, and
the A2A API key. Mount `ca.pem` only for a private or internal Safeguard appliance:

```bash
oc -n openshift-gitops create secret generic oneidentity-a2a-avp \
  --from-file=client-cert.pem=/secure/path/reader-client.crt \
  --from-file=client-key.pem=/secure/path/reader-client.key \
  --from-file=api-key=/secure/path/reader-a2a-api-key \
  --from-file=ca.pem=/secure/path/safeguard-ca.pem \
  --dry-run=client -o yaml | oc apply -f -
```

The client certificate and private key are the mutual-TLS identity Safeguard trusts, not
AWS access keys. Never commit the private key or the API key. Rotate the A2A identity in
Safeguard and revoke it immediately if it is exposed.

Create the publisher settings with the separate IAM access key ID and Safeguard
registration:

```bash
oc -n openshift-gitops create configmap aws-secrets-manager-publisher-auth \
  --from-literal=region='<aws-region>' \
  --from-literal=safeguardA2aUrl='https://safeguard.corp.example/service/a2a/v4/Credentials?type=Password' \
  --from-literal=accessKeyId='<publisher-access-key-id>' \
  --from-literal=credentialTtlSeconds='900' \
  --dry-run=client -o yaml | oc apply -f -

oc -n openshift-gitops create secret generic oneidentity-a2a-publisher \
  --from-file=client-cert.pem=/secure/path/publisher-client.crt \
  --from-file=client-key.pem=/secure/path/publisher-client.key \
  --from-file=api-key=/secure/path/publisher-a2a-api-key \
  --from-file=ca.pem=/secure/path/safeguard-ca.pem \
  --dry-run=client -o yaml | oc apply -f -
```

The reader and publisher must use separate Safeguard registrations and separate IAM users
so least privilege is preserved. The secret access key is fetched from Safeguard only when
the workload calls Secrets Manager, and is cached in memory for `credentialTtlSeconds`.

## 4. Create the static deployment secrets

Use an approved federated administrator session, such as AWS IAM Identity Center. The
administrator role may create and rotate secrets; the repo-server role remains read-only.

Secret names and fields:

| Secret name | Required fields |
|---|---|
| `mas/<account>/<cluster>/entitlement` | `image_pull_secret_b64` |
| `mas/<account>/<cluster>/<instance>/license` | `license_file` |
| `mas/<account>/<cluster>/<instance>/mongo-ca` | `tls_crt_b64`, `tls_key_b64` |
| `mas/<account>/<cluster>/<instance>/mongo` | `username`, `password`, `host`, `ca.crt` |
| `mas/<account>/<cluster>/<instance>/sls-mongo` | `username`, `password`, `ca.crt` |
| `mas/<account>/<cluster>/<instance>/jdbc-system` | `username`, `password`, `jdbc_url` |
| `mas/<account>/<cluster>/<instance>/certs/public` | `tls_crt_b64`, `tls_key_b64`, `ca_crt_b64` |
| `mas/<account>/<cluster>/<instance>/manage-crypto` | required only when reusing a Manage database: `cryptoKey`, `cryptoxKey` |
| `mas/<account>/<cluster>/<instance>/manage-cos` | optional S3 attachment fields documented in the config repository |

Encoding rules:

- `license_file`, Mongo `ca.crt`, and SLS Mongo `ca.crt` contain their original text.
- `tls_crt_b64`, `tls_key_b64`, and `ca_crt_b64` contain one base64 encoding of the file.
- `image_pull_secret_b64` is one base64 encoding of the complete Docker config JSON.
- Each secret value is one JSON object; field names are case-sensitive.

Create or update a secret without putting its value on the command line:

```bash
export AWS_REGION='<aws-region>'
export SECRET_ID='mas/<account>/<cluster>/<instance>/jdbc-system'
umask 077
PAYLOAD=$(mktemp)
trap 'rm -f "$PAYLOAD"' EXIT
jq -n \
  --arg username '<jdbc-user>' \
  --arg password '<jdbc-password>' \
  --arg jdbc_url 'jdbc:oracle:thin:@//host:1521/service' \
  '{username:$username,password:$password,jdbc_url:$jdbc_url}' > "$PAYLOAD"

if aws secretsmanager describe-secret --region "$AWS_REGION" --secret-id "$SECRET_ID" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --region "$AWS_REGION" \
    --secret-id "$SECRET_ID" --secret-string "file://$PAYLOAD"
else
  aws secretsmanager create-secret --region "$AWS_REGION" \
    --name "$SECRET_ID" --secret-string "file://$PAYLOAD"
fi
```

Use the same pattern for the remaining JSON payloads. Keep backups and rotation under the
company's approved AWS controls.

## 5. Render and validate the environment

```bash
cd /path/to/mas-gitops-config
./render.sh drroc4
git diff --check
git diff
git add .
git commit -m "Render drroc4 for AWS Secrets Manager"
git push

cd /path/to/platform-gitops
./scripts/preflight-consistency.sh drroc4
helm template platform gitops \
  -f gitops/envs/drroc4/common.yaml \
  -f gitops/envs/drroc4/values.yaml \
  --set component=all >/dev/null
```

The preflight must pass before anything is applied.

## 6. Install in order

```bash
./bootstrap/00-prereqs.sh drroc4
./bootstrap/05-operators.sh drroc4
./bootstrap/20-mongodb.sh drroc4
./bootstrap/30-mas.sh drroc4
```

What each step does:

1. `00-prereqs` configures Argo CD, the AWS Secrets Manager plugin, and the One Identity
   Safeguard A2A credential process.
2. `05-operators` installs and verifies cert-manager and any explicitly enabled operator.
3. `20-mongodb` validates its AWS secret fields, then installs the compatible MongoDB
   operator and database.
4. `30-mas` validates MongoDB and the static MAS secrets, then applies the IBM account
   root and automatic generated-secret publisher.

Use `./scripts/status.sh drroc4` while the IBM applications reconcile.

## 7. Automatic DRO and SLS registration

IBM `8.4.2` post-sync write-back Jobs accept only static AWS access keys and publish a
different field contract, so those two Jobs remain disabled. The platform's
`aws-generated-secrets-publisher` Deployment replaces that function automatically.

Every five minutes it checks the generated OpenShift resources, obtains AWS credentials
through the publisher's One Identity Safeguard A2A registration, and creates or updates:

```text
mas/<account>/<cluster>/dro
mas/<account>/<cluster>/<instance>/sls
```

It compares JSON before writing, so an unchanged registration does not create another
Secrets Manager version. No operator publish or Argo CD refresh is required.

Watch the automatic handoff without printing secret values:

```bash
oc get application aws-generated-secrets-publisher-drroc4 -n openshift-gitops
oc rollout status deployment/aws-generated-secrets-publisher \
  -n openshift-gitops --timeout=10m
oc logs deployment/aws-generated-secrets-publisher \
  -n openshift-gitops --tail=100 -f
./scripts/status.sh drroc4
```

## 8. Completion checks

```bash
./scripts/status.sh drroc4
oc get mongocfgs,slscfgs,jdbccfgs,bascfgs.config.mas.ibm.com -A
oc get suites.core.mas.ibm.com -A
oc get workspaces.core.mas.ibm.com -A
oc get manageapps,manageworkspaces -A
```

The installation is complete when Argo CD is synced and healthy, all system
configurations are Ready, the Suite and Manage workspace are Ready, and the MAS and
Manage login routes work.
