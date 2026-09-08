# Migration: custom publisher → IBM native postsync-update-sm (SLS/DRO)

Branch: `codex/ibm-native-publisher` (this repo) + `codex/ibm-native-publisher` (mas-gitops-config).
Goal: delete the custom `aws-generated-secrets-publisher` Deployment and let IBM's built-in
`postsync-update-sm` Jobs publish the generated SLS/DRO secrets to AWS Secrets Manager.

**Status: STAGED / NOT yet functional end-to-end.** The clean half is done; three consumer-side
items need your values + a test before this branch works. Test on `drroc4` only.

---

## Done on this branch (platform-gitops)
- Removed `workloads/aws-generated-secrets-publisher/` (the custom Deployment chart).
- Removed `gitops/templates/mas-foundation/31-generated-secrets-publisher.yaml` (the Argo app).
- Trimmed `generatedSecretsPublisher` in `gitops/values.yaml` to only `image` + `identitySecret`
  (still used by the **MongoDB CA publish job**, `25-mongodb-instance.yaml` — do NOT delete those).
- `scripts/seed-aws-secrets.sh`: seeds `mas/<account>/<cluster>/publisher` when
  `PUBLISHER_AWS_ACCESS_KEY_ID` / `PUBLISHER_AWS_SECRET_ACCESS_KEY` are exported. (On `main`/live too.)

## To do in mas-gitops-config (branch `codex/ibm-native-publisher`)
1. **Enable IBM's jobs** in `base/cluster/ibm-dro.yaml.tpl` and `base/instance/ibm-sls.yaml.tpl`:
   - `run_sync_hooks: true`
   - feed the publisher key so the jobs can write to AWS:
     `sm.aws_access_key_id: "<path:mas/${ACCOUNT_ID}/${CLUSTER_ID}/publisher#aws_access_key_id>"`
     `sm.aws_secret_access_key: "<path:mas/${ACCOUNT_ID}/${CLUSTER_ID}/publisher#aws_secret_access_key>"`
     (AVP resolves the value before the chart b64-encodes it into a hidden Secret — stays out of Git.)
   - the SLS job also needs `application_admin_role: true` to render.
2. **Realign the consumer refs** in `base/instance/ibm-mas-suite-configs.yaml.tpl` to IBM's native
   SM layout (this is what IBM WRITES — see below).

## IBM native SM layout (what the jobs write) — the contract to read against
From `ibm-gitops` `cluster-applications/030-ibm-dro/templates/14-postsync-update-sm_Job.yaml`
and `sls-applications/100-ibm-sls/templates/08-postsync-update-sm_Job.yaml`:

| | Path | Fields |
|---|---|---|
| DRO | `${ACCOUNT_ID}/${CLUSTER_ID}/dro` | `dro_url`, `dro_api_token`, `dro_ca_b64enc`, `dro_client_tls_tls_crt_b64`, `dro_client_tls_tls_key_b64` |
| SLS | `${ACCOUNT_ID}/${ICN}/${SUBSCRIPTION_ID}/sls` | `sls_url`, `registration_key`, `ca_b64` |

Where the job env sets: `ACCOUNT_ID=account_id`, `CLUSTER_ID=cluster_id`,
`ICN=ibm_customer_number`, `SUBSCRIPTION_ID=subscription_id`.

## ⚠️ Three things to CONFIRM before this works
1. **CA is base64.** IBM stores `dro_ca_b64enc` / `ca_b64` (base64), but your BASCfg/SLSCfg today
   consume raw PEM (`ca.crt`). Verify the MAS config chart accepts the b64 field, or add a decode.
   **This is the main blocker — test it first.**
2. **SLS path is keyed on IBM entitlement IDs**, not the MAS instance: you must supply
   `ibm_customer_number` and `subscription_id` to the SLS chart, and read from
   `<path:${ACCOUNT_ID}/${ICN}/${SUBSCRIPTION_ID}/sls#...>`. These values are not in the env files yet.
3. **No `mas/` prefix.** IBM writes under `<account>/<cluster>/...` (no leading `mas/`). Either:
   - widen the AVP path regex in `bootstrap/argocd-cr-avp-sidecar-patch.yaml` (currently `^mas/…`), or
   - set the DRO/SLS chart value `account_id: "mas/${ACCOUNT_ID}"` so IBM writes `mas/<acct>/<cluster>/dro`
     and your existing prefix + regex are preserved (check `account_id` isn't reused for tags/labels).

## Test plan (drroc4)
1. Seed the publisher key: `export PUBLISHER_AWS_ACCESS_KEY_ID=… PUBLISHER_AWS_SECRET_ACCESS_KEY=…` then `./scripts/seed-aws-secrets.sh`.
2. Point a throwaway env/instance at these branches; sync DRO + SLS.
3. `oc get job -A | grep update-sm` → Completed. `aws secretsmanager get-secret-value --secret-id <acct>/<cluster>/dro` → token present.
4. Confirm MAS BASCfg/SLSCfg reach Ready reading the new refs (this proves the b64-CA question).
5. Only after that passes: roll to other envs and delete this note.

## Rollback
Revert both branches (custom publisher is intact on `static-keys` / `codex/aws-secrets-manager`).
