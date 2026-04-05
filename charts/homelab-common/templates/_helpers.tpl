{{/*
Workload fullname — совместимо с legacy charts may / rss-to-telegram-bot:
если имя релиза содержит workload.name, итоговое имя = Release.Name.
*/}}
{{- define "homelab-common.workload.fullname" -}}
{{- $w := .workload }}
{{- $root := .root }}
{{- if $w.fullnameOverride }}
{{- $w.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := $w.name | default "workload" }}
{{- if contains $name $root.Release.Name }}
{{- $root.Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" $root.Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "homelab-common.workload.rssSelectorLabels" -}}
app.kubernetes.io/name: {{ .workload.name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{- define "homelab-common.workload.rssLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "homelab-common.workload.rssSelectorLabels" . }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}
