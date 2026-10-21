"""Command-line bridge for the Windows application."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date, datetime
from pathlib import Path
from typing import Any

from .akquant_adapter import require_akquant_version
from .backtest import AShareMarketBar
from .domain import Exchange, InstrumentId
from .order_draft import build_order_draft_batch, order_batch_to_dict
from .paper_account import (
    FIRST_EXPERIMENT_CASH,
    PaperAccountEngine,
    PaperAccountState,
    PaperIntent,
)
from .portfolio_plan import (
    AccountSnapshot,
    CandidateAsset,
    PositionSnapshot,
    build_buy_plans,
    plan_decision_to_dict,
)
from .shadow_pipeline import run_shadow_snapshot
from .snapshot_pipeline import run_snapshot_pipeline


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="syncnote-quant")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("doctor")
    backtest = subparsers.add_parser("backtest-snapshot")
    backtest.add_argument("--input", required=True)
    backtest.add_argument("--output", required=True)
    plan = subparsers.add_parser("build-plan")
    plan.add_argument("--input", required=True)
    plan.add_argument("--output", required=True)
    shadow = subparsers.add_parser("run-shadow")
    shadow.add_argument("--input", required=True)
    shadow.add_argument("--output", required=True)
    for name in ("paper-start", "paper-step", "paper-finish"):
        command = subparsers.add_parser(name)
        command.add_argument("--input", required=True)
        command.add_argument("--output", required=True)
    order_drafts = subparsers.add_parser("build-order-drafts")
    order_drafts.add_argument("--input", required=True)
    order_drafts.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "doctor":
            _write_stdout(
                {
                    "ok": True,
                    "akquantVersion": require_akquant_version(),
                    "python": sys.version.split()[0],
                }
            )
            return 0
        payload = json.loads(Path(args.input).read_text(encoding="utf-8"))
        if args.command == "backtest-snapshot":
            result = run_snapshot_pipeline(payload)
        elif args.command == "run-shadow":
            result = run_shadow_snapshot(payload)
        elif args.command == "paper-start":
            result = _paper_start(payload)
        elif args.command == "paper-step":
            result = _paper_step(payload)
        elif args.command == "paper-finish":
            result = _paper_finish(payload)
        elif args.command == "build-order-drafts":
            result = _build_order_drafts(payload)
        else:
            result = _build_plan(payload)
        Path(args.output).write_text(
            json.dumps(result, ensure_ascii=False, sort_keys=True, allow_nan=False),
            encoding="utf-8",
        )
        _write_stdout({"ok": True, "output": str(Path(args.output).resolve())})
        return 0
    except Exception as error:  # noqa: BLE001 - CLI boundary must return JSON errors
        _write_stdout({"ok": False, "error": str(error), "type": type(error).__name__})
        return 1


def _write_stdout(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")


def _build_plan(payload: dict[str, Any]) -> dict[str, Any]:
    account = AccountSnapshot(
        datetime.fromisoformat(str(payload["asOf"])),
        float(payload["equity"]),
        float(payload["cash"]),
        tuple(
            PositionSnapshot(
                InstrumentId(str(item["code"]), Exchange(str(item["exchange"]))),
                int(item["shares"]),
                int(item.get("sellableShares", item["shares"])),
                float(item.get("averageCost", 0)),
                float(item["lastPrice"]),
                str(item.get("industry") or "未分类"),
                float(item.get("annualVolatility", 0.30)),
            )
            for item in payload.get("positions", [])
        ),
    )
    candidates = tuple(
        CandidateAsset(
            InstrumentId(str(item["code"]), Exchange(str(item["exchange"]))),
            float(item["price"]),
            str(item.get("industry") or "未分类"),
            float(item["compositeScore"]),
            float(item["stopDistance"]),
            float(item.get("liquidityAmount", 0)),
            str(item.get("correlationCluster") or ""),
            str(item.get("entryCondition") or "下一交易日开盘不高于观察价，且质量门禁仍通过"),
            float(item.get("annualVolatility", 0.30)),
            {
                _instrument_from_canonical(str(key)): float(value)
                for key, value in item.get("correlations", {}).items()
            },
        )
        for item in payload.get("candidates", [])
    )
    requested_trust = str(payload.get("sourceTrustTier") or "public_validation")
    source_trust = (
        "primary_authorized"
        if requested_trust == "primary_authorized" and os.environ.get("TUSHARE_TOKEN", "").strip()
        else "public_personal_research"
        if requested_trust == "public_personal_research"
        else "public_validation"
    )
    decision = build_buy_plans(
        account,
        candidates,
        source_snapshot_hash=str(payload.get("sourceSnapshotHash") or ""),
        # A plan may use an authorized label only when the local process also
        # holds the provider credential outside the payload. The credential
        # value is never read into a report or sent onward.
        source_trust_tier=source_trust,
        stage2_qualified=bool(payload.get("stage2Qualified", False)),
    )
    output = plan_decision_to_dict(decision)
    output["researchOnly"] = source_trust != "primary_authorized"
    output["sourceTrustTier"] = source_trust
    return output


def _instrument_from_canonical(value: str) -> InstrumentId:
    code, exchange = value.split(".", 1)
    return InstrumentId(code, Exchange(exchange))


def _paper_start(payload: dict[str, Any]) -> dict[str, Any]:
    initial_cash = float(payload.get("initialCash", FIRST_EXPERIMENT_CASH))
    if initial_cash != FIRST_EXPERIMENT_CASH:
        raise ValueError("the first 30-day AI paper experiment starts with exactly RMB 1000")
    state = PaperAccountEngine.start(
        str(payload["experimentId"]),
        initial_cash,
        datetime.fromisoformat(str(payload["startedAt"])),
    )
    return {"state": state.to_dict()}


def _paper_step(payload: dict[str, Any]) -> dict[str, Any]:
    state = PaperAccountState.from_dict(payload["state"])
    if state.initial_cash != FIRST_EXPERIMENT_CASH:
        raise ValueError("the first 30-day AI paper experiment requires RMB 1000")
    result = PaperAccountEngine().advance(
        state,
        as_of=datetime.fromisoformat(str(payload["asOf"])),
        market_observed_at=(
            datetime.fromisoformat(str(payload["marketObservedAt"]))
            if payload.get("marketObservedAt")
            else None
        ),
        bars=tuple(_paper_bar_from_dict(item) for item in payload.get("bars", [])),
        intents=tuple(PaperIntent.from_dict(item) for item in payload.get("intents", [])),
    )
    return {
        "state": result.state.to_dict(),
        "events": [item.to_dict() for item in result.events],
    }


def _paper_finish(payload: dict[str, Any]) -> dict[str, Any]:
    state = PaperAccountState.from_dict(payload["state"])
    if state.initial_cash != FIRST_EXPERIMENT_CASH:
        raise ValueError("the first 30-day AI paper experiment requires RMB 1000")
    result = PaperAccountEngine().terminal_value(
        state,
        as_of=datetime.fromisoformat(str(payload["asOf"])),
    )
    return {"terminal": result.to_dict()}


def _paper_bar_from_dict(value: dict[str, Any]) -> AShareMarketBar:
    return AShareMarketBar(
        instrument=InstrumentId(str(value["code"]), Exchange(str(value["exchange"]))),
        trade_date=date.fromisoformat(str(value["date"])),
        open=float(value["open"]),
        high=float(value["high"]),
        low=float(value["low"]),
        close=float(value["close"]),
        previous_close=float(value["previousClose"]),
        volume=float(value["volume"]),
        suspended=bool(value.get("suspended", False)),
        is_st=bool(value.get("isSt", False)),
        listing_days=int(value.get("listingDays", 9999)),
        unlimited=bool(value.get("unlimited", False)),
        delisting_final_day=bool(value.get("delistingFinalDay", False)),
    )


def _build_order_drafts(payload: dict[str, Any]) -> dict[str, Any]:
    now = datetime.fromisoformat(str(payload["now"]))
    batch_id = str(payload["batchId"])
    batch = build_order_draft_batch(
        payload,
        now=now,
        batch_id=batch_id,
        max_notional=float(payload.get("maxNotional", 100_000)),
        validity_hours=int(payload.get("validityHours", 24)),
    )
    return order_batch_to_dict(batch)


if __name__ == "__main__":
    raise SystemExit(main())
