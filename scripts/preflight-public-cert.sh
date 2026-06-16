#!/usr/bin/env bash
set -euo pipefail
# Fail-fast check that the MAS public certificate exists in Vault BEFORE the
# account-root renders the mas-certs Secret. Skipping this is what let an empty
# <instanceId>-cert-public Secret reach the Suite operator, whose "Get Public Route
# certificates and key" task then died with a NoneType error and aborted the whole
# Suite reconcile (so mas-mongo-config / mas-mongo-credentials / <instance>-sls-cfg
# were never created, leaving catalogmgr stuck Init and the Suite IncompleteConfiguration).
#
#   ./preflight-public-cert.sh <path/to/cluster.env>
#   export VAULT_TOKEN first. No-op when MAS_MANUAL_CERT_MGMT=false.
ENVFILE="${1:?usage: preflight-public-cert.sh <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${ACCOUNT_ID:?}"; : "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
VAULT_NS="${VAULT_NS:-vault}"; VAULT_POD="${VAULT_POD:-vault-0}"
VADDR="${VADDR:-http://127.0.0.1:8200}"; KV="${KV_MOUNT:-secret}"

if ! [[ "${MAS_MANUAL_CERT_MGMT:-true}" =~ ^(1|true|yes)$ ]]; then
  echo ">> MAS_MANUAL_CERT_MGMT=false; MAS self-manages route certs. Nothing to check."
  exit 0
fi
[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; }

CPATH="$ACCOUNT_ID/$CLUSTER_ID/$INSTANCE_ID/certs/public"
field() { oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c \
  "export VAULT_ADDR=$VADDR VAULT_TOKEN='$VAULT_TOKEN'; vault kv get -field='$2' $KV/$1" 2>/dev/null; }

fail=0
for k in tls_crt_b64 tls_key_b64 ca_crt_b64; do
  v="$(field "$CPATH" "$k")"
  if [[ -z "$v" ]]; then
    echo "  FAIL  $KV/$CPATH#$k missing"; fail=1
  elif ! echo "$v" | base64 -d 2>/dev/null | grep -q 'BEGIN'; then
    echo "  FAIL  $KV/$CPATH#$k does not base64-decode to PEM"; fail=1
  else
    echo "  PASS  $KV/$CPATH#$k"
  fi
done

if [[ "$fail" -ne 0 ]]; then
  cat >&2 <<MSG

ERROR: MAS public certificate is not loaded in Vault ($KV/$CPATH).
       With manual cert management the Suite REQUIRES this before it can reconcile.
       Load it, then re-run:

         export VAULT_TOKEN='<token>'
         export PFX_PASSWORD='<pfx password if any>'
         ./scripts/load-mas-public-cert.sh "$ENVFILE" /path/to/mas-public-cert.pfx

       (Set MAS_MANUAL_CERT_MGMT=false in the env file only if MAS self-manages certs.)
MSG
  exit 1
fi
echo ">> MAS public cert present in Vault; safe to render <instanceId>-cert-public."
