#!/usr/bin/env bash
# Сценарии отказоустойчивости: failover и защита от split-brain.
# ВНИМАНИЕ: останавливает и замораживает контейнеры. Запуск: ./scripts/failover_demo.sh

BASE="${BASE:-http://localhost:8000}"
NODES=(redis-master redis-replica-1 redis-replica-2)
PAUSED=()

# Что бы ни случилось (в том числе Ctrl+C), замороженные узлы размораживаем
unfreeze() {
  for n in "${PAUSED[@]}"; do docker unpause "$n" >/dev/null 2>&1; done
}
trap unfreeze EXIT

node_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null
}

# Sentinel отдаёт имя или IP мастера, переводим в имя контейнера
master_name() {
  local addr n
  addr="$(timeout 5 docker exec sentinel-1 redis-cli -p 26379 \
    SENTINEL get-master-addr-by-name mymaster | head -1 | tr -d '\r')"
  for n in "${NODES[@]}"; do
    if [[ "$addr" == "$n" || "$addr" == "$(node_ip "$n")" ]]; then
      echo "$n"
      return
    fi
  done
}

step() { echo; echo "== $1 =="; }
post() { curl -s -m 15 -X POST "$BASE$1" -H "Content-Type: application/json" -d "$2"; }
role() { timeout 5 docker exec "$1" redis-cli INFO replication | grep '^role:' | tr -d '\r'; }
slaves() { timeout 5 docker exec "$1" redis-cli INFO replication | grep '^connected_slaves:' | tr -d '\r'; }

step "1. Мастер до остановки"
OLD="$(master_name)"
if [[ -z "$OLD" ]]; then
  echo "[FAIL] не удалось определить мастера, останавливаюсь"
  exit 1
fi
echo "Мастер: $OLD"

step "2. Останавливаем мастера ($OLD)"
docker stop "$OLD" >/dev/null
echo "Контейнер $OLD остановлен, ждём failover (до 60 с)..."
NEW=""
SECONDS=0
for _ in $(seq 1 60); do
  NEW="$(master_name)"
  if [[ -n "$NEW" && "$NEW" != "$OLD" ]]; then break; fi
  sleep 1
done
if [[ -n "$NEW" && "$NEW" != "$OLD" ]]; then
  echo "[OK] мастер сменился на $NEW за ~${SECONDS} с"
else
  echo "[FAIL] мастер не сменился за 60 с"
  docker start "$OLD" >/dev/null
  exit 1
fi

step "3. Приложение работает после failover"
curl -s -m 15 "$BASE/health"; echo
echo "Запись через API:"
post /api/players/9500 '{"name":"Failover","level":1,"region":"EU"}'; echo
echo "Чтение через API:"
curl -s -m 15 "$BASE/api/players/9500"; echo

step "4. Возвращаем старый мастер"
docker start "$OLD" >/dev/null
echo "Ждём 20 с, пока Sentinel переведёт $OLD в реплики..."
sleep 20
echo "Роль $OLD: $(role "$OLD")"
echo "У нового мастера $NEW: $(slaves "$NEW")"

step "5. Split-brain: замораживаем все реплики"
M="$(master_name)"
if [[ -z "$M" ]]; then
  echo "[FAIL] не удалось определить текущего мастера, останавливаюсь"
  exit 1
fi
echo "Текущий мастер: $M"
for n in "${NODES[@]}"; do
  if [[ "$n" != "$M" ]]; then
    docker pause "$n" >/dev/null && PAUSED+=("$n")
  fi
done
echo "Заморожены: ${PAUSED[*]}"
echo "Ждём 15 с (min-replicas-max-lag = 10)..."
sleep 15
echo "Запись напрямую в мастер (ожидаем NOREPLICAS):"
timeout 10 docker exec "$M" redis-cli SET sb_test 1
echo "Запись через API (ожидаем ошибку):"
curl -s -m 15 -o /dev/null -w 'HTTP %{http_code}\n' -X POST "$BASE/api/players/9501" \
  -H "Content-Type: application/json" -d '{"name":"Blocked","level":1,"region":"EU"}'

step "6. Размораживаем реплики"
unfreeze
PAUSED=()
echo "Ждём 15 с, пока реплики догонят мастера..."
sleep 15
echo "Запись после восстановления (ожидаем OK):"
timeout 10 docker exec "$M" redis-cli SET sb_test 1
timeout 10 docker exec "$M" redis-cli DEL sb_test player:9500 player:9501 >/dev/null
echo "У мастера $M: $(slaves "$M")"
