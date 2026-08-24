# Platform component chart

This chart renders independent Argo CD Applications selected with
`--set component=<name>`.

| Component | Purpose |
|---|---|
| `operators` | cert-manager and optional platform operators |
| `mongodb-operator` | MongoDB Kubernetes operator |
| `mongodb-instance` | dedicated MAS MongoDB instance |
| `mas` | official IBM MAS account root and automatic SLS/DRO secret publisher |
| `grafana` | optional Grafana instance |
| `all` | render validation and CI convenience |

There is no install-stage switch and no parent app-of-apps in this chart. The bootstrap
wrappers enforce the few cross-component readiness gates. After the `mas` component is
applied, IBM's official `8.4.2` account root owns the MAS cluster and instance
application tree.

The SLS/DRO publisher uses a separate IAM Roles Anywhere write role to copy generated
registration values into AWS Secrets Manager. IBM's static-key write-back Jobs remain
disabled; publishing is automatic and does not require an operator command.

All IBM applications use the `aws-secrets-manager-helm` Argo CD plugin configuration.
Secret placeholders are resolved from AWS Secrets Manager under
`mas/<account>/<cluster>/...`.
