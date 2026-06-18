#!/usr/bin/env bash
# Runs LAST (oc image), after harvest + vault-write. Two jobs:
#   1. Hard-refresh the consuming ArgoCD Application(s) so AVP re-reads Vault and re-renders
#      the config CR with the freshly-harvested registration/CA.
#   2. Bounce the MAS controller pods that CACHE their TLS/registration context on first
#      connect, so they re-read the corrected config. This replaces the manual
#      scripts/reconcile-mongo-dependent-configs.sh + enable-*-config.sh bounce — the
#      point of the retrofit: a hands-off deploy with no post-sync manual steps.
# Non-fatal by design (set +e semantics): a missing pod/app must never fail the sync hook.
set -uo pipefail
MODE="${1:-${MODE:-}}"
NS="${ARGO_NS:-openshift-gitops}"

# 1) re-read Vault into the consumer app(s)
for app in ${REFRESH_APPS:-}; do
  if oc get application "$app" -n "$NS" >/dev/null 2>&1; then
    oc annotate application "$app" -n "$NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
    echo ">> hard-refreshed $app"
  else
    echo ">> (consumer app $app not present yet — skipping)"
  fi
done

# 2) bounce the controllers that cache TLS/registration, retrying until the consumer
#    config CR reports good (or attempts exhausted). All best-effort.
bounce() {  # $1=namespace ; $2.. = pod name substrings
  local ns="$1"; shift
  oc get ns "$ns" >/dev/null 2>&1 || return 0
  local pat pod
  for pat in "$@"; do
    for pod in $(oc get pod -n "$ns" --no-headers 2>/dev/null | awk -v p="$pat" '$1 ~ p {print $1}'); do
      oc delete pod "$pod" -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
      echo ">> bounced $ns/$pod"
    done
  done
}

consumer_ready() {  # mode-specific success check on the rendered config CR
  local kind name typ
  case "$MODE" in
    sls)   kind=slscfgs.config.mas.ibm.com;   name="${INSTANCE_ID}-sls-system";   typ=Registered ;;
    dro)   kind=bascfgs.config.mas.ibm.com;   name="${INSTANCE_ID}-bas-system";   typ=Ready ;;
    mongo) kind=mongocfgs.config.mas.ibm.com; name="${INSTANCE_ID}-mongo-system"; typ=Ready ;;
    *) return 0 ;;
  esac
  oc get "$kind" "$name" -n "${CORE_NS:-}" \
    -o jsonpath="{range .status.conditions[?(@.type=='$typ')]}{.status}{end}" 2>/dev/null \
    | grep -qi true
}

if [ -z "${BOUNCE_CORE_PODS:-}" ] && [ -z "${BOUNCE_SLS_PODS:-}" ]; then
  echo ">> no controllers to bounce for mode=$MODE"; echo ">> refresh($MODE) complete"; exit 0
fi

ATTEMPTS="${BOUNCE_ATTEMPTS:-4}"; WAIT="${BOUNCE_WAIT:-240}"
for n in $(seq 1 "$ATTEMPTS"); do
  # sls/mongo: the consumer CR condition is a real "already registered/verified" signal — skip
  # bouncing a healthy one. dro: the goal is the downstream milestone consumers (bascfg is already
  # Ready while milestone still 401s), so ALWAYS bounce at least once to refresh their token.
  if [ "$MODE" != dro ] && consumer_ready; then echo ">> $MODE consumer already Ready (no bounce needed)"; break; fi
  [ -n "${BOUNCE_CORE_PODS:-}" ] && bounce "${CORE_NS:-}" ${BOUNCE_CORE_PODS}
  [ -n "${BOUNCE_SLS_PODS:-}" ]  && bounce "${SLS_NS:-}"  ${BOUNCE_SLS_PODS}
  echo ">> bounce $n/$ATTEMPTS (mode=$MODE); waiting up to ${WAIT}s for consumer Ready"
  e=0
  while [ "$e" -lt "$WAIT" ]; do
    if consumer_ready; then echo ">> $MODE consumer Ready"; break 2; fi
    sleep 15; e=$((e+15))
  done
done
echo ">> refresh($MODE) complete"
