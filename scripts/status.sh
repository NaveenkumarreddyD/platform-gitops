#!/usr/bin/env bash
# Read-only health summary for one environment.
set -uo pipefail
source "$(cd "$(dirname "$0")/../bootstrap" && pwd)/lib-bootstrap.sh"
resolve_env "${1:-}"
require_cluster

INSTANCE="$(env_instance)"
MONGO_NS="$(env_mongo_ns)"
hr(){ printf '%s\n' "----------------------------------------------------------------------"; }

echo "MAS platform status - env '$ENV' (instance $INSTANCE)"
hr
printf "%-38s %-12s %-12s\n" "APPLICATION" "SYNC" "HEALTH"
oc get applications -n "$ARGO_NS" \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status \
  --no-headers 2>/dev/null \
  | awk '{printf "%-38s %-12s %-12s\n",$1,$2,$3}' || echo "  (no applications)"
hr

echo "AWS SECRETS MANAGER"
aws_type="$(oc exec -n "$ARGO_NS" deployment/openshift-gitops-repo-server \
  -c avp-helm -- printenv AVP_TYPE 2>/dev/null | tr -d '\r' || true)"
aws_region="$(oc exec -n "$ARGO_NS" deployment/openshift-gitops-repo-server \
  -c avp-helm -- printenv AWS_REGION 2>/dev/null | tr -d '\r' || true)"
printf "  backend=%s region=%s\n" "${aws_type:-unavailable}" "${aws_region:-unset}"
if verify_avp_repo_server >/dev/null 2>&1; then
  echo "  One Identity A2A credentials: available"
else
  echo "  One Identity A2A credentials: FAILED"
fi
if verify_aws_secrets generated >/dev/null 2>&1; then
  echo "  SLS/DRO registration: present"
else
  echo "  SLS/DRO registration: incomplete (expected during initial deployment)"
fi
publisher_ready="$(oc get deployment aws-generated-secrets-publisher -n "$ARGO_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
printf "  generated-secret publisher: %s\n" "$([[ "$publisher_ready" == "1" ]] && echo ready || echo unavailable)"
hr

echo "MONGODB (namespace $MONGO_NS)"
oc get mongodbcommunity -n "$MONGO_NS" \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers 2>/dev/null \
  | awk '{printf "  %-28s %s\n",$1,$2}' || echo "  (none)"
hr

echo "MAS"
oc get suite -A \
  -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' \
  --no-headers 2>/dev/null \
  | awk '{printf "  Suite   %-20s ready=%s\n",$2,$3}' || echo "  Suite   (none)"
oc get manageworkspace -A \
  -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' \
  --no-headers 2>/dev/null \
  | awk '{printf "  Manage  %-20s ready=%s\n",$1,$2}' || echo "  Manage  (none)"
