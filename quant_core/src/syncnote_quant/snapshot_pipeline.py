"""JSON snapshot entry point used by the Windows Flutter application."""

from __future__ import annotations

import json
import os
from collections.abc import Mapping
from dataclasses import asdict
from datetime import date, datetime, time
from typing import Any
from zoneinfo import ZoneInfo

from .backtest import AShareBacktester, AShareMarketBar, ExecutionConfig
from .domain import Exchange, InstrumentId
from .factors import FactorEngine, FactorInput, StrategyProfile
from .research_report import build_research_report
from .strategy_pipeline import (
    FactorSnapshot,
    build_top_n_signals,
    evaluate_sample_split,
    run_cost_stress,
)
from .tushare_provider import TushareProvider
from .walk_forward import WalkForwardRunner

BEIJING = ZoneInfo("Asia/Shanghai")


def run_snapshot_pipeline(payload: Mapping[str, Any]) -> Mapping[str, Any]:
    """Evaluate a caller-supplied, provenance-labelled daily-bar snapshot."""

    provider = str(payload.get("provider") or "unknown")
    # This JSON bridge is fed by the public Flutter gateway. Never trust a
    # caller-supplied label to promote it into the authorized plan gate.
    requested_source = str(payload.get("requestedSource") or "free")
    trust_tier = "public_personal_research"
    profile = StrategyProfile(str(payload.get("profile") or "quality_value"))
    top_n = int(payload.get("topN") or 5)
    generated_at = _aware_datetime(payload.get("generatedAt"))
    series = payload.get("series")
    if not isinstance(series, list) or len(series) < 2:
        raise ValueError("snapshot pipeline requires at least two stock series")
    if requested_source == "tushare":
        if not os.environ.get("TUSHARE_TOKEN", "").strip():
            raise ValueError("Tushare mode requires TUSHARE_TOKEN in the local environment")
        series = _load_authorized_tushare_series(series)
        provider = TushareProvider.provider_name
        trust_tier = "primary_authorized"

    market_bars: list[AShareMarketBar] = []
    rows_by_instrument: dict[InstrumentId, list[Mapping[str, Any]]] = {}
    metadata: dict[InstrumentId, Mapping[str, Any]] = {}
    for raw_series in series:
        if not isinstance(raw_series, Mapping):
            raise TypeError("series rows must be objects")
        instrument = InstrumentId(
            str(raw_series["code"]), Exchange(str(raw_series["exchange"]))
        )
        raw_bars = raw_series.get("bars")
        if not isinstance(raw_bars, list) or len(raw_bars) < 65:
            raise ValueError(f"{instrument.canonical} needs at least 65 daily bars")
        ordered = sorted(raw_bars, key=lambda item: str(item["date"]))
        parsed: list[Mapping[str, Any]] = []
        previous_close: float | None = None
        for index, row in enumerate(ordered):
            day = date.fromisoformat(str(row["date"]))
            open_price = float(row["open"])
            high = float(row["high"])
            low = float(row["low"])
            close = float(row["close"])
            volume = float(row.get("volume") or 0)
            prior = float(row.get("previousClose") or previous_close or close)
            market_bars.append(
                AShareMarketBar(
                    instrument,
                    day,
                    open_price,
                    high,
                    low,
                    close,
                    prior,
                    volume,
                    bool(row.get("suspended", False)),
                    bool(row.get("isSt", False)),
                    int(row.get("listingDays") or 9999),
                    bool(row.get("unlimited", False)),
                    bool(row.get("delistingFinalDay", False)),
                )
            )
            parsed.append(row)
            previous_close = close
        rows_by_instrument[instrument] = parsed
        metadata[instrument] = raw_series

    common_dates = sorted(
        set.intersection(
            *(
                {date.fromisoformat(str(row["date"])) for row in rows}
                for rows in rows_by_instrument.values()
            )
        )
    )
    if len(common_dates) < 65:
        raise ValueError("common daily history is shorter than 65 trading days")
    ordered_dates = common_dates
    decision_dates = common_dates[60::21]
    if len(decision_dates) < 3:
        raise ValueError("snapshot needs at least three monthly rebalance dates")

    factor_engine = FactorEngine()
    snapshots: list[FactorSnapshot] = []
    coverage_values: list[float] = []
    latest_scores = ()
    for decision_date in decision_dates:
        factor_inputs = []
        for instrument, rows in rows_by_instrument.items():
            visible = [row for row in rows if str(row["date"]) <= decision_date.isoformat()]
            if len(visible) < 60:
                continue
            info = metadata[instrument]
            latest = visible[-1]
            factor_inputs.append(
                FactorInput(
                    instrument=instrument,
                    as_of=datetime.combine(decision_date, time(15), BEIJING),
                    industry=str(info.get("industry") or "未分类"),
                    market_cap=float(latest.get("marketCap") or 1),
                    closes=tuple(
                        float(row.get("signalClose") or row["close"])
                        for row in visible[-120:]
                    ),
                    amounts=tuple(float(row.get("amount") or 0) for row in visible[-120:]),
                    pe_ttm=_optional_float(latest.get("peTtm")),
                    pb=_optional_float(latest.get("pb")),
                    roe=_optional_float(latest.get("roe")),
                    revenue_yoy=_optional_float(latest.get("revenueYoy")),
                    profit_yoy=_optional_float(latest.get("profitYoy")),
                    operating_cashflow_to_profit=_optional_float(
                        latest.get("operatingCashflowToProfit")
                    ),
                    debt_ratio=_optional_float(latest.get("debtRatio")),
                    event_score=_optional_float(latest.get("eventScore")),
                )
            )
        scores = factor_engine.score_universe(
            factor_inputs,
            profile,
            neutralize_industry=len({item.industry for item in factor_inputs}) > 1,
            neutralize_size=len(factor_inputs) >= 5,
        )
        coverage_values.extend(item.coverage for item in scores)
        snapshots.append(FactorSnapshot(decision_date, profile, scores))
        latest_scores = scores

    minimum_coverage = float(payload.get("minimumCoverage") or 0.40)
    maximum_weight = float(payload.get("maximumWeight") or 0.10)
    signals = build_top_n_signals(
        snapshots,
        top_n=min(top_n, len(rows_by_instrument)),
        minimum_coverage=minimum_coverage,
        maximum_weight=maximum_weight,
    )
    split_index = max(2, min(len(ordered_dates) - 2, int(len(ordered_dates) * 0.70)))
    split_date = ordered_dates[split_index]
    execution = ExecutionConfig()
    sample_split = evaluate_sample_split(
        market_bars,
        signals,
        split_date=split_date,
        initial_cash=float(payload.get("initialCash") or 100_000),
        execution=execution,
    )
    out_bars = [item for item in market_bars if item.trade_date >= split_date]
    out_signals = {day: values for day, values in signals.items() if day >= split_date}
    stress = run_cost_stress(
        out_bars,
        out_signals,
        initial_cash=float(payload.get("initialCash") or 100_000),
        base=execution,
    )
    walk_forward = _walk_forward_summary(
        snapshots=snapshots,
        bars=market_bars,
        universe_size=len(rows_by_instrument),
        initial_cash=float(payload.get("initialCash") or 100_000),
        execution=execution,
        minimum_coverage=minimum_coverage,
        maximum_weight=maximum_weight,
    )
    report = build_research_report(
        strategy_name=f"{profile.value}-top{top_n}",
        generated_at=generated_at,
        provider=provider,
        trust_tier=trust_tier,
        factor_coverage=(
            sum(coverage_values) / len(coverage_values) if coverage_values else 0.0
        ),
        sample_split=sample_split,
        cost_stress=stress,
        execution_assumptions={
            "signal_time": "daily_close",
            "fill": "next_trading_day_open",
            "t_plus_one": True,
            "lot_size": execution.lot_size,
            "commission_rate": execution.commission_rate,
            "minimum_commission": execution.minimum_commission,
            "stamp_duty_rate": execution.stamp_duty_rate,
            "transfer_fee_rate": execution.transfer_fee_rate,
            "slippage_bps": execution.slippage_bps,
            "max_volume_participation": execution.max_volume_participation,
            "adjusted_for_signal_only": True,
        },
        walk_forward=walk_forward,
    )
    output = json.loads(report.to_json())
    output["splitDate"] = split_date.isoformat()
    output["universeSize"] = len(rows_by_instrument)
    output["tradingDays"] = len(ordered_dates)
    correlations = _latest_correlations(rows_by_instrument)
    output["latestRanking"] = [
        {
            "instrument": item.instrument.canonical,
            "code": item.instrument.code,
            "exchange": item.instrument.exchange.value,
            "composite": item.composite,
            "coverage": item.coverage,
            "price": float(
                next(
                    row["close"]
                    for row in rows_by_instrument[item.instrument]
                    if str(row["date"]) == decision_dates[-1].isoformat()
                )
            ),
            "industry": str(metadata[item.instrument].get("industry") or "未分类"),
            "liquidityAmount": float(
                next(
                    row.get("amount") or 0
                    for row in rows_by_instrument[item.instrument]
                    if str(row["date"]) == decision_dates[-1].isoformat()
                )
            ),
            "contributions": dict(item.contributions),
            "correlations": {
                other.canonical: value
                for other, value in correlations.get(item.instrument, {}).items()
            },
        }
        for item in latest_scores
    ]
    output["executionConfig"] = asdict(execution)
    output["dataAsOf"] = _latest_source_timestamp(series, "providerTimestamp", generated_at)
    output["fetchedAt"] = _latest_source_timestamp(series, "fetchedAt", generated_at)
    output["sourceSeries"] = [
        {
            "instrument": f"{item['code']}.{item['exchange']}",
            "executionProvider": str(item.get("executionProvider") or provider),
            "signalProvider": str(item.get("signalProvider") or provider),
            "providerTimestamp": str(item.get("providerTimestamp") or ""),
            "fetchedAt": str(item.get("fetchedAt") or ""),
        }
        for item in series
    ]
    return output


def _load_authorized_tushare_series(
    series: list[Mapping[str, Any]],
) -> list[Mapping[str, Any]]:
    """Replace public bridge rows with Tushare bars and point-in-time fields."""

    source = TushareProvider()
    enriched: list[Mapping[str, Any]] = []
    for raw in series:
        instrument = InstrumentId(str(raw["code"]), Exchange(str(raw["exchange"])))
        original_bars = raw.get("bars")
        if not isinstance(original_bars, list) or len(original_bars) < 65:
            raise ValueError(f"{instrument.canonical} lacks a usable requested range")
        start = date.fromisoformat(str(original_bars[0]["date"]))
        end = date.fromisoformat(str(original_bars[-1]["date"]))
        bars = tuple(source.bars(instrument, start, end))
        if len(bars) < 65:
            raise ValueError(f"Tushare returned fewer than 65 bars for {instrument.canonical}")
        factors = {
            item.trade_date: item.factor
            for item in source.adjustment_factors(instrument, start, end)
        }
        latest_factor = factors.get(bars[-1].timestamp.date(), 1.0)
        fundamentals = {
            item.trade_date: item
            for item in source.daily_fundamentals(instrument, start, end)
        }
        try:
            financials = sorted(
                source.financials(instrument, date(start.year - 3, 1, 1), end),
                key=lambda item: item.available_at,
            )
        except Exception:  # noqa: BLE001 - optional provider permission boundary
            financials = []
        rows: list[dict[str, Any]] = []
        previous_close: float | None = None
        for bar in bars:
            day = bar.timestamp.date()
            fundamental = fundamentals.get(day)
            visible_financial = next(
                (item for item in reversed(financials) if item.available_at.date() <= day),
                None,
            )
            values = visible_financial.values if visible_financial else {}
            factor = factors.get(day, latest_factor)
            rows.append(
                {
                    "date": day.isoformat(),
                    "open": bar.open,
                    "high": bar.high,
                    "low": bar.low,
                    "close": bar.close,
                    "previousClose": previous_close or bar.close,
                    "signalClose": bar.close * factor / latest_factor,
                    "volume": bar.volume,
                    "amount": bar.amount,
                    "marketCap": fundamental.market_cap if fundamental else None,
                    "peTtm": fundamental.pe_ttm if fundamental else None,
                    "pb": fundamental.pb if fundamental else None,
                    "roe": values.get("roe"),
                    "revenueYoy": values.get("or_yoy"),
                    "profitYoy": values.get("netprofit_yoy"),
                    "debtRatio": values.get("debt_to_assets"),
                    "operatingCashflowToProfit": values.get("ocf_to_or"),
                    "isSt": bool(raw.get("isSt", False)),
                }
            )
            previous_close = bar.close
        enriched.append(
            {
                **dict(raw),
                "executionProvider": TushareProvider.provider_name,
                "signalProvider": TushareProvider.provider_name,
                "providerTimestamp": bars[-1].timestamp.isoformat(),
                "fetchedAt": datetime.now(BEIJING).isoformat(),
                "bars": rows,
            }
        )
    return enriched


def _latest_correlations(
    rows: Mapping[InstrumentId, list[Mapping[str, Any]]],
) -> dict[InstrumentId, dict[InstrumentId, float]]:
    returns: dict[InstrumentId, dict[str, float]] = {}
    for instrument, values in rows.items():
        closes = [(str(item["date"]), float(item.get("signalClose") or item["close"])) for item in values[-121:]]
        returns[instrument] = {
            closes[index][0]: closes[index][1] / closes[index - 1][1] - 1
            for index in range(1, len(closes))
            if closes[index - 1][1] > 0
        }
    output: dict[InstrumentId, dict[InstrumentId, float]] = {item: {} for item in rows}
    for left in rows:
        for right in rows:
            if left == right:
                continue
            common = sorted(set(returns[left]) & set(returns[right]))
            if len(common) < 20:
                continue
            x = [returns[left][day] for day in common]
            y = [returns[right][day] for day in common]
            mean_x = sum(x) / len(x)
            mean_y = sum(y) / len(y)
            covariance = sum((a - mean_x) * (b - mean_y) for a, b in zip(x, y, strict=True))
            variance_x = sum((a - mean_x) ** 2 for a in x)
            variance_y = sum((b - mean_y) ** 2 for b in y)
            denominator = (variance_x * variance_y) ** 0.5
            output[left][right] = covariance / denominator if denominator > 0 else 0.0
    return output


def _aware_datetime(value: Any) -> datetime:
    parsed = datetime.fromisoformat(str(value)) if value else datetime.now(BEIJING)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("generatedAt must be timezone-aware")
    return parsed


def _optional_float(value: Any) -> float | None:
    if value is None or value == "":
        return None
    return float(value)


def _latest_source_timestamp(
    series: list[Any], field: str, fallback: datetime
) -> str:
    values: list[datetime] = []
    for item in series:
        if not isinstance(item, Mapping) or not item.get(field):
            continue
        parsed = datetime.fromisoformat(str(item[field]))
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError(f"{field} must be timezone-aware")
        values.append(parsed)
    return (max(values) if values else fallback).isoformat()


def _walk_forward_summary(
    *,
    snapshots: list[FactorSnapshot],
    bars: list[AShareMarketBar],
    universe_size: int,
    initial_cash: float,
    execution: ExecutionConfig,
    minimum_coverage: float,
    maximum_weight: float,
) -> tuple[Mapping[str, Any], ...]:
    decision_dates = [item.decision_date for item in snapshots]
    if len(decision_dates) < 8:
        return ()
    candidates = tuple(
        sorted({max(1, min(universe_size, value)) for value in (2, 3, 5, 8)})
    )

    def run_window(window: tuple[date, ...], top_n: int):
        lower, upper = window[0], window[-1]
        window_snapshots = [
            item for item in snapshots if lower <= item.decision_date <= upper
        ]
        window_signals = build_top_n_signals(
            window_snapshots,
            top_n=top_n,
            minimum_coverage=minimum_coverage,
            maximum_weight=maximum_weight,
        )
        window_bars = [item for item in bars if lower <= item.trade_date <= upper]
        if len({item.trade_date for item in window_bars}) < 2:
            raise ValueError("walk-forward window has fewer than two trading dates")
        return AShareBacktester(execution).run(
            window_bars, window_signals, initial_cash=initial_cash
        )

    folds = WalkForwardRunner[int, Any]().run(
        decision_dates,
        candidates,
        train_size=6,
        test_size=2,
        scorer=lambda dates, top_n: run_window(dates, top_n).metrics.sharpe,
        evaluator=run_window,
        parameter_name=lambda value: f"top{value}",
    )
    return tuple(
        {
            "trainStart": fold.train_dates[0].isoformat(),
            "trainEnd": fold.train_dates[-1].isoformat(),
            "testStart": fold.test_dates[0].isoformat(),
            "testEnd": fold.test_dates[-1].isoformat(),
            "selectedTopN": fold.selected_parameter,
            "trainingScores": dict(fold.training_scores),
            "testTotalReturn": fold.test_result.metrics.total_return,
            "testSharpe": fold.test_result.metrics.sharpe,
            "testMaxDrawdown": fold.test_result.metrics.max_drawdown,
        }
        for fold in folds
    )
