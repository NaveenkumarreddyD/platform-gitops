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
wait_app_synced_healthy ibm-mas-account-root 1800

echo ">> MAS account-root synced. Watch generated MAS Applications in $ARGO_NS."
