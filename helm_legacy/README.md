# Helm Configuration Structure

Эта структура организует Helm charts в модульные группы для лучшей управляемости и порядка развертывания.

## Структура файлов

```
helm/
├── helmfile.yaml                    # Главный файл, включающий все группы
├── helmfiles/                       # Модульные helmfile группы
│   ├── defaults.yaml               # Общие настройки и environments
│   ├── repositories.yaml           # Helm репозитории
│   ├── infrastructure.yaml         # Базовая инфраструктура
│   ├── network.yaml               # Сетевые сервисы и DNS
│   ├── security.yaml              # Безопасность и аутентификация  
│   ├── gitops.yaml                # GitOps и Infrastructure as Code
│   ├── applications.yaml          # Пользовательские приложения
│   └── not_used.yaml              # Неиспользуемые/экспериментальные компоненты
├── values/                         # Values файлы, организованные по группам
│   ├── infrastructure/            # Values для базовой инфраструктуры
│   ├── network/                   # Values для сетевых сервисов
│   ├── security/                  # Values для безопасности
│   ├── gitops/                    # Values для GitOps платформ
│   ├── applications/              # Values для приложений
│   └── not_used/                  # Values для неиспользуемых компонентов
└── docs/                          # Документация
```

## Порядок развертывания

Группы развертываются в следующем порядке:

### 1. Infrastructure (`infrastructure.yaml`)
Базовая инфраструктура кластера, которая должна быть развернута первой:
- **reflector** - репликация секретов/конфигмапов между namespace
- **longhorn** - распределенное block storage
- **metallb** - bare-metal load balancer
- **ingress-nginx** - ingress controller
- **cert-manager** - автоматическое управление TLS сертификатами
- **metrics-server** - сбор метрик ресурсов кластера

### 2. Network (`network.yaml`)
Сетевые сервисы и DNS:
- **external-dns** - автоматическое создание DNS записей в Cloudflare
- **pihole-****** - DNS фильтрация и блокировка рекламы
  - pihole-secret
  - pihole-externaldns-rbac  
  - pihole-externaldns
  - pihole

### 3. Security (`security.yaml`)
Безопасность и аутентификация:
- **keycloak-****** - Identity Provider и Single Sign-On
  - keycloak-secret
  - keycloak-ingress
  - keycloak

### 4. GitOps (`gitops.yaml`)
Платформы управления и Infrastructure as Code:
- **argocd** - GitOps continuous deployment
- **crossplane** - Infrastructure as Code platform
- **crossplane-keycloak-provider** - интеграция Crossplane с Keycloak

### 5. Applications (`applications.yaml`)
Пользовательские приложения:
- **vaultwarden** - самоуправляемый Bitwarden сервер
- **nextcloud** - облачное хранилище и офисный пакет
- **cluster-status-app** - мониторинг статуса кластера

### 6. Not Used (`not_used.yaml`)
Неиспользуемые/экспериментальные компоненты (по умолчанию отключен):
- Monitoring stack (Prometheus, Grafana)
- AI/LLM платформы (Ollama, Open WebUI)
- Home automation (Home Assistant)
- Торрент сервер и альтернативные storage решения

## Команды управления

### Развертывание всех сервисов:
```bash
cd helm/
helmfile apply
```

### Развертывание отдельной группы:
```bash
helmfile -f helmfiles/infrastructure.yaml apply
helmfile -f helmfiles/network.yaml apply
helmfile -f helmfiles/security.yaml apply
helmfile -f helmfiles/gitops.yaml apply
helmfile -f helmfiles/applications.yaml apply
```

### Просмотр планируемых изменений:
```bash
helmfile diff
```

### Удаление всех релизов:
```bash
helmfile destroy
```

## Активация экспериментальных компонентов

Для включения компонентов из `not_used.yaml`, раскомментируйте соответствующую строку в главном `helmfile.yaml`:

```yaml
helmfiles:
  # ... другие группы ...
  - path: ./helmfiles/not_used.yaml  # Раскомментировать эту строку
```

## Кастомизация

- **Values файлы**: Организованы по группам в `values/` директории:
  - `values/infrastructure/` - настройки базовой инфраструктуры
  - `values/network/` - конфигурации сетевых сервисов
  - `values/security/` - настройки безопасности и аутентификации
  - `values/gitops/` - конфигурации GitOps платформ
  - `values/applications/` - настройки пользовательских приложений
  - `values/not_used/` - конфигурации неиспользуемых компонентов
- **Secrets**: Манифесты секретов находятся в `../manifests/` 
- **Environments**: Настройки окружений в `defaults.yaml`