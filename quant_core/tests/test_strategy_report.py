from datetime import UTC, date, datetime, timedelta

from syncnote_quant.backtest import AShareMarketBar, ExecutionConfig
from syncnote_quant.domain import Exchange, InstrumentId
from syncnote_quant.factors import FactorScore, StrategyProfile
from syncnote_quant.research_report import build_research_report
from syncnote_quant.strategy_pipeline import (
    FactorSnapshot,
    build_top_n_signals,
    evaluate_sample_split,
    run_cost_stress,
)

START = date(2026, 1, 1)
FIRST = InstrumentId("600001", Exchange.SSE)
SECOND = InstrumentId("600002", Exchange.SSE)


def _score(instrument: InstrumentId, composite: float) -> FactorScore:
    return FactorScore(
        instrument,
        StrategyProfile.QUALITY_VALUE,
        composite,
        {"quality": composite},
        {"quality": composite},
        0.9,
    )


def _bars(days: int = 12) -> list[AShareMarketBar]:
    output = []
    for offset in range(days):
        for instrument, base in ((FIRST, 10.0), (SECOND, 20.0)):
            price = base + offset * (0.1 if instrument == FIRST else -0.05)
            previous = base if offset == 0 else base + (offset - 1) * (
                0.1 if instrument == FIRST else -0.05
            )
            output.append(
                AShareMarketBar(
                    instrument,
                    START + timedelta(days=offset),
                    price,
                    price,
                    price,
                    price,
                    previous,
                    1_000_000,
                )
            )
    return output


def test_top_n_signal_liquidates_stock_that_leaves_ranking() -> None:
    snapshots = [
        FactorSnapshot(
            START,
            StrategyProfile.QUALITY_VALUE,
            (_score(FIRST, 2), _score(SECOND, 1)),
        ),
        FactorSnapshot(
            START + timedelta(days=2),
            StrategyProfile.QUALITY_VALUE,
            (_score(SECOND, 3), _score(FIRST, 1)),
        ),
    ]
    signals = build_top_n_signals(snapshots, top_n=1, maximum_weight=0.2)
    assert signals[START] == {FIRST: 0.2}
    assert signals[START + timedelta(days=2)] == {FIRST: 0.0, SECOND: 0.2}


def test_report_keeps_public_validation_out_of_plan_gate_and_is_reproducible() -> None:
    bars = _bars()
    signals = {
        START: {FIRST: 0.2},
        START + timedelta(days=6): {FIRST: 0.2},
    }
    execution = ExecutionConfig(slippage_bps=0, max_volume_participation=1)
    split = evaluate_sample_split(
        bars,
        signals,
        split_date=START + timedelta(days=6),
        execution=execution,
    )
    stress = run_cost_stress(bars[12:], signals, base=execution)
    kwargs = {
        "strategy_name": "quality-value-v1",
        "generated_at": datetime(2026, 8, 30, tzinfo=UTC),
        "provider": "public fixture",
        "trust_tier": "public_validation",
        "factor_coverage": 0.9,
        "sample_split": split,
        "cost_stress": stress,
        "execution_assumptions": {"t_plus_one": True, "fill": "next_open"},
        "walk_forward": [],
        "minimum_out_sample_days": 2,
        "minimum_out_sample_trades": 1,
    }
    first = build_research_report(**kwargs)
    second = build_research_report(**kwargs)
    assert first.to_json() == second.to_json()
    assert first.qualification.qualified_for_plan is False
    assert any("不是已授权" in reason for reason in first.qualification.reasons)
