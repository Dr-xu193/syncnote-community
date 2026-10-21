"""Portfolio risk accounting and human-confirmed, condition-based buy plans."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from math import floor, isfinite, sqrt

from .domain import InstrumentId, require_aware


@dataclass(frozen=True, slots=True)
class PositionSnapshot:
    instrument: InstrumentId
    shares: int
    sellable_shares: int
    average_cost: float
    last_price: float
    industry: str
    annual_volatility: float = 0.30

    def __post_init__(self) -> None:
        if self.shares < 0 or self.sellable_shares < 0 or self.sellable_shares > self.shares:
            raise ValueError("position share counts are invalid")
        if self.last_price <= 0 or self.average_cost < 0:
            raise ValueError("position prices must be valid")
        if not 0 <= self.annual_volatility <= 5:
            raise ValueError("annual_volatility must be between zero and five")


@dataclass(frozen=True, slots=True)
class AccountSnapshot:
    as_of: datetime
    equity: float
    cash: float
    positions: tuple[PositionSnapshot, ...]

    def __post_init__(self) -> None:
        require_aware(self.as_of, "account as_of")
        if self.equity <= 0 or self.cash < 0 or self.cash > self.equity + 1e-6:
            raise ValueError("account equity/cash are invalid")


@dataclass(frozen=True, slots=True)
class RiskLimits:
    max_position_weight: float = 0.10
    max_industry_weight: float = 0.25
    minimum_cash_weight: float = 0.20
    max_gross_exposure: float = 0.80
    max_single_trade_loss: float = 0.01
    max_correlated_cluster_weight: float = 0.30
    max_plan_age_days: int = 5
    minimum_liquidity_amount: float = 0.0
    max_annualized_volatility: float = 0.35
    require_pairwise_correlations: bool = True

    def __post_init__(self) -> None:
        values = (
            self.max_position_weight,
            self.max_industry_weight,
            self.minimum_cash_weight,
            self.max_gross_exposure,
            self.max_single_trade_loss,
            self.max_correlated_cluster_weight,
            self.max_annualized_volatility,
        )
        if any(not isfinite(value) or not 0 < value <= 1 for value in values):
            raise ValueError("risk limits must be in (0, 1]")
        if self.max_plan_age_days <= 0:
            raise ValueError("max_plan_age_days must be positive")
        if self.minimum_liquidity_amount < 0:
            raise ValueError("minimum_liquidity_amount cannot be negative")


@dataclass(frozen=True, slots=True)
class CandidateAsset:
    instrument: InstrumentId
    price: float
    industry: str
    composite_score: float
    stop_distance: float
    liquidity_amount: float
    correlation_cluster: str = ""
    entry_condition: str = "下一交易日开盘不高于观察价，且质量门禁仍通过"
    annual_volatility: float = 0.30
    correlations: Mapping[InstrumentId, float] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.price <= 0 or self.liquidity_amount < 0:
            raise ValueError("candidate price/liquidity are invalid")
        if not 0 < self.stop_distance < 1:
            raise ValueError("stop_distance must be between zero and one")
        if not 0 <= self.annual_volatility <= 5:
            raise ValueError("annual_volatility must be between zero and five")
        if any(not -1 <= value <= 1 for value in self.correlations.values()):
            raise ValueError("correlations must be between -1 and 1")


@dataclass(frozen=True, slots=True)
class RiskExposure:
    position_weights: Mapping[InstrumentId, float]
    industry_weights: Mapping[str, float]
    cluster_weights: Mapping[str, float]
    gross_exposure: float
    cash_weight: float
    concentration_hhi: float
    largest_position_weight: float
    annualized_volatility: float


@dataclass(frozen=True, slots=True)
class PlanTranche:
    tranche: int
    target_weight: float
    target_shares: int
    condition: str
    invalidation: str


@dataclass(frozen=True, slots=True)
class BuyPlan:
    plan_id: str
    created_at: datetime
    valid_until: date
    source_snapshot_hash: str
    candidate: CandidateAsset
    current_exposure: RiskExposure
    tranches: tuple[PlanTranche, ...]
    total_target_weight: float
    maximum_loss_weight: float
    time_stop_days: int
    exit_rules: tuple[str, ...]
    human_confirmation_required: bool


@dataclass(frozen=True, slots=True)
class PlanDecision:
    ready: bool
    plans: tuple[BuyPlan, ...]
    reasons: tuple[str, ...]


def plan_decision_to_dict(decision: PlanDecision) -> dict[str, object]:
    return {
        "ready": decision.ready,
        "reasons": list(decision.reasons),
        "sourceSnapshotHash": (
            decision.plans[0].source_snapshot_hash if decision.plans else ""
        ),
        "plans": [_plan_to_dict(plan) for plan in decision.plans],
    }


def _plan_to_dict(plan: BuyPlan) -> dict[str, object]:
    exposure = plan.current_exposure
    return {
        "planId": plan.plan_id,
        "createdAt": plan.created_at.isoformat(),
        "validUntil": plan.valid_until.isoformat(),
        "sourceSnapshotHash": plan.source_snapshot_hash,
        "candidate": {
            "instrument": plan.candidate.instrument.canonical,
            "price": plan.candidate.price,
            "industry": plan.candidate.industry,
            "compositeScore": plan.candidate.composite_score,
            "stopDistance": plan.candidate.stop_distance,
            "liquidityAmount": plan.candidate.liquidity_amount,
            "correlationCluster": plan.candidate.correlation_cluster,
        },
        "currentExposure": {
            "positionWeights": {
                key.canonical: value for key, value in exposure.position_weights.items()
            },
            "industryWeights": dict(exposure.industry_weights),
            "clusterWeights": dict(exposure.cluster_weights),
            "grossExposure": exposure.gross_exposure,
            "cashWeight": exposure.cash_weight,
            "concentrationHhi": exposure.concentration_hhi,
            "largestPositionWeight": exposure.largest_position_weight,
            "annualizedVolatility": exposure.annualized_volatility,
        },
        "tranches": [
            {
                "tranche": item.tranche,
                "targetWeight": item.target_weight,
                "targetShares": item.target_shares,
                "condition": item.condition,
                "invalidation": item.invalidation,
            }
            for item in plan.tranches
        ],
        "totalTargetWeight": plan.total_target_weight,
        "maximumLossWeight": plan.maximum_loss_weight,
        "timeStopDays": plan.time_stop_days,
        "exitRules": list(plan.exit_rules),
        "humanConfirmationRequired": plan.human_confirmation_required,
    }


def calculate_exposure(account: AccountSnapshot) -> RiskExposure:
    values = {
        item.instrument: item.shares * item.last_price / account.equity
        for item in account.positions
        if item.shares > 0
    }
    industries: dict[str, float] = {}
    for item in account.positions:
        weight = values.get(item.instrument, 0.0)
        industries[item.industry] = industries.get(item.industry, 0.0) + weight
    # Existing positions lack cluster metadata; industry is the conservative proxy.
    clusters = dict(industries)
    return RiskExposure(
        position_weights=values,
        industry_weights=industries,
        cluster_weights=clusters,
        gross_exposure=sum(values.values()),
        cash_weight=account.cash / account.equity,
        concentration_hhi=sum(weight * weight for weight in values.values()),
        largest_position_weight=max(values.values(), default=0.0),
        annualized_volatility=_identity_volatility(account, values),
    )


def portfolio_volatility(
    weights: Mapping[InstrumentId, float],
    volatilities: Mapping[InstrumentId, float],
    correlations: Mapping[tuple[InstrumentId, InstrumentId], float] | None = None,
) -> float:
    """Annualized volatility from supplied point-in-time covariance inputs."""

    variance = 0.0
    correlation_map = correlations or {}
    instruments = tuple(weights)
    for left in instruments:
        for right in instruments:
            correlation = 1.0 if left == right else correlation_map.get(
                (left, right), correlation_map.get((right, left), 0.0)
            )
            variance += (
                weights[left]
                * weights[right]
                * volatilities.get(left, 0.30)
                * volatilities.get(right, 0.30)
                * correlation
            )
    return sqrt(max(0.0, variance))


def _identity_volatility(
    account: AccountSnapshot, weights: Mapping[InstrumentId, float]
) -> float:
    return portfolio_volatility(
        weights,
        {item.instrument: item.annual_volatility for item in account.positions},
    )


def build_buy_plans(
    account: AccountSnapshot,
    candidates: Sequence[CandidateAsset],
    *,
    source_snapshot_hash: str,
    source_trust_tier: str,
    stage2_qualified: bool,
    plan_id_prefix: str = "plan",
    limits: RiskLimits | None = None,
    max_plans: int = 5,
    time_stop_days: int = 30,
) -> PlanDecision:
    """Build plans only when every deterministic gate is already satisfied."""

    limits = limits or RiskLimits()
    exposure = calculate_exposure(account)
    reasons: list[str] = []
    if source_trust_tier not in {"primary_authorized", "public_personal_research"}:
        reasons.append("数据源未达到已授权主源，不能生成买入计划")
    if not stage2_qualified:
        reasons.append("第二阶段研究门禁未通过，不能生成买入计划")
    if exposure.gross_exposure > limits.max_gross_exposure + 1e-9:
        reasons.append("现有组合总风险敞口已超过上限")
    if exposure.cash_weight < limits.minimum_cash_weight - 1e-9:
        reasons.append("现有现金比例低于最低现金储备")
    if not candidates:
        reasons.append("没有通过数据质量和因子覆盖的候选")
    if reasons:
        return PlanDecision(False, (), tuple(reasons))
    if exposure.annualized_volatility > limits.max_annualized_volatility + 1e-9:
        reasons.append("现有组合年化波动超过上限")
        return PlanDecision(False, (), tuple(reasons))
    if time_stop_days <= 0:
        raise ValueError("time_stop_days must be positive")
    if max_plans <= 0:
        raise ValueError("max_plans must be positive")

    ranked = sorted(
        candidates,
        key=lambda item: (-item.composite_score, item.instrument.canonical),
    )
    plans: list[BuyPlan] = []
    planned_industries = dict(exposure.industry_weights)
    planned_clusters = dict(exposure.cluster_weights)
    available_weight = min(
        limits.max_gross_exposure - exposure.gross_exposure,
        exposure.cash_weight - limits.minimum_cash_weight,
    )
    for candidate in ranked:
        if len(plans) >= max_plans or available_weight <= 1e-9:
            break
        if candidate.liquidity_amount < limits.minimum_liquidity_amount:
            continue
        if limits.require_pairwise_correlations and any(
            item.instrument not in candidate.correlations
            for item in account.positions
            if item.shares > 0
        ):
            continue
        current = exposure.position_weights.get(candidate.instrument, 0.0)
        room = max(0.0, limits.max_position_weight - current)
        industry_room = max(
            0.0,
            limits.max_industry_weight - planned_industries.get(candidate.industry, 0.0),
        )
        cluster = candidate.correlation_cluster or candidate.industry
        cluster_room = max(
            0.0,
            limits.max_correlated_cluster_weight - planned_clusters.get(cluster, 0.0),
        )
        risk_room = limits.max_single_trade_loss / candidate.stop_distance
        target = min(room, industry_room, cluster_room, risk_room, available_weight)
        target = floor(target * 100) / 100
        if target <= 0:
            continue
        target_shares = floor(account.equity * target / candidate.price / 100) * 100
        if target_shares < 100:
            continue
        target = target_shares * candidate.price / account.equity
        current_vols = {
            item.instrument: item.annual_volatility for item in account.positions
        }
        current_vols[candidate.instrument] = candidate.annual_volatility
        current_weights = dict(exposure.position_weights)
        current_weights[candidate.instrument] = current + target
        correlation_pairs = {
            (candidate.instrument, item): value
            for item, value in candidate.correlations.items()
        }
        if (
            portfolio_volatility(current_weights, current_vols, correlation_pairs)
            > limits.max_annualized_volatility + 1e-9
        ):
            continue
        tranche_shares = _allocate_lot_shares(target_shares)
        tranche_weights = tuple(
            shares * candidate.price / account.equity for shares in tranche_shares
        )
        tranches = (
            PlanTranche(
                1,
                tranche_weights[0],
                tranche_shares[0],
                candidate.entry_condition,
                "若收盘跌破硬止损或出现主体逻辑失效，取消后续批次",
            ),
            PlanTranche(
                2,
                tranche_weights[1],
                tranche_shares[1],
                "第一批成交后，下一交易日收盘仍满足趋势与流动性条件",
                "若因子排名跌出候选前30%或行业风险上升，停止加仓",
            ),
            PlanTranche(
                3,
                tranche_weights[2],
                tranche_shares[2],
                "第二批后复核财务/公告和组合风险，人工确认才可继续",
                "达到时间止损、硬止损或论文/公告证据否定时不执行",
            ),
        )
        plans.append(
            BuyPlan(
                plan_id=f"{plan_id_prefix}-{candidate.instrument.canonical}",
                created_at=account.as_of,
                valid_until=account.as_of.date() + timedelta(days=limits.max_plan_age_days),
                source_snapshot_hash=source_snapshot_hash,
                candidate=candidate,
                current_exposure=exposure,
                tranches=tranches,
                total_target_weight=target,
                maximum_loss_weight=target * candidate.stop_distance,
                time_stop_days=time_stop_days,
                exit_rules=(
                    f"硬止损：从计划观察价下跌 {candidate.stop_distance:.1%}",
                    f"时间止损：{time_stop_days} 个交易日内未形成预期走势则复核并退出",
                    "逻辑失效：财务、公告或行业证据否定原始假设时退出",
                ),
                human_confirmation_required=True,
            )
        )
        available_weight -= target
        planned_industries[candidate.industry] = (
            planned_industries.get(candidate.industry, 0.0) + target
        )
        planned_clusters[cluster] = planned_clusters.get(cluster, 0.0) + target
    if not plans:
        return PlanDecision(False, (), ("候选均无法在仓位、行业、相关性、现金或整手约束下建立计划",))
    return PlanDecision(True, tuple(plans), ())


def _allocate_lot_shares(total_shares: int) -> tuple[int, int, int]:
    """Allocate all whole lots across 40/30/30 without losing small plans."""

    lots = total_shares // 100
    if lots <= 0:
        return (0, 0, 0)
    raw = (lots * 0.40, lots * 0.30, lots * 0.30)
    allocated = [floor(value) for value in raw]
    remaining = lots - sum(allocated)
    order = sorted(range(3), key=lambda index: (-(raw[index] - allocated[index]), index))
    for index in order[:remaining]:
        allocated[index] += 1
    return tuple(value * 100 for value in allocated)  # type: ignore[return-value]
