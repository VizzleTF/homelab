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

Добавьте homelab-common как дополнительный source:

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
          - $values/values/applications/myapp.yaml  # Тот же файл!
    
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

### May (custom chart)

**До:**
```yaml
# may-application.yaml
sources:
  - repoURL: https://github.com/VizzleTF/home_proxmox.git
    path: charts/may
  - repoURL: git@github.com:VizzleTF/home-proxmox-values.git
    path: manifests/applications/may  # Отдельные манифесты
```

**После:**
```yaml
# may-application.yaml
sources:
  - repoURL: https://github.com/VizzleTF/home_proxmox.git
    path: charts/may
    helm:
      valueFiles:
        - $values/values/applications/may.yaml
  - repoURL: https://github.com/VizzleTF/home_proxmox.git
    path: charts/homelab-common
    helm:
      valueFiles:
        - $values/values/applications/may.yaml  # Тот же файл
```

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
