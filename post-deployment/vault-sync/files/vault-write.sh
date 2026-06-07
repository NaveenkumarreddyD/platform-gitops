#!/usr/bin/env sh
# Runs in the vault image. Logs into Vault via k8s auth (writer role) and writes
# the harvested values from /work. KV-v2 'put' writes the whole secret in one shot.
set -e
MODE="${1:?mode sls|dro}"
export VAULT_ADDR="${VAULT_ADDR:?}"
[ -n "${VAULT_CACERT:-}" ] && export VAULT_CACERT
JWT="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
VAULT_TOKEN="$(vault write -field=token auth/kubernetes/login role="${VAULT_ROLE:?}" jwt="$JWT")"
export VAULT_TOKEN
IP="${ACCOUNT_ID:?}/${CLUSTER_ID:?}/${INSTANCE_ID:?}"
KV="${KV_MOUNT:-secret}"
if [ "$MODE" = "sls" ]; then
  vault kv put "$KV/$IP/sls" \
    registration_key=@/work/registration_key \
    url=@/work/url \
    ca.crt=@/work/ca.pem
  echo ">> wrote $KV/$IP/sls"
elif [ "$MODE" = "dro" ]; then
  vault kv put "$KV/$IP/dro" \
    url=@/work/url \
    api_token=@/work/api_token \
    ca.crt=@/work/ca.pem
  echo ">> wrote $KV/$IP/dro"
elif [ "$MODE" = "mongo" ]; then
  # creds/host already present (load-secrets) — PATCH only the runtime CA so we
  # don't clobber username/password/host. Patches BOTH consumers.
  vault kv patch "$KV/$IP/mongo"     ca.crt=@/work/ca.pem
  vault kv patch "$KV/$IP/sls-mongo" ca.crt=@/work/ca.pem
  echo ">> patched $KV/$IP/mongo#ca.crt and $KV/$IP/sls-mongo#ca.crt"
fi
