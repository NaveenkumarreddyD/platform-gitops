#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# deploy-cluster.sh — one command to bring up (or re-converge) a cluster once
# the platform (ArgoCD + Vault + AVP) is already bootstrapped on the hub.
#
# Per new cluster, the ONLY human inputs are:
#   1) envs/<cluster>.env   (the per-cluster values)
#   2) the secret material (exported in your shell, or a sourced secrets env)
# Everything below is automated.
#
# USAGE:
#   export VAULT_TOKEN=...                 # vault admin/root
#   ./deploy-cluster.sh <cluster> [--load] [--no-sync]
#     --load    : also run the rendered vault/<cluster>-load-secrets.sh
#                 (requires the secret env vars exported / sourced first)
#     --no-sync : render + preflight only, don't touch ArgoCD
#
# Assumes layout: render.py, envs/, vault/, scripts/ at repo root.
# ---------------------------------------------------------------------------
CLUSTER="${1:?usage: deploy-cluster.sh <cluster> [--load] [--no-sync]}"; shift || true
DO_LOAD=0; DO_SYNC=1
for a in "$@"; do case "$a" in --load) DO_LOAD=1;; --no-sync) DO_SYNC=0;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
NS_GITOPS="${NS_GITOPS:-openshift-gitops}"
ENVFILE="$HERE/envs/$CLUSTER.env"
[[ -f "$ENVFILE" ]] || { echo "no env file: $ENVFILE"; exit 1; }
set -a; . "$ENVFILE"; set +a
: "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }

step "1/6 render config from envs/$CLUSTER.env"
python3 "$HERE/render.py" "$CLUSTER"

if [[ "$DO_LOAD" == "1" ]]; then
  step "2/6 load secrets into Vault"
  "$HERE/vault/$CLUSTER_ID-load-secrets.sh"
else
  step "2/6 load secrets — SKIPPED (pass --load to run vault/$CLUSTER_ID-load-secrets.sh)"
fi

step "3/6 commit & push rendered config (manual confirm)"
echo "   git -C $HERE add mas/$CLUSTER_ID vault/$CLUSTER_ID-load-secrets.sh && git commit && git push"
echo "   (ArgoCD reads committed git state — uncommitted renders won't sync.)"

step "4/6 preflight Vault secrets"
if ! "$HERE/scripts/preflight-vault.sh" "$ENVFILE"; then
  echo "Preflight failed. For own-SLS the sls key WARN is expected until SLS is Ready."
  echo "Fix FAILs, then re-run. (Continuing to sync would just produce ComparisonErrors.)"
fi

[[ "$DO_SYNC" == "0" ]] && { echo; echo "Done (--no-sync)."; exit 0; }

step "5/6 ensure cluster is registered & account-root is synced"
echo "   (cluster registration is handled by platform-gitops; verify the target"
echo "    cluster Secret exists in $NS_GITOPS before first sync.)"
oc get application ibm-mas-account-root -n "$NS_GITOPS" >/dev/null 2>&1 \
  && oc annotate application ibm-mas-account-root -n "$NS_GITOPS" argocd.argoproj.io/refresh=hard --overwrite \
  || echo "   account-root app not found yet — sync it from the platform app-of-apps first."

step "6/6 status (sync bottom-up: configs -> suite -> workspace -> manage)"
oc get applications -n "$NS_GITOPS" -o json | jq -r \
  --arg c "$CLUSTER_ID" --arg i "$INSTANCE_ID" '
  .items[] | select(.metadata.name | test($c+"|"+$i))
  | "\(.metadata.name)\tsync=\(.status.sync.status // "-")\thealth=\(.status.health.status // "-")\t\([.status.conditions[]?.type] | join(","))"' \
  | sort | column -t -s$'\t'

cat <<EOF

Reminders specific to Vault (not in IBM's AWS flow):
  * After ANY Vault value change, ArgoCD's manifest cache is keyed by git
    revision, not Vault — restart the repo-server to force re-render:
       oc rollout restart deploy/openshift-gitops-repo-server -n $NS_GITOPS
    then hard-refresh the affected app.
  * Own-SLS: once LicenseService is Ready, run
       scripts/harvest-sls-registration.sh envs/$CLUSTER.env
    then sync ${INSTANCE_ID}-sls-system, then the suite.
EOF
