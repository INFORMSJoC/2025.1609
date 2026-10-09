#!/usr/bin/env python3
"""Normalize MPCLP T1 and AS19 records for the Table 1 recipe."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path


STATISTICS_ROOT = Path(__file__).resolve().parents[1]
ROOT = Path(__file__).resolve().parents[3]
DEFAULT_MAIN = ROOT / "results/summarized/T1/summary.csv"
DEFAULT_LITERATURE_DIR = ROOT / "scripts/statistics/reference"
DEFAULT_OUTPUT = ROOT / "output/artifacts/inputs/t1_bin_int_table1.csv"
METHOD_MAP = {"B&C-B": "B&C-B", "Str1+VI1": "B&C-I"}
THETA_BY_TABLE = {1: "0.2", 2: "0.5", 3: "0.8", 4: "0.2", 5: "0.5", 6: "0.8"}


def main_rows(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            if row["method"] not in METHOD_MAP:
                continue
            instance = "|".join((row["data"], row["r"], row["R"], row["theta"]))
            data_header = (ROOT / f"data/pmed{row['data']}.txt").read_text().splitlines()[0].split()
            rows.append(
                {
                    "instance": instance,
                    "dataset": row["data"],
                    "dataset_label": f"{row['data']}-{data_header[0]}-{data_header[2]}",
                    "theta": row["theta"],
                    "theta_label": rf"$\theta={row['theta']}$",
                    "method": METHOD_MAP[row["method"]],
                    "solved": str(row["status"] == "OPTIMAL"),
                    "nvar": row["nvar"],
                    "time": row["time"],
                    "nodes": row["node"],
                    "gap": row["gap"],
                    "rgap": row["rgap"],
                }
            )
    return rows


def literature_rows(directory: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for table_id in range(1, 7):
        radius = ("5", "20") if table_id <= 3 else ("10", "25")
        theta = THETA_BY_TABLE[table_id]
        with (directory / f"table_{table_id}.csv").open() as handle:
            next(handle, None)
            for line in handle:
                fields = line.split()
                if not fields:
                    continue
                data = fields[0]
                data_header = (ROOT / f"data/pmed{data}.txt").read_text().splitlines()[0].split()
                instance = "|".join((data, *radius, theta))
                timeout = fields[5] == "TL"
                gap = float(fields[8]) if len(fields) > 8 else 0.0
                eligible = not timeout and gap <= 0.99
                rows.append(
                    {
                        "instance": instance,
                        "dataset": data,
                        "dataset_label": f"{data}-{data_header[0]}-{data_header[2]}",
                        "theta": theta,
                        "theta_label": rf"$\theta={theta}$",
                        "method": "AS19",
                        "solved": str(eligible),
                        "nvar": "",
                        # The Table 1 recipe selects eligible AS19 records for
                        # the mean and falls back to all AS19 records when the
                        # group has none; retain the 3600-second timeout value
                        # so that fallback renders as TL rather than blank.
                        "time": fields[5] if eligible else "3600",
                        "nodes": "",
                        "gap": str(gap),
                        "rgap": "",
                    }
                )
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--main-summary", type=Path, default=DEFAULT_MAIN)
    parser.add_argument("--literature-dir", type=Path, default=DEFAULT_LITERATURE_DIR)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    rows = main_rows(args.main_summary) + literature_rows(args.literature_dir)
    keys = [(row["instance"], row["method"]) for row in rows]
    if len(keys) != len(set(keys)):
        raise ValueError("Prepared Table 1 data contains duplicate instance x method records.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fields = ["instance", "dataset", "dataset_label", "theta", "theta_label", "method", "solved", "nvar", "time", "nodes", "gap", "rgap"]
    with args.output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    print(f"Wrote {len(rows)} records to {args.output}")


if __name__ == "__main__":
    main()
