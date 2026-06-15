#!/usr/bin/env bash
set -euo pipefail
# Day-0 bootstrap — the ONLY thing you run by hand, ONCE per cluster.
# Usage: ./bootstrap/apply.sh <nroc4|roc4|drroc4>
ENV="${1:?usage: apply.sh <nroc4|roc4|drroc4>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${ARGO_NS:-openshift-gitops}"

echo ">> 1/4 prereqs: CA, RBAC, AppProject, AVP creds+plugin+token-review"
oc apply -f "$ROOT/bootstrap/00-prereqs/"                       # non-recursive: top-level files
for f in "$ROOT"/bootstrap/00-prereqs/repo-creds/*.yaml; do     # real repo creds (skip the example)
  [[ "$f" == *.example.yaml ]] && continue; [[ -e "$f" ]] && oc apply -f "$f"
done

echo ">> 2/4 enable the AVP sidecar on the repo-server (patch the ArgoCD CR)"
oc patch argocd "$NS" -n "$NS" --type merge \
  --patch-file "$ROOT/bootstrap/argocd-cr-avp-sidecar-patch.yaml"
oc rollout restart deploy/openshift-gitops-repo-server -n "$NS"
oc rollout status  deploy/openshift-gitops-repo-server -n "$NS" --timeout=180s || true

echo ">> 3/4 app-of-apps: apply ONLY the root app; ArgoCD generates the 9 child Applications"
helm template platform "$ROOT/gitops" \
  -f "$ROOT/gitops/envs/${ENV}/common.yaml" \
  -f "$ROOT/gitops/envs/${ENV}/values.yaml" \
  --set rootOnly=true | oc apply -f -

echo ">> 4/4 done. The root app (platform-$ENV) now generates + self-heals everything."
echo "   Next for first-time Vault only: ./scripts/setup-vault-platform.sh --store-k8s-secret $ENV"
echo "   Next for normal MAS install/recreate: ./scripts/install-ibm-way.sh --yes <envfile>"
echo "   Watch: oc get applications -n $NS"
