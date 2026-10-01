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

{{/*
metadata block for apps[] / cronJobs[] resources: dict "name" "root" "meta" (labels/annotations).
*/}}
{{- define "homelab-common.metadata" -}}
metadata:
  name: {{ .name }}
  namespace: {{ .root.Release.Namespace }}
  {{- with .meta }}
  {{- with .labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- end }}
{{- end }}

{{/*
ESO secretStoreRef for ExternalSecrets of this release. In SecretStore mode
every release reads OpenBao through its own store (templates/eso-store.yaml).
*/}}
{{- define "homelab-common.secretStoreRef" -}}
{{- $vault := (.Values.global | default dict).vault }}
{{- if eq ($vault.secretStoreKind | default "") "SecretStore" }}
name: openbao-{{ .Release.Name }}
kind: SecretStore
{{- else }}
name: {{ $vault.secretStore }}
kind: {{ $vault.secretStoreKind }}
{{- end }}
{{- end }}
