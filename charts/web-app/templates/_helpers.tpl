{{- define "web-app.selector" -}}
app.kubernetes.io/name: {{ .Release.Name }}
{{- end }}

{{- define "web-app.labels" -}}
{{ include "web-app.selector" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
