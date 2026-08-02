#!/usr/bin/env bash
# 10 — deploy Vault (the secrets backend). Independent component; couples to nothing.
# After this, Vault is running but EMPTY and SEALED. Initializing, unsealing and seeding it is a
# manual operator step (the unseal shares must never live in the cluster) — see INSTALL.md §V.
source "$(cd "$(dirname "$0")" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"; require_cluster

apply_component vault

say "waiting for the Vault statefulset to appear…"
oc rollout status statefulset/vault -n "$VAULT_NS" --timeout=5m 2>/dev/null || true
oc get pods -n "$VAULT_NS" -l app.kubernetes.io/name=vault 2>/dev/null || true

# Reencrypt route must trust the backend's service-serving cert. Inject the runtime service CA into
# the route's destinationCACertificate (the chart can't, and it's per-cluster). selfHeal ignores it.
say "wiring the Vault UI route to trust the backend (service CA)…"
for i in $(seq 1 30); do
  oc get route vault -n "$VAULT_NS" >/dev/null 2>&1 \
    && oc get cm service-ca-bundle -n "$VAULT_NS" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null | grep -q 'BEGIN CERTIFICATE' && break
  sleep 5
done
CA="$(oc get cm service-ca-bundle -n "$VAULT_NS" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null)"
if [[ -n "$CA" ]] && oc get route vault -n "$VAULT_NS" >/dev/null 2>&1; then
  oc patch route vault -n "$VAULT_NS" --type merge \
    -p "$(jq -n --arg ca "$CA" '{spec:{tls:{destinationCACertificate:$ca}}}')" >/dev/null 2>&1 \
    && say "  route destinationCACertificate set (service CA)" \
    || say "  NOTE: could not patch the route yet; re-run after the route exists (UI only, not blocking)"
else
  say "  NOTE: route/service-ca not ready yet — the UI route CA can be patched later (not blocking)"
fi

cat <<EOF

>> Vault deployed for '$ENV'.  Route: https://$(env_vault_host)

   NEXT (manual, INSTALL.md §V — cannot be scripted, the unseal shares are secret):
     1. Initialize   : vault operator init  (save vault-init-$ENV.json to escrow)
     2. Unseal       : apply 3 shares to vault-0/1/2
     3. Configure    : ./bootstrap/11-vault-config.sh $ENV   (k8s auth + policies + roles)
     4. Seed secrets : INSTALL.md §V.4 (vkv puts into $(vault_path) and $(vault_cluster_path))
     5. Verify       : ./bootstrap/12-vault-verify.sh $ENV
   THEN: ./bootstrap/20-mongodb.sh $ENV
EOF
