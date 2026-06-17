#!/usr/bin/env bash
set -euo pipefail
# Snapshot every Mongo-CA source + the consumers' state, so a BEFORE/AFTER diff around
# reconcile-mongo-dependent-configs.sh shows exactly WHY reconcile fixes things:
#   - if the CA fingerprints DIFFER before vs after  -> Vault held a stale/wrong CA (DRIFT);
#     reconcile fixed it by re-harvesting. Permanent fix = served-chain fallback / harvest order.
#   - if fingerprints are IDENTICAL but a pod's creationTimestamp changed -> reconcile only
#     BOUNCED a controller that had cached its TLS verify (CACHE). Permanent fix = ensure the
#     bounce always fires at the right moment (it already does in the install flow).
#
#   ./scripts/diag-mongo-ca.sh <cluster.env>
ENVFILE="${1:?usage: diag-mongo-ca.sh <cluster.env>}"
set -a; . "$ENVFILE"; set +a
: "${ACCOUNT_ID:?}"; : "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
MONGO_NS="${MONGO_NS:?}"; MONGO_CR="${MONGO_CR:-${INSTANCE_ID}-mongo}"
CORE_NS="mas-${INSTANCE_ID}-core"; SLS_NS="mas-${INSTANCE_ID}-sls"
VAULT_NS="${VAULT_NS:-vault}"; VAULT_POD="${VAULT_POD:-vault-0}"; VADDR="${VADDR:-http://127.0.0.1:8200}"; KV="${KV_MOUNT:-secret}"
IP="$ACCOUNT_ID/$CLUSTER_ID/$INSTANCE_ID"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fp() { # fingerprint a PEM on stdin; print sha256 or "-" if not a cert
  local f="$TMP/x.pem"; cat > "$f"
  if grep -q 'BEGIN CERTIFICATE' "$f" 2>/dev/null; then
    openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'
  else echo "-"; fi
}
secret_ca() { oc -n "$1" get secret "$2" -o jsonpath="{.data.ca\.crt}" 2>/dev/null | base64 -d 2>/dev/null; }
vault_ca() { oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c \
  "export VAULT_ADDR=$VADDR VAULT_TOKEN='${VAULT_TOKEN:-}'; vault kv get -field=ca.crt $KV/$IP/$1" 2>/dev/null; }

echo "================ MONGO-CA SNAPSHOT ($(date -u +%FT%TZ)) ================"
echo "-- CA fingerprints (sha256) --"
printf '  %-34s %s\n' "cert-manager ${MONGO_CR}-ca"          "$(secret_ca "$MONGO_NS" "${MONGO_CR}-ca"          | fp)"
printf '  %-34s %s\n' "cert-manager ${MONGO_CR}-server-cert" "$(secret_ca "$MONGO_NS" "${MONGO_CR}-server-cert" | fp)"
printf '  %-34s %s\n' "vault mongo#ca.crt"                   "$(vault_ca mongo     | fp)"
printf '  %-34s %s\n' "vault sls-mongo#ca.crt"               "$(vault_ca sls-mongo | fp)"

echo "-- controller pods (name + creationTimestamp; a NEW timestamp = it was bounced) --"
for ns_pat in "$SLS_NS:sls-controller-manager" "$CORE_NS:entitymgr-suite" "$CORE_NS:entitymgr-mongocfg" "$CORE_NS:entitymgr-slscfg"; do
  ns="${ns_pat%%:*}"; pat="${ns_pat##*:}"
  line="$(oc get pod -n "$ns" --no-headers 2>/dev/null | awk -v p="$pat" '$1 ~ p {print $1; exit}')"
  if [[ -n "$line" ]]; then
    ts="$(oc get pod "$line" -n "$ns" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"
    printf '  %-30s %-45s %s\n' "$pat" "$line" "$ts"
  else
    printf '  %-30s %s\n' "$pat" "(none)"
  fi
done

echo "-- consumer status --"
printf '  SLS LicenseService: %s\n' "$(oc get licenseservices.sls.ibm.com -n "$SLS_NS" -o jsonpath='{.items[0].status.status}' 2>/dev/null || echo missing)"
oc get licenseservices.sls.ibm.com -n "$SLS_NS" \
  -o jsonpath='{range .items[0].status.conditions[*]}    [{.type}={.status}] {.reason}{"\n"}{end}' 2>/dev/null || true
if oc get suite "$INSTANCE_ID" -n "$CORE_NS" >/dev/null 2>&1; then
  echo "  Suite conditions:"
  oc get suite "$INSTANCE_ID" -n "$CORE_NS" \
    -o jsonpath='{range .status.conditions[*]}    [{.type}={.status}] {.reason}{"\n"}{end}' 2>/dev/null || true
else
  echo "  Suite: (core operators not deployed yet)"
fi
echo "========================================================================"
