from datetime import UTC, date, datetime, timedelta

import pytest

from syncnote_quant.adjustments import AdjustmentMode, adjusted_closes_as_of
from syncnote_quant.domain import (
    AdjustmentFactor,
    Bar,
    BarInterval,
    Exchange,
    InstrumentId,
    InstrumentLifecycle,
    SourceEvidence,
)
from syncnote_quant.universe import active_universe_as_of

NOW = datetime(2026, 8, 28, 18, tzinfo=UTC)
STOCK = InstrumentId("600001", Exchange.SSE)
EVIDENCE = SourceEvidence("test", "fixture", NOW, NOW)


def test_adjustment_uses_only_factors_available_at_decision_time() -> None:
    bars = [
        Bar(
            STOCK,
            BarInterval.DAY,
            NOW - timedelta(days=2 - index),
            10,
            10,
            10,
            10,
            100,
            1000,
            EVIDENCE,
        )
        for index in range(3)
    ]
    factors = [
        AdjustmentFactor(
            STOCK,
            item.timestamp.date(),
            1 + index,
            item.timestamp,
            EVIDENCE,
        )
        for index, item in enumerate(bars)
    ]
    factors.append(
        AdjustmentFactor(
            STOCK,
            (NOW + timedelta(days=1)).date(),
            99,
            NOW + timedelta(days=1),
            EVIDENCE,
        )
    )
    result = adjusted_closes_as_of(
        bars, factors, as_of=NOW, mode=AdjustmentMode.FORWARD
    )
    assert list(result.values()) == pytest.approx([10 / 3, 20 / 3, 10])


def test_historical_universe_includes_later_delisted_stock_only_when_active() -> None:
    active = InstrumentLifecycle(
        STOCK, "存续", "行业", date(2020, 1, 1), None, EVIDENCE
    )
    delisted = InstrumentLifecycle(
        InstrumentId("600002", Exchange.SSE),
        "退市样本",
        "行业",
        date(2020, 1, 1),
        date(2025, 6, 30),
        EVIDENCE,
    )
    assert active_universe_as_of([active, delisted], date(2024, 1, 1)) == (
        STOCK,
        delisted.instrument,
    )
    assert active_universe_as_of([active, delisted], date(2026, 1, 1)) == (STOCK,)
