"""Explainable cross-sectional factors with point-in-time inputs."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from math import log, sqrt
from statistics import fmean, median, pstdev

from .domain import DailyFundamental, FinancialPointInTime, InstrumentId, require_aware


class StrategyProfile(StrEnum):
    QUALITY_VALUE = "quality_value"
    MEDIUM_TREND = "medium_trend"
    EVENT_OBSERVATION = "event_observation"


FACTOR_NAMES = (
    "quality",
    "growth",
    "value",
    "momentum",
    "low_volatility",
    "liquidity",
    "event",
)


PROFILE_WEIGHTS: Mapping[StrategyProfile, Mapping[str, float]] = {
    StrategyProfile.QUALITY_VALUE: {
        "quality": 0.25,
        "growth": 0.15,
        "value": 0.25,
        "momentum": 0.10,
        "low_volatility": 0.10,
        "liquidity": 0.10,
        "event": 0.05,
    },
    StrategyProfile.MEDIUM_TREND: {
        "quality": 0.10,
        "growth": 0.10,
        "value": 0.00,
        "momentum": 0.40,
        "low_volatility": 0.20,
        "liquidity": 0.15,
        "event": 0.05,
    },
    StrategyProfile.EVENT_OBSERVATION: {
        "quality": 0.10,
        "growth": 0.15,
        "value": 0.05,
        "momentum": 0.20,
        "low_volatility": 0.10,
        "liquidity": 0.10,
        "event": 0.30,
    },
}


@dataclass(frozen=True, slots=True)
class FactorInput:
    """One point-in-time cross-section row.

    ROE and year-on-year growth use percentage points. Cash-flow/profit and
    debt ratio use decimal ratios. ``event_score`` is deterministic and must be
    evidence-backed in the range [-1, 1].
    """

    instrument: InstrumentId
    as_of: datetime
    industry: str
    market_cap: float
    closes: tuple[float, ...]
    amounts: tuple[float, ...]
    pe_ttm: float | None = None
    pb: float | None = None
    roe: float | None = None
    revenue_yoy: float | None = None
    profit_yoy: float | None = None
    operating_cashflow_to_profit: float | None = None
    debt_ratio: float | None = None
    event_score: float | None = None

    def __post_init__(self) -> None:
        require_aware(self.as_of, "factor as_of")
        if self.market_cap <= 0:
            raise ValueError("market_cap must be positive")
        if any(value <= 0 for value in self.closes):
            raise ValueError("factor closes must be positive")
        if any(value < 0 for value in self.amounts):
            raise ValueError("factor amounts cannot be negative")
        if self.event_score is not None and not -1 <= self.event_score <= 1:
            raise ValueError("event_score must be between -1 and 1")


@dataclass(frozen=True, slots=True)
class RawFactorVector:
    instrument: InstrumentId
    as_of: datetime
    industry: str
    market_cap: float
    values: Mapping[str, float | None]
    coverage: float


@dataclass(frozen=True, slots=True)
class FactorScore:
    instrument: InstrumentId
    profile: StrategyProfile
    composite: float
    normalized: Mapping[str, float]
    contributions: Mapping[str, float]
    coverage: float


def latest_financial_values_as_of(
    values: Sequence[FinancialPointInTime], as_of: datetime
) -> Mapping[str, float | int | str | None]:
    require_aware(as_of, "as_of")
    eligible = [item for item in values if item.available_at <= as_of]
    eligible.sort(key=lambda item: (item.report_period, item.available_at))
    merged: dict[str, float | int | str | None] = {}
    for item in eligible:
        merged.update(item.values)
    return merged


def latest_daily_fundamental_as_of(
    values: Sequence[DailyFundamental], as_of: datetime
) -> DailyFundamental | None:
    require_aware(as_of, "as_of")
    eligible = [item for item in values if item.available_at <= as_of]
    return max(eligible, key=lambda item: (item.trade_date, item.available_at)) if eligible else None


class FactorEngine:
    def raw(self, item: FactorInput) -> RawFactorVector:
        values: dict[str, float | None] = {
            "quality": self._quality(item),
            "growth": self._growth(item),
            "value": self._value(item),
            "momentum": self._momentum(item.closes),
            "low_volatility": self._low_volatility(item.closes),
            "liquidity": self._liquidity(item.amounts),
            "event": item.event_score,
        }
        coverage = sum(value is not None for value in values.values()) / len(values)
        return RawFactorVector(
            item.instrument,
            item.as_of,
            item.industry,
            item.market_cap,
            values,
            coverage,
        )

    def score_universe(
        self,
        items: Sequence[FactorInput],
        profile: StrategyProfile,
        *,
        winsor_fraction: float = 0.05,
        neutralize_industry: bool = True,
        neutralize_size: bool = True,
    ) -> tuple[FactorScore, ...]:
        raw = [self.raw(item) for item in items]
        normalized_by_factor: dict[str, dict[InstrumentId, float]] = {}
        for name in FACTOR_NAMES:
            observations = {
                item.instrument: item.values[name]
                for item in raw
                if item.values[name] is not None
            }
            normalized_by_factor[name] = self._normalize(
                observations,
                raw,
                winsor_fraction=winsor_fraction,
                neutralize_industry=neutralize_industry,
                neutralize_size=neutralize_size,
            )
        weights = PROFILE_WEIGHTS[profile]
        output: list[FactorScore] = []
        for item in raw:
            normalized = {
                name: normalized_by_factor[name].get(item.instrument, 0.0)
                for name in FACTOR_NAMES
            }
            contributions = {name: normalized[name] * weights[name] for name in FACTOR_NAMES}
            output.append(
                FactorScore(
                    item.instrument,
                    profile,
                    sum(contributions.values()),
                    normalized,
                    contributions,
                    item.coverage,
                )
            )
        output.sort(key=lambda item: (-item.composite, item.instrument.canonical))
        return tuple(output)

    @staticmethod
    def _quality(item: FactorInput) -> float | None:
        parts: list[float] = []
        if item.roe is not None:
            parts.append(item.roe)
        if item.operating_cashflow_to_profit is not None:
            parts.append(item.operating_cashflow_to_profit * 20)
        if item.debt_ratio is not None:
            parts.append((1 - item.debt_ratio) * 20)
        return fmean(parts) if parts else None

    @staticmethod
    def _growth(item: FactorInput) -> float | None:
        parts = [value for value in (item.revenue_yoy, item.profit_yoy) if value is not None]
        return fmean(parts) if parts else None

    @staticmethod
    def _value(item: FactorInput) -> float | None:
        parts: list[float] = []
        if item.pe_ttm is not None and item.pe_ttm > 0:
            parts.append(-log(item.pe_ttm))
        if item.pb is not None and item.pb > 0:
            parts.append(-log(item.pb))
        return fmean(parts) if parts else None

    @staticmethod
    def _momentum(closes: Sequence[float]) -> float | None:
        if len(closes) < 21 or closes[-21] <= 0:
            return None
        return closes[-1] / closes[-21] - 1

    @staticmethod
    def _low_volatility(closes: Sequence[float]) -> float | None:
        if len(closes) < 21:
            return None
        returns = [
            closes[index] / closes[index - 1] - 1
            for index in range(len(closes) - 20, len(closes))
            if closes[index - 1] > 0
        ]
        return -(pstdev(returns) * sqrt(242)) if len(returns) >= 2 else None

    @staticmethod
    def _liquidity(amounts: Sequence[float]) -> float | None:
        valid = [value for value in amounts[-20:] if value > 0]
        return log(median(valid)) if valid else None

    def _normalize(
        self,
        observations: Mapping[InstrumentId, float | None],
        raw: Sequence[RawFactorVector],
        *,
        winsor_fraction: float,
        neutralize_industry: bool,
        neutralize_size: bool,
    ) -> dict[InstrumentId, float]:
        values = {instrument: float(value) for instrument, value in observations.items() if value is not None}
        if not values:
            return {}
        ordered = sorted(values.values())
        low = self._quantile(ordered, winsor_fraction)
        high = self._quantile(ordered, 1 - winsor_fraction)
        clipped = {key: min(high, max(low, value)) for key, value in values.items()}
        if neutralize_industry:
            industries = {item.instrument: item.industry for item in raw}
            by_industry: dict[str, list[float]] = {}
            for instrument, value in clipped.items():
                by_industry.setdefault(industries.get(instrument, ""), []).append(value)
            global_mean = fmean(clipped.values())
            clipped = {
                instrument: value
                - (
                    fmean(by_industry[industries.get(instrument, "")])
                    if len(by_industry[industries.get(instrument, "")]) >= 3
                    else global_mean
                )
                for instrument, value in clipped.items()
            }
        if neutralize_size and len(clipped) >= 3:
            sizes = {
                item.instrument: log(item.market_cap)
                for item in raw
                if item.instrument in clipped and item.market_cap > 0
            }
            if len(sizes) == len(clipped):
                x_mean = fmean(sizes.values())
                y_mean = fmean(clipped.values())
                variance = sum((value - x_mean) ** 2 for value in sizes.values())
                beta = (
                    sum(
                        (sizes[key] - x_mean) * (clipped[key] - y_mean)
                        for key in clipped
                    )
                    / variance
                    if variance > 0
                    else 0.0
                )
                clipped = {
                    key: value - (y_mean + beta * (sizes[key] - x_mean))
                    for key, value in clipped.items()
                }
        mean = fmean(clipped.values())
        deviation = pstdev(clipped.values())
        if deviation == 0:
            return {key: 0.0 for key in clipped}
        return {key: (value - mean) / deviation for key, value in clipped.items()}

    @staticmethod
    def _quantile(values: Sequence[float], fraction: float) -> float:
        if len(values) == 1:
            return values[0]
        position = min(1.0, max(0.0, fraction)) * (len(values) - 1)
        lower = int(position)
        upper = min(len(values) - 1, lower + 1)
        weight = position - lower
        return values[lower] * (1 - weight) + values[upper] * weight
