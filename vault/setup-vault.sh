#!/usr/bin/env bash
set -euo pipefail
# Run once against the (unsealed) management Vault. Requires: vault CLI, oc logged into mgmt cluster.
: "${VAULT_ADDR:?export VAULT_ADDR=https://<vault-host>}"
: "${VAULT_TOKEN:?export VAULT_TOKEN=<root-or-admin-token>}"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
REPO_SA="${REPO_SA:-openshift-gitops-repo-server}"
ROLE="${ROLE:-mas-gitops}"
POLICY="${POLICY:-mas-gitops}"

# 1) KV v2 at secret/
vault secrets enable -path=secret -version=2 kv 2>/dev/null || true

# 2) Policy
vault policy write "$POLICY" "$(dirname "$0")/vault-policy-mas-gitops.hcl"

# 3) Kubernetes auth bound to the MANAGEMENT cluster (AVP always runs here)
vault auth enable kubernetes 2>/dev/null || true
KUBE_HOST="$(oc whoami --show-server)"
KUBE_CA="$(oc get cm kube-root-ca.crt -n "$ARGO_NS" -o jsonpath='{.data.ca\.crt}')"
vault write auth/kubernetes/config kubernetes_host="$KUBE_HOST" kubernetes_ca_cert="$KUBE_CA"

# 4) Role: bind the ArgoCD repo-server SA -> policy
vault write auth/kubernetes/role/"$ROLE" \
  bound_service_account_names="$REPO_SA" \
  bound_service_account_namespaces="$ARGO_NS" \
  policies="$POLICY" ttl=1h

echo "Vault configured: KV v2 + k8s auth role '$ROLE' bound to $ARGO_NS/$REPO_SA"
