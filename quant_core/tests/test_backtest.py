from datetime import date, timedelta

import pytest

from syncnote_quant.backtest import (
    AShareBacktester,
    AShareMarketBar,
    ExecutionConfig,
    OrderSide,
    RejectReason,
)
from syncnote_quant.domain import Exchange, InstrumentId

START = date(2026, 8, 24)
STOCK = InstrumentId("600001", Exchange.SSE)


def bar(
    offset: int,
    *,
    open_price: float = 10,
    close: float = 10,
    previous: float = 10,
    high: float | None = None,
    low: float | None = None,
    volume: float = 1_000_000,
    suspended: bool = False,
    instrument: InstrumentId = STOCK,
) -> AShareMarketBar:
    return AShareMarketBar(
        instrument,
        START + timedelta(days=offset),
        open_price,
        max(open_price, close) if high is None else high,
        min(open_price, close) if low is None else low,
        close,
        previous,
        volume,
        suspended,
    )


def test_close_signal_executes_next_day_and_sell_obeys_t_plus_one() -> None:
    engine = AShareBacktester(
        ExecutionConfig(
            commission_rate=0,
            minimum_commission=5,
            stamp_duty_rate=0.0005,
            transfer_fee_rate=0,
            slippage_bps=0,
            max_volume_participation=1,
        )
    )
    result = engine.run(
        [bar(0), bar(1), bar(2)],
        {
            START: {STOCK: 0.10},
            START + timedelta(days=1): {STOCK: 0.0},
        },
    )
    assert [(trade.side, trade.trade_date) for trade in result.trades] == [
        (OrderSide.BUY, START + timedelta(days=1)),
        (OrderSide.SELL, START + timedelta(days=2)),
    ]
    assert all(trade.shares % 100 == 0 for trade in result.trades)
    assert result.trades[0].fees == 5
    assert result.trades[1].fees == 10
    assert result.metrics.total_cost == 15


def test_one_word_limit_up_rejects_then_retries_on_next_open() -> None:
    engine = AShareBacktester(ExecutionConfig(slippage_bps=0, max_volume_participation=1))
    result = engine.run(
        [
            bar(0),
            bar(1, open_price=11, close=11, previous=10, high=11, low=11),
            bar(2, open_price=10.5, close=10.6, previous=11),
        ],
        {START: {STOCK: 0.20}},
    )
    assert result.rejections[0].reason == RejectReason.LIMIT_UP
    assert result.trades[0].trade_date == START + timedelta(days=2)


def test_suspension_and_volume_capacity_are_not_optimistic() -> None:
    engine = AShareBacktester(
        ExecutionConfig(slippage_bps=0, max_volume_participation=0.10)
    )
    result = engine.run(
        [bar(0), bar(1, suspended=True), bar(2, volume=1_000)],
        {START: {STOCK: 0.50}},
    )
    assert result.rejections[0].reason == RejectReason.SUSPENDED
    assert result.trades[0].shares == 100
    assert result.final_positions[STOCK].shares == 100


def test_backtest_snapshot_hash_and_metrics_are_reproducible() -> None:
    bars = [bar(0), bar(1, close=9), bar(2, open_price=9, close=11, previous=9)]
    signals = {START: {STOCK: 0.50}}
    engine = AShareBacktester(ExecutionConfig(slippage_bps=0, max_volume_participation=1))
    first = engine.run(bars, signals)
    second = engine.run(bars, signals)
    assert first.snapshot_hash == second.snapshot_hash
    assert first.metrics == second.metrics
    assert first.metrics.max_drawdown <= 0


def test_price_limits_use_exchange_round_half_up() -> None:
    bar_item = bar(
        1,
        open_price=11.01,
        close=11.01,
        previous=10.005,
        high=11.01,
        low=11.01,
    )
    result = AShareBacktester(
        ExecutionConfig(slippage_bps=0, max_volume_participation=1)
    ).run([bar(0), bar_item], {START: {STOCK: 0.1}})
    assert result.rejections[0].reason == RejectReason.LIMIT_UP


def test_tiny_price_limit_moves_at_least_one_tick() -> None:
    assert AShareBacktester._price_limit(0.05, 0.10, up=True) == 0.06
    assert AShareBacktester._price_limit(0.05, 0.10, up=False) == 0.04


def test_risk_warning_limit_depends_on_board_exchange_and_effective_date() -> None:
    sz_main = InstrumentId("000001", Exchange.SZSE)
    sh_main = InstrumentId("600001", Exchange.SSE)
    chinext = InstrumentId("300001", Exchange.SZSE)
    assert AShareBacktester._price_limit_ratio(sz_main, date(2026, 7, 5), True) == 0.05
    assert AShareBacktester._price_limit_ratio(sz_main, date(2026, 7, 6), True) == 0.10
    assert AShareBacktester._price_limit_ratio(sh_main, date(2026, 7, 6), True) == 0.05
    assert AShareBacktester._price_limit_ratio(chinext, date(2026, 7, 6), True) == 0.20


def test_bse_only_listing_day_is_unlimited() -> None:
    bse = InstrumentId("920001", Exchange.BSE)
    first = AShareMarketBar(
        bse, START, 10, 10, 10, 10, 10, 1_000_000, listing_days=1
    )
    second = AShareMarketBar(
        bse,
        START + timedelta(days=1),
        13,
        13,
        13,
        13,
        10,
        1_000_000,
        listing_days=2,
    )
    result = AShareBacktester(
        ExecutionConfig(slippage_bps=0, max_volume_participation=1)
    ).run([first, second], {START: {bse: 0.1}})
    assert result.rejections[0].reason == RejectReason.LIMIT_UP


def test_position_is_forced_out_on_delisting_final_day() -> None:
    bars = [
        bar(0),
        bar(1),
        AShareMarketBar(
            STOCK,
            START + timedelta(days=2),
            9.5,
            9.5,
            9.5,
            9.5,
            10,
            1_000_000,
            delisting_final_day=True,
        ),
    ]
    result = AShareBacktester(
        ExecutionConfig(slippage_bps=0, max_volume_participation=1)
    ).run(bars, {START: {STOCK: 0.1}})
    assert [item.side for item in result.trades] == [OrderSide.BUY, OrderSide.SELL]
    assert result.trades[-1].trade_date == START + timedelta(days=2)
    assert STOCK not in result.final_positions


def test_input_and_signal_mapping_order_do_not_change_results() -> None:
    other = InstrumentId("600002", Exchange.SSE)
    bars = [
        bar(offset, instrument=instrument)
        for offset in range(3)
        for instrument in (STOCK, other)
    ]
    first_signals = {START: {STOCK: 0.2, other: 0.2}}
    second_signals = {START: {other: 0.2, STOCK: 0.2}}
    engine = AShareBacktester(
        ExecutionConfig(slippage_bps=0, max_volume_participation=1)
    )
    first = engine.run(bars, first_signals)
    second = engine.run(list(reversed(bars)), second_signals)
    assert first.metrics == second.metrics
    assert [item.instrument for item in first.trades] == [
        item.instrument for item in second.trades
    ]


def test_engine_rejects_implicit_leverage_and_non_finite_bars() -> None:
    other = InstrumentId("600002", Exchange.SSE)
    engine = AShareBacktester()
    with pytest.raises(ValueError, match="exceed 100%"):
        engine.run(
            [bar(0), bar(0, instrument=other), bar(1), bar(1, instrument=other)],
            {START: {STOCK: 0.6, other: 0.6}},
        )
    with pytest.raises(ValueError, match="prices must be positive"):
        engine.run([bar(0), bar(1, open_price=float("nan"))], {})


def test_execution_configuration_rejects_optimistic_invalid_values() -> None:
    with pytest.raises(ValueError, match="max_volume_participation"):
        ExecutionConfig(max_volume_participation=1.1)
    with pytest.raises(ValueError, match="execution costs"):
        ExecutionConfig(commission_rate=-0.1)


def test_star_market_never_submits_invalid_one_hundred_share_buy() -> None:
    star = InstrumentId("688001", Exchange.SSE)
    result = AShareBacktester(
        ExecutionConfig(slippage_bps=0, max_volume_participation=1)
    ).run(
        [bar(0, instrument=star), bar(1, instrument=star)],
        {START: {star: 0.01}},
    )
    assert result.trades == ()
    assert result.rejections[0].reason == RejectReason.MINIMUM_ORDER


def test_slippage_price_never_crosses_daily_price_limit() -> None:
    result = AShareBacktester(
        ExecutionConfig(slippage_bps=20, max_volume_participation=1)
    ).run(
        [
            bar(0),
            bar(1, open_price=11, close=10.9, previous=10, high=11, low=10.9),
        ],
        {START: {STOCK: 0.1}},
    )
    assert result.trades[0].price == 11


def test_slippage_price_stays_inside_observed_daily_range() -> None:
    result = AShareBacktester(
        ExecutionConfig(slippage_bps=50, max_volume_participation=1)
    ).run([bar(0), bar(1, high=10.02, low=9.98)], {START: {STOCK: 0.1}})
    assert result.trades[0].price == 10.02


def test_rebalance_sells_before_buys_to_release_cash() -> None:
    other = InstrumentId("600002", Exchange.SSE)
    bars = [
        bar(offset, instrument=instrument)
        for offset in range(3)
        for instrument in (STOCK, other)
    ]
    result = AShareBacktester(
        ExecutionConfig(slippage_bps=0, max_volume_participation=1)
    ).run(
        bars,
        {
            START: {other: 0.8},
            START + timedelta(days=1): {STOCK: 0.8, other: 0.0},
        },
    )
    day_two = [
        item.side
        for item in result.trades
        if item.trade_date == START + timedelta(days=2)
    ]
    assert day_two == [OrderSide.SELL, OrderSide.BUY]
