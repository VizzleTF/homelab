# Security Configuration Guide

Этот проект содержит файлы-примеры с замещенными паролями для безопасности. Чувствительные данные исключены из системы контроля версий.

## Настройка перед использованием

### 1. Terraform конфигурация
Скопируйте файл-пример и настройте реальные данные:
```bash
cp terraform_proxmox/provider_vars_example.tf terraform_proxmox/provider_vars.tf
```
Отредактируйте `terraform_proxmox/provider_vars.tf` и замените:
- `change_me` на реальные пароли
- `YOUR_PROXMOX_IP` на IP адрес вашего Proxmox сервера

### 2. Kubernetes Secrets
Создайте реальные файлы секретов из примеров:

#### Keycloak Secret
```bash
cp manifests/keycloak/secret_example.yaml manifests/keycloak/secret.yaml
```
Отредактируйте файл и замените пароль (используйте base64 кодирование):
```bash
echo -n 'your_real_password' | base64
```

#### CloudFlare Secret
```bash
cp manifests/letsencrypt/CloudFlare_Secret_example.yaml manifests/letsencrypt/CloudFlare_Secret.yaml
```
Замените `change_me` на ваш реальный CloudFlare API токен.

#### Proxmox Secret
```bash
cp manifests/cluster-status/proxmox_secret_example.yaml manifests/cluster-status/proxmox_secret.yaml
```
Отредактируйте файл и замените base64 закодированные значения.

#### Crossplane Keycloak Provider Config
```bash
cp manifests/crossplane/keycloak-provider-config_example.yaml manifests/crossplane/keycloak-provider-config.yaml
```
Замените `change_me` и `YOUR_KEYCLOAK_URL` на реальные значения.

### 3. Helm Values
Создайте реальные файлы значений из примеров:

#### Nextcloud Values
```bash
cp helm/values/nextcloud.values_example.yaml helm/values/nextcloud.values.yaml
```
Замените:
- `change_me` на реальные пароли
- `YOUR_NEXTCLOUD_DOMAIN` на ваш домен
- `YOUR_NFS_SERVER_IP` и `YOUR_LOAD_BALANCER_IP` при необходимости

#### Keycloak Values
```bash
cp helm/values/keycloak.values_example.yaml helm/values/keycloak.values.yaml
```
Замените `change_me` на реальные пароли базы данных.

## Файлы исключенные из Git

Следующие файлы содержат чувствительную информацию и исключены из системы контроля версий:

### Terraform
- `terraform_proxmox/provider_vars.tf`

### Kubernetes Secrets
- `manifests/keycloak/secret.yaml`
- `manifests/letsencrypt/CloudFlare_Secret.yaml`
- `manifests/cluster-status/proxmox_secret.yaml`
- `manifests/crossplane/keycloak-provider-config.yaml`

### Helm Values
- `helm/values/nextcloud.values.yaml`
- `helm/values/keycloak.values.yaml`

## Генерация паролей

Для генерации надежных паролей используйте:
```bash
# Генерация случайного пароля
openssl rand -base64 32

# Для base64 кодирования
echo -n 'your_password' | base64

# Для декодирования base64
echo 'encoded_password' | base64 -d
```

## Важные замечания

1. **НИКОГДА** не добавляйте файлы с реальными паролями в Git
2. Используйте разные пароли для разных сервисов
3. Регулярно обновляйте пароли
4. Храните пароли в менеджере паролей
5. Используйте сложные пароли (минимум 16 символов)

## Проверка безопасности

Перед коммитом всегда проверяйте, что чувствительные данные не попали в репозиторий:
```bash
git status
git diff --cached
``` 