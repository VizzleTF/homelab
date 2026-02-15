#!/bin/zsh

set -e

log() {
    echo -e "\033[1;34m$(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"
}

log "Начало настройки Kubernetes"

# Получение информации о узлах из переменной окружения
MASTER_NODE=$(echo $KUBE_NODES | jq -r '.[0].ip')

log "Запуск Kubespray"
cd ../../kubespray || { log "Ошибка: директория kubespray не найдена"; exit 1; }
ANSIBLE_FORCE_COLOR=1 ansible-playbook -i ../home_proxmox/ansible/inventory/inventory.yaml --become --become-user=root cluster.yml || { log "Ошибка при выполнении Kubespray"; exit 1; }

log "Получение нового kubeconfig"
scp root@$MASTER_NODE:~/.kube/config ~/.kube/config || { log "Ошибка при копировании kubeconfig"; exit 1; }
sed -i'' -e "s^server:.*^server: https://$MASTER_NODE:6443^" ~/.kube/config || { log "Ошибка при обновлении kubeconfig"; exit 1; }

log "Проверка узлов кластера"
kubectl get nodes -o wide || { log "Ошибка при получении информации о узлах кластера"; exit 1; }

log "Настройка Kubernetes завершена успешно"