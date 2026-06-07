#!/usr/bin/env bash
set -euo pipefail
oc get application -n openshift-gitops || true
oc get pods -n vault || true
oc get route -n vault || true
POD="$(oc get pod -n openshift-gitops | awk '/repo-server/ {print $1; exit}')"
echo "repo-server pod: ${POD}"
oc get pod "${POD}" -n openshift-gitops -o jsonpath='{.spec.containers[*].name}{"\n"}'
oc exec -n openshift-gitops "${POD}" -c avp-helm -- argocd-vault-plugin version || true
oc exec -n openshift-gitops "${POD}" -c avp-helm -- helm version || true
