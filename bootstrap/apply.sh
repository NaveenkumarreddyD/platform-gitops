#!/usr/bin/env bash
set -euo pipefail
# Usage: ./bootstrap/apply.sh <env>     e.g. ./bootstrap/apply.sh roc4
ENV="${1:?usage: apply.sh <nroc4|roc4|drroc4>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo ">> prereqs"; oc apply -f "$ROOT/bootstrap/00-prereqs/" || true
echo ">> rendering + applying app-of-apps for $ENV"
helm template mas-aoa "$ROOT/app-of-apps" \
  -f "$ROOT/app-of-apps/common-values.yaml" \
  -f "$ROOT/app-of-apps/${ENV}-values.yaml" | oc apply -f -
echo ">> done. Watch: oc get applications -n openshift-gitops"
