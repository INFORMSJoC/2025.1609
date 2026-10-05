#!/usr/bin/env python3
"""Cross-project workflow for compact compared-setting TeX tables.

Scope:
    Generic table workflow for optimization/research-code reports. This module
    turns already-parsed run records into compact TeX tables that compare
    several settings over shared instance groups: filter records, group them,
    render one row per group, append configured summary rows, and finish with
    solved-count and average rows.

The intent is to share the workflow around `common.table_stats` without moving
project choices into common code. Projects still provide method labels, row
labels, filters, instance grouping, and output file naming.

Do not add project-specific setting names, manuscript macros, result schemas,
raw-log parsing, or experiment paths here. Project packages should pass those
choices through `CompactTableConfig` and callbacks.
"""
from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from typing import Any

from common.table_stats import (
    TableStatsPolicy,
    average_source_count,
    gap_runs_for_group,
    metric_cells,
    metric_runs_for_group,
    table_metric_cells,
)


@dataclass(frozen=True)
class SummaryRowSpec:
    """Declarative recipe for one aggregate table row."""

    label: str
    predicate: Callable[[Any], bool]


@dataclass(frozen=True)
class CompactTableConfig:
    """Workflow contract for a compact compared-setting table."""

    methods_and_headers: Sequence[tuple[str, str]]
    key_func: Callable[[Any], tuple[Any, ...]]
    row_label: Callable[[Any], str]
    summary_rows: Sequence[SummaryRowSpec] = ()
    group_attr: str = "data"
    setting_attr: str = "method"
    average: str = "arithmetic"
    time_limit: float = 3600.0
    filter_predicate: Callable[[Any], bool] | None = None
    group_sort_key: Callable[[Any], Any] | None = None
    metric_headers: Sequence[str] = field(
        default_factory=lambda: (
            r" \tblnsol",
            r" \tbltime",
            r" \tblnode",
            r" \tblgap",
            r" \tblrgap",
        )
    )


def compact_table_policy(config: CompactTableConfig) -> TableStatsPolicy:
    return TableStatsPolicy(
        setting_attr=config.setting_attr,
        key_func=config.key_func,
        average=config.average,
        time_limit=config.time_limit,
    )


def selected_table_runs(runs: Sequence[Any], config: CompactTableConfig) -> list[Any]:
    methods = {method for method, _ in config.methods_and_headers}
    return [
        run
        for run in runs
        if getattr(run, config.setting_attr) in methods
        and (config.filter_predicate is None or config.filter_predicate(run))
    ]


def compact_table_header(method_headers: Sequence[str], metric_headers: Sequence[str]) -> str:
    nmetrics = len(metric_headers)
    lines = [
        r"\begin{tabular}{cc" + "r" * (len(method_headers) * nmetrics) + "}",
        r"\toprule",
        r"\multicolumn{1}{c}{\multirow{2}{*}{\tblgroup}}",
        r" & \multicolumn{1}{c}{\multirow{2}{*}{\tblndata}}",
    ]
    for header in method_headers:
        lines.append(rf" & \multicolumn{{{nmetrics}}}{{c}}{{{header}}}")
    lines.append(r" \\")
    lines.extend(
        rf"\cmidrule(r){{{start}-{start + nmetrics - 1}}}"
        for start in range(3, 3 + len(method_headers) * nmetrics, nmetrics)
    )
    lines.append(r" &  & " + " & ".join(list(metric_headers) * len(method_headers)) + r" \\")
    lines.append(r"\midrule")
    return "\n".join(lines)


def compact_table_row(label: str, runs: Sequence[Any], config: CompactTableConfig) -> str:
    methods = [method for method, _ in config.methods_and_headers]
    policy = compact_table_policy(config)
    cells = [rf"\multicolumn{{1}}{{l}}{{{label}}}", f"{len(runs) // len(methods):<6d}"]
    for block in table_metric_cells(runs, methods, policy):
        cells.extend(block)
    return " & ".join(cells) + r" \\"


def _group_runs(runs: Sequence[Any], config: CompactTableConfig) -> dict[Any, list[Any]]:
    sort_key = config.group_sort_key or (lambda value: value)
    grouped = {
        value: []
        for value in sorted({getattr(run, config.group_attr) for run in runs}, key=sort_key)
    }
    for run in runs:
        grouped[getattr(run, config.group_attr)].append(run)
    return grouped


def build_compact_summary_table(runs: Sequence[Any], config: CompactTableConfig) -> str:
    methods = [method for method, _ in config.methods_and_headers]
    selected_runs = selected_table_runs(runs, config)

    lines = [compact_table_header([header for _, header in config.methods_and_headers], config.metric_headers)]
    for group_value, group_runs in _group_runs(selected_runs, config).items():
        lines.append(compact_table_row(config.row_label(group_value), group_runs, config))

    if config.summary_rows:
        lines.append(r"\midrule")
        for summary in config.summary_rows:
            lines.append(
                compact_table_row(
                    summary.label,
                    [run for run in selected_runs if summary.predicate(run)],
                    config,
                )
            )

    lines.append(r"\midrule")
    sol_cells = [r"\multicolumn{1}{l}{Sol.}", f"{len(selected_runs) // len(methods):4d}"]
    for method in methods:
        nsol = sum(
            1
            for run in selected_runs
            if getattr(run, config.setting_attr) == method and run.status == "OPTIMAL"
        )
        sol_cells.extend([f"{nsol:7d}", "", "", "", ""])
    lines.append(" & ".join(sol_cells) + r" \\")

    policy = compact_table_policy(config)
    metric_runs = metric_runs_for_group(selected_runs, policy.key_func)
    gap_runs = gap_runs_for_group(selected_runs, policy.key_func)
    avg_cells = [
        r"\multicolumn{1}{l}{Aver.}",
        f"{average_source_count(selected_runs, policy, len(methods)):4d}",
    ]
    for method in methods:
        avg_cells.extend(["", *metric_cells(metric_runs, method, policy, gap_runs=gap_runs)[1:]])
    lines.append(" & ".join(avg_cells) + r" \\")

    lines.extend([r"\bottomrule", r"\end{tabular}"])
    return "\n".join(lines) + "\n"
