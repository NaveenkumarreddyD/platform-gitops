#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# Patch-safe Vault key updater. Use this for ANY later single-value change
# (CA rotation, password change) instead of `vault kv put`.
#
# WHY: `vault kv put <path> k=v` REPLACES the entire secret version — any keys
# you don't pass are dropped. We lost sls-mongo username/password exactly this
# way during a CA update. `vault kv patch` updates only the named key.
#
# CA/PEM values are passed via @file so they store as REAL multiline PEM
# (never escaped \n, which renders as InvalidByte through toYaml).
#
# USAGE:
#   ./update-vault-ca.sh <kv-path> <field> <pem-file>      # CA / file value
#   ./update-vault-ca.sh <kv-path> <field> --literal <val> # plain string value
# Examples:
#   ./update-vault-ca.sh mas/drroc4/drgitopsapp/mongo ca.crt ./mongo-ca.pem
#   ./update-vault-ca.sh mas/drroc4/drgitopsapp/sls-mongo password --literal 's3cr3t'
# ---------------------------------------------------------------------------
PATH_KV="${1:?kv path e.g. mas/drroc4/drgitopsapp/mongo}"
FIELD="${2:?field e.g. ca.crt}"
MODE="${3:?pem-file OR --literal}"
VAULT_NS="${VAULT_NS:-vault}"; VAULT_POD="${VAULT_POD:-vault-0}"
VADDR="${VADDR:-http://127.0.0.1:8200}"; KV="${KV_MOUNT:-secret}"
[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; }

if [[ "$MODE" == "--literal" ]]; then
  VAL="${4:?value}"
  oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c \
    "export VAULT_ADDR=$VADDR VAULT_TOKEN='$VAULT_TOKEN'; vault kv patch $KV/$PATH_KV '$FIELD=$VAL'"
else
  PEM="$MODE"; [[ -f "$PEM" ]] || { echo "no such file: $PEM"; exit 1; }
  grep -q 'BEGIN CERTIFICATE' "$PEM" || echo "WARN: $PEM has no BEGIN CERTIFICATE marker"
  grep -q '\\n' "$PEM" && { echo "ERROR: $PEM contains literal \\n — give a real PEM, not an escaped one"; exit 1; }
  oc cp "$PEM" "$VAULT_NS/$VAULT_POD:/tmp/patch.pem"
  oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c \
    "export VAULT_ADDR=$VADDR VAULT_TOKEN='$VAULT_TOKEN'; vault kv patch $KV/$PATH_KV '$FIELD'=@/tmp/patch.pem; rm -f /tmp/patch.pem"
fi
echo ">> patched $KV/$PATH_KV#$FIELD (other keys preserved). Restart repo-server + hard-refresh to pick it up:"
echo "   oc rollout restart deploy/openshift-gitops-repo-server -n openshift-gitops"
