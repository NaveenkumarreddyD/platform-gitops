#!/bin/sh
# Sweep every raft node; unseal any that report sealed=true. Idempotent + safe to run on a CronJob.
set -u
REPLICAS="${VAULT_REPLICAS:-3}"
SVC="${VAULT_INTERNAL_SVC:-vault-internal}"
NS="${VAULT_NAMESPACE:-vault}"
PORT="${VAULT_PORT:-8200}"
SCHEME="${VAULT_SCHEME:-http}"
KEYS_DIR="${KEYS_DIR:-/vault-keys}"

keys=""
for f in "$KEYS_DIR"/unseal-key-*; do
  [ -f "$f" ] || continue
  keys="$keys $(tr -d '\r\n' < "$f")"
done
[ -n "$keys" ] || { echo "ERROR: no unseal keys found in $KEYS_DIR (create the $KEYS_DIR secret)"; exit 1; }

sealed_of(){ vault status -format=json 2>/dev/null | grep -o '"sealed"[^,]*' | head -1 | sed 's/.*://; s/[^a-z]//g'; }

i=0
while [ "$i" -lt "$REPLICAS" ]; do
  export VAULT_ADDR="$SCHEME://vault-$i.$SVC.$NS.svc.cluster.local:$PORT"
  s="$(sealed_of)"
  if [ "$s" = "false" ]; then
    echo ">> vault-$i: already unsealed"
  elif [ -z "$s" ]; then
    echo ">> vault-$i: unreachable / not ready (skip)"
  else
    echo ">> vault-$i: SEALED -> unsealing"
    for k in $keys; do vault operator unseal "$k" >/dev/null 2>&1 || true; done
    echo ">> vault-$i: now sealed=$(sealed_of)"
  fi
  i=$((i+1))
done
echo ">> unseal sweep complete"
