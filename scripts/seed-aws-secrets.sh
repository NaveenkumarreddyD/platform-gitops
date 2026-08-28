#!/usr/bin/env bash
# seed-aws-secrets.sh — create/update all AWS Secrets Manager secrets for one MAS instance.
# Values are passed via exported environment variables. Idempotent (create-or-update).
# The Mongo CA (mongo#ca.crt), SLS and DRO secrets are NOT seeded here — they are created
# automatically by cert-manager + the in-cluster publishers.
set -euo pipefail

# ── REQUIRED exports ─────────────────────────────────────────────
: "${REGION:?export REGION=us-east-1}"
: "${CLUSTER:?export CLUSTER=drroc4}"                 # account == cluster
: "${INSTANCE:?export INSTANCE=drgitopsapp}"
: "${ENTITLEMENT_KEY:?export ENTITLEMENT_KEY=<ibm-entitlement-key>}"
: "${LICENSE_FILE:?export LICENSE_FILE=/path/to/entitlement.lic}"
: "${MONGO_ADMIN_PASSWORD:?export MONGO_ADMIN_PASSWORD=...}"
: "${SLS_MONGO_PASSWORD:?export SLS_MONGO_PASSWORD=...}"
: "${JDBC_USERNAME:?export JDBC_USERNAME=maximo}"
: "${JDBC_PASSWORD:?export JDBC_PASSWORD=...}"
: "${JDBC_URL:?export JDBC_URL=jdbc:oracle:thin:@//host:1521/SVC}"
: "${TLS_CRT:?export TLS_CRT=/path/to/tls.crt}"
: "${TLS_KEY:?export TLS_KEY=/path/to/tls.key}"
: "${CA_CHAIN:?export CA_CHAIN=/path/to/ca-chain.crt}"

# ── OPTIONAL exports (with defaults) ─────────────────────────────
MONGO_USERNAME="${MONGO_USERNAME:-admin}"
SLS_MONGO_USERNAME="${SLS_MONGO_USERNAME:-slsmongo}"
MONGO_NS="${MONGO_NS:-mongo-gitops}"
MONGO_HOST="${MONGO_HOST:-${INSTANCE}-mongo-svc.${MONGO_NS}.svc.cluster.local}"
# MANAGE_CRYPTO_KEY / MANAGE_CRYPTOX_KEY      — only when reusing a Manage DB
# POWERSCALE_S3_SUBCA / POWERSCALE_S3_ROOTCA  — only for S3 attachments

P="mas/${CLUSTER}/${CLUSTER}"
IP="${P}/${INSTANCE}"

put() {  # put <secret-name> <json-string>
  local name="$1" json="$2" f
  f="$(mktemp)"; chmod 600 "$f"; printf '%s' "$json" >"$f"
  if aws secretsmanager describe-secret --region "$REGION" --secret-id "$name" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --region "$REGION" --secret-id "$name" --secret-string "file://$f" >/dev/null
    echo "updated  $name"
  else
    aws secretsmanager create-secret  --region "$REGION" --name "$name" --secret-string "file://$f" >/dev/null
    echo "created  $name"
  fi
  rm -f "$f"
}

# entitlement (dockerconfigjson, base64) — built without needing oc/a cluster
AUTH="$(printf 'cp:%s' "$ENTITLEMENT_KEY" | base64 -w0)"
IPS_B64="$(jq -nc --arg p "$ENTITLEMENT_KEY" --arg a "$AUTH" \
  '{auths:{"cp.icr.io":{username:"cp",password:$p,auth:$a}}}' | base64 -w0)"
put "$P/entitlement"   "$(jq -n --arg v "$IPS_B64" '{image_pull_secret_b64:$v}')"

put "$IP/license"      "$(jq -n --arg v "$(cat "$LICENSE_FILE")" '{license_file:$v}')"
put "$IP/mongo"        "$(jq -n --arg u "$MONGO_USERNAME" --arg p "$MONGO_ADMIN_PASSWORD" --arg h "$MONGO_HOST" '{username:$u,password:$p,host:$h}')"
put "$IP/sls-mongo"    "$(jq -n --arg u "$SLS_MONGO_USERNAME" --arg p "$SLS_MONGO_PASSWORD" '{username:$u,password:$p}')"
put "$IP/jdbc-system"  "$(jq -n --arg u "$JDBC_USERNAME" --arg p "$JDBC_PASSWORD" --arg url "$JDBC_URL" '{username:$u,password:$p,jdbc_url:$url}')"
put "$IP/certs/public" "$(jq -n --arg c "$(base64 -w0 "$TLS_CRT")" --arg k "$(base64 -w0 "$TLS_KEY")" --arg a "$(base64 -w0 "$CA_CHAIN")" '{tls_crt_b64:$c,tls_key_b64:$k,ca_crt_b64:$a}')"

# optional — only if the vars are set
if [ -n "${MANAGE_CRYPTO_KEY:-}" ] && [ -n "${MANAGE_CRYPTOX_KEY:-}" ]; then
  put "$IP/manage-crypto" "$(jq -n --arg a "$MANAGE_CRYPTO_KEY" --arg b "$MANAGE_CRYPTOX_KEY" '{cryptoKey:$a,cryptoxKey:$b}')"
fi
if [ -n "${POWERSCALE_S3_SUBCA:-}" ] && [ -n "${POWERSCALE_S3_ROOTCA:-}" ]; then
  put "$IP/manage-cos" "$(jq -n --arg s "$POWERSCALE_S3_SUBCA" --arg r "$POWERSCALE_S3_ROOTCA" '{powerscale_s3_subca:$s,powerscale_s3_rootca:$r}')"
fi

echo
echo "== secrets under $P =="
aws secretsmanager list-secrets --region "$REGION" \
  --query "SecretList[?starts_with(Name,'$P')].Name" --output text | tr '\t' '\n' | sort
echo
echo "NOT seeded (auto-created): $IP/mongo#ca.crt (cert-manager), $IP/sls, $P/dro (publisher)"
