#!/usr/bin/env bash
set -euo pipefail
# Read-only cross-repo consistency check. account.id / clusterId / instanceId build the
# Vault secret path in BOTH platform-gitops (gitops.path helper) and mas-gitops-config
# (rendered <path:...> refs); if they disagree the paths diverge and the install fails
# LATE (this is the drroc4-vs-gitopsapp class of failure). This asserts they agree BEFORE
# you bootstrap. It makes NO changes.
#   Usage: ./scripts/preflight-consistency.sh <cluster>     e.g. drroc4
CLUSTER="${1:?usage: preflight-consistency.sh <cluster>   (e.g. drroc4)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GLOBAL="$ROOT/gitops/values.yaml"
COMMON="$ROOT/gitops/envs/$CLUSTER/common.yaml"
VALUES="$ROOT/gitops/envs/$CLUSTER/values.yaml"

ENVFILE=""
for d in "$ROOT/.." "$ROOT/../.."; do
  for repo in mas-gitops-config; do
    [[ -f "$d/$repo/envs/$CLUSTER.env" ]] && { ENVFILE="$d/$repo/envs/$CLUSTER.env"; break 2; }
  done
done

[[ -f "$COMMON" ]]  || { echo "MISSING: $COMMON"  >&2; exit 2; }
[[ -f "$VALUES" ]]  || { echo "MISSING: $VALUES"  >&2; exit 2; }
[[ -n "$ENVFILE" ]] || { echo "MISSING: mas-gitops-config/envs/$CLUSTER.env (expected beside platform-gitops)" >&2; exit 2; }

# platform side (simple key: value / inline-flow-map parsing)
# account.id is now per-env: read the env's common.yaml first, fall back to the global default.
P_ACCOUNT="$(grep -oE 'account: *\{ *id: *[A-Za-z0-9._-]+' "$COMMON" 2>/dev/null | head -1 | sed -E 's/.*id: *//' || true)"
[[ -z "$P_ACCOUNT" ]] && P_ACCOUNT="$(grep -oE 'account: *\{ *id: *[A-Za-z0-9._-]+' "$GLOBAL" 2>/dev/null | head -1 | sed -E 's/.*id: *//' || true)"
P_CLUSTER="$(grep -E '^clusterId:'  "$COMMON" | sed -E 's/.*: *//; s/[ "].*//')"
P_INSTANCE="$(grep -E '^instanceId:' "$VALUES" | sed -E 's/.*: *//; s/[ "].*//')"
P_MONGONS="$(grep -oE 'namespace: *[A-Za-z0-9._-]+' "$VALUES" | head -1 | sed -E 's/.*: *//')"
P_REV="$(grep -E '^source:' "$COMMON" | grep -oE 'revision: *"?[^",}]+' | sed -E 's/.*: *"?//')"

# config side
set -a; . "$ENVFILE"; set +a

fail=0
check(){ # label  platform-value  config-value
  if [[ "$2" == "$3" && -n "$2" ]]; then printf '  OK    %-12s %s\n' "$1" "$2"
  else printf '  FAIL  %-12s platform=%q  config=%q\n' "$1" "$2" "$3"; fail=1; fi
}

echo "Cross-repo consistency — cluster '$CLUSTER'"
echo "  platform: gitops/values.yaml + envs/$CLUSTER/{common,values}.yaml"
echo "  config:   $ENVFILE"
echo
# These three build the Vault path in BOTH repos — they MUST match.
check accountId  "$P_ACCOUNT"  "${ACCOUNT_ID:-}"
check clusterId  "$P_CLUSTER"  "${CLUSTER_ID:-}"
check instanceId "$P_INSTANCE" "${INSTANCE_ID:-}"

if [[ "$P_REV" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '  FAIL  %-12s source.revision=%s is a stock IBM tag; use the Vault patch branch (e.g. 8.4.0-vault-patch)\n' sourceRev "$P_REV"; fail=1
else
  printf '  OK    %-12s %s\n' sourceRev "$P_REV"
fi

echo
# mongo.namespace is platform-only (not in the config repo). It cannot be cross-checked
# here, but it MUST equal the namespace baked into the seeded mongo#host in Vault.
echo "REMINDER: platform mongo.namespace='$P_MONGONS' — the seeded Vault 'mongo#host'"
echo "          (INSTALL.md section 6) must use this same namespace."
echo
if [[ "$fail" == 0 ]]; then
  echo "PASS — account/cluster/instance are consistent across repos."
else
  echo "FAIL — fix the mismatches above before bootstrapping (they will fail late otherwise)."
  exit 1
fi
