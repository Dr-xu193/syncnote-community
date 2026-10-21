"""China-market time handling independent of the computer time zone."""

from __future__ import annotations

from collections.abc import Callable, Collection
from datetime import UTC, date, datetime, time, timedelta, timezone
from enum import StrEnum

BEIJING_TZ = timezone(timedelta(hours=8), name="Asia/Shanghai")

# SSE announcement [2025] No.45. Weekend dates are handled by weekday logic.
MAINLAND_HOLIDAYS_2026 = frozenset(
    {
        date(2026, 1, 1),
        date(2026, 1, 2),
        date(2026, 2, 16),
        date(2026, 2, 17),
        date(2026, 2, 18),
        date(2026, 2, 19),
        date(2026, 2, 20),
        date(2026, 2, 23),
        date(2026, 4, 6),
        date(2026, 5, 1),
        date(2026, 5, 4),
        date(2026, 5, 5),
        date(2026, 6, 19),
        date(2026, 9, 25),
        date(2026, 10, 1),
        date(2026, 10, 2),
        date(2026, 10, 5),
        date(2026, 10, 6),
        date(2026, 10, 7),
    }
)
MAINLAND_CALENDAR_VERSION = "SSE-2025-45/2026"
MAINLAND_CALENDAR_SOURCE = (
    "https://www.sse.com.cn/disclosure/announcement/general/"
    "c/c_20251222_10802507.shtml"
)


class MarketPhase(StrEnum):
    CLOSED = "closed"
    PREOPEN = "preopen"
    MORNING = "morning"
    BREAK = "break"
    AFTERNOON = "afternoon"
    AFTER_HOURS = "after_hours"


class FixedBeijingMarketClock:
    def __init__(self, now: Callable[[], datetime] | None = None) -> None:
        self._now = now or (lambda: datetime.now(UTC))

    def now(self) -> datetime:
        value = self._now()
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("clock must return a timezone-aware datetime")
        return value.astimezone(BEIJING_TZ)

    @staticmethod
    def to_beijing(value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("datetime must be timezone-aware")
        return value.astimezone(BEIJING_TZ)

    def phase(
        self,
        value: datetime | None = None,
        *,
        holidays: Collection[date] | None = None,
        extra_open_days: Collection[date] = (),
    ) -> MarketPhase:
        current = self.to_beijing(value) if value is not None else self.now()
        day = current.date()
        effective_holidays = MAINLAND_HOLIDAYS_2026 if holidays is None else holidays
        if day in extra_open_days:
            open_day = True
        else:
            open_day = current.weekday() < 5 and day not in effective_holidays
        if not open_day:
            return MarketPhase.CLOSED
        wall = current.time().replace(tzinfo=None)
        if time(9, 15) <= wall < time(9, 30):
            return MarketPhase.PREOPEN
        if time(9, 30) <= wall <= time(11, 30):
            return MarketPhase.MORNING
        if time(11, 30) < wall < time(13, 0):
            return MarketPhase.BREAK
        if time(13, 0) <= wall <= time(15, 0):
            return MarketPhase.AFTERNOON
        return MarketPhase.AFTER_HOURS
