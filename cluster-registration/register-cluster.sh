#!/usr/bin/env bash
set -euo pipefail
# Register a Target (spoke) cluster in the MANAGEMENT ArgoCD.
# Usage: ./register-cluster.sh <cluster-name> <kube-context>
# Requires: argocd CLI logged into the management ArgoCD, and a kubeconfig context for the spoke.
NAME="${1:?cluster name, e.g. drroc4}"
CTX="${2:?kube-context for the spoke cluster}"

# argocd cluster add creates a SA on the spoke + stores its credentials as a cluster Secret on mgmt.
argocd cluster add "$CTX" --name "$NAME" --yes

echo
echo "Registered '$NAME'. Confirm the server URL ArgoCD stored:"
argocd cluster list | grep -E "NAME|$NAME" || true
echo
echo ">>> Put that EXACT server URL into mas/$NAME/ibm-mas-cluster-base.yaml as cluster.url <<<"
