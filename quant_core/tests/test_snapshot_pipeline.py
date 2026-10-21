import json
from datetime import UTC, date, datetime, timedelta

from syncnote_quant.cli import main
from syncnote_quant.snapshot_pipeline import run_snapshot_pipeline


def _series(code: str, drift: float) -> dict[str, object]:
    bars = []
    previous = 10.0
    for offset in range(130):
        close = 10 + offset * drift
        bars.append(
            {
                "date": (date(2026, 1, 1) + timedelta(days=offset)).isoformat(),
                "open": previous,
                "high": max(previous, close) + 0.1,
                "low": min(previous, close) - 0.1,
                "close": close,
                "previousClose": previous,
                "volume": 1_000_000,
                "amount": 10_000_000 + offset,
            }
        )
        previous = close
    return {
        "code": code,
        "exchange": "SSE",
        "industry": "测试行业",
        "marketCap": 10_000_000_000,
        "bars": bars,
    }


def _payload() -> dict[str, object]:
    return {
        "provider": "公开测试快照",
        "trustTier": "public_validation",
        "generatedAt": datetime(2026, 8, 30, tzinfo=UTC).isoformat(),
        "profile": "medium_trend",
        "topN": 1,
        "maximumWeight": 0.2,
        "series": [_series("600001", 0.02), _series("600002", -0.01)],
    }


def test_snapshot_pipeline_produces_ranked_reproducible_public_report() -> None:
    first = run_snapshot_pipeline(_payload())
    second = run_snapshot_pipeline(_payload())
    assert first == second
    assert first["universeSize"] == 2
    assert first["tradingDays"] == 130
    assert first["latestRanking"][0]["instrument"] == "600001.SSE"
    assert first["qualification"]["qualified_for_plan"] is False


def test_cli_writes_machine_readable_report(tmp_path) -> None:
    input_path = tmp_path / "input.json"
    output_path = tmp_path / "output.json"
    input_path.write_text(json.dumps(_payload()), encoding="utf-8")
    assert (
        main(
            [
                "backtest-snapshot",
                "--input",
                str(input_path),
                "--output",
                str(output_path),
            ]
        )
        == 0
    )
    assert json.loads(output_path.read_text(encoding="utf-8"))["schema_version"] == 1


def test_snapshot_bridge_cannot_self_promote_public_data_to_authorized() -> None:
    payload = _payload()
    payload["trustTier"] = "primary_authorized"
    report = run_snapshot_pipeline(payload)
    assert report["trust_tier"] == "public_personal_research"
    assert report["qualification"]["qualified_for_plan"] is False
