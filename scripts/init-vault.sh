#!/usr/bin/env bash
set -euo pipefail
# init-vault.sh — one-time: initialize (on vault-0) + unseal ALL raft nodes, save keys, print root token.
# Irreducible MANUAL seam: the unseal keys + root token are sensitive and must be captured/stored by a
# human (cannot be GitOps'd). Vault here is 3-node raft HA: vault-1/2 retry_join vault-0, then need
# unsealing with the SAME keys. Defaults to 1 share / 1 threshold; override KEY_SHARES/KEY_THRESHOLD
# for production split-key custody.
#   Usage:  bash scripts/init-vault.sh
NS="${VAULT_NS:-vault}"; STS="${VAULT_STS:-vault}"
SHARES="${KEY_SHARES:-1}"; THRESH="${KEY_THRESHOLD:-1}"
OUT="${KEYS_OUT:-./vault-init-keys.json}"
V="VAULT_ADDR=http://127.0.0.1:8200"
REPLICAS="${VAULT_REPLICAS:-$(oc get statefulset "$STS" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 3)}"

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
  echo "   - For a TRULY fresh Vault: oc delete pvc -n $NS --all && oc delete pod -n $NS -l app.kubernetes.io/name=vault --force --grace-period=0 ; then re-run."
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

ROOT=$(python3 -c "import json; print(json.load(open('$OUT'))['root_token'])")
cat <<MSG

============================================================
 Vault initialized + all $REPLICAS node(s) unsealed.
 Next (one command finishes the platform):
     export VAULT_TOKEN=$ROOT
     bash scripts/deploy.sh ../mas-config-repo/envs/drroc4.env
============================================================
MSG
