"""Deterministic data gates used before factors, AI, plans or backtests."""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from math import isfinite

from .domain import (
    Bar,
    DataQualityReport,
    FinancialPointInTime,
    QualityCode,
    QualityIssue,
    QualitySeverity,
    Quote,
)


@dataclass(frozen=True, slots=True)
class QualityPolicy:
    max_quote_age: timedelta = timedelta(minutes=15)
    future_tolerance: timedelta = timedelta(minutes=2)
    cross_source_price_deviation: float = 0.005


class DataQualityValidator:
    def __init__(self, policy: QualityPolicy | None = None) -> None:
        self.policy = policy or QualityPolicy()

    def quote(
        self,
        value: Quote,
        *,
        references: Iterable[Quote] = (),
        checked_at: datetime | None = None,
    ) -> DataQualityReport:
        now = (checked_at or datetime.now(UTC)).astimezone(UTC)
        issues: list[QualityIssue] = []
        prices = [value.price, value.previous_close, value.open, value.high, value.low]
        if not all(isfinite(item) for item in prices):
            issues.append(self._blocking(QualityCode.MISSING, "报价包含非有限数值"))
        elif value.price <= 0 or value.previous_close <= 0:
            issues.append(self._blocking(QualityCode.MISSING, "现价或昨收缺失"))
        if value.open <= 0 or value.low <= 0 or value.high <= 0:
            issues.append(self._blocking(QualityCode.MISSING, "OHLC字段缺失"))
        elif value.high < max(value.open, value.low, value.price) or value.low > min(
            value.open, value.high, value.price
        ):
            issues.append(self._blocking(QualityCode.INVALID_OHLC, "报价OHLC关系无效"))
        if min(value.volume, value.amount, value.turnover_rate) < 0:
            issues.append(
                self._blocking(QualityCode.NEGATIVE_ACTIVITY, "成交字段出现负数")
            )
        if not value.evidence.provider or not value.evidence.dataset:
            issues.append(
                self._blocking(QualityCode.MISSING_EVIDENCE, "行情缺少来源证据")
            )
        observed = value.evidence.observed_at.astimezone(UTC)
        if observed > now + self.policy.future_tolerance:
            issues.append(self._blocking(QualityCode.FUTURE, "行情时间位于未来"))
        elif now - observed > self.policy.max_quote_age:
            issues.append(self._blocking(QualityCode.STALE, "行情超过允许时效"))

        providers = {value.evidence.provider}
        for reference in references:
            providers.add(reference.evidence.provider)
            if reference.instrument != value.instrument or reference.price <= 0:
                continue
            deviation = abs(value.price - reference.price) / (
                (abs(value.price) + abs(reference.price)) / 2
            )
            if deviation > self.policy.cross_source_price_deviation:
                issues.append(
                    self._blocking(
                        QualityCode.SOURCE_CONFLICT,
                        f"{value.evidence.provider}与{reference.evidence.provider}价格偏差过大",
                    )
                )
        return DataQualityReport(now, tuple(self._dedupe(issues)), tuple(sorted(providers)))

    def bars(
        self, values: Sequence[Bar], *, checked_at: datetime | None = None
    ) -> DataQualityReport:
        now = (checked_at or datetime.now(UTC)).astimezone(UTC)
        issues: list[QualityIssue] = []
        providers = {item.evidence.provider for item in values}
        if not values:
            issues.append(self._blocking(QualityCode.MISSING, "K线为空"))
        previous: datetime | None = None
        seen: set[datetime] = set()
        for index, item in enumerate(values):
            timestamp = item.timestamp.astimezone(UTC)
            if timestamp in seen:
                issues.append(self._blocking(QualityCode.DUPLICATE, "K线时间重复"))
            seen.add(timestamp)
            if previous is not None and timestamp <= previous:
                issues.append(self._blocking(QualityCode.UNORDERED, "K线未严格递增"))
            previous = timestamp
            if timestamp > now + self.policy.future_tolerance:
                issues.append(self._blocking(QualityCode.FUTURE, "K线包含未来数据"))
            if min(item.open, item.high, item.low, item.close) <= 0 or item.high < max(
                item.open, item.low, item.close
            ) or item.low > min(item.open, item.high, item.close):
                issues.append(
                    self._blocking(
                        QualityCode.INVALID_OHLC, f"第{index + 1}根K线OHLC无效"
                    )
                )
            if item.volume < 0 or item.amount < 0:
                issues.append(
                    self._blocking(QualityCode.NEGATIVE_ACTIVITY, "K线成交字段为负")
                )
        return DataQualityReport(now, tuple(self._dedupe(issues)), tuple(sorted(providers)))

    def financials(
        self,
        values: Sequence[FinancialPointInTime],
        *,
        as_of: datetime,
    ) -> DataQualityReport:
        if as_of.tzinfo is None or as_of.utcoffset() is None:
            raise ValueError("as_of must be timezone-aware")
        issues: list[QualityIssue] = []
        providers = {item.evidence.provider for item in values}
        for item in values:
            if item.available_at > as_of:
                issues.append(
                    self._blocking(
                        QualityCode.POINT_IN_TIME_VIOLATION,
                        "财务数据在回测时点尚不可见",
                    )
                )
        return DataQualityReport(
            as_of.astimezone(UTC),
            tuple(self._dedupe(issues)),
            tuple(sorted(providers)),
        )

    @staticmethod
    def _blocking(code: QualityCode, message: str) -> QualityIssue:
        return QualityIssue(code, QualitySeverity.BLOCKING, message)

    @staticmethod
    def _dedupe(values: Iterable[QualityIssue]) -> list[QualityIssue]:
        output: list[QualityIssue] = []
        seen: set[tuple[QualityCode, str]] = set()
        for item in values:
            key = (item.code, item.message)
            if key not in seen:
                seen.add(key)
                output.append(item)
        return output
