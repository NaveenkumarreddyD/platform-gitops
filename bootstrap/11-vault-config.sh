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
vault_exec "$VAULT_ROOT_TOKEN" secrets enable -path=secret kv-v2 2>/dev/null || true
vault_exec "$VAULT_ROOT_TOKEN" auth enable kubernetes 2>/dev/null || true
vault_exec "$VAULT_ROOT_TOKEN" write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

say "writing policies mas-gitops (AVP read) and mas-gitops-writer (harvest)"
vault_exec_stdin "$VAULT_ROOT_TOKEN" policy write mas-gitops - \
  < "$ROOT/vault-auth/mas-gitops-policy.hcl"
vault_exec_stdin "$VAULT_ROOT_TOKEN" policy write mas-gitops-writer - \
  < "$ROOT/vault-auth/mas-gitops-writer-policy.hcl"

# Bind the ACTUAL repo-server SA. OpenShift GitOps often leaves serviceAccountName unset on the
# repo-server deployment, so the pod runs as the namespace 'default' SA — hardcoding any other name
# causes Vault 403 "service account not authorized". Read it from the running pod; fall back to default.
REPO_SA="$(repo_server_sa)"
say "binding roles: mas-gitops → SA '$REPO_SA'; mas-gitops-writer → SLS/DRO harvest SAs"
vault_exec "$VAULT_ROOT_TOKEN" write auth/kubernetes/role/mas-gitops \
  bound_service_account_names=$REPO_SA \
  bound_service_account_namespaces=$ARGO_NS policies=mas-gitops ttl=20m
vault_exec "$VAULT_ROOT_TOKEN" write auth/kubernetes/role/mas-gitops-writer \
  bound_service_account_names=postsync-ibm-sls-update-sm-sa,postsync-ibm-dro-update-sm-sa \
  bound_service_account_namespaces=$SLS_NS,$DRO_NS policies=mas-gitops-writer ttl=20m

say "done. NEXT: seed secrets (INSTALL.md §V.4), then ./bootstrap/12-vault-verify.sh $ENV"
