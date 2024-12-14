#!/bin/bash

# Set variables
CONTAINER_NAME="lampac"
IMAGE_NAME="immisterio/lampac"
PORT="9118"

# Telegram settings
BOT_TOKEN="YOUR_BOT_TOKEN"
CHAT_ID="YOUR_CHAT_ID"

# Function to send telegram message
send_telegram_message() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML"
}

# Function to test telegram notifications
test_notifications() {
    echo "Testing Telegram notifications..."
    
    MESSAGE="🔄 <b>Lampac Update [TEST]</b>
📦 This is a test notification
🕒 Time: $(date '+%Y-%m-%d %H:%M:%S')
✅ If you see this message, notifications are working!"
    
    send_telegram_message "$MESSAGE"
    echo "Test message sent. Please check your Telegram."
    exit 0
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --test) test_notifications ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Force update manifest from registry
docker pull -q $IMAGE_NAME > /dev/null 2>&1

# Get local image digest
LOCAL_DIGEST=$(docker images --digests $IMAGE_NAME | grep latest | awk '{print $3}')
if [ -z "$LOCAL_DIGEST" ]; then
    echo "No local image found. Will proceed with initial pull."
    NEEDS_UPDATE=1
else
    # Get remote image digest
    REMOTE_DIGEST=$(docker image inspect $IMAGE_NAME | grep -m1 -A1 RepoDigests | grep sha | cut -d'"' -f2 | cut -d"@" -f2)
    
    # Compare digests
    if [ "$LOCAL_DIGEST" != "$REMOTE_DIGEST" ]; then
        echo "New version available!"
        NEEDS_UPDATE=1
    else
        echo "Already running the latest version."
        NEEDS_UPDATE=0
    fi
fi

if [ $NEEDS_UPDATE -eq 1 ]; then
    UPDATE_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Check if container exists and stop it
    if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
        echo "Stopping running container..."
        docker stop $CONTAINER_NAME
    fi

    # Remove existing container
    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        echo "Removing old container..."
        docker rm $CONTAINER_NAME
    fi

    # Start new container
    echo "Starting new container..."
    docker run -d \
        -p $PORT:$PORT \
        --restart always \
        --name $CONTAINER_NAME \
        $IMAGE_NAME

    UPDATE_END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Send notification only when update actually happened
    MESSAGE="🔄 <b>Lampac Update</b>
📦 Update completed successfully!
🕒 Start time: ${UPDATE_START_TIME}
⏱ End time: ${UPDATE_END_TIME}
🆔 New digest: ${REMOTE_DIGEST:0:12}..."
    
    send_telegram_message "$MESSAGE"
    echo "Update completed successfully!"
fi

# Show running container
docker ps | grep $CONTAINER_NAME