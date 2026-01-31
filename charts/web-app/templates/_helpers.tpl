{{- define "web-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "web-app.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "web-app.name" . -}}
{{- printf "%s" $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "web-app.labels" -}}
app.kubernetes.io/name: {{ include "web-app.name" . }}
app.kubernetes.io/part-of: sre-gitops
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
