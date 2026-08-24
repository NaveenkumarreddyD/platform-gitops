# IBM MAS platform GitOps

This repository installs IBM Maximo Application Suite on OpenShift with Argo CD and
AWS Secrets Manager. It uses the unmodified IBM MAS GitOps release `8.4.2` from
`https://github.com/ibm-mas/gitops.git`.

## Design

- `platform-gitops`: Argo CD bootstrap, cert-manager, MongoDB, and the IBM account root.
- `mas-gitops-config`: environment-specific IBM chart values and secret references.
- IBM's repository: consumed directly from the official GitHub URL at the pinned tag.
- AWS Secrets Manager: stores deployment secrets under `mas/<account>/<cluster>/...`.
- One Identity Safeguard A2A: an AWS `credential_process` fetches the AWS secret access key
  from Safeguard's Application-to-Application API over mutual TLS, so the Argo CD repo-server
  and publisher get AWS credentials without any AWS secret stored in an OpenShift Secret.
  The long-lived AWS access key lives and rotates inside Safeguard.
- Generated-secret publisher: automatically copies SLS and DRO registration into AWS
  Secrets Manager with a separate, write-only Safeguard A2A identity and IAM user.

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
