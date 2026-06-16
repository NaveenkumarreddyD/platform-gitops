#!/usr/bin/env bash
set -euo pipefail
# All-in-one MAS install = mas-prep.sh + mas-install.sh, back to back.
# Prefer running the two parts separately so you can checkpoint in between:
#   ./scripts/mas-prep.sh    --yes <env>   # secrets + config + cert + Mongo + account-root
#   (check Suite exists + SystemDatabaseReady=True)
#   ./scripts/mas-install.sh --yes <env>   # SLS + JDBC + (DRO/BAS) + Suite + Manage
#
# Run after Vault is up (setup-vault-platform.sh + setup-vault-auth.sh).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

YES_ARGS=(); ENVFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES_ARGS+=(--yes); shift ;;
    -h|--help) echo "usage: install-ibm-way.sh [--yes] <path/to/cluster.env>"; exit 0 ;;
    *) ENVFILE="$1"; shift ;;
  esac
done
ENVFILE="${ENVFILE:?usage: install-ibm-way.sh [--yes] <path/to/cluster.env>}"

./scripts/mas-prep.sh    "${YES_ARGS[@]}" "$ENVFILE"
./scripts/mas-install.sh "${YES_ARGS[@]}" "$ENVFILE"
