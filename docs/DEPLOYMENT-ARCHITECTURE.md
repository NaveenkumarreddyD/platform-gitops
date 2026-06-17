# MAS GitOps — Proper Deployment Structure (root-cause analysis + target design)

This documents *why* we hit the issues we hit, what the official IBM model does differently, and the
concrete changes to make the deployment self-orchestrating so they don't recur.

## TL;DR

Every recurring problem traces to **one root cause**: our repo replaced ArgoCD's **declarative,
hands-off orchestration** with **bastion-driven imperative scripts + manual sync gates**. That
created timing windows (CA drift), parked sync operations, generation lag, and stale-code risk.
The official IBM GitOps model is fully declarative — push config + secrets, and ArgoCD does the
rest via ApplicationSet generators, automated sync, custom-resource healthchecks, and **in-cluster
resource hooks** that harvest runtime registration at exactly the right moment. Aligning to that
model structurally eliminates the whole class of problems.

---

## What the official model relies on (and why it doesn't have our problems)

Per the [Orchestration](https://ibm-mas.github.io/gitops/main/orchestration/) and
[Timings](https://ibm-mas.github.io/gitops/main/timings/) docs, the official flow uses **five**
mechanisms together. We adopted some and worked around others — that gap is the bug.

| Mechanism | What it does | Did we have it? |
|---|---|---|
| **ApplicationSet git generators** | auto-generate the app hierarchy from the config repo on a ~3-min poll | yes (from IBM account-root) — but we **interrupt it with manual syncs** |
| **Automated sync policies** (`selfHeal`+`prune`) | every generated app syncs itself; no human `oc patch sync` | **no** — we set `autoSync:false` and drive syncs by hand |
| **Custom resource healthchecks** | ArgoCD knows real CR health, so sync waves actually gate | **added during this work** ✓ |
| **Sync waves** | ordering within each app | yes ✓ |
| **Resource hooks** (PreSync/PostSync/PostDelete) | run Jobs **in-cluster** at the right wave — incl. harvesting runtime registration into the secrets store | **no** — we replaced PostSync harvest with bastion scripts run at the wrong time |

The thing that prevents CA drift in the official model: the **PostSync harvest hooks**
(`07-postsync-update-sm` for SLS, `14-postsync-update-sm` for DRO) run *inside the cluster, as part
of the sync wave* — **after** the component (SLS/DRO) is healthy and **before** its consumer
(SLSCfg/BASCfg) syncs. So the registration key + CA are always current and present the moment the
consumer renders. There is no "harvest from a laptop at the right time" — the wave guarantees it.

---

## Issue-by-issue: root cause → official approach → fix

| Problem we hit | Our root cause | Official approach | Fix to align |
|---|---|---|---|
| SLS / DRO / Mongo `CERTIFICATE_VERIFY_FAILED` (CA drift) | bastion harvest ran **before** the consumer existed, or against a regenerated CA | PostSync **hook Job** harvests in-cluster, wave-timed, every sync | move harvest into PostSync hooks (write to Vault); stabilize CAs |
| Suite route-cert `NoneType` (empty cert) | cert not in Vault before the Suite reconciled | cert is a normal AVP-rendered secret, present before suite wave | load cert to Vault before account-root (✓ already enforced) |
| cert "type immutable" clash | `mas-certs` used `kubernetes.io/tls`, suite uses `Opaque` | suite owns the cert secret as `Opaque` | `mas-certs` now renders `Opaque` (✓) |
| DRO blocked whole cascade | `MarketplaceConfig` healthcheck gated on a CR that can't go healthy without RHM | RHM is registered in IBM's env; check passes | removed that healthcheck (✓); DRO uses IBM entitlement |
| 3-hour **parked** instance/root syncs | a **manual** sync is wave-gated and waits forever on a `Missing` manual-gate child | every app **auto-syncs**; no human op to park | enable automated sync; stop manual `oc patch sync` |
| generation lag / manual nudges | we sync the wrong parent (`account-root`) and interrupt the appset | appset git generator auto-creates apps on poll | let the cascade run; if nudging, nudge the **instance** app |
| stale bastion code (recurring) | bastion clone drifts from GitLab | pure GitOps — almost no bastion scripts | minimize bastion scripts; guard clone freshness |
| staged-installer complexity | imperative `stage.sh`/`mas-prep`/`mas-install` orchestration | declarative + hooks; no orchestrator | demote scripts to troubleshooting-only |

---

## Target architecture (official-aligned)

**Manual steps — only three, all one-time / declarative:**
1. **Bootstrap** (once per cluster): `apply.sh` → Vault, AVP sidecar, **CR healthchecks**, app-of-apps root.
2. **Seed Vault** (once): static secrets + **public cert** (manual cert mgmt) into Vault.
3. **Push config** to the config repo. Done. ArgoCD takes over.

**Everything after that is ArgoCD, not the bastion:**
- ApplicationSet generators create cluster → instance → suite/config apps.
- All apps have **automated sync** (`selfHeal: true, prune: true`).
- **CR healthchecks** make each sync wave wait for real readiness.
- **PostSync hook Jobs** harvest SLS/DRO registration (+ Mongo CA) into Vault **in-cluster**, wave-timed, so consumers always render with current trust material.
- **PostDelete hooks** clean up on teardown.

No `stage.sh`, no `mas-prep`/`mas-install`, no `enable-*`, no manual `oc patch sync` on the happy path.

---

## Migration plan (prioritized, incremental — each step is safe on its own)

1. **Enable automated sync on the gated apps.** Flip `accountRoot.autoSync` and `registrationSync.autoSync` to `true` (and remove the manual-gate annotations from `app-30/40/50`). This alone kills the *parked-sync* and *manual-nudge* classes — ArgoCD self-syncs the cascade. (Keep healthchecks so ordering still holds.)

2. **Move runtime harvest into in-cluster PostSync hooks.** Convert `workloads/vault-sync` Jobs into ArgoCD `PostSync` hooks attached to the SLS and DRO apps (annotation `argocd.argoproj.io/hook: PostSync`), gated on the component's readiness, writing to Vault. This removes the bastion-timed harvest entirely → no CA-drift-by-timing, no "harvest then refresh" dance. The served-CA fallback we added stays inside the hook for robustness.

3. **Stabilize the internal CAs.** Make the Mongo cert-manager CA (and optionally SLS via `internal_certificate_authority`) **persistent across teardown** (don't delete the CA secret/PVC on reinstall). Stable CA = cm `ca` always matches the served cert = the served-CA fallback essentially never fires.

4. **Render configs unconditionally; gate by hooks, not env flags.** Drop the `ENABLE_SLS_CONFIG`/`ENABLE_BAS_CONFIG` `BEGIN_OPTIONAL_*` staging. The PreSync/PostSync hooks + healthchecks already enforce ordering, so the SLSCfg/BASCfg can always render and simply wait for their dependencies (the official pattern).

5. **Reduce bastion scripts + guard freshness.** Keep only `bootstrap`, `setup-vault-*`, `load-secrets`, `load-mas-public-cert`. Add a one-line guard that refuses to run if the clone is behind `origin/main` (kills the stale-code trap). Move `stage.sh`/`mas-prep`/`mas-install`/`reconcile-*` under a `troubleshooting/` folder.

6. **DRO via IBM entitlement, RHM-free** (already the case): `GITOPS_OWNS_DRO=true`, entitlement in Vault auto-renders `redhat-marketplace-pull-secret`, MarketplaceConfig healthcheck omitted.

---

## Honest assessment

The current (post-fixes) repo **works** — you've reached a healthy Suite + BAS through it. But it's
*semi-imperative*: it needs operator discipline (current code, terminate stuck syncs, run scripts
in order). The issues you hit are the friction of fighting ArgoCD's declarative model with manual
steps.

- **Want minimal change?** Keep today's model; just hold the discipline (pull before run; terminate
  parked syncs; the healthchecks + served-CA fallbacks now self-heal most drift).
- **Want it to truly not recur?** Do steps 1–3 of the migration. Step 1 (automated sync) removes the
  parked-sync/manual-nudge pain with the least effort; step 2 (PostSync harvest hooks) removes the
  CA-drift-by-timing class; step 3 (stable CAs) removes the residual drift. That converges on the
  official hands-off model.

Sources: [Orchestration](https://ibm-mas.github.io/gitops/main/orchestration/),
[Timings](https://ibm-mas.github.io/gitops/main/timings/),
[Config Repository](https://ibm-mas.github.io/gitops/main/configrepo/),
[The Secrets Vault](https://ibm-mas.github.io/gitops/main/secrets/),
ibm-mas/gitops `100-ibm-sls` & `030-ibm-dro` postsync jobs.
