#!/usr/bin/env bash
set -euo pipefail
# init-vault.sh — one-time: initialize (on vault-0) + unseal ALL raft nodes, save keys, print root token.
# Irreducible MANUAL gate: the unseal keys + root token are sensitive and must be captured/stored by a
# human (cannot be GitOps'd). Vault here is 3-node raft HA: vault-1/2 retry_join vault-0, then need
# unsealing with the SAME keys. Defaults to 1 share / 1 threshold; override KEY_SHARES/KEY_THRESHOLD
# for production split-key custody.
#   Usage:  bash scripts/init-vault.sh
NS="${VAULT_NS:-vault}"; STS="${VAULT_STS:-vault}"
SHARES="${KEY_SHARES:-1}"; THRESH="${KEY_THRESHOLD:-1}"
OUT="${KEYS_OUT:-./vault-init-keys.json}"
V="VAULT_ADDR=http://127.0.0.1:8200"
REPLICAS="${VAULT_REPLICAS:-$(oc get statefulset "$STS" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 3)}"
STORE_K8S="${STORE_K8S:-0}"; KEYS_SECRET="${KEYS_SECRET:-vault-unseal-keys}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --store-k8s-secret) STORE_K8S=1; shift ;;
    --keys-secret) KEYS_SECRET="$2"; shift 2 ;;
    -h|--help) echo "usage: init-vault.sh [--store-k8s-secret] [--keys-secret <name>]"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

wait_running(){ local pod="$1" p=""
  for _ in $(seq 1 60); do
    p=$(oc get pod "$pod" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ "$p" == "Running" ]] && return 0; sleep 5
  done
  echo "ERROR: $pod not Running (phase='$p')."; return 1; }

unseal(){ local pod="$1"; shift
  for k in "$@"; do oc exec -n "$NS" "$pod" -- sh -c "$V vault operator unseal $k" >/dev/null; done
  echo "   $pod unsealed."; }

echo ">> Vault raft HA: $REPLICAS node(s) in ns/$NS."
wait_running "${STS}-0"

if oc exec -n "$NS" "${STS}-0" -- sh -c "$V vault status -format=json" 2>/dev/null | grep -q '"initialized": *true'; then
  echo ">> Vault is ALREADY initialized."
  echo "   - If nodes are just sealed, unseal each (${STS}-0..$((REPLICAS-1))) with your saved keys."
  echo "   - Do not delete Vault PVCs during MAS reinstall/recreate; Vault is durable platform state."
  exit 0
fi

echo ">> initializing on ${STS}-0 ($SHARES share(s) / $THRESH threshold)..."
oc exec -n "$NS" "${STS}-0" -- sh -c "$V vault operator init -key-shares=$SHARES -key-threshold=$THRESH -format=json" > "$OUT"
chmod 600 "$OUT"
echo ">> keys + root token saved to $OUT (chmod 600). STORE SECURELY, then shred this file."

mapfile -t KEYS < <(python3 -c "import json; d=json.load(open('$OUT')); [print(x) for x in d['unseal_keys_b64'][:$THRESH]]")
echo ">> unsealing the raft leader (${STS}-0)..."
unseal "${STS}-0" "${KEYS[@]}"

# standbys: wait for them to come up + retry_join, then unseal with the same keys
for i in $(seq 1 $((REPLICAS-1))); do
  echo ">> waiting for standby ${STS}-$i to join + unsealing..."
  wait_running "${STS}-$i"; sleep 3
  unseal "${STS}-$i" "${KEYS[@]}"
done

if [[ "$STORE_K8S" == "1" ]]; then
  echo ">> storing $THRESH unseal key(s) into secret/$KEYS_SECRET in ns/$NS for auto-unseal..."
  args=(); idx=0
  for k in "${KEYS[@]}"; do args+=(--from-literal="unseal-key-$idx=$k"); idx=$((idx+1)); done
  oc create secret generic "$KEYS_SECRET" -n "$NS" "${args[@]}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc label secret "$KEYS_SECRET" -n "$NS" app.kubernetes.io/part-of=mas-platform --overwrite >/dev/null 2>&1 || true
  echo ">> secret/$KEYS_SECRET created. Enable enable.vaultUnseal + vault.autoUnseal.enabled to deploy the CronJob."
fi

ROOT=$(python3 -c "import json; print(json.load(open('$OUT'))['root_token'])")
cat <<MSG

============================================================
 Vault initialized + all $REPLICAS node(s) unsealed.
 Next:
     export VAULT_TOKEN=$ROOT
     ./scripts/setup-vault-auth.sh
============================================================
MSG
