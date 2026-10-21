import pytest

pd = pytest.importorskip("pandas")

from syncnote_quant.domain import Exchange, InstrumentId
from syncnote_quant.tushare_provider import TushareProvider


def test_tushare_token_is_never_optional_without_injected_client(monkeypatch) -> None:
    monkeypatch.delenv("TUSHARE_TOKEN", raising=False)
    with pytest.raises(ValueError, match="TUSHARE_TOKEN"):
        TushareProvider()


def test_injected_client_does_not_require_persisted_token(monkeypatch) -> None:
    monkeypatch.delenv("TUSHARE_TOKEN", raising=False)
    provider = TushareProvider(client=object())
    assert provider.provider_name == "Tushare Pro"


def test_tushare_symbol_suffixes_match_vendor_contract() -> None:
    assert TushareProvider._ts_code(InstrumentId("600001", Exchange.SSE)) == "600001.SH"
    assert TushareProvider._ts_code(InstrumentId("000001", Exchange.SZSE)) == "000001.SZ"
    assert TushareProvider._ts_code(InstrumentId("920001", Exchange.BSE)) == "920001.BJ"


def test_stock_basic_keeps_historical_delisted_membership(monkeypatch) -> None:
    monkeypatch.delenv("TUSHARE_TOKEN", raising=False)

    class Client:
        @staticmethod
        def stock_basic(**kwargs):
            if kwargs["list_status"] == "L":
                return pd.DataFrame(
                    [
                        {
                            "ts_code": "600001.SH",
                            "name": "存续样本",
                            "industry": "测试",
                            "list_date": "20200101",
                            "delist_date": "",
                        }
                    ]
                )
            if kwargs["list_status"] == "D":
                return pd.DataFrame(
                    [
                        {
                            "ts_code": "920001.BJ",
                            "name": "退市样本",
                            "industry": "测试",
                            "list_date": "20210101",
                            "delist_date": "20250630",
                        }
                    ]
                )
            return pd.DataFrame()

    rows = TushareProvider(client=Client()).instruments()
    assert [item.instrument.canonical for item in rows] == ["600001.SSE", "920001.BSE"]
    assert rows[1].delist_date.isoformat() == "2025-06-30"
