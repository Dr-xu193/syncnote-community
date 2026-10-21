"""Typed, point-in-time market data used by the SyncNote quant engine."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import date, datetime
from enum import StrEnum
from typing import Any


def require_aware(value: datetime, name: str) -> None:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError(f"{name} must be timezone-aware")


class Exchange(StrEnum):
    SSE = "SSE"
    SZSE = "SZSE"
    BSE = "BSE"


class BarInterval(StrEnum):
    MINUTE = "1m"
    DAY = "1d"
    WEEK = "1w"
    MONTH = "1mo"


class FinancialStatement(StrEnum):
    INCOME = "income"
    BALANCE = "balance"
    CASHFLOW = "cashflow"
    INDICATOR = "indicator"


class MarketSession(StrEnum):
    CLOSED = "closed"
    PREOPEN = "preopen"
    MORNING = "morning"
    BREAK = "break"
    AFTERNOON = "afternoon"
    AFTER_HOURS = "after_hours"


class QualitySeverity(StrEnum):
    INFO = "info"
    WARNING = "warning"
    BLOCKING = "blocking"


class QualityCode(StrEnum):
    MISSING = "missing"
    STALE = "stale"
    FUTURE = "future"
    DUPLICATE = "duplicate"
    UNORDERED = "unordered"
    INVALID_OHLC = "invalid_ohlc"
    NEGATIVE_ACTIVITY = "negative_activity"
    SOURCE_CONFLICT = "source_conflict"
    POINT_IN_TIME_VIOLATION = "point_in_time_violation"
    MISSING_EVIDENCE = "missing_evidence"


@dataclass(frozen=True, slots=True)
class InstrumentId:
    code: str
    exchange: Exchange

    def __post_init__(self) -> None:
        if len(self.code) != 6 or not self.code.isdigit():
            raise ValueError("A-share instrument code must contain six digits")

    @property
    def canonical(self) -> str:
        return f"{self.code}.{self.exchange.value}"


@dataclass(frozen=True, slots=True)
class SourceEvidence:
    provider: str
    dataset: str
    observed_at: datetime
    fetched_at: datetime
    source_url: str = ""
    license_scope: str = "personal_research"
    provider_version: str = ""
    fields: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not self.provider.strip() or not self.dataset.strip():
            raise ValueError("source provider and dataset are required")
        require_aware(self.observed_at, "observed_at")
        require_aware(self.fetched_at, "fetched_at")


@dataclass(frozen=True, slots=True)
class Quote:
    instrument: InstrumentId
    name: str
    price: float
    previous_close: float
    open: float
    high: float
    low: float
    volume: float
    amount: float
    turnover_rate: float
    evidence: SourceEvidence
    trade_status: str = ""


@dataclass(frozen=True, slots=True)
class Bar:
    instrument: InstrumentId
    interval: BarInterval
    timestamp: datetime
    open: float
    high: float
    low: float
    close: float
    volume: float
    amount: float
    evidence: SourceEvidence

    def __post_init__(self) -> None:
        require_aware(self.timestamp, "bar timestamp")


@dataclass(frozen=True, slots=True)
class FinancialPointInTime:
    instrument: InstrumentId
    statement: FinancialStatement
    report_period: date
    published_at: datetime
    available_at: datetime
    values: Mapping[str, float | int | str | None]
    evidence: SourceEvidence
    revision: str = ""

    def __post_init__(self) -> None:
        require_aware(self.published_at, "published_at")
        require_aware(self.available_at, "available_at")
        if self.available_at < self.published_at:
            raise ValueError("available_at cannot precede published_at")


@dataclass(frozen=True, slots=True)
class Announcement:
    instrument: InstrumentId
    title: str
    published_at: datetime
    available_at: datetime
    category: str
    url: str
    evidence: SourceEvidence

    def __post_init__(self) -> None:
        require_aware(self.published_at, "published_at")
        require_aware(self.available_at, "available_at")
        if self.available_at < self.published_at:
            raise ValueError("available_at cannot precede published_at")


@dataclass(frozen=True, slots=True)
class AdjustmentFactor:
    instrument: InstrumentId
    trade_date: date
    factor: float
    available_at: datetime
    evidence: SourceEvidence

    def __post_init__(self) -> None:
        require_aware(self.available_at, "available_at")
        if self.factor <= 0:
            raise ValueError("adjustment factor must be positive")


@dataclass(frozen=True, slots=True)
class InstrumentLifecycle:
    """Point-in-time listing range used to prevent survivorship bias."""

    instrument: InstrumentId
    name: str
    industry: str
    list_date: date
    delist_date: date | None
    evidence: SourceEvidence

    def active_on(self, trade_date: date) -> bool:
        return self.list_date <= trade_date and (
            self.delist_date is None or trade_date <= self.delist_date
        )


@dataclass(frozen=True, slots=True)
class DailyFundamental:
    instrument: InstrumentId
    trade_date: date
    available_at: datetime
    market_cap: float
    pe_ttm: float | None
    pb: float | None
    turnover_rate: float | None
    evidence: SourceEvidence

    def __post_init__(self) -> None:
        require_aware(self.available_at, "available_at")
        if self.market_cap <= 0:
            raise ValueError("daily market cap must be positive")


@dataclass(frozen=True, slots=True)
class TradeCalendarDay:
    trade_date: date
    is_open: bool
    previous_open_date: date | None
    evidence: SourceEvidence


@dataclass(frozen=True, slots=True)
class QualityIssue:
    code: QualityCode
    severity: QualitySeverity
    message: str
    field_name: str = ""
    source: str = ""


@dataclass(frozen=True, slots=True)
class DataQualityReport:
    checked_at: datetime
    issues: tuple[QualityIssue, ...] = field(default_factory=tuple)
    providers: tuple[str, ...] = field(default_factory=tuple)

    def __post_init__(self) -> None:
        require_aware(self.checked_at, "checked_at")

    @property
    def is_actionable(self) -> bool:
        return not any(issue.severity == QualitySeverity.BLOCKING for issue in self.issues)

    @property
    def blocking_reasons(self) -> tuple[str, ...]:
        return tuple(
            issue.message
            for issue in self.issues
            if issue.severity == QualitySeverity.BLOCKING
        )


def evidence_to_dict(value: SourceEvidence) -> dict[str, Any]:
    return {
        "provider": value.provider,
        "dataset": value.dataset,
        "observed_at": value.observed_at.isoformat(),
        "fetched_at": value.fetched_at.isoformat(),
        "source_url": value.source_url,
        "license_scope": value.license_scope,
        "provider_version": value.provider_version,
        "fields": list(value.fields),
    }


def bar_to_dict(value: Bar) -> dict[str, Any]:
    return {
        "instrument": value.instrument.canonical,
        "interval": value.interval.value,
        "timestamp": value.timestamp.isoformat(),
        "open": value.open,
        "high": value.high,
        "low": value.low,
        "close": value.close,
        "volume": value.volume,
        "amount": value.amount,
        "evidence": evidence_to_dict(value.evidence),
    }
