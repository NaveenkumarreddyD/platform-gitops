#!/usr/bin/env bash
# 12 — READ-ONLY preflight: assert every secret MAS will need is already in Vault.
# This converts the #1 late failure (AVP "cannot resolve <path:…>" at MAS sync) into an early,
# named error. Uses the AVP read-only Kubernetes auth role; a root token is not required.
source "$(cd "$(dirname "$0")" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"; require_cluster
TOKEN="${VAULT_ROOT_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  say "using read-only Vault Kubernetes auth as $(repo_server_sa)"
  TOKEN="$(vault_k8s_token)" || die "Vault Kubernetes auth failed — run ./bootstrap/11-vault-config.sh $ENV"
fi

P="$(vault_path)"; C="$(vault_cluster_path)"
# path#field, one per line. Cluster-scoped first, then instance-scoped.
REQUIRED="
$C/entitlement#image_pull_secret_b64
$P/license#license_file
$P/jdbc-system#username
$P/jdbc-system#password
$P/jdbc-system#jdbc_url
$P/mongo-ca#tls_crt_b64
$P/mongo-ca#tls_key_b64
$P/mongo#username
$P/mongo#password
$P/mongo#host
$P/mongo#ca.crt
$P/sls-mongo#username
$P/sls-mongo#password
$P/certs/public#tls_crt_b64
$P/certs/public#tls_key_b64
$P/certs/public#ca_crt_b64
"
# Optional paths:
#  - manage-crypto: only when MANAGE_AUTO_GENERATE_ENCRYPTION_KEYS=false
OPTIONAL="
$P/manage-crypto#cryptoKey
$P/manage-crypto#cryptoxKey
"

check(){ # <path#field>  -> 0 if present
  local pf="$1" path="${1%%#*}" field="${1##*#}"
  vault_exec "$TOKEN" kv get -field="$field" "$path" >/dev/null 2>&1
}

fail=0
echo "Vault preflight — $ENV   (paths under $C and $P)"
for pf in $REQUIRED; do
  if check "$pf"; then printf '  OK    %s\n' "$pf"; else printf '  MISSING %s\n' "$pf"; fail=1; fi
done
for pf in $OPTIONAL; do
  if check "$pf"; then printf '  OK    %s  (present)\n' "$pf"
  else printf '  --    %s  (absent → MAS uses its default; seed only if you enable the manual option)\n' "$pf"; fi
done
echo
if [[ "$fail" == 0 ]]; then
  echo "PASS — all required secrets present. NEXT: ./bootstrap/20-mongodb.sh $ENV"
else
  echo "FAIL — seed the MISSING paths (INSTALL.md §V.4) before deploying MongoDB/MAS."; exit 1
fi
