#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# Harvest SLS registration into Vault — the Vault replacement for the chart's
# AWS-only postsync job (100-ibm-sls/templates/07-postsync-update-sm_Job.yaml,
# which begins `$aws_secret := "aws"` and writes to AWS Secrets Manager). On
# Vault that job is a no-op, so the sls#registration_key / url / ca.crt that
# the SlsCfg (sls-system) needs are never populated automatically.
#
# Run this ONCE per instance AFTER the LicenseService reports Ready, then sync
# sls-system. SKIP this entirely if you point the instance at a centralized,
# already-licensed SLS (just load that SLS's registration_key/url/ca by hand).
#
# USAGE: ./harvest-sls-registration.sh <cluster.env>
# ---------------------------------------------------------------------------
ENVFILE="${1:?usage: harvest-sls-registration.sh <env file>}"
set -a; . "$ENVFILE"; set +a
VAULT_NS="${VAULT_NS:-vault}"; VAULT_POD="${VAULT_POD:-vault-0}"
VADDR="${VADDR:-http://127.0.0.1:8200}"; KV="${KV_MOUNT:-secret}"
: "${ACCOUNT_ID:?}"; : "${CLUSTER_ID:?}"; : "${INSTANCE_ID:?}"
[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; }
SLS_NS="${SLS_NS:-mas-${INSTANCE_ID}-sls}"
IP="$ACCOUNT_ID/$CLUSTER_ID/$INSTANCE_ID"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo ">> reading SLS registration from namespace $SLS_NS"

# 1) registration key — try the LicenseService CR status first, then the well-known ConfigMap.
RK="$(oc get licenseservice -n "$SLS_NS" -o jsonpath='{.items[0].status.registrationKey}' 2>/dev/null || true)"
[[ -z "$RK" ]] && RK="$(oc get cm sls-suite-registration -n "$SLS_NS" -o jsonpath='{.data.registrationKey}' 2>/dev/null || true)"
[[ -z "$RK" ]] && RK="$(oc get cm -n "$SLS_NS" -o jsonpath='{range .items[*]}{.data.registrationKey}{"\n"}{end}' 2>/dev/null | grep -m1 . || true)"
[[ -z "$RK" ]] && { echo "ERROR: could not find SLS registrationKey in $SLS_NS. Is LicenseService Ready?"; \
  echo "       oc get licenseservice,cm -n $SLS_NS"; exit 1; }

# 2) URL — internal service is the robust choice for in-cluster MAS.
URL="${SLS_URL_OVERRIDE:-https://sls.${SLS_NS}.svc.cluster.local}"
RT="$(oc get route -n "$SLS_NS" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
[[ -n "$RT" ]] && echo "   (note: external route also exists: https://$RT ; using internal svc URL)"

# 3) CA — pull from the SLS serving TLS secret (try common names/keys).
CA=""
for s in sls-cert sls-tls $(oc get secret -n "$SLS_NS" -o name 2>/dev/null | grep -iE 'sls.*(cert|tls)' | sed 's#secret/##'); do
  for k in ca.crt tls.crt; do
    oc get secret "$s" -n "$SLS_NS" -o jsonpath="{.data.${k//./\\.}}" 2>/dev/null | base64 -d > "$TMP/ca.pem" 2>/dev/null || true
    grep -q 'BEGIN CERTIFICATE' "$TMP/ca.pem" 2>/dev/null && { CA="$TMP/ca.pem"; break 2; }
  done
done
[[ -z "$CA" ]] && { echo "WARN: no SLS CA secret found; writing registration_key+url only."; : > "$TMP/ca.pem"; CA="$TMP/ca.pem"; }

echo ">> registration_key=${RK:0:8}…  url=$URL  ca=$( [[ -s "$CA" ]] && echo PEM || echo empty )"
oc cp "$CA" "$VAULT_NS/$VAULT_POD:/tmp/sls-ca.pem"

# Full put is correct here: this writes the whole sls secret in one shot.
oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c \
  "export VAULT_ADDR=$VADDR VAULT_TOKEN='$VAULT_TOKEN'; \
   vault kv put $KV/$IP/sls registration_key='$RK' url='$URL' ca.crt=@/tmp/sls-ca.pem"
oc exec -n "$VAULT_NS" "$VAULT_POD" -- sh -c "rm -f /tmp/sls-ca.pem" || true

echo ">> wrote $KV/$IP/sls. Now hard-refresh the repo-server cache and sync sls-system:"
echo "   oc rollout restart deploy/openshift-gitops-repo-server -n openshift-gitops"
echo "   oc annotate application ${INSTANCE_ID}-sls-system.${CLUSTER_ID} -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite"
