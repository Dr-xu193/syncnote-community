"""Serializable stage-two research report with conservative qualification gates."""

from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from dataclasses import asdict, dataclass
from datetime import datetime
from typing import Any

from .backtest import BacktestMetrics
from .domain import require_aware
from .strategy_pipeline import CostStressResult, SampleSplitResult


@dataclass(frozen=True, slots=True)
class StrategyQualification:
    qualified_for_plan: bool
    reasons: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class QuantResearchReport:
    schema_version: int
    strategy_name: str
    generated_at: datetime
    provider: str
    trust_tier: str
    snapshot_hash: str
    factor_coverage: float
    in_sample: Mapping[str, float | None]
    out_of_sample: Mapping[str, float | None]
    cost_stress: Mapping[str, Mapping[str, float | None]]
    walk_forward: tuple[Mapping[str, Any], ...]
    execution_assumptions: Mapping[str, Any]
    qualification: StrategyQualification
    warnings: tuple[str, ...]

    def __post_init__(self) -> None:
        require_aware(self.generated_at, "generated_at")

    def to_json(self) -> str:
        payload = asdict(self)
        payload["generated_at"] = self.generated_at.isoformat()
        return json.dumps(
            payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )


def build_research_report(
    *,
    strategy_name: str,
    generated_at: datetime,
    provider: str,
    trust_tier: str,
    factor_coverage: float,
    sample_split: SampleSplitResult,
    cost_stress: Sequence[CostStressResult],
    execution_assumptions: Mapping[str, Any],
    walk_forward: Sequence[Mapping[str, Any]],
    minimum_out_sample_days: int = 121,
    minimum_out_sample_trades: int = 20,
) -> QuantResearchReport:
    require_aware(generated_at, "generated_at")
    reasons: list[str] = []
    if trust_tier not in {"primary_authorized", "public_personal_research"}:
        reasons.append("数据源不是已授权主数据源，只能用于公开验证")
    if factor_coverage < 0.70:
        reasons.append("因子覆盖率低于70%")
    out_days = len(sample_split.out_of_sample.daily)
    if out_days < minimum_out_sample_days:
        reasons.append(f"样本外仅{out_days}个交易日，低于{minimum_out_sample_days}日")
    out_trades = len(sample_split.out_of_sample.trades)
    if out_trades < minimum_out_sample_trades:
        reasons.append(f"样本外仅{out_trades}笔成交，低于{minimum_out_sample_trades}笔")
    stressed = next((item for item in cost_stress if item.label == "cost_x3"), None)
    if stressed is None:
        reasons.append("缺少三倍成本压力测试")
    elif stressed.result.metrics.total_return <= 0:
        reasons.append("三倍成本压力下总收益不为正")
    if len(walk_forward) < 3:
        reasons.append("Walk-forward 样本外折数少于3")
    else:
        ordered_returns = sorted(
            float(item.get("testTotalReturn") or 0) for item in walk_forward
        )
        median_return = ordered_returns[len(ordered_returns) // 2]
        if median_return <= 0:
            reasons.append("Walk-forward 样本外收益中位数不为正")

    warnings = (
        "回测收益不等于未来收益，报告不构成买卖建议。",
        "AI不得改写行情、因子、成交或风险数值。",
        "只有所有确定性门禁通过后，下一阶段才可生成待人工确认的计划。",
        (
            "免费公开源计划只用于个人研究演练，不得连接券商。"
            if trust_tier == "public_personal_research"
            else "授权数据仍需用户逐项人工确认。"
        ),
    )
    return QuantResearchReport(
        schema_version=1,
        strategy_name=strategy_name,
        generated_at=generated_at,
        provider=provider,
        trust_tier=trust_tier,
        snapshot_hash=sample_split.out_of_sample.snapshot_hash,
        factor_coverage=factor_coverage,
        in_sample=_metrics(sample_split.in_sample.metrics),
        out_of_sample=_metrics(sample_split.out_of_sample.metrics),
        cost_stress={item.label: _metrics(item.result.metrics) for item in cost_stress},
        walk_forward=tuple(dict(item) for item in walk_forward),
        execution_assumptions=dict(execution_assumptions),
        qualification=StrategyQualification(not reasons, tuple(reasons)),
        warnings=warnings,
    )


def _metrics(metrics: BacktestMetrics) -> Mapping[str, float | None]:
    return {
        "total_return": metrics.total_return,
        "annualized_return": metrics.annualized_return,
        "annualized_volatility": metrics.annualized_volatility,
        "sharpe": metrics.sharpe,
        "sortino": metrics.sortino,
        "max_drawdown": metrics.max_drawdown,
        "calmar": metrics.calmar,
        "positive_day_ratio": metrics.positive_day_ratio,
        "turnover": metrics.turnover,
        "total_cost": metrics.total_cost,
        "cvar_95": metrics.cvar_95,
        "beta": metrics.beta,
    }
