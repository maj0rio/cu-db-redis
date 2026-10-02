# GameHub: Redis с отказоустойчивостью (ДЗ №1, СУБД, Центральный университет)

Бэкенд игровой платформы GameHub: профили игроков, счётчик входов, турнирный
рейтинг, достижения и очередь уведомлений. Redis здесь единственное хранилище.
Кластер: 1 мастер, 2 реплики и 3 Sentinel для автоматического переключения.
Автор: Фадеев Иван.

## Содержание

1. [Архитектура](#архитектура)
2. [Структура репозитория](#структура-репозитория)
3. [Запуск](#запуск)
4. [API](#api)
5. [Структуры данных Redis](#структуры-данных-redis)
6. [Конфигурация Redis и Sentinel](#конфигурация-redis-и-sentinel)
7. [Отказоустойчивость и split-brain](#отказоустойчивость-и-split-brain)
8. [Проверка](#проверка)
9. [Проектные решения и ограничения](#проектные-решения-и-ограничения)

## Архитектура

```
                      ┌────────────┐  ┌────────────┐
   HTTP :8000         │ gamehub-app│  │  consumer  │  читает стрим
  ───────────────────►│  (FastAPI) │  │ (XREADGROUP)│
                      └─────┬──────┘  └─────┬──────┘
                            │ спрашивают у Sentinel адрес мастера/реплик
                            ▼
        ┌────────────┬────────────┬────────────┐
        │ sentinel-1 │ sentinel-2 │ sentinel-3 │   кворум 2 из 3
        └─────┬──────┴─────┬──────┴─────┬──────┘
              │ следят     │            │
              ▼            ▼            ▼
        ┌──────────────┐  репликация  ┌────────────────┐ ┌────────────────┐
        │ redis-master │ ───────────► │ redis-replica-1│ │ redis-replica-2│
        │   :6379      │ ───────────────────────────────►│                │
        └──────────────┘              └────────────────┘ └────────────────┘
```

Все контейнеры находятся в одной docker-сети `gamehub`.

| Компонент | Порт на хосте | Назначение |
|---|---|---|
| `redis-master` | 6379 | Запись и чтение. RDB + AOF, `volatile-lru`, защита от split-brain |
| `redis-replica-1`, `redis-replica-2` | 6380, 6381 | Только чтение, повторяют мастер |
| `sentinel-1..3` | 26379, 26380, 26381 | Обнаружение отказа и переключение мастера |
| `redis-insight` | 5540 | Веб-интерфейс (необязательный) |
| `gamehub-app` | 8000 | REST API на FastAPI |
| `gamehub-consumer` | нет | Потребитель стрима уведомлений |

Приложение подключается к Redis **только через Sentinel**. Запись идёт на мастер
(`master_for`), чтение с реплик (`slave_for`). Адрес мастера никуда не зашит: клиент
узнаёт его у Sentinel при каждом переподключении, поэтому failover происходит без
перезапуска приложения.

## Структура репозитория

```
.
├── docker-compose.yml
├── redis/
│   ├── master.conf          # конфиг мастера (redis.conf мастера)
│   └── replica.conf         # конфиг реплик
├── sentinel/
│   └── sentinel.conf
├── app/
│   ├── main.py              # приложение, lifespan, подключение роутеров
│   ├── config.py            # константы и построители ключей Redis
│   ├── schemas.py           # Pydantic-модели запросов
│   ├── redis_client.py      # клиенты Sentinel, ретраи, проверка при старте
│   ├── consumer.py          # потребитель стрима
│   ├── routers/             # players, leaderboard, achievements
│   ├── requirements.txt
│   └── Dockerfile
└── scripts/
    ├── check.sh             # собственная полная проверка
    ├── failover_demo.sh     # failover и split-brain
    ├── seed_demo.sh         # тестовые данные для демо и самопроверки
    └── self_check.py        # скрипт самопроверки от преподавателя
```

## Запуск

Требуется Docker с плагином Compose v2.

```bash
git clone https://github.com/maj0rio/cu-db-redis.git
cd cu-db-redis
docker compose up -d --build
docker compose ps
```

Проверка кластера:

```bash
docker exec redis-master redis-cli INFO replication     # connected_slaves:2
docker exec sentinel-1 redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster
curl localhost:8000/health
```

Интерактивная документация API: http://localhost:8000/docs

Полный сброс, включая данные:

```bash
docker compose down -v
```

## API

| Метод | Путь | Описание | Команды Redis |
|---|---|---|---|
| POST | `/api/players/{id}` | Создать или обновить профиль | `HSET`, `HSETNX created_at`, `DEL cache` |
| GET | `/api/players/{id}` | Профиль через кеш | `GET cache`; при промахе `HGETALL` + `SET ... EX 60` |
| PATCH | `/api/players/{id}/level` | Изменить уровень на `delta` | `HINCRBY`, `DEL cache`, `XADD notifications` |
| POST | `/api/players/{id}/login` | Зафиксировать вход | Lua: `INCR` + `EXPIRE` |
| POST | `/api/leaderboard/score` | Добавить очки | `ZINCRBY tournament:main` |
| GET | `/api/leaderboard/top?limit=10` | Топ игроков | `ZREVRANGE ... WITHSCORES` |
| GET | `/api/leaderboard/rank/{id}` | Место игрока (1 = лидер) | `ZREVRANK` |
| POST | `/api/players/{id}/achievements` | Добавить достижение | `SADD` |
| GET | `/api/players/{id}/achievements/{name}` | Есть ли достижение | `SISMEMBER` |
| GET | `/api/players/{id1}/achievements/common/{id2}` | Общие достижения | `SINTER` |
| POST | `/api/players/batch` | Массовое создание профилей | pipeline из `HSET`, `HSETNX`, `DEL` |
| GET | `/health` | Состояние и текущий мастер | `SENTINEL get-master-addr-by-name` |

Примеры:

```bash
curl -X POST localhost:8000/api/players/1 -H "Content-Type: application/json" \
     -d '{"name":"Alice","level":5,"region":"EU"}'
curl localhost:8000/api/players/1                        # "source":"db"
curl localhost:8000/api/players/1                        # "source":"cache"
curl -X PATCH localhost:8000/api/players/1/level -H "Content-Type: application/json" \
     -d '{"delta":2}'
curl -X POST localhost:8000/api/leaderboard/score -H "Content-Type: application/json" \
     -d '{"player_id":"1","score":100}'
curl "localhost:8000/api/leaderboard/top?limit=10"
```

В ответе `GET /api/players/{id}` поле `source` показывает, откуда пришли данные:
`cache` или `db`. Это дополнение к рекомендованному контракту, оно нужно для
наглядной демонстрации кеша.

## Структуры данных Redis

| Данные | Ключ | Тип | TTL | Содержимое |
|---|---|---|---|---|
| Профиль игрока | `player:{id}` | Hash | нет | `name`, `level`, `region`, `created_at` |
| Счётчик входов | `logins:{id}` | String | 24 часа | число входов за сутки |
| Кеш профиля | `cache:player:{id}` | String | 60 с | JSON профиля |
| Лидерборд | `tournament:main` | Sorted Set | нет | member = `player_id`, score = очки |
| Достижения | `achievements:{id}` | Set | нет | названия достижений |
| Уведомления | `notifications` | Stream | 7 дней | `player_id`, `type`, `message`, `timestamp` |

Все имена ключей строятся в одном месте, в `app/config.py`.

**Счётчик входов.** Lua-скрипт выполняет `INCR`, а при первом входе (результат 1) ещё
и `EXPIRE 86400`. Скрипт выполняется атомарно, поэтому счётчик не может остаться без
TTL. Окно фиксированное: сутки с первого входа.

**Кеш (cache-aside).** При запросе профиля сначала читается кеш. При промахе профиль
читается из хеша, сериализуется в JSON и записывается с `EX 60`. Любое обновление
профиля (`POST`, `PATCH`) удаляет кеш.

**Стрим уведомлений.** Группа `notifications-group` создаётся при старте приложения и
потребителя командой, эквивалентной `XGROUP CREATE notifications notifications-group $ MKSTREAM`
(повторное создание безопасно). Хранение 7 дней обеспечивает `XADD ... MINID`: при
каждом добавлении удаляются записи старше недели. Потребитель читает через
`XREADGROUP`, выводит сообщение в консоль и подтверждает его через `XACK`.

## Конфигурация Redis и Sentinel

**Мастер** (`redis/master.conf`):

| Параметр | Значение | Зачем |
|---|---|---|
| `appendonly` / `appendfsync` | `yes` / `everysec` | AOF, потеря не более ~1 с данных |
| `auto-aof-rewrite-percentage` | `100` | пересборка AOF при удвоении размера |
| `save` | `900 1`, `300 10`, `60 10000` | снапшоты RDB |
| `maxmemory` | `256mb` | лимит памяти |
| `maxmemory-policy` | `volatile-lru` | вытесняются только ключи с TTL (кеш), а профили и рейтинг нет |
| `min-replicas-to-write` | `1` | защита от split-brain |
| `min-replicas-max-lag` | `10` | реплика считается живой при отставании до 10 с |

**Реплики** (`redis/replica.conf`): `replica-read-only yes`, те же параметры
персистентности и памяти. `min-replicas-*` указаны и здесь: после failover реплика
становится мастером, и защита должна работать у нового мастера. `replicaof` и
`replica-announce-ip` передаются в `docker-compose.yml`, чтобы узлы были стабильно
известны Sentinel по именам контейнеров, а не по меняющимся IP.

**Sentinel** (`sentinel/sentinel.conf`): `sentinel monitor mymaster redis-master 6379 2`
(кворум 2 из 3), `down-after-milliseconds 5000`, `failover-timeout 10000`,
`parallel-syncs 1`, `resolve-hostnames yes`, `announce-hostnames yes`.

Конфиги копируются в контейнер при старте (`cp ... /data/redis.conf`), а не
монтируются только для чтения: Sentinel и `CONFIG REWRITE` переписывают их во время
работы.

## Отказоустойчивость и split-brain

Сценарий вручную:

```bash
# failover: остановить мастера и подождать
docker stop redis-master
sleep 15
docker exec sentinel-1 redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster
curl localhost:8000/health
curl -X POST localhost:8000/api/players/9500 -H "Content-Type: application/json" \
     -d '{"name":"Failover","level":1,"region":"EU"}'
docker start redis-master        # вернётся как реплика

# split-brain: заморозить реплики текущего мастера
docker pause redis-replica-1 redis-replica-2
sleep 15
docker exec redis-master redis-cli SET x 1   # NOREPLICAS Not enough good replicas to write.
docker unpause redis-replica-1 redis-replica-2
```

Если мастер к моменту опыта уже менялся, замораживать нужно реплики **текущего**
мастера. Автоматизированный вариант со всеми шагами: `./scripts/failover_demo.sh`.

Измеренное время переключения: около 7 секунд (5 с `down-after-milliseconds` плюс
выборы и повышение реплики).

**Как приложение переживает failover.** Клиент настроен с таймаутами по 1 с и
политикой повторов: экспоненциальный backoff от 0.2 до 2 с, до 10 повторов, в сумме
порядка 15 с. На каждый повтор клиент заново спрашивает у Sentinel адрес мастера.
Запросы во время переключения ждут и проходят уже на новом мастере.

## Проверка

| Скрипт | Что делает |
|---|---|
| `scripts/self_check.py` | самопроверка от преподавателя (нужны данные `scripts/seed_demo.sh`) |
| `scripts/check.sh` | наша проверка: инфраструктура, все эндпоинты, кеш, стрим, Lua, pipeline |
| `scripts/failover_demo.sh` | failover и split-brain |

```bash
./scripts/seed_demo.sh && python3 scripts/self_check.py
./scripts/check.sh
./scripts/failover_demo.sh
```

`self_check.py` ожидает, что мастером является контейнер `redis-master`. Запускайте его
на исходной топологии, до `failover_demo.sh` или после чистого перезапуска.

## Проектные решения и ограничения

- **Чтение с реплик и eventual consistency.** Репликация асинхронна, и сразу после
  записи реплика может на доли секунды отдавать старые данные. Поэтому при промахе кеша
  профиль читается с **мастера**: иначе устаревшее значение закешировалось бы на 60 с.
- **Место в рейтинге через `ZREVRANK`, а не `ZRANK`.** `ZRANK` считает от наименьшего
  счёта, и лидер получил бы последнее место. Топ строится через `ZREVRANGE`, поэтому
  место считается тем же порядком, начиная с 1.
- **`created_at` пишется через `HSETNX`.** В задании он указан в `HSET`, но тогда любое
  обновление профиля затирало бы дату создания.
- **Повтор неидемпотентных команд при failover.** Если команда (`INCR`, `HINCRBY`,
  `ZINCRBY`) дошла до мастера, а ответ потерялся при его падении, повтор выполнит её
  второй раз. Для учебного сервиса это допустимо; в проде нужны идемпотентные ключи
  операций.
- **Составные операции не транзакционны.** Например, `HINCRBY`, `DEL` кеша и `XADD`
  в `PATCH /level` идут отдельными командами: при падении приложения между ними
  уведомление может не отправиться. Для атомарности подошли бы `MULTI/EXEC` или Lua.
- **Холодный старт и защита от split-brain.** Пока к свежему мастеру не подключились
  реплики, `min-replicas-to-write 1` отклоняет любую запись (`NOREPLICAS`). Поэтому
  проверка готовности при старте приложения делает пробную запись, а не `PING`, и
  ждёт до 30 с.
- **`NOREPLICAS` не повторяется.** Это ошибка Redis, а не обрыв соединения, и приложение
  отвечает HTTP 500 сразу. Это осознанное поведение защиты.
- **Потребитель читает только новые сообщения (`>`).** Сообщения, оставшиеся в списке
  необработанных после падения потребителя, не перечитываются автоматически
  (для этого понадобился бы `XAUTOCLAIM`).
- **Безопасность.** Пароль и TLS не настроены (`protected-mode no`), порты открыты на
  хост. Допустимо только для учебного стенда.
- Redis здесь единственное хранилище, как задано в условии. В проде профили, рейтинг
  и достижения жили бы в основной БД, а в Redis остались бы кеш, сессии и счётчики.
