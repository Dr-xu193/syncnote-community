"""Deterministic daily A-share backtest used as the execution truth layer."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping, Sequence
from dataclasses import asdict, dataclass
from datetime import date
from decimal import ROUND_HALF_UP, Decimal
from enum import StrEnum
from math import ceil, floor, isfinite, sqrt
from statistics import fmean, pstdev

from .domain import Exchange, InstrumentId


class OrderSide(StrEnum):
    BUY = "buy"
    SELL = "sell"


class RejectReason(StrEnum):
    SUSPENDED = "suspended"
    LIMIT_UP = "limit_up"
    LIMIT_DOWN = "limit_down"
    T_PLUS_ONE = "t_plus_one"
    INSUFFICIENT_CASH = "insufficient_cash"
    VOLUME_LIMIT = "volume_limit"
    MISSING_BAR = "missing_bar"
    DELISTED = "delisted"
    MINIMUM_ORDER = "minimum_order"


@dataclass(frozen=True, slots=True)
class AShareMarketBar:
    instrument: InstrumentId
    trade_date: date
    open: float
    high: float
    low: float
    close: float
    previous_close: float
    volume: float
    suspended: bool = False
    is_st: bool = False
    listing_days: int = 9999
    unlimited: bool = False
    delisting_final_day: bool = False


@dataclass(frozen=True, slots=True)
class ExecutionConfig:
    lot_size: int = 100
    commission_rate: float = 0.0003
    minimum_commission: float = 5.0
    stamp_duty_rate: float = 0.0005
    transfer_fee_rate: float = 0.00001
    slippage_bps: float = 5.0
    max_volume_participation: float = 0.10
    annual_trading_days: int = 242

    def __post_init__(self) -> None:
        if self.lot_size <= 0 or self.annual_trading_days <= 0:
            raise ValueError("lot_size and annual_trading_days must be positive")
        costs = (
            self.commission_rate,
            self.minimum_commission,
            self.stamp_duty_rate,
            self.transfer_fee_rate,
            self.slippage_bps,
        )
        if any(not isfinite(value) or value < 0 for value in costs):
            raise ValueError("execution costs must be finite and non-negative")
        if not 0 < self.max_volume_participation <= 1:
            raise ValueError("max_volume_participation must be in (0, 1]")


@dataclass(slots=True)
class Position:
    shares: int = 0
    sellable_shares: int = 0
    average_cost: float = 0.0


@dataclass(frozen=True, slots=True)
class Trade:
    trade_date: date
    instrument: InstrumentId
    side: OrderSide
    shares: int
    price: float
    gross_value: float
    fees: float
    signal_date: date


@dataclass(frozen=True, slots=True)
class RejectedOrder:
    trade_date: date
    instrument: InstrumentId
    side: OrderSide
    requested_shares: int
    reason: RejectReason
    signal_date: date


@dataclass(frozen=True, slots=True)
class DailyPortfolio:
    trade_date: date
    cash: float
    market_value: float
    equity: float
    daily_return: float
    cumulative_cost: float


@dataclass(frozen=True, slots=True)
class BacktestMetrics:
    total_return: float
    annualized_return: float
    annualized_volatility: float
    sharpe: float
    sortino: float
    max_drawdown: float
    calmar: float
    positive_day_ratio: float
    turnover: float
    total_cost: float
    cvar_95: float
    beta: float | None


@dataclass(frozen=True, slots=True)
class BacktestResult:
    daily: tuple[DailyPortfolio, ...]
    trades: tuple[Trade, ...]
    rejections: tuple[RejectedOrder, ...]
    final_positions: Mapping[InstrumentId, Position]
    metrics: BacktestMetrics
    snapshot_hash: str


@dataclass(slots=True)
class _PendingTarget:
    target_weight: float
    signal_date: date


class AShareBacktester:
    def __init__(self, config: ExecutionConfig | None = None) -> None:
        self.config = config or ExecutionConfig()

    def run(
        self,
        bars: Sequence[AShareMarketBar],
        signals: Mapping[date, Mapping[InstrumentId, float]],
        *,
        initial_cash: float = 100_000.0,
        benchmark_closes: Mapping[date, float] | None = None,
    ) -> BacktestResult:
        if initial_cash <= 0:
            raise ValueError("initial_cash must be positive")
        for day, weights in signals.items():
            total = sum(weights.values())
            if not isfinite(total) or total > 1 + 1e-12:
                raise ValueError(f"target weights exceed 100% on {day}")
        grouped: dict[date, dict[InstrumentId, AShareMarketBar]] = {}
        for bar in bars:
            self._validate_bar(bar)
            if bar.instrument in grouped.setdefault(bar.trade_date, {}):
                raise ValueError("duplicate instrument/date bar")
            grouped[bar.trade_date][bar.instrument] = bar
        dates = sorted(grouped)
        if len(dates) < 2:
            raise ValueError("at least two trading dates are required")

        cash = initial_cash
        cumulative_cost = 0.0
        positions: dict[InstrumentId, Position] = {}
        last_close: dict[InstrumentId, float] = {}
        pending: dict[InstrumentId, _PendingTarget] = {}
        delisted: set[InstrumentId] = set()
        trades: list[Trade] = []
        rejections: list[RejectedOrder] = []
        daily: list[DailyPortfolio] = []
        traded_value = 0.0

        for trade_date in dates:
            day_bars = grouped[trade_date]
            for position in positions.values():
                position.sellable_shares = position.shares

            open_equity = cash + sum(
                position.shares
                * (
                    day_bars[instrument].open
                    if instrument in day_bars
                    else last_close.get(instrument, position.average_cost)
                )
                for instrument, position in sorted(
                    positions.items(), key=lambda item: item[0].canonical
                )
                if instrument not in delisted
            )
            for instrument, bar in day_bars.items():
                position = positions.get(instrument)
                if not bar.delisting_final_day or position is None or position.shares <= 0:
                    continue
                cash, cost, value, _ = self._execute_target(
                    trade_date,
                    _PendingTarget(0.0, trade_date),
                    bar,
                    open_equity,
                    cash,
                    positions,
                    trades,
                    rejections,
                )
                cumulative_cost += cost
                traded_value += value
                pending.pop(instrument, None)
            ordered_pending = sorted(
                pending.items(),
                key=lambda item: self._pending_priority(
                    item[0], item[1], day_bars, open_equity, positions
                ),
            )
            for instrument, target in ordered_pending:
                if instrument in delisted:
                    rejections.append(
                        RejectedOrder(
                            trade_date,
                            instrument,
                            OrderSide.BUY if target.target_weight > 0 else OrderSide.SELL,
                            0,
                            RejectReason.DELISTED,
                            target.signal_date,
                        )
                    )
                    pending.pop(instrument, None)
                    continue
                bar = day_bars.get(instrument)
                if bar is None:
                    rejections.append(
                        RejectedOrder(
                            trade_date,
                            instrument,
                            OrderSide.BUY if target.target_weight > 0 else OrderSide.SELL,
                            0,
                            RejectReason.MISSING_BAR,
                            target.signal_date,
                        )
                    )
                    continue
                cash, cost, value, completed = self._execute_target(
                    trade_date,
                    target,
                    bar,
                    open_equity,
                    cash,
                    positions,
                    trades,
                    rejections,
                )
                cumulative_cost += cost
                traded_value += value
                if completed:
                    pending.pop(instrument, None)

            for instrument, bar in day_bars.items():
                last_close[instrument] = bar.close
            market_value = sum(
                position.shares * last_close.get(instrument, position.average_cost)
                for instrument, position in sorted(
                    positions.items(), key=lambda item: item[0].canonical
                )
                if instrument not in delisted
            )
            equity = cash + market_value
            previous_equity = daily[-1].equity if daily else initial_cash
            daily.append(
                DailyPortfolio(
                    trade_date,
                    cash,
                    market_value,
                    equity,
                    equity / previous_equity - 1,
                    cumulative_cost,
                )
            )
            for instrument, target_weight in sorted(
                signals.get(trade_date, {}).items(),
                key=lambda item: item[0].canonical,
            ):
                if not 0 <= target_weight <= 1:
                    raise ValueError("target weights must be between zero and one")
                if instrument not in delisted:
                    pending[instrument] = _PendingTarget(target_weight, trade_date)
            delisted.update(
                instrument
                for instrument, bar in day_bars.items()
                if bar.delisting_final_day
            )

        metrics = self._metrics(
            daily,
            traded_value,
            cumulative_cost,
            benchmark_closes or {},
        )
        return BacktestResult(
            tuple(daily),
            tuple(trades),
            tuple(rejections),
            {
                key: Position(value.shares, value.sellable_shares, value.average_cost)
                for key, value in positions.items()
                if value.shares > 0
            },
            metrics,
            self._snapshot_hash(bars, signals, initial_cash),
        )

    def _execute_target(
        self,
        trade_date: date,
        target: _PendingTarget,
        bar: AShareMarketBar,
        equity: float,
        cash: float,
        positions: dict[InstrumentId, Position],
        trades: list[Trade],
        rejections: list[RejectedOrder],
    ) -> tuple[float, float, float, bool]:
        position = positions.setdefault(bar.instrument, Position())
        desired = floor(equity * target.target_weight / bar.open / self.config.lot_size)
        desired *= self.config.lot_size
        delta = desired - position.shares
        if abs(delta) < self.config.lot_size:
            return cash, 0.0, 0.0, True
        side = OrderSide.BUY if delta > 0 else OrderSide.SELL
        requested = abs(delta)
        blocked = self._blocked_reason(bar, side)
        if blocked is not None:
            rejections.append(
                RejectedOrder(
                    trade_date,
                    bar.instrument,
                    side,
                    requested,
                    blocked,
                    target.signal_date,
                )
            )
            return cash, 0.0, 0.0, False

        volume_cap = floor(
            bar.volume * self.config.max_volume_participation / self.config.lot_size
        ) * self.config.lot_size
        if volume_cap <= 0:
            rejections.append(
                RejectedOrder(
                    trade_date,
                    bar.instrument,
                    side,
                    requested,
                    RejectReason.VOLUME_LIMIT,
                    target.signal_date,
                )
            )
            return cash, 0.0, 0.0, False
        shares = min(requested, volume_cap)

        if side == OrderSide.SELL:
            if position.sellable_shares <= 0:
                rejections.append(
                    RejectedOrder(
                        trade_date,
                        bar.instrument,
                        side,
                        requested,
                        RejectReason.T_PLUS_ONE,
                        target.signal_date,
                    )
                )
                return cash, 0.0, 0.0, False
            shares = min(shares, position.sellable_shares)
        price = self._execution_price(bar, side)

        if side == OrderSide.BUY:
            minimum_buy = self._minimum_buy_shares(bar.instrument)
            if shares < minimum_buy:
                rejections.append(
                    RejectedOrder(
                        trade_date,
                        bar.instrument,
                        side,
                        requested,
                        RejectReason.MINIMUM_ORDER,
                        target.signal_date,
                    )
                )
                return cash, 0.0, 0.0, requested < minimum_buy
            while shares >= self.config.lot_size:
                gross = shares * price
                fees = self._fees(gross, side)
                if gross + fees <= cash:
                    break
                shares -= self.config.lot_size
            if shares < self.config.lot_size:
                rejections.append(
                    RejectedOrder(
                        trade_date,
                        bar.instrument,
                        side,
                        requested,
                        RejectReason.INSUFFICIENT_CASH,
                        target.signal_date,
                    )
                )
                return cash, 0.0, 0.0, False
            gross = shares * price
            fees = self._fees(gross, side)
            old_cost = position.average_cost * position.shares
            position.shares += shares
            position.average_cost = (old_cost + gross + fees) / position.shares
            cash -= gross + fees
        else:
            shares = floor(shares / self.config.lot_size) * self.config.lot_size
            if shares <= 0:
                return cash, 0.0, 0.0, False
            gross = shares * price
            fees = self._fees(gross, side)
            position.shares -= shares
            position.sellable_shares -= shares
            cash += gross - fees
            if position.shares == 0:
                position.average_cost = 0.0
        trades.append(
            Trade(
                trade_date,
                bar.instrument,
                side,
                shares,
                price,
                gross,
                fees,
                target.signal_date,
            )
        )
        completed = abs(desired - position.shares) < self.config.lot_size
        return cash, fees, gross, completed

    def _pending_priority(
        self,
        instrument: InstrumentId,
        target: _PendingTarget,
        day_bars: Mapping[InstrumentId, AShareMarketBar],
        equity: float,
        positions: Mapping[InstrumentId, Position],
    ) -> tuple[int, str]:
        bar = day_bars.get(instrument)
        if bar is None:
            return 2, instrument.canonical
        desired = floor(
            equity * target.target_weight / bar.open / self.config.lot_size
        ) * self.config.lot_size
        current = positions.get(instrument, Position()).shares
        return (0 if desired < current else 1), instrument.canonical

    def _blocked_reason(
        self, bar: AShareMarketBar, side: OrderSide
    ) -> RejectReason | None:
        if bar.suspended:
            return RejectReason.SUSPENDED
        if bar.unlimited or self._is_ipo_unlimited(bar):
            return None
        ratio = self._price_limit_ratio(bar.instrument, bar.trade_date, bar.is_st)
        limit_up = self._price_limit(bar.previous_close, ratio, up=True)
        limit_down = self._price_limit(bar.previous_close, ratio, up=False)
        if side == OrderSide.BUY and bar.open >= limit_up and bar.low >= limit_up:
            return RejectReason.LIMIT_UP
        if side == OrderSide.SELL and bar.open <= limit_down and bar.high <= limit_down:
            return RejectReason.LIMIT_DOWN
        return None

    @staticmethod
    def _price_limit_ratio(
        instrument: InstrumentId, trade_date: date, is_st: bool
    ) -> float:
        if instrument.exchange == Exchange.BSE:
            return 0.30
        if instrument.code.startswith(("300", "301", "688")):
            return 0.20
        if is_st and instrument.exchange == Exchange.SSE:
            return 0.05
        if (
            is_st
            and instrument.exchange == Exchange.SZSE
            and trade_date < date(2026, 7, 6)
        ):
            return 0.05
        return 0.10

    @staticmethod
    def _is_ipo_unlimited(bar: AShareMarketBar) -> bool:
        # SSE/SZSE IPOs have no daily limit for the first five trading days;
        # BSE only exempts the listing day. `listing_days` is one-based.
        return bar.listing_days <= (1 if bar.instrument.exchange == Exchange.BSE else 5)

    def _minimum_buy_shares(self, instrument: InstrumentId) -> int:
        # STAR Market requires at least 200 shares per buy order; using the
        # configured 100-share grid above that minimum is conservative but valid.
        if instrument.code.startswith(("688", "689")):
            return max(200, self.config.lot_size)
        return self.config.lot_size

    @staticmethod
    def _price_limit(previous_close: float, ratio: float, *, up: bool) -> float:
        # Exchange rules require round-half-up to the RMB 0.01 tick. If the
        # rounded difference is below one tick, force exactly one tick.
        tick = Decimal("0.01")
        previous = Decimal(str(previous_close)).quantize(tick, rounding=ROUND_HALF_UP)
        direction = Decimal(1) if up else Decimal(-1)
        raw = previous * (Decimal(1) + direction * Decimal(str(ratio)))
        rounded = raw.quantize(tick, rounding=ROUND_HALF_UP)
        if abs(rounded - previous) < tick:
            rounded = previous + direction * tick
        return float(max(tick, rounded))

    def _execution_price(self, bar: AShareMarketBar, side: OrderSide) -> float:
        multiplier = 1 + self.config.slippage_bps / 10_000 * (
            1 if side == OrderSide.BUY else -1
        )
        price = self._round_tick(bar.open * multiplier, up=side == OrderSide.BUY)
        price = min(price, bar.high) if side == OrderSide.BUY else max(price, bar.low)
        if bar.unlimited or self._is_ipo_unlimited(bar):
            return price
        ratio = self._price_limit_ratio(bar.instrument, bar.trade_date, bar.is_st)
        if side == OrderSide.BUY:
            return min(price, self._price_limit(bar.previous_close, ratio, up=True))
        return max(price, self._price_limit(bar.previous_close, ratio, up=False))

    def _fees(self, gross: float, side: OrderSide) -> float:
        commission = max(self.config.minimum_commission, gross * self.config.commission_rate)
        transfer = gross * self.config.transfer_fee_rate
        stamp = gross * self.config.stamp_duty_rate if side == OrderSide.SELL else 0.0
        return commission + transfer + stamp

    @staticmethod
    def _round_tick(value: float, *, up: bool) -> float:
        scaled = value * 100
        return (ceil(scaled - 1e-9) if up else floor(scaled + 1e-9)) / 100

    @staticmethod
    def _validate_bar(bar: AShareMarketBar) -> None:
        prices = (bar.open, bar.high, bar.low, bar.close, bar.previous_close)
        if any(not isfinite(value) for value in prices) or min(prices) <= 0:
            raise ValueError("bar prices must be positive")
        if bar.high < max(bar.open, bar.low, bar.close) or bar.low > min(
            bar.open, bar.high, bar.close
        ):
            raise ValueError("invalid OHLC relationship")
        if not isfinite(bar.volume) or bar.volume < 0:
            raise ValueError("bar volume cannot be negative")
        if bar.listing_days <= 0:
            raise ValueError("listing_days must be positive")

    def _metrics(
        self,
        daily: Sequence[DailyPortfolio],
        traded_value: float,
        total_cost: float,
        benchmark_closes: Mapping[date, float],
    ) -> BacktestMetrics:
        returns = [item.daily_return for item in daily[1:]]
        total_return = daily[-1].equity / daily[0].equity - 1 if len(daily) > 1 else 0.0
        years = max(1 / self.config.annual_trading_days, (len(daily) - 1) / self.config.annual_trading_days)
        annualized = (1 + total_return) ** (1 / years) - 1 if 1 + total_return > 0 else -1.0
        volatility = pstdev(returns) * sqrt(self.config.annual_trading_days) if len(returns) > 1 else 0.0
        mean_return = fmean(returns) if returns else 0.0
        sharpe = mean_return * self.config.annual_trading_days / volatility if volatility > 0 else 0.0
        downside = [min(0.0, value) for value in returns]
        downside_deviation = (
            sqrt(fmean(value * value for value in downside))
            * sqrt(self.config.annual_trading_days)
            if downside
            else 0.0
        )
        sortino = (
            mean_return * self.config.annual_trading_days / downside_deviation
            if downside_deviation > 0
            else 0.0
        )
        peak = daily[0].equity
        max_drawdown = 0.0
        for item in daily:
            peak = max(peak, item.equity)
            max_drawdown = min(max_drawdown, item.equity / peak - 1)
        average_equity = fmean(item.equity for item in daily)
        ordered_returns = sorted(returns)
        tail_count = max(1, ceil(len(ordered_returns) * 0.05)) if ordered_returns else 0
        cvar = fmean(ordered_returns[:tail_count]) if tail_count else 0.0
        beta = self._beta(daily, benchmark_closes)
        return BacktestMetrics(
            total_return,
            annualized,
            volatility,
            sharpe,
            sortino,
            max_drawdown,
            annualized / abs(max_drawdown) if max_drawdown < 0 else 0.0,
            sum(value > 0 for value in returns) / len(returns) if returns else 0.0,
            traded_value / average_equity if average_equity > 0 else 0.0,
            total_cost,
            cvar,
            beta,
        )

    @staticmethod
    def _beta(
        daily: Sequence[DailyPortfolio], benchmark_closes: Mapping[date, float]
    ) -> float | None:
        pairs: list[tuple[float, float]] = []
        previous: float | None = None
        previous_equity: float | None = None
        for item in daily:
            benchmark = benchmark_closes.get(item.trade_date)
            if benchmark is not None and previous is not None and previous_equity is not None:
                pairs.append((item.equity / previous_equity - 1, benchmark / previous - 1))
            if benchmark is not None:
                previous = benchmark
                previous_equity = item.equity
        if len(pairs) < 2:
            return None
        market_mean = fmean(pair[1] for pair in pairs)
        strategy_mean = fmean(pair[0] for pair in pairs)
        variance = fmean((pair[1] - market_mean) ** 2 for pair in pairs)
        if variance == 0:
            return 0.0
        covariance = fmean(
            (strategy - strategy_mean) * (market - market_mean)
            for strategy, market in pairs
        )
        return covariance / variance

    def _snapshot_hash(
        self,
        bars: Sequence[AShareMarketBar],
        signals: Mapping[date, Mapping[InstrumentId, float]],
        initial_cash: float,
    ) -> str:
        payload = {
            "config": asdict(self.config),
            "initial_cash": initial_cash,
            "bars": [
                {
                    **asdict(bar),
                    "instrument": bar.instrument.canonical,
                    "trade_date": bar.trade_date.isoformat(),
                }
                for bar in sorted(bars, key=lambda value: (value.trade_date, value.instrument.canonical))
            ],
            "signals": {
                day.isoformat(): {
                    instrument.canonical: weight
                    for instrument, weight in sorted(
                        weights.items(), key=lambda item: item[0].canonical
                    )
                }
                for day, weights in sorted(signals.items())
            },
        }
        return hashlib.sha256(
            json.dumps(payload, ensure_ascii=True, sort_keys=True).encode("utf-8")
        ).hexdigest()
