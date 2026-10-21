"""Walk-forward selection that never uses a test window for parameter choice."""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import date
from typing import Generic, TypeVar

Parameter = TypeVar("Parameter")
Result = TypeVar("Result")


@dataclass(frozen=True, slots=True)
class WalkForwardFold(Generic[Parameter, Result]):
    train_dates: tuple[date, ...]
    test_dates: tuple[date, ...]
    selected_parameter: Parameter
    training_scores: Mapping[str, float]
    test_result: Result


class WalkForwardRunner(Generic[Parameter, Result]):
    def run(
        self,
        dates: Sequence[date],
        parameters: Sequence[Parameter],
        *,
        train_size: int,
        test_size: int,
        scorer: Callable[[tuple[date, ...], Parameter], float],
        evaluator: Callable[[tuple[date, ...], Parameter], Result],
        parameter_name: Callable[[Parameter], str] = str,
    ) -> tuple[WalkForwardFold[Parameter, Result], ...]:
        ordered = tuple(sorted(set(dates)))
        if train_size <= 0 or test_size <= 0:
            raise ValueError("train_size and test_size must be positive")
        if not parameters:
            raise ValueError("at least one parameter candidate is required")
        folds: list[WalkForwardFold[Parameter, Result]] = []
        cursor = train_size
        while cursor + test_size <= len(ordered):
            train_dates = ordered[cursor - train_size : cursor]
            test_dates = ordered[cursor : cursor + test_size]
            scores = {parameter_name(value): scorer(train_dates, value) for value in parameters}
            selected = max(
                parameters,
                key=lambda value: (scores[parameter_name(value)], parameter_name(value)),
            )
            if train_dates[-1] >= test_dates[0]:
                raise AssertionError("walk-forward train/test windows overlap")
            folds.append(
                WalkForwardFold(
                    train_dates,
                    test_dates,
                    selected,
                    dict(sorted(scores.items())),
                    evaluator(test_dates, selected),
                )
            )
            cursor += test_size
        return tuple(folds)
