# Миграция на homelab-common chart

## Процесс миграции приложения

### 1. Добавьте секцию homelab-common в values файл

Откройте `home-proxmox-values/values/applications/{app}.yaml` и добавьте в начало:

```yaml
# Общие ресурсы через homelab-common
homelab-common:
  externalSecrets: [...]
  httpRoutes: [...]
  backupCronJobs: [...]
  # и т.д.

# Основные настройки приложения (существующие)
image:
  tag: latest
# ...
```

### 2. Обновите ArgoCD Application

Добавьте homelab-common как дополнительный source. В `helm.valueFiles` **только у этого source** укажите сначала `$values/values/shared/global.yaml`, затем файл приложения (upstream chart оставьте без `global.yaml`, если у чарта строгая values schema).

```yaml
spec:
  sources:
    # Основной chart приложения (существующий)
    - repoURL: https://charts.example.com/myapp
      chart: myapp
      targetRevision: "*"
      helm:
        valueFiles:
          - $values/values/applications/myapp.yaml
    
    # НОВОЕ: Общие ресурсы через homelab-common
    - repoURL: https://github.com/VizzleTF/home_proxmox.git
      path: charts/homelab-common
      targetRevision: HEAD
      helm:
        valueFiles:
          - $values/values/shared/global.yaml
          - $values/values/applications/myapp.yaml
    
    # Values репозиторий (существующий)
    - repoURL: git@github.com:VizzleTF/home-proxmox-values.git
      targetRevision: HEAD
      ref: values
```

### 3. Удалите старые манифесты

После успешного деплоя удалите:
- `home-proxmox-values/manifests/applications/{app}/external-secret.yaml`
- `home-proxmox-values/manifests/applications/{app}/httproute*.yaml`
- `home-proxmox-values/manifests/applications/{app}/backup-cronjob.yaml`
- и т.д.

Оставьте только специфичные для приложения манифесты (если есть).

## Примеры миграции

### Immich (multi-source app)

**До:**
```yaml
# immich-application.yaml
sources:
  - repoURL: https://immich-app.github.io/immich-charts
    chart: immich
    helm:
      valueFiles:
        - $values/values/applications/immich.yaml
  - repoURL: git@github.com:VizzleTF/home-proxmox-values.git
    path: manifests/applications/immich  # Отдельные манифесты
```

**После:**
```yaml
# immich-application.yaml
sources:
  - repoURL: https://immich-app.github.io/immich-charts
    chart: immich
    helm:
      valueFiles:
        - $values/values/applications/immich.yaml
  - repoURL: https://github.com/VizzleTF/home_proxmox.git
    path: charts/homelab-common  # Общий chart
    helm:
      valueFiles:
        - $values/values/applications/immich.yaml  # Тот же файл
```

### May (workload в homelab-common)

**До:** два Helm source (`charts/may` + `charts/homelab-common`).

**После:** один source `charts/homelab-common`; Deployment/Service/PVC задаются в `homelab-common.workloads` с `profile: may` в `values/applications/may.yaml`.

## Чеклист миграции

- [ ] Создать секцию `homelab-common` в values файле
- [ ] Перенести ExternalSecrets
- [ ] Перенести HTTPRoutes
- [ ] Перенести Backup CronJobs
- [ ] Перенести RBAC (если есть)
- [ ] Перенести NetworkPolicy (если есть)
- [ ] Перенести LimitRange (если есть)
- [ ] Перенести CNPG Database (если есть)
- [ ] Обновить ArgoCD Application (добавить homelab-common source)
- [ ] Закоммитить и запушить изменения
- [ ] Дождаться успешного sync в ArgoCD
- [ ] Проверить, что все ресурсы созданы
- [ ] Удалить старые манифесты из `manifests/applications/{app}/`
- [ ] Удалить старый source с манифестами из ArgoCD Application

## Преимущества после миграции

1. **Один файл** — вся конфигурация в `values/applications/{app}.yaml`
2. **Меньше файлов** — не нужно управлять десятками отдельных манифестов
3. **Консистентность** — все приложения используют одинаковые паттерны
4. **Проще обновлять** — изменения в homelab-common применяются ко всем приложениям
5. **Типизация** — Helm валидирует структуру values

## Откат (если что-то пошло не так)

1. Удалите homelab-common source из ArgoCD Application
2. Верните старый source с манифестами
3. ArgoCD автоматически пересинхронизирует приложение
