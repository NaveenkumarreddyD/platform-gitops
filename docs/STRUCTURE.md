# platform-gitops — structure (start here)

Convention: the `gitlab-argocd-starter` pattern — Helm chart per area, `<env>-values.yaml`
per environment, classic **app-of-apps**. Environments are clusters: `nroc4` (non-prod),
`roc4` (prod), `drroc4` (DR).

```
app-of-apps/      ROOT chart. Apply ONCE per cluster. Makes AppProject + repo Secret +
                  the gitops-<env> Application. Per-env files: <env>-values.yaml.
gitops/           GENERATOR. Renders every Argo Application for one env (hub singletons +
                  per-instance workloads). Values layered: common -> <env>-common -> <env>.
post-deployment/  Workload charts the gitops Apps point at:
  operators/        OLM install (namespace/operator-group/subscription) — Mongo operator
  mongodb/          dedicated MongoDBCommunity CR + secrets + cert-manager CA
  jdbc/             external (non-SSL) Oracle JdbcCfg
  vault-sync/       registration-sync Jobs (mongo gate + SLS/DRO -> Vault)
  grafana/          Grafana (operator v5) + Thanos datasource + MAS dashboards
bootstrap/        00-prereqs/ + apply.sh (per-cluster bootstrap)
scripts/          load-secrets.sh, setup-vault-auth.sh wrapper, deploy-instance.sh ...
vault-auth/       Vault policies + setup-vault-auth.sh
```

## Flow (app-of-apps)
```
bootstrap/apply.sh <env>
   -> app-of-apps  creates AppProject "mas" + Application gitops-<env>
gitops-<env>
   -> gitops/ renders Applications, sync-wave ordered:
      -10 AVP | 10 Vault | 20 Mongo operator | 25 Mongo CR | 28 mongo->Vault (gate)
      30 account-root (Core/Manage) | 40 JDBC | 50 SLS/DRO sync
account-root -> discovers all MAS instances from mas-config-repo
```

## Add a new cluster/env
1. `gitops/`: add `<env>-common-values.yaml` (clusterId, vault.host) + `<env>-values.yaml` (instanceId, mongo ns, ...).
2. `app-of-apps/`: add `<env>-values.yaml` (just `envName: <env>`).
3. `post-deployment/operators/`: add `<env>-values.yaml` (usually empty).
4. `mas-config-repo`: add `envs/<cluster>.env` + `render.py <cluster>`.
5. `bootstrap/apply.sh <env>` on that cluster. No template edits.

## Per-env values live in ONE place
The instance specifics (clusterId, instanceId, Mongo ns/version, JDBC SSL, DRO ns) are set in
`gitops/<env>-*` and passed inline to the workload charts by the generator — so you don't
duplicate them across post-deployment charts.
