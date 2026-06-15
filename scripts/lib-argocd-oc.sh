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

wait_app_exists() {
  local app="${1:?app name}" timeout="${2:-600}" elapsed=0
  while :; do
    oc get application "$app" -n "$ARGO_NS" >/dev/null 2>&1 && {
      echo ">> application/$app exists"
      return 0
    }
    (( elapsed += 5 ))
    [[ "$elapsed" -ge "$timeout" ]] && { echo "ERROR: timeout waiting for application/$app" >&2; return 1; }
    sleep 5
  done
}

sync_parent_until_child_exists() {
  local parent="${1:?parent app name}" child="${2:?child app name}" timeout="${3:-600}" elapsed=0
  while :; do
    oc get application "$child" -n "$ARGO_NS" >/dev/null 2>&1 && {
      echo ">> application/$child exists"
      return 0
    }

    echo ">> refreshing/syncing $parent so application/$child is generated"
    sync_app_oc "$parent" false

    for _ in 1 2 3 4 5 6; do
      oc get application "$child" -n "$ARGO_NS" >/dev/null 2>&1 && {
        echo ">> application/$child exists"
        return 0
      }
      sleep 5
      (( elapsed += 5 ))
      [[ "$elapsed" -ge "$timeout" ]] && {
        echo "ERROR: timeout waiting for application/$child after refreshing $parent" >&2
        print_app_diagnostics "$parent" || true
        return 1
      }
    done
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

wait_app_synced_idle() {
  local app="${1:?app name}" timeout="${2:-1200}" elapsed=0 sync="" op=""
  while :; do
    sync="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    op="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    [[ "$sync" == "Synced" && "$op" != "Running" ]] && {
      echo ">> $app Synced/Idle"
      return 0
    }
    (( elapsed += 10 ))
    [[ "$elapsed" -ge "$timeout" ]] && {
      echo "ERROR: timeout waiting for $app (sync=$sync operation=$op)" >&2
      print_app_diagnostics "$app" || true
      return 1
    }
    sleep 10
  done
}

wait_crd() {
  local crd="${1:?crd name}" timeout="${2:-1200}" elapsed=0
  while :; do
    oc get crd "$crd" >/dev/null 2>&1 && {
      echo ">> CRD $crd is registered"
      return 0
    }
    (( elapsed += 10 ))
    [[ "$elapsed" -ge "$timeout" ]] && {
      echo "ERROR: timeout waiting for CRD $crd" >&2
      oc get crd | grep -Ei 'mas.ibm.com|sls.ibm.com|grafana.integreatly.org' || true
      return 1
    }
    sleep 10
  done
}

resource_status() {
  local resource="${1:?resource}" name="${2:?name}" namespace="${3:?namespace}"
  oc get "$resource" "$name" -n "$namespace" -o jsonpath='{.status.status}' 2>/dev/null || true
}

wait_resource_ready() {
  local resource="${1:?resource}" name="${2:?name}" namespace="${3:?namespace}" timeout="${4:-1800}" elapsed=0 status=""
  while :; do
    status="$(resource_status "$resource" "$name" "$namespace")"
    [[ "$status" == "Ready" ]] && {
      echo ">> $resource/$name Ready"
      return 0
    }
    (( elapsed += 15 ))
    [[ "$elapsed" -ge "$timeout" ]] && {
      echo "ERROR: timeout waiting for $namespace/$resource/$name Ready (status=${status:-missing})" >&2
      oc get "$resource" "$name" -n "$namespace" -o yaml 2>/dev/null | \
        grep -iA8 -B2 'conditions:\|message:\|reason:\|status:\|type:' || true
      return 1
    }
    sleep 15
  done
}

wait_suite_ready() {
  local suite="${1:?suite name}" namespace="${2:?namespace}" timeout="${3:-3600}" elapsed=0 status="" generation="" observed=""
  while :; do
    status="$(resource_status suite "$suite" "$namespace")"
    generation="$(oc get suite "$suite" -n "$namespace" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)"
    observed="$(oc get suite "$suite" -n "$namespace" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)"
    [[ "$status" == "Ready" && ( -z "$generation" || "$generation" == "$observed" ) ]] && {
      echo ">> suite/$suite Ready"
      return 0
    }
    (( elapsed += 15 ))
    [[ "$elapsed" -ge "$timeout" ]] && {
      echo "ERROR: timeout waiting for $namespace/suite/$suite Ready (status=${status:-missing} generation=${generation:-?} observed=${observed:-?})" >&2
      oc get suite "$suite" -n "$namespace" -o yaml 2>/dev/null | \
        grep -iA8 -B2 'BasIntegrationReady\|IncompleteConfiguration\|Required condition\|conditions:\|message:\|reason:\|status:\|type:' || true
      return 1
    }
    sleep 15
  done
}

print_app_diagnostics() {
  local app="${1:?app name}"
  echo "== $app =="
  oc get application "$app" -n "$ARGO_NS" \
    -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,OP:.status.operationState.phase 2>/dev/null || return 0
  echo "-- operation message --"
  oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.operationState.message}{"\n"}' 2>/dev/null || true
  echo "-- conditions --"
  oc get application "$app" -n "$ARGO_NS" \
    -o jsonpath='{range .status.conditions[*]}{.type}{" - "}{.message}{"\n"}{end}' 2>/dev/null || true
  echo "-- resource results --"
  oc get application "$app" -n "$ARGO_NS" \
    -o jsonpath='{range .status.operationState.syncResult.resources[*]}{.kind}{"/"}{.name}{"  "}{.status}{"  "}{.message}{"\n"}{end}' 2>/dev/null || true
}
