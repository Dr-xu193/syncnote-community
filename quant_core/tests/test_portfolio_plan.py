from datetime import UTC, datetime

import pytest

from syncnote_quant.domain import Exchange, InstrumentId
from syncnote_quant.portfolio_plan import (
    AccountSnapshot,
    CandidateAsset,
    PositionSnapshot,
    RiskLimits,
    build_buy_plans,
    calculate_exposure,
    portfolio_volatility,
)

NOW = datetime(2026, 8, 31, 15, tzinfo=UTC)
EXISTING = InstrumentId("600001", Exchange.SSE)
CANDIDATE = InstrumentId("600002", Exchange.SSE)


def account(cash: float = 80_000) -> AccountSnapshot:
    position = PositionSnapshot(EXISTING, 2_000, 2_000, 10, 10, "测试行业")
    return AccountSnapshot(NOW, 100_000, cash, (position,))


def candidate() -> CandidateAsset:
    return CandidateAsset(
        CANDIDATE,
        10,
        "新行业",
        2,
        0.08,
        1e8,
        "new-cluster",
        correlations={EXISTING: 0.0},
    )


def test_exposure_is_reproducible_and_uses_cash_separately() -> None:
    result = calculate_exposure(account())
    assert result.gross_exposure == 0.2
    assert result.cash_weight == 0.8
    assert result.industry_weights == {"测试行业": 0.2}
    assert result.annualized_volatility == pytest.approx(0.06)


def test_portfolio_volatility_uses_supplied_pairwise_correlation() -> None:
    assert portfolio_volatility(
        {EXISTING: 0.5, CANDIDATE: 0.5},
        {EXISTING: 0.2, CANDIDATE: 0.4},
        {(EXISTING, CANDIDATE): 1.0},
    ) == pytest.approx(0.3)


def test_public_or_unqualified_research_can_never_create_plan() -> None:
    result = build_buy_plans(
        account(),
        [candidate()],
        source_snapshot_hash="abc",
        source_trust_tier="public_validation",
        stage2_qualified=True,
    )
    assert result.ready is False
    assert not result.plans
    assert any("授权主源" in reason for reason in result.reasons)


def test_authorized_plan_is_conditioned_split_and_human_confirmed() -> None:
    result = build_buy_plans(
        account(),
        [candidate()],
        source_snapshot_hash="abc",
        source_trust_tier="primary_authorized",
        stage2_qualified=True,
        limits=RiskLimits(max_position_weight=0.3, max_industry_weight=0.4),
    )
    assert result.ready is True
    plan = result.plans[0]
    assert sum(item.target_weight for item in plan.tranches) == plan.total_target_weight
    assert all(item.target_shares % 100 == 0 for item in plan.tranches)
    assert plan.human_confirmation_required is True
    assert plan.maximum_loss_weight <= 0.01 + 1e-9
    assert plan.valid_until > NOW.date()


def test_missing_pairwise_correlation_cannot_open_plan() -> None:
    value = CandidateAsset(CANDIDATE, 10, "新行业", 2, 0.08, 1e8)
    result = build_buy_plans(
        account(),
        [value],
        source_snapshot_hash="abc",
        source_trust_tier="primary_authorized",
        stage2_qualified=True,
    )
    assert result.ready is False
    assert "候选均无法" in result.reasons[0]
