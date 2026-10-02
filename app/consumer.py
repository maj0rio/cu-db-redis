import socket

from config import GROUP, STREAM
from redis_client import master, wait_for_redis, ensure_group

CONSUMER = socket.gethostname()


def main() -> None:
    wait_for_redis()
    ensure_group()
    print(f"Consumer {CONSUMER} started")
    while True:
        # block < socket_timeout (1 с), иначе клиент оборвёт ожидание сам
        resp = master.xreadgroup(GROUP, CONSUMER, {STREAM: ">"}, count=10, block=500)
        for _stream, messages in resp or []:
            for msg_id, fields in messages:
                print(f"[{msg_id}] {fields}", flush=True)
                master.xack(STREAM, GROUP, msg_id)


if __name__ == "__main__":
    main()
