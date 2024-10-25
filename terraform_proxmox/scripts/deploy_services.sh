#!/bin/zsh

set -e

log() {
    echo -e "\033[1;34m$(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"
}

log "Начало развертывания сервисов"

log "Запуск Helmfile"
cd ../helm || { log "Ошибка: директория helm не найдена"; exit 1; }
helmfile apply || { log "Ошибка при применении Helmfile"; exit 1; }

log "Создание ClusterIssuer"
kubectl apply -f ../manifests/letsencrypt/ClusterIssuer.yaml || { log "Ошибка при создании ClusterIssuer"; exit 1; }
kubectl apply -f ../manifests/letsencrypt/CloudFlare_Secret.yaml || { log "Ошибка при создании CloudFlare_Secret"; exit 1; }
kubectl patch secret cloudflare-api-token -n cert-manager --type=merge -p "{\"stringData\":{\"api-token\":\"$CLOUDFLARE_TOKEN\"}}"
kubectl apply -f ../manifests/letsencrypt/CloudFlare_ClusterIssuer.yaml || { log "Ошибка при создании CloudFlare_ClusterIssuer"; exit 1; }

log "Применение конфигурации MetalLB"
kubectl apply -f ../manifests/metallb/pool.yaml || { log "Ошибка при применении конфигурации MetalLB"; exit 1; }

log "Проверка развернутых сервисов"
kubectl get pods --all-namespaces || { log "Ошибка при получении информации о подах"; exit 1; }

log "Развертывание сервисов завершено успешно"