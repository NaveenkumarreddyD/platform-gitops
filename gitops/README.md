# Component chart

This chart renders **independent** Argo CD Applications — one component per render, selected by
`--set component=<name>`. There is no app-of-apps parent and no `installStage`: the bootstrap
scripts (`bootstrap/10-vault.sh`, `20-mongodb.sh`, `30-mas.sh`) each render and apply one
component. Components couple only through Vault secret paths.

```text
templates/validate.yaml           render-time guards (valid component, identity set, patched IBM branch)
templates/operators/              OLM operators (cert-manager, grafana-op) — component: operators (wave 5)
templates/secrets-vault/          Vault service              — component: vault    (wave 10)
templates/database-mongodb/       namespace, SCC, operator, MongoDB — component: mongodb (waves 19/20/25)
templates/mas-foundation/         IBM MAS account root       — component: mas      (wave 30)
templates/grafana/                optional Grafana instance  — component: grafana  (wave 60)
```

The `operators` component renders the reusable `workloads/operators` chart (Namespace +
OperatorGroup + Subscription per operator) with the list built from `certManagerOperator` +
(when `enable.grafana`) `grafanaOperator` in `gitops/values.yaml`. Add operators there.

`component` values: `operators`, `vault`, `mongodb`, `mas`, `grafana`, or `all` (renders everything, for a
single-shot). Within a component, ordering is driven solely by the `argocd.argoproj.io/sync-wave`
annotation — never by file or directory names; the number prefix on each file just mirrors its wave.

Ordering *between* components is enforced by the bootstrap scripts (each asserts its prerequisite),
not by this chart. Grafana is the sole optional switch (`enable.grafana`).
