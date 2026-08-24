# IBM MAS installation with AWS Secrets Manager

This is the supported fresh-install procedure. The IBM source is the unmodified official
`ibm-mas/gitops` release `8.4.2`, pinned so a later upstream release cannot change a
running installation unexpectedly.

Examples use `drroc4`. Replace it with the required environment name.

## 1. Architecture and access

The on-premises workloads authenticate to AWS with IAM Roles Anywhere:

```text
repo-server certificate -> 15-minute read role -> manifest generation
publisher certificate   -> 15-minute write role -> generated SLS/DRO secrets
```

Do not create an IAM user or store `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` in OpenShift.

Create these AWS resources:

1. A Roles Anywhere trust anchor for the approved issuing CA.
2. A read profile and role for Argo CD manifest generation.
3. A separate write profile and role for generated SLS/DRO registration.
4. Both profiles limited to 900-second sessions with audit-friendly session names.
5. A dedicated end-entity certificate for each workload.

The role trust policy must include `sts:AssumeRole`, `sts:TagSession`, and
`sts:SetSourceIdentity`, restricted to the expected trust anchor and AWS account:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "rolesanywhere.amazonaws.com"},
    "Action": ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"],
    "Condition": {
      "ArnEquals": {
        "aws:SourceArn": "arn:aws:rolesanywhere:<region>:<aws-account>:trust-anchor/<id>"
      },
      "StringEquals": {
        "aws:SourceAccount": "<aws-account>"
      }
    }
  }]
}
```

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
credentials. Use certificate subject conditions in the role trust policies when the
company PKI exposes stable subject attributes.

If the secrets use a customer-managed KMS key, allow `kms:Decrypt` to the read role and
the minimum encrypt/data-key permissions required by Secrets Manager to the publisher.
Restrict both with `kms:ViaService=secretsmanager.<region>.amazonaws.com`.

Allow HTTPS egress from the repo-server and publisher to the regional IAM Roles Anywhere
and Secrets Manager endpoints.

For on-premises clusters, prefer **interface VPC endpoints (AWS PrivateLink)** over public
egress so no traffic leaves the AWS network. All three services support them:
`com.amazonaws.<region>.rolesanywhere`, `com.amazonaws.<region>.sts`, and
`com.amazonaws.<region>.secretsmanager` (plus `com.amazonaws.<region>.kms` for a CMK).
Reach them over Direct Connect or VPN, and resolve the service DNS to the private endpoint
IPs from on-premises (Route 53 Resolver inbound endpoint, or `--endpoint` on the signing
helper). When using endpoints, gate access with `aws:SourceVpce` on the role and secret
policies rather than `aws:SourceIp` — the source-IP condition is not evaluated for requests
that arrive through a VPC endpoint. Note that endpoint policies do not apply to the Roles
Anywhere `CreateSession` action, so enforce scope on the role and profile.

Argo CD caches generated manifests after substitution. Restrict access to the repo-server,
Redis, Argo CD API/UI, and application manifests to the same administrative boundary as
the referenced secrets.

AWS references:

- https://docs.aws.amazon.com/rolesanywhere/latest/userguide/trust-model.html
- https://docs.aws.amazon.com/sdkref/latest/guide/access-rolesanywhere.html

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

Create the non-secret read-role settings:

```bash
oc -n openshift-gitops create configmap aws-secrets-manager-auth \
  --from-literal=region='<aws-region>' \
  --from-literal=roleArn='arn:aws:iam::<aws-account>:role/<role>' \
  --from-literal=profileArn='arn:aws:rolesanywhere:<region>:<aws-account>:profile/<id>' \
  --from-literal=trustAnchorArn='arn:aws:rolesanywhere:<region>:<aws-account>:trust-anchor/<id>' \
  --from-literal=roleSessionName='mas-gitops-<cluster>' \
  --dry-run=client -o yaml | oc apply -f -
```

Create the identity Secret from the dedicated certificate and unencrypted private key:

```bash
oc -n openshift-gitops create secret generic aws-rolesanywhere-avp \
  --from-file=certificate.pem=/secure/path/workload.crt \
  --from-file=private-key.pem=/secure/path/workload.key \
  --from-file=intermediates.pem=/secure/path/intermediate-chain.pem \
  --dry-run=client -o yaml | oc apply -f -
```

The intermediate file is optional when the leaf certificate chains directly to the trust
anchor. Never commit the certificate's private key. Rotate this identity through the
company PKI and revoke it immediately if it is exposed.

Create the publisher settings with the separate write role and profile:

```bash
oc -n openshift-gitops create configmap aws-secrets-manager-publisher-auth \
  --from-literal=region='<aws-region>' \
  --from-literal=roleArn='arn:aws:iam::<aws-account>:role/<publisher-role>' \
  --from-literal=profileArn='arn:aws:rolesanywhere:<region>:<aws-account>:profile/<publisher-profile-id>' \
  --from-literal=trustAnchorArn='arn:aws:rolesanywhere:<region>:<aws-account>:trust-anchor/<id>' \
  --from-literal=roleSessionName='mas-publisher-<cluster>' \
  --dry-run=client -o yaml | oc apply -f -

oc -n openshift-gitops create secret generic aws-rolesanywhere-publisher \
  --from-file=certificate.pem=/secure/path/publisher.crt \
  --from-file=private-key.pem=/secure/path/publisher.key \
  --from-file=intermediates.pem=/secure/path/intermediate-chain.pem \
  --dry-run=client -o yaml | oc apply -f -
```

The publisher certificate and private key are workload identity material, not AWS access
keys. The AWS helper exchanges them for a 15-minute session only when the publisher calls
Secrets Manager.

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

1. `00-prereqs` configures Argo CD, the AWS Secrets Manager plugin, and Roles Anywhere.
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

Every five minutes it checks the generated OpenShift resources, obtains a 15-minute
publisher session through IAM Roles Anywhere, and creates or updates:

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
