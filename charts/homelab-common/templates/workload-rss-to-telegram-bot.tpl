{{/*
Профиль rss-to-telegram-bot: опционально Secret/ConfigMap/PVC + Deployment.
Лейблы app.kubernetes.io/* — см. defines ниже; для другого проекта можно заменить только этот файл.
*/}}
{{- define "homelab-common.workload.rssSelectorLabels" -}}
app.kubernetes.io/name: {{ .workload.name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{- define "homelab-common.workload.rssLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "homelab-common.workload.rssSelectorLabels" . }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{- define "homelab-common.workload.rssToTelegram.render" }}
{{- $w := .workload }}
{{- $root := .root }}
{{- $ctx := dict "workload" $w "root" $root }}
{{- $fullname := include "homelab-common.workload.fullname" $ctx }}
{{- $secretName := $w.existingSecret | default $fullname }}
{{- $adv := $w.advancedConfig | default dict }}
{{- $cfg := $w.config | default dict }}
{{- $hasAdvanced := or $adv.databaseUrl $adv.apiId $adv.tProxy $adv.rProxy $adv.multiuser $adv.cronSecond $adv.errorLoggingChat $adv.debug }}
{{- $hchk := $w.healthCheck | default dict }}
{{- $st := $w.strategy | default dict }}
{{- $strategyType := $st.type | default "RollingUpdate" }}
{{- $pers := $w.persistence | default dict }}
{{- if and (not $w.existingSecret) $cfg.token }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ $fullname }}
  labels:
    {{- include "homelab-common.workload.rssLabels" $ctx | nindent 4 }}
type: Opaque
stringData:
  TOKEN: {{ $cfg.token | quote }}
  MANAGER: {{ $cfg.manager | quote }}
  {{- if $cfg.telegraphToken }}
  TELEGRAPH_TOKEN: {{ $cfg.telegraphToken | quote }}
  {{- end }}
  {{- if $adv.apiHash }}
  API_HASH: {{ $adv.apiHash | quote }}
  {{- end }}
{{- end }}
{{- if $hasAdvanced }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $fullname }}
  labels:
    {{- include "homelab-common.workload.rssLabels" $ctx | nindent 4 }}
data:
  {{- if $adv.databaseUrl }}
  DATABASE_URL: {{ $adv.databaseUrl | quote }}
  {{- end }}
  {{- if $adv.apiId }}
  API_ID: {{ $adv.apiId | quote }}
  {{- end }}
  {{- if $adv.tProxy }}
  T_PROXY: {{ $adv.tProxy | quote }}
  {{- end }}
  {{- if $adv.rProxy }}
  R_PROXY: {{ $adv.rProxy | quote }}
  {{- end }}
  {{- if $adv.multiuser }}
  MULTIUSER: {{ $adv.multiuser | quote }}
  {{- end }}
  {{- if $adv.cronSecond }}
  CRON_SECOND: {{ $adv.cronSecond | quote }}
  {{- end }}
  {{- if $adv.errorLoggingChat }}
  ERROR_LOGGING_CHAT: {{ $adv.errorLoggingChat | quote }}
  {{- end }}
  {{- if $adv.debug }}
  DEBUG: {{ $adv.debug | quote }}
  {{- end }}
{{- end }}
{{- if and $pers.enabled (not $pers.existingClaim) }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $fullname }}
  labels:
    {{- include "homelab-common.workload.rssLabels" $ctx | nindent 4 }}
spec:
  accessModes:
    - {{ $pers.accessMode | default "ReadWriteOnce" }}
  {{- if $pers.storageClass }}
  storageClassName: {{ $pers.storageClass | quote }}
  {{- end }}
  resources:
    requests:
      storage: {{ $pers.size }}
{{- end }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $fullname }}
  annotations:
    argocd.argoproj.io/sync-options: Replace=true
  labels:
    {{- include "homelab-common.workload.rssLabels" $ctx | nindent 4 }}
spec:
  replicas: {{ $w.replicaCount | default 1 }}
  strategy:
    type: {{ $strategyType }}
    {{- if and (eq $strategyType "RollingUpdate") $st.rollingUpdate }}
    rollingUpdate:
      {{- toYaml $st.rollingUpdate | nindent 6 }}
    {{- end }}
  selector:
    matchLabels:
      {{- include "homelab-common.workload.rssSelectorLabels" $ctx | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "homelab-common.workload.rssSelectorLabels" $ctx | nindent 8 }}
    spec:
      {{- with $w.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $w.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ $w.name }}
          image: "{{ $w.image.repository }}:{{ $w.image.tag }}"
          imagePullPolicy: {{ $w.image.pullPolicy | default "Always" }}
          {{- with $w.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          env:
            - name: PORT
              value: "{{ $w.port | default 8848 }}"
          envFrom:
            - secretRef:
                name: {{ $secretName }}
            {{- if $hasAdvanced }}
            - configMapRef:
                name: {{ $fullname }}
            {{- end }}
          {{- if $hchk.enabled }}
          livenessProbe:
            tcpSocket:
              port: {{ $w.port | default 8848 }}
            initialDelaySeconds: {{ $hchk.initialDelaySeconds | default 60 }}
            periodSeconds: {{ $hchk.periodSeconds | default 30 }}
            timeoutSeconds: {{ $hchk.timeoutSeconds | default 10 }}
            failureThreshold: {{ $hchk.failureThreshold | default 3 }}
          readinessProbe:
            tcpSocket:
              port: {{ $w.port | default 8848 }}
            initialDelaySeconds: {{ $hchk.initialDelaySeconds | default 60 }}
            periodSeconds: {{ $hchk.periodSeconds | default 30 }}
            timeoutSeconds: {{ $hchk.timeoutSeconds | default 10 }}
            failureThreshold: {{ $hchk.failureThreshold | default 3 }}
          {{- end }}
          {{- if $pers.enabled }}
          volumeMounts:
            - name: data
              mountPath: /app/config
          {{- end }}
          resources:
            {{- toYaml $w.resources | nindent 12 }}
      {{- if $pers.enabled }}
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: {{ $pers.existingClaim | default $fullname }}
      {{- end }}
      {{- with $w.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $w.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $w.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
