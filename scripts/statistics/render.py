#!/usr/bin/env python3
"""Render the paper-facing MPCLP figures and tables from recorded statistics.

The numbers come from the awk programs in ``scripts/statistics/awk`` and are read
back from small CSV files; this module only turns those numbers into the
published EPS/PNG/PDF figures and LaTeX tables.  The drawing sequence mirrors
the recipe contract in ``recipe.yaml`` and ``style.yaml`` call by call, so a
figure is fully determined by the recipe, the style registry, and the recorded
statistics.
"""

from __future__ import annotations

import csv
import logging
from pathlib import Path
import subprocess
import warnings

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.ticker import PercentFormatter

ROOT = Path(__file__).resolve().parent
AWK = ROOT / "awk"

class TransparencyNotice(logging.Filter):
    """Drop the one notice the EPS backend logs for every published figure.

    The styles deliberately draw a translucent legend frame, and the published
    EPS has always been written that way, so the notice is not news on a rebuild.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        return "does not support transparency" not in record.getMessage()


logging.getLogger("matplotlib.backends.backend_ps").addFilter(TransparencyNotice())

PRESETS = {
    "cdf": "empirical-cdf",
    "empirical_profile": "empirical-profile",
    "censored_empirical_profile": "censored-empirical-profile",
    "grouped_categorical_histogram": "grouped-categorical-histogram",
    "gap_profile": "gap-profile",
}


# Column the solver records its runtime in, and therefore the column a
# declared time limit is checked against.
RUNTIME_COLUMN = "runtime_seconds"


class ArtifactError(RuntimeError):
    """Raised when a recipe asks for something this renderer does not provide."""


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

def awk_command(script: str, *, awk: str = "awk", **parameters: object) -> list[str]:
    """Assemble the command line of one statistics program.

    ``awk`` selects the implementation, because the statistics must give the
    same answer under every awk the project claims to support.
    """
    command = [awk]
    for name, value in parameters.items():
        command += ["-v", f"{name}={'' if value is None else value}"]
    return command + ["-f", str(AWK / "common.awk"), "-f", str(AWK / script)]


def run_awk(script: str, output: Path, *, awk: str = "awk", **parameters: object) -> Path:
    """Run one statistics program and return the file it wrote."""
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w") as handle:
        result = subprocess.run(awk_command(script, awk=awk, **parameters), stdout=handle,
                                stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise ArtifactError(f"{script} failed: {result.stderr.strip()}")
    return output


def read_rows(path: Path, delimiter: str = ",") -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle, delimiter=delimiter))


def filter_expression(filters: dict | None) -> str:
    """Encode a figure filter as the "column=value" list the awk reader takes."""
    return ";".join(f"{column}={value}" for column, value in (filters or {}).items())


def figure_values(spec: dict, source: Path, directory: Path, *, awk: str = "awk") -> Path:
    """Export the raw per-record values one figure is drawn from."""
    return run_awk("series_values.awk", directory / f"{spec['name']}.values.tsv", awk=awk,
                   input=source, x=spec["x"], group=spec.get("group", ""),
                   instance=spec.get("instance_key", "instance"),
                   filters=filter_expression(spec.get("filter")))


# ---------------------------------------------------------------------------
# Figures
# ---------------------------------------------------------------------------

def series_measurements(path: Path) -> dict[str, list[str]]:
    """Raw values of every series in record order; "" is a record without one."""
    series: dict[str, list[str]] = {}
    for row in read_rows(path, delimiter="\t"):
        series.setdefault(row["series"], []).append(row["value"])
    return series


def draw_order(series, declared) -> list[str]:
    """Declared series first, then the remaining ones in order of appearance."""
    names = [str(value) for value in declared]
    return [name for name in names if name in series] + \
           [name for name in series if name not in names]


def profile_vertices(measurements: list[str], spec: dict) -> dict[str, tuple[list, list]]:
    """Boundary-augmented staircase and observation markers of one series.

    The profile is normalised by the number of measured values, so a
    right-censored series keeps its censored records in the denominator.
    """
    limits = spec.get("x_limits") or [None, None]
    boundary = spec.get("profile_boundary", {})
    censor = spec.get("right_censoring")
    unit = spec.get("y_unit", "fraction")
    measured = [float(text) for text in measurements if text != ""]
    observed = [value for value in measured if censor is None or value < censor]
    if boundary.get("clip_values_to_x_limits"):
        observed = [min(max(value, limits[0]), limits[1]) for value in observed]
    observed.sort()

    def share(count: int) -> float:
        if unit == "count":
            return float(count)
        if unit == "percentage":
            return count / len(measured) * 100
        return count / len(measured)

    event = ([], [])
    step = ([], [])
    for index, value in enumerate(observed, start=1):
        event[0].append(value)
        event[1].append(share(index))
    if boundary.get("start_at_xmin"):
        step[0].append(float(limits[0]))
        step[1].append(0.0)
    for index, value in enumerate(observed, start=1):
        step[0].append(value)
        step[1].append(share(index))
    if boundary.get("extend_to_xmax"):
        step[0].append(float(limits[1]))
        step[1].append(share(len(observed)) if observed else 0.0)
    return {"event": event, "step": step}


def grouped_vertices(measurements: dict[str, list[str]], spec: dict) \
        -> list[tuple[str, dict[str, tuple[list, list]]]]:
    """Profile of every series, in draw order."""
    order = draw_order(measurements, spec["style"].get("series", {}).get("order", []))
    return [(name, profile_vertices(measurements[name], spec)) for name in order]


def grouped_bars(measurements: dict[str, list[str]], spec: dict) -> list[tuple[str, list[float]]]:
    """Bar heights of every series, in draw order.

    The normaliser divides by every record of the series, not only by the
    records that carry a category, which is what the published percentages use.
    """
    categories = [float(value) for value in spec["categories"]]
    normalization = spec.get("normalization", "percentage")
    order = draw_order(measurements, spec["style"].get("series", {}).get("order", []))
    drawn = []
    for name in order:
        values = measurements[name]
        hits = [0.0] * len(categories)
        for text in values:
            if text == "":
                continue
            for index, category in enumerate(categories):
                if float(text) == category:
                    hits[index] += 1
                    break
        if normalization == "count" or not values:
            drawn.append((name, hits))
        elif normalization == "fraction":
            drawn.append((name, [hit / len(values) for hit in hits]))
        else:
            drawn.append((name, [hit / len(values) * 100 for hit in hits]))
    return drawn


def mathtext_context(style: dict) -> dict:
    """The mathtext overrides a style asks for; empty when it asks for none."""
    context: dict[str, str] = {}
    if style.get("mathtext_default") is not None:
        context["mathtext.default"] = str(style["mathtext_default"])
    policy = style.get("mathtext_variable_weight")
    if policy is None:
        return context
    if policy != "bold-italic":
        raise ArtifactError("mathtext_variable_weight must be 'bold-italic'.")
    context.update({
        "mathtext.default": "it",
        "mathtext.it": "DejaVu Sans:italic:weight=bold",
        "mathtext.rm": "DejaVu Sans:weight=bold",
        "mathtext.bf": "DejaVu Sans:weight=bold",
    })
    return context


def draw_figure(spec: dict, measurements: dict[str, list[str]]):
    """Draw one figure from the raw values of its series."""
    kind = PRESETS[spec["preset"]]
    style = spec.get("style", {})
    fig, ax = plt.subplots(figsize=style.get("figure_size"))
    linewidth = style.get("line_width", 1.5)
    labels = style.get("legend_labels", {})
    series_values = style.get("series", {}).get("values", {})
    series_keys = ("color", "marker", "markersize", "linestyle", "linewidth",
                   "markerfacecolor", "markeredgecolor", "markeredgewidth", "edgecolor", "alpha")
    marker_size = style.get("marker_size", 6)
    marker = style.get("marker", "o")

    def plot_options(value: str) -> dict:
        options = {"linewidth": linewidth, "marker": marker, "markersize": marker_size}
        options.update({key: series_values[value][key]
                        for key in series_keys if key in series_values[value]})
        return options

    def label_for(value: str) -> str:
        return series_values.get(value, {}).get("label", labels.get(value, value))

    legend_handles: list = []
    if kind == "grouped-categorical-histogram":
        categories = spec["categories"]
        groups = grouped_bars(measurements, spec)
        width = spec.get("bar_width", 0.8 / max(len(groups), 1))
        base_positions = list(range(len(categories)))
        for index, (label, heights) in enumerate(groups):
            offset = (index - (len(groups) - 1) / 2) * width
            options = {key: value for key, value in plot_options(label).items()
                       if key in {"color", "edgecolor", "linewidth", "alpha"}}
            ax.bar([base + offset for base in base_positions], heights, width=width,
                   label=label_for(label), **options)
        ax.set_xticks(base_positions)
        ax.set_xticklabels([str(category) for category in categories])
    else:
        boundary = spec.get("profile_boundary", {})
        events = kind == "censored-empirical-profile" and boundary.get("marker", True) is False
        for label, vertices in grouped_vertices(measurements, spec):
            options = plot_options(label)
            if not events:
                ax.step(vertices["step"][0], vertices["step"][1], where="post",
                        label=label_for(label), **options)
                continue
            # Draw the staircase without markers and the observations on top, so
            # the legend keeps the marker of the style.
            ax.step(vertices["step"][0], vertices["step"][1], where="post",
                    label=label_for(label), **{**options, "marker": None})
            legend_handles.append(Line2D([], [], label=label_for(label), **options))
            if vertices["event"][0]:
                ax.plot(vertices["event"][0], vertices["event"][1],
                        **{**options, "linestyle": "None", "label": "_nolegend_"})
        ax.set_ylabel("Empirical CDF" if kind == "censored-empirical-profile"
                      else "Empirical profile")
    finish_figure(fig, ax, spec, style, legend_handles)
    return fig


def finish_figure(fig, ax, spec: dict, style: dict, legend_handles: list) -> None:
    """Apply the axis, legend, grid, font, and layout contract of the recipe."""
    ax.set_xlabel(spec.get("x_label", spec["x"]))
    if spec.get("y_label"):
        ax.set_ylabel(spec["y_label"])
    if spec.get("xscale"):
        ax.set_xscale(spec["xscale"])
    if spec.get("x_limits"):
        ax.set_xlim(spec["x_limits"])
    if spec.get("x_ticks"):
        ax.set_xticks(spec["x_ticks"])
    if spec.get("x_tick_labels"):
        ax.set_xticklabels(spec["x_tick_labels"])
    if spec.get("y_limits"):
        ax.set_ylim(spec["y_limits"])
    if spec.get("y_as_percent"):
        ax.yaxis.set_major_formatter(PercentFormatter(xmax=1))
    if spec.get("y_ticks"):
        ax.set_yticks(spec["y_ticks"])
    if spec.get("y_tick_labels"):
        ax.set_yticklabels(spec["y_tick_labels"])
    font_size = style.get("font_size")
    font_weight = style.get("font_weight", "normal")
    if spec.get("group"):
        arguments = {"prop": {"size": style.get("legend_font_size", font_size),
                              "weight": style.get("legend_font_weight", font_weight)},
                     **style.get("legend", {})}
        ax.legend(handles=legend_handles or None, **arguments)
    ax.grid(alpha=style.get("grid_alpha", .25))
    if font_size:
        for item in [ax.title, ax.xaxis.label, ax.yaxis.label,
                     *ax.get_xticklabels(), *ax.get_yticklabels()]:
            item.set_fontsize(font_size)
            item.set_fontweight(font_weight)
    layout = spec.get("layout", {})
    if layout.get("tight", True):
        fig.tight_layout()
    if layout.get("subplots_adjust") is not None:
        fig.subplots_adjust(**layout["subplots_adjust"])


def render_figure(spec: dict, values: Path, out: Path) -> list[Path]:
    """Draw one figure from its raw values and write every requested format."""
    context = mathtext_context(spec.get("style", {}))
    measurements = series_measurements(values)
    with matplotlib.rc_context(context):
        fig = draw_figure(spec, measurements)
    options = {"bbox_inches": "tight", **spec.get("savefig", {})}
    outputs = []
    with matplotlib.rc_context(context), warnings.catch_warnings():
        warnings.filterwarnings("ignore", message=".*does not support transparency.*")
        for fmt in spec.get("formats", ["png"]):
            path = out / f"{spec['name']}.{fmt}"
            fig.savefig(path, **{**options, "dpi": 300 if fmt == "png" else None})
            outputs.append(path)
    plt.close(fig)
    return outputs


# ---------------------------------------------------------------------------
# Comparison tables
# ---------------------------------------------------------------------------

def order_literal(value: object) -> str:
    """Type-tag one declared row-order value so the awk reader compares it typed."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return "s:" + str(value)
    return "n:" + repr(value)


def text_literal(value: object) -> str:
    return "-" if value is None else str(value)


def metric_reference(metric) -> dict:
    return {"id": metric} if isinstance(metric, str) else metric


def metric_arguments(formatter) -> list[str]:
    """Flat "key=value" arguments of one metric formatter."""
    if isinstance(formatter, str):
        formatter = {"type": formatter}
    arguments = []
    for key, value in formatter.items():
        if key == "type" or value is None:
            continue
        arguments.append(f"{key}={int(value) if isinstance(value, bool) else value}")
    return arguments


def operation_literal(value: object) -> str:
    """Row label of one dimension: a template, or the instance count."""
    if isinstance(value, dict):
        if value.get("operation") != "instance_count":
            raise ArtifactError(f"Unsupported row value operation: {value.get('operation')}")
        return "op:instance_count"
    return str(value)


def table_specification(spec: dict) -> str:
    """Compile a comparison-table recipe into the flat contract awk reads."""
    rows = spec.get("rows", {})
    dimensions = rows.get("display_columns", rows.get("group_by", []))
    sections = rows.get("sections") or [rows]
    latex = spec.get("latex", {})
    header = latex.get("header", {})
    blocks = spec["method_blocks"]
    metrics = spec["metrics"]
    columns = len(dimensions) + sum(len(block["metrics"]) for block in blocks)
    wrap = latex.get("row_label_multicolumn", [])
    wrap = dimensions if wrap is True else wrap

    lines = [
        f"instance\t{spec.get('instance_key', 'instance')}",
        f"dimensions\t{','.join(dimensions)}",
        f"empty\t{text_literal(latex.get('empty_value', '--'))}",
        "column_format\t" + latex.get("column_format",
                                       "l" * len(dimensions) + "r" * (columns - len(dimensions))),
        f"multirow\t{int(bool(header.get('multirow_row_labels', False)))}",
        f"top_rule\t{int(bool(latex.get('top_rule', True)))}",
        f"mid_rule\t{int(bool(latex.get('mid_rule', True)))}",
        f"bottom_rule\t{int(bool(latex.get('bottom_rule', True)))}",
        f"cmidrule_trim\t{header.get('cmidrule_trim') or 'none'}",
    ]
    for dimension, macro in latex.get("row_labels", {}).items():
        lines.append(f"row_label\t{dimension}\t{macro}")
    for dimension in wrap:
        lines.append(f"multicolumn\t{dimension}")
    for metric_id, metric in metrics.items():
        lines.append("\t".join(["metric", metric_id, metric["field"],
                                 metric.get("aggregation", "arithmetic_mean"),
                                 metric.get("cohort", "all"),
                                 metric.get("fallback_cohort") or "-"]))
        lines.append("\t".join(["metric_label", metric_id, metric.get("label", metric_id)]))
        formatter = metric.get("format", {"type": "number", "precision": 3})
        arguments = metric_arguments(formatter)
        if isinstance(formatter, dict) and \
                formatter.get("type") in {"decimal_with_small_positive",
                                          "time_with_limit_and_small_positive"} \
                and "below" not in formatter:
            arguments.append(f"below=$<${formatter.get('threshold', 0.1):g}")
        lines.append("\t".join(["metric_format", metric_id,
                                 formatter if isinstance(formatter, str)
                                 else formatter.get("type", "number"), *arguments]))
    for cohort_id, cohort in spec.get("cohorts", {}).items():
        lines.append("\t".join(["cohort", cohort_id, cohort.get("type", "all"),
                                 cohort.get("field") or "-", text_literal(cohort.get("equals")),
                                 ",".join(cohort["methods"]) if cohort.get("methods") else "-"]))
    for block in blocks:
        for metric in block["metrics"]:
            reference = metric_reference(metric)
            metric_spec = metrics[reference["id"]]
            lines.append("\t".join(["cell", block["method"], reference["id"],
                                     reference.get("cohort") or metric_spec.get("cohort", "all"),
                                     reference.get("fallback_cohort")
                                     or metric_spec.get("fallback_cohort") or "-"]))
    for block in blocks:
        lines.append("\t".join(["block", block["method"], block["label"],
                                 ",".join(metric_reference(metric)["id"]
                                          for metric in block["metrics"])]))
    for index, section in enumerate(sections, start=1):
        order = section.get("order", {})
        declared = ";".join(f"{dimension}:{order_literal(value)}"
                            for dimension, values in order.items() for value in values)
        lines.append("\t".join(["section", ",".join(section.get("group_by", [])), declared or "-"]))
        for dimension in dimensions:
            lines.append("\t".join(["section_value", str(index), dimension,
                                     operation_literal(section.get("values", {})
                                                       .get(dimension, "{" + dimension + "}"))]))
        for method, metric_ids in section.get("blank_metrics", {}).items():
            lines.append("\t".join(["section_blank", str(index), method, ",".join(metric_ids)]))
    for index, summary in enumerate(spec.get("summary_rows", []), start=1):
        filters = ";".join(f"{column}={value}" for column, value in summary.get("filter", {}).items())
        lines.append("\t".join(["summary", str(index), filters or "-"]))
        for dimension, value in summary.get("display", {}).items():
            lines.append("\t".join(["summary_display", str(index), dimension,
                                     operation_literal(value)]))
        lines.append(f"summary_label\t{index}\t{summary.get('label', 'Total')}")
        lines.append(f"summary_midrule\t{index}\t{int(bool(summary.get('before_midrule')))}")
        keep = summary.get("keep")
        lines.append(f"summary_has_keep\t{index}\t{int(keep is not None)}")
        if keep is not None:
            for block in blocks:
                allowed = keep if isinstance(keep, list) else keep.get(block["method"], [])
                lines.append(f"summary_keep\t{index}\t{block['method']}\t{','.join(allowed) or '-'}")
        blank = summary.get("blank")
        lines.append(f"summary_has_blank\t{index}\t{int(blank is not None)}")
        if blank is not None:
            for block in blocks:
                blocked = blank if isinstance(blank, list) else blank.get(block["method"], [])
                lines.append(f"summary_blank\t{index}\t{block['method']}\t{','.join(blocked) or '-'}")
    return "\n".join(lines) + "\n"


def render_comparison_table(spec: dict, source: Path, directory: Path, target: Path, *,
                            awk: str = "awk") -> Path:
    """Compute one comparison table and write its LaTeX."""
    name = spec.get("id", spec.get("name", "comparison-table"))
    directory.mkdir(parents=True, exist_ok=True)
    specification = directory / f"{name}.spec.tsv"
    specification.write_text(table_specification(spec))
    recorded = run_awk("comparison_table.awk", directory / f"{name}.cells.tsv", awk=awk,
                       input=source, spec=specification)
    text = recorded.read_text()
    if not text:
        raise ArtifactError(f"{name}: comparison_table.awk produced no table")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    return target


# ---------------------------------------------------------------------------
# Record-panel tables
# ---------------------------------------------------------------------------

def record_panel_specification(spec: dict) -> str:
    """Compile a record-panel recipe into the flat contract awk reads."""
    side = spec.get("side_by_side", {})
    separator = side.get("separator", r"@{\qquad}")
    lines = [
        f"order_key\t{spec.get('order_key') or '-'}",
        f"empty\t{spec.get('latex', {}).get('empty_value', '--')}",
        f"split_after\t{side['split_after']}",
        f"separator\t{separator}",
    ]
    for column in spec["columns"]:
        formatter = column.get("format")
        if isinstance(formatter, str):
            kind, digits = formatter, 0
        else:
            formatter = formatter or {}
            kind, digits = formatter.get("type", ""), int(formatter.get("digits", 0))
        lines.append("\t".join(["column", column["field"],
                                 column.get("label", column["field"]),
                                 column.get("align", "l"), kind, f"digits={digits}"]))
    return "\n".join(lines) + "\n"


def render_record_panel_table(spec: dict, source: Path, directory: Path, target: Path, *,
                              awk: str = "awk") -> Path:
    """List records side by side and write the finished LaTeX."""
    name = spec.get("id", spec.get("name", "record-panel-table"))
    directory.mkdir(parents=True, exist_ok=True)
    specification = directory / f"{name}.spec.tsv"
    specification.write_text(record_panel_specification(spec))
    recorded = run_awk("record_panel_table.awk", directory / f"{name}.rows.tsv", awk=awk,
                       input=source, spec=specification)
    text = recorded.read_text()
    if not text:
        raise ArtifactError(f"{name}: record_panel_table.awk produced no table")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    return target


# ---------------------------------------------------------------------------
# Dataset checks
# ---------------------------------------------------------------------------

def check_specification(checks: dict, solved: dict | None) -> str:
    """Translate the checks of one dataset into the awk check contract."""
    lines = []
    if checks.get("required_columns"):
        lines.append("required\t" + ",".join(checks["required_columns"]))
    if checks.get("unique_by"):
        lines.append("unique\t" + ",".join(checks["unique_by"]))
    for dimension, values in (checks.get("complete_grid") or {}).items():
        lines.append(f"grid\t{dimension}=" + ",".join(str(value) for value in values))
    if checks.get("expected_instance_count") is not None:
        lines.append(f"expected_instances\t{checks['expected_instance_count']}")
    if checks.get("time_limit") is not None:
        lines.append(f"time_limit\t{checks['time_limit']}")
        lines.append(f"tolerance\t{checks.get('time_limit_tolerance', 0)}")
        lines.append(f"runtime\t{RUNTIME_COLUMN}")
    if solved:
        column = solved.get("column", "solved")
        lines.append(f"derived\t{column}\t{solved['field']}\t" +
                     ",".join(str(value) for value in solved["values"]))
    return "\n".join(lines) + "\n"


def check_dataset(source: Path, checks: dict, solved: dict | None, directory: Path) -> str:
    """Validate one dataset and return the check report of the run."""
    name = source.stem
    directory.mkdir(parents=True, exist_ok=True)
    specification = directory / f"{name}.checks.tsv"
    specification.write_text(check_specification(checks, solved))
    recorded = run_awk("dataset_check.awk", directory / f"{name}.check.txt",
                       input=source, spec=specification, instance="instance")
    summary = {"rows": "n/a", "instances": "n/a", "duplicates": "0", "missing": "0"}
    errors, warnings = [], []
    for line in recorded.read_text().splitlines():
        key, _, message = line.partition("\t")
        if key in summary:
            summary[key] = message
        elif key == "error":
            errors.append(message)
        elif key == "warning":
            warnings.append(message)
    lines = [
        "MPCLP artifact check report",
        "=" * 24,
        f"Rows: {summary['rows']}",
        f"Instances: {summary['instances']}",
        f"Duplicate records: {summary['duplicates']}",
        f"Missing combinations: {summary['missing']}",
        "",
        "Validation " + ("failed." if errors else "passed."),
    ]
    if errors:
        lines += ["", "Errors:", *[f"- {message}" for message in errors]]
    if warnings:
        lines += ["", "Warnings:", *[f"- {message}" for message in warnings]]
    return "\n".join(lines) + "\n"
