"""Deterministic point-in-time event factors from normalized announcements."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from math import exp

from .domain import Announcement, require_aware


class EventKind(StrEnum):
    EARNINGS_POSITIVE = "earnings_positive"
    EARNINGS_NEGATIVE = "earnings_negative"
    BUYBACK = "buyback"
    INSIDER_INCREASE = "insider_increase"
    INSIDER_DECREASE = "insider_decrease"
    MAJOR_CONTRACT = "major_contract"
    DIVIDEND = "dividend"
    INVESTIGATION = "investigation"
    PENALTY = "penalty"
    RISK_WARNING = "risk_warning"
    DELISTING = "delisting"


DEFAULT_EVENT_SCORES: Mapping[EventKind, float] = {
    EventKind.EARNINGS_POSITIVE: 0.6,
    EventKind.EARNINGS_NEGATIVE: -0.7,
    EventKind.BUYBACK: 0.5,
    EventKind.INSIDER_INCREASE: 0.4,
    EventKind.INSIDER_DECREASE: -0.4,
    EventKind.MAJOR_CONTRACT: 0.3,
    EventKind.DIVIDEND: 0.2,
    EventKind.INVESTIGATION: -0.9,
    EventKind.PENALTY: -0.8,
    EventKind.RISK_WARNING: -0.8,
    EventKind.DELISTING: -1.0,
}


@dataclass(frozen=True, slots=True)
class EventFactorResult:
    score: float | None
    used_events: tuple[str, ...]
    ignored_unknown_categories: tuple[str, ...]


def event_factor_as_of(
    announcements: Sequence[Announcement],
    *,
    as_of: datetime,
    half_life_days: float = 30.0,
    scores: Mapping[EventKind, float] = DEFAULT_EVENT_SCORES,
) -> EventFactorResult:
    """Calculate a decayed event score without title-keyword guessing."""

    require_aware(as_of, "as_of")
    if half_life_days <= 0:
        raise ValueError("half_life_days must be positive")
    weighted = 0.0
    total_weight = 0.0
    used: list[str] = []
    unknown: set[str] = set()
    for item in sorted(announcements, key=lambda value: value.available_at):
        if item.available_at > as_of:
            continue
        try:
            kind = EventKind(item.category)
        except ValueError:
            unknown.add(item.category)
            continue
        age_days = max(0.0, (as_of - item.available_at).total_seconds() / 86400)
        weight = exp(-0.6931471805599453 * age_days / half_life_days)
        weighted += scores[kind] * weight
        total_weight += weight
        used.append(f"{kind.value}@{item.available_at.isoformat()}")
    score = max(-1.0, min(1.0, weighted / total_weight)) if total_weight else None
    return EventFactorResult(score, tuple(used), tuple(sorted(unknown)))
