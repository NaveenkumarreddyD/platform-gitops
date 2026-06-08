# platform-gitops — structure

Three tiers, one job each:

```
bootstrap/    DAY-0 seed (imperative, once per cluster) — the ONLY manual step. 00-prereqs/ =
              GitLab CA, Argo RBAC, `mas` AppProject, repo creds, AND all AVP enablement (CMP
              plugin, Vault creds, token-review RBAC). apply.sh applies those, patches the
              repo-server with the AVP sidecar, then seeds the gitops root. ArgoCD owns the rest.
gitops/       THE GENERATOR (self-healing). Emits the self-managing root Application + all
              workload Applications, sync-wave ordered. Edit <env>-*.yaml here to change what
              deploys; ArgoCD reconciles. Values layered: common -> <env>-common -> <env>.
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
  -> helm template gitops | oc apply   (seeds the root Application "platform-<env>")
platform-<env>  (now ArgoCD-managed, self-heals)
  -> renders gitops/ -> emits all workload Applications, sync-wave ordered:
     -20 root | -10 AVP | 10 Vault | 20 Mongo operator(Helm) | 25 Mongo CR | 28 mongo->Vault gate
     30 account-root (Core/Manage) | 40 JDBC | 50 SLS/DRO sync | 55 grafana-operator | 60 Grafana
```

## Add a cluster/env
1. `gitops/`: add `<env>-common-values.yaml` (clusterId, vault.host) + `<env>-values.yaml` (instanceId, mongo ns, ...).
2. `workloads/operators` + `workloads/grafana`: add `<env>-values.yaml` (usually just overrides).
3. `mas-config-repo`: add `envs/<cluster>.env` + `render.py <cluster>`.
4. `./bootstrap/apply.sh <env>` on that cluster. No template edits.
