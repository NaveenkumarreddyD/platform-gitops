#!/usr/bin/env bash
set -euo pipefail
# Copy the DEDICATED Mongo's cert-manager CA into Vault (mongo#ca.crt AND sls-mongo#ca.crt), then
# hard-refresh the consuming apps. Run ONCE after the dedicated Mongo is Ready, and after any CA rotation.
#   ./sync-mongo-ca.sh <cluster.env>
ENVFILE="${1:?usage: sync-mongo-ca.sh <cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${ACCOUNT_ID:?}"; : "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
MONGO_NS="${MONGO_NS:-mongo-${INSTANCE_ID}}"; MONGO_CR="${MONGO_CR:-${INSTANCE_ID}-mongo}"
VAULT_NS="${VAULT_NS:-vault}"; VAULT_POD="${VAULT_POD:-vault-0}"; VADDR="${VADDR:-http://127.0.0.1:8200}"; KV="${KV_MOUNT:-secret}"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; }
IP="$ACCOUNT_ID/$CLUSTER_ID/$INSTANCE_ID"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# CA from the cert-manager CA secret (<resource>-ca), key ca.crt (fallback tls.crt)
for s in "${MONGO_CR}-ca" "${MONGO_CR}-server-cert"; do
  for k in ca.crt tls.crt; do
    oc get secret "$s" -n "$MONGO_NS" -o jsonpath="{.data.${k//./\\.}}" 2>/dev/null | base64 -d > "$TMP/ca.pem" 2>/dev/null || true
    grep -q 'BEGIN CERTIFICATE' "$TMP/ca.pem" 2>/dev/null && break 2
  done
done
grep -q 'BEGIN CERTIFICATE' "$TMP/ca.pem" 2>/dev/null || { echo "ERROR: no CA found in $MONGO_NS (looked at ${MONGO_CR}-ca / -server-cert). Is the Mongo Ready?"; oc get secret -n "$MONGO_NS" | grep -Ei 'ca|cert'; exit 1; }

oc cp "$TMP/ca.pem" "$VAULT_NS/$VAULT_POD:/tmp/mongo-ca.pem"
oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c "export VAULT_ADDR=$VADDR VAULT_TOKEN='$VAULT_TOKEN'; \
  vault kv patch $KV/$IP/mongo ca.crt=@/tmp/mongo-ca.pem; \
  vault kv patch $KV/$IP/sls-mongo ca.crt=@/tmp/mongo-ca.pem; rm -f /tmp/mongo-ca.pem"
echo ">> patched $KV/$IP/mongo#ca.crt and $KV/$IP/sls-mongo#ca.crt"

oc rollout restart deploy/openshift-gitops-repo-server -n "$ARGO_NS" >/dev/null 2>&1 || true
for app in "${INSTANCE_ID}-mongo-system.${CLUSTER_ID}" "${INSTANCE_ID}-sls-system.${CLUSTER_ID}"; do
  oc annotate application "$app" -n "$ARGO_NS" argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true
done
echo ">> repo-server restarted + mongo/sls apps hard-refreshed."
