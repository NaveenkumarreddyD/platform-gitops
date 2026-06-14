#!/usr/bin/env bash
# Runs in the oc/kubectl image (init container). Reads runtime registration
# values for MODE=sls|dro and writes them to /work for the vault-write container.
set -euo pipefail
MODE="${1:?mode sls|dro}"
mkdir -p /work; : > /work/ca.pem
RETRIES="${WAIT_RETRIES:-80}"; INTERVAL="${WAIT_INTERVAL:-15}"

read_ca() {  # $1=namespace ; tries common SLS/DRO cert secrets
  local ns="$1" s k
  for s in ${EXTRA_CA_SECRET:-} $(oc get secret -n "$ns" -o name 2>/dev/null | grep -iE "$CA_GREP" | sed 's#secret/##'); do
    for k in 'ca\.crt' 'tls\.crt'; do
      oc get secret "$s" -n "$ns" -o jsonpath="{.data.$k}" 2>/dev/null | base64 -d > /work/ca.pem 2>/dev/null || true
      grep -q 'BEGIN CERTIFICATE' /work/ca.pem 2>/dev/null && return 0
    done
  done
  : > /work/ca.pem
}

if [ "$MODE" = "sls" ]; then
  NS="${SLS_NS:?}"
  echo ">> waiting for LicenseService Ready in $NS"
  i=0
  until {
    initialized="$(oc get licenseservices.sls.ibm.com -n "$NS" -o jsonpath='{.items[0].status.initialized}' 2>/dev/null || true)"
    registration_key="$(oc get licenseservices.sls.ibm.com -n "$NS" -o jsonpath='{.items[0].status.registrationKey}' 2>/dev/null || true)"
    [[ "$initialized" =~ ^([Tt]rue|[Ii]nitialized|[Rr]eady)$ || -n "$registration_key" ]]
  }; do
    i=$((i+1)); [ "$i" -gt "$RETRIES" ] && { echo "timeout waiting for SLS Ready"; exit 1; }
    sleep "$INTERVAL"
  done
  RK="$(oc get licenseservices.sls.ibm.com -n "$NS" -o jsonpath='{.items[0].status.registrationKey}' 2>/dev/null || true)"
  [ -z "$RK" ] && RK="$(oc get cm sls-suite-registration -n "$NS" -o jsonpath='{.data.registrationKey}' 2>/dev/null || true)"
  [ -z "$RK" ] && { echo "ERROR: no SLS registrationKey in $NS"; exit 1; }
  # Assumes the IBM SLS operator creates a Service named "sls" on 443 in $NS.
  # If the actual Service name/port differs (check: oc get svc -n $NS), set SLS_URL_OVERRIDE
  # (or slsSync.urlOverride) to the correct in-cluster URL or the SLS Route host.
  URL="${SLS_URL_OVERRIDE:-https://sls.${NS}.svc.cluster.local}"
  printf '%s' "$RK"  > /work/registration_key
  printf '%s' "$URL" > /work/url
  CA_GREP='sls.*(cert|tls)'; EXTRA_CA_SECRET="sls-cert sls-tls"; read_ca "$NS"
  echo ">> sls: rk=${RK:0:8}… url=$URL ca=$( [ -s /work/ca.pem ] && echo PEM || echo empty )"

elif [ "$MODE" = "dro" ]; then
  NS="${DRO_NS:?}"
  URL="${DRO_URL_OVERRIDE:-}"
  if [ -z "$URL" ]; then
    H="$(oc get route -n "$NS" -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | grep -iE 'data-reporter|dro' | head -1 || true)"
    [ -n "$H" ] && URL="https://$H" || URL="https://ibm-data-reporter.${NS}.svc.cluster.local:3000"
  fi
  printf '%s' "$URL" > /work/url
  TOK="${DRO_TOKEN_OVERRIDE:-}"
  if [ -z "$TOK" ]; then
    for s in ${DRO_TOKEN_SECRET:-} $(oc get secret -n "$NS" -o name 2>/dev/null | grep -iE 'data-reporter|dro' | sed 's#secret/##'); do
      for k in api_key apikey token api-token; do
        TOK="$(oc get secret "$s" -n "$NS" -o jsonpath="{.data.$k}" 2>/dev/null | base64 -d 2>/dev/null || true)"
        [ -n "$TOK" ] && break 2
      done
    done
  fi
  [ -z "$TOK" ] && { echo "ERROR: DRO api token not found in $NS (set droSync.tokenSecret)"; exit 1; }
  printf '%s' "$TOK" > /work/api_token
  CA_GREP='(data-reporter|dro).*(cert|tls|ca)'; EXTRA_CA_SECRET="${DRO_CA_SECRET:-}"; read_ca "$NS"
  echo ">> dro: url=$URL token=${TOK:0:6}… ca=$( [ -s /work/ca.pem ] && echo PEM || echo empty )"

elif [ "$MODE" = "mongo" ]; then
  # Only the cert-manager CA is runtime here; username/password/host were written
  # statically by load-secrets.sh. So we harvest ONLY ca.pem (vault-write patches it
  # into mongo + sls-mongo without clobbering the creds).
  NS="${MONGO_NS:?}"; CR="${MONGO_CR:?}"
  # Gate: don't publish until Mongo is actually Running (so account-root, which waits
  # on this app, only proceeds once Mongo is usable — not merely created).
  echo ">> waiting for MongoDBCommunity '$CR' to be Running in $NS"
  i=0
  until oc get mongodbcommunity "$CR" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null | grep -qi running; do
    i=$((i+1))
    [ "$i" -gt "$RETRIES" ] && { echo "timeout waiting for Mongo Ready"; oc get mongodbcommunity -n "$NS" 2>/dev/null || true; exit 1; }
    sleep "$INTERVAL"
  done
  echo ">> Mongo '$CR' Running; harvesting CA secret (${CR}-ca / ${CR}-server-cert)"
  i=0
  while :; do
    for s in "${CR}-ca" "${CR}-server-cert"; do
      for k in 'ca\.crt' 'tls\.crt'; do
        oc get secret "$s" -n "$NS" -o jsonpath="{.data.$k}" 2>/dev/null | base64 -d > /work/ca.pem 2>/dev/null || true
        grep -q 'BEGIN CERTIFICATE' /work/ca.pem 2>/dev/null && break 3
      done
    done
    i=$((i+1))
    [ "$i" -gt "$RETRIES" ] && { echo "timeout waiting for Mongo CA in $NS"; oc get secret -n "$NS" 2>/dev/null | grep -Ei 'ca|cert' || true; exit 1; }
    sleep "$INTERVAL"
  done
  echo ">> mongo: ca=PEM (from $NS)"
else
  echo "unknown MODE $MODE"; exit 1
fi
echo ">> harvest($MODE) complete"
