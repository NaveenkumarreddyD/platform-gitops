#!/usr/bin/env bash
# Save Manage encryption keys to AWS Secrets Manager using the caller's federated AWS session.
set -euo pipefail
source "$(cd "$(dirname "$0")/../bootstrap" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"
require_cluster
command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
: "${AWS_REGION:?set AWS_REGION for the approved federated AWS session}"

INSTANCE="$(env_instance)"
MANAGE_NS="mas-${INSTANCE}-manage"
SECRET_ID="$(aws_instance_path)/manage-crypto"
K8S_SECRET="$(oc get secret -n "$MANAGE_NS" -o name 2>/dev/null \
  | grep -E 'manage-encryptionsecret' | head -1 || true)"
[[ -n "$K8S_SECRET" ]] || die "no Manage encryption secret found in $MANAGE_NS"

CRYPTO_KEY_FIELD="${CRYPTO_KEY_FIELD:-MXE_SECURITY_CRYPTO_KEY}"
CRYPTOX_KEY_FIELD="${CRYPTOX_KEY_FIELD:-MXE_SECURITY_CRYPTOX_KEY}"
crypto_key="$(oc get "$K8S_SECRET" -n "$MANAGE_NS" \
  -o "jsonpath={.data.$CRYPTO_KEY_FIELD}" | base64 -d)"
cryptox_key="$(oc get "$K8S_SECRET" -n "$MANAGE_NS" \
  -o "jsonpath={.data.$CRYPTOX_KEY_FIELD}" | base64 -d)"
[[ -n "$crypto_key" && -n "$cryptox_key" ]] \
  || die "expected fields were not found in $K8S_SECRET"

umask 077
payload="$(mktemp)"
trap 'rm -f "$payload"' EXIT
jq -n --arg cryptoKey "$crypto_key" --arg cryptoxKey "$cryptox_key" \
  '{cryptoKey:$cryptoKey, cryptoxKey:$cryptoxKey}' > "$payload"
unset crypto_key cryptox_key

if aws secretsmanager describe-secret --region "$AWS_REGION" \
  --secret-id "$SECRET_ID" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --region "$AWS_REGION" \
    --secret-id "$SECRET_ID" --secret-string "file://$payload" >/dev/null
else
  aws secretsmanager create-secret --region "$AWS_REGION" \
    --name "$SECRET_ID" --secret-string "file://$payload" >/dev/null
fi

echo "Saved Manage encryption keys to AWS Secrets Manager: $SECRET_ID"
echo "Set MANAGE_AUTO_GENERATE_ENCRYPTION_KEYS=false before reusing this database."
