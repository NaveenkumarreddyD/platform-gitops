#!/usr/bin/env bash
set -euo pipefail
# Production wrapper: run all safe prerequisite phases and stop before MAS account-root.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

DEPLOY_ARGS=()
ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|--no-push) DEPLOY_ARGS+=("$1"); shift ;;
    -h|--help)
      echo "usage: install-gated.sh [--yes] [--no-push] <path/to/cluster.env>"
      exit 0
      ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
[[ -n "$ENVFILE" ]] || { echo "usage: install-gated.sh [--yes] [--no-push] <path/to/cluster.env>" >&2; exit 2; }

echo "=== 1/4 Environment validation ==="
./scripts/check-env.sh "$ENVFILE"

echo "=== 2/4 Vault auth, static secrets, render config ==="
./scripts/deploy.sh "${DEPLOY_ARGS[@]}" "$ENVFILE"

echo "=== 3/4 Mongo prerequisites and full Vault preflight ==="
./scripts/prepare-prereqs.sh "$ENVFILE"

echo "=== 4/4 Status summary ==="
./scripts/status-summary.sh "$ENVFILE"

cat <<MSG

============================================================
Prerequisites are ready and MAS account-root is still gated.

Start IBM MAS/Core/SLS/Manage with:
    ./scripts/sync-mas-account-root.sh $ENVFILE

After SLS initializes, publish runtime registration with:
    ./scripts/sync-runtime-registration.sh $ENVFILE
============================================================
MSG
