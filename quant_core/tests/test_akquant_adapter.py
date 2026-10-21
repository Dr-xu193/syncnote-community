from datetime import date, timedelta

import pytest

pytest.importorskip("akquant")

from syncnote_quant.akquant_adapter import AKQUANT_VERSION, run_akquant_validation
from syncnote_quant.backtest import AShareBacktester, AShareMarketBar, ExecutionConfig
from syncnote_quant.domain import Exchange, InstrumentId

START = date(2026, 8, 24)
STOCK = InstrumentId("600001", Exchange.SSE)


def _bar(offset: int, price: float = 10.0) -> AShareMarketBar:
    return AShareMarketBar(
        STOCK,
        START + timedelta(days=offset),
        price,
        price,
        price,
        price,
        price,
        1_000_000,
    )


def test_pinned_akquant_contract_matches_golden_next_open_execution() -> None:
    bars = [_bar(0), _bar(1), _bar(2)]
    signals = {START: {STOCK: 0.10}}
    execution = ExecutionConfig(slippage_bps=0, max_volume_participation=1)

    golden = AShareBacktester(execution).run(bars, signals)
    secondary = run_akquant_validation(bars, signals, execution=execution)

    assert secondary.engine_version == AKQUANT_VERSION
    assert len(secondary.executions) == 1
    assert secondary.executions[0].trade_date == golden.trades[0].trade_date
    assert secondary.executions[0].symbol == golden.trades[0].instrument.canonical
    assert secondary.executions[0].side == golden.trades[0].side.value
    assert secondary.executions[0].quantity == golden.trades[0].shares
    assert secondary.executions[0].price == golden.trades[0].price
    assert secondary.executions[0].commission == golden.trades[0].fees

    resolved = secondary.resolved_config
    assert resolved["t_plus_one"] is True
    assert resolved["timezone"] == "Asia/Shanghai"
    assert resolved["fill_policy"] == {
        "price_basis": "open",
        "bar_offset": 1,
        "temporal": "same_cycle",
    }
    assert resolved["commission_policy"]["value"] == execution.commission_rate
    assert resolved["stamp_tax_rate"] == execution.stamp_duty_rate
    assert resolved["transfer_fee_rate"] == execution.transfer_fee_rate
    assert resolved["min_commission"] == execution.minimum_commission
    assert resolved["volume_limit_pct"] == execution.max_volume_participation
