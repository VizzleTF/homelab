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
