#!/usr/bin/env bash
set -uo pipefail
# ---------------------------------------------------------------------------
# Preflight: verify EVERY Vault secret an instance needs exists AND is encoded
# correctly, BEFORE you sync the account-root. Catches the ComparisonError /
# "missing Vault value" / "illegal base64" / escaped-CA failures up front
# instead of one ArgoCD sync at a time.
#
# USAGE: ./preflight-vault.sh [--phase static|full] <cluster.env>
#   e.g. ./preflight-vault.sh envs/drroc4.env
#   static = before Mongo is Running; checks all static secrets, skips Mongo CA.
#   full   = before syncing MAS account-root; requires Mongo and SLS-Mongo CA.
# Runs `vault` inside the vault pod via oc exec.
# Exit 0 = all green; non-zero = at least one problem (printed).
# ---------------------------------------------------------------------------
PHASE="full"
if [[ "${1:-}" == "--phase" ]]; then
  PHASE="${2:?usage: preflight-vault.sh [--phase static|full] <env file>}"
  shift 2
fi
case "$PHASE" in static|full) ;; *) echo "ERROR: phase must be static or full" >&2; exit 2 ;; esac
ENVFILE="${1:?usage: preflight-vault.sh [--phase static|full] <env file>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
VAULT_NS="${VAULT_NS:-vault}"; VAULT_POD="${VAULT_POD:-vault-0}"
VADDR="${VADDR:-http://127.0.0.1:8200}"; KV="${KV_MOUNT:-secret}"
: "${ACCOUNT_ID:?}"; : "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; }

P="$ACCOUNT_ID/$CLUSTER_ID"; IP="$ACCOUNT_ID/$CLUSTER_ID/$INSTANCE_ID"
fail=0
field() { oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c \
  "export VAULT_ADDR=$VADDR VAULT_TOKEN='$VAULT_TOKEN'; vault kv get -field='$2' $KV/$1" 2>/dev/null; }
ok(){ printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no(){ printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }

echo "== entitlement =="
v="$(field "$P/entitlement" image_pull_secret_b64)"
if [[ -z "$v" ]]; then no "entitlement#image_pull_secret_b64 missing"
elif ! echo "$v" | base64 -d 2>/dev/null | grep -q '"auths"'; then
  no "entitlement#image_pull_secret_b64 does not base64-decode to a dockerconfigjson (store base64 of {\"auths\":...})"
else ok "entitlement#image_pull_secret_b64 (valid base64 dockerconfigjson)"; fi

echo "== license =="
v="$(field "$IP/license" license_file)"
if [[ -z "$v" ]]; then no "license#license_file missing"
else
  if echo "$v" | grep -qiE 'INCREMENT|FEATURE'; then
    ok "license#license_file (raw license text; contains INCREMENT/FEATURE)"
  elif echo "$v" | grep -qiE 'SERVER|VENDOR'; then
    no "license#license_file has SERVER/VENDOR but no INCREMENT/FEATURE -> check that this is the MAS/SLS entitlement license.dat"
  elif echo "$v" | base64 -d 2>/dev/null | grep -qiE 'INCREMENT|FEATURE'; then
    no "license#license_file is base64-encoded; store raw license.dat text instead"
  else
    no "license#license_file present but does not look like a license entitlement"
  fi
fi

check_creds(){ # path u-field p-field
  local u p; u="$(field "$1" "$2")"; p="$(field "$1" "$3")"
  [[ -n "$u" ]] && ok "$1#$2" || no "$1#$2 missing"
  [[ -n "$p" ]] && ok "$1#$3" || no "$1#$3 missing"
}
check_manage_crypto(){ # path
  local crypto cryptox
  crypto="$(field "$1" cryptoKey)"
  cryptox="$(field "$1" cryptoxKey)"

  if [[ -z "$crypto" ]]; then
    no "$1#cryptoKey missing"
  elif [[ "$crypto" =~ [[:space:]] ]]; then
    no "$1#cryptoKey contains whitespace/newline characters"
  elif (( ${#crypto} % 24 != 0 )); then
    no "$1#cryptoKey length ${#crypto} invalid; must be a multiple of 24"
  else
    ok "$1#cryptoKey (${#crypto} chars; multiple of 24)"
  fi

  if [[ -z "$cryptox" ]]; then
    no "$1#cryptoxKey missing"
  elif [[ "$cryptox" =~ [[:space:]] ]]; then
    no "$1#cryptoxKey contains whitespace/newline characters"
  elif (( ${#cryptox} % 24 != 0 )); then
    no "$1#cryptoxKey length ${#cryptox} invalid; must be a multiple of 24"
  else
    ok "$1#cryptoxKey (${#cryptox} chars; multiple of 24)"
  fi
}
check_ca(){ # path field
  local c; c="$(field "$1" "$2")"
  if [[ -z "$c" ]]; then no "$1#$2 missing"
  elif echo "$c" | grep -q '\\n'; then no "$1#$2 contains literal \\n (escaped). Re-store as REAL multiline PEM via @file."
  elif echo "$c" | grep -q 'BEGIN CERTIFICATE'; then ok "$1#$2 (real PEM)"
  else no "$1#$2 present but no BEGIN CERTIFICATE marker"; fi
}

echo "== mongo =="; check_creds "$IP/mongo" username password
[[ -n "$(field "$IP/mongo" host)" ]] && ok "$IP/mongo#host" || no "$IP/mongo#host missing"
if [[ "$PHASE" == "full" ]]; then
  check_ca "$IP/mongo" ca.crt
else
  ok "$IP/mongo#ca.crt deferred until MongoDB is Running"
fi
echo "== sls-mongo =="; check_creds "$IP/sls-mongo" username password
if [[ "$PHASE" == "full" ]]; then
  check_ca "$IP/sls-mongo" ca.crt
else
  ok "$IP/sls-mongo#ca.crt deferred until MongoDB is Running"
fi
echo "== jdbc-system =="; check_creds "$IP/jdbc-system" username password
[[ -n "$(field "$IP/jdbc-system" jdbc_url)" ]] && ok "$IP/jdbc-system#jdbc_url" || no "$IP/jdbc-system#jdbc_url missing"
if [[ "${JDBC_SSL_ENABLED:-false}" =~ ^(1|true|yes)$ || "${JDBC_CA_REQUIRED:-false}" =~ ^(1|true|yes)$ ]]; then
  check_ca "$IP/jdbc-system" ca.crt
else
  ok "$IP/jdbc-system#ca.crt not required (JDBC_SSL_ENABLED=false)"
fi
echo "== manage-crypto =="; check_manage_crypto "$IP/manage-crypto"
echo "== superuser =="; check_creds "$IP/superuser" username password

echo "== sls (registration) =="
rk="$(field "$IP/sls" registration_key)"
if [[ -z "$rk" ]]; then
  printf '  \033[33mWARN\033[0m  %s\n' "$IP/sls#registration_key empty -> OK only if SLS not yet deployed (own-SLS) OR using centralized SLS not yet wired. Run harvest-sls-registration.sh after SLS is Ready."
else ok "$IP/sls#registration_key"; check_ca "$IP/sls" ca.crt
  [[ -n "$(field "$IP/sls" url)" ]] && ok "$IP/sls#url" || no "$IP/sls#url missing"; fi

echo
[[ $fail -eq 0 ]] && echo "PREFLIGHT($PHASE): required secrets present & well-formed." \
                  || echo "PREFLIGHT: problems above — fix before syncing account-root."
exit $fail
