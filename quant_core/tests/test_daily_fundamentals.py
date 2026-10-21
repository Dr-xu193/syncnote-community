from datetime import UTC, date, datetime, timedelta

import pytest

pd = pytest.importorskip("pandas")

from syncnote_quant.domain import DailyFundamental, Exchange, InstrumentId, SourceEvidence
from syncnote_quant.factors import latest_daily_fundamental_as_of
from syncnote_quant.tushare_provider import TushareProvider


def test_tushare_daily_basic_keeps_historical_valuation_point_in_time() -> None:
    class Client:
        @staticmethod
        def daily_basic(**kwargs):
            assert kwargs["fields"].endswith("total_mv")
            return pd.DataFrame(
                [
                    {
                        "ts_code": "600001.SH",
                        "trade_date": "20260828",
                        "turnover_rate": 1.5,
                        "pe_ttm": 12.0,
                        "pb": 1.2,
                        "total_mv": 123456.0,
                    }
                ]
            )

    rows = TushareProvider(client=Client()).daily_fundamentals(
        InstrumentId("600001", Exchange.SSE),
        date(2026, 8, 1),
        date(2026, 8, 30),
    )
    assert rows[0].market_cap == 1_234_560_000
    assert rows[0].available_at.hour == 18
    assert rows[0].pe_ttm == 12


def test_future_daily_valuation_is_not_visible() -> None:
    now = datetime(2026, 8, 30, tzinfo=UTC)
    instrument = InstrumentId("600001", Exchange.SSE)
    evidence = SourceEvidence("test", "daily_basic", now, now)
    old = DailyFundamental(
        instrument, date(2026, 8, 28), now - timedelta(days=2), 100, 10, 1, 2, evidence
    )
    future = DailyFundamental(
        instrument, date(2026, 8, 31), now + timedelta(days=1), 999, 99, 9, 9, evidence
    )
    assert latest_daily_fundamental_as_of([old, future], now) == old
