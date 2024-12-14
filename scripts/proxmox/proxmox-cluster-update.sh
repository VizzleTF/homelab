#!/bin/bash

LOG_FILE="/var/log/proxmox-update.log"
SSH_OPTIONS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID"
UPDATES_AVAILABLE=false

get_node_ip() {
    local node=$1
    awk -v node="$node" '
    /node {/ { in_node=1 }
    in_node && /name: / && $2 == node { found=1 }
    in_node && found && /ring0_addr: / { print $2; exit }
    /}/ { if (in_node) { in_node=0; found=0 } }
    ' /etc/pve/corosync.conf
}

send_telegram_message() {
    local message="$1"
    curl -s -X POST \
        "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TELEGRAM_CHAT_ID" \
        -d "text=$message" \
        -d "parse_mode=HTML" >> /dev/null
}

log_message() {
    local message="$1"
    local error="${2:-false}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

send_report() {
    if [ "$UPDATES_AVAILABLE" = "false" ]; then
        return
    fi
    
    local update_results="$1"
    local report="📊 <b>Отчет об обновлении кластера Proxmox</b>
$(printf "%s" "$update_results")"
    send_telegram_message "$report"
}

get_cluster_nodes() {
    pvecm nodes | awk '/^[[:space:]]+[0-9]+/ {print $3}' | sed 's/(local)//'
}

check_reboot_required() {
    local is_local=$1
    local node_ip=$2
    
    if [ "$is_local" = "true" ]; then
        [ -f /var/run/reboot-required ] && return 0 || return 1
    else
        ssh $SSH_OPTIONS root@$node_ip "[ -f /var/run/reboot-required ]"
        return $?
    fi
}

update_node() {
    local node=$1
    local is_local=$2
    local node_ip
    local last_error=""
    local needs_reboot=false
    local update_status=""
    
    if [ "$is_local" = "false" ]; then
        node_ip=$(get_node_ip "$node")
        if [ -z "$node_ip" ]; then
            echo "❌ $node - ошибка: не удалось получить IP-адрес"
            return 0
        fi
    fi
    
    if [ "$is_local" = "true" ]; then
        apt-get update >/dev/null
        UPDATES=$(apt-get -s upgrade | grep -P '^\d+ upgraded' | cut -d" " -f1)
        
        if [ "$UPDATES" -gt 0 ]; then
            UPDATES_AVAILABLE=true
            if ! DEBIAN_FRONTEND=noninteractive apt-get -y upgrade >> "$LOG_FILE" 2>&1; then
                update_status="❌ $node - ошибка: сбой обновления пакетов"
            else
                apt-get -y autoremove >/dev/null 2>&1
                apt-get -y autoclean >/dev/null 2>&1
                log_message "Обновление узла $node завершено успешно"
                update_status="✅ $node"
            fi
        fi
    else
        HAS_UPDATES=$(ssh $SSH_OPTIONS root@$node_ip "apt-get update >/dev/null && apt-get -s upgrade | grep -P '^\d+ upgraded' | cut -d' ' -f1")
        
        if [ "$HAS_UPDATES" -gt 0 ]; then
            UPDATES_AVAILABLE=true
            if ! scp $SSH_OPTIONS "$0" root@$node_ip:/tmp/update-script.sh >/dev/null 2>&1; then
                update_status="❌ $node - ошибка: не удалось скопировать скрипт"
            elif ! ssh $SSH_OPTIONS root@$node_ip "chmod +x /tmp/update-script.sh && /tmp/update-script.sh --local" >> "$LOG_FILE" 2>&1; then
                update_status="❌ $node - ошибка: сбой выполнения обновления"
            else
                log_message "Обновление узла $node завершено успешно"
                update_status="✅ $node"
            fi
            ssh $SSH_OPTIONS root@$node_ip "rm /tmp/update-script.sh" >/dev/null 2>&1
        fi
    fi
    
    if [ ! -z "$update_status" ]; then
        if [[ $update_status == ✅* ]] && check_reboot_required "$is_local" "$node_ip"; then
            update_status+=" - необходима перезагрузка"
        fi
        echo "$update_status"
    fi
    return 0
}

if [ "$1" = "--local" ]; then
    update_node "$(hostname)" "true"
    exit $?
fi

NODES=$(get_cluster_nodes)
if [ -z "$NODES" ]; then
    exit 1
fi

update_results=""
for node in $NODES; do
    if [ "$node" = "$(hostname)" ]; then
        result=$(update_node "$node" "true")
    else
        result=$(update_node "$node" "false")
    fi
    [ ! -z "$result" ] && update_results+="$result
"
done

send_report "$update_results"