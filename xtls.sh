#!/bin/bash

set -e

install_package() {
  local pkg=$1
  echo "[*] Установка пакета: $pkg"
  if command -v apt-get &>/dev/null; then
    apt-get update && apt-get install -y "$pkg"
  elif command -v yum &>/dev/null; then
    yum install -y "$pkg"
  else
    echo "❌ Неизвестный пакетный менеджер, установите $pkg вручную." >&2
    exit 1
  fi
}

echo "=== [0] Проверка и установка необходимых программ ==="

# Проверка docker
if ! command -v docker &>/dev/null; then
  echo "[*] Docker не найден. Устанавливаем..."
  curl -fsSL https://get.docker.com | sh
else
  echo "[+] Docker установлен."
fi

# Проверка docker-compose
if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
  echo "[*] Docker Compose не найден. Устанавливаем..."
  if command -v apt-get &>/dev/null; then
    install_package docker-compose-plugin
  else
    echo "❌ Docker Compose нужно установить вручную." >&2
    exit 1
  fi
else
  echo "[+] Docker Compose установлен."
fi

# Проверка jq
if ! command -v jq &>/dev/null; then
  echo "[*] jq не найден. Устанавливаем..."
  install_package jq
else
  echo "[+] jq установлен."
fi

DAEMON_JSON="/etc/docker/daemon.json"
BASE_SUBNET_PREFIX="fd00:feed:cafe"
SUBNET_SUFFIX_RANGE=($(seq 0 255))

find_free_subnet() {
  for i in "${SUBNET_SUFFIX_RANGE[@]}"; do
    subnet="${BASE_SUBNET_PREFIX}::$i::/64"
    conflict=false
    for net in $(docker network ls -q); do
      docker network inspect "$net" | grep -q "$subnet" && conflict=true && break
    done
    if [ "$conflict" = false ]; then
      echo "$subnet"
      return 0
    fi
  done
  echo "❌ Не удалось найти свободную подсеть." >&2
  exit 1
}

echo "=== [1] Поиск свободной подсети IPv6 ==="
FREE_SUBNET=$(find_free_subnet)
echo "[+] Используем подсеть: $FREE_SUBNET"

echo "=== [2] Настройка Docker с IPv6 ==="
if [ ! -f "$DAEMON_JSON" ]; then
  echo "{}" > "$DAEMON_JSON"
fi

# Удаляем старые ipv6 настройки
sed -i '/"ipv6":/d' "$DAEMON_JSON" || true
sed -i '/"fixed-cidr-v6":/d' "$DAEMON_JSON" || true

jq --arg subnet "$FREE_SUBNET" '. + { "ipv6": true, "fixed-cidr-v6": $subnet }' "$DAEMON_JSON" > "${DAEMON_JSON}.tmp" && mv "${DAEMON_JSON}.tmp" "$DAEMON_JSON"

echo "[+] Перезапуск Docker..."
systemctl restart docker

echo "=== [3] Удаление конфликтующих пользовательских сетей ==="
EXISTING_NETS=$(docker network ls --format '{{.Name}}')
for NET in $EXISTING_NETS; do
  if [[ "$NET" == "bridge" || "$NET" == "host" || "$NET" == "none" ]]; then
    continue
  fi
  if docker network inspect "$NET" | grep -q "$FREE_SUBNET"; then
    echo "[!] Удаляю конфликтующую сеть: $NET"
    docker network rm "$NET" || true
  fi
done

echo "=== [4] Создание сети Docker (reality-ipv6) ==="
docker network inspect reality-ipv6 &>/dev/null || docker network create \
  --driver bridge \
  --ipv6 \
  --subnet "$FREE_SUBNET" \
  reality-ipv6

echo "=== [5] Удаление предыдущего контейнера и образа ==="
docker stop xtls-reality &>/dev/null || true
docker rm xtls-reality &>/dev/null || true
docker rmi $(docker images myelectronix/xtls-reality -q) &>/dev/null || true

echo "=== [6] Переход в директорию проекта ==="
cd xtls-reality-docker || {
  echo "❌ Директория xtls-reality-дocker не найдена"
  exit 1
}

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
