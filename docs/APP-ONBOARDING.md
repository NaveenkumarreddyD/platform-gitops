# Adding Platform Applications

Use this checklist when adding another platform component to `platform-gitops`.

## Layout

Add Argo CD Application templates under:

```text
gitops/templates/apps/<wave>-<domain>/app-NN-name.yaml
```

Current domains:

```text
10-vault/          Vault server and auto-unseal
19-mongodb/        Mongo namespace, operator, and MongoDBCommunity CR
28-runtime-sync/   Mongo CA sync into Vault
30-mas/            IBM MAS account-root handoff
40-jdbc/           Locally owned MAS JDBC config
50-runtime-sync/   SLS/DRO runtime registrations into Vault
55-grafana/        Optional Grafana operator and CRs
```

Keep the root app in:

```text
gitops/templates/root/root-application.yaml
```

## Numbering

Use sync-wave numbers in the filename and `argocd.argoproj.io/sync-wave`.

Recommended ranges:

```text
10-18  shared platform services
19-29  prerequisites and runtime data needed before MAS
30-39  MAS account-root and MAS foundation gates
40-49  MAS config CRs that require MAS CRDs
50-59  runtime registration/sync jobs
60-69  optional observability/add-ons
```

Leave gaps between waves so later additions do not need renumbering.

The numeric directory prefix keeps Helm's render order aligned with Argo CD sync waves.

## Values

Put shared defaults in `gitops/values.yaml`.

Put cluster/instance overrides in:

```text
gitops/envs/<cluster>/common.yaml
gitops/envs/<cluster>/values.yaml
```

Add an `enable.<component>` flag for optional components. Default new optional components to
disabled unless they are required for a clean base install.

## Workload Chart

If the Application points at repo-local manifests, create a chart under:

```text
workloads/<component>/
```

Then set the Application source to `path: workloads/<component>`.

If the chart consumes Vault values, use the AVP plugin pattern and pass values through
`HELM_VALUES`. Keep the Vault path shape consistent with `gitops.path`.

## Manual Gates

Use manual sync when the component depends on CRDs, runtime-generated values, or external services.
Add a helper script in `scripts/` when the manual gate needs readiness checks before sync.

## Validation

Before pushing:

```bash
helm lint gitops -f gitops/envs/drroc4/common.yaml -f gitops/envs/drroc4/values.yaml
helm template platform gitops -f gitops/envs/drroc4/common.yaml -f gitops/envs/drroc4/values.yaml >/tmp/platform.yaml
bash -n scripts/*.sh
```
