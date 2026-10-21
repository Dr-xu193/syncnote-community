from datetime import date, timedelta

from syncnote_quant.walk_forward import WalkForwardRunner


def test_walk_forward_selects_only_on_training_and_evaluates_future_window() -> None:
    dates = [date(2026, 1, 1) + timedelta(days=index) for index in range(12)]
    scored_windows: list[tuple[date, ...]] = []
    evaluated_windows: list[tuple[date, ...]] = []

    def scorer(train_dates: tuple[date, ...], parameter: int) -> float:
        scored_windows.append(train_dates)
        return -abs(parameter - len(train_dates))

    def evaluator(test_dates: tuple[date, ...], parameter: int) -> tuple[int, date, date]:
        evaluated_windows.append(test_dates)
        return parameter, test_dates[0], test_dates[-1]

    folds = WalkForwardRunner[int, tuple[int, date, date]]().run(
        dates,
        [2, 4, 8],
        train_size=4,
        test_size=2,
        scorer=scorer,
        evaluator=evaluator,
    )
    assert len(folds) == 4
    assert all(fold.selected_parameter == 4 for fold in folds)
    assert all(fold.train_dates[-1] < fold.test_dates[0] for fold in folds)
    assert all(window not in scored_windows for window in evaluated_windows)
