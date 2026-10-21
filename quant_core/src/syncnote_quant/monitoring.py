"""Shadow-portfolio monitoring with idempotent, explainable alerts."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from enum import StrEnum

from .backtest import AShareBacktester, AShareMarketBar, BacktestResult, ExecutionConfig
from .clock import BEIJING_TZ
from .domain import InstrumentId, require_aware
from .portfolio_plan import BuyPlan


class AlertKind(StrEnum):
    PRICE_STOP = "price_stop"
    DRAWDOWN = "drawdown"
    PLAN_EXPIRING = "plan_expiring"
    PLAN_EXPIRED = "plan_expired"
    DATA_STALE = "data_stale"
    PLAN_INVALIDATED = "plan_invalidated"


@dataclass(frozen=True, slots=True)
class MonitorAlert:
    key: str
    kind: AlertKind
    severity: str
    occurred_at: datetime
    message: str
    source_snapshot_hash: str


@dataclass(frozen=True, slots=True)
class MonitorSnapshot:
    as_of: datetime
    equity: float
    peak_equity: float
    drawdown: float
    alerts: tuple[MonitorAlert, ...]


@dataclass(frozen=True, slots=True)
class ShadowRunResult:
    backtest: BacktestResult
    monitoring: tuple[MonitorSnapshot, ...]


class AlertDeduper:
    """Emit once per state fingerprint; a changed state may alert again."""

    def __init__(self) -> None:
        self._fingerprints: dict[str, str] = {}

    def accept(self, alert: MonitorAlert) -> MonitorAlert | None:
        fingerprint = f"{alert.kind.value}|{alert.message}|{alert.source_snapshot_hash}"
        if self._fingerprints.get(alert.key) == fingerprint:
            return None
        self._fingerprints[alert.key] = fingerprint
        return alert


class ShadowMonitor:
    def __init__(
        self,
        *,
        drawdown_warning: float = 0.08,
        drawdown_critical: float = 0.15,
        plan_expiry_warning_days: int = 1,
        max_data_age: timedelta = timedelta(days=1),
    ) -> None:
        if not 0 < drawdown_warning < drawdown_critical < 1:
            raise ValueError("drawdown thresholds must be ordered in (0, 1)")
        if plan_expiry_warning_days < 0:
            raise ValueError("plan_expiry_warning_days cannot be negative")
        if max_data_age <= timedelta(0):
            raise ValueError("max_data_age must be positive")
        self.drawdown_warning = drawdown_warning
        self.drawdown_critical = drawdown_critical
        self.plan_expiry_warning_days = plan_expiry_warning_days
        self.max_data_age = max_data_age
        self._deduper = AlertDeduper()

    def evaluate(
        self,
        *,
        as_of: datetime,
        equity: float,
        peak_equity: float,
        data_as_of: datetime,
        plans: Sequence[BuyPlan] = (),
        current_prices: Mapping[InstrumentId, float] = (),
        source_snapshot_hash: str = "",
    ) -> MonitorSnapshot:
        require_aware(as_of, "monitor as_of")
        require_aware(data_as_of, "monitor data_as_of")
        if equity <= 0 or peak_equity <= 0:
            raise ValueError("monitor equity must be positive")
        drawdown = equity / peak_equity - 1
        alerts: list[MonitorAlert] = []

        if -drawdown >= self.drawdown_critical:
            alerts.append(
                self._alert(
                    AlertKind.DRAWDOWN,
                    "critical",
                    as_of,
                    f"组合回撤达到 {-drawdown:.1%}，暂停新增计划并人工复核",
                    source_snapshot_hash,
                )
            )
        elif -drawdown >= self.drawdown_warning:
            alerts.append(
                self._alert(
                    AlertKind.DRAWDOWN,
                    "warning",
                    as_of,
                    f"组合回撤达到 {-drawdown:.1%}，进入风险观察",
                    source_snapshot_hash,
                )
            )

        if as_of - data_as_of > self.max_data_age:
            alerts.append(
                self._alert(
                    AlertKind.DATA_STALE,
                    "warning",
                    as_of,
                    f"监控行情已陈旧 {as_of - data_as_of}，不产生新的执行结论",
                    source_snapshot_hash,
                )
            )

        for plan in plans:
            days_left = (plan.valid_until - as_of.date()).days
            if days_left < 0:
                alerts.append(
                    self._alert(
                        AlertKind.PLAN_EXPIRED,
                        "warning",
                        as_of,
                        f"计划 {plan.plan_id} 已过期，需要重新研究",
                        plan.source_snapshot_hash,
                        plan.plan_id,
                    )
                )
            elif days_left <= self.plan_expiry_warning_days:
                alerts.append(
                    self._alert(
                        AlertKind.PLAN_EXPIRING,
                        "info",
                        as_of,
                        f"计划 {plan.plan_id} 将在 {days_left} 天后过期",
                        plan.source_snapshot_hash,
                        plan.plan_id,
                    )
                )
            price = current_prices.get(plan.candidate.instrument)
            stop_price = plan.candidate.price * (1 - plan.candidate.stop_distance)
            if price is not None and price <= stop_price:
                alerts.append(
                    self._alert(
                        AlertKind.PRICE_STOP,
                        "critical",
                        as_of,
                        f"{plan.candidate.instrument.canonical} 价格 {price:.2f} 已触发硬止损 {stop_price:.2f}",
                        plan.source_snapshot_hash,
                        plan.plan_id,
                    )
                )

        accepted = tuple(alert for alert in (self._deduper.accept(item) for item in alerts) if alert)
        return MonitorSnapshot(as_of, equity, peak_equity, drawdown, accepted)

    @staticmethod
    def _alert(
        kind: AlertKind,
        severity: str,
        occurred_at: datetime,
        message: str,
        source_hash: str,
        suffix: str = "",
    ) -> MonitorAlert:
        return MonitorAlert(
            key=f"{kind.value}:{suffix or 'portfolio'}",
            kind=kind,
            severity=severity,
            occurred_at=occurred_at,
            message=message,
            source_snapshot_hash=source_hash,
        )


def run_shadow_portfolio(
    bars: Sequence[AShareMarketBar],
    signals: Mapping[date, Mapping[InstrumentId, float]],
    *,
    initial_cash: float = 100_000.0,
    execution: ExecutionConfig | None = None,
    monitor: ShadowMonitor | None = None,
    data_timestamps: Mapping[date, datetime] | None = None,
) -> ShadowRunResult:
    """Run the same executable constraints as research, then monitor daily state."""

    result = AShareBacktester(execution).run(
        bars, signals, initial_cash=initial_cash
    )
    monitor = monitor or ShadowMonitor()
    timestamps = data_timestamps or {}
    snapshots: list[MonitorSnapshot] = []
    peak = initial_cash
    for daily in result.daily:
        peak = max(peak, daily.equity)
        data_as_of = timestamps.get(
            daily.trade_date,
            datetime.combine(daily.trade_date, time(15), BEIJING_TZ),
        )
        if data_as_of.tzinfo is None or data_as_of.utcoffset() is None:
            data_as_of = data_as_of.replace(tzinfo=BEIJING_TZ)
        snapshots.append(
            monitor.evaluate(
                as_of=datetime.combine(daily.trade_date, time(15), BEIJING_TZ),
                equity=daily.equity,
                peak_equity=peak,
                data_as_of=data_as_of,
                source_snapshot_hash=result.snapshot_hash,
            )
        )
    return ShadowRunResult(result, tuple(snapshots))
