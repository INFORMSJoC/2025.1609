#!/usr/bin/env python3
"""Export the T1 instances newly solved by the full B&C setting."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from collections import defaultdict
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts" / "statistics" / "lib"))

from mpclp.table_style import render_unsolved_grouped_tex, render_unsolved_original_tex


THETAS = (0.2, 0.5, 0.8)
RADII = ((5, 20), (10, 25))
THETA_BY_TABLE = {1: 0.2, 2: 0.5, 3: 0.8, 4: 0.2, 5: 0.5, 6: 0.8}


def public_path(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(ROOT))
    except ValueError:
        return str(resolved)


def literature_unsolved(directory: Path) -> set[tuple[int, int, int, float]]:
    selected: set[tuple[int, int, int, float]] = set()
    for table in range(1, 7):
        path = directory / f"table_{table}.csv"
        if not path.is_file():
            raise FileNotFoundError(f"Missing literature reference: {path}")
        radius = (5, 20) if table <= 3 else (10, 25)
        with path.open() as handle:
            next(handle, None)
            for line in handle:
                fields = line.split()
                if not fields:
                    continue
                status = fields[5] if len(fields) > 5 else ""
                gap = float(fields[8]) if len(fields) > 8 and fields[8] else 0.0
                if status == "TL" or gap > 0.99:
                    selected.add((int(fields[0]), *radius, THETA_BY_TABLE[table]))
    return selected


def instance_size(row: dict[str, str]) -> int:
    if row.get("i_count", "").strip():
        return int(float(row["i_count"]))
    data_path = ROOT / "data" / f"pmed{int(row['data'])}.txt"
    return int(data_path.read_text().split()[0])


def collect(summary: Path, references: Path) -> dict[tuple[int, int, float], list[tuple]]:
    eligible = literature_unsolved(references)
    solved: dict[tuple[int, int, float], list[tuple]] = defaultdict(list)
    seen: set[tuple[int, int, int, float]] = set()
    with summary.open(newline="") as handle:
        reader = csv.DictReader(handle)
        required = {"method", "data", "r", "R", "theta", "status", "time", "node", "obj_calc", "k", "path"}
        missing = sorted(required - set(reader.fieldnames or []))
        if missing:
            raise ValueError(f"{summary} is missing columns: {', '.join(missing)}")
        for row in reader:
            if row["method"] != "Str1+VI1" or row["status"] != "OPTIMAL":
                continue
            instance = int(row["data"])
            r, R, theta = int(row["r"]), int(row["R"]), float(row["theta"])
            identity = (instance, r, R, theta)
            if identity not in eligible:
                continue
            if identity in seen:
                raise ValueError(f"Duplicate full B&C result in {summary}: {identity}")
            seen.add(identity)
            objective_text = row.get("obj_calc", "").strip() or row.get("obj", "").strip()
            if not objective_text:
                raise ValueError(f"Missing objective for newly solved instance: {identity}")
            solved[(r, R, theta)].append((
                instance,
                instance_size(row),
                int(float(row["k"])),
                float(row["time"]),
                float(row["node"]),
                float(objective_text),
                theta,
                row["path"],
            ))
    for rows in solved.values():
        rows.sort(key=lambda value: value[0])
    return solved


def write_ordered_csv(path: Path, solved: dict[tuple[int, int, float], list[tuple]]) -> list[tuple]:
    path.parent.mkdir(parents=True, exist_ok=True)
    rows: list[tuple] = []
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(["order", "instance_id", "n_vertices", "k", "time", "nodes", "objective", "source_path"])
        order = 0
        for theta in THETAS:
            for r, R in RADII:
                for row in solved.get((r, R, theta), []):
                    order += 1
                    instance, n_vertices, k, time, nodes, objective, _, source = row
                    writer.writerow([order, f"{instance}-{r}-{R}-{theta:g}", n_vertices, k, time, nodes, objective, source])
                    rows.append(row)
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary", type=Path, default=ROOT / "results/summarized/T1/summary.csv")
    parser.add_argument("--literature-dir", type=Path, default=ROOT / "scripts/statistics/reference")
    parser.add_argument("--output", type=Path, default=ROOT / "output/artifacts/inputs/table5_newly_solved.csv")
    parser.add_argument("--manifest", type=Path, default=ROOT / "output/artifacts/inputs/table5_newly_solved.manifest.json")
    parser.add_argument("--grouped-tex", type=Path)
    parser.add_argument("--original-tex", type=Path)
    args = parser.parse_args()

    summary = args.summary.resolve()
    solved = collect(summary, args.literature_dir.resolve())
    rows = write_ordered_csv(args.output.resolve(), solved)
    if args.grouped_tex:
        args.grouped_tex.parent.mkdir(parents=True, exist_ok=True)
        args.grouped_tex.write_text(render_unsolved_grouped_tex(solved))
    if args.original_tex:
        args.original_tex.parent.mkdir(parents=True, exist_ok=True)
        args.original_tex.write_text(render_unsolved_original_tex(solved))
    manifest = {
        "schema_version": 1,
        "artifact": "newly solved literature-unsolved T1 instances",
        "source": public_path(summary),
        "source_sha256": hashlib.sha256(summary.read_bytes()).hexdigest(),
        "records": len(rows),
        "physical_rows": (len(rows) + 1) // 2,
        "split_after": (len(rows) + 1) // 2,
        "method": "Str1+VI1",
        "status": "OPTIMAL",
        "literature_reference": public_path(args.literature_dir),
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
