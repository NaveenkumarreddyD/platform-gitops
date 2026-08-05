#!/usr/bin/env bash
# 10 — deploy Vault (the secrets backend). Independent component; couples to nothing.
# After this, Vault is running but EMPTY and SEALED. Initializing, unsealing and seeding it is a
# manual operator step (the unseal shares must never live in the cluster) — see INSTALL.md §V.
source "$(cd "$(dirname "$0")" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"; require_cluster

apply_component vault

# --- Deterministic serving cert (SAN = vault-active.vault.svc) --------------------------------
# The Vault chart annotates MULTIPLE services (vault, vault-active, vault-standby) with the same
# serving-cert-secret-name, so OpenShift service-ca non-deterministically issues vault-tls for one
# of them — we have observed all three (vault, vault-active, vault-standby) across deploys. Every
# consumer (VAULT_TLS_SERVER_NAME, AVP, harvest, SLS/DRO, INSTALL.md) expects vault-active, so we
# enforce it defensively: strip the annotation from EVERY vault service, put it on ONLY
# vault-active, delete vault-tls, and wait for service-ca to reissue a cert whose SAN is exactly
# vault-active.vault.svc. Done BEFORE waiting for pods (they mount vault-tls → ContainerCreating
# until it exists). ignoreDifferences in the Application keeps selfHeal from re-adding it elsewhere.
pin_serving_cert() {
  say "pinning the serving cert to vault-active (deterministic vault-active.vault.svc)…"
  for i in $(seq 1 30); do oc get svc vault-active -n "$VAULT_NS" >/dev/null 2>&1 && break; sleep 5; done
  # 1) remove the annotation from ALL vault services (whatever the chart set)
  for svc in $(oc get svc -n "$VAULT_NS" -o name 2>/dev/null); do
    oc annotate "$svc" -n "$VAULT_NS" service.beta.openshift.io/serving-cert-secret-name- >/dev/null 2>&1 || true
  done
  # 2) request it on ONLY vault-active
  oc annotate svc vault-active -n "$VAULT_NS" \
    service.beta.openshift.io/serving-cert-secret-name=vault-tls --overwrite >/dev/null 2>&1 || true
  # 3) drop any existing vault-tls so service-ca reissues for vault-active only
  oc delete secret vault-tls -n "$VAULT_NS" >/dev/null 2>&1 || true
  # 4) wait until vault-tls exists AND its SAN is vault-active
  for i in $(seq 1 30); do
    if oc get secret vault-tls -n "$VAULT_NS" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
         | base64 -d 2>/dev/null | openssl x509 -noout -text 2>/dev/null \
         | grep -q 'DNS:vault-active\.vault\.svc'; then
      say "  vault-tls SAN OK: vault-active.vault.svc"; return 0
    fi
    sleep 5
  done
  say "  WARNING: vault-tls did not converge to vault-active.vault.svc — check service-ca"
  return 1
}
pin_serving_cert
# bounce any pods so they mount the freshly-issued cert (safe: not yet initialized)
oc delete pod -n "$VAULT_NS" -l app.kubernetes.io/name=vault --ignore-not-found >/dev/null 2>&1 || true

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
