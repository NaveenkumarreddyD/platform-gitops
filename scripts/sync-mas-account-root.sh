#!/usr/bin/env bash
set -euo pipefail
# Final explicit gate: verify prerequisites and sync IBM MAS account-root using oc only.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"
ENVFILE="${1:?usage: sync-mas-account-root.sh <path/to/cluster.env>}"

echo ">> full Vault preflight before MAS account-root"
./scripts/preflight-vault.sh --phase full "$ENVFILE"

echo ">> syncing ibm-mas-account-root"
sync_app_oc ibm-mas-account-root false
wait_app_synced_idle ibm-mas-account-root 1800

echo ">> MAS account-root sync completed. It may remain Progressing until SLS/DRO registration and gated config apps finish."
echo ">> Next gated steps: scripts/sync-jdbc-config.sh, scripts/sync-runtime-registration.sh"
