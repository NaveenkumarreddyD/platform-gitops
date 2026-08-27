# IBM MAS platform GitOps

This repository installs IBM Maximo Application Suite on OpenShift with Argo CD and
AWS Secrets Manager. It uses the IBM MAS GitOps `8.4.2` release from the internal fork
`https://gitlab.lac1.biz/gitops/ibm-gitops.git` (revision `official-8.4.2`) — stock
upstream except that the JDBC config chart's `sslEnabled` is made configurable
(`jdbc_ssl_enabled`) so a non-SSL database can be used.

## Design

- `platform-gitops`: Argo CD bootstrap, cert-manager, MongoDB, and the IBM account root.
- `mas-gitops-config`: environment-specific IBM chart values and secret references.
- IBM's repository: consumed directly from the official GitHub URL at the pinned tag.
- AWS Secrets Manager: stores deployment secrets under `mas/<account>/<cluster>/...`.
- AWS authentication: the Argo CD repo-server and publisher authenticate with a **static
  AWS access key** read from a Kubernetes Secret (`aws-static-credentials`) via plain
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION` environment variables. This is
  the simple bootstrap approach; it keeps a long-lived key in the cluster, so the keys must
  be least-privileged and rotated. See [INSTALL.md](INSTALL.md) for the security note.
- Generated-secret publisher: automatically copies SLS and DRO registration into AWS
  Secrets Manager with a separate, write-scoped static key (`aws-static-credentials-publisher`)
  and IAM user.

The `argocd-vault-plugin` executable remains because that is the upstream plugin name used
by IBM's charts. Its configured backend is `awssecretsmanager` (`AVP_TYPE=awssecretsmanager`);
no HashiCorp service, policy, token, or storage is part of this design.

## Install order

```text
00-prereqs -> 05-operators -> 20-mongodb -> 30-mas
```

The scripts are small, idempotent command wrappers. Argo CD and the IBM charts perform the
deployment. Use [INSTALL.md](INSTALL.md) for the supported procedure,
[MANUAL-INSTALL.md](MANUAL-INSTALL.md) for the equivalent direct commands, and
[RUNBOOK.md](RUNBOOK.md) for operations.

## Repository layout

```text
bootstrap/   Argo CD integration and four ordered bootstrap wrappers
gitops/      Component chart and environment values
workloads/   MongoDB, generated-secret publisher, OLM operator, and optional Grafana charts
scripts/     Read-only status/preflight plus Manage key backup
```
