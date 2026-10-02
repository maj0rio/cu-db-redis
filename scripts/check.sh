#!/usr/bin/env bash
# Полная проверка GameHub. Запуск из корня репозитория: ./scripts/check.sh
set -u

BASE="${BASE:-http://localhost:8000}"
NODES=(redis-master redis-replica-1 redis-replica-2)
PASS=0
FAIL=0

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

MASTER="$(master_name)"
if [[ -z "$MASTER" ]]; then
  echo "[FAIL] не удалось определить мастера через Sentinel"
  exit 1
fi

rcli() { timeout 10 docker exec "$MASTER" redis-cli "$@"; }
cfg() { rcli CONFIG GET "$1" | tail -1 | tr -d '\r'; }
sget() {
  timeout 10 docker exec sentinel-1 redis-cli -p 26379 SENTINEL master mymaster \
    | grep -A1 "^$1\$" | tail -1 | tr -d '\r'
}

section() { echo; echo "== $1 =="; }
ok() { echo "  [OK]   $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1 -> $2"; FAIL=$((FAIL + 1)); }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "ожидали '$3', получили '$2'"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "ожидали '$3' в '$2'"; fi; }

get() { curl -s -m 15 "$BASE$1"; }
post() { curl -s -m 15 -X POST "$BASE$1" -H "Content-Type: application/json" -d "$2"; }
patch() { curl -s -m 15 -X PATCH "$BASE$1" -H "Content-Type: application/json" -d "$2"; }
code() { curl -s -m 15 -o /dev/null -w '%{http_code}' "$@"; }

cleanup() {
  local keys=(player:9001 player:9002 cache:player:9001 cache:player:9002
              logins:9001 achievements:9001 achievements:9002)
  for i in $(seq 9100 9119); do keys+=("player:$i" "cache:player:$i"); done
  rcli DEL "${keys[@]}" >/dev/null
  rcli ZREM tournament:main 9001 9002 >/dev/null
}
trap cleanup EXIT
cleanup

echo "Текущий мастер: $MASTER"

section "1. Инфраструктура"
for c in redis-master redis-replica-1 redis-replica-2 sentinel-1 sentinel-2 sentinel-3 gamehub-app gamehub-consumer; do
  eq "контейнер $c запущен" "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" "true"
done
eq "мастер имеет роль master" "$(rcli INFO replication | grep '^role:' | tr -d '\r')" "role:master"
has "репликация: connected_slaves:2" "$(rcli INFO replication)" "connected_slaves:2"
eq "appendonly yes" "$(cfg appendonly)" "yes"
eq "appendfsync everysec" "$(cfg appendfsync)" "everysec"
eq "maxmemory 256mb" "$(cfg maxmemory)" "268435456"
eq "maxmemory-policy volatile-lru" "$(cfg maxmemory-policy)" "volatile-lru"
eq "min-replicas-to-write 1" "$(cfg min-replicas-to-write)" "1"
eq "min-replicas-max-lag 10" "$(cfg min-replicas-max-lag)" "10"
eq "Sentinel: реплик 2" "$(sget num-slaves)" "2"
eq "Sentinel: других sentinel 2" "$(sget num-other-sentinels)" "2"
eq "Sentinel: quorum 2" "$(sget quorum)" "2"
has "приложение видит мастера" "$(get /health)" '"status":"ok"'

section "2. Профили и кеш"
post /api/players/9001 '{"name":"Alice","level":5,"region":"EU"}' >/dev/null
r="$(get /api/players/9001)"
has "GET: первый запрос из БД (cache miss)" "$r" '"source":"db"'
created="$(echo "$r" | grep -o '"created_at":[0-9]*')"
has "GET: второй запрос из кеша (cache hit)" "$(get /api/players/9001)" '"source":"cache"'
ttl="$(rcli TTL cache:player:9001)"
if (( ttl > 0 && ttl <= 60 )); then ok "TTL кеша в пределах 1..60 (сейчас $ttl)"; else bad "TTL кеша" "$ttl"; fi
eq "несуществующий игрок: 404" "$(code "$BASE/api/players/777777")" "404"
eq "валидация: 422 без region" "$(code -X POST "$BASE/api/players/9002" -H 'Content-Type: application/json' -d '{"name":"Bob"}')" "422"
sleep 1
post /api/players/9001 '{"name":"Alice","level":5,"region":"EU"}' >/dev/null
r="$(get /api/players/9001)"
has "обновление профиля сбросило кеш" "$r" '"source":"db"'
has "created_at не затёрт при обновлении" "$r" "$created"
sleep 1
REPLICA="$(for n in "${NODES[@]}"; do [[ "$n" != "$MASTER" ]] && echo "$n" && break; done)"
eq "данные есть на реплике ($REPLICA)" "$(timeout 10 docker exec "$REPLICA" redis-cli HGET player:9001 name | tr -d '\r')" "Alice"

section "3. Уровень и уведомления (Stream)"
before="$(rcli XLEN notifications)"
has "PATCH level +2" "$(patch /api/players/9001/level '{"delta":2}')" '"level":7'
r="$(get /api/players/9001)"
has "после PATCH кеш сброшен" "$r" '"source":"db"'
has "уровень в профиле 7" "$r" '"level":7'
after="$(rcli XLEN notifications)"
if (( after > before )); then ok "XLEN notifications вырос ($before -> $after)"; else bad "XLEN notifications" "$before -> $after"; fi
sleep 2
has "потребитель вывел уведомление" "$(timeout 10 docker logs --since 30s gamehub-consumer 2>&1)" "'player_id': '9001'"
eq "XPENDING = 0 (XACK выполнен)" "$(rcli XPENDING notifications notifications-group | head -1 | tr -d '\r')" "0"

section "4. Счётчик входов (Lua)"
post /api/players/9001/login '{}' >/dev/null
has "второй вход даёт счётчик 2" "$(post /api/players/9001/login '{}')" '"logins_today":2'
eq "GET logins:9001 = 2" "$(rcli GET logins:9001 | tr -d '\r')" "2"
ttl="$(rcli TTL logins:9001)"
if (( ttl > 86300 && ttl <= 86400 )); then ok "TTL счётчика около 24 часов ($ttl)"; else bad "TTL счётчика" "$ttl"; fi

section "5. Лидерборд (Sorted Set)"
post /api/leaderboard/score '{"player_id":"9001","score":1000000}' >/dev/null
post /api/leaderboard/score '{"player_id":"9002","score":2000000}' >/dev/null
sleep 1
has "топ: лидер 9002" "$(get '/api/leaderboard/top?limit=2')" '"place":1,"player_id":"9002"'
has "место игрока 9001 = 2" "$(get /api/leaderboard/rank/9001)" '"place":2'
has "ZINCRBY накапливает очки" "$(post /api/leaderboard/score '{"player_id":"9001","score":1500000}')" '"score":2500000.0'
sleep 1
has "после накопления 9001 первый" "$(get /api/leaderboard/rank/9001)" '"place":1'
eq "rank несуществующего: 404" "$(code "$BASE/api/leaderboard/rank/777777")" "404"
eq "limit вне диапазона: 422" "$(code "$BASE/api/leaderboard/top?limit=0")" "422"

section "6. Достижения (Set)"
has "новое достижение" "$(post /api/players/9001/achievements '{"name":"first_win"}')" '"new":true'
has "повтор: new=false" "$(post /api/players/9001/achievements '{"name":"first_win"}')" '"new":false'
post /api/players/9001/achievements '{"name":"speedrun"}' >/dev/null
post /api/players/9002/achievements '{"name":"first_win"}' >/dev/null
sleep 1
has "SISMEMBER: есть" "$(get /api/players/9001/achievements/first_win)" '"has":true'
has "SISMEMBER: нет" "$(get /api/players/9001/achievements/nope)" '"has":false'
has "SINTER: общие достижения" "$(get /api/players/9001/achievements/common/9002)" '"common":["first_win"]'

section "7. Pipeline (batch)"
payload="["
for i in $(seq 9100 9119); do
  payload+="{\"id\":\"$i\",\"name\":\"P$i\",\"level\":$((i - 9000)),\"region\":\"EU\"},"
done
payload="${payload%,}]"
r="$(post /api/players/batch "$payload")"
has "batch создал 20 профилей" "$r" '"created":20'
echo "         ответ: $r"
eq "профиль из batch в Redis" "$(rcli HGET player:9119 name | tr -d '\r')" "P9119"

echo
echo "Итог: пройдено $PASS, провалено $FAIL"
(( FAIL == 0 ))
