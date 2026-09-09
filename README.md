# IBM MAS platform GitOps

This repository installs IBM Maximo Application Suite on OpenShift with Argo CD and
AWS Secrets Manager. It uses the IBM MAS GitOps `8.5.0` release from the internal fork
`https://gitlab.lac1.biz/gitops/ibm-mas-gitops.git` (revision `8.5.0-jdbc-patch`) — stock
upstream except that the JDBC config chart's `sslEnabled` is made configurable
(`jdbc_ssl_enabled`) so a non-SSL database can be used.

## Design

- `platform-gitops`: Argo CD bootstrap, cert-manager, MongoDB, and the IBM account root.
- `mas-gitops-config`: environment-specific IBM chart values and secret references.
- IBM's repository: consumed from the internal GitLab fork at the pinned revision (see above) —
  NOT the public GitHub release; the fork carries the one `jdbc_ssl_enabled` patch.
- AWS Secrets Manager: stores deployment secrets under `<account>/<cluster>/...`.
- AWS authentication: the Argo CD repo-server and publisher authenticate with a **static
  AWS access key** read from a Kubernetes Secret (`aws-static-credentials`) via plain
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION` environment variables. This is
  the simple bootstrap approach; it keeps a long-lived key in the cluster, so the keys must
  be least-privileged and rotated. See [INSTALL.md](INSTALL.md) for the security note.
- SLS/DRO publisher: IBM's native `postsync-update-sm` jobs write the generated SLS and DRO
  registration into AWS Secrets Manager, using a separate, write-scoped static key
  (`aws-static-credentials-publisher`).

The `argocd-vault-plugin` executable remains because that is the upstream plugin name used
by IBM's charts. Its configured backend is `awssecretsmanager` (`AVP_TYPE=awssecretsmanager`);
no HashiCorp service, policy, token, or storage is part of this design.

## Install order

```text
00-prereqs -> 05-operators -> 20-mongodb -> 30-mas
```

The scripts are small, idempotent command wrappers. Argo CD and the IBM charts perform the
deployment. Use [INSTALL.md](INSTALL.md) for the end-to-end procedure,
[RUNBOOK.md](RUNBOOK.md) for day-2 operations, and [UNINSTALL.md](UNINSTALL.md) for teardown.

## Repository layout

```text
bootstrap/     Argo CD integration and four ordered install wrappers (00→05→20→30)
argocd-apps/   The Argo CD "Application" definitions (app-of-apps) + per-cluster settings
charts/        The Helm charts those Applications deploy (MongoDB, OLM operators, Grafana)
scripts/       Read-only status/preflight, secret seeding, and teardown (day-2 tools)
```

`argocd-apps/` holds the *pointers* (Argo CD Applications) and `charts/` holds the
*payloads* (the charts they install) — the standard Argo CD "app-of-apps" split. See
[STRUCTURE.md](STRUCTURE.md) for the full map.
