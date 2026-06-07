#!/usr/bin/env bash
set -euo pipefail
# Day-0 seed, run ONCE per cluster.   Usage: ./bootstrap/apply.sh <nroc4|roc4|drroc4>
ENV="${1:?usage: apply.sh <nroc4|roc4|drroc4>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo ">> prereqs (GitLab CA, Argo RBAC, repo creds, AppProject)"
oc apply -f "$ROOT/bootstrap/00-prereqs/"
echo ">> seeding the self-managing root + all Applications for $ENV"
helm template platform "$ROOT/gitops" \
  -f "$ROOT/gitops/common-values.yaml" \
  -f "$ROOT/gitops/${ENV}-common-values.yaml" \
  -f "$ROOT/gitops/${ENV}-values.yaml" | oc apply -f -
echo ">> done. ArgoCD now owns it. Watch: oc get applications -n openshift-gitops"
