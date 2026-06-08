# platform-gitops — structure

Three tiers, one job each:

```
bootstrap/    DAY-0 bootstrap (imperative, once per cluster) — the ONLY manual step. 00-prereqs/ =
              GitLab CA, Argo RBAC, `mas` AppProject, repo creds, AND all AVP enablement (CMP
              plugin, Vault creds, token-review RBAC). apply.sh applies those, patches the
              repo-server with the AVP sidecar, then applies the gitops root. ArgoCD owns the rest.
gitops/       APP-OF-APPS GENERATOR (self-healing). One file per Application:
                templates/root-application.yaml   the app-of-apps root (apply.sh applies ONLY this)
                templates/app-10-vault.yaml ... app-60-grafana.yaml   the 9 children (wave-ordered)
              The root app points at path: gitops, so ArgoCD renders this chart -> generates the 9
              children (and re-renders the root app = self-managing). Edit <env>-*.yaml to change what
              deploys; ArgoCD reconciles. Values: values.yaml (shared base, auto-loaded) +
                envs/<cluster>/common.yaml (cluster-scope) + envs/<cluster>/values.yaml (instance).
              One folder per cluster under envs/ — scales cleanly; no flat sprawl.
workloads/    The actual Helm charts the Applications point at:
  operators/    grafana-operator (OLM, pinned v5.21.2 for OCP < 4.19)
  mongodb/      MongoDBCommunity CR (3x, 6.0.12, 20Gi+20Gi, TLS+SCRAM)  [operator via Helm chart]
  jdbc/         external Oracle JdbcCfg
  vault-sync/   registration-sync Jobs (mongo gate + SLS/DRO -> Vault)
  grafana/      Grafana CR + Thanos datasource + dashboards
scripts/, vault-auth/, docs/
```

## Flow
```
bootstrap/apply.sh <env>
  -> 00-prereqs (AppProject + creds + CA + RBAC)
  -> helm template gitops --set rootOnly=true | oc apply   (applies ONLY the root app)
platform-<env>  (now ArgoCD-managed, self-heals)
  -> renders gitops/ -> GENERATES all 9 child Applications, sync-wave ordered:
     -20 root | -10 AVP | 10 Vault | 19 Mongo SCC prereq | 20 Mongo operator(Helm) | 25 Mongo CR | 28 mongo->Vault gate
     30 account-root (manual gate for Core/Manage) | 40 JDBC | 50 SLS/DRO sync (manual after SLS exists) | 55 grafana-operator | 60 Grafana
```

`ibm-mas-account-root` is intentionally generated without an automated sync policy by default.
Sync it manually only after Vault is initialized, MongoDB is Running, and the Vault preflight for
entitlement, license, Mongo credentials/CA, and JDBC passes.
`vault-registration-sync-<instance>` is also manual by default so its SLS/DRO PostSync jobs do not
time out before account-root creates SLS.

## Add a cluster/env
1. `gitops/envs/<cluster>/`: copy `envs/_example/` -> `common.yaml` (clusterId, storageClass, vault.host) + `values.yaml` (instanceId, mongo ns, jdbc, dro, sls).
2. (operators + grafana need NOTHING per-cluster — they render from their own values.yaml.)
3. `mas-config-repo`: add `envs/<cluster>.env` + `render.py <cluster>`.
4. `./bootstrap/apply.sh <env>` on that cluster. No template edits.
