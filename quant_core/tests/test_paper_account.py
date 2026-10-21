"""Forward-only, persistent-account contracts for the 30-day paper experiment."""

from __future__ import annotations

import json
from datetime import date, datetime, time, timedelta

import pytest

from syncnote_quant.backtest import AShareBacktester, AShareMarketBar, ExecutionConfig
from syncnote_quant.cli import main
from syncnote_quant.clock import BEIJING_TZ
from syncnote_quant.domain import Exchange, InstrumentId
from syncnote_quant.paper_account import PaperAccountEngine, PaperAccountState, PaperIntent

FIRST = date(2026, 8, 24)
STOCK = InstrumentId("600001", Exchange.SSE)


def moment(day: date, hour: int = 16, minute: int = 0) -> datetime:
    return datetime.combine(day, time(hour, minute), BEIJING_TZ)


def bar(
    day: date,
    *,
    open_price: float = 10,
    close: float = 10,
    previous: float = 10,
    high: float | None = None,
    low: float | None = None,
    volume: float = 1_000_000,
    suspended: bool = False,
) -> AShareMarketBar:
    return AShareMarketBar(
        STOCK,
        day,
        open_price,
        max(open_price, close) if high is None else high,
        min(open_price, close) if low is None else low,
        close,
        previous,
        volume,
        suspended,
    )


def intent(day: date, name: str, weight: float) -> PaperIntent:
    return PaperIntent(name, STOCK, weight, moment(day, 15, 5))


def advance(
    engine: PaperAccountEngine,
    state: PaperAccountState,
    day: date,
    *,
    bars: tuple[AShareMarketBar, ...] | None = None,
    intents: tuple[PaperIntent, ...] = (),
):
    actual_bars = (bar(day),) if bars is None and day.weekday() < 5 else bars or ()
    return engine.advance(
        state,
        as_of=moment(day),
        bars=actual_bars,
        market_observed_at=moment(day, 15, 1) if actual_bars else None,
        intents=intents,
    )


def test_account_runs_thirty_calendar_days_without_resetting_or_backfilling() -> None:
    engine = PaperAccountEngine(ExecutionConfig(slippage_bps=0, max_volume_participation=1))
    state = engine.start("one-account", 10_000, moment(FIRST, 14))
    all_events = []
    first_fill_cash = None
    for offset in range(30):
        day = FIRST + timedelta(days=offset)
        decisions = (intent(day, "buy-first", 0.5),) if offset == 0 else ()
        result = advance(engine, state, day, intents=decisions)
        all_events.extend(result.events)
        state = PaperAccountState.from_dict(result.state.to_dict())
        if offset == 1:
            first_fill_cash = state.cash
            assert state.positions[0].shares > 0
            assert state.positions[0].sellable_shares == 0
        if offset == 2:
            assert state.positions[0].sellable_shares == state.positions[0].shares
        if offset > 1:
            assert state.cash == first_fill_cash

    assert state.last_processed_day == FIRST + timedelta(days=29)
    assert state.ends_at == moment(FIRST + timedelta(days=30), 0)
    assert sum(item.kind == "fill" for item in all_events) == 1
    assert sum(item.kind == "daily_close" for item in all_events) == 30
    assert len({item.event_id for item in all_events}) == len(all_events)
    terminal = engine.terminal_value(state, as_of=state.ends_at)
    assert terminal.net_value is not None
    assert terminal.net_value < 10_000  # Entry and estimated exit fees are included.
    assert not terminal.missing_prices


def test_decision_is_not_filled_until_next_trading_day_and_sell_follows_t_plus_one() -> None:
    engine = PaperAccountEngine(ExecutionConfig(slippage_bps=0, max_volume_participation=1))
    state = engine.start("next-open", 10_000, moment(FIRST, 14))
    first = advance(engine, state, FIRST, intents=(intent(FIRST, "buy", 0.5),))
    assert first.state.positions == ()
    bought = advance(engine, first.state, FIRST + timedelta(days=1))
    assert [
        (item.kind, item.detail.get("side")) for item in bought.events if item.kind == "fill"
    ] == [("fill", "buy")]
    fill = next(item for item in bought.events if item.kind == "fill").to_dict()
    assert fill["occurredAt"] == moment(FIRST + timedelta(days=1), 9, 30).isoformat()
    assert fill["recordedAt"] == moment(FIRST + timedelta(days=1)).isoformat()
    assert fill["sourceObservedAt"] == moment(FIRST + timedelta(days=1), 15, 1).isoformat()
    assert fill["engineVersion"] == "paper-v1"
    sell_day = FIRST + timedelta(days=2)
    signalled = advance(engine, bought.state, sell_day, intents=(intent(sell_day, "sell", 0),))
    assert signalled.state.positions[0].shares > 0
    sold = advance(engine, signalled.state, FIRST + timedelta(days=3))
    assert sold.state.positions == ()
    assert any(item.kind == "fill" and item.detail["side"] == "sell" for item in sold.events)
    assert sold.state.cash < 10_000
    assert sold.state.cumulative_fees >= 10


def test_incremental_account_matches_existing_ashare_execution_truth() -> None:
    execution = ExecutionConfig(slippage_bps=5, max_volume_participation=1)
    days = [FIRST + timedelta(days=offset) for offset in range(3)]
    bars = [
        bar(days[0]),
        bar(days[1], open_price=10.2, close=10.5, previous=10, high=10.5),
        bar(days[2], open_price=10.6, close=10.4, previous=10.5),
    ]
    expected = AShareBacktester(execution).run(
        bars,
        {days[0]: {STOCK: 0.5}, days[1]: {STOCK: 0.0}},
        initial_cash=10_000,
    )
    engine = PaperAccountEngine(execution)
    state = engine.start("contract", 10_000, moment(FIRST, 14))
    observed_fills = []
    for offset, day in enumerate(days):
        decisions = (
            (intent(day, "buy", 0.5),)
            if offset == 0
            else (intent(day, "sell", 0.0),)
            if offset == 1
            else ()
        )
        result = advance(engine, state, day, bars=(bars[offset],), intents=decisions)
        observed_fills.extend(item for item in result.events if item.kind == "fill")
        state = result.state

    assert [
        (
            item.detail["side"],
            item.occurred_at.date(),
            item.detail["shares"],
            item.detail["price"],
            item.detail["fees"],
        )
        for item in observed_fills
    ] == [
        (trade.side.value, trade.trade_date, trade.shares, trade.price, trade.fees)
        for trade in expected.trades
    ]
    assert state.cash == expected.daily[-1].cash
    assert state.cumulative_fees == expected.metrics.total_cost


def test_limit_up_and_suspension_cannot_fill_optimistically() -> None:
    engine = PaperAccountEngine(ExecutionConfig(slippage_bps=0, max_volume_participation=1))
    state = advance(
        engine,
        engine.start("blocked", 10_000, moment(FIRST, 14)),
        FIRST,
        intents=(intent(FIRST, "buy", 0.5),),
    ).state
    day_one = FIRST + timedelta(days=1)
    blocked = advance(
        engine,
        state,
        day_one,
        bars=(bar(day_one, open_price=11, close=11, previous=10, high=11, low=11),),
    )
    assert blocked.state.positions == ()
    assert any(item.detail.get("reason") == "limit_up" for item in blocked.events)
    day_two = FIRST + timedelta(days=2)
    suspended = advance(
        engine,
        blocked.state,
        day_two,
        bars=(bar(day_two, suspended=True, previous=11),),
    )
    assert suspended.state.positions == ()
    assert any(item.detail.get("reason") == "suspended" for item in suspended.events)
    day_three = FIRST + timedelta(days=3)
    filled = advance(
        engine,
        suspended.state,
        day_three,
        bars=(bar(day_three, open_price=10.5, close=10.5, previous=10),),
    )
    assert filled.state.positions[0].shares > 0


def test_cash_and_volume_capacity_are_real_constraints() -> None:
    engine = PaperAccountEngine(ExecutionConfig(slippage_bps=0, max_volume_participation=0.1))
    small = advance(
        engine,
        engine.start("cash-limit", 1_000, moment(FIRST, 14)),
        FIRST,
        intents=(intent(FIRST, "all-in", 1),),
    ).state
    rejected = advance(engine, small, FIRST + timedelta(days=1))
    assert rejected.state.cash == 1_000
    assert rejected.state.positions == ()
    assert any(item.detail.get("reason") == "insufficient_cash" for item in rejected.events)

    state = advance(
        engine,
        engine.start("volume-limit", 10_000, moment(FIRST, 14)),
        FIRST,
        intents=(intent(FIRST, "buy", 0.8),),
    ).state
    limited = advance(
        engine,
        state,
        FIRST + timedelta(days=1),
        bars=(bar(FIRST + timedelta(days=1), volume=1_000),),
    )
    assert limited.state.positions[0].shares == 100
    assert limited.state.pending  # A partial target remains until a later open.
    assert limited.state.cash >= 0
    assert limited.state.cumulative_fees >= 5


def test_one_thousand_yuan_account_only_buys_affordable_whole_lots() -> None:
    engine = PaperAccountEngine(ExecutionConfig(slippage_bps=0, max_volume_participation=1))
    state = advance(
        engine,
        engine.start("small-bankroll", 1_000, moment(FIRST, 14)),
        FIRST,
        intents=(intent(FIRST, "try-full", 1.0),),
    ).state
    rejected = advance(engine, state, FIRST + timedelta(days=1))
    assert rejected.state.cash == 1_000
    assert rejected.state.positions == ()
    assert any(item.detail.get("reason") == "insufficient_cash" for item in rejected.events)

    cheaper_day = FIRST + timedelta(days=2)
    bought = advance(
        engine,
        rejected.state,
        cheaper_day,
        bars=(bar(cheaper_day, open_price=9.9, close=9.9, previous=10),),
    )
    assert bought.state.initial_cash == 1_000
    assert bought.state.positions[0].shares == 100
    assert 0 <= bought.state.cash < 5
    assert bought.state.cumulative_fees >= 5


def test_too_expensive_lot_is_explained_instead_of_silently_skipped() -> None:
    engine = PaperAccountEngine()
    state = advance(
        engine,
        engine.start("high-price", 1_000, moment(FIRST, 14)),
        FIRST,
        intents=(intent(FIRST, "want-stock", 1.0),),
    ).state
    next_day = FIRST + timedelta(days=1)
    expensive = advance(
        engine,
        state,
        next_day,
        bars=(bar(next_day, open_price=100, close=100, previous=100),),
    )
    assert expensive.state.positions == ()
    assert any(item.detail.get("reason") == "minimum_order" for item in expensive.events)


def test_delisting_final_day_forces_exit_and_prevents_future_targets() -> None:
    engine = PaperAccountEngine(ExecutionConfig(slippage_bps=0, max_volume_participation=1))
    state = advance(
        engine,
        engine.start("delisting", 10_000, moment(FIRST, 14)),
        FIRST,
        intents=(intent(FIRST, "buy", 0.2),),
    ).state
    state = advance(engine, state, FIRST + timedelta(days=1)).state
    final_day = FIRST + timedelta(days=2)
    closing_bar = bar(final_day)
    closing_bar = AShareMarketBar(
        closing_bar.instrument,
        closing_bar.trade_date,
        closing_bar.open,
        closing_bar.high,
        closing_bar.low,
        closing_bar.close,
        closing_bar.previous_close,
        closing_bar.volume,
        delisting_final_day=True,
    )
    result = advance(engine, state, final_day, bars=(closing_bar,))
    assert result.state.positions == ()
    assert result.state.delisted == (STOCK,)
    assert any(item.kind == "fill" and item.detail["side"] == "sell" for item in result.events)
    with pytest.raises(ValueError, match="delisted"):
        advance(
            engine,
            result.state,
            FIRST + timedelta(days=3),
            intents=(intent(FIRST + timedelta(days=3), "rebuy", 0.5),),
        )


def test_missing_current_quote_is_visible_in_daily_valuation() -> None:
    engine = PaperAccountEngine()
    state = advance(
        engine,
        engine.start("stale", 10_000, moment(FIRST, 14)),
        FIRST,
        intents=(intent(FIRST, "buy", 0.4),),
    ).state
    state = advance(engine, state, FIRST + timedelta(days=1)).state
    day_without_data = FIRST + timedelta(days=2)
    result = advance(engine, state, day_without_data, bars=())
    assert result.state.last_equity is None
    close_event = next(item for item in result.events if item.kind == "daily_close")
    assert close_event.detail["missingPrices"] == [STOCK.canonical]


def test_empty_new_account_does_not_require_an_unrelated_stock_bar() -> None:
    engine = PaperAccountEngine()
    state = engine.start("empty-account", 1_000, moment(FIRST, 14))
    result = advance(engine, state, FIRST, bars=())
    assert result.state.cash == 1_000
    assert not any(item.kind == "market_data_missing" for item in result.events)


def test_known_exchange_holiday_never_fills_pending_trade() -> None:
    start = date(2026, 9, 24)
    engine = PaperAccountEngine()
    state = advance(
        engine,
        engine.start("holiday", 10_000, moment(start, 14)),
        start,
        intents=(intent(start, "buy", 0.5),),
    ).state
    holiday = advance(engine, state, date(2026, 9, 25), bars=())
    assert holiday.state.positions == ()
    assert holiday.state.pending
    assert not any(item.kind == "fill" for item in holiday.events)
    next_open = advance(engine, holiday.state, date(2026, 9, 28))
    assert next_open.state.positions[0].shares > 0


def test_replay_is_idempotent_and_conflicting_replay_is_refused() -> None:
    engine = PaperAccountEngine()
    state = engine.start("idempotent", 10_000, moment(FIRST, 14))
    decisions = (intent(FIRST, "single", 0.4),)
    result = advance(engine, state, FIRST, intents=decisions)
    replay = advance(engine, result.state, FIRST, intents=decisions)
    assert replay.state == result.state
    assert replay.events == ()
    with pytest.raises(ValueError, match="already processed"):
        advance(engine, result.state, FIRST, intents=(intent(FIRST, "changed", 0.7),))
    with pytest.raises(ValueError, match="already applied"):
        advance(engine, result.state, FIRST + timedelta(days=1), intents=decisions)


def test_future_bars_and_backdated_intents_are_refused() -> None:
    engine = PaperAccountEngine()
    state = engine.start("time-boundary", 10_000, moment(FIRST, 14))
    with pytest.raises(ValueError, match="before market close"):
        engine.advance(
            state,
            as_of=moment(FIRST, 14, 30),
            bars=(bar(FIRST),),
            market_observed_at=moment(FIRST, 14),
        )
    with pytest.raises(ValueError, match="future"):
        engine.advance(
            state,
            as_of=moment(FIRST),
            bars=(bar(FIRST),),
            market_observed_at=moment(FIRST, 16, 1),
        )
    with pytest.raises(ValueError, match="before it was observed"):
        engine.advance(
            state,
            as_of=moment(FIRST),
            bars=(bar(FIRST),),
            market_observed_at=moment(FIRST, 15, 1),
            intents=(PaperIntent("early", STOCK, 0.5, moment(FIRST, 14, 30)),),
        )
    with pytest.raises(ValueError, match="bar date"):
        engine.advance(
            state,
            as_of=moment(FIRST),
            bars=(bar(FIRST + timedelta(days=1)),),
            market_observed_at=moment(FIRST, 15, 1),
        )


def test_missing_open_day_cancels_old_targets_without_backfilled_trade() -> None:
    engine = PaperAccountEngine()
    state = advance(
        engine,
        engine.start("missed-day", 10_000, moment(FIRST, 14)),
        FIRST,
        intents=(intent(FIRST, "old-buy", 0.8),),
    ).state
    after_gap = advance(engine, state, FIRST + timedelta(days=2))
    assert after_gap.state.positions == ()
    assert after_gap.state.pending == ()
    assert any(item.kind == "missed_day" for item in after_gap.events)
    assert any(item.kind == "pending_cancelled_after_missed_market" for item in after_gap.events)


def test_terminal_value_rejects_missing_latest_price_and_early_finish() -> None:
    engine = PaperAccountEngine()
    state = engine.start("terminal", 10_000, moment(FIRST, 14))
    with pytest.raises(ValueError, match="not reached"):
        engine.terminal_value(state, as_of=moment(FIRST + timedelta(days=1)))
    state = advance(engine, state, FIRST, intents=(intent(FIRST, "buy", 0.4),)).state
    state = advance(engine, state, FIRST + timedelta(days=1)).state
    terminal = engine.terminal_value(state, as_of=state.ends_at)
    assert terminal.net_value is None
    assert terminal.missing_prices == (STOCK.canonical,)


def test_paper_cli_start_step_finish_is_machine_readable(tmp_path) -> None:
    source = tmp_path / "in.json"
    target = tmp_path / "out.json"
    source.write_text(
        json.dumps(
            {
                "experimentId": "cli",
                "initialCash": 1_000,
                "startedAt": moment(FIRST, 14).isoformat(),
            }
        ),
        encoding="utf-8",
    )
    assert main(["paper-start", "--input", str(source), "--output", str(target)]) == 0
    state = json.loads(target.read_text(encoding="utf-8"))["state"]
    source.write_text(
        json.dumps(
            {
                "state": state,
                "asOf": moment(FIRST).isoformat(),
                "marketObservedAt": moment(FIRST, 15, 1).isoformat(),
                "bars": [
                    {
                        "code": STOCK.code,
                        "exchange": STOCK.exchange.value,
                        "date": FIRST.isoformat(),
                        "open": 10,
                        "high": 10,
                        "low": 10,
                        "close": 10,
                        "previousClose": 10,
                        "volume": 1_000_000,
                    }
                ],
                "intents": [intent(FIRST, "cli-buy", 0.5).to_dict()],
            }
        ),
        encoding="utf-8",
    )
    assert main(["paper-step", "--input", str(source), "--output", str(target)]) == 0
    result = json.loads(target.read_text(encoding="utf-8"))
    assert result["state"]["pending"][0]["intentId"] == "cli-buy"
    assert any(item["kind"] == "decision" for item in result["events"])
    source.write_text(
        json.dumps({"state": result["state"], "asOf": result["state"]["endsAt"]}),
        encoding="utf-8",
    )
    assert main(["paper-finish", "--input", str(source), "--output", str(target)]) == 0
    assert json.loads(target.read_text(encoding="utf-8"))["terminal"]["netValue"] == 1_000


def test_official_paper_cli_refuses_other_starting_capital(tmp_path, capsys) -> None:
    source = tmp_path / "in.json"
    target = tmp_path / "out.json"
    source.write_text(
        json.dumps(
            {
                "experimentId": "wrong-cash",
                "initialCash": 10_000,
                "startedAt": moment(FIRST, 14).isoformat(),
            }
        ),
        encoding="utf-8",
    )
    assert main(["paper-start", "--input", str(source), "--output", str(target)]) == 1
    assert not target.exists()
    assert "exactly RMB 1000" in capsys.readouterr().out

    forged_state = PaperAccountEngine.start("forged", 10_000, moment(FIRST, 14)).to_dict()
    source.write_text(
        json.dumps({"state": forged_state, "asOf": moment(FIRST).isoformat()}),
        encoding="utf-8",
    )
    assert main(["paper-step", "--input", str(source), "--output", str(target)]) == 1
    assert "requires RMB 1000" in capsys.readouterr().out
