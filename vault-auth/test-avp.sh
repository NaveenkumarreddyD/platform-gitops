#!/usr/bin/env bash
set -euo pipefail
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-openshift-gitops}"
VAULT_ADDR_IN_POD="${VAULT_ADDR_IN_POD:-http://127.0.0.1:8200}"
VAULT_ADDR_FOR_AVP="${VAULT_ADDR_FOR_AVP:-http://vault-active.vault.svc.cluster.local:8200}"
AVP_ROLE="${AVP_ROLE:-mas-gitops}"
if [[ -z "${VAULT_TOKEN:-}" ]]; then echo "ERROR: export VAULT_TOKEN first" >&2; exit 1; fi
oc exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- sh -c "export VAULT_ADDR=${VAULT_ADDR_IN_POD}; export VAULT_TOKEN='${VAULT_TOKEN}'; vault kv put secret/mas/test-avp message='hello-from-vault'"
POD="$(oc get pod -n "${ARGO_NAMESPACE}" | awk '/repo-server/ {print $1; exit}')"
oc exec -n "${ARGO_NAMESPACE}" "${POD}" -c avp-helm -- sh -c "
export AVP_TYPE=vault
export AVP_AUTH_TYPE=k8s
export AVP_K8S_ROLE=${AVP_ROLE}
export VAULT_ADDR=${VAULT_ADDR_FOR_AVP}
cat <<'EOF' | argocd-vault-plugin generate -
apiVersion: v1
kind: ConfigMap
metadata:
  name: avp-test
  namespace: openshift-gitops
data:
  message: \"<path:secret/data/mas/test-avp#message>\"
EOF
"
