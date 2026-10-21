from dataclasses import replace
from datetime import UTC, date, datetime, timedelta

from syncnote_quant.domain import (
    Exchange,
    FinancialPointInTime,
    FinancialStatement,
    InstrumentId,
    SourceEvidence,
)
from syncnote_quant.factors import (
    FactorEngine,
    FactorInput,
    StrategyProfile,
    latest_financial_values_as_of,
)

AS_OF = datetime(2026, 8, 28, 15, tzinfo=UTC)


def item(code: str, strength: float) -> FactorInput:
    closes = tuple(10 + index * strength * 0.01 for index in range(80))
    return FactorInput(
        InstrumentId(code, Exchange.SSE),
        AS_OF,
        "同行业",
        10_000_000_000,
        closes,
        tuple(100_000_000 + index for index in range(80)),
        pe_ttm=max(5, 30 - strength),
        pb=max(0.5, 5 - strength * 0.1),
        roe=8 + strength,
        revenue_yoy=5 + strength,
        profit_yoy=4 + strength,
        operating_cashflow_to_profit=0.6 + strength * 0.02,
        debt_ratio=max(0.1, 0.7 - strength * 0.02),
        event_score=min(1, strength / 10),
    )


def test_factor_ranking_is_explainable_and_reproducible() -> None:
    inputs = [item("600001", 2), item("600002", 6), item("600003", 10)]
    engine = FactorEngine()
    first = engine.score_universe(
        inputs,
        StrategyProfile.QUALITY_VALUE,
        neutralize_industry=False,
        neutralize_size=False,
    )
    second = engine.score_universe(
        inputs,
        StrategyProfile.QUALITY_VALUE,
        neutralize_industry=False,
        neutralize_size=False,
    )
    assert first == second
    assert first[0].instrument.code == "600003"
    assert abs(sum(first[0].contributions.values()) - first[0].composite) < 1e-12
    assert first[0].coverage == 1.0


def test_future_financial_publication_is_not_visible_to_factor_date() -> None:
    instrument = InstrumentId("600519", Exchange.SSE)
    evidence = SourceEvidence("test", "financial", AS_OF, AS_OF)
    old = FinancialPointInTime(
        instrument,
        FinancialStatement.INDICATOR,
        date(2026, 3, 31),
        AS_OF - timedelta(days=10),
        AS_OF - timedelta(days=10),
        {"roe": 12.0},
        evidence,
    )
    future = FinancialPointInTime(
        instrument,
        FinancialStatement.INDICATOR,
        date(2026, 6, 30),
        AS_OF + timedelta(days=1),
        AS_OF + timedelta(days=1),
        {"roe": 99.0},
        evidence,
    )
    values = latest_financial_values_as_of([old, future], AS_OF)
    assert values["roe"] == 12.0


def test_single_member_industries_do_not_zero_the_entire_ranking() -> None:
    inputs = [
        item("600001", 2),
        item("600002", 6),
        item("600003", 10),
    ]
    inputs = [
        replace(value, industry=f"行业{index}")
        for index, value in enumerate(inputs)
    ]
    scores = FactorEngine().score_universe(
        inputs,
        StrategyProfile.QUALITY_VALUE,
        neutralize_industry=True,
        neutralize_size=False,
    )
    assert scores[0].instrument.code == "600003"
    assert any(item.composite != 0 for item in scores)
