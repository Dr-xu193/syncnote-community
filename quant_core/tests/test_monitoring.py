from datetime import UTC, datetime, timedelta

from syncnote_quant.domain import Exchange, InstrumentId
from syncnote_quant.monitoring import AlertKind, ShadowMonitor
from syncnote_quant.portfolio_plan import (
    BuyPlan,
    CandidateAsset,
    PlanTranche,
    RiskExposure,
)

NOW = datetime(2026, 8, 31, 15, tzinfo=UTC)
STOCK = InstrumentId("600001", Exchange.SSE)


def _plan() -> BuyPlan:
    candidate = CandidateAsset(STOCK, 10, "测试", 1, 0.1, 1e8)
    return BuyPlan(
        "p1",
        NOW,
        NOW.date(),
        "hash",
        candidate,
        RiskExposure({}, {}, {}, 0, 1, 0, 0, 0),
        (PlanTranche(1, 0.1, 1000, "条件", "失效"),),
        0.1,
        0.01,
        30,
        ("stop",),
        True,
    )


def test_monitor_deduplicates_repeated_stop_and_escalates_new_state() -> None:
    monitor = ShadowMonitor()
    first = monitor.evaluate(
        as_of=NOW,
        equity=90_000,
        peak_equity=100_000,
        data_as_of=NOW,
        plans=(_plan(),),
        current_prices={STOCK: 8.9},
        source_snapshot_hash="hash",
    )
    second = monitor.evaluate(
        as_of=NOW + timedelta(hours=1),
        equity=90_000,
        peak_equity=100_000,
        data_as_of=NOW,
        plans=(_plan(),),
        current_prices={STOCK: 8.9},
        source_snapshot_hash="hash",
    )
    third = monitor.evaluate(
        as_of=NOW + timedelta(hours=2),
        equity=80_000,
        peak_equity=100_000,
        data_as_of=NOW,
        plans=(_plan(),),
        current_prices={STOCK: 8.9},
        source_snapshot_hash="hash",
    )
    assert {item.kind for item in first.alerts} == {
        AlertKind.PRICE_STOP,
        AlertKind.PLAN_EXPIRING,
        AlertKind.DRAWDOWN,
    }
    assert second.alerts == ()
    assert any(item.kind == AlertKind.DRAWDOWN for item in third.alerts)


def test_monitor_marks_stale_data_without_making_execution_decision() -> None:
    result = ShadowMonitor().evaluate(
        as_of=NOW,
        equity=100_000,
        peak_equity=100_000,
        data_as_of=NOW - timedelta(days=2),
    )
    assert result.alerts[0].kind == AlertKind.DATA_STALE
