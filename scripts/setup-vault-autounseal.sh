#!/usr/bin/env bash
set -euo pipefail
# setup-vault-autounseal.sh — create/refresh the Kubernetes Secret the vault-unseal CronJob reads.
#
# Use this if Vault was already initialized (you did NOT pass --store-k8s-secret to init-vault.sh).
# It reads the saved init JSON (vault-init-keys.json by default) and writes the threshold unseal
# keys into secret/<keysSecret> in ns/vault as unseal-key-0..N files.
#
#   Usage:  ./scripts/setup-vault-autounseal.sh [--keys-file vault-init-keys.json] [--secret vault-unseal-keys] [--ns vault] [--threshold N]
NS="${VAULT_NS:-vault}"
KEYS_FILE="${KEYS_OUT:-./vault-init-keys.json}"
SECRET="${KEYS_SECRET:-vault-unseal-keys}"
THRESH="${KEY_THRESHOLD:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keys-file) KEYS_FILE="$2"; shift 2 ;;
    --secret)    SECRET="$2"; shift 2 ;;
    --ns)        NS="$2"; shift 2 ;;
    --threshold) THRESH="$2"; shift 2 ;;
    -h|--help) echo "usage: setup-vault-autounseal.sh [--keys-file f] [--secret name] [--ns ns] [--threshold N]"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$KEYS_FILE" ]] || { echo "ERROR: keys file not found: $KEYS_FILE (point --keys-file at your saved init JSON)" >&2; exit 1; }

mapfile -t KEYS < <(python3 -c "import json,sys; d=json.load(open('$KEYS_FILE')); [print(x) for x in d['unseal_keys_b64'][:$THRESH]]")
[[ "${#KEYS[@]}" -ge 1 ]] || { echo "ERROR: no unseal keys parsed from $KEYS_FILE" >&2; exit 1; }

args=(); idx=0
for k in "${KEYS[@]}"; do args+=(--from-literal="unseal-key-$idx=$k"); idx=$((idx+1)); done
oc create secret generic "$SECRET" -n "$NS" "${args[@]}" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc label secret "$SECRET" -n "$NS" app.kubernetes.io/part-of=mas-platform --overwrite >/dev/null 2>&1 || true
echo ">> secret/$SECRET written to ns/$NS with ${#KEYS[@]} unseal key(s)."
echo ">> Enable auto-unseal: set enable.vaultUnseal=true and vault.autoUnseal.enabled=true, commit, push, sync platform root."
