#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# Configure Vault Kubernetes auth for AVP (role: mas-gitops).
#
# DEFAULT = NO-EXPIRY mode: Vault validates incoming SA tokens using its OWN pod
# ServiceAccount token (kubelet-rotated), so there is NO static token_reviewer_jwt
# to expire. Re-running this is safe/idempotent and never re-introduces the 24h
# breakage. The Vault server SA is granted system:auth-delegator to do TokenReview.
#
# Legacy (static reviewer JWT, expires in 24h) is available with STATIC_REVIEWER_JWT=1.
#
# RUN:  export VAULT_TOKEN=<root> ; ./setup-vault-auth.sh
# ---------------------------------------------------------------------------
NS_GITOPS="${NAMESPACE_OPENSHIFT_GITOPS:-openshift-gitops}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_SA="${VAULT_SA:-vault}"                 # the Vault server ServiceAccount (the reviewer)
VAULT_ADDR_IN_POD="${VAULT_ADDR_IN_POD:-http://127.0.0.1:8200}"
VAULT_ROLE="${VAULT_ROLE:-mas-gitops}"
VAULT_POLICY="${VAULT_POLICY:-mas-gitops}"
# The SA AVP logs in as = whatever SA the repo-server pod actually runs as. This VARIES by
# OpenShift GitOps version/config (commonly 'default'; sometimes 'openshift-gitops-argocd-repo-server').
# Auto-detect it so the Vault role always binds the real SA. Override with REPO_SA=... if needed.
REPO_SA="${REPO_SA:-$(oc get pods -n "$NS_GITOPS" -l app.kubernetes.io/name=openshift-gitops-repo-server -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null)}"
REPO_SA="${REPO_SA:-openshift-gitops-argocd-repo-server}"   # fallback if detection returns nothing
ROLE_TTL="${ROLE_TTL:-1h}"
STATIC_REVIEWER_JWT="${STATIC_REVIEWER_JWT:-0}"
[[ -z "${VAULT_TOKEN:-}" ]] && { echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; }

# locate the policy file whether run from vault-auth/ or scripts/
HERE="$(cd "$(dirname "$0")" && pwd)"
POLICY="$HERE/mas-gitops-policy.hcl"; [[ -f "$POLICY" ]] || POLICY="$HERE/../vault-auth/mas-gitops-policy.hcl"
[[ -f "$POLICY" ]] || { echo "ERROR: mas-gitops-policy.hcl not found"; exit 1; }

vx(){ oc exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- sh -c \
  "export VAULT_ADDR=$VAULT_ADDR_IN_POD VAULT_TOKEN='$VAULT_TOKEN'; $*"; }

# KV v2 + policy + auth method
vx "vault secrets enable -path=secret kv-v2 || true"
oc cp "$POLICY" "$VAULT_NAMESPACE/$VAULT_POD:/tmp/mas-gitops-policy.hcl"
vx "vault policy write $VAULT_POLICY /tmp/mas-gitops-policy.hcl"
vx "vault auth enable kubernetes || true"

# The reviewer needs TokenReview permission.
if [[ "$STATIC_REVIEWER_JWT" == "1" ]]; then
  echo ">> LEGACY mode: static 24h reviewer JWT (will expire — prefer the default)."
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  oc create token "$REPO_SA" -n "$NS_GITOPS" --duration=24h > "$TMP/reviewer.jwt"
  oc get cm kube-root-ca.crt -n "$NS_GITOPS" -o jsonpath='{.data.ca\.crt}' > "$TMP/kube-ca.crt"
  oc cp "$TMP/reviewer.jwt" "$VAULT_NAMESPACE/$VAULT_POD:/tmp/reviewer.jwt"
  oc cp "$TMP/kube-ca.crt"  "$VAULT_NAMESPACE/$VAULT_POD:/tmp/kube-ca.crt"
  oc adm policy add-cluster-role-to-user system:auth-delegator "system:serviceaccount:${NS_GITOPS}:${REPO_SA}" || true
  vx "vault write auth/kubernetes/config token_reviewer_jwt=\"\$(cat /tmp/reviewer.jwt)\" kubernetes_host='$(oc whoami --show-server)' kubernetes_ca_cert=@/tmp/kube-ca.crt"
else
  echo ">> NO-EXPIRY mode: Vault uses its own pod SA token for TokenReview (auto-rotated)."
  # grant the Vault server SA permission to review tokens
  oc adm policy add-cluster-role-to-user system:auth-delegator "system:serviceaccount:${VAULT_NAMESPACE}:${VAULT_SA}" || true
  # NO token_reviewer_jwt -> Vault uses /var/run/secrets/.../token in its own pod (rotated).
  vx "vault write auth/kubernetes/config \
        kubernetes_host=https://kubernetes.default.svc \
        kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
        disable_iss_validation=true"
fi

# the AVP role: which SA may log in, which policy it gets, token TTL
vx "vault write auth/kubernetes/role/$VAULT_ROLE \
      bound_service_account_names='$REPO_SA' \
      bound_service_account_namespaces='$NS_GITOPS' \
      policies='$VAULT_POLICY' ttl=$ROLE_TTL"
vx "vault read auth/kubernetes/role/$VAULT_ROLE"

# ---- WRITER role for the vault-registration-sync Jobs (SLS/DRO harvest) ----
# Narrow write access to ONLY the runtime registration secrets. Skip with WRITER_ROLE=0.
if [[ "${WRITER_ROLE:-1}" == "1" ]]; then
  WRITER_POLICY="${WRITER_POLICY:-mas-gitops-writer}"
  WRITER_VAULT_ROLE="${WRITER_VAULT_ROLE:-mas-gitops-writer}"
  # both sync apps use the writer role: wave-50 (sls/dro) + wave-28 (mongo)
  WRITER_SA="${WRITER_SA:-vault-registration-sync}"
  WPOL="$HERE/mas-gitops-writer-policy.hcl"; [[ -f "$WPOL" ]] || WPOL="$HERE/../vault-auth/mas-gitops-writer-policy.hcl"
  if [[ -f "$WPOL" ]]; then
    oc cp "$WPOL" "$VAULT_NAMESPACE/$VAULT_POD:/tmp/mas-gitops-writer-policy.hcl"
    vx "vault policy write $WRITER_POLICY /tmp/mas-gitops-writer-policy.hcl"
    vx "vault write auth/kubernetes/role/$WRITER_VAULT_ROLE \
          bound_service_account_names='$WRITER_SA' \
          bound_service_account_namespaces='$NS_GITOPS' \
          policies='$WRITER_POLICY' ttl=10m"
    echo ">> writer role '$WRITER_VAULT_ROLE' bound to SA '$WRITER_SA' (policy: $WRITER_POLICY)"
  else
    echo ">> WARN: mas-gitops-writer-policy.hcl not found; skipped writer role."
  fi
fi
echo ">> done. Restart repo-server + run vault-auth/test-avp.sh to verify."
