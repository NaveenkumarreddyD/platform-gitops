#!/usr/bin/env bash
# 00 - Configure OpenShift GitOps and AWS Secrets Manager access.
# Idempotent: safe to re-run. Does not deploy any MAS component.
source "$(cd "$(dirname "$0")" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"

say "0/3 preflight"
command -v oc >/dev/null 2>&1 || die "oc not found"
command -v openssl >/dev/null 2>&1 || die "openssl not found"
oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift (oc login ...)"
oc get argocd "$ARGO_NS" -n "$ARGO_NS" >/dev/null 2>&1 || die "OpenShift GitOps ArgoCD '$ARGO_NS' not found - install the operator first"
oc get secret gitlab-gitops-group-repo-creds -n "$ARGO_NS" >/dev/null 2>&1 || die "repo credential secret 'gitlab-gitops-group-repo-creds' missing in $ARGO_NS (INSTALL.md)"
lbl="$(oc get secret gitlab-gitops-group-repo-creds -n "$ARGO_NS" -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}' 2>/dev/null || true)"
[[ "$lbl" == "repo-creds" ]] || die "repo credential secret is not labeled as an Argo CD repo-creds secret"

validate_aws_identity_inputs

say "1/3 apply Argo CD prerequisites"
oc apply -f "$ROOT/bootstrap/00-prereqs/00-gitlab-ca-configmap.yaml"
oc apply -f "$ROOT/bootstrap/00-prereqs/01-argocd-cluster-admin-rbac.yaml"
oc apply -f "$ROOT/bootstrap/00-prereqs/02-argo-project.yaml"
oc apply -f "$ROOT/bootstrap/00-prereqs/03-avp-cmp-plugin.yaml"

say "2/3 patch the ArgoCD CR and roll the repo-server"
oc patch argocd "$ARGO_NS" -n "$ARGO_NS" --type merge --patch-file "$ROOT/bootstrap/argocd-cr-healthchecks-patch.yaml"
oc patch argocd "$ARGO_NS" -n "$ARGO_NS" --type merge --patch-file "$ROOT/bootstrap/argocd-cr-avp-sidecar-patch.yaml"
for _ in $(seq 1 60); do
  deployed_avp_type="$(oc get deployment openshift-gitops-repo-server -n "$ARGO_NS" -o jsonpath='{.spec.template.spec.containers[?(@.name=="avp-helm")].env[?(@.name=="AVP_TYPE")].value}' 2>/dev/null || true)"
  [[ "$deployed_avp_type" == "awssecretsmanager" ]] && break
  sleep 5
done
[[ "${deployed_avp_type:-}" == "awssecretsmanager" ]] || die "Argo CD operator did not configure the AWS Secrets Manager CMP sidecar"
oc rollout restart deploy/openshift-gitops-repo-server -n "$ARGO_NS"
oc rollout status deploy/openshift-gitops-repo-server -n "$ARGO_NS" --timeout=10m
verify_avp_repo_server
say "verified AWS Secrets Manager CMP is configured (static-key credentials)"

say "3/3 done. NEXT: ./bootstrap/05-operators.sh $ENV"
