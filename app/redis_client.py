import os
import time

from redis.backoff import ExponentialBackoff
from redis.exceptions import ConnectionError, TimeoutError
from redis.retry import Retry
from redis.sentinel import Sentinel
from redis.exceptions import ConnectionError, ResponseError, TimeoutError

from config import GROUP, STREAM

MASTER_NAME = os.getenv("REDIS_MASTER_NAME", "mymaster")

# "sentinel-1:26379,sentinel-2:26379,..." -> [("sentinel-1", 26379), ...]
SENTINELS = [
    (host, int(port))
    for host, port in (
        item.split(":") for item in os.getenv(
            "REDIS_SENTINELS",
            "sentinel-1:26379,sentinel-2:26379,sentinel-3:26379",
        ).split(",")
    )
]

# Таймауты и ретраи: во время failover (~15 с) запросы не должны падать сразу.
# Клиент пересоздаёт соединение, заново спрашивает у Sentinel адрес мастера
# и повторяет команду.
_retry = Retry(ExponentialBackoff(cap=2, base=0.1), retries=10)

sentinel = Sentinel(
    SENTINELS,
    sentinel_kwargs={"socket_timeout": 1.0, "socket_connect_timeout": 1.0},
)

# master: запись; replica: чтение (slave_for выбирает реплики по кругу)
master = sentinel.master_for(
    MASTER_NAME,
    socket_timeout=1.0,
    socket_connect_timeout=1.0,
    retry=_retry,
    retry_on_error=[ConnectionError, TimeoutError],
    decode_responses=True,
)
replica = sentinel.slave_for(
    MASTER_NAME,
    socket_timeout=1.0,
    socket_connect_timeout=1.0,
    retry=_retry,
    retry_on_error=[ConnectionError, TimeoutError],
    decode_responses=True,
)


def wait_for_redis(attempts: int = 30, delay: float = 1.0) -> None:
    """Проверка соединения при старте: ждём, пока Sentinel и мастер поднимутся."""
    for i in range(1, attempts + 1):
        try:
            addr = sentinel.discover_master(MASTER_NAME)
            # Проверяем запись, а не PING: мастер с min-replicas-to-write
            # отклоняет запись, пока к нему не подключились реплики
            master.set("startup:probe", 1, ex=10)
            print(f"Redis OK, master={addr}")
            return
        except Exception as e:
            print(f"[{i}/{attempts}] Redis not ready: {e}")
            time.sleep(delay)
    raise RuntimeError("Redis is not available")


def ensure_group() -> None:
    """Создаёт consumer group (и сам стрим), если их ещё нет."""
    try:
        master.xgroup_create(STREAM, GROUP, id="$", mkstream=True)
    except ResponseError as e:
        # группа уже существует, это нормально
        if "BUSYGROUP" not in str(e):
            raise