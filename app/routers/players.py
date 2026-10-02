import json
import time

from fastapi import APIRouter, HTTPException

from config import (
    CACHE_TTL, LOGIN_TTL, STREAM, STREAM_RETENTION_SEC,
    cache_key, logins_key, player_key,
)
from redis_client import master, replica
from schemas import LevelDelta, PlayerBatchItem, PlayerIn

router = APIRouter(prefix="/api/players", tags=["players"])

# INCR и EXPIRE должны выполниться атомарно: Lua-скрипт Redis исполняет целиком.
# TTL ставится только при первом входе, поэтому окно фиксированное: 24 часа.
LOGIN_LUA = """
local count = redis.call('INCR', KEYS[1])
if count == 1 then
    redis.call('EXPIRE', KEYS[1], ARGV[1])
end
return count
"""
login_script = master.register_script(LOGIN_LUA)


# ВАЖНО: /batch объявлен выше /{player_id}, иначе "batch" попадёт в player_id.
@router.post("/batch")
def batch_create(players: list[PlayerBatchItem]):
    """Массовое создание профилей одним pipeline."""
    start = time.perf_counter()
    now = int(time.time())
    # transaction=False: нужна экономия round-trip, а не атомарность пачки
    with master.pipeline(transaction=False) as pipe:
        for p in players:
            key = player_key(p.id)
            pipe.hset(key, mapping={"name": p.name, "level": p.level, "region": p.region})
            pipe.hsetnx(key, "created_at", now)
            pipe.delete(cache_key(p.id))
        pipe.execute()
    elapsed_ms = (time.perf_counter() - start) * 1000
    return {"created": len(players), "elapsed_ms": round(elapsed_ms, 2)}


@router.post("/{player_id}")
def upsert_player(player_id: str, player: PlayerIn):
    """Создаёт или обновляет профиль, сбрасывает кеш."""
    key = player_key(player_id)
    master.hset(key, mapping={
        "name": player.name,
        "level": player.level,
        "region": player.region,
    })
    # created_at пишем только при создании, чтобы обновление его не затирало
    master.hsetnx(key, "created_at", int(time.time()))
    master.delete(cache_key(player_id))
    return {"status": "ok", "id": player_id}


@router.get("/{player_id}")
def get_player(player_id: str):
    """Профиль с кешем (cache-aside, TTL 60 с)."""
    cached = replica.get(cache_key(player_id))
    if cached:
        return {**json.loads(cached), "source": "cache"}

    # промах: читаем с мастера, чтобы не закешировать устаревшие данные реплики
    data = master.hgetall(player_key(player_id))
    if not data:
        raise HTTPException(status_code=404, detail="Player not found")

    profile = {
        "id": player_id,
        "name": data["name"],
        "level": int(data["level"]),
        "region": data["region"],
        "created_at": int(data["created_at"]),
    }
    master.set(cache_key(player_id), json.dumps(profile), ex=CACHE_TTL)
    return {**profile, "source": "db"}


@router.patch("/{player_id}/level")
def change_level(player_id: str, body: LevelDelta):
    """Меняет уровень, сбрасывает кеш, отправляет уведомление в стрим."""
    key = player_key(player_id)
    if not master.exists(key):
        raise HTTPException(status_code=404, detail="Player not found")

    new_level = master.hincrby(key, "level", body.delta)
    master.delete(cache_key(player_id))

    now = int(time.time())
    master.xadd(
        STREAM,
        {
            "player_id": player_id,
            "type": "level_changed",
            "message": f"Level changed by {body.delta}, now {new_level}",
            "timestamp": now,
        },
        # хранение 7 дней: удаляем записи старше порога
        minid=(now - STREAM_RETENTION_SEC) * 1000,
    )
    return {"id": player_id, "level": new_level}


@router.post("/{player_id}/login")
def login(player_id: str):
    """Фиксирует вход: счётчик за сутки."""
    count = login_script(keys=[logins_key(player_id)], args=[LOGIN_TTL])
    return {"id": player_id, "logins_today": count}
