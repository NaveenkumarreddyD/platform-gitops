#!/usr/bin/env bash
# status.sh <env> — READ-ONLY whole-system health for one cluster. Safe to run anytime; needs no
# Vault token. Shows each decoupled component's Argo CD sync/health plus the live signals that
# matter (Vault seal, MongoDB phase, MAS Suite/Manage, SLS/DRO harvest). Use it to find WHICH
# layer is unhealthy, then jump to that component's section in RUNBOOK.md.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARGO_NS="${ARGO_NS:-openshift-gitops}"; VAULT_NS="${VAULT_NS:-vault}"
ENV="${1:?usage: status.sh <env>   (e.g. doc4)}"
COMMON="$ROOT/gitops/envs/$ENV/common.yaml"; VALUES="$ROOT/gitops/envs/$ENV/values.yaml"
[[ -f "$VALUES" ]] || { echo "no env: gitops/envs/$ENV" >&2; exit 2; }
INSTANCE="$(grep -E '^instanceId:' "$VALUES" | sed -E 's/.*: *//; s/[ "].*//')"
MONGO_NS="$(grep -oE 'namespace: *[A-Za-z0-9._-]+' "$VALUES" | head -1 | sed -E 's/.*: *//')"

hr(){ printf '%s\n' "----------------------------------------------------------------------"; }
echo "MAS platform status — env '$ENV'  (instance $INSTANCE)"; hr

# --- Argo CD Applications (the decoupled components) ---
printf "%-22s %-12s %-12s\n" "APPLICATION" "SYNC" "HEALTH"
oc get applications -n "$ARGO_NS" -l app.kubernetes.io/part-of=mas-platform \
   -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers 2>/dev/null \
 | awk '{printf "%-22s %-12s %-12s\n",$1,$2,$3}' || echo "  (no applications found)"
hr

# --- Vault (seal state across nodes) ---
echo "VAULT"
for p in vault-0 vault-1 vault-2; do
  s="$(oc exec -n "$VAULT_NS" "$p" -- sh -c 'export VAULT_ADDR=http://127.0.0.1:8200; vault status -format=json' 2>/dev/null \
       | grep -oE '"sealed": *(true|false)' | sed 's/.*: *//')"
  [[ -n "$s" ]] && printf "  %-8s sealed=%s\n" "$p" "$s" || printf "  %-8s (not present)\n" "$p"
done
hr

# --- MongoDB ---
echo "MONGODB  (ns $MONGO_NS)"
oc get mongodbcommunity -n "$MONGO_NS" -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers 2>/dev/null \
 | awk '{printf "  %-24s %s\n",$1,$2}' || echo "  (none)"
hr

# --- MAS Suite / Manage ---
echo "MAS"
oc get suite -A -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' --no-headers 2>/dev/null \
 | awk '{printf "  Suite   %-16s ready=%s\n",$2,$3}' || echo "  Suite   (none)"
oc get manageworkspace -A -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' --no-headers 2>/dev/null \
 | awk '{printf "  Manage  %-16s ready=%s\n",$1,$2}' || echo "  Manage  (none)"
hr

# --- Harvest jobs (SLS/DRO registration written back to Vault) ---
echo "HARVEST (registration → Vault)"
for kv in "SLS:mas-${INSTANCE}-sls:postsync-ibm-sls-update-sm" "DRO:ibm-software-central:postsync-ibm-dro-update-sm"; do
  lbl="${kv%%:*}"; rest="${kv#*:}"; ns="${rest%%:*}"; pat="${rest#*:}"
  j="$(oc get jobs -n "$ns" -o name 2>/dev/null | grep "$pat" | tail -1)"
  if [[ -n "$j" ]]; then
    ok="$(oc get "$j" -n "$ns" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
    printf "  %-4s %s  succeeded=%s\n" "$lbl" "${j#job.batch/}" "${ok:-0}"
  else printf "  %-4s (no job yet — appears after 30-mas)\n" "$lbl"; fi
done
hr
echo "Red component? → RUNBOOK.md section for that component."
