# Lampac Docker Update Script

Скрипт для автоматического обновления Docker контейнера Lampac с уведомлениями в Telegram.

## Возможности
- Автоматическая проверка новых версий образа Docker
- Уведомления в Telegram при обновлениях
- Тестирование уведомлений
- Логирование обновлений
- Обновление только при наличии новой версии

## Установка

```bash
# Скачать скрипт
wget -O /root/lampac_update.sh https://raw.githubusercontent.com/VizzleTF/home_proxmox/refs/heads/main/sripts/lampac/lampac_update.sh

# Сделать скрипт исполняемым
chmod +x /root/lampac_update.sh

# Создать файл лога
touch /var/log/lampac_update.log
chmod 640 /var/log/lampac_update.log
```

## Настройка Telegram

1. Создайте бота через @BotFather и получите токен
2. Получите chat_id:
   - Отправьте сообщение боту
   - Откройте: `https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates`
   - Найдите "chat":{"id": ваш_chat_id}

3. Обновите переменные в скрипте:
```bash
BOT_TOKEN="YOUR_BOT_TOKEN"
CHAT_ID="YOUR_CHAT_ID"
```

## Настройка автозапуска

Добавьте в crontab для запуска каждый день в 4:00:
```bash
echo "0 4 * * * /root/lampac_update.sh >> /var/log/lampac_update.log 2>&1" >> /etc/crontab
```

## Логи

Логи обновлений доступны в:
```bash
tail -f /var/log/lampac_update.log
```