import json
from datetime import UTC, datetime

from syncnote_quant.cli import main


def _payload() -> dict[str, object]:
    return {
        "asOf": datetime(2026, 8, 31, tzinfo=UTC).isoformat(),
        "equity": 100000,
        "cash": 100000,
        "positions": [],
        "sourceSnapshotHash": "abc",
        "sourceTrustTier": "primary_authorized",
        "stage2Qualified": True,
        "candidates": [
            {
                "code": "600002",
                "exchange": "SSE",
                "price": 10,
                "compositeScore": 2,
                "stopDistance": 0.08,
                "liquidityAmount": 1e8,
            }
        ],
    }


def test_plan_cli_cannot_self_promote_source_to_unlock_plan(tmp_path, monkeypatch) -> None:
    monkeypatch.delenv("TUSHARE_TOKEN", raising=False)
    payload = _payload()
    input_path = tmp_path / "plan-input.json"
    output_path = tmp_path / "plan-output.json"
    input_path.write_text(json.dumps(payload), encoding="utf-8")
    assert main(["build-plan", "--input", str(input_path), "--output", str(output_path)]) == 0
    result = json.loads(output_path.read_text(encoding="utf-8"))
    assert result["ready"] is False
    assert not result["plans"]
    assert any("授权主源" in reason for reason in result["reasons"])


def test_plan_cli_accepts_authorized_source_only_with_local_credential(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("TUSHARE_TOKEN", "local-only-test-credential")
    input_path = tmp_path / "plan-authorized-input.json"
    output_path = tmp_path / "plan-authorized-output.json"
    input_path.write_text(json.dumps(_payload()), encoding="utf-8")
    assert main(["build-plan", "--input", str(input_path), "--output", str(output_path)]) == 0
    result = json.loads(output_path.read_text(encoding="utf-8"))
    assert result["ready"] is True
    assert result["plans"][0]["humanConfirmationRequired"] is True
