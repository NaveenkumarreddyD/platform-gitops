#!/usr/bin/env bash
# 00 — cluster prerequisites (run ONCE per cluster, before any component).
# Applies the GitLab CA, cluster-admin RBAC for Argo CD, the AppProject, and the AVP CMP plugin,
# then patches the ArgoCD CR (MAS CR health checks + AVP sidecar) and rolls the repo-server.
# Idempotent: safe to re-run. Does NOT deploy any component.
source "$(cd "$(dirname "$0")" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"

say "0/3 preflight"
command -v oc >/dev/null 2>&1 || die "oc not found"
oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift (oc login ...)"
oc get argocd "$ARGO_NS" -n "$ARGO_NS" >/dev/null 2>&1 \
  || die "OpenShift GitOps ArgoCD '$ARGO_NS' not found — install the operator first"
# The GitLab repo credential MUST exist and carry the Argo CD label, or every Git fetch fails
# silently. Do not create it here (needs the deploy token) — assert it (INSTALL.md §3).
oc get secret gitlab-gitops-group-repo-creds -n "$ARGO_NS" >/dev/null 2>&1 \
  || die "repo credential secret 'gitlab-gitops-group-repo-creds' missing in $ARGO_NS (INSTALL.md §3)."
lbl="$(oc get secret gitlab-gitops-group-repo-creds -n "$ARGO_NS" -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}' 2>/dev/null || true)"
[[ "$lbl" == "repo-creds" ]] || die "repo cred secret missing label argocd.argoproj.io/secret-type=repo-creds — Argo CD ignores it (INSTALL.md §3)."

say "1/3 prereqs: GitLab CA, cluster-admin RBAC, AppProject, AVP plugin"
oc apply -f "$ROOT/bootstrap/00-prereqs/00-gitlab-ca-configmap.yaml"
oc apply -f "$ROOT/bootstrap/00-prereqs/01-argocd-cluster-admin-rbac.yaml"
oc apply -f "$ROOT/bootstrap/00-prereqs/02-argo-project.yaml"
oc apply -f "$ROOT/bootstrap/00-prereqs/03-avp-cmp-plugin.yaml"

say "2/3 patch the ArgoCD CR (MAS CR health checks + AVP sidecar), then roll the repo-server"
oc patch argocd "$ARGO_NS" -n "$ARGO_NS" --type merge --patch-file "$ROOT/bootstrap/argocd-cr-healthchecks-patch.yaml"
oc patch argocd "$ARGO_NS" -n "$ARGO_NS" --type merge --patch-file "$ROOT/bootstrap/argocd-cr-avp-sidecar-patch.yaml"
oc rollout status deploy/openshift-gitops-repo-server -n "$ARGO_NS" --timeout=10m

say "3/3 done. NEXT: ./bootstrap/05-operators.sh $ENV"
