from datetime import UTC, date, datetime, timedelta

from syncnote_quant.domain import (
    Bar,
    BarInterval,
    Exchange,
    FinancialPointInTime,
    FinancialStatement,
    InstrumentId,
    QualityCode,
    Quote,
    SourceEvidence,
)
from syncnote_quant.quality import DataQualityValidator

NOW = datetime(2026, 8, 27, 7, 0, tzinfo=UTC)
INSTRUMENT = InstrumentId("600519", Exchange.SSE)


def evidence(provider: str, observed: datetime = NOW) -> SourceEvidence:
    return SourceEvidence(provider, "quote", observed, NOW)


def quote(provider: str = "primary", price: float = 100.0) -> Quote:
    return Quote(
        INSTRUMENT,
        "测试股票",
        price,
        99.0,
        99.5,
        max(101.0, price),
        98.5,
        1000,
        100000,
        1.2,
        evidence(provider),
    )


def test_valid_quote_is_actionable() -> None:
    report = DataQualityValidator().quote(quote(), checked_at=NOW)
    assert report.is_actionable


def test_stale_and_cross_source_conflict_block_research() -> None:
    stale = Quote(
        INSTRUMENT,
        "测试股票",
        100,
        99,
        99.5,
        101,
        98.5,
        1000,
        100000,
        1.2,
        evidence("primary", NOW - timedelta(hours=2)),
    )
    reference = quote("secondary", 103)
    report = DataQualityValidator().quote(
        stale, references=[reference], checked_at=NOW
    )
    assert not report.is_actionable
    assert {item.code for item in report.issues} >= {
        QualityCode.STALE,
        QualityCode.SOURCE_CONFLICT,
    }


def test_duplicate_or_invalid_bars_are_rejected() -> None:
    timestamp = NOW - timedelta(days=1)
    values = [
        Bar(INSTRUMENT, BarInterval.DAY, timestamp, 10, 11, 9, 10.5, 10, 100, evidence("p", timestamp)),
        Bar(INSTRUMENT, BarInterval.DAY, timestamp, 10, 9, 11, 10, 10, 100, evidence("p", timestamp)),
    ]
    report = DataQualityValidator().bars(values, checked_at=NOW)
    assert not report.is_actionable
    assert {item.code for item in report.issues} >= {
        QualityCode.DUPLICATE,
        QualityCode.INVALID_OHLC,
    }


def test_point_in_time_financial_data_cannot_leak_future_publication() -> None:
    published = NOW + timedelta(days=2)
    value = FinancialPointInTime(
        INSTRUMENT,
        FinancialStatement.INDICATOR,
        date(2026, 6, 30),
        published,
        published,
        {"roe": 12.0},
        evidence("fundamental", published),
    )
    report = DataQualityValidator().financials([value], as_of=NOW)
    assert not report.is_actionable
    assert report.issues[0].code == QualityCode.POINT_IN_TIME_VIOLATION
