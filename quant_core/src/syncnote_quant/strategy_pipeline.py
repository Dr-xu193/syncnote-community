"""Deterministic factor signal construction and sample-split evaluation."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import date

from .backtest import (
    AShareBacktester,
    AShareMarketBar,
    BacktestResult,
    ExecutionConfig,
)
from .domain import InstrumentId
from .factors import FactorScore, StrategyProfile


@dataclass(frozen=True, slots=True)
class FactorSnapshot:
    decision_date: date
    profile: StrategyProfile
    scores: tuple[FactorScore, ...]


@dataclass(frozen=True, slots=True)
class SampleSplitResult:
    split_date: date
    in_sample: BacktestResult
    out_of_sample: BacktestResult


@dataclass(frozen=True, slots=True)
class CostStressResult:
    label: str
    execution: ExecutionConfig
    result: BacktestResult


def build_top_n_signals(
    snapshots: Sequence[FactorSnapshot],
    *,
    top_n: int,
    minimum_coverage: float = 0.70,
    cash_buffer: float = 0.05,
    maximum_weight: float = 0.10,
) -> Mapping[date, Mapping[InstrumentId, float]]:
    if top_n <= 0:
        raise ValueError("top_n must be positive")
    if not 0 <= minimum_coverage <= 1:
        raise ValueError("minimum_coverage must be between zero and one")
    if not 0 <= cash_buffer < 1:
        raise ValueError("cash_buffer must be between zero and one")
    if not 0 < maximum_weight <= 1:
        raise ValueError("maximum_weight must be between zero and one")

    previous: set[InstrumentId] = set()
    output: dict[date, dict[InstrumentId, float]] = {}
    for snapshot in sorted(snapshots, key=lambda item: item.decision_date):
        ranked = sorted(
            (
                item
                for item in snapshot.scores
                if item.profile == snapshot.profile and item.coverage >= minimum_coverage
            ),
            key=lambda item: (-item.composite, item.instrument.canonical),
        )[:top_n]
        selected = {item.instrument for item in ranked}
        target_weight = min(maximum_weight, (1 - cash_buffer) / max(1, len(ranked)))
        targets = {
            instrument: 0.0
            for instrument in sorted(previous - selected, key=lambda item: item.canonical)
        }
        targets.update({item.instrument: target_weight for item in ranked})
        output[snapshot.decision_date] = targets
        previous = selected
    return output


def evaluate_sample_split(
    bars: Sequence[AShareMarketBar],
    signals: Mapping[date, Mapping[InstrumentId, float]],
    *,
    split_date: date,
    initial_cash: float = 100_000.0,
    execution: ExecutionConfig | None = None,
) -> SampleSplitResult:
    in_bars = [item for item in bars if item.trade_date < split_date]
    out_bars = [item for item in bars if item.trade_date >= split_date]
    if len({item.trade_date for item in in_bars}) < 2:
        raise ValueError("in-sample period needs at least two trading dates")
    if len({item.trade_date for item in out_bars}) < 2:
        raise ValueError("out-of-sample period needs at least two trading dates")
    in_signals = {day: values for day, values in signals.items() if day < split_date}
    out_signals = {day: values for day, values in signals.items() if day >= split_date}
    engine = AShareBacktester(execution)
    return SampleSplitResult(
        split_date,
        engine.run(in_bars, in_signals, initial_cash=initial_cash),
        engine.run(out_bars, out_signals, initial_cash=initial_cash),
    )


def run_cost_stress(
    bars: Sequence[AShareMarketBar],
    signals: Mapping[date, Mapping[InstrumentId, float]],
    *,
    initial_cash: float = 100_000.0,
    base: ExecutionConfig | None = None,
) -> tuple[CostStressResult, ...]:
    baseline = base or ExecutionConfig()
    scenarios = (
        ("base", 1.0),
        ("cost_x2", 2.0),
        ("cost_x3", 3.0),
    )
    output: list[CostStressResult] = []
    for label, multiplier in scenarios:
        stressed = ExecutionConfig(
            lot_size=baseline.lot_size,
            commission_rate=baseline.commission_rate * multiplier,
            minimum_commission=baseline.minimum_commission * multiplier,
            stamp_duty_rate=baseline.stamp_duty_rate * multiplier,
            transfer_fee_rate=baseline.transfer_fee_rate * multiplier,
            slippage_bps=baseline.slippage_bps * multiplier,
            max_volume_participation=baseline.max_volume_participation,
            annual_trading_days=baseline.annual_trading_days,
        )
        output.append(
            CostStressResult(
                label,
                stressed,
                AShareBacktester(stressed).run(
                    bars, signals, initial_cash=initial_cash
                ),
            )
        )
    return tuple(output)
