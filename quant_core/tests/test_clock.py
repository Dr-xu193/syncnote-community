from datetime import UTC, date, datetime

from syncnote_quant.clock import FixedBeijingMarketClock, MarketPhase


def test_market_phase_is_independent_of_computer_timezone() -> None:
    clock = FixedBeijingMarketClock()
    instant = datetime(2026, 8, 27, 2, 0, tzinfo=UTC)
    assert clock.to_beijing(instant).hour == 10
    assert clock.phase(instant) == MarketPhase.MORNING


def test_holiday_closes_an_otherwise_normal_weekday() -> None:
    clock = FixedBeijingMarketClock()
    instant = datetime(2026, 10, 1, 2, 0, tzinfo=UTC)
    assert clock.phase(instant, holidays={date(2026, 10, 1)}) == MarketPhase.CLOSED


def test_official_2026_calendar_is_the_default() -> None:
    clock = FixedBeijingMarketClock()
    assert clock.phase(datetime(2026, 1, 2, 2, tzinfo=UTC)) == MarketPhase.CLOSED
    assert clock.phase(datetime(2026, 1, 5, 2, tzinfo=UTC)) == MarketPhase.MORNING
