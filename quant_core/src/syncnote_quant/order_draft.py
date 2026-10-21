"""Brokerage-neutral order drafts with explicit human confirmation gates.

This module deliberately stops before any broker API.  It turns an already
qualified research plan into an auditable draft and makes confirmation,
expiry, cancellation and the emergency stop deterministic operations.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime, timedelta
from hashlib import sha256
from math import isfinite
from typing import Literal

OrderSide = Literal["buy", "sell"]
DraftStatus = Literal["pending_confirmation", "confirmed", "cancelled", "expired"]


def _aware(value: datetime, label: str) -> None:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError(f"{label} must be timezone-aware")


@dataclass(frozen=True, slots=True)
class OrderDraft:
    draft_id: str
    idempotency_key: str
    plan_id: str
    instrument: str
    side: OrderSide
    quantity: int
    limit_price: float
    tranche: int
    created_at: datetime
    expires_at: datetime
    source_snapshot_hash: str
    status: DraftStatus = "pending_confirmation"
    human_confirmation_required: bool = True
    broker_submission_allowed: bool = False

    def __post_init__(self) -> None:
        if not self.draft_id or not self.plan_id or not self.instrument:
            raise ValueError("draft identity is required")
        if not self.idempotency_key:
            raise ValueError("idempotency_key is required")
        if self.side not in ("buy", "sell"):
            raise ValueError("side must be buy or sell")
        if self.quantity <= 0 or self.quantity % 100 != 0:
            raise ValueError("quantity must be a positive 100-share lot")
        if not isfinite(self.limit_price) or self.limit_price <= 0:
            raise ValueError("limit_price must be finite and positive")
        if self.tranche <= 0:
            raise ValueError("tranche must be positive")
        _aware(self.created_at, "created_at")
        _aware(self.expires_at, "expires_at")
        if self.expires_at <= self.created_at:
            raise ValueError("expires_at must be after created_at")
        if len(self.source_snapshot_hash) > 256:
            raise ValueError("source_snapshot_hash is too long")
        if self.status != "pending_confirmation" and self.broker_submission_allowed:
            raise ValueError("broker submission is permanently disabled")
        if self.broker_submission_allowed:
            raise ValueError("broker submission is permanently disabled")

    @property
    def notional(self) -> float:
        return self.quantity * self.limit_price


@dataclass(frozen=True, slots=True)
class OrderDraftBatch:
    batch_id: str
    created_at: datetime
    expires_at: datetime
    source_snapshot_hash: str
    drafts: tuple[OrderDraft, ...]
    status: Literal["pending_confirmation", "confirmed", "cancelled", "expired"] = (
        "pending_confirmation"
    )
    emergency_stop: bool = False

    def __post_init__(self) -> None:
        if not self.batch_id or not self.drafts:
            raise ValueError("batch must contain at least one draft")
        _aware(self.created_at, "created_at")
        _aware(self.expires_at, "expires_at")
        if self.expires_at <= self.created_at:
            raise ValueError("batch expires_at must be after created_at")
        if self.emergency_stop and self.status == "confirmed":
            raise ValueError("emergency stop cannot coexist with confirmed status")
        if len({item.idempotency_key for item in self.drafts}) != len(self.drafts):
            raise ValueError("duplicate idempotency key")

    @property
    def total_notional(self) -> float:
        return sum(item.notional for item in self.drafts)


def idempotency_key(
    *, plan_id: str, tranche: int, instrument: str, quantity: int, limit_price: float, source_snapshot_hash: str
) -> str:
    """Return a stable key so retries cannot create a second draft."""

    raw = "|".join(
        (
            plan_id,
            str(tranche),
            instrument,
            str(quantity),
            f"{limit_price:.8f}",
            source_snapshot_hash,
        )
    )
    return sha256(raw.encode("utf-8")).hexdigest()


def build_order_draft_batch(
    plan_payload: dict[str, object],
    *,
    now: datetime,
    batch_id: str,
    max_notional: float = 100_000.0,
    validity_hours: int = 24,
) -> OrderDraftBatch:
    """Convert a qualified plan JSON into non-submittable drafts.

    The payload is treated as untrusted UI data: it must explicitly say ready,
    carry a source hash, and contain finite positive prices and lot quantities.
    """

    _aware(now, "now")
    if validity_hours <= 0 or max_notional <= 0 or not isfinite(max_notional):
        raise ValueError("draft limits are invalid")
    if plan_payload.get("ready") is not True:
        raise ValueError("only a qualified plan can create order drafts")
    source_hash = str(plan_payload.get("sourceSnapshotHash") or "")
    if not source_hash:
        raise ValueError("source snapshot hash is required")
    raw_plans = plan_payload.get("plans")
    if not isinstance(raw_plans, list) or not raw_plans:
        raise ValueError("qualified plan has no orderable tranches")
    drafts: list[OrderDraft] = []
    expires = now + timedelta(hours=validity_hours)
    for raw_plan in raw_plans:
        if not isinstance(raw_plan, dict):
            raise TypeError("plan entry must be an object")
        plan_id = str(raw_plan.get("planId") or "")
        candidate = raw_plan.get("candidate")
        if not plan_id or not isinstance(candidate, dict):
            raise ValueError("plan candidate is incomplete")
        instrument = str(candidate.get("instrument") or "")
        price = float(candidate.get("price") or 0)
        if not instrument or not isfinite(price) or price <= 0:
            raise ValueError("plan candidate price is invalid")
        for raw_tranche in raw_plan.get("tranches", []):
            if not isinstance(raw_tranche, dict):
                raise TypeError("tranche must be an object")
            tranche = int(raw_tranche.get("tranche") or 0)
            quantity = int(raw_tranche.get("targetShares") or 0)
            if quantity <= 0:
                continue
            item_key = idempotency_key(
                plan_id=plan_id,
                tranche=tranche,
                instrument=instrument,
                quantity=quantity,
                limit_price=price,
                source_snapshot_hash=source_hash,
            )
            draft = OrderDraft(
                draft_id=f"{batch_id}-{item_key[:12]}",
                idempotency_key=item_key,
                plan_id=plan_id,
                instrument=instrument,
                side="buy",
                quantity=quantity,
                limit_price=price,
                tranche=tranche,
                created_at=now,
                expires_at=expires,
                source_snapshot_hash=source_hash,
            )
            if draft.notional > max_notional + 1e-9:
                raise ValueError("draft exceeds per-order notional limit")
            drafts.append(draft)
    if not drafts:
        raise ValueError("plan contains no positive-lot tranche")
    return OrderDraftBatch(
        batch_id=batch_id,
        created_at=now,
        expires_at=expires,
        source_snapshot_hash=source_hash,
        drafts=tuple(drafts),
    )


def confirm_batch(
    batch: OrderDraftBatch,
    *,
    now: datetime,
    confirmation_phrase: str,
    emergency_stop: bool = False,
) -> OrderDraftBatch:
    """Mark a draft as confirmed, never submit it to a broker."""

    _aware(now, "now")
    if confirmation_phrase.strip() != "确认草稿":
        raise ValueError("必须输入‘确认草稿’才可确认")
    if batch.status != "pending_confirmation":
        return batch
    if emergency_stop or batch.emergency_stop:
        return cancel_batch(batch, now=now, emergency_stop=True)
    if now >= batch.expires_at:
        return expire_batch(batch, now=now)
    confirmed = tuple(replace(item, status="confirmed") for item in batch.drafts)
    return OrderDraftBatch(
        batch_id=batch.batch_id,
        created_at=batch.created_at,
        expires_at=batch.expires_at,
        source_snapshot_hash=batch.source_snapshot_hash,
        drafts=confirmed,
        status="confirmed",
    )


def cancel_batch(
    batch: OrderDraftBatch, *, now: datetime, emergency_stop: bool = False
) -> OrderDraftBatch:
    _aware(now, "now")
    if batch.status != "pending_confirmation":
        return batch
    cancelled = tuple(replace(item, status="cancelled") for item in batch.drafts)
    return OrderDraftBatch(
        batch_id=batch.batch_id,
        created_at=batch.created_at,
        expires_at=batch.expires_at,
        source_snapshot_hash=batch.source_snapshot_hash,
        drafts=cancelled,
        status="cancelled",
        emergency_stop=emergency_stop,
    )


def expire_batch(batch: OrderDraftBatch, *, now: datetime) -> OrderDraftBatch:
    _aware(now, "now")
    if batch.status != "pending_confirmation":
        return batch
    expired = tuple(replace(item, status="expired") for item in batch.drafts)
    return OrderDraftBatch(
        batch_id=batch.batch_id,
        created_at=batch.created_at,
        expires_at=batch.expires_at,
        source_snapshot_hash=batch.source_snapshot_hash,
        drafts=expired,
        status="expired",
    )


def order_batch_to_dict(batch: OrderDraftBatch) -> dict[str, object]:
    return {
        "batchId": batch.batch_id,
        "createdAt": batch.created_at.isoformat(),
        "expiresAt": batch.expires_at.isoformat(),
        "sourceSnapshotHash": batch.source_snapshot_hash,
        "status": batch.status,
        "emergencyStop": batch.emergency_stop,
        "brokerSubmissionAllowed": False,
        "drafts": [
            {
                "draftId": item.draft_id,
                "idempotencyKey": item.idempotency_key,
                "planId": item.plan_id,
                "instrument": item.instrument,
                "side": item.side,
                "quantity": item.quantity,
                "limitPrice": item.limit_price,
                "tranche": item.tranche,
                "createdAt": item.created_at.isoformat(),
                "expiresAt": item.expires_at.isoformat(),
                "sourceSnapshotHash": item.source_snapshot_hash,
                "status": item.status,
                "humanConfirmationRequired": item.human_confirmation_required,
                "brokerSubmissionAllowed": False,
            }
            for item in batch.drafts
        ],
    }
