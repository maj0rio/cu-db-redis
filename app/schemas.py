from pydantic import BaseModel


class PlayerIn(BaseModel):
    name: str
    level: int = 1
    region: str


class PlayerBatchItem(PlayerIn):
    id: str


class LevelDelta(BaseModel):
    delta: int


class ScoreIn(BaseModel):
    player_id: str
    score: float


class AchievementIn(BaseModel):
    name: str
