# Vertical Pod Autoscaler (VPA) Policies

Данная директория содержит VPA политики для автоматической оптимизации ресурсов подов **только в пользовательских namespace'ах**.

## Архитектура VPA (без системных namespace'ов)

### Компоненты:
1. **VPA Helm Chart** - основные компоненты (recommender, updater, admission-controller)
2. **Auto VPA Creator** - автоматическое создание VPA объектов только для пользовательских приложений
3. **System Cleanup** - очистка VPA из системных namespace'ов
4. **Admission Controller Config** - исключение системных namespace'ов

## Развертывание VPA

### 1. Установка VPA через Helmfile

```bash
# Развертывание VPA компонентов
cd helm
helmfile -f helmfiles/infrastructure.yaml apply
```

### 2. Применение VPA политик (только для пользовательских namespace'ов)

```bash
# Создание namespace и RBAC
kubectl apply -f manifests/vpa-policies/global-vpa-policy.yaml

# Конфигурация admission controller с исключениями
kubectl apply -f manifests/vpa-policies/vpa-admission-controller-config.yaml

# Автоматический создатель VPA (только для пользовательских namespace'ов)
kubectl apply -f manifests/vpa-policies/auto-vpa-creator.yaml

# Очистка VPA из системных namespace'ов (если есть)
kubectl apply -f manifests/vpa-policies/vpa-system-cleanup.yaml
```

### 3. Проверка VPA

```bash
# Проверка подов VPA
kubectl get pods -n vpa-system

# Проверка VPA только в пользовательских namespace'ах
kubectl get vpa --all-namespaces

# Проверка автоматически созданных VPA
kubectl get vpa --all-namespaces -l auto-created=true

# Убедиться что в системных namespace'ах нет VPA
kubectl get vpa -n kube-system
kubectl get vpa -n longhorn-system
kubectl get vpa -n metallb-system
```

## Исключенные системные namespace'ы

VPA **не будет применяться** к следующим namespace'ам:

### Kubernetes системные:
- `kube-system` - основные компоненты Kubernetes
- `kube-public` - публичные ресурсы
- `kube-node-lease` - lease объекты нод
- `default` - default namespace

### Инфраструктурные:
- `vpa-system` - сам VPA
- `longhorn-system` - система хранения
- `metallb-system` - load balancer
- `cert-manager` - управление сертификатами
- `ingress-nginx` - ingress controller
- `external-dns` - внешний DNS

### Дополнительные исключения:
- Все namespace'ы начинающиеся с `kube-`
- Поды с системными компонентами (kube-apiserver, etcd и т.д.)

## Как работает VPA (только пользовательские namespace'ы)

### 1. Автоматическое создание VPA объектов
- **CronJob** каждые 5 минут сканирует только пользовательские namespace'ы
- Создает VPA для Deployment/StatefulSet/DaemonSet в разрешенных namespace'ах
- **Строго исключает** все системные namespace'ы

### 2. Автоматическое применение рекомендаций
- **Admission Controller** работает только с пользовательскими namespace'ами
- Автоматически применяет VPA рекомендации
- Использует лимиты: CPU 10m-4, Memory 32Mi-8Gi

### 3. Непрерывная оптимизация
- **Recommender** анализирует метрики только пользовательских приложений
- **Updater** пересоздает поды с оптимальными ресурсами
- **updateMode: Auto** - полностью автоматический режим

## Мониторинг

```bash
# Проверка что VPA работает только с пользовательскими namespace'ами
kubectl get vpa --all-namespaces

# Логи auto-creator (должны показывать пропуски системных namespace'ов)
kubectl logs -n vpa-system -l job-name=auto-vpa-creator

# Проверка admission controller исключений
kubectl get mutatingadmissionwebhooks vpa-global-admission-controller -o yaml

# События VPA
kubectl get events --all-namespaces | grep -i vpa
```

## ✅ Безопасность

1. **Системные компоненты защищены** - VPA не влияет на Kubernetes и инфраструктурные компоненты
2. **Стабильность кластера** - исключены критически важные namespace'ы
3. **Только пользовательские приложения** - VPA оптимизирует только ваши приложения
4. **Автоматическая очистка** - удаление случайно созданных VPA в системных namespace'ах

VPA будет автоматически оптимизировать ресурсы **только пользовательских приложений**, не затрагивая критически важные системные компоненты. 