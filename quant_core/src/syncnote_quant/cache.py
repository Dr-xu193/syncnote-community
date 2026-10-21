"""Small, rebuildable local cache. Firestore is never used for raw market history."""

from __future__ import annotations

import json
import sqlite3
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Protocol, Self


@dataclass(frozen=True, slots=True)
class CacheRecord:
    namespace: str
    key: str
    as_of: datetime
    payload: Mapping[str, Any]
    source_hash: str


class CacheBackend(Protocol):
    def put(self, record: CacheRecord) -> None: ...

    def latest(self, namespace: str, key: str) -> CacheRecord | None: ...


class SqliteMarketCache:
    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._connection = sqlite3.connect(self.path)
        self._connection.execute(
            """
            CREATE TABLE IF NOT EXISTS cache_records (
              namespace TEXT NOT NULL,
              cache_key TEXT NOT NULL,
              as_of TEXT NOT NULL,
              payload TEXT NOT NULL,
              source_hash TEXT NOT NULL,
              PRIMARY KEY(namespace, cache_key, as_of)
            )
            """
        )
        self._connection.commit()

    def put(self, record: CacheRecord) -> None:
        if record.as_of.tzinfo is None or record.as_of.utcoffset() is None:
            raise ValueError("cache as_of must be timezone-aware")
        self._connection.execute(
            """INSERT OR REPLACE INTO cache_records
               (namespace, cache_key, as_of, payload, source_hash)
               VALUES (?, ?, ?, ?, ?)""",
            (
                record.namespace,
                record.key,
                record.as_of.astimezone(UTC).isoformat(),
                json.dumps(record.payload, ensure_ascii=False, sort_keys=True),
                record.source_hash,
            ),
        )
        self._connection.commit()

    def latest(self, namespace: str, key: str) -> CacheRecord | None:
        row = self._connection.execute(
            """SELECT as_of, payload, source_hash FROM cache_records
               WHERE namespace = ? AND cache_key = ?
               ORDER BY as_of DESC LIMIT 1""",
            (namespace, key),
        ).fetchone()
        if row is None:
            return None
        return CacheRecord(namespace, key, datetime.fromisoformat(row[0]), json.loads(row[1]), row[2])

    def close(self) -> None:
        self._connection.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
