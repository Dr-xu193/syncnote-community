"""Point-in-time price adjustment for signal calculation only."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from datetime import datetime
from enum import StrEnum

from .domain import AdjustmentFactor, Bar, require_aware


class AdjustmentMode(StrEnum):
    NONE = "none"
    FORWARD = "forward"
    BACKWARD = "backward"


def adjusted_closes_as_of(
    bars: Sequence[Bar],
    factors: Sequence[AdjustmentFactor],
    *,
    as_of: datetime,
    mode: AdjustmentMode = AdjustmentMode.FORWARD,
) -> Mapping[datetime, float]:
    """Adjust signal prices using only factors already available at ``as_of``.

    Execution must continue to use raw prices. Forward adjustment anchors the
    history to the latest factor known at the decision time; backward adjustment
    retains the provider's cumulative factor scale.
    """

    require_aware(as_of, "as_of")
    if not bars:
        return {}
    instrument = bars[0].instrument
    if any(item.instrument != instrument for item in bars):
        raise ValueError("adjustment input must contain one instrument")
    visible_bars = [item for item in bars if item.timestamp <= as_of]
    if mode == AdjustmentMode.NONE:
        return {item.timestamp: item.close for item in visible_bars}

    eligible = sorted(
        (
            item
            for item in factors
            if item.instrument == instrument and item.available_at <= as_of
        ),
        key=lambda item: item.trade_date,
    )
    if not eligible:
        raise ValueError("no point-in-time adjustment factors are available")
    by_date = {item.trade_date: item.factor for item in eligible}
    anchor = eligible[-1].factor
    output: dict[datetime, float] = {}
    last_factor: float | None = None
    for bar in sorted(visible_bars, key=lambda item: item.timestamp):
        factor = by_date.get(bar.timestamp.date(), last_factor)
        if factor is None:
            raise ValueError(f"missing adjustment factor on {bar.timestamp.date()}")
        last_factor = factor
        multiplier = factor / anchor if mode == AdjustmentMode.FORWARD else factor
        output[bar.timestamp] = bar.close * multiplier
    return output
