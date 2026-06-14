#!/usr/bin/env bash
set -euo pipefail
# Print the applications that are not clean and include Argo operation/resource
# messages. This is the first command to run when a sync says only "Failed".
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/lib-argocd-oc.sh"
ENVFILE="${1:-}"
if [[ -n "$ENVFILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENVFILE"; set +a
fi
ARGO_NS="${ARGO_NS:-openshift-gitops}"

mapfile -t apps < <(oc get applications -n "$ARGO_NS" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\t"}{.status.operationState.phase}{"\n"}{end}' \
  | awk '$2!="Synced" || $3!="Healthy" || $4=="Failed" {print $1}' | sort -u)

if [[ "${#apps[@]}" -eq 0 ]]; then
  echo "All Argo CD Applications are Synced/Healthy with no failed operation."
  exit 0
fi

echo "Applications needing attention:"
printf '  %s\n' "${apps[@]}"
echo
for app in "${apps[@]}"; do
  print_app_diagnostics "$app"
  echo
done
