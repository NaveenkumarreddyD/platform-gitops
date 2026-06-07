#!/usr/bin/env bash
# Wrapper — the authoritative script lives in vault-auth/. Run with VAULT_TOKEN exported.
exec "$(cd "$(dirname "$0")" && pwd)/../vault-auth/setup-vault-auth.sh" "$@"
