#!/usr/bin/env bash
# Detect (and optionally fix) a dedicated SLS that's stuck BELOW the catalog's channel head
# — the "we wanted 3.12 but got 3.9" case. An orphan/older CSV in the instance SLS namespace
# gets adopted by the Subscription instead of the catalog head. Read-only unless --fix.
#
# Usage:  ./preflight-sls.sh <instanceId> [--fix]      e.g. ./preflight-sls.sh drgitopsapp
set -uo pipefail
IID="${1:?usage: preflight-sls.sh <instanceId> [--fix]}"; FIX="${2:-}"
SLS_NS="mas-${IID}-sls"; CAT_NS="openshift-marketplace"
command -v oc >/dev/null || { echo "ERROR: oc not on PATH"; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged in (oc login ...)"; exit 1; }

echo "SLS namespace : $SLS_NS"
HEAD=$(oc get packagemanifest ibm-sls -n "$CAT_NS" \
  -o jsonpath='{.status.channels[?(@.name=="3.x")].currentCSV}' 2>/dev/null)
[ -z "$HEAD" ] && HEAD=$(oc get packagemanifest ibm-sls -n "$CAT_NS" -o jsonpath='{.status.defaultChannel}' 2>/dev/null)
echo "catalog 3.x head (currentCSV) : ${HEAD:-<not found - check catalog/digest>}"

INST=$(oc get sub -n "$SLS_NS" -o jsonpath='{.items[?(@.spec.name=="ibm-sls")].status.installedCSV}' 2>/dev/null)
[ -z "$INST" ] && INST=$(oc get csv -n "$SLS_NS" -o name 2>/dev/null | grep -o 'ibm-sls[^ ]*' | head -1)
echo "installed in $SLS_NS            : ${INST:-<none>}"

if [ -n "$HEAD" ] && [ -n "$INST" ] && [ "$INST" != "$HEAD" ]; then
  echo
  echo ">> MISMATCH: $SLS_NS is on '$INST' but the catalog head is '$HEAD'."
  echo ">> OLM is holding the older CSV. Delete it (NOT the Subscription); OLM reinstalls the head:"
  echo "     oc delete csv $INST -n $SLS_NS"
  echo "   (scope is the instance SLS namespace ONLY — never touch the shared 'ibm-sls' namespace)"
  if [ "$FIX" = "--fix" ]; then
    echo ">> --fix given: deleting $INST in $SLS_NS ..."
    oc delete csv "$INST" -n "$SLS_NS" && echo ">> done. Watch: oc get csv -n $SLS_NS -w"
  fi
  exit 2
fi
echo; echo "OK: SLS matches the catalog head (or nothing to compare)."
