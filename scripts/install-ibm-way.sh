#!/usr/bin/env bash
set -euo pipefail
# IBM-aligned staged install — now a thin wrapper over scripts/stage.sh.
#
# The install is broken into named, idempotent stages (preflight -> apply -> verify),
# each independently re-runnable. This wrapper runs them all in order, resuming from
# the checkpoint if a previous run stopped. To run or re-run a single stage:
#
#   ./scripts/stage.sh --list
#   ./scripts/stage.sh --only sls <env>
#   ./scripts/stage.sh --from mongo-verify <env>
#
# Order: preflight -> vault -> cert -> mongo -> account-root -> mongo-verify
#        -> sls -> jdbc -> bas -> suite -> manage -> verify
#
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

YES_ARGS=(); ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES_ARGS+=(--yes); shift ;;
    --force) YES_ARGS+=(--force); shift ;;
    -h|--help) echo "usage: install-ibm-way.sh [--yes] [--force] <path/to/cluster.env>"; exit 0 ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: install-ibm-way.sh [--yes] [--force] <path/to/cluster.env>}"

exec ./scripts/stage.sh --all "${YES_ARGS[@]}" "$ENVFILE"
