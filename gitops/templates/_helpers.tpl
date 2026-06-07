{{- define "gitops.vaultAddr" -}}{{ .Values.vault.addr }}{{- end -}}
{{- define "gitops.mongoNs"   -}}{{ .Values.mongo.namespace | default (printf "mongo-%s" .Values.instanceId) }}{{- end -}}
{{- define "gitops.slsNs"     -}}mas-{{ .Values.instanceId }}-sls{{- end -}}
{{- define "gitops.coreNs"    -}}mas-{{ .Values.instanceId }}-core{{- end -}}
{{- define "gitops.path"      -}}secret/data/{{ .Values.account.id }}/{{ .Values.clusterId }}/{{ .Values.instanceId }}{{- end -}}
