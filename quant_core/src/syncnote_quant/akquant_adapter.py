"""Pinned AKQuant validation adapter for the deterministic A-share engine.

AKQuant is deliberately a second implementation, not the source of truth for
price-limit and suspension handling.  The adapter pins all execution semantics
that must agree with :mod:`syncnote_quant.backtest` and exposes a small,
serializable result for contract tests and reports.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import date
from importlib import metadata
from math import isfinite
from typing import Any

from .backtest import AShareMarketBar, ExecutionConfig
from .domain import InstrumentId

AKQUANT_VERSION = "0.3.52"
SHANGHAI_TIMEZONE = "Asia/Shanghai"


@dataclass(frozen=True, slots=True)
class AkquantExecution:
    trade_date: date
    symbol: str
    side: str
    quantity: int
    price: float
    commission: float


@dataclass(frozen=True, slots=True)
class AkquantValidationResult:
    engine_version: str
    executions: tuple[AkquantExecution, ...]
    metrics: Mapping[str, float | int | str | None]
    resolved_config: Mapping[str, Any]


def require_akquant_version() -> str:
    try:
        version = metadata.version("akquant")
    except metadata.PackageNotFoundError as error:
        raise RuntimeError(
            "AKQuant is not installed; install quant_core[backtest] in the Python venv"
        ) from error
    if version != AKQUANT_VERSION:
        raise RuntimeError(
            f"AKQuant version mismatch: expected {AKQUANT_VERSION}, got {version}"
        )
    return version


def run_akquant_validation(
    bars: Sequence[AShareMarketBar],
    signals: Mapping[date, Mapping[InstrumentId, float]],
    *,
    initial_cash: float = 100_000.0,
    execution: ExecutionConfig | None = None,
) -> AkquantValidationResult:
    """Run the pinned secondary engine with explicit A-share semantics."""

    version = require_akquant_version()
    if initial_cash <= 0:
        raise ValueError("initial_cash must be positive")
    if not bars:
        raise ValueError("at least one market bar is required")
    config = execution or ExecutionConfig()
    for day, weights in signals.items():
        total = sum(weights.values())
        if not isfinite(total) or total > 1 + 1e-12:
            raise ValueError(f"target weights exceed 100% on {day}")

    import pandas as pd
    from akquant import (
        BacktestConfig,
        ChinaStockConfig,
        NextOpen,
        StrategyConfig,
        run_backtest,
    )

    market_data: dict[str, Any] = {}
    bars_by_symbol: dict[str, list[AShareMarketBar]] = {}
    for bar in bars:
        bars_by_symbol.setdefault(bar.instrument.canonical, []).append(bar)
    for symbol, symbol_bars in sorted(bars_by_symbol.items()):
        ordered = sorted(symbol_bars, key=lambda item: item.trade_date)
        if len({item.trade_date for item in ordered}) != len(ordered):
            raise ValueError(f"duplicate AKQuant bar for {symbol}")
        index = pd.DatetimeIndex(
            [
                pd.Timestamp(item.trade_date.isoformat(), tz=SHANGHAI_TIMEZONE)
                + pd.Timedelta(hours=15)
                for item in ordered
            ]
        )
        market_data[symbol] = pd.DataFrame(
            {
                "open": [item.open for item in ordered],
                "high": [item.high for item in ordered],
                "low": [item.low for item in ordered],
                "close": [item.close for item in ordered],
                "volume": [item.volume for item in ordered],
            },
            index=index,
        )

    signal_by_symbol = {
        day: {instrument.canonical: weight for instrument, weight in weights.items()}
        for day, weights in signals.items()
    }
    issued: set[tuple[date, str]] = set()

    def on_bar(context: Any, bar: Any) -> None:
        local_day = (
            pd.Timestamp(bar.timestamp, unit="ns", tz="UTC")
            .tz_convert(SHANGHAI_TIMEZONE)
            .date()
        )
        key = (local_day, str(bar.symbol))
        if key in issued:
            return
        target = signal_by_symbol.get(local_day, {}).get(str(bar.symbol))
        if target is None:
            return
        if not 0 <= target <= 1:
            raise ValueError("target weights must be between zero and one")
        issued.add(key)
        context.order_target_percent(symbol=bar.symbol, target_percent=target)

    strategy_config = StrategyConfig(
        initial_cash=initial_cash,
        commission_rate=config.commission_rate,
        stamp_tax_rate=config.stamp_duty_rate,
        transfer_fee_rate=config.transfer_fee_rate,
        min_commission=config.minimum_commission,
        slippage={"type": "percent", "value": config.slippage_bps / 10_000},
        volume_limit_pct=config.max_volume_participation,
        exit_on_last_bar=False,
    )
    backtest_config = BacktestConfig(
        strategy_config=strategy_config,
        instruments=sorted(market_data),
        china_stock=ChinaStockConfig(enforce_tick_size=True),
        timezone=SHANGHAI_TIMEZONE,
        days_per_year=float(config.annual_trading_days),
        show_progress=False,
        bootstrap_samples=0,
    )
    raw = run_backtest(
        data=market_data,
        strategy=on_bar,
        config=backtest_config,
        t_plus_one=True,
        lot_size=config.lot_size,
        fill_policy=NextOpen(),
        show_progress=False,
    )

    executions = tuple(
        AkquantExecution(
            trade_date=pd.Timestamp(row.timestamp).tz_convert(SHANGHAI_TIMEZONE).date(),
            symbol=str(row.symbol),
            side=str(row.side),
            quantity=int(row.quantity),
            price=float(row.price),
            commission=float(row.commission),
        )
        for row in raw.executions_df.itertuples(index=False)
    )
    metrics = {
        str(name): _serializable_scalar(value)
        for name, value in raw.metrics_df["value"].items()
    }
    return AkquantValidationResult(
        engine_version=version,
        executions=executions,
        metrics=metrics,
        resolved_config=dict(raw.resolved_config),
    )


def _serializable_scalar(value: Any) -> float | int | str | None:
    if value is None:
        return None
    if hasattr(value, "isoformat"):
        return str(value.isoformat())
    if hasattr(value, "item"):
        value = value.item()
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int | float):
        return value
    return str(value)
