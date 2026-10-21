"""Optional Tushare adapter. Credentials never enter source or Firestore."""

from __future__ import annotations

import os
from collections.abc import Sequence
from datetime import date, datetime, time
from math import isnan
from numbers import Real
from typing import Any

from .clock import BEIJING_TZ
from .domain import (
    AdjustmentFactor,
    Announcement,
    Bar,
    BarInterval,
    DailyFundamental,
    Exchange,
    FinancialPointInTime,
    FinancialStatement,
    InstrumentId,
    InstrumentLifecycle,
    Quote,
    SourceEvidence,
    TradeCalendarDay,
)


class TushareProvider:
    provider_name = "Tushare Pro"

    def __init__(self, token: str | None = None, client: Any | None = None) -> None:
        self._token = (token or os.environ.get("TUSHARE_TOKEN", "")).strip()
        if client is None and not self._token:
            raise ValueError("TUSHARE_TOKEN is required outside the repository")
        self._pro = client

    def _client(self) -> Any:
        if self._pro is None:
            try:
                import tushare  # type: ignore
            except ImportError as error:
                raise RuntimeError("Install syncnote-quant-core[tushare]") from error
            self._pro = tushare.pro_api(self._token)
        return self._pro

    @staticmethod
    def _ts_code(instrument: InstrumentId) -> str:
        suffix = {
            Exchange.SSE: "SH",
            Exchange.SZSE: "SZ",
            Exchange.BSE: "BJ",
        }[instrument.exchange]
        return f"{instrument.code}.{suffix}"

    @staticmethod
    def _date(value: date) -> str:
        return value.strftime("%Y%m%d")

    @staticmethod
    def _parse_date(value: object) -> date:
        raw = str(value)
        if len(raw) != 8 or not raw.isdigit():
            raise ValueError(f"Invalid Tushare date: {raw}")
        return date.fromisoformat(f"{raw[0:4]}-{raw[4:6]}-{raw[6:8]}")

    @staticmethod
    def _clean_value(value: Any) -> Any:
        if isinstance(value, Real) and isnan(float(value)):
            return None
        return value

    def _evidence(self, dataset: str, observed_at: datetime) -> SourceEvidence:
        return SourceEvidence(
            provider=self.provider_name,
            dataset=dataset,
            observed_at=observed_at,
            fetched_at=datetime.now(BEIJING_TZ),
            source_url="https://tushare.pro/document/2",
            license_scope="personal_research",
        )

    def quote(self, instrument: InstrumentId) -> Quote:
        frame = self._client().daily(ts_code=self._ts_code(instrument), limit=1)
        if frame is None or frame.empty:
            raise LookupError(f"No Tushare quote for {instrument.canonical}")
        row = frame.iloc[0]
        observed = datetime.combine(
            self._parse_date(row["trade_date"]),
            time(15, 0),
            BEIJING_TZ,
        )
        return Quote(
            instrument=instrument,
            name=instrument.code,
            price=float(row["close"]),
            previous_close=float(row["pre_close"]),
            open=float(row["open"]),
            high=float(row["high"]),
            low=float(row["low"]),
            volume=float(row.get("vol", 0)),
            amount=float(row.get("amount", 0)) * 1000,
            turnover_rate=0,
            evidence=self._evidence("daily", observed),
        )

    def instruments(self) -> Sequence[InstrumentLifecycle]:
        frames = []
        for status in ("L", "D", "P"):
            frame = self._client().stock_basic(
                exchange="",
                list_status=status,
                fields="ts_code,name,industry,list_date,delist_date",
            )
            if frame is not None and not frame.empty:
                frames.append(frame)
        output: list[InstrumentLifecycle] = []
        for frame in frames:
            for _, row in frame.iterrows():
                raw_code = str(row.get("ts_code") or "")
                if "." not in raw_code:
                    continue
                code, suffix = raw_code.split(".", 1)
                exchange = {"SH": Exchange.SSE, "SZ": Exchange.SZSE, "BJ": Exchange.BSE}.get(
                    suffix
                )
                if exchange is None:
                    continue
                listed = str(row.get("list_date") or "")
                if len(listed) != 8:
                    continue
                delisted = str(row.get("delist_date") or "")
                observed = datetime.combine(
                    datetime.now(BEIJING_TZ).date(), time(18, 0), BEIJING_TZ
                )
                output.append(
                    InstrumentLifecycle(
                        InstrumentId(code, exchange),
                        str(row.get("name") or code),
                        str(row.get("industry") or "未分类"),
                        self._parse_date(listed),
                        self._parse_date(delisted) if len(delisted) == 8 else None,
                        self._evidence("stock_basic", observed),
                    )
                )
        return tuple(sorted(output, key=lambda item: item.instrument.canonical))

    def daily_fundamentals(
        self, instrument: InstrumentId, start: date, end: date
    ) -> Sequence[DailyFundamental]:
        frame = self._client().daily_basic(
            ts_code=self._ts_code(instrument),
            start_date=self._date(start),
            end_date=self._date(end),
            fields="ts_code,trade_date,turnover_rate,pe_ttm,pb,total_mv",
        )
        output: list[DailyFundamental] = []
        for _, row in frame.sort_values("trade_date").iterrows():
            trade_date = self._parse_date(row["trade_date"])
            available = datetime.combine(trade_date, time(18, 0), BEIJING_TZ)
            market_cap = self._clean_value(row.get("total_mv"))
            if market_cap is None or float(market_cap) <= 0:
                continue
            output.append(
                DailyFundamental(
                    instrument,
                    trade_date,
                    available,
                    float(market_cap) * 10_000,
                    _optional_number(self._clean_value(row.get("pe_ttm"))),
                    _optional_number(self._clean_value(row.get("pb"))),
                    _optional_number(self._clean_value(row.get("turnover_rate"))),
                    self._evidence("daily_basic", available),
                )
            )
        return tuple(output)

    def bars(
        self,
        instrument: InstrumentId,
        start: date,
        end: date,
        interval: BarInterval = BarInterval.DAY,
    ) -> Sequence[Bar]:
        api_name = {
            BarInterval.DAY: "daily",
            BarInterval.WEEK: "weekly",
            BarInterval.MONTH: "monthly",
        }.get(interval)
        if api_name is None:
            raise NotImplementedError("Minute permission is an explicit optional data product")
        frame = getattr(self._client(), api_name)(
            ts_code=self._ts_code(instrument),
            start_date=self._date(start),
            end_date=self._date(end),
        )
        output: list[Bar] = []
        for _, row in frame.sort_values("trade_date").iterrows():
            observed = datetime.combine(
                self._parse_date(row["trade_date"]),
                time(15, 0),
                BEIJING_TZ,
            )
            output.append(
                Bar(
                    instrument,
                    interval,
                    observed,
                    float(row["open"]),
                    float(row["high"]),
                    float(row["low"]),
                    float(row["close"]),
                    float(row.get("vol", 0)),
                    float(row.get("amount", 0)) * 1000,
                    self._evidence(api_name, observed),
                )
            )
        return output

    def adjustment_factors(
        self, instrument: InstrumentId, start: date, end: date
    ) -> Sequence[AdjustmentFactor]:
        frame = self._client().adj_factor(
            ts_code=self._ts_code(instrument),
            start_date=self._date(start),
            end_date=self._date(end),
        )
        output: list[AdjustmentFactor] = []
        for _, row in frame.sort_values("trade_date").iterrows():
            trade_date = self._parse_date(row["trade_date"])
            available = datetime.combine(trade_date, time(18, 0), BEIJING_TZ)
            output.append(
                AdjustmentFactor(
                    instrument,
                    trade_date,
                    float(row["adj_factor"]),
                    available,
                    self._evidence("adj_factor", available),
                )
            )
        return output

    def financials(
        self, instrument: InstrumentId, start: date, end: date
    ) -> Sequence[FinancialPointInTime]:
        frame = self._client().fina_indicator(
            ts_code=self._ts_code(instrument),
            start_date=self._date(start),
            end_date=self._date(end),
        )
        output: list[FinancialPointInTime] = []
        for index, row in frame.iterrows():
            announcement = str(row.get("ann_date") or "")
            actual_announcement = str(row.get("f_ann_date") or announcement)
            if len(announcement) != 8 or len(actual_announcement) != 8:
                continue
            published = datetime.combine(
                self._parse_date(announcement), time(18, 0), BEIJING_TZ
            )
            available = datetime.combine(
                self._parse_date(actual_announcement), time(18, 0), BEIJING_TZ
            )
            available = max(available, published)
            period = self._parse_date(row["end_date"])
            values = {
                key: self._clean_value(value)
                for key, value in row.to_dict().items()
                if key not in {"ts_code", "ann_date", "f_ann_date", "end_date"}
            }
            output.append(
                FinancialPointInTime(
                    instrument,
                    FinancialStatement.INDICATOR,
                    period,
                    published,
                    available,
                    values,
                    self._evidence("fina_indicator", available),
                    revision=f"{actual_announcement}:{row.get('update_flag', index)}",
                )
            )
        return output

    def announcements(
        self, instrument: InstrumentId, start: date, end: date
    ) -> Sequence[Announcement]:
        raise NotImplementedError("Announcement permission must be configured explicitly")

    def trade_calendar(self, start: date, end: date) -> Sequence[TradeCalendarDay]:
        frame = self._client().trade_cal(
            exchange="SSE", start_date=self._date(start), end_date=self._date(end)
        )
        output: list[TradeCalendarDay] = []
        for _, row in frame.sort_values("cal_date").iterrows():
            day = self._parse_date(row["cal_date"])
            observed = datetime.combine(day, time(0, 0), BEIJING_TZ)
            previous = str(row.get("pretrade_date") or "")
            output.append(
                TradeCalendarDay(
                    day,
                    int(row["is_open"]) == 1,
                    self._parse_date(previous)
                    if len(previous) == 8
                    else None,
                    self._evidence("trade_cal", observed),
                )
            )
        return output


def _optional_number(value: Any) -> float | None:
    return None if value is None else float(value)
