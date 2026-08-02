#!/usr/bin/env bash
# Shared helpers for the decoupled component bootstrap scripts (00→30).
# Each component (vault, MongoDB operator/instance, mas) is an independent Argo CD Application rendered from the
# gitops/ chart with --set component=<name> and applied directly. There is no app-of-apps parent
# and no installStage; components couple only through Vault secret paths. Ordering is enforced by
# each script asserting its own prerequisite (e.g. 30-mas refuses to run until Vault is verified
# and MongoDB is Running), so you cannot silently skip a dependency.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
VAULT_NS="${VAULT_NS:-vault}"
VAULT_ADDR_IN_POD="${VAULT_ADDR_IN_POD:-https://127.0.0.1:8200}"
VAULT_CACERT_IN_POD="${VAULT_CACERT_IN_POD:-/vault/userconfig/service-ca-bundle/service-ca.crt}"
VAULT_TLS_SERVER_NAME="${VAULT_TLS_SERVER_NAME:-vault-active.vault.svc}"

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo ">> $*"; }

# resolve_env <env> : sets ENV, COMMON, VALUES and asserts they exist.
resolve_env(){
  ENV="${1:?usage: $(basename "$0") <env>   (e.g. doc4)}"
  COMMON="$ROOT/gitops/envs/$ENV/common.yaml"
  VALUES="$ROOT/gitops/envs/$ENV/values.yaml"
  [[ -f "$COMMON" && -f "$VALUES" ]] || die "env files gitops/envs/$ENV/{common,values}.yaml not found"
}

# require_cluster : assert oc login + OpenShift GitOps present.
require_cluster(){
  command -v oc   >/dev/null 2>&1 || die "oc not found in PATH"
  command -v helm >/dev/null 2>&1 || die "helm not found in PATH"
  oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift (oc login ...)"
  oc get argocd "$ARGO_NS" -n "$ARGO_NS" >/dev/null 2>&1 \
    || die "OpenShift GitOps ArgoCD '$ARGO_NS' not found — run ./bootstrap/00-prereqs.sh $ENV first"
}

# cfg <file> <key> : read a top-level scalar (grep-based, matches preflight-consistency.sh).
cfg(){ grep -E "^$2:" "$1" 2>/dev/null | head -1 | sed -E 's/^[^:]*: *//; s/[ "].*//'; }
# inline <file> <regex-after-colon> : read a value from an inline-flow map, e.g. vault: { host: X }.
inline(){ grep -oE "$2: *[A-Za-z0-9._:/-]+" "$1" 2>/dev/null | head -1 | sed -E 's/.*: *//'; }

# env identity (account defaults to the global 'mas' when not overridden per-env).
env_account(){ local a; a="$(grep -oE 'account: *\{ *id: *[A-Za-z0-9._-]+' "$COMMON" | head -1 | sed -E 's/.*id: *//')"; echo "${a:-mas}"; }
env_cluster(){ cfg "$COMMON" clusterId; }
env_instance(){ cfg "$VALUES" instanceId; }
env_vault_host(){ inline "$COMMON" host; }
env_mongo_ns(){ grep -oE 'namespace: *[A-Za-z0-9._-]+' "$VALUES" | head -1 | sed -E 's/.*: *//'; }

# env_feature_enabled <name> : resolve enable.<name>, preferring the environment override.
env_feature_enabled(){
  local key="$1" value
  value="$(awk -v key="$key" '
    /^enable:[[:space:]]*$/ { inside=1; next }
    inside && /^[^[:space:]]/ { exit }
    inside && $1 == key ":" { print tolower($2); exit }
  ' "$VALUES")"
  if [[ -z "$value" ]]; then
    value="$(awk -v key="$key" '
      /^enable:[[:space:]]*$/ { inside=1; next }
      inside && /^[^[:space:]]/ { exit }
      inside && $1 == key ":" { print tolower($2); exit }
    ' "$ROOT/gitops/values.yaml")"
  fi
  [[ "$value" == "true" ]]
}

# vault_path : secret/<account>/<cluster>/<instance>  (matches gitops.path helper + config repo).
vault_path(){ echo "secret/$(env_account)/$(env_cluster)/$(env_instance)"; }
vault_cluster_path(){ echo "secret/$(env_account)/$(env_cluster)"; }

# render_component <component> : emit the component's manifests (runs validate.yaml guards too).
render_component(){
  local component="$1"; shift
  helm template platform "$ROOT/gitops" -f "$COMMON" -f "$VALUES" --set component="$component" "$@"
}
# apply_component <component> : render + oc apply.
apply_component(){
  local component="$1"; shift
  say "rendering + applying component '$component' to $ARGO_NS"
  render_component "$component" "$@" | oc apply -f -
}

# vault_exec <token-or-empty> <vault args...> : TLS-authenticated Vault CLI in vault-0.
vault_exec(){
  local tok="$1"; shift
  local -a vault_env=(
    "VAULT_ADDR=$VAULT_ADDR_IN_POD"
    "VAULT_CACERT=$VAULT_CACERT_IN_POD"
    "VAULT_TLS_SERVER_NAME=$VAULT_TLS_SERVER_NAME"
  )
  [[ -n "$tok" ]] && vault_env+=("VAULT_TOKEN=$tok")
  oc exec -n "$VAULT_NS" vault-0 -- env "${vault_env[@]}" vault "$@"
}

vault_exec_stdin(){
  local tok="$1"; shift
  oc exec -i -n "$VAULT_NS" vault-0 -- env \
    "VAULT_ADDR=$VAULT_ADDR_IN_POD" \
    "VAULT_CACERT=$VAULT_CACERT_IN_POD" \
    "VAULT_TLS_SERVER_NAME=$VAULT_TLS_SERVER_NAME" \
    "VAULT_TOKEN=$tok" vault "$@"
}

# OpenShift GitOps may run repo-server with the namespace default ServiceAccount.
repo_server_sa(){
  local sa
  sa="$(oc get pods -n "$ARGO_NS" -l app.kubernetes.io/name=openshift-gitops-repo-server \
    -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null || true)"
  [[ -n "$sa" ]] || sa="$(oc get deployment openshift-gitops-repo-server -n "$ARGO_NS" \
    -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
  echo "${sa:-default}"
}

# Log in through the same read-only Kubernetes auth role used by the AVP sidecar.
vault_k8s_token(){
  local sa jwt
  sa="$(repo_server_sa)"
  jwt="$(oc create token "$sa" -n "$ARGO_NS" --duration=10m)" \
    || die "could not create a short-lived token for $ARGO_NS/$sa"
  vault_exec "" write -field=token auth/kubernetes/login role=mas-gitops jwt="$jwt"
}
