#!/usr/bin/env bash
# Данные для самопроверки и демо. Запуск: ./scripts/seed_demo.sh
BASE="${BASE:-http://localhost:8000}"
J='Content-Type: application/json'

curl -s -X POST "$BASE/api/players/1001" -H "$J" -d '{"name":"Alice","level":5,"region":"EU"}'; echo
curl -s -X POST "$BASE/api/players/1002" -H "$J" -d '{"name":"Bob","level":3,"region":"US"}'; echo
curl -s -X PATCH "$BASE/api/players/1001/level" -H "$J" -d '{"delta":2}'; echo
curl -s -X POST "$BASE/api/players/1001/login" -H "$J" -d '{}'; echo
curl -s -X POST "$BASE/api/leaderboard/score" -H "$J" -d '{"player_id":"1001","score":1500}'; echo
curl -s -X POST "$BASE/api/leaderboard/score" -H "$J" -d '{"player_id":"1002","score":900}'; echo
curl -s -X POST "$BASE/api/players/1001/achievements" -H "$J" -d '{"name":"first_win"}'; echo
curl -s -X POST "$BASE/api/players/1002/achievements" -H "$J" -d '{"name":"first_win"}'; echo

payload="["
for i in $(seq 2001 2020); do
  payload+="{\"id\":\"$i\",\"name\":\"Player$i\",\"level\":1,\"region\":\"EU\"},"
done
curl -s -X POST "$BASE/api/players/batch" -H "$J" -d "${payload%,}]"; echo

# Заполняем кеш последним: у него TTL 60 с
curl -s "$BASE/api/players/1001"; echo
