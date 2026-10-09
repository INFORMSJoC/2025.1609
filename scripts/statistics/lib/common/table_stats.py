#!/usr/bin/env python3
"""Generic compared-setting table aggregation rules.

Scope:
    Cross-project. This module aggregates records for tables that compare
    multiple algorithm/settings over the same instance keys. It assumes each
    record has at least these attributes: a setting attribute selected by
    `TableStatsPolicy.setting_attr`, `status`, `time`, `node`, `gap`, and
    `rgap`.

Rules:
    - `S` is a per-setting solved count.
    - `T`, `N`, and `LPG(%)` use row-local instance keys where at least one
      compared setting solved; if that subset is empty, they fall back to all
      row-local instance keys.
    - `G(%)` uses row-local instance keys where at least one compared setting
      did not solve; if that subset is empty, it falls back to all row-local
      instance keys.
    - Numeric averages are arithmetic unless the table policy explicitly asks
      for another supported average.

Do not put project constants, TeX table layout, raw-log parsing, or output-path
policy here. A project-specific style layer should decide labels, columns, and
where generated files are written.
"""
from __future__ import annotations

import math
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any


DEFAULT_TIME_LIMIT_SECONDS = 3600.0

RunKey = tuple[Any, ...]
RunKeyFunc = Callable[[Any], RunKey]


@dataclass(frozen=True)
class TableStatsPolicy:
    """Aggregation policy for a compared-setting performance table."""

    setting_attr: str
    key_func: RunKeyFunc
    average: str = "arithmetic"
    time_limit: float = DEFAULT_TIME_LIMIT_SECONDS


def shifted_geomean(values: Sequence[float], shift: float = 1.0) -> float:
    if not values:
        return 0.0
    return math.exp(sum(math.log(max(v, 0.0) + shift) for v in values) / len(values)) - shift


def arithmetic_mean(values: Sequence[float]) -> float:
    if not values:
        return 0.0
    return sum(values) / len(values)


def average_func(name: str) -> Callable[[Sequence[float]], float]:
    if name == "geometric":
        return shifted_geomean
    if name == "arithmetic":
        return arithmetic_mean
    raise ValueError(f"Unknown average type: {name}")


def format_time(value: float, time_limit: float = DEFAULT_TIME_LIMIT_SECONDS) -> str:
    if value >= time_limit - 0.01:
        return r"    \TL"
    if 0 < value < 0.1:
        return r" $<$0.1"
    return f"{value:7.1f}"


def format_decimal(value: float) -> str:
    if 0 < value < 0.1:
        return r" $<$0.1"
    return f"{value:7.1f}"


def format_integer_average(value: float) -> str:
    return f"{math.floor(value + 0.5 + 1e-9):7d}"


def setting_runs(runs: Sequence[Any], setting_attr: str, setting: str) -> list[Any]:
    return [run for run in runs if getattr(run, setting_attr) == setting]


def runs_with_any_optimal(runs: Sequence[Any], key_func: RunKeyFunc) -> list[Any]:
    solved_keys = {key_func(run) for run in runs if run.status == "OPTIMAL"}
    return [run for run in runs if key_func(run) in solved_keys]


def runs_with_any_nonoptimal(runs: Sequence[Any], key_func: RunKeyFunc) -> list[Any]:
    nonoptimal_keys = {key_func(run) for run in runs if run.status != "OPTIMAL"}
    return [run for run in runs if key_func(run) in nonoptimal_keys]


def metric_runs_for_group(runs: Sequence[Any], key_func: RunKeyFunc) -> list[Any]:
    selected = runs_with_any_optimal(runs, key_func)
    return selected if selected else list(runs)


def gap_runs_for_group(runs: Sequence[Any], key_func: RunKeyFunc) -> list[Any]:
    selected = runs_with_any_nonoptimal(runs, key_func)
    return selected if selected else list(runs)


def metric_cells(
    runs: Sequence[Any],
    setting: str,
    policy: TableStatsPolicy,
    *,
    gap_runs: Sequence[Any] | None = None,
) -> list[str]:
    selected = setting_runs(runs, policy.setting_attr, setting)
    nsol = sum(1 for run in selected if run.status == "OPTIMAL")
    if not selected:
        return [f"{nsol:7d}", format_time(policy.time_limit, policy.time_limit), "", "", ""]

    gap_selected = setting_runs(gap_runs if gap_runs is not None else runs, policy.setting_attr, setting)
    if not gap_selected:
        gap_selected = selected

    avg = average_func(policy.average)
    time = avg([run.time for run in selected])
    node = avg([run.node for run in selected])
    gap = avg([run.gap for run in gap_selected])
    rgap = avg([run.rgap for run in selected])
    return [
        f"{nsol:7d}",
        format_time(time, policy.time_limit),
        format_integer_average(node),
        format_decimal(gap),
        format_decimal(rgap),
    ]


def table_metric_cells(runs: Sequence[Any], settings: Sequence[str], policy: TableStatsPolicy) -> list[list[str]]:
    metrics_source = metric_runs_for_group(runs, policy.key_func)
    gap_source = gap_runs_for_group(runs, policy.key_func)
    return [metric_cells(metrics_source, setting, policy, gap_runs=gap_source) for setting in settings]


def average_source_count(runs: Sequence[Any], policy: TableStatsPolicy, nsettings: int) -> int:
    return len(metric_runs_for_group(runs, policy.key_func)) // nsettings
