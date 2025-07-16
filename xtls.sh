#!/bin/bash

set -e

# Проверка и установка программы, если отсутствует
check_install() {
  if ! command -v "$1" &>/dev/null; then
    echo "[*] Устанавливаю $1..."
    if [ "$1" = "docker" ]; then
      curl -fsSL https://get.docker.com | sh
    elif [ "$1" = "docker-compose" ]; then
      # Установка docker-compose (если не входит в docker)
      if command -v apt &>/dev/null; then
        apt update && apt install -y docker-compose
      elif command -v yum &>/dev/null; then
        yum install -y docker-compose
      else
        echo "Пожалуйста, установите docker-compose вручную"
        exit 1
      fi
    else
      if command -v apt &>/dev/null; then
        apt update && apt install -y "$1"
      elif command -v yum &>/dev/null; then
        yum install -y "$1"
      else
        echo "Пожалуйста, установите $1 вручную"
        exit 1
      fi
    fi
  fi
}

echo "=== Проверка необходимых программ ==="
check_install docker
check_install docker-compose
check_install git
check_install curl

echo "=== [1] Настройка Docker с поддержкой IPv6 ==="
DAEMON_JSON="/etc/docker/daemon.json"
IPV6_SUBNET="fd00:feed:cafe:0::/64"

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

echo "=== [2] Проверка и удаление конфликтующих Docker-сетей ==="
EXISTING_NETS=$(docker network ls --format '{{.Name}}')

for NET in $EXISTING_NETS; do
  if docker network inspect "$NET" 2>/dev/null | grep -q "$IPV6_SUBNET"; then
    echo "[!] Удаляю конфликтующую сеть: $NET"
    docker network rm "$NET" || true
  fi
done

echo "=== [3] Создание IPv6-сети Docker (reality-ipv6) ==="
if ! docker network inspect reality-ipv6 &>/dev/null; then
  docker network create \
    --driver bridge \
    --ipv6 \
    --subnet "$IPV6_SUBNET" \
    reality-ipv6
fi

echo "=== [4] Удаление предыдущего контейнера и образа ==="
docker stop xtls-reality &>/dev/null || true
docker rm xtls-reality &>/dev/null || true
docker rmi $(docker images myelectronix/xtls-reality -q) &>/dev/null || true

echo "=== [5] Переход в директорию с проектом ==="
if [ ! -d "xtls-reality-docker" ]; then
  git clone https://github.com/myelectronix/xtls-reality-docker.git
fi
cd xtls-reality-docker

echo "=== [6] Создание docker-compose.override.yml ==="
cat <<EOF > docker-compose.override.yml
services:
  xtls-reality:
    networks:
      - reality-ipv6

networks:
  reality-ipv6:
    external: true
EOF

echo "=== [7] Запуск Docker Compose ==="
docker compose up -d

echo "=== [8] Ожидание и вывод QR-кода ==="
sleep 5
docker exec xtls-reality bash get-client-qr.sh || echo "Не удалось получить QR"
echo
echo "[+] Конфигурация клиента:"
docker exec xtls-reality bash get-client-settings.sh || echo "Не удалось получить конфигурацию"

echo "✅ Установка завершена."
