# Manual installation without bootstrap scripts

This performs the same installation as [INSTALL.md](INSTALL.md) with direct `oc` and
`helm` commands. Complete the IAM user, workload identity, repository credential, static
secrets, render, and preflight sections in `INSTALL.md` first.

Examples use `drroc4`.

## 1. Set local paths

```bash
cd /path/to/platform-gitops
export ENV=drroc4
export ARGO_NS=openshift-gitops
export COMMON=gitops/envs/drroc4/common.yaml
export VALUES=gitops/envs/drroc4/values.yaml
```

## 2. Configure Argo CD

```bash
oc apply -f bootstrap/00-prereqs/00-gitlab-ca-configmap.yaml
oc apply -f bootstrap/00-prereqs/01-argocd-cluster-admin-rbac.yaml
oc apply -f bootstrap/00-prereqs/02-argo-project.yaml
oc apply -f bootstrap/00-prereqs/03-avp-cmp-plugin.yaml

oc patch argocd openshift-gitops -n "$ARGO_NS" --type merge \
  --patch-file bootstrap/argocd-cr-healthchecks-patch.yaml
oc patch argocd openshift-gitops -n "$ARGO_NS" --type merge \
  --patch-file bootstrap/argocd-cr-avp-sidecar-patch.yaml
oc rollout restart deployment/openshift-gitops-repo-server -n "$ARGO_NS"
oc rollout status deployment/openshift-gitops-repo-server -n "$ARGO_NS" --timeout=10m
```

Confirm the live plugin is AWS and resolves a real secret. The sidecar image has no `aws`
CLI, so verify through AVP rather than `aws sts`:

```bash
oc exec -n "$ARGO_NS" deployment/openshift-gitops-repo-server -c avp-helm -- \
  printenv AVP_TYPE AWS_REGION
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: t\nstringData:\n  u: <path:mas/<account>/<cluster>/<instance>/jdbc-system#username>\n' \
  | oc exec -i -n "$ARGO_NS" deployment/openshift-gitops-repo-server -c avp-helm -- \
  argocd-vault-plugin generate -
```

`AVP_TYPE` must show `awssecretsmanager`. The `generate` command must emit the resolved
Secret without error.

## 3. Install cert-manager

```bash
helm template platform gitops -f "$COMMON" -f "$VALUES" \
  --set component=operators | oc apply -f -

oc wait --for=condition=Established \
  crd/certificates.cert-manager.io --timeout=10m
oc get subscription,csv,installplan -n cert-manager-operator
```

When cert-manager is already platform-managed, set `enable.certManager: false` and only
run the CRD check.

## 4. Install the MongoDB operator

Choose the operator version from the live OpenShift minor:

| OpenShift | MongoDB operator |
|---|---|
| 4.17 or 4.18 | 1.4.0 |
| 4.19 | 1.6.1 |
| 4.20 | 1.8.0 |
| 4.21 | 1.9.1 |

```bash
oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
export MONGO_OPERATOR_VERSION='<version-from-table>'

helm template platform gitops -f "$COMMON" -f "$VALUES" \
  --set component=mongodb-operator \
  --set-string mongoOperator.version="$MONGO_OPERATOR_VERSION" | oc apply -f -

oc wait --for=condition=Established \
  crd/mongodbcommunity.mongodbcommunity.mongodb.com --timeout=10m
```

Wait until `mongodb-kubernetes-operator` is Available in the configured Mongo namespace.

## 5. Install the MongoDB instance

```bash
helm template platform gitops -f "$COMMON" -f "$VALUES" \
  --set component=mongodb-instance | oc apply -f -

oc get mongodbcommunity,pods -n mongo-gitops -w
```

Continue only after the MongoDB resource reports `Running`.

## 6. Install MAS

```bash
helm template platform gitops -f "$COMMON" -f "$VALUES" \
  --set component=mas | oc apply -f -

oc get applications -n "$ARGO_NS" -w
```

The render creates the official IBM account root and the generated-secret publisher.
The account root creates the cluster and instance application tree. The publisher writes
the generated SLS/DRO registration to AWS automatically, so do not create child
applications or publish registration by hand. Use `scripts/status.sh <env>` or the
read-only commands in [RUNBOOK.md](RUNBOOK.md) to verify completion.
