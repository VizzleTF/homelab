#!/bin/zsh

set -e

log() {
    echo -e "\033[1;34m$(date '+%Y-%m-%d %H:%M:%S') - $1\033[0m"
}

log "Начало подготовки окружения"

# Получение информации о узлах из переменной окружения
NODES=$(echo $KUBE_NODES | jq -r '.[] | .ip')

log "Обновление SSH ключей"
for NODE in $NODES; do
    if ! ssh-keygen -F $NODE > /dev/null; then
        ssh-keyscan $NODE >> ~/.ssh/known_hosts || { log "Ошибка при добавлении $NODE в known_hosts"; exit 1; }
    fi
done

log "Запуск Ansible"
cd ../ansible || { log "Ошибка: директория ansible не найдена"; exit 1; }
ANSIBLE_FORCE_COLOR=1 ansible-playbook playbooks/oracle_new_vm.yaml -i inventory/inventory.yaml || { log "Ошибка при выполнении Ansible playbook"; exit 1; }

log "Подготовка окружения завершена успешно"