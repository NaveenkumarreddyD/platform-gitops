# bootstrap — day-0 seed (run ONCE per cluster)

ArgoCD can't create its own first resources, so this is the only imperative step.
`apply.sh <env>` applies `00-prereqs/` (GitLab CA trust, Argo RBAC, repo credentials, the
`mas` AppProject) then renders `gitops/` for that env and applies it. That render includes a
**self-managing root Application** (`platform-<env>`) — from then on ArgoCD owns everything:
edit `gitops/<env>-*.yaml`, commit, and it re-renders all Applications (and itself).

    ./bootstrap/apply.sh roc4      # prod cluster
