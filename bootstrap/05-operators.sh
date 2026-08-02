#!/usr/bin/env bash
# 05 — install OLM operators (cert-manager, + grafana-operator if enabled) via the reusable
# workloads/operators chart. Runs EARLY: cert-manager's CRDs must exist before MongoDB
# (component 20 uses Issuer/Certificate) and before MAS. Independent component.
source "$(cd "$(dirname "$0")" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"; require_cluster

if env_feature_enabled certManager || env_feature_enabled grafana; then
  apply_component operators
else
  say "no platform-owned OLM operators selected; verifying the required existing CRDs"
fi

say "waiting for cert-manager CRDs to register (Red Hat cert-manager operator install can take a few minutes)…"
for i in $(seq 1 60); do
  oc get crd certificates.cert-manager.io >/dev/null 2>&1 && break
  sleep 10
done
if oc get crd certificates.cert-manager.io >/dev/null 2>&1; then
  oc wait --for=condition=Established crd/certificates.cert-manager.io --timeout=3m 2>/dev/null || true
  say "cert-manager ready:"; oc get csv -n cert-manager-operator 2>/dev/null | grep -i cert-manager || true
else
  die "cert-manager CRD not present — check: oc get subscription,csv,installplan -n cert-manager-operator"
fi

if env_feature_enabled grafana; then
  say "Grafana is enabled; waiting for the pinned operator CRDs"
  for i in $(seq 1 60); do
    oc get crd grafanas.grafana.integreatly.org >/dev/null 2>&1 && break
    sleep 10
  done
  if ! oc get crd grafanas.grafana.integreatly.org >/dev/null 2>&1; then
    install_plan="$(oc get subscription grafana-operator -n platform-operators \
      -o jsonpath='{.status.installplan.name}' 2>/dev/null || true)"
    echo "Grafana uses Manual InstallPlan approval to prevent an unreviewed channel upgrade."
    [[ -n "$install_plan" ]] && echo "Approve this plan, then rerun this step: oc patch installplan/$install_plan -n platform-operators --type merge -p '{\"spec\":{\"approved\":true}}'"
    die "Grafana CRD not present — inspect: oc get subscription,csv,installplan -n platform-operators"
  fi
  oc wait --for=condition=Established crd/grafanas.grafana.integreatly.org --timeout=3m
  apply_component grafana
fi

say "done. NEXT: ./bootstrap/10-vault.sh $ENV"
