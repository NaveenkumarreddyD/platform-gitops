#!/usr/bin/env bash
# Read-only cross-repository identity and secret-prefix validation.
set -euo pipefail
CLUSTER="${1:?usage: preflight-consistency.sh <cluster>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$ROOT/gitops/envs/$CLUSTER/common.yaml"
VALUES="$ROOT/gitops/envs/$CLUSTER/values.yaml"

ENVFILE=""
for d in "$ROOT/.." "$ROOT/../.."; do
  [[ -f "$d/mas-gitops-config/envs/$CLUSTER.env" ]] \
    && { ENVFILE="$d/mas-gitops-config/envs/$CLUSTER.env"; break; }
done
[[ -f "$COMMON" && -f "$VALUES" ]] || { echo "missing platform env $CLUSTER" >&2; exit 2; }
[[ -n "$ENVFILE" ]] || { echo "missing mas-gitops-config/envs/$CLUSTER.env" >&2; exit 2; }

P_ACCOUNT="$(grep -oE 'account: *\{ *id: *[A-Za-z0-9._-]+' "$COMMON" | sed -E 's/.*id: *//')"
P_CLUSTER="$(grep -E '^clusterId:' "$COMMON" | sed -E 's/.*: *//; s/[ "].*//')"
P_INSTANCE="$(grep -E '^instanceId:' "$VALUES" | sed -E 's/.*: *//; s/[ "].*//')"
P_REV="$(grep -E '^source:' "$COMMON" | grep -oE 'revision: *"?[^",}]+' | sed -E 's/.*: *"?//')"
set -a; . "$ENVFILE"; set +a

failed=0
check(){
  if [[ -n "$2" && "$2" == "$3" ]]; then
    printf 'OK   %-12s %s\n' "$1" "$2"
  else
    printf 'FAIL %-12s platform=%q config=%q\n' "$1" "$2" "$3"
    failed=1
  fi
}

check accountId "$P_ACCOUNT" "${ACCOUNT_ID:-}"
check clusterId "$P_CLUSTER" "${CLUSTER_ID:-}"
check instanceId "$P_INSTANCE" "${INSTANCE_ID:-}"
check ibmRelease "$P_REV" "official-8.5.0"

config_root="$(cd "$(dirname "$ENVFILE")/.." && pwd)"
expected="mas/${ACCOUNT_ID}/${CLUSTER_ID}"
# Use grep (present on every RHEL host) instead of ripgrep, so a bastion without
# ripgrep installed cannot produce a false PASS on the legacy check or a false FAIL
# on the AWS check.
if grep -rqEI --exclude-dir=.git 'secret/data/|VAULT_ADDR|vault_writer' \
  "$ROOT/bootstrap" "$ROOT/gitops" "$ROOT/workloads" \
  "$config_root/base" "$config_root/envs" "$config_root/$ACCOUNT_ID/$CLUSTER_ID" \
  2>/dev/null; then
  echo "FAIL legacy backend references remain"
  failed=1
else
  echo "OK   no legacy backend references"
fi
if grep -rqFI --exclude-dir=.git "<path:${expected}/" "$config_root/$ACCOUNT_ID/$CLUSTER_ID" 2>/dev/null; then
  echo "OK   AWS prefix   $expected"
else
  echo "FAIL no rendered AWS references under $expected"
  failed=1
fi

exit "$failed"
