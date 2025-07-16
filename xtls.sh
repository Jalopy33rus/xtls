#!/bin/bash

set -e

echo "=== [1] Установка Docker (если не установлен) ==="
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

echo "=== [2] Настройка Docker с поддержкой IPv6 ==="
DAEMON_JSON="/etc/docker/daemon.json"
IPV6_SUBNET="fd00:feed:cafe::/64"

if [ ! -f "$DAEMON_JSON" ]; then
  echo "{}" > "$DAEMON_JSON"
fi

if ! grep -q '"ipv6": true' "$DAEMON_JSON"; then
  cat <<EOF > "$DAEMON_JSON"
{
  "ipv6": true,
  "fixed-cidr-v6": "$IPV6_SUBNET"
}
EOF
  echo "[+] Перезапуск Docker..."
  systemctl restart docker
fi

echo "=== [3] Удаление конфликтующих Docker-сетей ==="
EXISTING_NETS=$(docker network ls --format '{{.Name}}')
for NET in $EXISTING_NETS; do
  if [[ "$NET" == "bridge" || "$NET" == "host" || "$NET" == "none" ]]; then
    continue
  fi
  if docker network inspect "$NET" | grep -q "$IPV6_SUBNET"; then
    echo "[!] Удаляю конфликтующую сеть: $NET"
    docker network rm "$NET" || true
  fi
done

echo "=== [4] Создание IPv6-сети Docker (reality-ipv6) ==="
docker network inspect reality-ipv6 &>/dev/null || docker network create \
  --driver bridge \
  --ipv6 \
  --subnet "$IPV6_SUBNET" \
  reality-ipv6

echo "=== [5] Удаление предыдущего контейнера и образа ==="
docker stop xtls-reality &>/dev/null || true
docker rm xtls-reality &>/dev/null || true
docker rmi $(docker images myelectronix/xtls-reality -q) &>/dev/null || true

echo "=== [6] Переход в директорию с проектом ==="
cd xtls-reality-docker

echo "=== [7] Создание docker-compose.override.yml ==="
cat <<EOF > docker-compose.override.yml
services:
  xtls-reality:
    networks:
      - reality-ipv6

networks:
  reality-ipv6:
    external: true
EOF

echo "=== [8] Запуск Docker Compose ==="
docker compose up -d

echo "=== [9] Ожидание и вывод QR-кода ==="
sleep 5
docker exec xtls-reality bash get-client-qr.sh || echo "Не удалось получить QR"
echo
echo "[+] Конфигурация клиента:"
docker exec xtls-reality bash get-client-settings.sh || echo "Не удалось получить конфигурацию"

echo "✅ Установка завершена."
