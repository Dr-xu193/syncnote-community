"""Prediction calibration and post-hoc error attribution."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from enum import StrEnum
from statistics import fmean


@dataclass(frozen=True, slots=True)
class PredictionOutcome:
    prediction_id: str
    predicted_probability: float
    outcome: bool

    def __post_init__(self) -> None:
        if not 0 <= self.predicted_probability <= 1:
            raise ValueError("predicted_probability must be between zero and one")


@dataclass(frozen=True, slots=True)
class CalibrationBin:
    lower: float
    upper: float
    count: int
    mean_prediction: float
    observed_rate: float


@dataclass(frozen=True, slots=True)
class CalibrationReport:
    sample_count: int
    brier_score: float
    bins: tuple[CalibrationBin, ...]


def calibration_report(
    outcomes: Sequence[PredictionOutcome], *, bin_count: int = 5
) -> CalibrationReport:
    if bin_count <= 0:
        raise ValueError("bin_count must be positive")
    if not outcomes:
        return CalibrationReport(0, 0.0, ())
    brier = fmean(
        (item.predicted_probability - float(item.outcome)) ** 2 for item in outcomes
    )
    bins: list[CalibrationBin] = []
    for index in range(bin_count):
        lower = index / bin_count
        upper = (index + 1) / bin_count
        selected = [
            item
            for item in outcomes
            if lower <= item.predicted_probability < upper
            or index == bin_count - 1
            and lower <= item.predicted_probability <= upper
        ]
        if selected:
            bins.append(
                CalibrationBin(
                    lower,
                    upper,
                    len(selected),
                    fmean(item.predicted_probability for item in selected),
                    fmean(float(item.outcome) for item in selected),
                )
            )
    return CalibrationReport(len(outcomes), brier, tuple(bins))


class ErrorClass(StrEnum):
    DATA = "data_error"
    STRATEGY = "strategy_error"
    EXECUTION = "execution_error"
    BEHAVIOR = "behavior_error"
    UNKNOWN = "unknown"


def attribute_review_error(
    *,
    data_was_correct: bool,
    strategy_rule_was_valid: bool,
    execution_was_feasible: bool,
    user_followed_plan: bool,
) -> ErrorClass:
    if not data_was_correct:
        return ErrorClass.DATA
    if not strategy_rule_was_valid:
        return ErrorClass.STRATEGY
    if not execution_was_feasible:
        return ErrorClass.EXECUTION
    if not user_followed_plan:
        return ErrorClass.BEHAVIOR
    return ErrorClass.UNKNOWN
