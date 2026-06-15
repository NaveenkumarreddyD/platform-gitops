{{- define "gitops.vaultAddr" -}}{{ .Values.vault.addr }}{{- end -}}
{{- define "gitops.mongoNs"   -}}{{ required "mongo.namespace must be set in gitops/envs/<cluster>/values.yaml and MUST equal MONGO_NS in mas-gitops-config/envs/<cluster>.env" .Values.mongo.namespace }}{{- end -}}
{{- define "gitops.slsNs"     -}}mas-{{ .Values.instanceId }}-sls{{- end -}}
{{- define "gitops.coreNs"    -}}mas-{{ .Values.instanceId }}-core{{- end -}}
{{- define "gitops.path"      -}}secret/data/{{ .Values.account.id }}/{{ .Values.clusterId }}/{{ .Values.instanceId }}{{- end -}}
