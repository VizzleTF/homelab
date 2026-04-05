# Homelab Common Chart - Итоги

## ✅ Что сделано

1. **Создан shared Helm chart** (`type: application` в Chart.yaml) для общих ресурсов (ExternalSecrets, HTTPRoutes, Backups, RBAC, NetworkPolicy, LimitRange, CNPG Database)

2. **Один values файл** — секция `homelab-common` в основном values файле приложения

3. **Все шаблоны работают** с LF окончаниями строк

4. **Решена проблема с дефисом** в `homelab-common` через `{{ $hc := index .Values "homelab-common" }}`

## 📁 Структура

```
home_proxmox/charts/homelab-common/
├── Chart.yaml (type: application — отдельный ArgoCD source, не Helm library chart)
├── values.yaml (defaults)
├── templates/
│   ├── externalsecret.yaml ✅
│   ├── httproute.yaml ✅
│   ├── backup-cronjob.yaml ✅
│   ├── cnpg-database.yaml ✅
│   ├── networkpolicy.yaml ✅
│   ├── limitrange.yaml ✅
│   └── rbac.yaml ✅
├── examples/
│   └── immich-example.yaml
└── README.md
```

## 🚀 Как использовать

### 1. Добавить секцию в values файл

```yaml
# home-proxmox-values/values/applications/myapp.yaml

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
    
    # Добавить homelab-common
    - repoURL: https://github.com/VizzleTF/home_proxmox.git
      path: charts/homelab-common
      targetRevision: HEAD
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
