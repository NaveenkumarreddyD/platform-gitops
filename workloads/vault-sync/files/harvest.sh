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

read_route_ca() { # $1=https URL; writes the served CA bundle to /work/ca.pem. FALLBACK ONLY:
  # the official IBM jobs read the CA from a Secret/ConfigMap, not a handshake. We keep this
  # as a last resort for environments where the CA secret isn't populated.
  local url="$1" host chain="/work/route-chain.pem" cert_count
  host="${url#https://}"; host="${host%%/*}"; host="${host%%:*}"
  [ -n "$host" ] || return 1
  : > "$chain"
  if command -v openssl >/dev/null 2>&1; then
    openssl s_client -showcerts -connect "${host}:443" -servername "$host" </dev/null 2>/dev/null |
      awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > "$chain" || true
  fi
  if grep -q 'BEGIN CERTIFICATE' "$chain" 2>/dev/null; then
    cert_count="$(grep -c 'BEGIN CERTIFICATE' "$chain" 2>/dev/null || echo 0)"
    if [ "$cert_count" -gt 1 ]; then
      awk '
        /BEGIN CERTIFICATE/ { n++; keep=(n > 1) }
        keep { print }
      ' "$chain" > /work/ca.pem
    else
      cp "$chain" /work/ca.pem
    fi
    return 0
  fi
  return 1
}

if [ "$MODE" = "sls" ]; then
  NS="${SLS_NS:?}"
  echo ">> waiting for LicenseService Ready in $NS"
  i=0
  until {
    initialized="$(oc get licenseservices.sls.ibm.com -n "$NS" -o jsonpath='{.items[0].status.initialized}' 2>/dev/null || true)"
    registration_key="$(oc get licenseservices.sls.ibm.com -n "$NS" -o jsonpath='{.items[0].status.registrationKey}' 2>/dev/null || true)"
    cm_registration_key="$(oc get cm sls-suite-registration -n "$NS" -o jsonpath='{.data.registrationKey}' 2>/dev/null || true)"
    cm_ca="$(oc get cm sls-suite-registration -n "$NS" -o jsonpath='{.data.ca}' 2>/dev/null || true)"
    [[ "$initialized" =~ ^([Tt]rue|[Ii]nitialized|[Rr]eady)$ || -n "$registration_key" || ( -n "$cm_registration_key" && "$cm_ca" == *"BEGIN CERTIFICATE"* ) ]]
  }; do
    i=$((i+1)); [ "$i" -gt "$RETRIES" ] && { echo "timeout waiting for SLS Ready"; exit 1; }
    sleep "$INTERVAL"
  done
  RK="$(oc get cm sls-suite-registration -n "$NS" -o jsonpath='{.data.registrationKey}' 2>/dev/null || true)"
  [ -z "$RK" ] && RK="$(oc get licenseservices.sls.ibm.com -n "$NS" -o jsonpath='{.items[0].status.registrationKey}' 2>/dev/null || true)"
  [ -z "$RK" ] && { echo "ERROR: no SLS registrationKey in $NS"; exit 1; }
  URL="${SLS_URL_OVERRIDE:-$(oc get cm sls-suite-registration -n "$NS" -o jsonpath='{.data.url}' 2>/dev/null || true)}"
  [ -z "$URL" ] && URL="https://sls.${NS}.svc.cluster.local"
  printf '%s' "$RK"  > /work/registration_key
  printf '%s' "$URL" > /work/url
  CA_GREP='sls.*(cert|tls|ca)'; EXTRA_CA_SECRET="sls-cert sls-tls sls-ca"; i=0
  until {
    oc get cm sls-suite-registration -n "$NS" -o jsonpath='{.data.ca}' > /work/ca.pem 2>/dev/null || true
    grep -q 'BEGIN CERTIFICATE' /work/ca.pem 2>/dev/null || read_ca "$NS"
    grep -q 'BEGIN CERTIFICATE' /work/ca.pem 2>/dev/null
  }; do
    i=$((i+1))
    [ "$i" -gt "$RETRIES" ] && {
      echo "ERROR: timeout waiting for SLS CA certificate in $NS"
      oc get secret -n "$NS" 2>/dev/null | grep -Ei 'sls|cert|tls|ca' || true
      exit 1
    }
    sleep "$INTERVAL"
  done
  # UPSTREAM-NATIVE primary path: trust ONLY the cm 'ca' (already in /work/ca.pem) — this is
  # exactly what IBM's official 07-postsync-update-sm job does. We then VERIFY that cm 'ca'
  # actually validates the cert served at $URL. Only if it does NOT (CA drift between the
  # published cm 'ca' and the live serving cert, which is what caused CERTIFICATE_VERIFY_FAILED)
  # do we fall back to appending the live served chain. So a healthy SLS stays byte-for-byte
  # upstream; the fallback self-heals drift instead of failing.
  sls_host="${URL#https://}"; sls_host="${sls_host%%/*}"; sls_host="${sls_host%%:*}"
  if [ -n "$sls_host" ] && command -v openssl >/dev/null 2>&1; then
    if echo | openssl s_client -connect "${sls_host}:443" -servername "$sls_host" \
         -CAfile /work/ca.pem -verify_return_error </dev/null >/dev/null 2>&1; then
      echo ">> sls: cm 'ca' validates the served cert (upstream-native; no append needed)"
    else
      echo ">> sls: cm 'ca' does NOT validate the served cert (CA drift) — appending live served chain as fallback"
      openssl s_client -showcerts -connect "${sls_host}:443" -servername "$sls_host" </dev/null 2>/dev/null \
        | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > /work/sls-served.pem || true
      if grep -q 'BEGIN CERTIFICATE' /work/sls-served.pem 2>/dev/null; then
        printf '\n' >> /work/ca.pem
        cat /work/sls-served.pem >> /work/ca.pem
      fi
    fi
  fi
  echo ">> sls: rk=${RK:0:8}… url=$URL ca=$( [ -s /work/ca.pem ] && echo PEM || echo empty )"

elif [ "$MODE" = "dro" ]; then
  NS="${DRO_NS:?}"
  URL="${DRO_URL_OVERRIDE:-}"
  if [ -z "$URL" ]; then
    H="$(oc get route -n "$NS" -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | grep -iE 'data-reporter|dro' | head -1 || true)"
    [ -n "$H" ] && URL="https://$H" || URL="https://ibm-data-reporter.${NS}.svc.cluster.local:3000"
  fi
  printf '%s' "$URL" > /work/url
  # Official IBM method: token comes from Secret ibm-data-reporter-operator-api-token (field 'token').
  TOK="${DRO_TOKEN_OVERRIDE:-}"
  if [ -z "$TOK" ]; then
    for s in ${DRO_TOKEN_SECRET:-} ibm-data-reporter-operator-api-token $(oc get secret -n "$NS" -o name 2>/dev/null | grep -iE 'data-reporter|dro' | sed 's#secret/##'); do
      for k in token api_key apikey api-token; do
        TOK="$(oc get secret "$s" -n "$NS" -o jsonpath="{.data.$k}" 2>/dev/null | base64 -d 2>/dev/null || true)"
        [ -n "$TOK" ] && break 2
      done
    done
  fi
  [ -z "$TOK" ] && { echo "ERROR: DRO api token not found in $NS (set droSync.tokenSecret)"; exit 1; }
  printf '%s' "$TOK" > /work/api_token
  # Official IBM method (primary): the DRO CA ships in Secret ibm-data-reporter-operator-api-token
  # (field ca.crt). Prefer that. BUT verify it actually validates the cert served at $URL — on a
  # reencrypt Route the endpoint serves the cluster INGRESS cert, while a service-account-token's
  # ca.crt is the kube CA (mismatch -> CERTIFICATE_VERIFY_FAILED). If it doesn't validate, fall
  # back to the live served chain so BASCfg trusts whatever the DRO endpoint actually presents.
  : > /work/ca.pem
  for s in ${DRO_CA_SECRET:-} ibm-data-reporter-operator-api-token $(oc get secret -n "$NS" -o name 2>/dev/null | grep -iE 'data-reporter|dro' | sed 's#secret/##'); do
    oc get secret "$s" -n "$NS" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > /work/ca.pem 2>/dev/null || true
    grep -q 'BEGIN CERTIFICATE' /work/ca.pem 2>/dev/null && break
  done
  dro_host="${URL#https://}"; dro_host="${dro_host%%/*}"; dro_port="${dro_host##*:}"; dro_host="${dro_host%%:*}"
  [ "$dro_port" = "$dro_host" ] && dro_port=443
  if [ -n "$dro_host" ] && command -v openssl >/dev/null 2>&1; then
    if grep -q 'BEGIN CERTIFICATE' /work/ca.pem 2>/dev/null && \
       echo | openssl s_client -connect "${dro_host}:${dro_port}" -servername "$dro_host" \
         -CAfile /work/ca.pem -verify_return_error </dev/null >/dev/null 2>&1; then
      echo ">> dro: secret 'ca.crt' validates the endpoint (upstream-native)"
    else
      echo ">> dro: secret 'ca.crt' missing or does not validate ${dro_host}:${dro_port} — using live served chain"
      echo | openssl s_client -showcerts -connect "${dro_host}:${dro_port}" -servername "$dro_host" </dev/null 2>/dev/null \
        | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > /work/ca.pem || true
    fi
  fi
  if ! grep -q 'BEGIN CERTIFICATE' /work/ca.pem 2>/dev/null; then
    CA_GREP='(data-reporter|dro).*(cert|tls|ca)'; EXTRA_CA_SECRET="${DRO_CA_SECRET:-}"; read_ca "$NS"
  fi
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
