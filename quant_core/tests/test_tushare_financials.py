from datetime import date

import pytest

pd = pytest.importorskip("pandas")

from syncnote_quant.domain import Exchange, InstrumentId
from syncnote_quant.tushare_provider import TushareProvider


def test_tushare_financial_uses_actual_disclosure_time_and_revision() -> None:
    class Client:
        @staticmethod
        def fina_indicator(**kwargs):
            return pd.DataFrame(
                [
                    {
                        "ts_code": kwargs["ts_code"],
                        "ann_date": "20260820",
                        "f_ann_date": "20260822",
                        "end_date": "20260630",
                        "update_flag": "1",
                        "roe": 12.5,
                    }
                ]
            )

    row = TushareProvider(client=Client()).financials(
        InstrumentId("600001", Exchange.SSE),
        date(2026, 1, 1),
        date(2026, 8, 30),
    )[0]
    assert row.published_at.date().isoformat() == "2026-08-20"
    assert row.available_at.date().isoformat() == "2026-08-22"
    assert row.revision == "20260822:1"
