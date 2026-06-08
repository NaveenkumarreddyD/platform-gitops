#!/usr/bin/env bash
# Shared helpers for driving Argo CD Applications with oc only.
set -euo pipefail

ARGO_NS="${ARGO_NS:-openshift-gitops}"

hard_refresh_app() {
  local app="${1:?app name}"
  oc annotate application "$app" -n "$ARGO_NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}

wait_app_idle() {
  local app="${1:?app name}" timeout="${2:-600}" elapsed=0 phase=""
  while :; do
    phase="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    [[ "$phase" != "Running" ]] && return 0
    (( elapsed += 5 ))
    [[ "$elapsed" -ge "$timeout" ]] && { echo "ERROR: timeout waiting for $app operation to finish" >&2; return 1; }
    sleep 5
  done
}

sync_app_oc() {
  local app="${1:?app name}" prune="${2:-false}"
  oc get application "$app" -n "$ARGO_NS" >/dev/null
  hard_refresh_app "$app"
  wait_app_idle "$app" 600
  oc patch application "$app" -n "$ARGO_NS" --type merge \
    -p "{\"operation\":{\"initiatedBy\":{\"username\":\"oc\"},\"sync\":{\"prune\":${prune}}}}" >/dev/null
  echo ">> requested sync for $app"
}

wait_app_synced_healthy() {
  local app="${1:?app name}" timeout="${2:-1200}" elapsed=0 health="" sync="" op=""
  while :; do
    health="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    sync="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    op="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    [[ "$health" == "Healthy" && "$sync" == "Synced" && "$op" != "Running" ]] && {
      echo ">> $app Synced/Healthy"
      return 0
    }
    (( elapsed += 10 ))
    [[ "$elapsed" -ge "$timeout" ]] && {
      echo "ERROR: timeout waiting for $app (sync=$sync health=$health operation=$op)" >&2
      oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.conditions}' 2>/dev/null || true
      echo
      return 1
    }
    sleep 10
  done
}
