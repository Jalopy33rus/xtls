#!/bin/bash

set -e

echo "[1/8] Проверка Docker..."
if ! command -v docker &> /dev/null; then
  echo "[+] Устанавливаю Docker..."
  curl -fsSL https://get.docker.com | sh
fi

echo "[2/8] Включаем IPv6 в Docker..."

DOCKER_CONFIG_FILE="/etc/docker/daemon.json"

if [ ! -f "$DOCKER_CONFIG_FILE" ]; then
  echo "{}" > "$DOCKER_CONFIG_FILE"
fi

if ! grep -q '"ipv6": true' "$DOCKER_CONFIG_FILE"; then
  cat <<EOF > "$DOCKER_CONFIG_FILE"
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00:dead:beef::/64"
}
EOF
  echo "[+] Перезапускаю Docker с IPv6..."
  systemctl restart docker
else
  echo "[✓] IPv6 уже включён"
fi

echo "[3/8] Создание Docker-сети с IPv6..."
docker network inspect reality-ipv6 >/dev/null 2>&1 || docker network create \
  --driver bridge \
  --ipv6 \
  --subnet "fd00:dead:beef::/64" \
  reality-ipv6

echo "[4/8] Клонирую репозиторий XTLS Reality..."
if [ ! -d "xtls-reality-docker" ]; then
  git clone https://github.com/myelectronix/xtls-reality-docker.git
fi
cd xtls-reality-docker

echo "[5/8] Создание docker-compose.override.yml с IPv6-сетью..."
cat <<EOF > docker-compose.override.yml
services:
  xtls-reality:
    networks:
      - reality-ipv6

networks:
  reality-ipv6:
    external: true
EOF

echo "[6/8] Запускаю контейнер..."
docker compose up -d

echo "[7/8] Жду 10 секунд на инициализацию..."
sleep 10

echo "[8/8] Получаю QR-код:"
docker exec xtls-reality bash get-client-qr.sh

echo
echo "[+] Текстовая конфигурация:"
docker exec xtls-reality bash get-client-settings.sh
