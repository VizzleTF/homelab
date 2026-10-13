{{/*
Resource name of a workloads[]/configMaps[]/secrets[] item:
the release name when it already contains the item name, else <release>-<name>.
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
Standard labels of every object of this chart. No chart version on purpose:
a homelab-common bump must not touch every object in the cluster.
dict "root" $ ["app" <app.kubernetes.io/name, default the release>] ["extra" <labels that win>]
*/}}
{{- define "homelab-common.labels" -}}
{{- $std := dict "app.kubernetes.io/name" (.app | default .root.Release.Name) "app.kubernetes.io/instance" .root.Release.Name "app.kubernetes.io/managed-by" .root.Release.Service }}
{{- toYaml (mergeOverwrite $std (deepCopy (.extra | default dict))) }}
{{- end }}

{{/*
metadata block: dict "name" "root" ["app"] ["meta" (labels/annotations)].
*/}}
{{- define "homelab-common.metadata" -}}
{{- $meta := .meta | default dict -}}
metadata:
  name: {{ .name }}
  namespace: {{ .root.Release.Namespace }}
  labels:
    {{- include "homelab-common.labels" (dict "root" .root "app" .app "extra" $meta.labels) | nindent 4 }}
  {{- with $meta.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
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
