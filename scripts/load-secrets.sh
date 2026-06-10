#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# Vault secret loader v3 — env-file driven, NON-SSL JDBC, DEDICATED Mongo.
#   ./load-secrets.sh <cluster.env>     (export VAULT_TOKEN + the REQUIRE vars first)
#
#   REQUIRE  : IBM_ENTITLEMENT_KEY  MAS_LICENSE_FILE  JDBC_USERNAME/PASSWORD/URL
#   OPTIONAL : JDBC_CA_CRT  (TCPS only; omit for non-SSL Oracle)
#   GENERATE : superuser, manage-crypto, mongo(admin) + sls-mongo passwords  (made once, reused)
#   NOTE     : mongo/sls-mongo CA come LATER from scripts/sync-mongo-ca.sh once the dedicated Mongo
#              is up (its cert-manager CA). mongo#host points at the NEW dedicated Mongo service.
# ---------------------------------------------------------------------------
ENVFILE="${1:?usage: load-secrets.sh <cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${ACCOUNT_ID:?}"; : "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
PREFIX="secret/${ACCOUNT_ID}/${CLUSTER_ID}"; IPREFIX="${PREFIX}/${INSTANCE_ID}"
KV="${KV_MOUNT:-secret}"
VAULT_NS="${VAULT_NS:-vault}"; VAULT_POD="${VAULT_POD:-vault-0}"; VADDR="${VADDR:-http://127.0.0.1:8200}"
# Dedicated Mongo for THIS instance (created by GitOps; not the shared mas-mongo-ce):
MONGO_HOST="${MONGO_HOST:-${INSTANCE_ID}-mongo-svc.${MONGO_NS:-mongo-${INSTANCE_ID}}.svc.cluster.local}"
[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; }
vrun(){ oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c "export VAULT_ADDR=$VADDR VAULT_TOKEN='$VAULT_TOKEN'; $*"; }
vget(){ vrun "vault kv get -field='$2' $1" 2>/dev/null || true; }
gen(){ openssl rand -base64 "${1:-24}" | tr -d '\r\n/+=' | cut -c1-"${2:-24}"; }
putfile(){ oc cp "$1" "$VAULT_NS/$VAULT_POD:/tmp/$2"; }

: "${IBM_ENTITLEMENT_KEY:?REQUIRED}"; : "${MAS_LICENSE_FILE:?REQUIRED path to license.dat}"
: "${JDBC_USERNAME:?REQUIRED}"; : "${JDBC_PASSWORD:?REQUIRED}"; : "${JDBC_URL:?REQUIRED}"
: "${MAS_LICENSE_ID:=}"; : "${JDBC_CA_CRT:=}"   # JDBC_CA_CRT empty => non-SSL

# generate-once (reused on re-run)
MAS_SUPERUSER_USERNAME="${MAS_SUPERUSER_USERNAME:-$(vget "$IPREFIX/superuser" username)}"; MAS_SUPERUSER_USERNAME="${MAS_SUPERUSER_USERNAME:-superuser}"
MAS_SUPERUSER_PASSWORD="${MAS_SUPERUSER_PASSWORD:-$(vget "$IPREFIX/superuser" password)}"; MAS_SUPERUSER_PASSWORD="${MAS_SUPERUSER_PASSWORD:-$(gen 24 24)}"
MANAGE_CRYPTO_KEY="${MANAGE_CRYPTO_KEY:-$(vget "$IPREFIX/manage-crypto" cryptoKey)}";   MANAGE_CRYPTO_KEY="${MANAGE_CRYPTO_KEY:-$(gen 72 72)}"
MANAGE_CRYPTOX_KEY="${MANAGE_CRYPTOX_KEY:-$(vget "$IPREFIX/manage-crypto" cryptoxKey)}"; MANAGE_CRYPTOX_KEY="${MANAGE_CRYPTOX_KEY:-$(gen 72 72)}"
MONGO_USERNAME="${MONGO_USERNAME:-admin}"
MONGO_PASSWORD="${MONGO_PASSWORD:-$(vget "$IPREFIX/mongo" password)}"; MONGO_PASSWORD="${MONGO_PASSWORD:-$(gen 24 24)}"
SLS_MONGO_USERNAME="${SLS_MONGO_USERNAME:-slsmongo}"
SLS_MONGO_PASSWORD="${SLS_MONGO_PASSWORD:-$(vget "$IPREFIX/sls-mongo" password)}"; SLS_MONGO_PASSWORD="${SLS_MONGO_PASSWORD:-$(gen 24 24)}"

ENC="$(printf 'cp:%s' "$IBM_ENTITLEMENT_KEY" | base64 -w0)"
DOCKERCFG="$(printf '{"auths":{"cp.icr.io":{"auth":"%s"}}}' "$ENC" | base64 -w0)"
vrun "vault kv put $PREFIX/entitlement image_pull_secret_b64='$DOCKERCFG'"
putfile "$MAS_LICENSE_FILE" mas-license.dat
vrun "vault kv put $IPREFIX/license license_id='$MAS_LICENSE_ID' license_file=@/tmp/mas-license.dat; rm -f /tmp/mas-license.dat"
vrun "vault kv put $IPREFIX/superuser username='$MAS_SUPERUSER_USERNAME' password='$MAS_SUPERUSER_PASSWORD'"
vrun "vault kv put $IPREFIX/manage-crypto cryptoKey='$MANAGE_CRYPTO_KEY' cryptoxKey='$MANAGE_CRYPTOX_KEY'"

if [[ -n "$JDBC_CA_CRT" ]]; then
  putfile "$JDBC_CA_CRT" jdbc-ca.pem
  vrun "vault kv put $IPREFIX/jdbc-system username='$JDBC_USERNAME' password='$JDBC_PASSWORD' jdbc_url='$JDBC_URL' ca.crt=@/tmp/jdbc-ca.pem; rm -f /tmp/jdbc-ca.pem"
else
  vrun "vault kv put $IPREFIX/jdbc-system username='$JDBC_USERNAME' password='$JDBC_PASSWORD' jdbc_url='$JDBC_URL'"
fi

# Dedicated Mongo: write creds + host now; CA is patched in by sync-mongo-ca.sh after Mongo is Ready.
vrun "vault kv patch $IPREFIX/mongo username='$MONGO_USERNAME' password='$MONGO_PASSWORD' host='$MONGO_HOST' 2>/dev/null || vault kv put $IPREFIX/mongo username='$MONGO_USERNAME' password='$MONGO_PASSWORD' host='$MONGO_HOST'"
vrun "vault kv patch $IPREFIX/sls-mongo username='$SLS_MONGO_USERNAME' password='$SLS_MONGO_PASSWORD' 2>/dev/null || vault kv put $IPREFIX/sls-mongo username='$SLS_MONGO_USERNAME' password='$SLS_MONGO_PASSWORD'"

echo ">> Loaded (generate-once values reused on re-run)."
echo ">> JDBC: $( [[ -n "$JDBC_CA_CRT" ]] && echo 'TCPS (CA stored)' || echo 'non-SSL (no CA)' )"
echo ">> mongo#host=$MONGO_HOST  (dedicated Mongo; CA filled later)"
echo ">> NEXT: after the dedicated Mongo is Ready -> scripts/sync-mongo-ca.sh $ENVFILE"
echo ">>       after SLS is Ready                 -> scripts/harvest-sls-registration.sh $ENVFILE"
echo ">> Verify: scripts/preflight-vault.sh $ENVFILE"
