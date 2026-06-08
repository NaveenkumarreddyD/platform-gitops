#!/usr/bin/env bash
set -euo pipefail
# One-command post-Vault deploy: configure Vault auth -> load static secrets -> static preflight
# -> render config -> commit/push. It deliberately does NOT sync IBM MAS account-root.
# Usage:  export VAULT_TOKEN=<root> (+ IBM_ENTITLEMENT_KEY/MAS_LICENSE_FILE/JDBC_* for load)
#         ./scripts/deploy.sh ../mas-config-repo/envs/drroc4.env
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
ENVFILE="${1:?usage: deploy.sh <path/to/cluster.env>}"
CONFIG_REPO="${CONFIG_REPO:-$(cd "$(dirname "$ENVFILE")/.." && pwd)}"
CLUSTER="$(basename "$ENVFILE" .env)"
say(){ printf '\n=== %s ===\n' "$*"; }
[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first"; exit 1; }

say "1/5 Configure Vault auth (k8s auth + reader/writer roles; auto-detects repo-server SA)"
./scripts/setup-vault-auth.sh
say "2/5 Load secrets into Vault";  ./scripts/load-secrets.sh "$ENVFILE"
say "3/5 Static preflight (Mongo CA is deferred until MongoDB is Running)"
./scripts/preflight-vault.sh --phase static "$ENVFILE"
say "4/5 Render config (shared-cluster files auto-skipped)"
( cd "$CONFIG_REPO" && python3 render.py "$CLUSTER" )
say "5/5 Commit + push config"
set +e
(
  cd "$CONFIG_REPO"
  git add "mas/$CLUSTER"
  echo ">> Config repo: $CONFIG_REPO"
  echo ">> Staged rendered files only. Vault secret values are NOT committed; rendered files contain AVP <path:...> references."
  if git diff --cached --quiet; then
    echo ">> No rendered config changes to commit."
    exit 10
  fi
  git --no-pager diff --cached --stat
  echo
  git --no-pager diff --cached --name-status
)
rc=$?
set -e
if [[ "$rc" == "10" ]]; then
  echo ">> Nothing to push. Next: run ./scripts/prepare-prereqs.sh $ENVFILE"
  exit 0
fi
read -r -p "Commit and push ONLY the staged rendered MAS config above? [y/N] " a
if [[ "$a" == y ]]; then
  ( cd "$CONFIG_REPO" && git commit -m "deploy: $CLUSTER" && git push )
  echo ">> pushed. Next: run ./scripts/prepare-prereqs.sh $ENVFILE"
else
  echo ">> skipped push. Review with: cd $CONFIG_REPO && git diff --cached"
  echo ">> Commit/push manually if the rendered config is intended, then run ./scripts/prepare-prereqs.sh $ENVFILE"
fi
