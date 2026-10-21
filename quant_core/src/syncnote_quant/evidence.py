"""Evidence bundles and deterministic numeric checks for AI research."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime
from math import isfinite

from .domain import require_aware


@dataclass(frozen=True, slots=True)
class EvidenceRecord:
    evidence_id: str
    kind: str
    source: str
    observed_at: datetime
    fields: Mapping[str, float | int | str | None]
    content_hash: str

    def __post_init__(self) -> None:
        require_aware(self.observed_at, "evidence observed_at")


@dataclass(frozen=True, slots=True)
class EvidenceClaim:
    claim_id: str
    statement: str
    evidence_ids: tuple[str, ...]
    numeric_fields: Mapping[str, float]


@dataclass(frozen=True, slots=True)
class EvidenceCheck:
    passed: bool
    issues: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class EvidenceBundle:
    bundle_id: str
    snapshot_hash: str
    created_at: datetime
    records: tuple[EvidenceRecord, ...]
    claims: tuple[EvidenceClaim, ...]

    def __post_init__(self) -> None:
        require_aware(self.created_at, "evidence bundle created_at")


def make_evidence_record(
    *,
    evidence_id: str,
    kind: str,
    source: str,
    observed_at: datetime,
    fields: Mapping[str, float | int | str | None],
) -> EvidenceRecord:
    content = json.dumps(dict(fields), ensure_ascii=True, sort_keys=True, separators=(",", ":"))
    return EvidenceRecord(
        evidence_id,
        kind,
        source,
        observed_at,
        dict(fields),
        hashlib.sha256(content.encode("utf-8")).hexdigest(),
    )


def verify_claim(
    claim: EvidenceClaim,
    records: Sequence[EvidenceRecord],
    *,
    tolerance: float = 1e-9,
) -> EvidenceCheck:
    by_id = {item.evidence_id: item for item in records}
    issues: list[str] = []
    selected = [by_id[item] for item in claim.evidence_ids if item in by_id]
    if len(selected) != len(claim.evidence_ids):
        issues.append("claim 引用了不存在的证据")
    for field, expected in claim.numeric_fields.items():
        matches = [record.fields[field] for record in selected if field in record.fields]
        if not matches:
            issues.append(f"证据未提供数值字段：{field}")
            continue
        if any(not isinstance(value, (int, float)) or not isfinite(float(value)) for value in matches):
            issues.append(f"证据数值非法：{field}")
            continue
        if not any(abs(float(value) - expected) <= tolerance for value in matches):
            issues.append(f"AI/声明数值与证据不一致：{field}")
    return EvidenceCheck(not issues, tuple(issues))


def verify_bundle(bundle: EvidenceBundle) -> EvidenceCheck:
    issues: list[str] = []
    for record in bundle.records:
        rebuilt = make_evidence_record(
            evidence_id=record.evidence_id,
            kind=record.kind,
            source=record.source,
            observed_at=record.observed_at,
            fields=record.fields,
        )
        if rebuilt.content_hash != record.content_hash:
            issues.append(f"证据哈希不一致：{record.evidence_id}")
    for claim in bundle.claims:
        check = verify_claim(claim, bundle.records)
        issues.extend(check.issues)
    return EvidenceCheck(not issues, tuple(issues))
