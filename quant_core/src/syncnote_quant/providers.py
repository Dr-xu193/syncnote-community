"""Provider contracts keep vendor semantics outside research code."""

from __future__ import annotations

from collections.abc import Sequence
from datetime import date
from typing import Protocol

from .domain import (
    AdjustmentFactor,
    Announcement,
    Bar,
    BarInterval,
    DailyFundamental,
    FinancialPointInTime,
    InstrumentId,
    InstrumentLifecycle,
    Quote,
    TradeCalendarDay,
)


class MarketDataProvider(Protocol):
    @property
    def provider_name(self) -> str: ...

    def quote(self, instrument: InstrumentId) -> Quote: ...

    def instruments(self) -> Sequence[InstrumentLifecycle]: ...

    def daily_fundamentals(
        self, instrument: InstrumentId, start: date, end: date
    ) -> Sequence[DailyFundamental]: ...

    def bars(
        self,
        instrument: InstrumentId,
        start: date,
        end: date,
        interval: BarInterval = BarInterval.DAY,
    ) -> Sequence[Bar]: ...

    def adjustment_factors(
        self, instrument: InstrumentId, start: date, end: date
    ) -> Sequence[AdjustmentFactor]: ...

    def financials(
        self, instrument: InstrumentId, start: date, end: date
    ) -> Sequence[FinancialPointInTime]: ...

    def announcements(
        self, instrument: InstrumentId, start: date, end: date
    ) -> Sequence[Announcement]: ...

    def trade_calendar(self, start: date, end: date) -> Sequence[TradeCalendarDay]: ...
