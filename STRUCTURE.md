# Repository structure — what lives where

This repo installs IBM MAS on OpenShift with Argo CD. If you know nothing about Argo CD,
read the mental model first, then use the "where do I change X?" table.

## Mental model (one paragraph)

Scripts in `bootstrap/` turn things on **in order**. Each script runs Helm on the chart in
`argocd-apps/`, which produces small **Argo CD `Application` objects** — these are *pointers*
that tell Argo CD "deploy this chart into this namespace and keep it in sync." The charts they
point at (the real MongoDB / operators / Grafana YAML) live in `charts/`. IBM's MAS chart is the
exception — it lives in IBM's own Git repo, so for MAS there is only a pointer here. Secret
values never live in Git; they live in **AWS Secrets Manager** and are pulled in at sync time.

```
bootstrap/*.sh  ──runs Helm on──▶  argocd-apps/  ──emits──▶  Argo CD Applications
                                                                   │ point at
                                        ┌──────────────────────────┼───────────────────────┐
                                        ▼                          ▼                       ▼
                                   charts/mongodb            charts/operators        IBM's MAS repo
                                   charts/grafana                                    (pulled by Argo)
```

`argocd-apps/` = the **remote control** (pointers). `charts/` = the **TVs** (payloads).

## Folder map

```
platform-gitops/
├── bootstrap/            You run these. 4 ordered install scripts + shared engine.
│   ├── 00-prereqs.sh       wire Argo CD to AWS Secrets Manager (no MAS yet)
│   ├── 05-operators.sh     install cert-manager (+ grafana operator if enabled)
│   ├── 20-mongodb.sh       install MongoDB (operator, then the database)
│   ├── 30-mas.sh           deploy IBM MAS (fans out into the whole MAS tree)
│   ├── lib-bootstrap.sh    shared functions all 4 scripts use (env lookup, waits, guards)
│   ├── 00-prereqs/         the YAML that 00-prereqs.sh applies (Argo project, RBAC, AVP plugin)
│   └── argocd-cr-*.yaml     patches that add the AWS-secrets sidecar + MAS health checks to Argo CD
│
├── argocd-apps/         The Argo CD Application definitions + per-cluster settings (a Helm chart).
│   ├── values.yaml         GLOBAL defaults for every cluster (version pins, image shas, toggles)
│   ├── envs/<cluster>/      PER-CLUSTER overrides:
│   │   ├── common.yaml        identity + the 3 repo URLs & branches (account, clusterId, repos)
│   │   └── values.yaml        instance settings (instanceId, mongo size, grafana on/off)
│   └── templates/          the Application objects, numbered by install order:
│       ├── operators/05-operators.yaml               → deploys charts/operators
│       ├── database-mongodb/19,20,25-*.yaml           → deploys charts/mongodb (prereqs, operator, DB)
│       ├── mas-foundation/30-ibm-mas-account-root.yaml → the IBM MAS pointer (payload = IBM's repo)
│       ├── grafana/60-grafana.yaml                    → deploys charts/grafana (optional)
│       ├── _helpers.tpl     builds the bare secret path <account>/<cluster>/<instance>
│       └── validate.yaml    fails the render early if a required value is missing
│
├── charts/              The Helm charts THIS repo owns (the payloads Argo CD deploys).
│   ├── mongodb/            the real MongoDB: CA, SCC, admin secret, MongoDBCommunity, CA-publish job
│   ├── operators/          installs an OLM operator by Subscription (used for cert-manager, grafana)
│   └── grafana/            optional dashboards
│
├── scripts/             Day-2 tools you run by hand.
│   ├── seed-aws-secrets.sh       create/update all AWS SM secrets for an instance
│   ├── status.sh <env>          read-only health summary
│   ├── preflight-consistency.sh read-only cross-repo id/version/path check
│   ├── capture-manage-crypto.sh save Manage encryption keys (reused-DB installs)
│   └── teardown-cluster.sh      ordered, safe uninstall of one instance
│
└── *.md                 README (overview), INSTALL (end-to-end), RUNBOOK (day-2), UNINSTALL, this file.
```

## "I want to change X — where do I touch it?"

| I want to… | Edit here | Then |
|---|---|---|
| Change a **version pin / image / global toggle** | `argocd-apps/values.yaml` | commit, push, sync |
| Change a **per-cluster value** (instanceId, mongo size, grafana on/off) | `argocd-apps/envs/<cluster>/values.yaml` | commit, push, sync |
| Change a cluster's **identity or repo branch** | `argocd-apps/envs/<cluster>/common.yaml` | commit, push, sync |
| Add a **new cluster** | copy `argocd-apps/envs/_example/` → `argocd-apps/envs/<new>/`, edit both files | run bootstrap `00→30` |
| Change **how MongoDB itself is built** | `charts/mongodb/` | commit, push, sync |
| Change **whether/where an Application deploys** | its file in `argocd-apps/templates/…` | commit, push, sync |
| Change a **secret value** (password, TLS, entitlement) | AWS Secrets Manager (re-run `scripts/seed-aws-secrets.sh`) | hard-refresh the app (see RUNBOOK) |
| Change **MAS app config** (SLS/DRO/Manage/JDBC) | the **`mas-gitops-config`** repo, not here | render + push there |

Rule of thumb: **`argocd-apps/`** = *whether/where/which version* something deploys.
**`charts/`** = *how* the thing we own is actually built. **AWS Secrets Manager** = secret *values*.

## When something breaks

1. `./scripts/status.sh <cluster>` — one-screen health of Argo apps, AWS, Mongo, MAS.
2. `oc get applications -n openshift-gitops` — which Argo app is not Synced/Healthy.
3. Then open [RUNBOOK.md](RUNBOOK.md) and jump to the section matching the symptom.

Common first check: an app is *Synced* but nothing was created → Argo rendered nothing because
the AWS-secrets plugin couldn't resolve a `<path:...>` — look at the repo-server `avp-helm` logs
(RUNBOOK → "AWS secret substitution fails").
