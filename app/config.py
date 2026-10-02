"""Константы и схема ключей Redis."""

CACHE_TTL = 60                         # сек, кеш профиля
LOGIN_TTL = 24 * 3600                  # сек, счётчик входов
STREAM_RETENTION_SEC = 7 * 24 * 3600   # хранение уведомлений в стриме

STREAM = "notifications"
GROUP = "notifications-group"
LEADERBOARD = "tournament:main"


def player_key(player_id: str) -> str:
    return f"player:{player_id}"


def cache_key(player_id: str) -> str:
    return f"cache:player:{player_id}"


def logins_key(player_id: str) -> str:
    return f"logins:{player_id}"


def achievements_key(player_id: str) -> str:
    return f"achievements:{player_id}"
