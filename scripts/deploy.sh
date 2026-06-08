#!/usr/bin/env bash
set -euo pipefail
# One-command post-Vault deploy: configure Vault auth -> load secrets -> preflight -> render config -> commit/push.
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
say "3/5 Preflight (CA WARNs are normal pre-sync)"; ./scripts/preflight-vault.sh "$ENVFILE" || true
say "4/5 Render config (shared-cluster files auto-skipped)"
( cd "$CONFIG_REPO" && python3 render.py "$CLUSTER" )
say "5/5 Commit + push config"
( cd "$CONFIG_REPO" && git add -A && git --no-pager diff --cached --stat )
read -r -p "Commit and push the above to the config repo? [y/N] " a
if [[ "$a" == y ]]; then
  ( cd "$CONFIG_REPO" && git commit -m "deploy: $CLUSTER" && git push )
  echo ">> pushed. account-root picks it up. Mongo/SLS/DRO CA registration is automated by the PostSync Jobs."
else
  echo ">> skipped push. Review, then commit/push manually."
fi
