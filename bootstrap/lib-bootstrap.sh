#!/usr/bin/env bash
# Shared helpers for the decoupled component bootstrap scripts (00→30).
# Each component (vault, mongodb, mas) is an INDEPENDENT Argo CD Application rendered from the
# gitops/ chart with --set component=<name> and applied directly. There is no app-of-apps parent
# and no installStage; components couple only through Vault secret paths. Ordering is enforced by
# each script asserting its own prerequisite (e.g. 30-mas refuses to run until Vault is verified
# and MongoDB is Running), so you cannot silently skip a dependency.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
VAULT_NS="${VAULT_NS:-vault}"

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

# vault_path : secret/<account>/<cluster>/<instance>  (matches gitops.path helper + config repo).
vault_path(){ echo "secret/$(env_account)/$(env_cluster)/$(env_instance)"; }
vault_cluster_path(){ echo "secret/$(env_account)/$(env_cluster)"; }

# render_component <component> : emit the component's manifests (runs validate.yaml guards too).
render_component(){
  helm template platform "$ROOT/gitops" -f "$COMMON" -f "$VALUES" --set component="$1"
}
# apply_component <component> : render + oc apply.
apply_component(){
  say "rendering + applying component '$1' to $ARGO_NS"
  render_component "$1" | oc apply -f -
}

# vault_exec <token> <args...> : run a vault CLI command inside vault-0 (VAULT_ADDR set for you).
vault_exec(){ local tok="$1"; shift; oc exec -n "$VAULT_NS" vault-0 -- sh -c \
  "export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='$tok'; $*"; }
