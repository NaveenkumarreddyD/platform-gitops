#!/usr/bin/env bash
# 05 — install OLM operators (cert-manager, + grafana-operator if enabled) via the reusable
# workloads/operators chart. Runs EARLY: cert-manager's CRDs must exist before MongoDB
# (component 20 uses Issuer/Certificate) and before MAS. Independent component.
source "$(cd "$(dirname "$0")" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"; require_cluster

apply_component operators

say "waiting for cert-manager CRDs to register (Red Hat cert-manager operator install can take a few minutes)…"
for i in $(seq 1 60); do
  oc get crd certificates.cert-manager.io >/dev/null 2>&1 && break
  sleep 10
done
if oc get crd certificates.cert-manager.io >/dev/null 2>&1; then
  oc wait --for=condition=Established crd/certificates.cert-manager.io --timeout=3m 2>/dev/null || true
  say "cert-manager ready:"; oc get csv -n cert-manager-operator 2>/dev/null | grep -i cert-manager || true
else
  say "cert-manager CRD not present yet — check the operator install:"
  echo "     oc get subscription,csv,installplan -n cert-manager-operator"
fi

say "done. NEXT: ./bootstrap/10-vault.sh $ENV"
