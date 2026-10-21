"""Survivorship-free A-share universe construction."""

from __future__ import annotations

from collections.abc import Sequence
from datetime import date

from .domain import InstrumentId, InstrumentLifecycle


def active_universe_as_of(
    lifecycles: Sequence[InstrumentLifecycle], trade_date: date
) -> tuple[InstrumentId, ...]:
    active = {item.instrument for item in lifecycles if item.active_on(trade_date)}
    return tuple(sorted(active, key=lambda item: item.canonical))


def membership_by_date(
    lifecycles: Sequence[InstrumentLifecycle], dates: Sequence[date]
) -> dict[date, tuple[InstrumentId, ...]]:
    return {
        day: active_universe_as_of(lifecycles, day)
        for day in sorted(set(dates))
    }
