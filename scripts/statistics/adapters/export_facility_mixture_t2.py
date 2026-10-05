#!/usr/bin/env python3
"""Build facility-mixture T2 report datasets from declared run summaries."""
from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_INPUT_MANIFEST = ROOT / "scripts/statistics/t2-inputs.yaml"
SHARES = ("1090", "5050", "9010")
THETAS = ("0.01", "0.1", "0.2")
FULL_SETTING = "Str1+VI1+LocalSearch1"
PREVIOUS_T2_PROFILE_BLOCK = {"0.1": "1090", "0.2": "5050", "0.5": "9010"}


def number(value: Any) -> float | None:
    try:
        return float(value) if str(value).strip() else None
    except (TypeError, ValueError):
        return None


def integer(value: Any) -> int | None:
    text = str(value).strip()
    if text.lower().startswith("pmed"):
        text = text[4:]
    parsed = number(text)
    return None if parsed is None else int(parsed)


def canonical_theta(value: str) -> str:
    return format(float(value), ".15g") if value else ""


def k_ratio_group(k: int, i_count: int) -> str | None:
    if 20 * k <= i_count:
        return "0-5%"
    if 10 * k == i_count:
        return "10%"
    if 5 * k == i_count:
        return "20%"
    if 3 * k == i_count:
        return "1/3"
    return None


def location_count(data: int) -> int | None:
    path = ROOT / "data" / f"pmed{data}.txt"
    try:
        return int(path.read_text().splitlines()[0].split()[0])
    except (OSError, IndexError, ValueError):
        return None


def display_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path.resolve())


@dataclass(frozen=True)
class Run:
    run_id: str
    summary_path: str
    data: int
    r: int
    R: int
    theta: str
    share: str
    mode: str
    coloc: str
    setting: str
    status: str
    time: float | None
    nodes: float | None
    gap: float | None
    rgap: float | None
    objective: float | None
    eta_m: float | None
    eta_p: float | None
    ncl: int | None
    nl: int | None
    mcl: int | None
    locations: int | None
    k: int | None
    path: str
    role: str


def read_manifest(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path} must be JSON-compatible YAML: {exc}") from exc
    if payload.get("schema_version") != 1 or not isinstance(payload.get("summaries"), list):
        raise ValueError(f"invalid facility-mixture input manifest: {path}")
    return payload


def run_from_row(row: dict[str, str], entry: dict[str, Any], summary_path: Path) -> Run | None:
    data, r, radius = integer(row.get("data")), integer(row.get("r")), integer(row.get("R"))
    if data is None or r is None or radius is None or not row.get("status"):
        return None
    role = str(entry.get("role", "facility"))
    source = (row.get("path") or "").strip()
    if role == "auto":
        role = (
            "kmedian"
            if (row.get("mode") or "").strip() == "KMED"
            or (row.get("method") or "").strip() == "KMED"
            or "-kmedian-" in source.lower()
            else "facility"
        )
    share = (row.get("lh") or "").strip()
    if role == "figure4_previous":
        share = PREVIOUS_T2_PROFILE_BLOCK.get(format(number(row.get("p_s")) or 0, ".15g"), "")
    if not share:
        return None
    setting = (row.get("setting") or "").strip()
    mode = (row.get("mode") or "").strip()
    coloc = (row.get("coloc") or "").strip()
    if role == "kmedian":
        mode, coloc, setting = "KMED", "KMED", "KMED"
    objective = number(row.get("obj_calc"))
    if objective is None:
        objective = number(row.get("obj"))
    return Run(
        str(entry["run_id"]), display_path(summary_path), data, r, radius,
        "1" if role == "kmedian" else canonical_theta((row.get("theta") or "").strip()),
        share, mode, coloc, setting, (row.get("status") or "").strip(),
        number(row.get("time")), number(row.get("node")), number(row.get("gap")),
        number(row.get("rgap")), objective, number(row.get("sum_etaM_solution")),
        number(row.get("sum_etaP_solution")), integer(row.get("ncl")), integer(row.get("nl")),
        integer(row.get("mcl")), integer(row.get("i_count")) or location_count(data),
        integer(row.get("k")), source, role,
    )


def load_runs(manifest_path: Path) -> tuple[list[Run], dict[str, Any]]:
    manifest = read_manifest(manifest_path)
    runs: list[Run] = []
    inputs: list[dict[str, Any]] = []
    for entry in manifest["summaries"]:
        if not all(key in entry for key in ("run_id", "path")):
            raise ValueError("each manifest summary requires run_id and path")
        path = Path(entry["path"])
        path = path if path.is_absolute() else ROOT / path
        if not path.is_file():
            raise FileNotFoundError(f"declared summary does not exist: {path}")
        count = 0
        with path.open(newline="", encoding="utf-8") as source:
            reader = csv.DictReader(source)
            required = {"data", "r", "R", "theta", "status", "path"}
            if not required.issubset(set(reader.fieldnames or [])):
                raise ValueError(f"incompatible summary schema: {path}")
            for row in reader:
                run = run_from_row(row, entry, path)
                if run is not None:
                    runs.append(run)
                    count += 1
        inputs.append({"run_id": entry["run_id"], "summary": display_path(path), "role": entry.get("role", "facility"), "records": count})
    return runs, {"manifest": display_path(manifest_path), "inputs": inputs}


def deduplicate(runs: list[Run]) -> tuple[list[Run], list[dict[str, Any]]]:
    records: dict[tuple[Any, ...], Run] = {}
    duplicates: list[dict[str, Any]] = []
    for run in runs:
        key = (run.role, run.data, run.r, run.R, run.theta, run.share, run.mode, run.coloc, run.setting)
        if key in records:
            duplicates.append({"key": list(key), "first": records[key].path, "duplicate": run.path})
            continue
        records[key] = run
    return list(records.values()), duplicates


def write_csv(path: Path, fields: list[str], rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def build_datasets(runs: list[Run]) -> tuple[dict[str, list[dict[str, object]]], dict[str, Any]]:
    facility = [run for run in runs if run.role == "facility" and run.share in SHARES]
    full = [run for run in facility if run.mode == "Int" and run.setting == FULL_SETTING and run.theta in THETAS]
    lookup = {(run.data, run.r, run.R, run.theta, run.share, run.coloc): run for run in full}
    fig2: list[dict[str, object]] = []
    missing_pairs: list[dict[str, Any]] = []
    nonoptimal_pairs: list[dict[str, Any]] = []
    pair_provenance: list[dict[str, Any]] = []
    for coloc in full:
        if coloc.coloc != "ColocOn":
            continue
        nocoloc = lookup.get((coloc.data, coloc.r, coloc.R, coloc.theta, coloc.share, "NoCoLoc"))
        if nocoloc is None or coloc.objective is None or nocoloc.objective is None or coloc.k is None or coloc.locations is None:
            missing_pairs.append({"key": [coloc.data, coloc.r, coloc.R, coloc.theta, coloc.share], "coloc_source": coloc.path, "reason": "missing peer or required metric"})
            continue
        if coloc.status != "OPTIMAL" or nocoloc.status != "OPTIMAL":
            nonoptimal_pairs.append({"key": [coloc.data, coloc.r, coloc.R, coloc.theta, coloc.share], "coloc_status": coloc.status, "nocoloc_status": nocoloc.status})
        group = k_ratio_group(coloc.k, coloc.locations)
        row = {
            "instance": coloc.data, "r": coloc.r, "R": coloc.R, "theta": coloc.theta,
            "p_s": coloc.share, "i_count": coloc.locations, "k": coloc.k,
            "k_over_i": coloc.k / coloc.locations, "k_ratio_group": group or "excluded",
            "k_ratio_selected": "selected" if group else "excluded",
            "objective_coloc_on": coloc.objective, "objective_no_coloc": nocoloc.objective,
            "relative_objective_loss_pct": (coloc.objective - nocoloc.objective) / coloc.objective * 100,
            "coloc_status": coloc.status, "nocoloc_status": nocoloc.status,
            "coloc_source": coloc.path, "nocoloc_source": nocoloc.path,
        }
        fig2.append(row)
        pair_provenance.append({
            "key": [coloc.data, coloc.r, coloc.R, coloc.theta, coloc.share],
            "coloc": {"run_id": coloc.run_id, "summary": coloc.summary_path, "record": coloc.path},
            "nocoloc": {"run_id": nocoloc.run_id, "summary": nocoloc.summary_path, "record": nocoloc.path},
        })

    fig3: list[dict[str, object]] = []
    for run in full:
        if run.coloc != "ColocOn" or not run.nl or run.locations is None or run.k is None:
            continue
        group = k_ratio_group(run.k, run.locations)
        fig3.append({
            "instance": run.data, "r": run.r, "R": run.R, "theta": run.theta, "p_s": run.share,
            "status": run.status, "i_count": run.locations, "k": run.k, "k_over_i": run.k / run.locations,
            "k_ratio_group": group or "excluded", "k_ratio_selected": "selected" if group else "excluded",
            "ncl": run.ncl, "nl": run.nl,
            "ncl_over_nl": run.ncl / run.nl,
            "ncl_over_nl_pct": run.ncl / run.nl * 100,
            "mcl": run.mcl, "source": run.path,
        })

    method = {("Int", "ColocOn", FULL_SETTING): "B&C-I", ("Int", "NoCoLoc", FULL_SETTING): "B&C-NC-I", ("Bin", "NoCoLoc", ""): "B&C-NC-B"}
    fig4_runs = [run for run in facility if not (run.mode == "Bin" and run.coloc == "NoCoLoc")]
    facility_bcncb = [run for run in facility if run.mode == "Bin" and run.coloc == "NoCoLoc" and run.theta in THETAS]
    facility_bcncb_keys = {
        (run.data, run.r, run.R, run.theta, run.share) for run in facility_bcncb
    }
    if len(facility_bcncb_keys) == 720:
        bcncb_runs = facility_bcncb
        bcncb_source = "facility-mixture candidate"
    else:
        bcncb_runs = [
            run for run in runs
            if run.role == "figure4_previous" and run.mode == "Bin" and run.coloc == "NoCoLoc"
        ]
        bcncb_source = "prior step_half T2 substitution"
    fig4_runs += bcncb_runs
    fig4 = [{
        "instance": run.data, "r": run.r, "R": run.R, "theta": run.theta, "p_s": run.share,
        "method": method[(run.mode, run.coloc, run.setting)], "status": run.status,
        "runtime_seconds": run.time, "end_gap_percent": run.gap, "source": run.path,
    } for run in fig4_runs if (run.mode, run.coloc, run.setting) in method and run.theta in THETAS]

    kmed = {(run.data, run.r, run.R, run.share): run for run in runs if run.role == "kmedian"}
    gap: list[dict[str, object]] = []
    time_rows: list[dict[str, object]] = []
    for run in full:
        if run.coloc != "ColocOn":
            continue
        baseline = kmed.get((run.data, run.r, run.R, run.share))
        if baseline and baseline.eta_m is not None and baseline.eta_p is not None and run.objective is not None:
            reference = float(run.theta) * baseline.eta_m + (1 - float(run.theta)) * baseline.eta_p
            gap.append({"instance": run.data, "r": run.r, "R": run.R, "theta": run.theta, "p_s": run.share, "gap_improvement_percent": (run.objective - reference) / reference * 100, "mpclp_source": run.path, "kmedian_source": baseline.path})
        time_rows.append({"instance": run.data, "r": run.r, "R": run.R, "theta": run.theta, "p_s": run.share, "series": run.theta, "status": run.status, "runtime_seconds": run.time, "source": run.path})
    for baseline in kmed.values():
        time_rows.append({"instance": baseline.data, "r": baseline.r, "R": baseline.R, "theta": "1", "p_s": baseline.share, "series": "1.0", "status": baseline.status, "runtime_seconds": baseline.time, "source": baseline.path})

    settings = {"Str0+VI0": "Str0+VI0", "Str1+VI0": "Str1+VI0", "Str0+VI1": "Str0+VI1", FULL_SETTING: "Str1+VI1"}
    table: list[dict[str, object]] = []
    for run in facility:
        if run.mode == "Int" and run.coloc == "ColocOn" and run.setting in settings and run.theta in THETAS:
            header = (ROOT / f"data/pmed{run.data}.txt").read_text().splitlines()[0].split()
            table.append({"instance": "|".join(map(str, (run.data, run.r, run.R, run.theta, run.share))), "dataset": run.data, "dataset_label": f"{run.data}-{header[0]}-{header[2]}", "theta": run.theta, "theta_label": rf"$\theta={run.theta}$", "method": settings[run.setting], "solved": str(run.status == "OPTIMAL"), "time": run.time, "nodes": run.nodes, "gap": run.gap, "rgap": run.rgap, "source": run.path})

    datasets = {"figure2_t2_colocation_loss.csv": fig2, "figure3_t2_colocation_metrics.csv": fig3, "figure4_t2_solver_profiles.csv": fig4, "figure5_t2_gap_improvement.csv": gap, "figure5_t2_time_profiles.csv": time_rows, "t3_foursettings_table3.csv": table}
    coverage = {
        "figure2_pairs": len(fig2), "figure2_missing_pairs": len(missing_pairs),
        "missing_pair_samples": missing_pairs[:20], "figure2_pair_provenance": pair_provenance,
        "figure2_nonoptimal_pairs": len(nonoptimal_pairs), "nonoptimal_pair_samples": nonoptimal_pairs[:20],
        "nonoptimal_records": sum(run.status != "OPTIMAL" for run in runs),
        "nonoptimal_samples": [{"run_id": run.run_id, "status": run.status, "path": run.path} for run in runs if run.status != "OPTIMAL"][:20],
        "figure2_k_ratio_groups": dict(sorted(Counter(row["k_ratio_group"] for row in fig2).items())),
        "figure3_records": len(fig3), "figure4_records": len(fig4), "figure5_gap_records": len(gap),
        "figure5_time_records": len(time_rows), "table3_records": len(table),
        "figure4_bcncb_source": bcncb_source,
        "figure4_bcncb_records": len(bcncb_runs),
    }
    return datasets, coverage


FIELDS = {
    "figure2_t2_colocation_loss.csv": ["instance", "r", "R", "theta", "p_s", "i_count", "k", "k_over_i", "k_ratio_group", "k_ratio_selected", "objective_coloc_on", "objective_no_coloc", "relative_objective_loss_pct", "coloc_status", "nocoloc_status", "coloc_source", "nocoloc_source"],
    "figure3_t2_colocation_metrics.csv": ["instance", "r", "R", "theta", "p_s", "status", "i_count", "k", "k_over_i", "k_ratio_group", "k_ratio_selected", "ncl", "nl", "ncl_over_nl", "ncl_over_nl_pct", "mcl", "source"],
    "figure4_t2_solver_profiles.csv": ["instance", "r", "R", "theta", "p_s", "method", "status", "runtime_seconds", "end_gap_percent", "source"],
    "figure5_t2_gap_improvement.csv": ["instance", "r", "R", "theta", "p_s", "gap_improvement_percent", "mpclp_source", "kmedian_source"],
    "figure5_t2_time_profiles.csv": ["instance", "r", "R", "theta", "p_s", "series", "status", "runtime_seconds", "source"],
    "t3_foursettings_table3.csv": ["instance", "dataset", "dataset_label", "theta", "theta_label", "method", "solved", "time", "nodes", "gap", "rgap", "source"],
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-manifest", type=Path, default=DEFAULT_INPUT_MANIFEST)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    manifest_path = args.input_manifest.expanduser().resolve()
    output = args.output_dir.expanduser().resolve()
    runs, provenance = load_runs(manifest_path)
    runs, duplicates = deduplicate(runs)
    datasets, coverage = build_datasets(runs)
    for name, rows in datasets.items():
        write_csv(output / name, FIELDS[name], rows)
    report = {"schema_version": 1, **provenance, "records": len(runs), "duplicate_records": len(duplicates), "duplicate_samples": duplicates[:20], **coverage}
    (output / "facility_mixture_t2.manifest.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    console_report = {key: value for key, value in report.items() if key != "figure2_pair_provenance"}
    print(json.dumps(console_report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
