{{- define "sre-gitops-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sre-gitops-app.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "sre-gitops-app.name" . -}}
{{- printf "%s" $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "sre-gitops-app.labels" -}}
app.kubernetes.io/name: {{ include "sre-gitops-app.name" . }}
app.kubernetes.io/part-of: sre-gitops-argocd
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
