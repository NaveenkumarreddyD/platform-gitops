# IBM MAS installation with AWS Secrets Manager

This is the supported fresh-install procedure. The IBM source is the `ibm-mas/gitops`
`8.5.0` release served from the internal fork `https://gitlab.lac1.biz/gitops/ibm-gitops.git`
(revision `8.5.0-jdbc-patch`), pinned so a later upstream release cannot change a running
installation unexpectedly. The fork is stock 8.5.0 except the JDBC config chart's
`sslEnabled` is made configurable via `jdbc_ssl_enabled` (to support a non-SSL database).

Examples use `drroc4`. Replace it with the required environment name.

## 1. Architecture and access

> **Security note.** This procedure stores a **long-lived AWS access key in the cluster**
> (a Kubernetes Secret in `openshift-gitops`), which is exactly what production security
> policy usually wants to avoid. It is the simple bootstrap approach. Keep each key
> **least-privileged**, **rotate it** on a schedule, and delete any key that is exposed.

The on-premises workloads authenticate to AWS Secrets Manager with a **static IAM access
key** read from a Kubernetes Secret through plain environment variables
(`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`):

```text
repo-server (avp-helm) reads aws-static-credentials           -> reads MAS secrets  -> manifest generation
publisher reads aws-static-credentials-publisher              -> writes IAM secrets -> generated SLS/DRO secrets
```

Create these resources:

1. An IAM user with an access key for Argo CD manifest generation (read).
2. A separate IAM user with an access key for generated SLS/DRO registration (write).
   Separate users keep least privilege intact.
3. Rotate each key on a schedule with your approved AWS controls, and delete any key that
   is exposed.

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
endpoint.

For on-premises clusters, prefer **interface VPC endpoints (AWS PrivateLink)** over public
egress so no AWS traffic leaves the AWS network. The AWS services support them:
`com.amazonaws.<region>.secretsmanager` (plus `com.amazonaws.<region>.kms` for a CMK).
Reach them over Direct Connect or VPN, and resolve the service DNS to the private endpoint
IPs from on-premises (Route 53 Resolver inbound endpoint). When using endpoints, gate
access with `aws:SourceVpce` on the secret and KMS policies rather than `aws:SourceIp` —
the source-IP condition is not evaluated for requests that arrive through a VPC endpoint.

Because a real long-lived AWS access key exists in the cluster, key rotation,
least-privilege IAM, KMS encryption, private VPC endpoints, and CloudTrail all matter
more, not less.

Argo CD caches generated manifests after substitution. Restrict access to the repo-server,
Redis, Argo CD API/UI, and application manifests to the same administrative boundary as
the referenced secrets.

## 2. Required tools and repositories

Required locally: `oc`, `helm`, `git`, `openssl`, `jq`, and Python 3.

Required repositories:

| Repository | Source |
|---|---|
| Platform | your `platform-gitops` repository |
| Configuration | your `mas-gitops-config` repository |
| IBM MAS GitOps (fork) | `https://gitlab.lac1.biz/gitops/ibm-gitops.git`, revision `8.5.0-jdbc-patch` |

The IBM fork is read from GitLab at the pinned revision `8.5.0-jdbc-patch`. It is stock
upstream 8.5.0 plus the single reviewed JDBC `sslEnabled` change; do not add further local
patches to it.

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

Create two Secrets in namespace `openshift-gitops`, each holding the keys `region`,
`aws_access_key_id`, and `aws_secret_access_key`. The workloads read them as the
`AWS_REGION`, `AWS_ACCESS_KEY_ID`, and `AWS_SECRET_ACCESS_KEY` environment variables.

- `aws-static-credentials` — the reader. AVP resolves `<path:>` placeholders at sync time
  with this key, which is read-only.
- `aws-static-credentials-publisher` — the publisher. It writes the generated SLS/DRO
  registration with this separate write-scoped key.

```bash
oc create secret generic aws-static-credentials -n openshift-gitops \
  --from-literal=region=us-east-1 \
  --from-literal=aws_access_key_id=AKIAXXXXXXXXXXXXXXXX \
  --from-literal=aws_secret_access_key=xxxxxxxx

oc create secret generic aws-static-credentials-publisher -n openshift-gitops \
  --from-literal=region=us-east-1 \
  --from-literal=aws_access_key_id=AKIAYYYYYYYYYYYYYYYY \
  --from-literal=aws_secret_access_key=yyyyyyyy
```

The reader and publisher must use separate IAM users so least privilege is preserved.
Never commit these keys. Rotate them on a schedule and delete either key immediately if it
is exposed.

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

First configure the environment file in the configuration repository
(`mas-gitops-config/envs/drroc4.env`). It sets the Manage (Maximo) deployment values —
`INSTANCE_ID`, `WORKSPACE_ID`, `MAS_EDITION`, the database schema/tablespace, the JDBC SSL
mode (`jdbc_ssl_enabled`), the attachment provider, the encryption-key mode, and the
optional per-bundle JMS `server.xml`. Then render, which fills those values and leaves the
`<path:>` placeholders for AVP to resolve from AWS Secrets Manager:

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

1. `00-prereqs` configures Argo CD and the AWS Secrets Manager plugin, wiring the
   `aws-static-credentials` Secret into the repo-server as AWS environment variables.
2. `05-operators` installs and verifies cert-manager and any explicitly enabled operator.
3. `20-mongodb` validates its AWS secret fields, then installs the compatible MongoDB
   operator and database.
4. `30-mas` validates MongoDB and the static MAS secrets, then applies the IBM account
   root and automatic generated-secret publisher.

Use `./scripts/status.sh drroc4` while the IBM applications reconcile.

## 7. Automatic DRO and SLS registration

IBM `8.5.0` post-sync write-back Jobs accept only static AWS access keys and publish a
different field contract, so those two Jobs remain disabled. The platform's
`aws-generated-secrets-publisher` Deployment replaces that function automatically.

Every five minutes it checks the generated OpenShift resources, authenticates to AWS with
the static key in `aws-static-credentials-publisher`, and creates or updates:

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
