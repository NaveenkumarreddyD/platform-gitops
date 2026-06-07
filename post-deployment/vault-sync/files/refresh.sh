#!/usr/bin/env bash
# Runs LAST (oc image). After Vault is updated, force a hard refresh of the
# consuming ArgoCD Application(s) so AVP re-reads Vault on the next render —
# this replaces the manual `oc annotate application … refresh=hard`.
set -euo pipefail
NS="${ARGO_NS:-openshift-gitops}"
[ -n "${REFRESH_APPS:-}" ] || { echo ">> no consumer apps to refresh"; exit 0; }
for app in $REFRESH_APPS; do
  if oc get application "$app" -n "$NS" >/dev/null 2>&1; then
    oc annotate application "$app" -n "$NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    echo ">> hard-refreshed $app"
  else
    echo ">> (consumer app $app not present yet — skipping; it will pick up Vault on first render)"
  fi
done
