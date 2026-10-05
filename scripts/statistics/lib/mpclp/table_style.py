#!/usr/bin/env python3
"""Reusable MPCLP TeX table layout renderers.

Scope:
    MPCLP-specific table presentation. This module turns already-selected data
    and shared statistics into TeX/CSV table artifacts with the visual layouts
    used by the manuscript audit and appendix checks.

Current layouts:
    - compact `Group` performance summary tables;
    - grouped and original-format newly solved/unsolved-instance tables;
    - two-panel theta-gap tables for co-location summaries.

Boundary:
    MPCLP row labels, filters, and output-path policy live here; the compact
    compared-setting table workflow lives in `common.table_workflow`;
    aggregation rules live in `common.table_stats`; experiment-specific input
    selection and CLI workflows live in `scripts/report/`.
"""
from __future__ import annotations

import csv
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from common.table_workflow import (
    CompactTableConfig,
    SummaryRowSpec,
    build_compact_summary_table,
)
from .config import ROOT, TIME_LIMIT_SECONDS


@dataclass(frozen=True)
class CompactSummaryConfig:
    methods_and_macros: Sequence[tuple[str, str]]
    key_func: Callable[[Any], tuple[Any, ...]]
    theta_values: Sequence[str]
    setting_attr: str = "method"
    average: str = "arithmetic"
    time_limit: float = TIME_LIMIT_SECONDS
    include_ps_rows: bool = False


def read_group_label(data_id: int) -> str:
    data_file = ROOT / f"data/pmed{data_id}.txt"
    first = data_file.read_text().splitlines()[0].split()
    n_vertices, _, k_value = first
    return f"{data_id}-{n_vertices}-{k_value}"


def _compact_workflow_config(ps_values: Sequence[str], config: CompactSummaryConfig) -> CompactTableConfig:
    methods = [method for method, _ in config.methods_and_macros]

    summary_rows: list[SummaryRowSpec] = []
    if config.include_ps_rows:
        for sp in ps_values:
            summary_rows.append(
                SummaryRowSpec(label=rf"$p^s={sp}$", predicate=lambda run, sp=sp: run.sp == sp)
            )
    for theta in config.theta_values:
        summary_rows.append(
            SummaryRowSpec(
                label=rf"$\theta={theta}$",
                predicate=lambda run, theta=theta: run.theta == theta,
            )
        )

    return CompactTableConfig(
        methods_and_headers=config.methods_and_macros,
        key_func=config.key_func,
        row_label=lambda data_id: read_group_label(int(data_id)),
        summary_rows=summary_rows,
        setting_attr=config.setting_attr,
        average=config.average,
        time_limit=config.time_limit,
        filter_predicate=lambda run: run.sp in ps_values
        and run.theta in config.theta_values
        and getattr(run, config.setting_attr) in methods,
    )


def build_compact_table(runs: Sequence[Any], ps_values: Sequence[str], config: CompactSummaryConfig) -> str:
    return build_compact_summary_table(runs, _compact_workflow_config(ps_values, config))


def write_compact_radius_tables(
    runs: Sequence[Any],
    output_dir: Path,
    radius_pairs: Sequence[tuple[str, str]],
    ps_sets: Sequence[tuple[str, Sequence[str]]],
    config: CompactSummaryConfig,
) -> list[Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for r, R in radius_pairs:
        radius_runs = [run for run in runs if run.r == r and run.R == R]
        for suffix, ps_values in ps_sets:
            path = output_dir / f"summary_r{r}-R{R}_{suffix}.tex"
            path.write_text(build_compact_table(radius_runs, ps_values, config))
            written.append(path)

    if len(radius_pairs) > 1:
        radius_labels = "_".join(f"r{r}-R{R}" for r, R in radius_pairs)
        radius_set = set(radius_pairs)
        combined_runs = [run for run in runs if (run.r, run.R) in radius_set]
        for suffix, ps_values in ps_sets:
            path = output_dir / f"summary_{radius_labels}_{suffix}.tex"
            path.write_text(build_compact_table(combined_runs, ps_values, config))
            written.append(path)
    return written


def _theta_text(theta: float) -> str:
    return f"{theta:g}"


def _format_one_decimal_or_lt(value: float) -> str:
    if 0 < value < 0.1:
        return r" $<$0.1"
    return f"{value:7.1f}"


def _unsolved_side(row: Sequence[Any], r: int, R: int, theta: float | None = None) -> str:
    inst, n_vertices, k_value, solve_time, nodes, obj = row[:6]
    shown_theta = theta if theta is not None else row[6]
    return (
        f"{inst}-{r}-{R}-{_theta_text(float(shown_theta))}"
        f" & {int(n_vertices):7d} & {int(k_value):7d}"
        f" & {_format_one_decimal_or_lt(float(solve_time))} & {int(nodes):7d} & {_format_one_decimal_or_lt(float(obj))}"
    )


def render_unsolved_grouped_tex(solved: dict[tuple[int, int, float], list[Sequence[Any]]]) -> str:
    lines = [
        r"\begin{tabular}{cccrrr@{\hspace{20pt}}cccrrr}",
        r"\toprule",
        r"\multicolumn{1}{r}{\idfull}",
        r"& \multicolumn{1}{r}{\V}",
        r"& \multicolumn{1}{r}{\K}",
        r"&  \tbltime &  \tblnode &  \tblobj & \multicolumn{1}{r}{\idfull}",
        r"& \multicolumn{1}{r}{\V}",
        r"& \multicolumn{1}{r}{\K}",
        r"&  \tbltime &  \tblnode &  \tblobj \\",
        r"\midrule",
    ]
    for theta in [0.2, 0.5, 0.8]:
        lines.append(r"\multicolumn{12}{c}{$\theta = %s$} \\" % _theta_text(theta))
        lines.append(r"\midrule")
        left = solved.get((5, 20, theta), [])
        right = solved.get((10, 25, theta), [])
        for idx in range(max(len(left), len(right))):
            left_cells = _unsolved_side(left[idx], 5, 20, theta) if idx < len(left) else " & & & & & "
            right_cells = _unsolved_side(right[idx], 10, 25, theta) if idx < len(right) else " & & & & & "
            lines.append(f"{left_cells} & {right_cells} \\\\")
        if theta < 0.8:
            lines.append(r"\addlinespace")
    lines.extend([r"\bottomrule", r"\end{tabular}"])
    return "\n".join(lines) + "\n"


def render_unsolved_original_tex(solved: dict[tuple[int, int, float], list[Sequence[Any]]]) -> str:
    rows = []
    for theta in [0.2, 0.5, 0.8]:
        for r, R in [(5, 20), (10, 25)]:
            rows.extend((r, R, row) for row in solved.get((r, R, theta), []))

    split_at = (len(rows) + 1) // 2
    left = rows[:split_at]
    right = rows[split_at:]

    lines = [
        r"\begin{tabular}{cccrrr@{\hspace{20pt}}cccrrr}",
        "\t" + r"\toprule",
        "\t" + r"\multicolumn{1}{r}{\idfull}",
        "\t" + r"& \multicolumn{1}{r}{\V}",
        "\t" + r"& \multicolumn{1}{r}{\K}",
        "\t" + r"&  \tbltime &  \tblnode &  \tblobj & \multicolumn{1}{r}{\idfull}",
        "\t" + r"& \multicolumn{1}{r}{\V}",
        "\t" + r"& \multicolumn{1}{r}{\K}",
        "\t" + r"&  \tbltime &  \tblnode &  \tblobj \\",
        "\t" + r"\midrule",
    ]
    for idx in range(max(len(left), len(right))):
        left_cells = _unsolved_side(left[idx][2], left[idx][0], left[idx][1]) if idx < len(left) else r" &  &  &  &  &  "
        right_cells = _unsolved_side(right[idx][2], right[idx][0], right[idx][1]) if idx < len(right) else r" &  &  &  &  &  "
        lines.append(f"\t{left_cells}    & {right_cells} \\\\")
    lines.extend(["\t" + r"\bottomrule", r"\end{tabular}"])
    return "\n".join(lines) + "\n"


def write_unsolved_csv(path: Path, solved: dict[tuple[int, int, float], list[Sequence[Any]]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(["id", "r", "R", "theta", "|V|", "K", "time", "node", "obj"])
        for key in sorted(solved):
            r, R, theta = key
            for inst, n_vertices, k_value, solve_time, nodes, obj in solved[key]:
                writer.writerow([inst, r, R, theta, n_vertices, k_value, f"{solve_time:.1f}", nodes, f"{obj:.2f}"])


def format_positive_gap(value: float | None, proven: bool = True) -> str:
    if value is None or value <= 0:
        return "    --"
    suffix = "" if proven else "$^*$"
    if value < 0.1:
        return rf" $<$0.1{suffix}"
    return f" {value:6.1f}{suffix}"


def render_two_panel_theta_gap_table(rows: Sequence[dict[str, Any]], theta_values: Sequence[str]) -> str:
    """Render the two-panel id/K/theta gap table used by co-location summaries."""
    theta_headers = " & ".join(rf"$\theta={theta}$" for theta in theta_values)
    lines = [
        r"\begin{tabular}{crrrr|crrrr}",
        r"\toprule",
        rf"id & $K$ & {theta_headers} & id & $K$ & {theta_headers} \\",
        r"\midrule",
    ]
    half = (len(rows) + 1) // 2
    left = rows[:half]
    right = rows[half:]
    for idx in range(half):
        cells: list[str] = []
        for side in (left, right):
            if idx >= len(side):
                cells.extend([""] * (2 + len(theta_values)))
                continue
            row = side[idx]
            cells.append(f"{row['data']} & {row['k']}")
            for theta in theta_values:
                cells.append(format_positive_gap(row.get(f"gap_{theta}"), row.get(f"proven_{theta}", True)))
        width = 2 + len(theta_values)
        lines.append(" & ".join(cells[:width]) + " & " + " & ".join(cells[width:]) + r" \\")
    lines.extend([r"\bottomrule", r"\end{tabular}"])
    return "\n".join(lines) + "\n"
