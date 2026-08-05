#!/usr/bin/env bash
# 10 — deploy Vault (the secrets backend). Independent component; couples to nothing.
# Vault runs NON-TLS (HTTP) — see gitops/templates/secrets-vault/10-vault-server.yaml. After this,
# Vault is running but EMPTY and SEALED. Initializing, unsealing and seeding it is a manual operator
# step (the unseal shares must never live in the cluster) — see INSTALL.md §V.
source "$(cd "$(dirname "$0")" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"; require_cluster

apply_component vault

say "waiting for the Vault statefulset to appear…"
oc rollout status statefulset/vault -n "$VAULT_NS" --timeout=5m 2>/dev/null || true
oc get pods -n "$VAULT_NS" -l app.kubernetes.io/name=vault 2>/dev/null || true

cat <<EOF

>> Vault deployed for '$ENV' (HTTP).  Route: https://$(env_vault_host)  (router does edge TLS)

   NEXT (manual, INSTALL.md §V — cannot be scripted, the unseal shares are secret):
     1. Initialize   : vault operator init  (save vault-init-$ENV.json to escrow)
     2. Unseal       : apply 3 shares to vault-0/1/2
     3. Configure    : ./bootstrap/11-vault-config.sh $ENV   (k8s auth + policies + roles)
     4. Seed secrets : INSTALL.md §V.4 (vkv puts into $(vault_path) and $(vault_cluster_path))
     5. Verify       : ./bootstrap/12-vault-verify.sh $ENV
   THEN: ./bootstrap/20-mongodb.sh $ENV

   Vault CLI env (in-pod): VAULT_ADDR=http://127.0.0.1:8200   (no VAULT_CACERT / VAULT_TLS_SERVER_NAME)
EOF
