# platform-gitops — structure

Three tiers, one job each:

```
bootstrap/    DAY-0 bootstrap (imperative, once per cluster) — the ONLY manual step. 00-prereqs/ =
              optional repo CA, Argo RBAC, `mas` AppProject, repo creds, AND all AVP enablement (CMP
              plugin, Vault creds, token-review RBAC). apply.sh applies those, patches the ArgoCD CR
              with (a) the AVP sidecar and (b) the MAS custom resource healthchecks
              (argocd-cr-healthchecks-patch.yaml — Suite/MongoCfg/SlsCfg/JdbcCfg/BasCfg/Manage/
              LicenseService/OLM/Db2u), then applies the gitops root. The healthchecks make Argo
              gate sync waves on REAL CR readiness instead of mere existence, so the platform
              self-orchestrates (the staged scripts then just drive + verify). ArgoCD owns the rest.
gitops/       APP-OF-APPS GENERATOR (self-healing). One file per Application:
                templates/root/root-application.yaml   the app-of-apps root (apply.sh applies ONLY this)
                templates/apps/<domain>/app-NN-*.yaml   children (wave-ordered by domain)
              The root app points at path: gitops, so ArgoCD renders this chart -> generates the
              children (and re-renders the root app = self-managing). Edit <env>-*.yaml to change what
              deploys; ArgoCD reconciles. Values: values.yaml (shared base, auto-loaded) +
                envs/<cluster>/common.yaml (cluster-scope) + envs/<cluster>/values.yaml (instance).
              One folder per cluster under envs/ — scales cleanly; no flat sprawl.
workloads/    The actual Helm charts the Applications point at:
  mongodb/      MongoDBCommunity CR (3x, 6.0.12, 20Gi+20Gi, TLS+SCRAM)  [operator via Helm chart]
  jdbc/         external Oracle JdbcCfg
  vault-sync/   registration-sync Jobs (mongo gate + SLS/DRO -> Vault)
  operators/    optional OLM operator installs; Grafana is disabled by default
  grafana/      optional Grafana CR + Thanos datasource + dashboards
scripts/, vault-auth/, docs/
```

## Flow
```
bootstrap/apply.sh <env>
  -> 00-prereqs (AppProject + creds + CA + RBAC)
  -> helm template gitops --set rootOnly=true | oc apply   (applies ONLY the root app)
platform-<env>  (now ArgoCD-managed, self-heals)
  -> renders gitops/ -> GENERATES wave-ordered child Applications:
     Vault, MongoDB, MAS account-root, JDBC, SLS, DRO/BAS, Manage, optional components.
```

Use `scripts/install-ibm-way.sh` as the production entrypoint. It renders config, refreshes
Argo CD parents until child Applications exist, then waits on real MAS CR readiness in IBM order:
MongoDB, SLS, JDBC, DRO/BAS, Suite Ready, and finally Manage.

## Add a cluster/env
1. `gitops/envs/<cluster>/`: copy `envs/_example/` -> `common.yaml` (clusterId, storageClass, vault.host) + `values.yaml` (instanceId, mongo ns, jdbc, dro, sls).
2. Optional components such as Grafana are controlled by `enable.*` values.
3. `mas-gitops-config`: add `envs/<cluster>.env` + `render.py <cluster>`.
4. `./bootstrap/apply.sh <env>` on that cluster, then run `scripts/install-ibm-way.sh --yes <envfile>`.
   No template edits.
