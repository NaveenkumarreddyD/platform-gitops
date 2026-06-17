#!/usr/bin/env bash
# Shared helpers for driving Argo CD Applications with oc only.
set -euo pipefail

ARGO_NS="${ARGO_NS:-openshift-gitops}"

hard_refresh_app() {
  local app="${1:?app name}"
  oc annotate application "$app" -n "$ARGO_NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}

yaml_inline_value() {
  local file="${1:?file}" map="${2:?map}" key="${3:?key}"
  [[ -f "$file" ]] || return 0
  perl -ne '
    BEGIN { ($map, $key) = splice(@ARGV, 0, 2); }
    if (/\Q$map\E:\s*\{[^}]*\Q$key\E:\s*"?([^",} ]+)/) {
      print "$1\n";
      exit 0;
    }
  ' "$map" "$key" "$file" 2>/dev/null || true
}

cluster_generator_setting() {
  local cluster="${1:?cluster}" key="${2:?key}" value=""
  for file in "gitops/envs/$cluster/common.yaml" "gitops/envs/$cluster/values.yaml" "gitops/values.yaml"; do
    value="$(yaml_inline_value "$file" generator "$key")"
    [[ -n "$value" ]] && {
      printf '%s\n' "$value"
      return 0
    }
  done
}

wait_config_repo_published() {
  local config_repo="${1:?config repo}" cluster="${2:?cluster}" timeout="${3:-300}"
  local expected="" repo_url="" revision="" elapsed=0 remote_sha=""

  [[ "${SKIP_GIT_PUBLISH_WAIT:-false}" == "true" ]] && {
    echo ">> SKIP_GIT_PUBLISH_WAIT=true; not waiting for Argo config repo visibility"
    return 0
  }

  expected="$(git -C "$config_repo" rev-parse HEAD)"
  repo_url="$(cluster_generator_setting "$cluster" repo_url)"
  revision="$(cluster_generator_setting "$cluster" revision)"
  repo_url="${repo_url:-$(git -C "$config_repo" config --get remote.origin.url || true)}"
  revision="${revision:-$(git -C "$config_repo" branch --show-current || true)}"
  revision="${revision:-main}"

  [[ -n "$repo_url" ]] || {
    echo "ERROR: cannot determine MAS config generator repo URL for cluster $cluster" >&2
    return 1
  }

  echo ">> waiting for Argo MAS config repo to expose $revision=$expected"
  echo "   repo: $repo_url"
  while :; do
    remote_sha="$(git ls-remote "$repo_url" "refs/heads/$revision" 2>/dev/null | awk '{print $1; exit}')"
    [[ -z "$remote_sha" ]] && remote_sha="$(git ls-remote "$repo_url" "$revision" 2>/dev/null | awk '{print $1; exit}')"
    [[ "$remote_sha" == "$expected" ]] && {
      echo ">> Argo MAS config repo is current ($revision=$expected)"
      return 0
    }

    if (( elapsed == 0 || elapsed % 60 == 0 )); then
      echo ">> still waiting for MAS config repo visibility (remote=${remote_sha:-unreadable}, expected=$expected, elapsed=${elapsed}s)"
    fi
    (( elapsed += 15 ))
    [[ "$elapsed" -ge "$timeout" ]] && {
      echo "ERROR: Argo MAS config repo did not expose expected commit within ${timeout}s." >&2
      echo "       expected: $expected" >&2
      echo "       observed: ${remote_sha:-unreadable}" >&2
      echo "       repo:     $repo_url" >&2
      echo "       branch:   $revision" >&2
      echo "       If Argo reads GitLab, mirror/push this commit there before syncing." >&2
      return 1
    }
    sleep 15
  done
}

wait_app_refresh_complete() {
  local app="${1:?app name}" timeout="${2:-300}" elapsed=0 refresh="" last_report=-60
  while :; do
    refresh="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/refresh}' 2>/dev/null || true)"
    [[ -z "$refresh" ]] && return 0
    if (( elapsed == 0 || elapsed - last_report >= 60 )); then
      echo ">> waiting for hard refresh on application/$app to complete (elapsed=${elapsed}s)"
      last_report="$elapsed"
    fi
    (( elapsed += 5 ))
    [[ "$elapsed" -ge "$timeout" ]] && {
      echo "ERROR: timeout waiting for hard refresh to complete for $app" >&2
      return 1
    }
    sleep 5
  done
}

wait_app_idle() {
  local app="${1:?app name}" timeout="${2:-600}" elapsed=0 phase="" last_report=-60
  while :; do
    phase="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    [[ "$phase" != "Running" ]] && return 0
    if (( elapsed == 0 || elapsed - last_report >= 60 )); then
      echo ">> waiting for application/$app operation to finish (phase=${phase:-unknown}, elapsed=${elapsed}s)"
      last_report="$elapsed"
    fi
    (( elapsed += 5 ))
    [[ "$elapsed" -ge "$timeout" ]] && { echo "ERROR: timeout waiting for $app operation to finish" >&2; return 1; }
    sleep 5
  done
}

wait_app_exists() {
  local app="${1:?app name}" timeout="${2:-600}" elapsed=0 last_report=-60
  while :; do
    oc get application "$app" -n "$ARGO_NS" >/dev/null 2>&1 && {
      echo ">> application/$app exists"
      return 0
    }
    if (( elapsed == 0 || elapsed - last_report >= 60 )); then
      echo ">> waiting for application/$app to be generated (elapsed=${elapsed}s)"
      last_report="$elapsed"
    fi
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
  wait_app_refresh_complete "$app" 300
  wait_app_idle "$app" 600
  oc patch application "$app" -n "$ARGO_NS" --type merge \
    -p "{\"operation\":{\"initiatedBy\":{\"username\":\"oc\"},\"sync\":{\"prune\":${prune}}}}" >/dev/null
  echo ">> requested sync for $app"
}

wait_app_synced_healthy() {
  local app="${1:?app name}" timeout="${2:-1200}" elapsed=0 health="" sync="" op="" last_report=-60
  while :; do
    health="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    sync="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    op="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    [[ "$health" == "Healthy" && "$sync" == "Synced" && "$op" != "Running" ]] && {
      echo ">> $app Synced/Healthy"
      return 0
    }
    if (( elapsed == 0 || elapsed - last_report >= 60 )); then
      echo ">> waiting for application/$app Synced/Healthy (sync=${sync:-unknown}, health=${health:-unknown}, operation=${op:-none}, elapsed=${elapsed}s)"
      last_report="$elapsed"
    fi
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
  local app="${1:?app name}" timeout="${2:-1200}" elapsed=0 sync="" op="" last_report=-60
  while :; do
    sync="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    op="$(oc get application "$app" -n "$ARGO_NS" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    [[ "$sync" == "Synced" && "$op" != "Running" ]] && {
      echo ">> $app Synced/Idle"
      return 0
    }
    if (( elapsed == 0 || elapsed - last_report >= 60 )); then
      echo ">> waiting for application/$app Synced/Idle (sync=${sync:-unknown}, operation=${op:-none}, elapsed=${elapsed}s)"
      last_report="$elapsed"
    fi
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
  local crd="${1:?crd name}" timeout="${2:-1200}" elapsed=0 last_report=-60
  while :; do
    oc get crd "$crd" >/dev/null 2>&1 && {
      echo ">> CRD $crd is registered"
      return 0
    }
    if (( elapsed == 0 || elapsed - last_report >= 60 )); then
      echo ">> waiting for CRD $crd to be registered (elapsed=${elapsed}s)"
      last_report="$elapsed"
    fi
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
  local resource="${1:?resource}" name="${2:?name}" namespace="${3:?namespace}" s="" r=""
  s="$(oc get "$resource" "$name" -n "$namespace" -o jsonpath='{.status.status}' 2>/dev/null || true)"
  # Some MAS config CRs (MongoCfg/SlsCfg/JdbcCfg/BasCfg) leave .status.status EMPTY and report
  # readiness via a Ready=True condition instead (the printer "STATUS" column comes from there).
  # Without this, wait_resource_ready hangs forever on a CR that is actually Ready.
  if [[ -z "$s" ]]; then
    r="$(oc get "$resource" "$name" -n "$namespace" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "$r" == "True" ]] && s="Ready"
  fi
  printf '%s' "$s"
}

# Wait for a resource to simply EXIST (not necessarily Ready). Use for CRs that are created
# asynchronously by an upstream app cascade (e.g. the Suite CR generated by the account-root
# ApplicationSet -> instance app, which lags the account-root sync by a git-poll cycle or two).
wait_resource_exists() {
  local resource="${1:?resource}" name="${2:?name}" namespace="${3:?namespace}" timeout="${4:-900}" elapsed=0 last=-60
  while :; do
    oc get "$resource" "$name" -n "$namespace" >/dev/null 2>&1 && {
      echo ">> $namespace/$resource/$name exists"
      return 0
    }
    if (( elapsed == 0 || elapsed - last >= 60 )); then
      echo ">> waiting for $namespace/$resource/$name to be created (elapsed=${elapsed}s)"
      last="$elapsed"
    fi
    (( elapsed += 15 ))
    [[ "$elapsed" -ge "$timeout" ]] && {
      echo "ERROR: timeout waiting for $namespace/$resource/$name to be created" >&2
      return 1
    }
    sleep 15
  done
}

wait_resource_ready() {
  local resource="${1:?resource}" name="${2:?name}" namespace="${3:?namespace}" timeout="${4:-1800}" elapsed=0 status="" last_report=-60
  while :; do
    status="$(resource_status "$resource" "$name" "$namespace")"
    [[ "$status" == "Ready" ]] && {
      echo ">> $namespace/$resource/$name Ready"
      return 0
    }
    if (( elapsed == 0 || elapsed - last_report >= 60 )); then
      echo ">> waiting for $namespace/$resource/$name Ready (status=${status:-missing}, elapsed=${elapsed}s)"
      last_report="$elapsed"
    fi
    (( elapsed += 15 ))
    [[ "$elapsed" -ge "$timeout" ]] && {
      echo "ERROR: timeout waiting for $namespace/$resource/$name Ready (status=${status:-missing})" >&2
      dump_cr_conditions "$resource" "$name" "$namespace"
      dump_operator_logs "$namespace" "$(entitymgr_pattern "$resource")" 300
      return 1
    }
    sleep 15
  done
}

wait_suite_ready() {
  local suite="${1:?suite name}" namespace="${2:?namespace}" timeout="${3:-3600}" elapsed=0 status="" generation="" observed="" last_report=-60
  while :; do
    status="$(resource_status suite "$suite" "$namespace")"
    generation="$(oc get suite "$suite" -n "$namespace" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)"
    observed="$(oc get suite "$suite" -n "$namespace" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)"
    # Only enforce the generation match when the CR actually reports observedGeneration.
    # The MAS Suite CR does NOT populate .status.observedGeneration, so gating on it would
    # hang forever even when the Suite is Ready. If observed is absent, trust status==Ready.
    [[ "$status" == "Ready" && ( -z "$observed" || "$generation" == "$observed" ) ]] && {
      echo ">> suite/$suite Ready"
      return 0
    }
    if (( elapsed == 0 || elapsed - last_report >= 60 )); then
      echo ">> waiting for $namespace/suite/$suite Ready (status=${status:-missing}, generation=${generation:-?}, observed=${observed:-?}, elapsed=${elapsed}s)"
      oc get suite "$suite" -n "$namespace" \
        -o 'custom-columns=NAME:.metadata.name,STATUS:.status.status,SYSTEMDB:.status.conditions[?(@.type=="SystemDatabaseReady")].status,SLS:.status.conditions[?(@.type=="SLSIntegrationReady")].status,BAS:.status.conditions[?(@.type=="BASIntegrationReady")].status,ROUTES:.status.conditions[?(@.type=="RoutesReady")].status' 2>/dev/null || true
      last_report="$elapsed"
    fi
    (( elapsed += 15 ))
    [[ "$elapsed" -ge "$timeout" ]] && {
      echo "ERROR: timeout waiting for $namespace/suite/$suite Ready (status=${status:-missing} generation=${generation:-?} observed=${observed:-?})" >&2
      dump_cr_conditions suite "$suite" "$namespace"
      echo ">> the FIRST non-True condition above is the blocker; common causes:"
      echo "   SystemDatabaseReady=InvalidConfiguration -> Mongo CA stale: ./scripts/reconcile-mongo-dependent-configs.sh <env>"
      echo "   SLSIntegrationReady=InvalidConfiguration  -> SLS not in Vault: ./scripts/sync-runtime-registration.sh --sls-only <env>"
      echo "   BASIntegrationReady=NotConfigured         -> expected until ./scripts/enable-bas-config.sh runs"
      echo "   a MODULE FAILURE in the operator log below (e.g. 'Get Public Route certificates')"
      echo "   means the Suite reconcile aborted early -> mas-mongo-config/-credentials/sls-cfg"
      echo "   never got created. Fix the operator error first (often: load-mas-public-cert.sh)."
      dump_operator_logs "$namespace" 'ibm-mas-operator' 300
      dump_operator_logs "$namespace" 'entitymgr-suite' 200
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

# --- CR-level diagnostics ---------------------------------------------------
# The MAS config controllers report "InvalidConfiguration" on a CR while the
# REAL cause (an ansible "MODULE FAILURE", a Mongo TLS handshake error, an empty
# AVP-rendered field) is only visible in the entitymgr operator pod logs. These
# helpers surface that so a timeout is actionable instead of opaque.

# dump_cr_conditions <resource> <name> <namespace>
dump_cr_conditions() {
  local res="${1:?resource}" name="${2:?name}" ns="${3:?namespace}"
  echo "-- $res/$name conditions --"
  oc get "$res" "$name" -n "$ns" \
    -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{"  ("}{.reason}{") "}{.message}{"\n"}{end}' 2>/dev/null || true
}

# dump_operator_logs <namespace> <pod-name-substring> [tail]
# Prints the filtered tail of the first matching operator pod's log.
dump_operator_logs() {
  local ns="${1:?namespace}" pat="${2:?pod pattern}" tail="${3:-300}" pod=""
  pod="$(oc get pod -n "$ns" --no-headers 2>/dev/null | awk -v p="$pat" '$1 ~ p {print $1; exit}')"
  [[ -z "$pod" ]] && { echo "   (no pod matching /$pat/ in $ns to pull logs from)"; return 0; }
  echo "-- operator logs: $ns/$pod (last $tail, error-filtered) --"
  oc logs -n "$ns" "$pod" --tail="$tail" 2>/dev/null \
    | grep -iE 'fatal|MODULE FAILURE|failed=|[^a-z]error|unable to|not ready|registration|mongo|certificate|x509|handshake' \
    | tail -n 40 || true
}

# entitymgr_pattern <resource> -> entitymgr-<singular>  (mongocfgs.config... -> entitymgr-mongocfg)
entitymgr_pattern() {
  local base="${1%%.*}"; base="${base%s}"; printf 'entitymgr-%s' "$base"
}

# wait_suite_condition <suite> <namespace> <conditionType> [timeout]
# Waits for ONE Suite condition to reach status True. On timeout it dumps the
# condition messages and the suite operator logs, then returns 1 (fail fast).
wait_suite_condition() {
  local suite="${1:?suite}" ns="${2:?namespace}" cond="${3:?conditionType}" timeout="${4:-1800}"
  local elapsed=0 status="" reason="" msg="" last=-60
  while :; do
    status="$(oc get suite "$suite" -n "$ns" -o jsonpath="{.status.conditions[?(@.type=='$cond')].status}" 2>/dev/null || true)"
    [[ "$status" == "True" ]] && { echo ">> suite/$suite $cond=True"; return 0; }
    reason="$(oc get suite "$suite" -n "$ns" -o jsonpath="{.status.conditions[?(@.type=='$cond')].reason}" 2>/dev/null || true)"
    msg="$(oc get suite "$suite" -n "$ns" -o jsonpath="{.status.conditions[?(@.type=='$cond')].message}" 2>/dev/null || true)"
    if (( elapsed == 0 || elapsed - last >= 60 )); then
      echo ">> waiting for suite/$suite $cond=True (status=${status:-?}, reason=${reason:-?}: ${msg:-}) elapsed=${elapsed}s"
      last="$elapsed"
    fi
    (( elapsed += 15 ))
    [[ "$elapsed" -ge "$timeout" ]] && {
      echo "ERROR: timeout waiting for suite/$suite $cond (reason=${reason:-?}: ${msg:-})" >&2
      dump_cr_conditions suite "$suite" "$ns"
      # The Suite CR is reconciled by the MAS operator (ibm-mas-operator), not the
      # entitymgr-suite pod. A MODULE FAILURE there (e.g. the "Get Public Route
      # certificates and key" task NoneType crash from an empty *-cert-public secret)
      # only shows in this log, so pull both.
      dump_operator_logs "$ns" 'ibm-mas-operator' 300
      dump_operator_logs "$ns" 'entitymgr-suite' 200
      return 1
    }
    sleep 15
  done
}
