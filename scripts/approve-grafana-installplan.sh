#!/usr/bin/env bash
set -euo pipefail
# approve-grafana-installplan.sh — auto-approve ONLY the pinned Grafana operator InstallPlan.
#
# The Grafana operator Subscription uses installPlanApproval: Manual to hold the cluster on
# grafana-operator.v5.21.2 (v5.22.x CRD breaks on OCP < 4.19). This script approves the
# InstallPlan that references the pinned CSV and refuses any other version, so the OCP 4.18 pin
# is respected without a human running oc patch.
#
#   Usage:  ./scripts/approve-grafana-installplan.sh [--csv grafana-operator.v5.21.2] [--ns platform-operators]
ARGO_NS="${ARGO_NS:-openshift-gitops}"
NS="${OPERATORS_NS:-platform-operators}"
CSV_PIN="${GRAFANA_CSV_PIN:-grafana-operator.v5.21.2}"
TIMEOUT="${TIMEOUT:-600}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv) CSV_PIN="$2"; shift 2 ;;
    --ns)  NS="$2"; shift 2 ;;
    -h|--help) echo "usage: approve-grafana-installplan.sh [--csv <csv>] [--ns <namespace>]"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

say(){ printf '\n=== %s ===\n' "$*"; }
say "Approving Grafana InstallPlan for CSV=$CSV_PIN in ns/$NS (refusing other versions)"

# Wait for an InstallPlan that targets the pinned CSV to appear (the operator may still be resolving).
elapsed=0
ip=""
while :; do
  ip="$(oc get installplan -n "$NS" -o json 2>/dev/null \
        | jq -r --arg csv "$CSV_PIN" \
            '.items[] | select(.spec.clusterServiceVersionNames[]? == $csv) | .metadata.name' \
        | head -n1)"
  [[ -n "$ip" ]] && break
  (( elapsed += 10 ))
  if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
    echo "WARN: no InstallPlan referencing $CSV_PIN found in ns/$NS after ${TIMEOUT}s." >&2
    echo "WARN: the grafana-operator Application may not be synced yet; re-run after wave 55." >&2
    exit 0
  fi
  sleep 10
done

approved="$(oc get installplan "$ip" -n "$NS" -o jsonpath='{.spec.approved}' 2>/dev/null || echo "")"
if [[ "$approved" == "true" ]]; then
  echo ">> InstallPlan $ip already approved. Nothing to do."
  exit 0
fi

# Hard guard: never approve a plan that also pulls a non-pinned (e.g. v5.22.x) CSV.
others="$(oc get installplan "$ip" -n "$NS" -o json \
          | jq -r --arg csv "$CSV_PIN" '.spec.clusterServiceVersionNames[] | select(. != $csv)')"
if [[ -n "$others" ]]; then
  echo "ERROR: InstallPlan $ip also targets non-pinned CSV(s):" >&2
  echo "$others" >&2
  echo "ERROR: refusing to approve to protect the OCP-4.18 pin. Approve by hand if you are on OCP >= 4.19." >&2
  exit 1
fi

oc patch installplan "$ip" -n "$NS" --type merge -p '{"spec":{"approved":true}}' >/dev/null
echo ">> Approved InstallPlan $ip ($CSV_PIN) in ns/$NS."
