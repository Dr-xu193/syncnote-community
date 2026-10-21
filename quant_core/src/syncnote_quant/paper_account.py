"""One persistent, point-in-time daily paper account for a 30-day experiment.

The account receives decisions after a day's observations and can fill them
only at a later trading day's open. It does not choose securities or strategies.
The caller must persist each decision before passing it to ``advance``.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Collection, Mapping, Sequence
from dataclasses import asdict, dataclass
from datetime import date, datetime, time, timedelta
from math import isfinite
from typing import Any

from .backtest import (
    AShareBacktester,
    AShareMarketBar,
    ExecutionConfig,
    OrderSide,
    Position,
    RejectedOrder,
    RejectReason,
    Trade,
    _PendingTarget,
)
from .clock import BEIJING_TZ, MAINLAND_HOLIDAYS_2026
from .domain import Exchange, InstrumentId, require_aware

FIRST_EXPERIMENT_CASH = 1000.0


def _instrument_to_dict(value: InstrumentId) -> dict[str, str]:
    return {"code": value.code, "exchange": value.exchange.value}


def _instrument_from_dict(value: Mapping[str, Any]) -> InstrumentId:
    return InstrumentId(str(value["code"]), Exchange(str(value["exchange"])))


@dataclass(frozen=True, slots=True)
class PaperPosition:
    instrument: InstrumentId
    shares: int
    sellable_shares: int
    average_cost: float
    last_close: float | None
    last_price_day: date | None

    def __post_init__(self) -> None:
        if self.shares < 0 or not 0 <= self.sellable_shares <= self.shares:
            raise ValueError("position shares or sellable shares are invalid")
        if not isfinite(self.average_cost) or self.average_cost < 0:
            raise ValueError("position average cost is invalid")
        if self.last_close is not None and (not isfinite(self.last_close) or self.last_close <= 0):
            raise ValueError("position last close is invalid")

    def to_dict(self) -> dict[str, Any]:
        return {
            "instrument": _instrument_to_dict(self.instrument),
            "shares": self.shares,
            "sellableShares": self.sellable_shares,
            "averageCost": self.average_cost,
            "lastClose": self.last_close,
            "lastPriceDay": self.last_price_day.isoformat() if self.last_price_day else None,
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> PaperPosition:
        last_day = value.get("lastPriceDay")
        return cls(
            _instrument_from_dict(value["instrument"]),
            int(value["shares"]),
            int(value["sellableShares"]),
            float(value["averageCost"]),
            float(value["lastClose"]) if value.get("lastClose") is not None else None,
            date.fromisoformat(str(last_day)) if last_day else None,
        )


@dataclass(frozen=True, slots=True)
class PaperIntent:
    intent_id: str
    instrument: InstrumentId
    target_weight: float
    submitted_at: datetime

    def __post_init__(self) -> None:
        require_aware(self.submitted_at, "intent submitted_at")
        if not self.intent_id.strip():
            raise ValueError("intent_id is required")
        if not isfinite(self.target_weight) or not 0 <= self.target_weight <= 1:
            raise ValueError("target_weight must be finite and between zero and one")

    def to_dict(self) -> dict[str, Any]:
        return {
            "intentId": self.intent_id,
            "instrument": _instrument_to_dict(self.instrument),
            "targetWeight": self.target_weight,
            "submittedAt": self.submitted_at.isoformat(),
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> PaperIntent:
        return cls(
            str(value["intentId"]),
            _instrument_from_dict(value["instrument"]),
            float(value["targetWeight"]),
            datetime.fromisoformat(str(value["submittedAt"])),
        )


@dataclass(frozen=True, slots=True)
class PaperPendingTarget:
    intent_id: str
    instrument: InstrumentId
    target_weight: float
    signal_day: date

    def __post_init__(self) -> None:
        if not self.intent_id.strip() or not isfinite(self.target_weight):
            raise ValueError("pending target is invalid")
        if not 0 <= self.target_weight <= 1:
            raise ValueError("pending target weight is invalid")

    def to_dict(self) -> dict[str, Any]:
        return {
            "intentId": self.intent_id,
            "instrument": _instrument_to_dict(self.instrument),
            "targetWeight": self.target_weight,
            "signalDay": self.signal_day.isoformat(),
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> PaperPendingTarget:
        return cls(
            str(value["intentId"]),
            _instrument_from_dict(value["instrument"]),
            float(value["targetWeight"]),
            date.fromisoformat(str(value["signalDay"])),
        )


@dataclass(frozen=True, slots=True)
class PaperAccountState:
    experiment_id: str
    started_at: datetime
    ends_at: datetime
    initial_cash: float
    cash: float
    positions: tuple[PaperPosition, ...] = ()
    pending: tuple[PaperPendingTarget, ...] = ()
    delisted: tuple[InstrumentId, ...] = ()
    seen_intent_ids: tuple[str, ...] = ()
    last_processed_day: date | None = None
    last_input_hash: str = ""
    cumulative_fees: float = 0.0
    last_equity: float | None = None

    def __post_init__(self) -> None:
        require_aware(self.started_at, "started_at")
        require_aware(self.ends_at, "ends_at")
        if not self.experiment_id.strip() or not isfinite(self.initial_cash):
            raise ValueError("valid experiment_id and initial_cash are required")
        if self.initial_cash <= 0 or not isfinite(self.cash) or self.cash < -1e-6:
            raise ValueError("account cash must be finite and non-negative")
        if self.ends_at <= self.started_at:
            raise ValueError("experiment deadline must follow its start")
        expected_end = datetime.combine(
            self.started_at.astimezone(BEIJING_TZ).date() + timedelta(days=30),
            time.min,
            BEIJING_TZ,
        )
        if self.ends_at.astimezone(BEIJING_TZ) != expected_end:
            raise ValueError("experiment must span exactly 30 Beijing calendar days")
        if len({item.instrument for item in self.positions}) != len(self.positions):
            raise ValueError("duplicate account positions")
        if len({item.instrument for item in self.pending}) != len(self.pending):
            raise ValueError("duplicate pending targets")
        if len({item.intent_id for item in self.pending}) != len(self.pending):
            raise ValueError("duplicate pending intent IDs")
        if len(set(self.seen_intent_ids)) != len(self.seen_intent_ids):
            raise ValueError("duplicate applied intent IDs")

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "experimentId": self.experiment_id,
            "startedAt": self.started_at.isoformat(),
            "endsAt": self.ends_at.isoformat(),
            "initialCash": self.initial_cash,
            "cash": self.cash,
            "positions": [item.to_dict() for item in self.positions],
            "pending": [item.to_dict() for item in self.pending],
            "delisted": [_instrument_to_dict(item) for item in self.delisted],
            "seenIntentIds": list(self.seen_intent_ids),
            "lastProcessedDay": (
                self.last_processed_day.isoformat() if self.last_processed_day else None
            ),
            "lastInputHash": self.last_input_hash,
            "cumulativeFees": self.cumulative_fees,
            "lastEquity": self.last_equity,
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> PaperAccountState:
        if value.get("schemaVersion") != 1:
            raise ValueError("unsupported paper account schema")
        last_day = value.get("lastProcessedDay")
        return cls(
            experiment_id=str(value["experimentId"]),
            started_at=datetime.fromisoformat(str(value["startedAt"])),
            ends_at=datetime.fromisoformat(str(value["endsAt"])),
            initial_cash=float(value["initialCash"]),
            cash=float(value["cash"]),
            positions=tuple(PaperPosition.from_dict(item) for item in value.get("positions", [])),
            pending=tuple(PaperPendingTarget.from_dict(item) for item in value.get("pending", [])),
            delisted=tuple(_instrument_from_dict(item) for item in value.get("delisted", [])),
            seen_intent_ids=tuple(str(item) for item in value.get("seenIntentIds", [])),
            last_processed_day=date.fromisoformat(str(last_day)) if last_day else None,
            last_input_hash=str(value.get("lastInputHash") or ""),
            cumulative_fees=float(value.get("cumulativeFees") or 0),
            last_equity=(
                float(value["lastEquity"]) if value.get("lastEquity") is not None else None
            ),
        )


@dataclass(frozen=True, slots=True)
class PaperEvent:
    event_id: str
    kind: str
    occurred_at: datetime
    recorded_at: datetime
    source_observed_at: datetime | None
    detail: Mapping[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "eventId": self.event_id,
            "kind": self.kind,
            "occurredAt": self.occurred_at.isoformat(),
            "recordedAt": self.recorded_at.isoformat(),
            "sourceObservedAt": (
                self.source_observed_at.isoformat() if self.source_observed_at else None
            ),
            "engineVersion": "paper-v1",
            "detail": dict(self.detail),
        }


@dataclass(frozen=True, slots=True)
class PaperAdvanceResult:
    state: PaperAccountState
    events: tuple[PaperEvent, ...]


@dataclass(frozen=True, slots=True)
class PaperTerminalValue:
    as_of: datetime
    cash: float
    market_value: float | None
    estimated_exit_fees: float | None
    net_value: float | None
    missing_prices: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "asOf": self.as_of.isoformat(),
            "cash": self.cash,
            "marketValue": self.market_value,
            "estimatedExitFees": self.estimated_exit_fees,
            "netValue": self.net_value,
            "missingPrices": list(self.missing_prices),
        }


class PaperAccountEngine:
    """Pure daily transition engine; persistence and AI belong to later stages."""

    def __init__(
        self,
        execution: ExecutionConfig | None = None,
        *,
        holidays: Collection[date] = MAINLAND_HOLIDAYS_2026,
    ) -> None:
        self._backtester = AShareBacktester(execution)
        self._holidays = frozenset(holidays)

    @staticmethod
    def start(experiment_id: str, initial_cash: float, started_at: datetime) -> PaperAccountState:
        require_aware(started_at, "started_at")
        local_start = started_at.astimezone(BEIJING_TZ)
        end_day = local_start.date() + timedelta(days=30)
        ends_at = datetime.combine(end_day, time.min, BEIJING_TZ)
        return PaperAccountState(
            experiment_id=experiment_id,
            started_at=local_start,
            ends_at=ends_at,
            initial_cash=initial_cash,
            cash=initial_cash,
            last_equity=initial_cash,
        )

    def advance(
        self,
        state: PaperAccountState,
        *,
        as_of: datetime,
        bars: Sequence[AShareMarketBar] = (),
        market_observed_at: datetime | None = None,
        intents: Sequence[PaperIntent] = (),
    ) -> PaperAdvanceResult:
        require_aware(as_of, "as_of")
        current = as_of.astimezone(BEIJING_TZ)
        day = current.date()
        if current < state.started_at or current >= state.ends_at:
            raise ValueError("paper step is outside the 30-day experiment")
        input_hash = self._input_hash(current, bars, market_observed_at, intents)
        if state.last_processed_day == day:
            if state.last_input_hash == input_hash:
                return PaperAdvanceResult(state, ())
            raise ValueError("day already processed with different data")
        if state.last_processed_day is not None and day < state.last_processed_day:
            raise ValueError("paper days must be processed in chronological order")
        self._validate_inputs(state, current, bars, market_observed_at, intents)

        events: list[PaperEvent] = []
        positions = {
            item.instrument: Position(item.shares, item.sellable_shares, item.average_cost)
            for item in state.positions
        }
        last_prices = {
            item.instrument: (item.last_close, item.last_price_day) for item in state.positions
        }
        pending = {item.instrument: item for item in state.pending}
        delisted = set(state.delisted)
        seen = set(state.seen_intent_ids)
        cash = state.cash
        fees = state.cumulative_fees

        skipped_from = (
            state.last_processed_day + timedelta(days=1)
            if state.last_processed_day is not None
            else state.started_at.date()
        )
        while skipped_from < day:
            events.append(
                self._event(state, "missed_day", skipped_from, len(events), {}, recorded_at=current)
            )
            if self._is_open(skipped_from) and pending:
                events.append(
                    self._event(
                        state,
                        "pending_cancelled_after_missed_market",
                        skipped_from,
                        len(events),
                        {"intentIds": sorted(item.intent_id for item in pending.values())},
                        recorded_at=current,
                    )
                )
                pending.clear()
            skipped_from += timedelta(days=1)

        day_bars = {item.instrument: item for item in bars}
        if self._is_open(day) and not day_bars and (positions or pending):
            events.append(
                self._event(state, "market_data_missing", day, len(events), {}, recorded_at=current)
            )
            if pending:
                events.append(
                    self._event(
                        state,
                        "pending_cancelled_without_market_data",
                        day,
                        len(events),
                        {"intentIds": sorted(item.intent_id for item in pending.values())},
                        recorded_at=current,
                    )
                )
                pending.clear()
        elif day_bars:
            for position in positions.values():
                position.sellable_shares = position.shares
            open_equity = cash + sum(
                position.shares
                * (
                    day_bars[instrument].open
                    if instrument in day_bars
                    else last_prices[instrument][0] or position.average_cost
                )
                for instrument, position in positions.items()
                if instrument not in delisted
            )
            trades: list[Trade] = []
            rejections: list[RejectedOrder] = []
            newly_delisted = {
                instrument for instrument, bar in day_bars.items() if bar.delisting_final_day
            }
            for instrument in sorted(newly_delisted, key=lambda item: item.canonical):
                position = positions.get(instrument)
                if position is not None and position.shares > 0:
                    cash, cost, _, _ = self._backtester._execute_target(
                        day,
                        _PendingTarget(0.0, day),
                        day_bars[instrument],
                        open_equity,
                        cash,
                        positions,
                        trades,
                        rejections,
                    )
                    fees += cost
                pending.pop(instrument, None)
                events.append(
                    self._event(
                        state,
                        "delisting_final_day",
                        day,
                        len(events),
                        {"instrument": instrument.canonical},
                        recorded_at=current,
                        source_observed_at=market_observed_at,
                    )
                )
            ordered_pending = sorted(
                pending.items(),
                key=lambda item: self._backtester._pending_priority(
                    item[0],
                    _PendingTarget(item[1].target_weight, item[1].signal_day),
                    day_bars,
                    open_equity,
                    positions,
                ),
            )
            for instrument, target in ordered_pending:
                if instrument in delisted:
                    pending.pop(instrument, None)
                    rejections.append(
                        RejectedOrder(
                            day,
                            instrument,
                            OrderSide.BUY if target.target_weight > 0 else OrderSide.SELL,
                            0,
                            RejectReason.DELISTED,
                            target.signal_day,
                        )
                    )
                    continue
                bar = day_bars.get(instrument)
                if bar is None:
                    rejections.append(
                        RejectedOrder(
                            day,
                            instrument,
                            OrderSide.BUY if target.target_weight > 0 else OrderSide.SELL,
                            0,
                            RejectReason.MISSING_BAR,
                            target.signal_day,
                        )
                    )
                    continue
                trades_before = len(trades)
                rejections_before = len(rejections)
                cash, cost, _, completed = self._backtester._execute_target(
                    day,
                    _PendingTarget(target.target_weight, target.signal_day),
                    bar,
                    open_equity,
                    cash,
                    positions,
                    trades,
                    rejections,
                )
                fees += cost
                if (
                    completed
                    and target.target_weight > 0
                    and len(trades) == trades_before
                    and len(rejections) == rejections_before
                    and positions[instrument].shares == 0
                ):
                    rejections.append(
                        RejectedOrder(
                            day,
                            instrument,
                            OrderSide.BUY,
                            0,
                            RejectReason.MINIMUM_ORDER,
                            target.signal_day,
                        )
                    )
                if completed:
                    pending.pop(instrument, None)
            for trade in trades:
                events.append(
                    self._event(
                        state,
                        "fill",
                        day,
                        len(events),
                        {
                            "instrument": trade.instrument.canonical,
                            "side": trade.side.value,
                            "shares": trade.shares,
                            "price": trade.price,
                            "fees": trade.fees,
                            "signalDay": trade.signal_date.isoformat(),
                        },
                        at_open=True,
                        recorded_at=current,
                        source_observed_at=market_observed_at,
                    )
                )
            for rejection in rejections:
                events.append(
                    self._event(
                        state,
                        "rejection",
                        day,
                        len(events),
                        {
                            "instrument": rejection.instrument.canonical,
                            "reason": rejection.reason.value,
                            "requestedShares": rejection.requested_shares,
                            "signalDay": rejection.signal_date.isoformat(),
                        },
                        at_open=True,
                        recorded_at=current,
                        source_observed_at=market_observed_at,
                    )
                )
            for instrument, bar in day_bars.items():
                if instrument in positions:
                    last_prices[instrument] = (bar.close, day)
            delisted.update(newly_delisted)

        for intent in intents:
            if intent.instrument in delisted:
                raise ValueError("cannot target a delisted instrument")
            seen.add(intent.intent_id)
            pending[intent.instrument] = PaperPendingTarget(
                intent.intent_id, intent.instrument, intent.target_weight, day
            )
            events.append(
                self._event(
                    state,
                    "decision",
                    day,
                    len(events),
                    {
                        "intentId": intent.intent_id,
                        "instrument": intent.instrument.canonical,
                        "targetWeight": intent.target_weight,
                        "submittedAt": intent.submitted_at.isoformat(),
                    },
                    occurred_at=intent.submitted_at,
                    recorded_at=current,
                    source_observed_at=market_observed_at,
                )
            )

        retained = sorted(
            (
                (instrument, position)
                for instrument, position in positions.items()
                if position.shares
            ),
            key=lambda item: item[0].canonical,
        )
        paper_positions = tuple(
            PaperPosition(
                instrument,
                position.shares,
                position.sellable_shares,
                position.average_cost,
                last_prices.get(instrument, (None, None))[0],
                last_prices.get(instrument, (None, None))[1],
            )
            for instrument, position in retained
        )
        missing_prices = [
            item.instrument.canonical
            for item in paper_positions
            if item.instrument in delisted or (self._is_open(day) and item.last_price_day != day)
        ]
        market_value = sum(
            item.shares * (item.last_close if item.last_close is not None else item.average_cost)
            for item in paper_positions
            if item.instrument not in delisted
        )
        equity = None if missing_prices else cash + market_value
        events.append(
            self._event(
                state,
                "daily_close",
                day,
                len(events),
                {
                    "cash": cash,
                    "marketValue": None if missing_prices else market_value,
                    "equity": equity,
                    "missingPrices": missing_prices,
                },
                occurred_at=current,
                recorded_at=current,
                source_observed_at=market_observed_at,
            )
        )
        next_state = PaperAccountState(
            experiment_id=state.experiment_id,
            started_at=state.started_at,
            ends_at=state.ends_at,
            initial_cash=state.initial_cash,
            cash=cash,
            positions=paper_positions,
            pending=tuple(sorted(pending.values(), key=lambda item: item.instrument.canonical)),
            delisted=tuple(sorted(delisted, key=lambda item: item.canonical)),
            seen_intent_ids=tuple(sorted(seen)),
            last_processed_day=day,
            last_input_hash=input_hash,
            cumulative_fees=fees,
            last_equity=equity,
        )
        return PaperAdvanceResult(next_state, tuple(events))

    def terminal_value(self, state: PaperAccountState, *, as_of: datetime) -> PaperTerminalValue:
        require_aware(as_of, "as_of")
        current = as_of.astimezone(BEIJING_TZ)
        if current < state.ends_at:
            raise ValueError("experiment has not reached its 30-day deadline")
        latest_open_day = state.ends_at.date() - timedelta(days=1)
        while not self._is_open(latest_open_day):
            latest_open_day -= timedelta(days=1)
        missing = tuple(
            item.instrument.canonical
            for item in state.positions
            if item.instrument in state.delisted
            or item.last_close is None
            or item.last_price_day != latest_open_day
        )
        if missing:
            return PaperTerminalValue(current, state.cash, None, None, None, missing)
        market_value = sum(item.shares * (item.last_close or 0) for item in state.positions)
        exit_fees = sum(
            self._backtester._fees(item.shares * (item.last_close or 0), OrderSide.SELL)
            for item in state.positions
        )
        return PaperTerminalValue(
            current,
            state.cash,
            market_value,
            exit_fees,
            state.cash + market_value - exit_fees,
            (),
        )

    def _validate_inputs(
        self,
        state: PaperAccountState,
        as_of: datetime,
        bars: Sequence[AShareMarketBar],
        market_observed_at: datetime | None,
        intents: Sequence[PaperIntent],
    ) -> None:
        day = as_of.date()
        if bars:
            if not self._is_open(day):
                raise ValueError("market bars cannot be supplied for a closed day")
            if market_observed_at is None:
                raise ValueError("market observation time is required for bars")
            require_aware(market_observed_at, "market_observed_at")
            observed = market_observed_at.astimezone(BEIJING_TZ)
            if observed.date() != day or observed.time() < time(15):
                raise ValueError("full daily bars are unavailable before market close")
            if observed > as_of:
                raise ValueError("market data cannot be observed in the future")
        elif market_observed_at is not None:
            raise ValueError("market observation time requires bars")
        if len({item.instrument for item in bars}) != len(bars):
            raise ValueError("duplicate instrument/day bar")
        for bar in bars:
            if bar.trade_date != day:
                raise ValueError("bar date must match paper step day")
            self._backtester._validate_bar(bar)
        if len({item.intent_id for item in intents}) != len(intents):
            raise ValueError("duplicate intent IDs in one step")
        if len({item.instrument for item in intents}) != len(intents):
            raise ValueError("multiple targets for one stock in one step")
        for intent in intents:
            submitted = intent.submitted_at.astimezone(BEIJING_TZ)
            if intent.intent_id in state.seen_intent_ids:
                raise ValueError("intent ID was already applied")
            if submitted.date() != day or not state.started_at <= submitted <= as_of:
                raise ValueError("intent must be submitted on the current day before as_of")
            if market_observed_at is not None and submitted < market_observed_at.astimezone(
                BEIJING_TZ
            ):
                raise ValueError("intent cannot use a completed bar before it was observed")

    def _is_open(self, day: date) -> bool:
        return day.weekday() < 5 and day not in self._holidays

    @staticmethod
    def _input_hash(
        as_of: datetime,
        bars: Sequence[AShareMarketBar],
        market_observed_at: datetime | None,
        intents: Sequence[PaperIntent],
    ) -> str:
        body = {
            "asOf": as_of.isoformat(),
            "marketObservedAt": (market_observed_at.isoformat() if market_observed_at else None),
            "bars": [
                asdict(item) for item in sorted(bars, key=lambda bar: bar.instrument.canonical)
            ],
            "intents": [
                item.to_dict() for item in sorted(intents, key=lambda item: item.intent_id)
            ],
        }
        return hashlib.sha256(
            json.dumps(body, default=str, sort_keys=True).encode("utf-8")
        ).hexdigest()

    @staticmethod
    def _event(
        state: PaperAccountState,
        kind: str,
        day: date,
        ordinal: int,
        detail: Mapping[str, Any],
        *,
        at_open: bool = False,
        occurred_at: datetime | None = None,
        recorded_at: datetime | None = None,
        source_observed_at: datetime | None = None,
    ) -> PaperEvent:
        moment = occurred_at or datetime.combine(
            day, time(9, 30) if at_open else time(15), BEIJING_TZ
        )
        detail_hash = hashlib.sha256(
            json.dumps(detail, sort_keys=True, default=str).encode("utf-8")
        ).hexdigest()[:16]
        raw_id = f"{state.experiment_id}|{day.isoformat()}|{kind}|{ordinal}|{detail_hash}"
        event_id = hashlib.sha256(raw_id.encode("utf-8")).hexdigest()[:24]
        return PaperEvent(
            event_id,
            kind,
            moment,
            recorded_at or moment,
            source_observed_at,
            detail,
        )
