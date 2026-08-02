#!/usr/bin/env bash
# capture-manage-crypto.sh <env> — make the MAS layer truly redeployable.
#
# WHY: with autoGenerateEncryptionKeys=true (the safe first-install default), MAS generates its
# Manage encryption keys into a Kubernetes Secret. If you later delete/rebuild the MAS namespace
# you LOSE those keys and can no longer decrypt the existing database. This script copies the
# generated keys into Vault (path manage-crypto) so they survive a MAS rebuild. After capturing,
# flip the env to autoGenerateEncryptionKeys=false and re-render — MAS then reads the keys from
# Vault on every (re)deploy and always reattaches to the same data.
#
# Run ONCE, after Manage is first Ready. Requires: export VAULT_ROOT_TOKEN=...
source "$(cd "$(dirname "$0")/../bootstrap" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"; require_cluster
: "${VAULT_ROOT_TOKEN:?export VAULT_ROOT_TOKEN before running}"
INSTANCE="$(env_instance)"
MANAGE_NS="mas-${INSTANCE}-manage"
VPATH="$(vault_path)/manage-crypto"

SEC="$(oc get secret -n "$MANAGE_NS" -o name 2>/dev/null | grep -E 'manage-encryptionsecret' | head -1)"
[[ -n "$SEC" ]] || { echo "ERROR: no *-manage-encryptionsecret in $MANAGE_NS — is Manage installed and Ready?" >&2; exit 1; }
echo ">> found $SEC in $MANAGE_NS; its data keys:"
oc get "$SEC" -n "$MANAGE_NS" -o go-template='{{range $k,$v := .data}}   {{$k}}{{"\n"}}{{end}}'

# The config template reads manage-crypto#cryptoKey and #cryptoxKey. Map the secret's fields with
# CRYPTO_KEY_FIELD / CRYPTOX_KEY_FIELD if the discovered names differ from these defaults.
CK_FIELD="${CRYPTO_KEY_FIELD:-MXE_SECURITY_CRYPTO_KEY}"
CX_FIELD="${CRYPTOX_KEY_FIELD:-MXE_SECURITY_CRYPTOX_KEY}"
ck="$(oc get "$SEC" -n "$MANAGE_NS" -o jsonpath="{.data.$CK_FIELD}" 2>/dev/null | base64 -d 2>/dev/null || true)"
cx="$(oc get "$SEC" -n "$MANAGE_NS" -o jsonpath="{.data.$CX_FIELD}" 2>/dev/null | base64 -d 2>/dev/null || true)"
[[ -n "$ck" && -n "$cx" ]] || { echo "ERROR: fields $CK_FIELD / $CX_FIELD not found — re-run with CRYPTO_KEY_FIELD=<name> CRYPTOX_KEY_FIELD=<name> from the list above." >&2; exit 1; }

echo ">> writing $VPATH (cryptoKey, cryptoxKey) to Vault"
vault_exec "$VAULT_ROOT_TOKEN" kv put "$VPATH" cryptoKey="$ck" cryptoxKey="$cx" >/dev/null
echo ">> done. Now set MANAGE_AUTO_GENERATE_ENCRYPTION_KEYS=false in the config env, re-render,"
echo "   commit + push. The MAS layer is now redeployable — it reads these keys from Vault."
