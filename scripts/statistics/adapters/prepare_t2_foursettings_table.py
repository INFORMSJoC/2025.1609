#!/usr/bin/env python3
"""Normalize the four T1 integer settings for the Table 2 recipe."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path


STATISTICS_ROOT = Path(__file__).resolve().parents[1]
ROOT = Path(__file__).resolve().parents[3]
METHODS = {"Str0+VI0", "Str1+VI0", "Str0+VI1", "Str1+VI1"}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--main-summary", type=Path, default=ROOT / "results/summarized/T1/summary.csv")
    parser.add_argument("--output", type=Path, default=ROOT / "output/artifacts/inputs/t2_foursettings_table2.csv")
    args = parser.parse_args()
    rows = []
    with args.main_summary.open(newline="") as handle:
        for source in csv.DictReader(handle):
            if source["method"] not in METHODS:
                continue
            header = (ROOT / f"data/pmed{source['data']}.txt").read_text().splitlines()[0].split()
            rows.append({
                "instance": "|".join((source["data"], source["r"], source["R"], source["theta"])),
                "dataset": source["data"],
                "dataset_label": f"{source['data']}-{header[0]}-{header[2]}",
                "theta": source["theta"],
                "theta_label": rf"$\theta={source['theta']}$",
                "method": source["method"],
                "solved": str(source["status"] == "OPTIMAL"),
                "time": source["time"],
                "nodes": source["node"],
                "gap": source["gap"],
                "rgap": source["rgap"],
            })
    keys = [(row["instance"], row["method"]) for row in rows]
    if len(keys) != len(set(keys)):
        raise ValueError("Duplicate instance x method records.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fields = list(rows[0])
    with args.output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    print(f"Wrote {len(rows)} records to {args.output}")


if __name__ == "__main__":
    main()
