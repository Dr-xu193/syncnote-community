from datetime import UTC, datetime

import pytest

from syncnote_quant.calibration import (
    ErrorClass,
    PredictionOutcome,
    attribute_review_error,
    calibration_report,
)
from syncnote_quant.evidence import (
    EvidenceBundle,
    EvidenceClaim,
    make_evidence_record,
    verify_bundle,
)

NOW = datetime(2026, 8, 31, 15, tzinfo=UTC)


def test_evidence_hash_and_numeric_claim_are_verified() -> None:
    record = make_evidence_record(
        evidence_id="quote-1",
        kind="quote",
        source="primary",
        observed_at=NOW,
        fields={"price": 10.0, "change_percent": 2.0},
    )
    bundle = EvidenceBundle(
        "bundle-1",
        "snapshot",
        NOW,
        (record,),
        (EvidenceClaim("claim-1", "price", ("quote-1",), {"price": 10.0}),),
    )
    assert verify_bundle(bundle).passed is True


def test_calibration_brier_and_error_priority_are_deterministic() -> None:
    report = calibration_report(
        [
            PredictionOutcome("1", 0.8, True),
            PredictionOutcome("2", 0.2, False),
        ]
    )
    assert report.brier_score == pytest.approx(0.04)
    assert sum(item.count for item in report.bins) == 2
    assert attribute_review_error(
        data_was_correct=False,
        strategy_rule_was_valid=False,
        execution_was_feasible=False,
        user_followed_plan=False,
    ) == ErrorClass.DATA
