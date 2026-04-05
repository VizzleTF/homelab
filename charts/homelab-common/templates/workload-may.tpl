{{/*
Профиль may: Deployment + PVC + Service (лейблы app: <name>).
Переиспользование: скопировать этот файл в другой chart и подключить из dispatch.
*/}}
{{- define "homelab-common.workload.may.render" }}
{{- $w := .workload }}
{{- $root := .root }}
{{- $ctx := dict "workload" $w "root" $root }}
{{- $fullname := include "homelab-common.workload.fullname" $ctx }}
{{- $strat := $w.strategy | default dict }}
{{- $svc := $w.service | default dict }}
{{- $sr := $w.secretRef | default dict }}
{{- $p := $w.persistence | default dict }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $fullname }}
  labels:
    app: {{ $w.name }}
spec:
  replicas: {{ $w.replicaCount | default 1 }}
  strategy:
    type: {{ $strat.type | default "Recreate" }}
  selector:
    matchLabels:
      app: {{ $w.name }}
  template:
    metadata:
      labels:
        app: {{ $w.name }}
    spec:
      {{- with $w.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ $w.name }}
          image: "{{ $w.image.repository }}:{{ $w.image.tag }}"
          imagePullPolicy: {{ $w.image.pullPolicy | default "IfNotPresent" }}
          {{- with $w.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          ports:
            - name: http
              containerPort: {{ $svc.port }}
              protocol: TCP
          envFrom:
            - secretRef:
                name: {{ $sr.name }}
          {{- if $p.enabled }}
          volumeMounts:
            - name: data
              mountPath: {{ $p.mountPath }}
          {{- end }}
          resources:
            {{- toYaml $w.resources | nindent 12 }}
      {{- if $p.enabled }}
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: {{ $fullname }}
      {{- end }}
{{- if $p.enabled }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $fullname }}
  labels:
    app: {{ $w.name }}
spec:
  accessModes:
    - {{ $p.accessMode | default "ReadWriteOnce" }}
  storageClassName: {{ $p.storageClass }}
  resources:
    requests:
      storage: {{ $p.size }}
{{- end }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $fullname }}
  labels:
    app: {{ $w.name }}
spec:
  type: {{ $svc.type | default "ClusterIP" }}
  ports:
    - port: {{ $svc.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app: {{ $w.name }}
{{- end }}
