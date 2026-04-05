# Homelab Common Chart

Shared Helm chart (`Chart.yaml`: `type: application`) для общих Kubernetes ресурсов. Отдельно от upstream chart в ArgoCD multi-source; это не Helm `type: library` (такой тип только как зависимость и не деплоится своим релизом).

## ✅ РАБОТАЕТ! Все шаблоны с LF; для homelab-common source: `values/shared/global.yaml` + файл приложения (`global.*` и `homelab-common`)

## Возможности

- **ExternalSecrets** — интеграция с Vault
- **HTTPRoutes** — Gateway API маршруты (external/internal/both)
- **Backup CronJobs** — rsync и rclone бэкапы
- **RBAC** — ServiceAccount, ClusterRole, ClusterRoleBinding
- **CiliumNetworkPolicy** — сетевые политики
- **LimitRange** — дефолтные лимиты ресурсов
- **CNPG Database** — CloudNativePG Database манифесты

## Использование

### ArgoCD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: immich
  namespace: argocd
spec:
  sources:
    # Основной chart приложения
    - repoURL: https://immich-app.github.io/immich-charts
      chart: immich
      targetRevision: "*"
      helm:
        valueFiles:
          - $values/values/applications/immich.yaml
    
    # homelab-common для общих ресурсов
    - repoURL: https://github.com/VizzleTF/home_proxmox.git
      path: charts/homelab-common
      targetRevision: HEAD
      helm:
        valueFiles:
          - $values/values/shared/global.yaml
          - $values/values/applications/immich.yaml
    
    # Values репозиторий
    - repoURL: git@github.com:VizzleTF/home-proxmox-values.git
      targetRevision: HEAD
      ref: values
```

### Values файл

```yaml
# values/applications/immich.yaml

# Секция для homelab-common
homelab-common:
  externalSecrets:
    - name: immich-app-secrets
      data:
        - secretKey: password
          property: password
          vaultPath: immich/app-secrets  # Будет: homelab/k8s/immich/app-secrets
      templateData:
        PASSWORD: "{{ .password }}"
  
  httpRoutes:
    - name: immich
      hostname: immich  # Будет: immich.vaka.work
      gateway: both  # external + internal
      service:
        name: immich-server
        port: 2283
  
  backupCronJobs:
    - name: backup-immich
      schedule: "0 2 * * *"
      type: rsync
      source:
        pvc: immich-library-pvc
      destination:
        type: nfs
        path: /immich

# Основные настройки Immich chart
image:
  tag: "v2.6.3"
resources:
  requests:
    cpu: 15m
    memory: 2400Mi
```

## Примеры

См. `examples/immich-example.yaml` для полного примера.

## Важно!

- Все шаблоны используют `{{ $hc := index .Values "homelab-common" }}` для избежания проблем с дефисом в имени
- Первая строка шаблона НЕ должна начинаться с `{{-` (без пробела после `{{`)
- Все файлы с LF окончаниями строк
