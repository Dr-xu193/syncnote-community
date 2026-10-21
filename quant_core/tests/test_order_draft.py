from datetime import UTC, datetime, timedelta

import pytest

from syncnote_quant import (
    build_order_draft_batch,
    cancel_batch,
    confirm_batch,
    expire_batch,
    order_batch_to_dict,
)

NOW = datetime(2026, 8, 31, 9, 0, tzinfo=UTC)


def _payload(*, ready=True):
    return {
        "ready": ready,
        "sourceSnapshotHash": "snapshot-abc",
        "plans": [
            {
                "planId": "plan-600519",
                "candidate": {"instrument": "600519.SSE", "price": 100.0},
                "tranches": [
                    {"tranche": 1, "targetShares": 100},
                    {"tranche": 2, "targetShares": 200},
                    {"tranche": 3, "targetShares": 0},
                ],
            }
        ],
    }


def test_qualified_plan_creates_lot_sized_non_submittable_drafts():
    batch = build_order_draft_batch(_payload(), now=NOW, batch_id="batch-1")

    assert batch.status == "pending_confirmation"
    assert len(batch.drafts) == 2
    assert len({item.idempotency_key for item in batch.drafts}) == 2
    assert all(item.quantity % 100 == 0 for item in batch.drafts)
    assert all(not item.broker_submission_allowed for item in batch.drafts)
    assert order_batch_to_dict(batch)["brokerSubmissionAllowed"] is False


def test_unqualified_or_untrusted_plan_is_blocked():
    with pytest.raises(ValueError, match="qualified"):
        build_order_draft_batch(_payload(ready=False), now=NOW, batch_id="batch-2")
    payload = _payload()
    payload["sourceSnapshotHash"] = ""
    with pytest.raises(ValueError, match="snapshot hash"):
        build_order_draft_batch(payload, now=NOW, batch_id="batch-3")


def test_confirmation_requires_exact_phrase_and_never_submits():
    batch = build_order_draft_batch(_payload(), now=NOW, batch_id="batch-4")
    with pytest.raises(ValueError, match="确认草稿"):
        confirm_batch(batch, now=NOW, confirmation_phrase="确认")

    confirmed = confirm_batch(batch, now=NOW, confirmation_phrase="确认草稿")
    assert confirmed.status == "confirmed"
    assert all(item.status == "confirmed" for item in confirmed.drafts)
    assert all(not item.broker_submission_allowed for item in confirmed.drafts)
    assert (
        confirm_batch(confirmed, now=NOW, confirmation_phrase="确认草稿").status
        == "confirmed"
    )
    assert cancel_batch(confirmed, now=NOW).status == "confirmed"


def test_expiry_and_emergency_stop_are_terminal():
    batch = build_order_draft_batch(_payload(), now=NOW, batch_id="batch-5")
    expired = confirm_batch(
        batch,
        now=NOW + timedelta(hours=25),
        confirmation_phrase="确认草稿",
    )
    assert expired.status == "expired"
    assert all(item.status == "expired" for item in expired.drafts)

    stopped = confirm_batch(
        batch,
        now=NOW,
        confirmation_phrase="确认草稿",
        emergency_stop=True,
    )
    assert stopped.status == "cancelled"
    assert stopped.emergency_stop is True
    assert all(item.status == "cancelled" for item in stopped.drafts)

    cancelled = cancel_batch(batch, now=NOW)
    assert cancelled.status == "cancelled"
    assert all(item.status == "cancelled" for item in cancelled.drafts)


def test_invalid_lot_or_notional_is_rejected():
    payload = _payload()
    payload["plans"][0]["tranches"][0]["targetShares"] = 50
    with pytest.raises(ValueError, match="100-share lot"):
        build_order_draft_batch(payload, now=NOW, batch_id="batch-6")

    with pytest.raises(ValueError, match="per-order notional"):
        build_order_draft_batch(
            _payload(), now=NOW, batch_id="batch-7", max_notional=1
        )


def test_expire_helper_requires_timezone_aware_time():
    batch = build_order_draft_batch(_payload(), now=NOW, batch_id="batch-8")
    with pytest.raises(ValueError, match="timezone-aware"):
        expire_batch(batch, now=datetime.fromisoformat("2026-08-31T09:00:00"))
