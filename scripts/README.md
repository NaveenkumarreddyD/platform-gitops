# Scripts

`INSTALL.md` and `RUNBOOK.md` are the supported way to install and operate this
platform — plain `oc`, `helm`, and `vault` commands, with no orchestration/reconciliation
script. This mirrors the official IBM MAS GitOps model: Argo CD sync waves, CR health
checks, and in-chart PostSync jobs do the orchestration. The scripts below are read-only
checks, day-0 bootstrap, and teardown — not installers.

## Operational scripts (maintained)

| Script | Purpose |
|---|---|
| `preflight-consistency.sh <cluster>` | **Read-only.** Assert account/cluster/instance IDs match across platform-gitops and the config repo, and that `source.revision` is the Vault patch branch. Run before bootstrap (INSTALL.md §2). |
| `status.sh <env>` | **Read-only.** Whole-system dashboard: each component's Argo CD sync/health, Vault seal, MongoDB phase, MAS Suite/Manage, SLS/DRO harvest. Needs no Vault token. First stop when something is unhealthy. |
| `capture-manage-crypto.sh <env>` | One-time: copy Manage's generated encryption keys into Vault so the MAS layer becomes redeployable (then flip `MANAGE_AUTO_GENERATE_ENCRYPTION_KEYS=false`). Needs `VAULT_ROOT_TOKEN`. |
| `../bootstrap/00-prereqs.sh … 30-mas.sh <cluster>` | Decoupled component install (prereqs → vault → config → verify → mongodb → mas). Each asserts its prerequisite. See `bootstrap/README.md`. Not an installer/reconciler. |
| `delete-fast.sh` | Fast, complete teardown of one cluster/instance (dry-run without `--confirm`). Label-selects apps, pauses Argo CD durably, purges OLM, strips finalizers, restores Argo CD on exit. |
| `restore-gitops-controllers.sh` | Un-pause Argo CD controllers if a teardown was interrupted. |
| `lib-argocd-oc.sh` | Shared shell library used by `delete-fast.sh`. Not run directly. |

Manage attachments on PowerScale S3 are configured in the Manage **database** (the
`mxe.cos*` system properties, applied via the Manage UI/API) — see
`mas-config-repo/docs/manage-attachments-powerscale-s3.md`. They are not managed from
this repo, so no attachment scripts live here.

## Removed scripts

The old pre-stage orchestration scripts (script-driven install, in-cluster unseal-key
storage, custom harvest flow, Vault-auth setup helper) have been **deleted**: they
conflicted with the current security posture (operator-held unseal shares, never
in-cluster) and referenced applications that no longer exist. They remain available
in git history if ever needed. Vault Kubernetes-auth setup lives in `INSTALL.md` §5.
