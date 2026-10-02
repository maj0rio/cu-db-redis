from fastapi import APIRouter, HTTPException, Query

from config import LEADERBOARD
from redis_client import master, replica
from schemas import ScoreIn

router = APIRouter(prefix="/api/leaderboard", tags=["leaderboard"])


@router.post("/score")
def add_score(body: ScoreIn):
    """Прибавляет очки игроку (создаёт его в рейтинге при необходимости)."""
    total = master.zincrby(LEADERBOARD, body.score, body.player_id)
    return {"player_id": body.player_id, "score": total}


@router.get("/top")
def top(limit: int = Query(10, ge=1, le=100)):
    """Топ игроков по убыванию очков."""
    rows = replica.zrevrange(LEADERBOARD, 0, limit - 1, withscores=True)
    return [
        {"place": i + 1, "player_id": member, "score": score}
        for i, (member, score) in enumerate(rows)
    ]


@router.get("/rank/{player_id}")
def rank(player_id: str):
    """Место игрока (1 = лидер). ZREVRANK, потому что рейтинг по убыванию."""
    pos = replica.zrevrank(LEADERBOARD, player_id)
    if pos is None:
        raise HTTPException(status_code=404, detail="Player not in leaderboard")
    return {"player_id": player_id, "place": pos + 1}
