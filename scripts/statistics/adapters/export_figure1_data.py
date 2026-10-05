#!/usr/bin/env python3
"""Export the canonical T1 Figure 1 records from MPCLP's summary CSV."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path


STATISTICS_ROOT = Path(__file__).resolve().parents[1]
ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "results/summarized/T1/summary.csv"
DATA_DIR = ROOT / "output/artifacts/inputs"
OUTPUT = DATA_DIR / "figure1_t1.csv"
MANIFEST = DATA_DIR / "figure1_t1.manifest.json"
METHODS = {"B&C-B": "B&C-B", "Str1+VI1": "B&C-I"}
FIELDS = ["instance", "r", "R", "theta", "method", "status", "runtime_seconds", "end_gap_percent", "source_path"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--main-summary", type=Path, default=SOURCE)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    args = parser.parse_args()

    with args.main_summary.open(newline="") as handle:
        source_rows = list(csv.DictReader(handle))
    records = []
    for row in source_rows:
        label = METHODS.get(row["method"])
        if label is None:
            continue
        if not row.get("gap"):
            raise SystemExit("Missing end gap for Figure 1 source row: {0}".format(row.get("path")))
        records.append({
            "instance": str(row["data"]),
            "r": int(row["r"]),
            "R": int(row["R"]),
            "theta": float(row["theta"]),
            "method": label,
            "status": row["status"],
            "runtime_seconds": float(row["time"]),
            "end_gap_percent": float(row["gap"]),
            "source_path": row["path"],
        })
    records.sort(key=lambda row: (row["method"], row["instance"], row["r"], row["R"], row["theta"]))
    counts = {method: sum(row["method"] == method for row in records) for method in sorted(set(METHODS.values()))}
    if counts != {"B&C-B": 240, "B&C-I": 240}:
        raise SystemExit(f"Unexpected Figure 1 method counts: {counts}")
    keys = {method: {(row["instance"], row["r"], row["R"], row["theta"]) for row in records if row["method"] == method} for method in counts}
    if keys["B&C-B"] != keys["B&C-I"]:
        raise SystemExit("Figure 1 method records do not share the same instance grid.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(records)
    try:
        source_label = str(args.main_summary.resolve().relative_to(ROOT))
    except ValueError:
        source_label = str(args.main_summary.resolve())
    args.manifest.write_text(json.dumps({
        "artifact": "Figure 1 T1 record-level input",
        "format": "csv",
        "data_file": args.output.name,
        "source": source_label,
        "source_sha256": hashlib.sha256(args.main_summary.read_bytes()).hexdigest(),
        "record_count": len(records),
        "method_counts": counts,
        "record_key": ["instance", "r", "R", "theta", "method"],
        "units": {"runtime_seconds": "s", "end_gap_percent": "%"},
        "columns": FIELDS,
        "generator": "python3 scripts/statistics/adapters/export_figure1_data.py --main-summary <summary> --output <csv> --manifest <json>",
    }, indent=2) + "\n")
    print(f"Wrote {len(records)} records to {args.output}")
    print(f"Wrote provenance manifest to {args.manifest}")


if __name__ == "__main__":
    main()
