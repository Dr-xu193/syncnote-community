from datetime import UTC, datetime, timedelta

from syncnote_quant.cache import CacheRecord, SqliteMarketCache


def test_sqlite_cache_is_rebuildable_and_returns_latest(tmp_path) -> None:
    path = tmp_path / "market.sqlite3"
    now = datetime(2026, 8, 27, tzinfo=UTC)
    with SqliteMarketCache(path) as cache:
        cache.put(CacheRecord("quote", "600519.SSE", now, {"price": 100}, "a"))
        cache.put(
            CacheRecord(
                "quote", "600519.SSE", now + timedelta(minutes=1), {"price": 101}, "b"
            )
        )
        latest = cache.latest("quote", "600519.SSE")
        assert latest is not None
        assert latest.payload["price"] == 101
        assert latest.source_hash == "b"
