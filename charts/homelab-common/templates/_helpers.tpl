{{/*
Имя ресурса приложения: если Release.Name содержит app.name — итог = Release.Name.
*/}}
{{- define "homelab-common.app.fullname" -}}
{{- $a := .app }}
{{- $root := .root }}
{{- if $a.fullnameOverride }}
{{- $a.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := $a.name | default "app" }}
{{- if contains $name $root.Release.Name }}
{{- $root.Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" $root.Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}
