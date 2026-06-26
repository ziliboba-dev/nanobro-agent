#!/bin/bash
set -e

echo "=== Xray VLESS + Reality Setup ==="

# Check Docker
if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker не найден. Установи Docker и повтори."
  exit 1
fi

PORT=8443

# Check port availability
if ss -tlnp | grep -q ":$PORT "; then
  echo "WARNING: Порт $PORT занят, пробую 2053..."
  PORT=2053
fi

# Generate credentials
UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519 2>/dev/null)
PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey:" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYS" | grep "(PublicKey)" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

# Force IPv4
SERVER_IP=$(curl -4 -s ifconfig.me)

# Validate keys
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
  echo "ERROR: Не удалось сгенерировать ключи. Вывод x25519:"
  echo "$KEYS"
  exit 1
fi

# Create config
mkdir -p /etc/xray

cat > /etc/xray/config.json << CONF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "www.apple.com:443",
        "xver": 0,
        "serverNames": ["www.apple.com"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
CONF

# Stop old container if exists
docker rm -f xray 2>/dev/null && echo "Старый контейнер удалён." || true

# Run Xray (entrypoint is already 'xray', so just pass subcommand)
docker run -d \
  --name xray \
  --restart unless-stopped \
  --network host \
  -v /etc/xray:/etc/xray \
  ghcr.io/xtls/xray-core:latest \
  run -c /etc/xray/config.json

sleep 2

if docker ps | grep -q xray; then
  echo ""
  echo "✓ Xray запущен на порту $PORT"
  echo ""
  echo "=== Параметры подключения ==="
  echo "Протокол:    VLESS"
  echo "Адрес:       $SERVER_IP"
  echo "Порт:        $PORT"
  echo "UUID:        $UUID"
  echo "Flow:        xtls-rprx-vision"
  echo "Security:    Reality"
  echo "Public Key:  $PUBLIC_KEY"
  echo "Short ID:    $SHORT_ID"
  echo "SNI:         www.apple.com"
  echo "Fingerprint: chrome"
  echo ""
  echo "=== Ссылка для импорта ==="
  echo "vless://$UUID@$SERVER_IP:$PORT?type=tcp&security=reality&pbk=$PUBLIC_KEY&fp=chrome&sni=www.apple.com&sid=$SHORT_ID&flow=xtls-rprx-vision#NanoBrat"
  echo ""
  echo "=== Откат ==="
  echo "docker rm -f xray && rm -rf /etc/xray"
else
  echo "ERROR: контейнер не запустился. Проверь логи: docker logs xray"
  exit 1
fi
