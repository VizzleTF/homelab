# Proxmox Cluster Update Script

Скрипт для автоматического обновления всех узлов кластера Proxmox с уведомлениями в Telegram.

## Возможности
- Автоматическое обновление всех узлов кластера
- Отправка уведомлений в Telegram об успешных обновлениях и ошибках
- Проверка необходимости перезагрузки
- Минимальное логирование
- Обновление только при наличии доступных пакетов

## Установка

```bash
# Скачать скрипт
wget -O /usr/local/sbin/proxmox-cluster-update.sh https://raw.githubusercontent.com/VizzleTF/home_proxmox/refs/heads/main/scripts/proxmox/proxmox-cluster-update.sh

# Сделать скрипт исполняемым
chmod +x /usr/local/sbin/proxmox-cluster-update.sh

# Создать файл лога
touch /var/log/proxmox-update.log
chmod 640 /var/log/proxmox-update.log
```

## Настройка Telegram

1. Создайте бота через @BotFather и получите токен
2. Получите chat_id:
   - Отправьте сообщение боту
   - Откройте: `https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates`
   - Найдите "chat":{"id": ваш_chat_id}

3. Обновите переменные в скрипте:
```bash
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID"
```

## Настройка автозапуска

Добавьте в crontab для запуска каждый день в 3:00:
```bash
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/sbin/proxmox-cluster-update.sh") | crontab -
```

## Логи

Логи обновлений доступны в:
```bash
tail -f /var/log/proxmox-update.log
```