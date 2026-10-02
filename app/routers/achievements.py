from fastapi import APIRouter

from config import achievements_key
from redis_client import master, replica
from schemas import AchievementIn

router = APIRouter(prefix="/api/players", tags=["achievements"])


@router.post("/{player_id}/achievements")
def add_achievement(player_id: str, body: AchievementIn):
    added = master.sadd(achievements_key(player_id), body.name)
    return {"player_id": player_id, "achievement": body.name, "new": bool(added)}


@router.get("/{player_id}/achievements/{name}")
def has_achievement(player_id: str, name: str):
    has = replica.sismember(achievements_key(player_id), name)
    return {"player_id": player_id, "achievement": name, "has": bool(has)}


@router.get("/{id1}/achievements/common/{id2}")
def common_achievements(id1: str, id2: str):
    common = replica.sinter(achievements_key(id1), achievements_key(id2))
    return {"common": sorted(common)}
