#!/usr/bin/env bash
# seed-secrets.sh <env> — seed the static secrets into Vault from EXPORTED variables.
# Runs the vkv puts for step 7. All Vault paths are derived from the env files
# (account/cluster/instance), so nothing is hard-coded. Run after 11-vault-config.sh.
#
# Required exports:
#   VAULT_ROOT_TOKEN     root token from vault-init-<env>.json
#   IBM_ENTITLEMENT_KEY  IBM entitlement key
#   LICENSE_FILE         path to the MAS license file (license.dat)
#   JDBC_USER JDBC_PASS JDBC_URL   Oracle credentials + URL
#
# Optional exports:
#   MONGO_HOST                     default: <instance>-mongo-svc.<mongo-ns>.svc.cluster.local
#   MONGO_CA_CRT_FILE MONGO_CA_KEY_FILE   bring your own Mongo CA (else one is generated)
#   MAS_TLS_CRT_FILE MAS_TLS_KEY_FILE MAS_CA_FILE   seed certs/public (only if using a real MAS cert)
#   PKI_DIR                        where a generated Mongo CA is written (default: ~/mas-<cluster>-pki)
#   ROTATE_MONGO_PASSWORDS=true    explicitly replace both Mongo passwords (default: preserve)
source "$(cd "$(dirname "$0")" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"; require_cluster
: "${VAULT_ROOT_TOKEN:?export VAULT_ROOT_TOKEN}"
: "${IBM_ENTITLEMENT_KEY:?export IBM_ENTITLEMENT_KEY}"
: "${LICENSE_FILE:?export LICENSE_FILE (path to license.dat)}"
: "${JDBC_USER:?export JDBC_USER}"; : "${JDBC_PASS:?export JDBC_PASS}"; : "${JDBC_URL:?export JDBC_URL}"
[[ -f "$LICENSE_FILE" ]] || die "LICENSE_FILE not found: $LICENSE_FILE"

INSTANCE="$(env_instance)"; MONGO_NS="$(env_mongo_ns)"
P="$(vault_path)"; C="$(vault_cluster_path)"
MONGO_HOST="${MONGO_HOST:-${INSTANCE}-mongo-svc.${MONGO_NS}.svc.cluster.local}"
PKI_DIR="${PKI_DIR:-$HOME/mas-$(env_cluster)-pki}"

# Pass values as argv so PEM/multi-line values are preserved exactly.
vkv(){ vault_exec "$VAULT_ROOT_TOKEN" kv put "$@" >/dev/null; }
vget(){ vault_exec "$VAULT_ROOT_TOKEN" kv get -field="$2" "$1" 2>/dev/null; }
rndpw(){ openssl rand -hex 24 | cut -c1-24; }

say "seeding secrets for $ENV under $C and $P"

# entitlement (cluster) + license + jdbc (instance)
ENTITLEMENT_B64="$(printf '{"auths":{"cp.icr.io":{"auth":"%s"}}}' \
  "$(printf 'cp:%s' "$IBM_ENTITLEMENT_KEY" | base64 | tr -d '\r\n')" | base64 | tr -d '\r\n')"
vkv "$C/entitlement"        image_pull_secret_b64="$ENTITLEMENT_B64"
vkv "$P/license"            license_file="$(cat "$LICENSE_FILE")"
vkv "$P/jdbc-system"        username="$JDBC_USER" password="$JDBC_PASS" jdbc_url="$JDBC_URL"
say "  ok  entitlement, license, jdbc-system"

# Mongo CA — bring your own, preserve the Vault copy, or generate once.
umask 077; mkdir -p "$PKI_DIR"
existing_ca_b64="$(vget "$P/mongo-ca" tls_crt_b64 || true)"
existing_ca_key_b64="$(vget "$P/mongo-ca" tls_key_b64 || true)"
if [[ -n "${MONGO_CA_CRT_FILE:-}${MONGO_CA_KEY_FILE:-}" ]]; then
  [[ -n "${MONGO_CA_CRT_FILE:-}" && -n "${MONGO_CA_KEY_FILE:-}" ]] \
    || die "set both MONGO_CA_CRT_FILE and MONGO_CA_KEY_FILE"
  [[ -f "$MONGO_CA_CRT_FILE" && -f "$MONGO_CA_KEY_FILE" ]] \
    || die "provided Mongo CA certificate/key file not found"
  CA_CRT="$MONGO_CA_CRT_FILE"; CA_KEY="$MONGO_CA_KEY_FILE"
  CA_PEM="$(cat "$CA_CRT")"
  vkv "$P/mongo-ca" tls_crt_b64="$(base64 < "$CA_CRT" | tr -d '\r\n')" tls_key_b64="$(base64 < "$CA_KEY" | tr -d '\r\n')"
  say "  updated mongo-ca from provided files"
elif [[ -n "$existing_ca_b64" && -n "$existing_ca_key_b64" ]]; then
  CA_PEM="$(printf '%s' "$existing_ca_b64" | openssl base64 -d -A)"
  say "  preserved existing mongo-ca"
elif [[ -n "$existing_ca_b64$existing_ca_key_b64" ]]; then
  die "$P/mongo-ca is incomplete; restore both tls_crt_b64 and tls_key_b64"
else
  CA_CRT="$PKI_DIR/mongo-ca.crt"; CA_KEY="$PKI_DIR/mongo-ca.key"
  if [[ -f "$CA_CRT" || -f "$CA_KEY" ]]; then
    [[ -f "$CA_CRT" && -f "$CA_KEY" ]] || die "$PKI_DIR contains only one Mongo CA file"
  else
    openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
      -subj "/CN=${INSTANCE}-mongo-ca" -out "$CA_CRT" 2>/dev/null
    say "  generated Mongo CA -> $CA_CRT"
  fi
  CA_PEM="$(cat "$CA_CRT")"
  vkv "$P/mongo-ca" tls_crt_b64="$(base64 < "$CA_CRT" | tr -d '\r\n')" tls_key_b64="$(base64 < "$CA_KEY" | tr -d '\r\n')"
fi

mongo_password="$(vget "$P/mongo" password || true)"
slsmongo_password="$(vget "$P/sls-mongo" password || true)"
if [[ "${ROTATE_MONGO_PASSWORDS:-false}" == "true" || -z "$mongo_password" ]]; then
  mongo_password="$(rndpw)"
fi
if [[ "${ROTATE_MONGO_PASSWORDS:-false}" == "true" || -z "$slsmongo_password" ]]; then
  slsmongo_password="$(rndpw)"
fi
vkv "$P/mongo" username=admin password="$mongo_password" host="$MONGO_HOST" ca.crt="$CA_PEM"
vkv "$P/sls-mongo" username=slsmongo password="$slsmongo_password" ca.crt="$CA_PEM"
if [[ "${ROTATE_MONGO_PASSWORDS:-false}" == "true" ]]; then
  say "  rotated MongoDB passwords by explicit request"
else
  say "  preserved existing MongoDB passwords (generated only when absent)"
fi
say "  ok  mongo-ca, mongo (host=$MONGO_HOST), sls-mongo"

# certs/public — ALWAYS seeded. Manage requires a public cert (unlike the Suite, it can't
# self-sign), so seed either the real cert (MAS_TLS_* files) or a self-signed placeholder.
existing_mas_crt="$(vget "$P/certs/public" tls_crt_b64 || true)"
existing_mas_key="$(vget "$P/certs/public" tls_key_b64 || true)"
existing_mas_ca="$(vget "$P/certs/public" ca_crt_b64 || true)"
if [[ -n "${MAS_TLS_CRT_FILE:-}${MAS_TLS_KEY_FILE:-}${MAS_CA_FILE:-}" ]]; then
  [[ -n "${MAS_TLS_CRT_FILE:-}" && -n "${MAS_TLS_KEY_FILE:-}" && -n "${MAS_CA_FILE:-}" ]] \
    || die "set MAS_TLS_CRT_FILE, MAS_TLS_KEY_FILE, and MAS_CA_FILE together"
  [[ -f "$MAS_TLS_CRT_FILE" && -f "$MAS_TLS_KEY_FILE" && -f "$MAS_CA_FILE" ]] \
    || die "one or more provided MAS certificate files do not exist"
  vkv "$P/certs/public" \
    tls_crt_b64="$(base64 < "$MAS_TLS_CRT_FILE" | tr -d '\r\n')" \
    tls_key_b64="$(base64 < "$MAS_TLS_KEY_FILE" | tr -d '\r\n')" \
    ca_crt_b64="$(base64 < "$MAS_CA_FILE" | tr -d '\r\n')"
  say "  ok  certs/public (real MAS cert)"
elif [[ -n "$existing_mas_crt" && -n "$existing_mas_key" && -n "$existing_mas_ca" ]]; then
  say "  ok  certs/public (preserved existing certificate)"
elif [[ -n "$existing_mas_crt$existing_mas_key$existing_mas_ca" ]]; then
  die "$P/certs/public is incomplete; restore all three certificate fields"
else
  # Self-signed placeholder (browsers warn until you swap the real cert). Domain derives from the
  # vault host (vault.apps.<cluster>... -> <instance>.apps.<cluster>...); override with MAS_DOMAIN.
  MAS_DOMAIN="${MAS_DOMAIN:-${INSTANCE}.${VAULT_HOST_APPS:-$(env_vault_host | sed 's/^vault\.//')}}"
  if [[ -f "$PKI_DIR/mas-tls.crt" || -f "$PKI_DIR/mas-tls.key" ]]; then
    [[ -f "$PKI_DIR/mas-tls.crt" && -f "$PKI_DIR/mas-tls.key" ]] \
      || die "$PKI_DIR contains only one MAS TLS file"
  else
    openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days 825 \
      -keyout "$PKI_DIR/mas-tls.key" -out "$PKI_DIR/mas-tls.crt" \
      -subj "/CN=${MAS_DOMAIN}" -addext "subjectAltName=DNS:${MAS_DOMAIN},DNS:*.${MAS_DOMAIN}" 2>/dev/null
  fi
  vkv "$P/certs/public" \
    tls_crt_b64="$(base64 < "$PKI_DIR/mas-tls.crt" | tr -d '\r\n')" \
    tls_key_b64="$(base64 < "$PKI_DIR/mas-tls.key" | tr -d '\r\n')" \
    ca_crt_b64="$(base64 < "$PKI_DIR/mas-tls.crt" | tr -d '\r\n')"
  say "  ok  certs/public (self-signed placeholder for ${MAS_DOMAIN} — swap real cert later)"
fi

say "done. Move $PKI_DIR + vault-init-$ENV.json to escrow. NEXT: ./bootstrap/12-vault-verify.sh $ENV"
