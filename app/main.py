from contextlib import asynccontextmanager

from fastapi import FastAPI

from redis_client import MASTER_NAME, ensure_group, sentinel, wait_for_redis
from routers import achievements, leaderboard, players


@asynccontextmanager
async def lifespan(app: FastAPI):
    wait_for_redis()
    ensure_group()
    yield


app = FastAPI(title="GameHub", lifespan=lifespan)

app.include_router(players.router)
app.include_router(achievements.router)
app.include_router(leaderboard.router)


@app.get("/health")
def health():
    host, port = sentinel.discover_master(MASTER_NAME)
    return {"status": "ok", "master": f"{host}:{port}"}
