#!/usr/bin/env bash
# 30 — deploy IBM MAS (the account-root, which fans out into the whole MAS tree).
# REFUSES to run until its prerequisites are met: MongoDB Running + the read-only
# Vault preflight passes. This is what replaces installStage — the dependency is enforced,
# not assumed. Set ALLOW_UNVERIFIED=true to bypass the prechecks (not recommended).
source "$(cd "$(dirname "$0")" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"; require_cluster
MONGO_NS="$(env_mongo_ns)"

# The IBM MAS account-root configures its generated applications to use AVP.
# Verify the live sidecar even when ALLOW_UNVERIFIED bypasses data prerequisites.
verify_avp_repo_server

# MAS requires cert-manager (cert_manager_namespace in the suite config).
oc get crd certificates.cert-manager.io >/dev/null 2>&1 \
  || die "cert-manager CRD (certificates.cert-manager.io) not found — run ./bootstrap/05-operators.sh $ENV first"

if [[ "${ALLOW_UNVERIFIED:-false}" != "true" ]]; then
  say "precheck 1/2: MongoDB Running in $MONGO_NS"
  phase="$(oc -n "$MONGO_NS" get mongodbcommunity -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Running" ]] || die "MongoDB is '${phase:-absent}', not Running — run ./bootstrap/20-mongodb.sh $ENV first (or ALLOW_UNVERIFIED=true)"

  say "precheck 2/2: Vault secrets present"
  "$ROOT/bootstrap/12-vault-verify.sh" "$ENV" >/dev/null \
    || die "Vault preflight failed — run ./bootstrap/12-vault-verify.sh $ENV and seed the gaps"
fi

apply_component mas

cat <<EOF

>> IBM MAS account-root applied for '$ENV'. It now generates the cluster/instance tree.
   Watch:  ./scripts/status.sh $ENV
           oc get applications -n $ARGO_NS -l app.kubernetes.io/part-of=mas-platform
   The SLS/DRO harvest jobs will write their registration back into Vault automatically.
EOF
