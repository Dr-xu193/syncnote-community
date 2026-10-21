"""Run a lightweight shadow portfolio from the same snapshot bridge as research."""

from __future__ import annotations

from collections.abc import Mapping
from datetime import date, datetime
from typing import Any

from .backtest import AShareMarketBar
from .domain import Exchange, InstrumentId
from .monitoring import run_shadow_portfolio


def run_shadow_snapshot(payload: Mapping[str, Any]) -> Mapping[str, Any]:
    series = payload.get("series")
    if not isinstance(series, list) or len(series) < 2:
        raise ValueError("shadow snapshot requires at least two stock series")
    bars: list[AShareMarketBar] = []
    by_instrument: dict[InstrumentId, set[date]] = {}
    for raw_series in series:
        if not isinstance(raw_series, Mapping):
            raise TypeError("series rows must be objects")
        instrument = InstrumentId(
            str(raw_series["code"]), Exchange(str(raw_series["exchange"]))
        )
        raw_bars = raw_series.get("bars")
        if not isinstance(raw_bars, list) or len(raw_bars) < 2:
            raise ValueError(f"{instrument.canonical} needs at least two bars")
        ordered = sorted(raw_bars, key=lambda item: str(item["date"]))
        dates: set[date] = set()
        previous_close: float | None = None
        for row in ordered:
            day = date.fromisoformat(str(row["date"]))
            close = float(row["close"])
            previous = float(row.get("previousClose") or previous_close or close)
            bars.append(
                AShareMarketBar(
                    instrument,
                    day,
                    float(row["open"]),
                    float(row["high"]),
                    float(row["low"]),
                    close,
                    previous,
                    float(row.get("volume") or 0),
                    bool(row.get("suspended", False)),
                    bool(row.get("isSt", False)),
                    int(row.get("listingDays") or 9999),
                    bool(row.get("unlimited", False)),
                    bool(row.get("delistingFinalDay", False)),
                )
            )
            dates.add(day)
            previous_close = close
        by_instrument[instrument] = dates
    common = sorted(set.intersection(*by_instrument.values()))
    if len(common) < 2:
        raise ValueError("shadow snapshot has fewer than two common trading dates")
    # A shadow run starts with a deterministic rebalance one day before the
    # latest available bar, so at least one next-open fill can be observed.
    signal_date = common[-2]
    weight = min(0.10, 0.80 / len(by_instrument))
    signals = {signal_date: {instrument: weight for instrument in by_instrument}}
    shadow = run_shadow_portfolio(
        bars,
        signals,
        initial_cash=float(payload.get("initialCash") or 100_000),
    )
    latest = shadow.monitoring[-1]
    peak_equity = max(
        latest.peak_equity,
        float(payload.get("previousPeakEquity") or 0),
    )
    drawdown = latest.equity / peak_equity - 1
    alert_rows = [
        {
            "key": alert.key,
            "kind": alert.kind.value,
            "severity": alert.severity,
            "occurred_at": alert.occurred_at.isoformat(),
            "message": alert.message,
        }
        for alert in latest.alerts
    ]
    if -drawdown >= 0.15:
        alert_rows.append(
            _plain_alert("drawdown", "critical", latest.as_of, f"组合回撤达到 {-drawdown:.1%}")
        )
    elif -drawdown >= 0.08:
        alert_rows.append(
            _plain_alert("drawdown", "warning", latest.as_of, f"组合回撤达到 {-drawdown:.1%}")
        )

    latest_prices = {
        item.instrument.canonical: item.close
        for item in bars
        if item.trade_date == common[-1]
    }
    for decision in payload.get("plans", []):
        if not isinstance(decision, Mapping):
            continue
        for raw_plan in decision.get("plans", []):
            if not isinstance(raw_plan, Mapping):
                continue
            plan_id = str(raw_plan.get("planId") or "unknown")
            valid_until = date.fromisoformat(str(raw_plan.get("validUntil")))
            days_left = (valid_until - common[-1]).days
            if days_left < 0:
                alert_rows.append(
                    _plain_alert(
                        "plan_expired", "warning", latest.as_of, f"计划 {plan_id} 已过期"
                    )
                )
            elif days_left <= 1:
                alert_rows.append(
                    _plain_alert(
                        "plan_expiring",
                        "info",
                        latest.as_of,
                        f"计划 {plan_id} 将在 {days_left} 天后过期",
                    )
                )
            candidate = raw_plan.get("candidate")
            if not isinstance(candidate, Mapping):
                continue
            instrument = str(candidate.get("instrument") or "")
            observation_price = float(candidate.get("price") or 0)
            stop_distance = float(candidate.get("stopDistance") or 0)
            current_price = latest_prices.get(instrument)
            if (
                current_price is not None
                and observation_price > 0
                and 0 < stop_distance < 1
                and current_price <= observation_price * (1 - stop_distance)
            ):
                alert_rows.append(
                    _plain_alert(
                        "price_stop",
                        "critical",
                        latest.as_of,
                        f"{instrument} 已触发计划 {plan_id} 的硬止损",
                    )
                )

    generated_value = payload.get("generatedAt")
    generated_at = (
        datetime.fromisoformat(str(generated_value)) if generated_value else latest.as_of
    )
    if (generated_at.date() - common[-1]).days > 4:
        alert_rows.append(
            _plain_alert("data_stale", "warning", latest.as_of, "模拟盘行情超过四天未更新")
        )
    deduped_alerts = list({item["key"] + item["message"]: item for item in alert_rows}.values())
    return {
        "schema_version": 1,
        "as_of": latest.as_of.isoformat(),
        "equity": latest.equity,
        "peak_equity": peak_equity,
        "drawdown": drawdown,
        "alerts": deduped_alerts,
        "snapshot_hash": shadow.backtest.snapshot_hash,
        "trade_count": len(shadow.backtest.trades),
        "total_cost": shadow.backtest.metrics.total_cost,
        "source_provider": str(payload.get("provider") or "unknown"),
        "source_trust_tier": "public_validation",
        "execution_assumptions": {
            "fill": "next_trading_day_open",
            "t_plus_one": True,
            "no_broker_connection": True,
        },
    }


def _plain_alert(
    kind: str, severity: str, occurred_at: datetime, message: str
) -> dict[str, str]:
    return {
        "key": f"{kind}:{message}",
        "kind": kind,
        "severity": severity,
        "occurred_at": occurred_at.isoformat(),
        "message": message,
    }
