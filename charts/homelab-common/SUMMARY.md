# Homelab Common Chart - Итоги

## ✅ Что сделано

1. **Создан shared Helm chart** (`type: application` в Chart.yaml) для общих ресурсов (ExternalSecrets, HTTPRoutes, Backups, RBAC, LimitRange, CNPG Database)

2. **Один values файл** — секция `homelab-common` в основном values файле приложения

3. **Все шаблоны работают** с LF окончаниями строк

4. **Решена проблема с дефисом** в `homelab-common` через `{{ $hc := index .Values "homelab-common" }}`

## 📁 Структура

```
charts/homelab-common/
├── Chart.yaml (type: application — отдельный ArgoCD source, не Helm library chart)
├── values.yaml (defaults)
├── templates/
│   ├── externalsecret.yaml ✅
│   ├── httproute.yaml ✅
│   ├── backup-cronjob.yaml ✅
│   ├── cnpg-database.yaml ✅
│   ├── limitrange.yaml ✅
│   └── rbac.yaml ✅
├── examples/
│   └── immich-example.yaml
└── README.md
```

## 🚀 Как использовать

### 1. Добавить секцию в values файл

```yaml
# argocd/apps/myapp/values.yaml

homelab-common:
  externalSecrets:
    - name: myapp-secrets
      data:
        - secretKey: password
          property: password
      templateData:
        PASSWORD: "{{ .password }}"
  
  httpRoutes:
    - name: myapp
      hostname: myapp
      gateway: external
      service:
        name: myapp
        port: 8080

# Основные настройки приложения
image:
  tag: latest
```

### 2. Обновить ArgoCD Application

```yaml
spec:
  sources:
    - repoURL: https://charts.example.com/myapp
      chart: myapp
      helm:
        valueFiles:
          - $values/values/applications/myapp.yaml
    
    # Добавить homelab-common (опубликован в Forgejo Helm registry)
    - repoURL: https://git.example.com/api/packages/vizzle/helm
      chart: homelab-common
      targetRevision: "1.7.1"
      helm:
        valueFiles:
          - $values/values/applications/myapp.yaml  # Тот же файл!
```

## ✅ Мигрировано

- Immich ✅
- May ✅
- Nextcloud ✅
- Openclaw ✅
- Vaultwarden ✅
- Vault ✅

## 🎯 Преимущества

1. **DRY** — нет дублирования
2. **Один файл** — вся конфигурация в одном месте
3. **Консистентность** — одинаковые паттерны везде
4. **Централизованные обновления** — изменения применяются ко всем приложениям
5. **Простота** — не нужно управлять десятками отдельных манифестов
