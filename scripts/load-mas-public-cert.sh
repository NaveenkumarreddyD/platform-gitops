#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: load-mas-public-cert.sh <cluster.env> <cert.pfx>"
  echo "       export VAULT_TOKEN first. If the PFX is password-protected, export PFX_PASSWORD."
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
ENVFILE="${1:?$(usage)}"
PFX_FILE="${2:?$(usage)}"
[[ -f "$ENVFILE" ]] || { echo "ERROR: env file not found: $ENVFILE" >&2; exit 2; }
[[ -f "$PFX_FILE" ]] || { echo "ERROR: PFX file not found: $PFX_FILE" >&2; exit 2; }

# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${ACCOUNT_ID:?}"; : "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
VAULT_NS="${VAULT_NS:-vault}"; VAULT_POD="${VAULT_POD:-vault-0}"
VADDR="${VADDR:-http://127.0.0.1:8200}"; KV="${KV_MOUNT:-secret}"
[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS_ARGS=()
if [[ -n "${PFX_PASSWORD:-}" ]]; then
  PASS_ARGS=(-passin "pass:${PFX_PASSWORD}")
fi

openssl pkcs12 -in "$PFX_FILE" "${PASS_ARGS[@]}" -clcerts -nokeys -out "$TMP/tls.crt"
openssl pkcs12 -in "$PFX_FILE" "${PASS_ARGS[@]}" -nocerts -nodes -out "$TMP/tls.key"
openssl pkcs12 -in "$PFX_FILE" "${PASS_ARGS[@]}" -cacerts -nokeys -out "$TMP/ca.crt"

openssl x509 -in "$TMP/tls.crt" -noout -subject -issuer -ext subjectAltName
grep -q 'BEGIN CERTIFICATE' "$TMP/tls.crt" || { echo "ERROR: tls.crt missing PEM certificate" >&2; exit 1; }
grep -q 'BEGIN.*PRIVATE KEY' "$TMP/tls.key" || { echo "ERROR: tls.key missing PEM private key" >&2; exit 1; }
grep -q 'BEGIN CERTIFICATE' "$TMP/ca.crt" || { echo "ERROR: ca.crt missing PEM CA chain" >&2; exit 1; }

base64 < "$TMP/tls.crt" | tr -d '\n' > "$TMP/tls.crt.b64"
base64 < "$TMP/tls.key" | tr -d '\n' > "$TMP/tls.key.b64"
base64 < "$TMP/ca.crt" | tr -d '\n' > "$TMP/ca.crt.b64"

oc cp "$TMP/tls.crt.b64" "$VAULT_NS/$VAULT_POD:/tmp/mas-tls.crt.b64"
oc cp "$TMP/tls.key.b64" "$VAULT_NS/$VAULT_POD:/tmp/mas-tls.key.b64"
oc cp "$TMP/ca.crt.b64" "$VAULT_NS/$VAULT_POD:/tmp/mas-ca.crt.b64"

PATH_KV="$KV/$ACCOUNT_ID/$CLUSTER_ID/$INSTANCE_ID/certs/public"
oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c "
  export VAULT_ADDR=$VADDR VAULT_TOKEN='$VAULT_TOKEN'
  vault kv put '$PATH_KV' \
    tls_crt_b64=@/tmp/mas-tls.crt.b64 \
    tls_key_b64=@/tmp/mas-tls.key.b64 \
    ca_crt_b64=@/tmp/mas-ca.crt.b64
  rm -f /tmp/mas-tls.crt.b64 /tmp/mas-tls.key.b64 /tmp/mas-ca.crt.b64
"

echo ">> wrote MAS public certificate material to $PATH_KV"

# Self-check: read each field back and confirm ONE base64 decode yields PEM. This
# catches the double-encoding trap (source that was already base64 text, not raw PEM),
# which renders a secret whose value decodes to base64 instead of a certificate and
# makes the Suite operator's route-cert task fail. Single base64(PEM) is the contract
# the mas-certs chart's `data:` block depends on.
echo ">> verifying stored values are single base64 of PEM (guards against double-encoding)"
readback() { oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c \
  "export VAULT_ADDR=$VADDR VAULT_TOKEN='$VAULT_TOKEN'; vault kv get -field='$2' '$1'" 2>/dev/null; }
verr=0
check_pem() { # field marker
  local v; v="$(readback "$PATH_KV" "$1")"
  if echo "$v" | base64 -d 2>/dev/null | grep -q "BEGIN.*$2"; then
    echo "   PASS $1 -> single base64 of a PEM '$2'"
  else
    echo "   FAIL $1 -> does NOT decode to a PEM '$2' (looks double-encoded). Provide RAW PEM/PFX, not base64." >&2
    verr=1
  fi
}
check_pem tls_crt_b64 CERTIFICATE
check_pem tls_key_b64 'PRIVATE KEY'
check_pem ca_crt_b64  CERTIFICATE
[[ "$verr" -eq 0 ]] || { echo "ERROR: stored cert material failed validation; not safe to render." >&2; exit 1; }
echo ">> verified: tls/key/ca each decode to PEM in a single step."
