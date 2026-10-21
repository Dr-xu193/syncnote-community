from datetime import UTC, datetime, timedelta

from syncnote_quant.domain import Announcement, Exchange, InstrumentId, SourceEvidence
from syncnote_quant.event_factors import EventKind, event_factor_as_of

NOW = datetime(2026, 8, 30, 15, tzinfo=UTC)
STOCK = InstrumentId("600001", Exchange.SSE)
EVIDENCE = SourceEvidence("test", "announcements", NOW, NOW)


def _announcement(kind: str, available_at: datetime) -> Announcement:
    return Announcement(
        STOCK,
        kind,
        available_at,
        available_at,
        kind,
        "https://example.invalid/evidence",
        EVIDENCE,
    )


def test_event_factor_is_point_in_time_and_explains_unknown_categories() -> None:
    result = event_factor_as_of(
        [
            _announcement(EventKind.BUYBACK.value, NOW - timedelta(days=1)),
            _announcement("provider_unmapped", NOW - timedelta(days=2)),
            _announcement(EventKind.INVESTIGATION.value, NOW + timedelta(days=1)),
        ],
        as_of=NOW,
    )
    assert result.score == 0.5
    assert len(result.used_events) == 1
    assert result.ignored_unknown_categories == ("provider_unmapped",)
