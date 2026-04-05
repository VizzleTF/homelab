{{/*
Универсальные K8s-манифесты: metadata + spec/data через values.
Параметр root — контекст релиза (для namespace по умолчанию).
*/}}
{{- define "homelab-common.k8s.deployment" -}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .metadata.name }}
  namespace: {{ .metadata.namespace | default .root.Release.Namespace }}
  {{- with .metadata.labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .metadata.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- toYaml .spec | nindent 2 }}
{{- end }}

{{- define "homelab-common.k8s.service" -}}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ .metadata.name }}
  namespace: {{ .metadata.namespace | default .root.Release.Namespace }}
  {{- with .metadata.labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .metadata.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- toYaml .spec | nindent 2 }}
{{- end }}

{{- define "homelab-common.k8s.pvc" -}}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .metadata.name }}
  namespace: {{ .metadata.namespace | default .root.Release.Namespace }}
  {{- with .metadata.labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .metadata.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- toYaml .spec | nindent 2 }}
{{- end }}

{{- define "homelab-common.k8s.secret" -}}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ .metadata.name }}
  namespace: {{ .metadata.namespace | default .root.Release.Namespace }}
  {{- with .metadata.labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .metadata.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
type: {{ .type | default "Opaque" }}
{{- with .stringData }}
stringData:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .data }}
data:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "homelab-common.k8s.configmap" -}}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .metadata.name }}
  namespace: {{ .metadata.namespace | default .root.Release.Namespace }}
  {{- with .metadata.labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .metadata.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
data:
  {{- toYaml (.data | default dict) | nindent 2 }}
{{- end }}
