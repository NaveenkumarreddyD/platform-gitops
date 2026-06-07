#!/usr/bin/env bash
set -euo pipefail
# Harvest the SHARED DRO endpoint/api-token/CA into Vault (dro#url, dro#api_token, dro#ca.crt) so the
# BasCfg (bas-system) can be created. The BAS equivalent of harvest-sls-registration.sh.
#   ./harvest-dro-registration.sh <cluster.env>
# Override discovery with DRO_NS / DRO_URL_OVERRIDE / DRO_TOKEN_SECRET / DRO_CA_SECRET if names differ.
ENVFILE="${1:?usage: harvest-dro-registration.sh <cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${ACCOUNT_ID:?}"; : "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
DRO_NS="${DRO_NS:-${DRO_NAMESPACE:-ibm-software-central}}"
VAULT_NS="${VAULT_NS:-vault}"; VAULT_POD="${VAULT_POD:-vault-0}"; VADDR="${VADDR:-http://127.0.0.1:8200}"; KV="${KV_MOUNT:-secret}"
[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; }
IP="$ACCOUNT_ID/$CLUSTER_ID/$INSTANCE_ID"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo ">> reading DRO from namespace $DRO_NS"

# 1) endpoint (route, else internal svc)
URL="${DRO_URL_OVERRIDE:-}"
if [[ -z "$URL" ]]; then
  H="$(oc get route -n "$DRO_NS" -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | grep -iE 'data-reporter|dro' | head -1 || true)"
  [[ -n "$H" ]] && URL="https://$H" || URL="https://ibm-data-reporter.${DRO_NS}.svc.cluster.local:3000"
fi

# 2) api token (DataReporterConfig api key secret)
TOK="${DRO_TOKEN_OVERRIDE:-}"
if [[ -z "$TOK" ]]; then
  for s in ${DRO_TOKEN_SECRET:-} $(oc get secret -n "$DRO_NS" -o name 2>/dev/null | grep -iE 'data-reporter|dro' | sed 's#secret/##'); do
    for k in api_key apikey token api-token; do
      TOK="$(oc get secret "$s" -n "$DRO_NS" -o jsonpath="{.data.${k}}" 2>/dev/null | base64 -d 2>/dev/null || true)"; [[ -n "$TOK" ]] && break 2
    done
  done
fi

# 3) CA (DRO serving cert)
CA=""
for s in ${DRO_CA_SECRET:-} $(oc get secret -n "$DRO_NS" -o name 2>/dev/null | grep -iE 'data-reporter|dro' | grep -iE 'cert|tls|ca' | sed 's#secret/##'); do
  for k in ca.crt tls.crt; do
    oc get secret "$s" -n "$DRO_NS" -o jsonpath="{.data.${k//./\\.}}" 2>/dev/null | base64 -d > "$TMP/ca.pem" 2>/dev/null || true
    grep -q 'BEGIN CERTIFICATE' "$TMP/ca.pem" 2>/dev/null && { CA="$TMP/ca.pem"; break 2; }
  done
done
[[ -z "$CA" ]] && { echo "WARN: no DRO CA found; writing url+token only."; : > "$TMP/ca.pem"; CA="$TMP/ca.pem"; }

echo "   url=$URL"
echo "   api_token=$( [[ -n "$TOK" ]] && echo "${TOK:0:6}…" || echo MISSING )"
echo "   ca=$( [[ -s "$CA" ]] && echo PEM || echo empty )"
[[ -z "$TOK" ]] && { echo "ERROR: DRO api token not found in $DRO_NS. Set DRO_TOKEN_SECRET or DRO_TOKEN_OVERRIDE."; oc get secret -n "$DRO_NS" | grep -iE 'data-reporter|dro' || true; exit 1; }

oc cp "$CA" "$VAULT_NS/$VAULT_POD:/tmp/dro-ca.pem"
oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c "export VAULT_ADDR=$VADDR VAULT_TOKEN='$VAULT_TOKEN'; \
  vault kv put $KV/$IP/dro url='$URL' api_token='$TOK' ca.crt=@/tmp/dro-ca.pem; rm -f /tmp/dro-ca.pem"
echo ">> wrote $KV/$IP/dro (url, api_token, ca.crt). Then sync ${INSTANCE_ID}-bas-system."
