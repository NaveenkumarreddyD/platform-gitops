# bootstrap — day-0 (run ONCE per cluster)

ArgoCD can't create its own first resources, so this is the only imperative step.
`apply.sh <env>` applies `00-prereqs/` (optional repo CA trust, Argo RBAC, repo credentials, the
`mas` AppProject) then renders `gitops/` for that env and applies it. That render includes a
**self-managing root Application** (`platform-<env>`). From then on Argo CD renders platform
Applications, while Vault remains durable platform state and must not be reset during MAS recreate.

    ./bootstrap/apply.sh roc4      # prod cluster
    ./scripts/setup-vault-platform.sh roc4   # first-time Vault only
