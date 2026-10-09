#!/usr/bin/env python3
"""Rebuild the MPCLP paper figures and tables from the public summary data.

The recipes in ``recipe.yaml`` and ``tables/*.recipe.yaml`` declare what every
artifact is; ``render.py`` turns the recorded statistics into the published
figures and tables.  No external statistics or rendering engine is involved.
"""

from __future__ import annotations

import argparse
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import yaml

ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parents[1]
# The generated trees and the paper-facing files all live in one place.
OUTPUT = REPOSITORY / "output" / "artifacts"
INPUTS = OUTPUT / "inputs"
sys.path.insert(0, str(ROOT))

import render  # noqa: E402  (sibling module of this driver)


def run_step(command: list[str], description: str, **kwargs) -> int:
    """Run one build step, showing its output only when it fails."""
    result = subprocess.run(command, capture_output=True, text=True, check=False, **kwargs)
    if result.returncode:
        print(f"{description}: failed with exit status {result.returncode}", file=sys.stderr)
        if result.stdout:
            print(result.stdout, end="", file=sys.stderr)
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
    return result.returncode


def read_yaml(path: Path) -> dict:
    value = yaml.safe_load(path.read_text()) or {}
    if not isinstance(value, dict):
        raise ValueError(f"Expected a YAML mapping: {path}")
    return value


def compile_recipe(
    recipe: dict,
    styles: dict,
    artifact_ids: set[str] | None = None,
    *,
    data_directory: Path | None = None,
    output_directory: Path | None = None,
) -> dict:
    datasets = recipe.get("data", {})
    figures, tables = [], []
    selected_input = None
    checks = None

    for artifact in recipe.get("paper", {}).get("figures", []):
        if artifact_ids and artifact["id"] not in artifact_ids:
            continue
        dataset = datasets[artifact["input"]]
        selected_input = dataset if selected_input is None else selected_input
        if dataset != selected_input:
            raise ValueError("This initial MPCLP adapter supports one input dataset per build.")
        style_name = artifact.get("style")
        figures.append({
            "name": artifact["id"],
            "preset": artifact["preset"],
            "x": artifact.get("x", "runtime_seconds"),
            "group": artifact.get("group"),
            "filter": artifact.get("filter", {}),
            "x_label": artifact.get("labels", {}).get("x"),
            "y_label": artifact.get("labels", {}).get("y"),
            "formats": artifact.get("formats", ["pdf"]),
            "style": styles[style_name],
            **{
                key: artifact[key]
                for key in (
                    "right_censoring", "profile_boundary", "xscale", "x_limits",
                    "x_ticks", "x_tick_labels", "y_limits", "y_ticks",
                    "y_tick_labels", "y_as_percent", "y_unit", "categories",
                    "bar_width", "normalization", "layout", "savefig",
                )
                if key in artifact
            },
        })

    for artifact in recipe.get("paper", {}).get("tables", []):
        if artifact_ids and artifact["id"] not in artifact_ids:
            continue
        dataset = datasets[artifact["input"]]
        selected_input = dataset if selected_input is None else selected_input
        if dataset != selected_input:
            raise ValueError("This initial MPCLP adapter supports one input dataset per build.")
        tables.append({
            "name": artifact["id"],
            "group_by": artifact["rows"],
            "sort_by": artifact["rows"],
            "rename": artifact.get("labels", {}),
            "columns": artifact["columns"],
            "format": "tex",
        })

    if selected_input is None:
        raise ValueError("Recipe contains no figures or tables.")
    return {
        "project": recipe.get("project", "MPCLP"),
        "input": {
            "files": [str(((data_directory or INPUTS) / Path(selected_input["source"]).name).resolve())],
            "solved": selected_input.get("solved"),
        },
        "checks": selected_input.get("checks", {}),
        "output": {"directory": str((output_directory or OUTPUT).resolve())},
        "figures": figures,
        "tables": tables,
    }


def build_artifacts(config: dict, output_directory: Path | None = None) -> tuple[list[Path], list[Path]]:
    """Validate the dataset, then render every figure and table of one config."""
    out = Path(output_directory or OUTPUT).resolve()
    out.mkdir(parents=True, exist_ok=True)
    statistics = out / "stats"
    sources = [Path(item) for item in config.get("input", {}).get("files", [])]
    if sources:
        report = render.check_dataset(sources[0], config.get("checks", {}),
                                      config.get("input", {}).get("solved"), statistics)
        (out / "check-report.txt").write_text(report)
    figures = []
    for spec in config.get("figures", []):
        if not sources:
            raise SystemExit(f"Figure {spec['name']} needs a top-level input.")
        values = render.figure_values(spec, sources[0], statistics)
        figures.extend(render.render_figure(spec, values, out))
    tables = [render_table(spec, sources, out, statistics) for spec in config.get("tables", [])]
    return figures, tables


def declaration(path: str) -> Path:
    """Resolve a path a recipe declares, relative to the repository root."""
    resolved = Path(path)
    return resolved if resolved.is_absolute() else (ROOT.parents[1] / resolved).resolve()


def render_table(spec: dict, sources: list[Path], out: Path, statistics: Path) -> Path:
    """Render one table of a compiled config to the path the recipe declares."""
    kind = spec.get("type", "table")
    if kind == "comparison-table":
        source = declaration(spec.get("input")) if "input" in spec else sources[0]
        target = Path(spec["output"]) if "output" in spec else out / f"{spec['id']}.tex"
        return render.render_comparison_table(spec, source, statistics, target)
    if kind == "record-panel-table":
        source = declaration(spec["input"])
        target = Path(spec.get("output") or f"{spec['id']}.tex")
        return render.render_record_panel_table(spec, source, statistics, target)
    raise SystemExit(f"Unsupported table type: {kind}")


def build_table(
    recipe_name: str,
    input_path: Path,
    output_path: Path,
    output_directory: Path,
) -> Path:
    """Render one table recipe against an explicit input and output path."""
    spec = read_yaml(ROOT / "tables" / recipe_name)["tables"][0]
    spec["input"] = str(input_path.resolve())
    spec["output"] = str(output_path.resolve())
    out = output_directory.resolve()
    out.mkdir(parents=True, exist_ok=True)
    return render_table(spec, [], out, out / "stats")


def build_recipe(recipe: dict, styles: dict, artifact_ids: set[str], *,
                 data_directory: Path | None = None,
                 output_directory: Path | None = None) -> tuple[list[Path], list[Path]]:
    """Compile one recipe selection and render it."""
    config = compile_recipe(recipe, styles, artifact_ids,
                            data_directory=data_directory, output_directory=output_directory)
    return build_artifacts(config, config["output"]["directory"])


def check_recipe(recipe: dict, styles: dict, artifact_ids: set[str], *,
                 data_directory: Path | None = None,
                 output_directory: Path | None = None) -> int:
    """Validate the selected dataset without drawing anything."""
    config = compile_recipe(recipe, styles, artifact_ids,
                            data_directory=data_directory, output_directory=output_directory)
    sources = [Path(item) for item in config["input"]["files"]]
    report = render.check_dataset(sources[0], config.get("checks", {}),
                                  config["input"].get("solved"), Path(config["output"]["directory"]) / "stats")
    print(report, end="")
    return 1 if "Validation failed." in report else 0


def facility_mixture_view(recipe: dict, styles: dict) -> tuple[dict, dict]:
    """Apply the new T2's share encoding without altering the paper YAML files."""
    recipe, styles = deepcopy(recipe), deepcopy(styles)
    for dataset_name in ("t2_figure2", "t2_figure3", "t2_figure4", "t2_figure5_gap"):
        recipe["data"][dataset_name]["checks"]["complete_grid"]["p_s"] = [1090, 5050, 9010]
    line_values = {
        "1090": {"color": "red", "marker": "o", "markersize": 7, "markerfacecolor": "none", "markeredgecolor": "red", "markeredgewidth": 1, "label": r"$\mathbf{10\%}$ low-$\mathbfit{p_i}$ sites"},
        "5050": {"color": "blue", "marker": "s", "markersize": 7, "markerfacecolor": "none", "markeredgecolor": "blue", "markeredgewidth": 1, "label": r"$\mathbf{50\%}$ low-$\mathbfit{p_i}$ sites"},
        "9010": {"color": "green", "marker": "D", "markersize": 7, "markerfacecolor": "none", "markeredgecolor": "green", "markeredgewidth": 1, "label": r"$\mathbf{90\%}$ low-$\mathbfit{p_i}$ sites"},
    }
    histogram_values = {
        key: {"color": value["color"], "edgecolor": value["color"], "alpha": 0.75, "label": value["label"]}
        for key, value in line_values.items()
    }
    for style_name in ("ijoc-figure2-ps", "ijoc-figure3-ps"):
        styles[style_name]["series"] = {"order": ["1090", "5050", "9010"], "values": line_values}
    styles["ijoc-figure3-ps-histogram"]["series"] = {"order": ["1090", "5050", "9010"], "values": histogram_values}
    return recipe, styles


def run_facility_adapter(data_directory: Path, input_manifest: Path | None = None) -> int:
    data_directory.mkdir(parents=True, exist_ok=True)
    return run_step([
        sys.executable, str(ROOT / "adapters" / "export_facility_mixture_t2.py"),
        "--input-manifest", str(input_manifest or ROOT / "t2-inputs.yaml"),
        "--output-dir", str(data_directory),
    ], "export_facility_mixture_t2.py")


def build_facility_table3(data_directory: Path, output_directory: Path) -> int:
    """Render the comparison-table recipe for Table 3 against adapter data."""
    build_table("table3.recipe.yaml", data_directory / "t3_foursettings_table3.csv",
                output_directory / "T3-FourSettings-Table3.tex", output_directory)
    return 0


def review_asset(name: str) -> str:
    """Name an artifact as it sits next to the review document that includes it."""
    return name


def write_facility_review(output_directory: Path) -> None:
    """Write the review document that assembles the facility-mixture artifacts."""
    path = review_asset
    source_text = rf"""\documentclass[10pt]{{article}}
\usepackage[margin=0.55in]{{geometry}}
\usepackage{{graphicx,caption,newtxtext,newtxmath,booktabs,multirow,xspace}}
\setlength{{\parindent}}{{0pt}}
\captionsetup{{font=small,labelfont=bf}}
\newcommand{{\panel}}[2]{{\begin{{minipage}}[b]{{0.48\textwidth}}\centering\includegraphics[width=\linewidth]{{#1}}\\[-2pt]\small (#2)\end{{minipage}}}}
\newcommand{{\paneliii}}[2]{{\begin{{minipage}}[b]{{0.32\textwidth}}\centering\includegraphics[width=\linewidth]{{#1}}\\[-2pt]\small (#2)\end{{minipage}}}}
\newcommand{{\I}}{{\mathcal{{I}}}}
\newcommand{{\testBin}}{{\texttt{{B\&C-B}}\xspace}}
\newcommand{{\testInt}}{{\texttt{{B\&C-I}}\xspace}}
\newcommand{{\testLiterature}}{{\texttt{{\'{{A}}S19}}\xspace}}
\newcommand{{\testbasicInt}}{{\texttt{{bB\&C-I}}\xspace}}
\newcommand{{\testbasicIntStr}}{{\texttt{{bB\&C-I+E}}\xspace}}
\newcommand{{\testbasicIntVI}}{{\texttt{{bB\&C-I+L}}\xspace}}
\newcommand{{\testbasicIntStrVI}}{{\texttt{{bB\&C-I+E+L}}\xspace}}
\newcommand{{\tblgroup}}{{\texttt{{id-$|\I|$-$K$}}\xspace}}
\newcommand{{\tblndata}}{{\texttt{{\#}}\xspace}}
\newcommand{{\tblnvar}}{{\texttt{{V}}\xspace}}
\newcommand{{\tblnsol}}{{\texttt{{S}}\xspace}}
\newcommand{{\tbltime}}{{\texttt{{T}}\xspace}}
\newcommand{{\tblnode}}{{\texttt{{N}}\xspace}}
\newcommand{{\tblgap}}{{\texttt{{G}}(\texttt{{\%}})\xspace}}
\newcommand{{\tblrgap}}{{\texttt{{LPG}}(\texttt{{\%}})\xspace}}
\newcommand{{\tblinstances}}{{\texttt{{\#Instances}}\xspace}}
\newcommand{{\tblaver}}{{\texttt{{Aver.}}\xspace}}
\newcommand{{\idfull}}{{\texttt{{id-$r$-$R$-$\theta$}}\xspace}}
\newcommand{{\V}}{{\texttt{{$|\I|$}}\xspace}}
\newcommand{{\K}}{{\texttt{{$K$}}\xspace}}
\newcommand{{\tblobj}}{{\texttt{{OPT}}\xspace}}
\newcommand{{\TL}}{{\texttt{{TL}}\xspace}}
\begin{{document}}
\begin{{center}}\Large\bfseries Figures and tables for the paper ``An efficient branch-and-cut algorithm for the multiple probabilistic covering location problem''\end{{center}}
\begin{{center}}\begin{{minipage}}{{0.98\textwidth}}\centering\scriptsize
\setlength{{\tabcolsep}}{{2.5pt}}\renewcommand{{\arraystretch}}{{0.95}}
\captionof{{table}}{{Overall performance comparison of settings \testBin and \testInt on testset T1.}}
\resizebox{{\textwidth}}{{!}}{{\input{{{path('T1-BinInt-Table1.tex')}}}}}
\end{{minipage}}\end{{center}}
\clearpage
\begin{{figure}}[!ht]\centering
\panel{{{path('Figure1-T1-Time-Profile.eps')}}}{{a}}\hfill
\panel{{{path('Figure1-T1-Gap-Profile.eps')}}}{{b}}
\caption{{Performance profiles of the CPU time and the end gap returned by settings \testBin and \testInt on testset T1.}}\end{{figure}}
\clearpage
\begin{{center}}\begin{{minipage}}{{0.98\textwidth}}\centering\scriptsize
\setlength{{\tabcolsep}}{{2.5pt}}\renewcommand{{\arraystretch}}{{0.95}}
\captionof{{table}}{{Performance comparison of settings \testbasicInt, \testbasicIntStr, \testbasicIntVI, and \testbasicIntStrVI on testset T1.}}
\resizebox{{\textwidth}}{{!}}{{\input{{{path('T2-FourSettings-Table2.tex')}}}}}
\end{{minipage}}\end{{center}}
\clearpage
\setcounter{{table}}{{2}}
\begin{{center}}\begin{{minipage}}{{0.98\textwidth}}\centering\scriptsize
\setlength{{\tabcolsep}}{{2.5pt}}\renewcommand{{\arraystretch}}{{0.95}}
\captionof{{table}}{{Performance comparison of settings \testbasicInt, \testbasicIntStr, \testbasicIntVI, and \testbasicIntStrVI on testset T2.}}
\resizebox{{\textwidth}}{{!}}{{\input{{{path('T3-FourSettings-Table3.tex')}}}}}
\end{{minipage}}\end{{center}}
\clearpage
\setcounter{{table}}{{4}}
\begin{{center}}\begin{{minipage}}{{0.98\textwidth}}\centering\footnotesize
\setlength{{\tabcolsep}}{{3pt}}\renewcommand{{\arraystretch}}{{0.95}}
\captionof{{table}}{{Previously unsolved MPCLP instances in testset T1 by \'{{A}}lvarez-Miranda and Sinnl (2019) solved to optimality by the proposed B\&C algorithm.}}
\input{{{path('table5_unsolved_original_format.tex')}}}
\end{{minipage}}\end{{center}}
\clearpage
\setcounter{{figure}}{{1}}
\begin{{figure}}[!ht]\centering
\paneliii{{{path('Figure2-T2-Objective-Loss-By-Theta.eps')}}}{{a}}\hfill
\paneliii{{{path('Figure2-T2-Objective-Loss-By-K-Ratio.eps')}}}{{b}}\hfill
\paneliii{{{path('Figure2-T2-Objective-Loss-By-Ps.eps')}}}{{c}}
\caption{{Performance profiles of the objective loss caused by forbidding facility co-location for instances in testset T2, grouped by (a) parameter $\theta$, (b) ratio $K/|\I|$, and (c) percentage of low-$p_i$ sites.}}\end{{figure}}
\clearpage
\begin{{figure}}[!ht]\centering
\paneliii{{{path('Figure3-T2-NCL-NL-By-Theta.eps')}}}{{a}}\hfill
\paneliii{{{path('Figure3-T2-NCL-NL-By-K-Ratio.eps')}}}{{b}}\hfill
\paneliii{{{path('Figure3-T2-NCL-NL-By-Ps.eps')}}}{{c}}\\[8pt]
\paneliii{{{path('Figure3-T2-MCL-By-Theta.eps')}}}{{d}}\hfill
\paneliii{{{path('Figure3-T2-MCL-By-K-Ratio.eps')}}}{{e}}\hfill
\paneliii{{{path('Figure3-T2-MCL-By-Ps.eps')}}}{{f}}
\caption{{Performance profiles of the proportion of used sites at which facilities are co-located ($\texttt{{nCL}}/\texttt{{nL}} \,[\%]$) and empirical distributions of the maximum number of facilities ($\texttt{{mCL}}$) located at a site on testset T2.}}\end{{figure}}
\clearpage
\setcounter{{figure}}{{3}}
\begin{{figure}}[!ht]\centering
\panel{{{path('Figure4-T2-CPU-Time-Profile.eps')}}}{{a}}\hfill
\panel{{{path('Figure4-T2-End-Gap-Profile.eps')}}}{{b}}
\caption{{Performance profiles of (a) CPU time and (b) end gap returned by settings \testInt, \texttt{{B\&C-NC-I}}, and \texttt{{B\&C-NC-B}} on testset T2.}}\end{{figure}}
\clearpage
\setcounter{{figure}}{{4}}
\begin{{figure}}[!ht]\centering
\panel{{{path('Figure5-T2-Gap-Improvement-Profile.eps')}}}{{a}}\hfill
\panel{{{path('Figure5-T2-CPU-Time-Profile.eps')}}}{{b}}
\caption{{Performance profiles of (a) the gap improvement of the MPCLP solution over the $K$-median solution and (b) the CPU time of solving the MPCLP and $K$-median problem on testset T2.}}\end{{figure}}
\end{{document}}
"""
    output_directory = output_directory.resolve()
    source = output_directory / "paper_artifacts_review.tex"
    source.write_text(source_text)


def write_t2_review(output_directory: Path) -> None:
    """Write the review document for the isolated T2 candidate artifacts."""
    path = review_asset
    source_text = rf"""\documentclass[10pt]{{article}}
\usepackage[margin=0.55in]{{geometry}}
\usepackage{{graphicx,caption,newtxtext,newtxmath,booktabs,multirow,xspace}}
\setlength{{\parindent}}{{0pt}}
\captionsetup{{font=small,labelfont=bf}}
\newcommand{{\panel}}[2]{{\begin{{minipage}}[b]{{0.48\textwidth}}\centering\includegraphics[width=\linewidth]{{#1}}\\[-2pt]\small (#2)\end{{minipage}}}}
\newcommand{{\paneliii}}[2]{{\begin{{minipage}}[b]{{0.32\textwidth}}\centering\includegraphics[width=\linewidth]{{#1}}\\[-2pt]\small (#2)\end{{minipage}}}}
\newcommand{{\I}}{{\mathcal{{I}}}}
\newcommand{{\testbasicInt}}{{\texttt{{bB\&C-I}}\xspace}}
\newcommand{{\testbasicIntStr}}{{\texttt{{bB\&C-I+E}}\xspace}}
\newcommand{{\testbasicIntVI}}{{\texttt{{bB\&C-I+L}}\xspace}}
\newcommand{{\testbasicIntStrVI}}{{\texttt{{bB\&C-I+E+L}}\xspace}}
\newcommand{{\tblgroup}}{{\texttt{{id-$|\I|$-$K$}}\xspace}}
\newcommand{{\tblndata}}{{\texttt{{\#}}\xspace}}
\newcommand{{\tblnvar}}{{\texttt{{V}}\xspace}}
\newcommand{{\tblnsol}}{{\texttt{{S}}\xspace}}
\newcommand{{\tbltime}}{{\texttt{{T}}\xspace}}
\newcommand{{\tblnode}}{{\texttt{{N}}\xspace}}
\newcommand{{\tblgap}}{{\texttt{{G}}(\texttt{{\%}})\xspace}}
\newcommand{{\tblrgap}}{{\texttt{{LPG}}(\texttt{{\%}})\xspace}}
\newcommand{{\tblinstances}}{{\texttt{{\#Instances}}\xspace}}
\newcommand{{\tblaver}}{{\texttt{{Aver.}}\xspace}}
\newcommand{{\TL}}{{\texttt{{TL}}\xspace}}
\begin{{document}}
\begin{{center}}\Large\bfseries Candidate T2 figures and tables for the paper ``An efficient branch-and-cut algorithm for the multiple probabilistic covering location problem''\end{{center}}
\begin{{center}}\begin{{minipage}}{{0.98\textwidth}}\centering\scriptsize
\setlength{{\tabcolsep}}{{2.5pt}}\renewcommand{{\arraystretch}}{{0.95}}
\captionof{{table}}{{Performance comparison of settings \testbasicInt, \testbasicIntStr, \testbasicIntVI, and \testbasicIntStrVI on testset T2.}}
\resizebox{{\textwidth}}{{!}}{{\input{{{path('T3-FourSettings-Table3.tex')}}}}}
\end{{minipage}}\end{{center}}
\clearpage
\begin{{figure}}[!ht]\centering
\paneliii{{{path('Figure2-T2-Objective-Loss-By-Theta.eps')}}}{{a}}\hfill
\paneliii{{{path('Figure2-T2-Objective-Loss-By-K-Ratio.eps')}}}{{b}}\hfill
\paneliii{{{path('Figure2-T2-Objective-Loss-By-Ps.eps')}}}{{c}}
\caption{{Performance profiles of the objective loss caused by forbidding facility co-location for instances in testset T2, grouped by (a) parameter $\theta$, (b) ratio $K/|\I|$, and (c) percentage of low-$p_i$ sites.}}\end{{figure}}
\clearpage
\begin{{figure}}[!ht]\centering
\paneliii{{{path('Figure3-T2-NCL-NL-By-Theta.eps')}}}{{a}}\hfill
\paneliii{{{path('Figure3-T2-NCL-NL-By-K-Ratio.eps')}}}{{b}}\hfill
\paneliii{{{path('Figure3-T2-NCL-NL-By-Ps.eps')}}}{{c}}\\[8pt]
\paneliii{{{path('Figure3-T2-MCL-By-Theta.eps')}}}{{d}}\hfill
\paneliii{{{path('Figure3-T2-MCL-By-K-Ratio.eps')}}}{{e}}\hfill
\paneliii{{{path('Figure3-T2-MCL-By-Ps.eps')}}}{{f}}
\caption{{Performance profiles of the proportion of used sites at which facilities are co-located ($\texttt{{nCL}}/\texttt{{nL}} \,[\%]$) and empirical distributions of the maximum number of facilities ($\texttt{{mCL}}$) located at a site on testset T2.}}\end{{figure}}
\clearpage
\begin{{figure}}[!ht]\centering
\panel{{{path('Figure4-T2-CPU-Time-Profile.eps')}}}{{a}}\hfill
\panel{{{path('Figure4-T2-End-Gap-Profile.eps')}}}{{b}}
\caption{{Performance profiles of (a) CPU time and (b) end gap returned by settings \texttt{{B\&C-I}}, \texttt{{B\&C-NC-I}}, and \texttt{{B\&C-NC-B}} on testset T2.}}\end{{figure}}
\clearpage
\begin{{figure}}[!ht]\centering
\panel{{{path('Figure5-T2-Gap-Improvement-Profile.eps')}}}{{a}}\hfill
\panel{{{path('Figure5-T2-CPU-Time-Profile.eps')}}}{{b}}
\caption{{Performance profiles of (a) the gap improvement of the MPCLP solution over the $K$-median solution and (b) the CPU time of solving the MPCLP and $K$-median problem on testset T2.}}\end{{figure}}
\end{{document}}
"""
    source = output_directory / "t2_candidate_review.tex"
    source.write_text(source_text)


def write_facility_provenance(
    output_directory: Path,
    *,
    source_summary: Path | None = None,
    data_directory: Path | None = None,
) -> None:
    """Provide a human-readable artifact-to-CSV-to-log index beside the artifacts."""
    data = "data"
    catalog = {
        "source_profile": "facility_mixture",
        "adapter_manifest": f"{data}/facility_mixture_t2.manifest.json",
        "artifacts": {
            "Figure2-T2-Objective-Loss-By-Theta.eps": {"input": f"{data}/figure2_t2_colocation_loss.csv", "raw_path_columns": ["coloc_source", "nocoloc_source"]},
            "Figure2-T2-Objective-Loss-By-Ps.eps": {"input": f"{data}/figure2_t2_colocation_loss.csv", "raw_path_columns": ["coloc_source", "nocoloc_source"]},
            "Figure2-T2-Objective-Loss-By-K-Ratio.eps": {"input": f"{data}/figure2_t2_colocation_loss.csv", "raw_path_columns": ["coloc_source", "nocoloc_source"], "filter": {"k_ratio_selected": "selected"}},
            "Figure3-T2-NCL-NL-By-Theta.eps": {"input": f"{data}/figure3_t2_colocation_metrics.csv", "raw_path_columns": ["source"]},
            "Figure3-T2-NCL-NL-By-Ps.eps": {"input": f"{data}/figure3_t2_colocation_metrics.csv", "raw_path_columns": ["source"]},
            "Figure3-T2-MCL-By-Theta.eps": {"input": f"{data}/figure3_t2_colocation_metrics.csv", "raw_path_columns": ["source"]},
            "Figure3-T2-MCL-By-Ps.eps": {"input": f"{data}/figure3_t2_colocation_metrics.csv", "raw_path_columns": ["source"]},
            "Figure3-T2-NCL-NL-By-K-Ratio.eps": {"input": f"{data}/figure3_t2_colocation_metrics.csv", "raw_path_columns": ["source"]},
            "Figure3-T2-MCL-By-K-Ratio.eps": {"input": f"{data}/figure3_t2_colocation_metrics.csv", "raw_path_columns": ["source"]},
            "Figure4-T2-CPU-Time-Profile.eps": {"input": f"{data}/figure4_t2_solver_profiles.csv", "raw_path_columns": ["source"], "methods": ["B&C-I", "B&C-NC-I", "B&C-NC-B"], "temporary_substitution": "The complete B&C-NC-B curve uses the prior step_half T2; the other methods use facility-mixture T2."},
            "Figure4-T2-End-Gap-Profile.eps": {"input": f"{data}/figure4_t2_solver_profiles.csv", "raw_path_columns": ["source"], "methods": ["B&C-I", "B&C-NC-I", "B&C-NC-B"], "temporary_substitution": "The complete B&C-NC-B curve uses the prior step_half T2; the other methods use facility-mixture T2."},
            "Figure5-T2-Gap-Improvement-Profile.eps": {"input": f"{data}/figure5_t2_gap_improvement.csv", "raw_path_columns": ["mpclp_source", "kmedian_source"]},
            "Figure5-T2-CPU-Time-Profile.eps": {"input": f"{data}/figure5_t2_time_profiles.csv", "raw_path_columns": ["source"]},
            "T3-FourSettings-Table3.tex": {"input": f"{data}/t3_foursettings_table3.csv", "raw_path_columns": ["source"]},
            "T5-Newly-Solved-Table5.tex": {"input": f"{data}/table5_newly_solved.csv", "raw_path_columns": ["source_path"], "method": "Str1+VI1", "status": "OPTIMAL"},
            "paper_artifacts_review.tex": {"contains": ["Table 3", "Figure 2", "Figure 3", "Figure 4", "Figure 5"]},
        },
    }
    if source_summary is not None:
        source_summary = source_summary.resolve()
        catalog["source_profile"] = "facility_mixture_candidate"
        catalog["source_summary"] = str(source_summary)
        catalog["source_sha256"] = hashlib.sha256(source_summary.read_bytes()).hexdigest()
        catalog["artifacts"].pop("paper_artifacts_review.tex", None)
        catalog["artifacts"]["t2_candidate_review.tex"] = {
            "contains": ["Table 3", "Figure 2", "Figure 3", "Figure 4", "Figure 5"]
        }
    adapter_manifest = (
        output_directory / "inputs" / "facility_mixture_t2.manifest.json"
        if source_summary is not None
        else (data_directory or INPUTS) / "facility_mixture_t2.manifest.json"
    )
    if adapter_manifest.is_file():
        coverage = json.loads(adapter_manifest.read_text())
        catalog["figure4_bcncb_source"] = coverage.get("figure4_bcncb_source")
        catalog["figure4_bcncb_records"] = coverage.get("figure4_bcncb_records")
        if coverage.get("figure4_bcncb_source") == "facility-mixture candidate":
            for artifact in (
                "Figure4-T2-CPU-Time-Profile.eps",
                "Figure4-T2-End-Gap-Profile.eps",
            ):
                catalog["artifacts"][artifact].pop("temporary_substitution", None)
    (output_directory / "artifact_provenance.json").write_text(json.dumps(catalog, indent=2) + "\n")


def write_t1_review(output_directory: Path) -> None:
    path = review_asset
    source_text = rf"""\documentclass[10pt]{{article}}
\usepackage[margin=0.55in]{{geometry}}
\usepackage{{graphicx,caption,newtxtext,newtxmath,booktabs,multirow,xspace}}
\setlength{{\parindent}}{{0pt}}
\captionsetup{{font=small,labelfont=bf}}
\newcommand{{\panel}}[2]{{\begin{{minipage}}[b]{{0.48\textwidth}}\centering\includegraphics[width=\linewidth]{{#1}}\\[-2pt]\small (#2)\end{{minipage}}}}
\newcommand{{\paneliii}}[2]{{\begin{{minipage}}[b]{{0.32\textwidth}}\centering\includegraphics[width=\linewidth]{{#1}}\\[-2pt]\small (#2)\end{{minipage}}}}
\newcommand{{\I}}{{\mathcal{{I}}}}
\newcommand{{\testBin}}{{\texttt{{B\&C-B}}\xspace}}
\newcommand{{\testInt}}{{\texttt{{B\&C-I}}\xspace}}
\newcommand{{\testLiterature}}{{\texttt{{\'{{A}}S19}}\xspace}}
\newcommand{{\testbasicInt}}{{\texttt{{bB\&C-I}}\xspace}}
\newcommand{{\testbasicIntStr}}{{\texttt{{bB\&C-I+E}}\xspace}}
\newcommand{{\testbasicIntVI}}{{\texttt{{bB\&C-I+L}}\xspace}}
\newcommand{{\testbasicIntStrVI}}{{\texttt{{bB\&C-I+E+L}}\xspace}}
\newcommand{{\tblgroup}}{{\texttt{{id-$|\I|$-$K$}}\xspace}}
\newcommand{{\tblndata}}{{\texttt{{\#}}\xspace}}
\newcommand{{\tblnvar}}{{\texttt{{V}}\xspace}}
\newcommand{{\tblnsol}}{{\texttt{{S}}\xspace}}
\newcommand{{\tbltime}}{{\texttt{{T}}\xspace}}
\newcommand{{\tblnode}}{{\texttt{{N}}\xspace}}
\newcommand{{\tblgap}}{{\texttt{{G}}(\texttt{{\%}})\xspace}}
\newcommand{{\tblrgap}}{{\texttt{{LPG}}(\texttt{{\%}})\xspace}}
\newcommand{{\tblinstances}}{{\texttt{{\#Instances}}\xspace}}
\newcommand{{\tblaver}}{{\texttt{{Aver.}}\xspace}}
\newcommand{{\TL}}{{\texttt{{TL}}\xspace}}
\begin{{document}}
\begin{{center}}\Large\bfseries Candidate T1 figures and tables for the paper ``An efficient branch-and-cut algorithm for the multiple probabilistic covering location problem''\end{{center}}
\begin{{center}}\begin{{minipage}}{{0.98\textwidth}}\centering\scriptsize
\setlength{{\tabcolsep}}{{2.5pt}}\renewcommand{{\arraystretch}}{{0.95}}
\captionof{{table}}{{Overall performance comparison of settings \testBin and \testInt on testset T1.}}
\resizebox{{\textwidth}}{{!}}{{\input{{{path('T1-BinInt-Table1.tex')}}}}}
\end{{minipage}}\end{{center}}
\clearpage
\begin{{figure}}[!ht]\centering
\panel{{{path('Figure1-T1-Time-Profile.eps')}}}{{a}}\hfill
\panel{{{path('Figure1-T1-Gap-Profile.eps')}}}{{b}}
\caption{{Performance profiles of the CPU time and the end gap returned by settings \testBin and \testInt on testset T1.}}\end{{figure}}
\clearpage
\begin{{center}}\begin{{minipage}}{{0.98\textwidth}}\centering\scriptsize
\setlength{{\tabcolsep}}{{2.5pt}}\renewcommand{{\arraystretch}}{{0.95}}
\captionof{{table}}{{Performance comparison of settings \testbasicInt, \testbasicIntStr, \testbasicIntVI, and \testbasicIntStrVI on testset T1.}}
\resizebox{{\textwidth}}{{!}}{{\input{{{path('T2-FourSettings-Table2.tex')}}}}}
\end{{minipage}}\end{{center}}
\end{{document}}
"""
    source = output_directory / "t1_candidate_review.tex"
    source.write_text(source_text)


def build_t1_candidate(
    summary: Path,
    output_directory: Path,
    recipe: dict,
    styles: dict,
) -> int:
    summary = summary.resolve()
    output_directory = output_directory.resolve()
    protected_directories = {ROOT.resolve(), OUTPUT.resolve(), INPUTS.resolve(),
                             OUTPUT.parent.resolve()}
    if output_directory in protected_directories:
        raise SystemExit(
            "Refusing T1 candidate output in the published artifact tree; "
            "choose a dedicated subdirectory such as output/candidates/t1_<run>."
        )
    data_directory = output_directory / "inputs"
    prepared_directory = data_directory
    data_directory.mkdir(parents=True, exist_ok=True)
    prepared_directory.mkdir(parents=True, exist_ok=True)

    adapter_commands = [
        [
            sys.executable, str(ROOT / "adapters" / "export_figure1_data.py"),
            "--main-summary", str(summary),
            "--output", str(data_directory / "figure1_t1.csv"),
            "--manifest", str(data_directory / "figure1_t1.manifest.json"),
        ],
        [
            sys.executable, str(ROOT / "adapters" / "prepare_t1_bin_int_table1.py"),
            "--main-summary", str(summary),
            "--output", str(prepared_directory / "t1_bin_int_table1.csv"),
        ],
        [
            sys.executable, str(ROOT / "adapters" / "prepare_t2_foursettings_table.py"),
            "--main-summary", str(summary),
            "--output", str(prepared_directory / "t2_foursettings_table2.csv"),
        ],
    ]
    for command in adapter_commands:
        if run_step(command, command[1].rsplit("/", 1)[-1]):
            return 1
    build_recipe(recipe, styles, {"Figure1-T1-Time-Profile", "Figure1-T1-Gap-Profile"},
                 data_directory=data_directory, output_directory=output_directory)
    table_specs = [
        ("table1.recipe.yaml", "t1_bin_int_table1.csv", "T1-BinInt-Table1.tex"),
        ("table2.recipe.yaml", "t2_foursettings_table2.csv", "T2-FourSettings-Table2.tex"),
    ]
    for recipe_name, input_name, output_name in table_specs:
        build_table(recipe_name, prepared_directory / input_name,
                    output_directory / output_name, output_directory)
    write_t1_review(output_directory)
    provenance = {
        "profile": "t1-candidate",
        "source_summary": str(summary),
        "source_sha256": hashlib.sha256(summary.read_bytes()).hexdigest(),
        "artifacts": {
            "Figure1-T1-Time-Profile.eps": "data/figure1_t1.csv",
            "Figure1-T1-Gap-Profile.eps": "data/figure1_t1.csv",
            "T1-BinInt-Table1.tex": "inputs/t1_bin_int_table1.csv",
            "T2-FourSettings-Table2.tex": "inputs/t2_foursettings_table2.csv",
            "t1_candidate_review.tex": [
                "T1-BinInt-Table1.tex", "Figure1-T1-Time-Profile.eps",
                "Figure1-T1-Gap-Profile.eps", "T2-FourSettings-Table2.tex",
            ],
        },
    }
    (output_directory / "artifact_provenance.json").write_text(
        json.dumps(provenance, indent=2) + "\n"
    )
    print(f"Generated isolated T1 candidate artifacts in {output_directory}")
    return 0


T2_ARTIFACT_GROUPS = [
    ("Figure 2 subfigures", {"Figure2-T2-Objective-Loss-By-Theta", "Figure2-T2-Objective-Loss-By-Ps", "Figure2-T2-Objective-Loss-By-K-Ratio"}),
    ("Figure 3 subfigures", {"Figure3-T2-NCL-NL-By-Theta", "Figure3-T2-NCL-NL-By-Ps", "Figure3-T2-MCL-By-Theta", "Figure3-T2-MCL-By-Ps", "Figure3-T2-NCL-NL-By-K-Ratio", "Figure3-T2-MCL-By-K-Ratio"}),
    ("Figure 4 subfigures", {"Figure4-T2-CPU-Time-Profile", "Figure4-T2-End-Gap-Profile"}),
    ("Figure 5(a)", {"Figure5-T2-Gap-Improvement-Profile"}),
    ("Figure 5(b)", {"Figure5-T2-CPU-Time-Profile"}),
]


def build_t2_candidate(
    summary: Path,
    output_directory: Path,
    recipe: dict,
    styles: dict,
) -> int:
    """Build all T2 artifacts below an explicit isolated candidate directory."""
    summary = summary.resolve()
    output_directory = output_directory.resolve()
    protected_directories = {ROOT.resolve(), OUTPUT.resolve(), INPUTS.resolve(),
                             OUTPUT.parent.resolve()}
    if output_directory in protected_directories:
        raise SystemExit(
            "Refusing T2 candidate output in the published artifact tree; "
            "choose a dedicated subdirectory such as output/candidates/t2_<run>."
        )
    if not summary.is_file():
        raise SystemExit(f"T2 candidate summary does not exist: {summary}")
    data_directory = output_directory / "data"
    data_directory.mkdir(parents=True, exist_ok=True)
    input_manifest = data_directory / "input_manifest.json"
    input_manifest.write_text(json.dumps({
        "schema_version": 1,
        "summaries": [{
            "run_id": output_directory.name,
            "role": "auto",
            "path": str(summary),
        }],
    }, indent=2) + "\n")
    if run_facility_adapter(data_directory, input_manifest):
        return 1
    for label, identifiers in T2_ARTIFACT_GROUPS:
        print(f"Building {label}")
        build_recipe(recipe, styles, identifiers,
                     data_directory=data_directory, output_directory=output_directory)
    print("Building Table 3")
    build_facility_table3(data_directory, output_directory)
    print("Writing isolated T2 review document")
    write_t2_review(output_directory)
    write_facility_provenance(output_directory, source_summary=summary)
    print(f"Generated isolated T2 candidate artifacts in {output_directory}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Rebuild the MPCLP paper figures and tables.")
    parser.add_argument("command", choices=("check", "build", "all", "t1", "t2"))
    parser.add_argument("--artifact", action="append", help="Paper artifact id to build; repeatable.")
    parser.add_argument("--output-dir", type=Path, help="Output directory (default: output/artifacts).")
    parser.add_argument("--t1-summary", type=Path, help="T1 summary.csv used by the isolated `t1` build.")
    parser.add_argument("--t2-summary", type=Path, help="T2 summary.csv used by the isolated `t2` build.")
    args = parser.parse_args(argv)

    recipe = read_yaml(ROOT / "recipe.yaml")
    styles = read_yaml(ROOT / "style.yaml").get("styles", {})
    output_directory = (args.output_dir or OUTPUT).resolve()
    if args.command == "t1":
        if args.t1_summary is None or args.output_dir is None:
            parser.error("t1 requires --t1-summary and --output-dir to protect baseline artifacts")
        return build_t1_candidate(args.t1_summary, args.output_dir, recipe, styles)
    if args.command == "t2":
        if args.t2_summary is None or args.output_dir is None:
            parser.error("t2 requires --t2-summary and --output-dir to protect baseline artifacts")
        recipe, styles = facility_mixture_view(recipe, styles)
        return build_t2_candidate(args.t2_summary, args.output_dir, recipe, styles)

    # The published artifacts all come from the facility-mixture testset T2.
    recipe, styles = facility_mixture_view(recipe, styles)
    # An explicit output directory owns the intermediates and the matplotlib cache
    # as well, so a build into a scratch directory leaves the published tree alone.
    data_directory = output_directory / "inputs" if args.output_dir else INPUTS
    os.environ.setdefault("MPLCONFIGDIR", str(output_directory / "mplconfig"))
    (output_directory / "mplconfig").mkdir(parents=True, exist_ok=True)
    print("Refreshing the facility-mixture T2 export")
    if run_facility_adapter(data_directory):
        return 1
    if args.command == "all":
        if args.artifact:
            parser.error("--artifact is not used with all")
        print("Refreshing the record exports")
        for adapter, arguments in (
                ("export_figure1_data.py", ["--output", str(data_directory / "figure1_t1.csv"),
                                            "--manifest", str(data_directory / "figure1_t1.manifest.json")]),
                ("prepare_t1_bin_int_table1.py", ["--output", str(data_directory / "t1_bin_int_table1.csv")]),
                ("prepare_t2_foursettings_table.py", ["--output", str(data_directory / "t2_foursettings_table2.csv")]),
        ):
            if run_step([sys.executable, str(ROOT / "adapters" / adapter)] + arguments, adapter):
                return 1
        if run_step([
            sys.executable,
            str(ROOT / "adapters" / "prepare_table5_newly_solved.py"),
            "--output", str(data_directory / "table5_newly_solved.csv"),
            "--manifest", str(data_directory / "table5_newly_solved.manifest.json"),
            "--grouped-tex", str(output_directory / "table5_unsolved.tex"),
            "--original-tex", str(output_directory / "table5_unsolved_original_format.tex"),
        ], "prepare_table5_newly_solved.py"):
            return 1
        print("Figure 1 (2 subfigures)")
        build_recipe(recipe, styles, {"Figure1-T1-Time-Profile", "Figure1-T1-Gap-Profile"},
                     data_directory=data_directory, output_directory=output_directory)
        for recipe_name, source, name in (
                ("table1.recipe.yaml", data_directory / "t1_bin_int_table1.csv", "T1-BinInt-Table1.tex"),
                ("table2.recipe.yaml", data_directory / "t2_foursettings_table2.csv", "T2-FourSettings-Table2.tex"),
                ("table5.recipe.yaml", data_directory / "table5_newly_solved.csv", "T5-Newly-Solved-Table5.tex")):
            print(name.removesuffix(".tex"))
            build_table(recipe_name, source, output_directory / name, output_directory)
        for label, identifiers in T2_ARTIFACT_GROUPS:
            print(label)
            build_recipe(recipe, styles, identifiers, data_directory=data_directory,
                         output_directory=output_directory)
        print("T3-FourSettings-Table3")
        build_facility_table3(data_directory, output_directory)
        print("Review document")
        write_facility_review(output_directory)
        write_facility_provenance(output_directory, data_directory=data_directory)
        adapter_manifest = json.loads((data_directory / "facility_mixture_t2.manifest.json").read_text())
        print(f"\nFigures and tables are in {output_directory}")
        print(
            f"Figure 4 draws {adapter_manifest['figure4_bcncb_records']} records per method from "
            f"{adapter_manifest['figure4_bcncb_source']}."
        )
        return 0
    if not args.artifact:
        parser.error(f"--artifact is required for {args.command}")
    if args.command == "check":
        return check_recipe(recipe, styles, set(args.artifact), data_directory=data_directory,
                            output_directory=output_directory)
    build_recipe(recipe, styles, set(args.artifact), data_directory=data_directory,
                 output_directory=output_directory)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
