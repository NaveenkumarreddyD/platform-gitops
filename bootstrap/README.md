# bootstrap — run ONCE per cluster

Prereqs in `00-prereqs/` (apply first): GitLab CA trust, repo credentials, Argo CD cluster RBAC.

Then render the root `app-of-apps` for THIS cluster's env and apply it. That creates the
AppProject `mas` and the single `gitops-<env>` Application, which fans out everything else.

    # example: prod cluster (roc4)
    helm template mas-aoa ../app-of-apps \
      -f ../app-of-apps/common-values.yaml \
      -f ../app-of-apps/roc4-values.yaml | oc apply -f -

Envs: `nroc4` (non-prod) · `roc4` (prod) · `drroc4` (DR). One values file = one cluster.
