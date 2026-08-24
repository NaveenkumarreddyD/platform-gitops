#!/usr/bin/env bash
# Shared helpers for the ordered platform bootstrap scripts (00 -> 30).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
AWS_AUTH_CONFIGMAP="${AWS_AUTH_CONFIGMAP:-aws-secrets-manager-auth}"
AWS_IDENTITY_SECRET="${AWS_IDENTITY_SECRET:-aws-rolesanywhere-avp}"
AWS_PUBLISHER_AUTH_CONFIGMAP="${AWS_PUBLISHER_AUTH_CONFIGMAP:-aws-secrets-manager-publisher-auth}"
AWS_PUBLISHER_IDENTITY_SECRET="${AWS_PUBLISHER_IDENTITY_SECRET:-aws-rolesanywhere-publisher}"

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo ">> $*"; }

resolve_env(){
  ENV="${1:?usage: $(basename "$0") <env>   (e.g. doc4)}"
  COMMON="$ROOT/gitops/envs/$ENV/common.yaml"
  VALUES="$ROOT/gitops/envs/$ENV/values.yaml"
  [[ -f "$COMMON" && -f "$VALUES" ]] || die "env files gitops/envs/$ENV/{common,values}.yaml not found"
}

require_cluster(){
  command -v oc >/dev/null 2>&1 || die "oc not found in PATH"
  command -v helm >/dev/null 2>&1 || die "helm not found in PATH"
  oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift (oc login ...)"
  oc get argocd "$ARGO_NS" -n "$ARGO_NS" >/dev/null 2>&1 || die "OpenShift GitOps ArgoCD '$ARGO_NS' not found - run ./bootstrap/00-prereqs.sh $ENV first"
}

cfg(){ grep -E "^$2:" "$1" 2>/dev/null | head -1 | sed -E 's/^[^:]*: *//; s/[ "].*//'; }
env_account(){
  local value
  value="$(grep -oE 'account: *\{ *id: *[A-Za-z0-9._-]+' "$COMMON" | head -1 | sed -E 's/.*id: *//')"
  echo "${value:-mas}"
}
env_cluster(){ cfg "$COMMON" clusterId; }
env_instance(){ cfg "$VALUES" instanceId; }
env_mongo_ns(){ grep -oE 'namespace: *[A-Za-z0-9._-]+' "$VALUES" | head -1 | sed -E 's/.*: *//'; }
aws_cluster_path(){ echo "mas/$(env_account)/$(env_cluster)"; }
aws_instance_path(){ echo "$(aws_cluster_path)/$(env_instance)"; }

env_feature_enabled(){
  local key="$1" value
  value="$(awk -v key="$key" '/^enable:[[:space:]]*$/ { inside=1; next } inside && /^[^[:space:]]/ { exit } inside && $1 == key ":" { print tolower($2); exit }' "$VALUES")"
  if [[ -z "$value" ]]; then
    value="$(awk -v key="$key" '/^enable:[[:space:]]*$/ { inside=1; next } inside && /^[^[:space:]]/ { exit } inside && $1 == key ":" { print tolower($2); exit }' "$ROOT/gitops/values.yaml")"
  fi
  [[ "$value" == "true" ]]
}

render_component(){
  local component="$1"; shift
  helm template platform "$ROOT/gitops" -f "$COMMON" -f "$VALUES" --set component="$component" "$@"
}

apply_component(){
  local component="$1"; shift
  say "rendering and applying component '$component' to $ARGO_NS"
  render_component "$component" "$@" | oc apply -f -
}

validate_rolesanywhere_identity_inputs(){
  local configmap_name="${1:?configmap name required}"
  local secret_name="${2:?secret name required}"
  local purpose="${3:?identity purpose required}"
  local key value
  oc get configmap "$configmap_name" -n "$ARGO_NS" >/dev/null 2>&1 || die "ConfigMap $ARGO_NS/$configmap_name is missing for $purpose (see INSTALL.md)"
  for key in region roleArn profileArn trustAnchorArn roleSessionName; do
    value="$(oc get configmap "$configmap_name" -n "$ARGO_NS" -o "jsonpath={.data.$key}" 2>/dev/null || true)"
    [[ -n "$value" && "$value" != *REPLACE_ME* ]] || die "ConfigMap $ARGO_NS/$configmap_name is missing a real '$key' value"
  done
  oc get secret "$secret_name" -n "$ARGO_NS" >/dev/null 2>&1 || die "Secret $ARGO_NS/$secret_name is missing for $purpose (see INSTALL.md)"
  for key in certificate.pem private-key.pem; do
    value="$(oc get secret "$secret_name" -n "$ARGO_NS" -o "jsonpath={.data.$key}" 2>/dev/null || true)"
    [[ -n "$value" ]] || die "Secret $ARGO_NS/$secret_name is missing '$key'"
  done
}

validate_aws_identity_inputs(){
  validate_rolesanywhere_identity_inputs "$AWS_AUTH_CONFIGMAP" "$AWS_IDENTITY_SECRET" "read-only manifest generation"
  validate_rolesanywhere_identity_inputs "$AWS_PUBLISHER_AUTH_CONFIGMAP" "$AWS_PUBLISHER_IDENTITY_SECRET" "generated SLS/DRO publishing"
}

validate_rolesanywhere_certificate_secret(){
  local secret_name="${1:?secret name required}" cert_pub key_pub
  oc get secret "$secret_name" -n "$ARGO_NS" -o go-template='{{index .data "certificate.pem"}}' | base64 -d | openssl x509 -noout -checkend 86400 >/dev/null || die "AWS Roles Anywhere certificate in $ARGO_NS/$secret_name is invalid or expires within 24 hours"
  oc get secret "$secret_name" -n "$ARGO_NS" -o go-template='{{index .data "private-key.pem"}}' | base64 -d | openssl pkey -noout >/dev/null 2>&1 || die "AWS Roles Anywhere private key in $ARGO_NS/$secret_name is invalid or encrypted"
  cert_pub="$(oc get secret "$secret_name" -n "$ARGO_NS" -o go-template='{{index .data "certificate.pem"}}' | base64 -d | openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256)"
  key_pub="$(oc get secret "$secret_name" -n "$ARGO_NS" -o go-template='{{index .data "private-key.pem"}}' | base64 -d | openssl pkey -pubout -outform DER 2>/dev/null | openssl sha256)"
  [[ "$cert_pub" == "$key_pub" ]] || die "AWS Roles Anywhere certificate and private key in $ARGO_NS/$secret_name do not match"
}

verify_avp_repo_server(){
  local type region
  type="$(oc exec -n "$ARGO_NS" deployment/openshift-gitops-repo-server -c avp-helm -- printenv AVP_TYPE 2>/dev/null | tr -d '\r' || true)"
  region="$(oc exec -n "$ARGO_NS" deployment/openshift-gitops-repo-server -c avp-helm -- printenv AWS_REGION 2>/dev/null | tr -d '\r' || true)"
  [[ "$type" == "awssecretsmanager" && -n "$region" ]] || die "AWS Secrets Manager CMP is unavailable - run ./bootstrap/00-prereqs.sh $ENV"
  oc exec -n "$ARGO_NS" deployment/openshift-gitops-repo-server -c avp-helm -- /usr/local/bin/aws-rolesanywhere-credential-process >/dev/null || die "AWS Roles Anywhere could not issue short-lived credentials"
}

verify_aws_secrets(){
  local set_name="${1:?verify_aws_secrets requires mongo, mas, or generated}"
  local ipath cpath manifest
  ipath="$(aws_instance_path)"
  cpath="$(aws_cluster_path)"
  case "$set_name" in
    mongo)
      manifest="apiVersion: v1
kind: Secret
metadata:
  name: aws-preflight-mongo
stringData:
  mongoPassword: <path:$ipath/mongo#password>
  slsMongoUsername: <path:$ipath/sls-mongo#username>
  slsMongoPassword: <path:$ipath/sls-mongo#password>
  mongoCaCert: <path:$ipath/mongo-ca#tls_crt_b64>
  mongoCaKey: <path:$ipath/mongo-ca#tls_key_b64>"
      ;;
    mas)
      manifest="apiVersion: v1
kind: Secret
metadata:
  name: aws-preflight-mas
stringData:
  entitlement: <path:$cpath/entitlement#image_pull_secret_b64>
  license: <path:$ipath/license#license_file>
  jdbcUsername: <path:$ipath/jdbc-system#username>
  jdbcPassword: <path:$ipath/jdbc-system#password>
  jdbcUrl: <path:$ipath/jdbc-system#jdbc_url>
  mongoUsername: <path:$ipath/mongo#username>
  mongoPassword: <path:$ipath/mongo#password>
  mongoHost: <path:$ipath/mongo#host>
  mongoCa: <path:$ipath/mongo#ca.crt>
  publicTlsCert: <path:$ipath/certs/public#tls_crt_b64>
  publicTlsKey: <path:$ipath/certs/public#tls_key_b64>
  publicCaCert: <path:$ipath/certs/public#ca_crt_b64>"
      ;;
    generated)
      manifest="apiVersion: v1
kind: Secret
metadata:
  name: aws-preflight-generated
stringData:
  slsUrl: <path:$ipath/sls#url>
  slsRegistrationKey: <path:$ipath/sls#registration_key>
  slsCa: <path:$ipath/sls#ca.crt>
  droUrl: <path:$cpath/dro#url>
  droApiToken: <path:$cpath/dro#api_token>
  droCa: <path:$cpath/dro#ca.crt>"
      ;;
    *) die "unknown AWS secret set '$set_name'" ;;
  esac
  printf '%s\n' "$manifest" | oc exec -i -n "$ARGO_NS" deployment/openshift-gitops-repo-server -c avp-helm -- argocd-vault-plugin generate - >/dev/null || die "AWS Secrets Manager preflight failed for '$set_name' under $ipath"
}
