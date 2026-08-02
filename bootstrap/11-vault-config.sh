#!/usr/bin/env bash
# 11 — configure Vault auth + policies + roles (deterministic, idempotent).
# Run AFTER Vault is initialized and unsealed. Enables kv-v2 + kubernetes auth, writes the AVP
# read policy and the harvest-writer policy (both wildcard the account segment), and binds the
# repo-server + harvest service accounts. Requires the root token: export VAULT_ROOT_TOKEN=...
source "$(cd "$(dirname "$0")" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"; require_cluster
: "${VAULT_ROOT_TOKEN:?export VAULT_ROOT_TOKEN (from vault-init-$ENV.json) before running}"
INSTANCE="$(env_instance)"; SLS_NS="mas-${INSTANCE}-sls"; DRO_NS="ibm-software-central"

say "enabling kv-v2 at secret/ and kubernetes auth (idempotent)"
vault_exec "$VAULT_ROOT_TOKEN" "vault secrets enable -path=secret kv-v2 2>/dev/null || true"
vault_exec "$VAULT_ROOT_TOKEN" "vault auth enable kubernetes 2>/dev/null || true"
vault_exec "$VAULT_ROOT_TOKEN" '
  vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" \
    token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'

say "writing policies mas-gitops (AVP read) and mas-gitops-writer (harvest)"
oc exec -i -n "$VAULT_NS" vault-0 -- sh -c \
  "export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='$VAULT_ROOT_TOKEN'; vault policy write mas-gitops -" \
  < "$ROOT/vault-auth/mas-gitops-policy.hcl"
oc exec -i -n "$VAULT_NS" vault-0 -- sh -c \
  "export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='$VAULT_ROOT_TOKEN'; vault policy write mas-gitops-writer -" \
  < "$ROOT/vault-auth/mas-gitops-writer-policy.hcl"

# Derive the ACTUAL repo-server SA (OpenShift GitOps names it openshift-gitops-argocd-repo-server,
# not openshift-gitops-repo-server) — hardcoding it causes Vault 403 "service account not authorized".
REPO_SA="$(oc get deployment openshift-gitops-repo-server -n "$ARGO_NS" -o jsonpath='{.spec.template.spec.serviceAccountName}')"
[[ -n "$REPO_SA" ]] || die "could not resolve the repo-server service account in $ARGO_NS"
say "binding roles: mas-gitops → $REPO_SA; mas-gitops-writer → SLS/DRO harvest SAs"
vault_exec "$VAULT_ROOT_TOKEN" "vault write auth/kubernetes/role/mas-gitops \
  bound_service_account_names=$REPO_SA \
  bound_service_account_namespaces=$ARGO_NS policies=mas-gitops ttl=20m"
vault_exec "$VAULT_ROOT_TOKEN" "vault write auth/kubernetes/role/mas-gitops-writer \
  bound_service_account_names=postsync-ibm-sls-update-sm-sa,postsync-ibm-dro-update-sm-sa \
  bound_service_account_namespaces=$SLS_NS,$DRO_NS policies=mas-gitops-writer ttl=20m"

say "done. NEXT: seed secrets (INSTALL.md §V.4), then ./bootstrap/12-vault-verify.sh $ENV"
