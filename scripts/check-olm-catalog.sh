#!/usr/bin/env bash
set -euo pipefail
# Verify the IBM operator catalog is usable before relying on OLM Subscriptions.
# Run after ibm-mas-account-root has created operator-catalog.<cluster>, and
# before debugging Suite/SLS/Manage Subscription resolution.

ENVFILE="${1:?usage: check-olm-catalog.sh <path/to/cluster.env>}"
# shellcheck disable=SC1090
set -a; . "$ENVFILE"; set +a
: "${MAS_CHANNEL:?}"; : "${SLS_CHANNEL:?}"; : "${MAS_APP_CHANNEL:?}"

CAT_NS="${CAT_NS:-openshift-marketplace}"
CAT_NAME="${CAT_NAME:-ibm-operator-catalog}"
TIMEOUT="${TIMEOUT:-900}"
INTERVAL="${INTERVAL:-15}"

command -v jq >/dev/null || { echo "ERROR: jq missing from PATH" >&2; exit 1; }

state() {
  oc get catalogsource "$CAT_NAME" -n "$CAT_NS" \
    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true
}

channel_head() {
  local pkg="$1" channel="$2"
  oc get packagemanifest "$pkg" -n "$CAT_NS" -o json 2>/dev/null \
    | jq -r --arg ch "$channel" '.status.channels[]? | select(.name == $ch) | .currentCSV // empty'
}

check_once() {
  local missing=0 csv=""
  oc get catalogsource "$CAT_NAME" -n "$CAT_NS" >/dev/null 2>&1 || {
    echo "catalogsource/$CAT_NAME missing in $CAT_NS"
    return 1
  }

  echo "catalogsource/$CAT_NAME state=${1:-$(state)}"
  for spec in "ibm-mas:$MAS_CHANNEL" "ibm-sls:$SLS_CHANNEL" "ibm-mas-manage:$MAS_APP_CHANNEL"; do
    pkg="${spec%%:*}"
    channel="${spec#*:}"
    csv="$(channel_head "$pkg" "$channel")"
    if [[ -z "$csv" ]]; then
      echo "  MISSING package=$pkg channel=$channel"
      missing=1
    else
      echo "  OK package=$pkg channel=$channel head=$csv"
    fi
  done
  return "$missing"
}

elapsed=0
while :; do
  if check_once "$(state)"; then
    echo "OLM catalog check passed."
    exit 0
  fi
  (( elapsed += INTERVAL ))
  if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
    echo "ERROR: timed out waiting for IBM catalog packages." >&2
    oc describe catalogsource "$CAT_NAME" -n "$CAT_NS" 2>/dev/null || true
    exit 1
  fi
  sleep "$INTERVAL"
done
