# Bootstrap

These four scripts are small, idempotent wrappers around `oc` and `helm`:

```text
00-prereqs.sh <env>    Configure Argo CD and AWS Secrets Manager workload access
05-operators.sh <env>  Install/verify cert-manager and optional platform operators
20-mongodb.sh <env>    Install the compatible MongoDB operator and database
30-mas.sh <env>        Apply the IBM MAS account root and generated-secret publisher
```

Each step checks its prerequisites and stops with a useful error. Argo CD remains the
reconciler; the scripts do not implement a second deployment engine.

Before `00-prereqs`, create:

- `openshift-gitops/aws-secrets-manager-auth` ConfigMap
- `openshift-gitops/aws-rolesanywhere-avp` Secret
- `openshift-gitops/aws-secrets-manager-publisher-auth` ConfigMap
- `openshift-gitops/aws-rolesanywhere-publisher` Secret
- `openshift-gitops/gitlab-gitops-group-repo-creds` Secret

The complete procedure and direct-command alternative are in
`../INSTALL.md` and `../MANUAL-INSTALL.md`.
