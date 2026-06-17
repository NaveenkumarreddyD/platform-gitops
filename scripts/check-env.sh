#!/usr/bin/env bash
set -euo pipefail
# Validate local tools, cluster access, required env vars, and obvious config placeholders.
ENVFILE="${1:?usage: check-env.sh <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${ACCOUNT_ID:?}"; : "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
VAULT_NS="${VAULT_NS:-vault}"
fail=0

ok(){ printf '  PASS  %s\n' "$1"; }
no(){ printf '  FAIL  %s\n' "$1"; fail=1; }
warn(){ printf '  WARN  %s\n' "$1"; }

echo "== local tools =="
for c in oc helm git python3 openssl; do
  command -v "$c" >/dev/null 2>&1 && ok "$c" || no "$c missing from PATH"
done

echo "== cluster access =="
oc whoami >/dev/null 2>&1 && ok "oc login active ($(oc whoami 2>/dev/null))" || no "oc login required"
oc get namespace "$ARGO_NS" >/dev/null 2>&1 && ok "namespace/$ARGO_NS" || no "namespace/$ARGO_NS missing"
oc get applications.argoproj.io -n "$ARGO_NS" >/dev/null 2>&1 && ok "Argo CD Application CRD accessible" || no "cannot read Argo CD Applications in $ARGO_NS"
oc auth can-i patch applications.argoproj.io -n "$ARGO_NS" >/dev/null 2>&1 && ok "can patch Argo CD Applications" || no "need permission to patch Argo CD Applications in $ARGO_NS"

echo "== config values =="
for k in CLUSTER_URL MAS_DOMAIN MONGO_NS; do
  v="${!k:-}"
  [[ -n "$v" && "$v" != CHANGE_ME* && "$v" != *CHANGE_ME* ]] && ok "$k=$v" || no "$k is unset or still CHANGE_ME"
done

echo "== versions (pin what gets deployed) =="
# Channels select the operator stream; target versions pin the exact CSV. Both must be set,
# and must be carried by the operator-catalog image, or you get the wrong MAS/Manage version.
for k in MAS_CHANNEL SLS_CHANNEL MAS_APP_CHANNEL MAS_TARGET_VERSION MANAGE_TARGET_VERSION; do
  v="${!k:-}"
  [[ -n "$v" ]] && ok "$k=$v" || no "$k unset (required to control the deployed version)"
done

# Catalog <-> version consistency. The catalog tag is the master pin for EVERY app version;
# if the target pins don't match what the tag actually ships, you get a silent version skew
# (e.g. Manage installs the catalog's channel head, the ManageWorkspace requests your pin,
# and the vmanage webhook rejects it / the Maximo DB update fails). Verified against the IBM
# catalog manifests at https://ibm-mas.github.io/cli/catalogs/. Add new tags here as you adopt them.
echo "== catalog <-> version consistency =="
cat_tag="${MAS_CATALOG_VERSION:-}"
if [[ -z "$cat_tag" ]]; then
  no "MAS_CATALOG_VERSION unset (the catalog tag is the master version pin)"
else
  exp_core=""; exp_manage=""; exp_sls=""
  case "$cat_tag" in
    v9-240625-amd64) exp_core=8.11.12; exp_manage=8.7.9;  exp_sls=3.9.1  ;;
    v9-250828-amd64) exp_core=8.11.25; exp_manage=8.7.23; exp_sls=3.12.2 ;;
    v9-250925-amd64) exp_core=8.11.26; exp_manage=8.7.24; exp_sls=3.12.2 ;;
    v9-251030-amd64) exp_core=8.11.27; exp_manage=8.7.25; exp_sls=3.12.2 ;;
    v9-251127-amd64) exp_core=8.11.28; exp_manage=8.7.26; exp_sls=3.12.2 ;;
  esac
  if [[ -z "$exp_core" ]]; then
    warn "catalog $cat_tag not in the known map; cannot verify it ships MAS ${MAS_TARGET_VERSION:-?} / Manage ${MANAGE_TARGET_VERSION:-?}. Confirm at ibm-mas.github.io/cli/catalogs/$cat_tag/ and add it to check-env.sh."
  else
    [[ "${MAS_TARGET_VERSION:-}"    == "$exp_core"   ]] && ok "catalog $cat_tag ships MAS core $exp_core (matches MAS_TARGET_VERSION)" \
      || no "catalog $cat_tag ships MAS core $exp_core but MAS_TARGET_VERSION=${MAS_TARGET_VERSION:-unset} — fix the tag or the pin"
    [[ "${MANAGE_TARGET_VERSION:-}" == "$exp_manage" ]] && ok "catalog $cat_tag ships Manage $exp_manage (matches MANAGE_TARGET_VERSION)" \
      || no "catalog $cat_tag ships Manage $exp_manage but MANAGE_TARGET_VERSION=${MANAGE_TARGET_VERSION:-unset} — fix the tag or the pin"
    if [[ -n "${MANAGE_COMPONENT_VERSION:-}" && "${MANAGE_COMPONENT_VERSION}" != "$exp_manage" ]]; then
      no "MANAGE_COMPONENT_VERSION=${MANAGE_COMPONENT_VERSION} != catalog Manage $exp_manage — ManageWorkspace will be rejected by the vmanage webhook"
    fi
    if [[ -n "${SLS_TARGET_VERSION:-}" && "${SLS_TARGET_VERSION}" != "$exp_sls" ]]; then
      warn "SLS_TARGET_VERSION=${SLS_TARGET_VERSION} != catalog SLS $exp_sls"
    fi
  fi
fi

# Manage encryption keys: catch the SILENT break where the config renders fine but Manage can't
# read the DB. autoGenerateEncryptionKeys=true makes Manage MINT NEW keys on every workspace
# (re)create and IGNORE any you provide — fine for a fresh/empty DB, fatal for a REUSED DB (the
# existing data was encrypted with the original keys, so it won't decrypt; the failure only shows
# up much later at Manage server start, not at config/preflight time).
echo "== manage encryption keys =="
istrue(){ [[ "${1:-}" =~ ^([Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|1)$ ]]; }
autogen="${MANAGE_AUTO_GENERATE_ENCRYPTION_KEYS:-true}"
allowcustom="${ALLOW_CUSTOM_MANAGE_CRYPTO_KEYS:-false}"
if istrue "$autogen" && istrue "$allowcustom"; then
  no "MANAGE_AUTO_GENERATE_ENCRYPTION_KEYS=true AND ALLOW_CUSTOM_MANAGE_CRYPTO_KEYS=true is contradictory: Manage will GENERATE new keys and IGNORE the ones you supply, so a reused DB will not decrypt. Set MANAGE_AUTO_GENERATE_ENCRYPTION_KEYS=false to actually use your keys."
elif istrue "$autogen"; then
  warn "MANAGE_AUTO_GENERATE_ENCRYPTION_KEYS=true — OK ONLY for a fresh/empty Manage DB. For a REUSED DB this mints NEW keys that cannot decrypt existing data (silent failure at Manage server start). Reused DB => set false and provide the ORIGINAL MXE_SECURITY_CRYPTO_KEY/CRYPTOX_KEY."
else
  ok "MANAGE_AUTO_GENERATE_ENCRYPTION_KEYS=false (Manage uses Vault-managed keys — deterministic across reinstalls)"
  if istrue "$allowcustom"; then
    if [[ -n "${MANAGE_CRYPTO_KEY:-}" && -n "${MANAGE_CRYPTOX_KEY:-}" ]]; then
      ok "custom Manage crypto keys provided via env (ALLOW_CUSTOM_MANAGE_CRYPTO_KEYS=true)"
    else
      warn "ALLOW_CUSTOM_MANAGE_CRYPTO_KEYS=true but MANAGE_CRYPTO_KEY/CRYPTOX_KEY not exported — they must already be in Vault (preflight-vault.sh verifies format). For a reused DB these MUST be the ORIGINAL keys."
    fi
  fi
fi

echo "== required secret inputs =="
[[ -n "${VAULT_TOKEN:-}" ]] && ok "VAULT_TOKEN exported" || no "export VAULT_TOKEN first"
if [[ "${CHECK_SECRET_INPUTS:-true}" =~ ^([Ff][Aa][Ll][Ss][Ee]|0|[Nn][Oo])$ ]]; then
  warn "static secret input checks skipped; resume mode expects secrets already loaded in Vault"
else
  [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]] && ok "IBM_ENTITLEMENT_KEY exported" || no "export IBM_ENTITLEMENT_KEY"
  [[ -n "${MAS_LICENSE_FILE:-}" && -f "${MAS_LICENSE_FILE:-}" ]] && ok "MAS_LICENSE_FILE exists" || no "MAS_LICENSE_FILE missing or file not found"
  [[ -n "${JDBC_USERNAME:-}" ]] && ok "JDBC_USERNAME exported" || no "export JDBC_USERNAME"
  [[ -n "${JDBC_PASSWORD:-}" ]] && ok "JDBC_PASSWORD exported" || no "export JDBC_PASSWORD"
  [[ -n "${JDBC_URL:-}" ]] && ok "JDBC_URL exported" || no "export JDBC_URL"
  if [[ -n "${JDBC_CA_CRT:-}" ]]; then
    [[ -f "$JDBC_CA_CRT" ]] && ok "JDBC_CA_CRT exists" || no "JDBC_CA_CRT file not found"
  else
    warn "JDBC_CA_CRT unset; OK for non-SSL JDBC"
  fi
fi

echo "== vault =="
oc get pod -n "$VAULT_NS" vault-0 >/dev/null 2>&1 && ok "vault-0 exists" || no "vault-0 missing; run/bootstrap Vault first"
phase="$(oc get pod -n "$VAULT_NS" vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "$phase" == "Running" ]] && ok "vault-0 Running" || warn "vault-0 phase=$phase"

echo
[[ "$fail" -eq 0 ]] && echo "CHECK-ENV: passed." || { echo "CHECK-ENV: fix failures above."; exit 1; }
