#!/usr/bin/env bash
# 20 — deploy MongoDB (operator + dedicated instance). Independent component.
# Reads mongo-ca / mongo / sls-mongo from Vault via AVP, so Vault must be seeded first.
source "$(cd "$(dirname "$0")" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"; require_cluster
MONGO_NS="$(env_mongo_ns)"

# MongoDB's TLS uses a cert-manager Issuer + Certificate — the CRDs must exist first.
oc get crd certificates.cert-manager.io >/dev/null 2>&1 \
  || die "cert-manager CRD (certificates.cert-manager.io) not found — run ./bootstrap/05-operators.sh $ENV first"

# Guard: the CA/creds must be in Vault or the MongoDB CR never becomes Ready.
if [[ -n "${VAULT_ROOT_TOKEN:-}" ]]; then
  vault_exec "$VAULT_ROOT_TOKEN" "vault kv get -field=tls_crt_b64 '$(vault_path)/mongo-ca'" >/dev/null 2>&1 \
    || die "Vault path $(vault_path)/mongo-ca missing — run ./bootstrap/12-vault-verify.sh $ENV first"
else
  say "NOTE: VAULT_ROOT_TOKEN not set — skipping the Vault precheck (run 12-vault-verify.sh yourself)"
fi

apply_component mongodb

say "waiting for MongoDB to report Running in $MONGO_NS (up to 15m)…"
oc -n "$MONGO_NS" wait --for=jsonpath='{.status.phase}'=Running mongodbcommunity --all --timeout=15m 2>/dev/null \
  || say "MongoDB not Running yet — check: oc get mongodbcommunity -n $MONGO_NS  (RUNBOOK: MongoDB not Running)"
oc get mongodbcommunity,pods -n "$MONGO_NS" 2>/dev/null || true

say "done. NEXT: ./bootstrap/30-mas.sh $ENV   (only once MongoDB is Running)"
