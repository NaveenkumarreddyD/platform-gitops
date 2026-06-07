{{- define "vrs.job" -}}
{{- $mode := .mode -}}
{{- $root := .root -}}
{{- $slsNs := $root.Values.slsSync.namespace | default (printf "mas-%s-sls" $root.Values.instanceId) -}}
{{- $c := $root.Values.clusterId -}}
{{- $i := $root.Values.instanceId -}}
{{- $apps := "" -}}
{{- if eq $mode "sls" }}{{- $apps = printf "%s-sls-system.%s" $i $c -}}{{- end -}}
{{- if eq $mode "dro" }}{{- $apps = printf "%s-bas-system.%s" $i $c -}}{{- end -}}
{{- if eq $mode "mongo" }}{{- $apps = printf "%s-mongo-system.%s %s-sls-system.%s" $i $c $i $c -}}{{- end -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-sync-{{ $mode }}-{{ $root.Values.instanceId }}
  namespace: {{ $root.Values.namespace }}
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 2
  activeDeadlineSeconds: {{ $root.Values.activeDeadlineSeconds | default 1800 }}
  ttlSecondsAfterFinished: {{ $root.Values.ttlSecondsAfterFinished | default 3600 }}
  template:
    spec:
      serviceAccountName: {{ $root.Values.serviceAccount }}
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
      volumes:
        - name: work
          emptyDir: {}
        - name: scripts
          configMap:
            name: {{ $root.Values.serviceAccount }}-scripts
            defaultMode: 0555
      initContainers:
        - name: harvest
          image: {{ $root.Values.ocImage }}
          command: ["/bin/bash","/scripts/harvest.sh","{{ $mode }}"]
          env:
            - {name: SLS_NS, value: "{{ $slsNs }}"}
            - {name: SLS_URL_OVERRIDE, value: "{{ $root.Values.slsSync.urlOverride }}"}
            - {name: DRO_NS, value: "{{ $root.Values.droSync.namespace }}"}
            - {name: DRO_URL_OVERRIDE, value: "{{ $root.Values.droSync.urlOverride }}"}
            - {name: DRO_TOKEN_SECRET, value: "{{ $root.Values.droSync.tokenSecret }}"}
            - {name: DRO_CA_SECRET, value: "{{ $root.Values.droSync.caSecret }}"}
            - {name: MONGO_NS, value: "{{ $root.Values.mongoSync.namespace }}"}
            - {name: MONGO_CR, value: "{{ $root.Values.mongoSync.resourceName | default (printf "%s-mongo" $root.Values.instanceId) }}"}
            - {name: WAIT_RETRIES, value: "{{ $root.Values.waitRetries }}"}
            - {name: WAIT_INTERVAL, value: "{{ $root.Values.waitInterval }}"}
          volumeMounts: [{name: work, mountPath: /work}, {name: scripts, mountPath: /scripts}]
          securityContext: &sc
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities: {drop: ["ALL"]}
          resources: &res
            requests: {cpu: 50m, memory: 64Mi}
            limits:   {cpu: 250m, memory: 256Mi}
        - name: vault-write
          image: {{ $root.Values.vaultImage }}
          command: ["/bin/sh","/scripts/vault-write.sh","{{ $mode }}"]
          env:
            - {name: VAULT_ADDR, value: "{{ $root.Values.vaultAddr }}"}
            - {name: VAULT_CACERT, value: "{{ $root.Values.vaultCacert }}"}
            - {name: VAULT_ROLE, value: "{{ $root.Values.vaultRole }}"}
            - {name: ACCOUNT_ID, value: "{{ $root.Values.accountId }}"}
            - {name: CLUSTER_ID, value: "{{ $root.Values.clusterId }}"}
            - {name: INSTANCE_ID, value: "{{ $root.Values.instanceId }}"}
            - {name: KV_MOUNT, value: "{{ $root.Values.kvMount }}"}
          volumeMounts: [{name: work, mountPath: /work}, {name: scripts, mountPath: /scripts}]
          securityContext: *sc
          resources: *res
      containers:
        - name: refresh
          image: {{ $root.Values.ocImage }}
          command: ["/bin/bash","/scripts/refresh.sh"]
          env:
            - {name: ARGO_NS, value: "{{ $root.Values.namespace }}"}
            - {name: REFRESH_APPS, value: "{{ $apps }}"}
          volumeMounts: [{name: scripts, mountPath: /scripts}]
          securityContext: *sc
          resources: *res
{{- end -}}
