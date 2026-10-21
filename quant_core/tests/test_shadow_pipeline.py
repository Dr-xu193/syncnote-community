import json
from datetime import date, timedelta

from syncnote_quant.cli import main
from syncnote_quant.shadow_pipeline import run_shadow_snapshot


def _payload() -> dict[str, object]:
    def series(code: str, base: float) -> dict[str, object]:
        bars = []
        previous = base
        for offset in range(4):
            close = base + offset * 0.1
            bars.append(
                {
                    "date": (date(2026, 8, 24) + timedelta(days=offset)).isoformat(),
                    "open": previous,
                    "high": max(previous, close),
                    "low": min(previous, close),
                    "close": close,
                    "previousClose": previous,
                    "volume": 1_000_000,
                }
            )
            previous = close
        return {"code": code, "exchange": "SSE", "bars": bars}

    return {
        "provider": "公开测试源",
        "series": [series("600001", 10), series("600002", 20)],
    }


def test_shadow_snapshot_uses_same_execution_truth_and_no_broker() -> None:
    result = run_shadow_snapshot(_payload())
    assert result["schema_version"] == 1
    assert result["trade_count"] == 2
    assert result["execution_assumptions"]["t_plus_one"] is True
    assert result["execution_assumptions"]["no_broker_connection"] is True
    assert result["source_trust_tier"] == "public_validation"


def test_shadow_cli_is_machine_readable(tmp_path) -> None:
    input_path = tmp_path / "shadow-input.json"
    output_path = tmp_path / "shadow-output.json"
    input_path.write_text(json.dumps(_payload()), encoding="utf-8")
    assert main(["run-shadow", "--input", str(input_path), "--output", str(output_path)]) == 0
    assert json.loads(output_path.read_text(encoding="utf-8"))["trade_count"] == 2
