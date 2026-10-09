#!/usr/bin/env python3
"""Generate coordinate pmed instances matching the ORlib pmed size grid.

Each generated instance uses independent random customer and candidate-location
coordinates in the square [0, 100] x [0, 100]. The output format is read by
`src/common/readdata.jl` and keeps the first three fields compatible with the
existing pmed label convention:

    n_locations n_customers K COORD_PMED ...
"""
from __future__ import annotations

import argparse
import random
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class PmedSize:
    source_id: int
    n_vertices: int
    k: int


def read_orlib_sizes(data_dir: Path) -> list[PmedSize]:
    sizes: list[PmedSize] = []
    for source_id in range(1, 41):
        first = (data_dir / f"pmed{source_id}.txt").read_text().splitlines()[0].split()
        sizes.append(PmedSize(source_id=source_id, n_vertices=int(first[0]), k=int(first[2])))
    return sizes


def random_points(rng: random.Random, count: int) -> list[tuple[float, float]]:
    return [(rng.uniform(0.0, 100.0), rng.uniform(0.0, 100.0)) for _ in range(count)]


def write_instance(path: Path, size: PmedSize, target_id: int, seed: int) -> None:
    rng = random.Random(seed)
    customers = random_points(rng, size.n_vertices)
    locations = random_points(rng, size.n_vertices)

    lines = [
        (
            f"{size.n_vertices} {size.n_vertices} {size.k} COORD_PMED "
            f"seed={seed} source=pmed{size.source_id}"
        ),
        "CUSTOMERS",
    ]
    lines.extend(f"{idx} {x:.6f} {y:.6f}" for idx, (x, y) in enumerate(customers, start=1))
    lines.append("LOCATIONS")
    lines.extend(f"{idx} {x:.6f} {y:.6f}" for idx, (x, y) in enumerate(locations, start=1))
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data")
    parser.add_argument("--first-id", type=int, default=41)
    parser.add_argument("--base-seed", type=int, default=20260707)
    args = parser.parse_args()

    args.data_dir.mkdir(parents=True, exist_ok=True)
    for offset, size in enumerate(read_orlib_sizes(args.data_dir)):
        target_id = args.first_id + offset
        seed = args.base_seed + size.source_id
        write_instance(args.data_dir / f"pmed{target_id}.txt", size, target_id, seed)
        print(f"pmed{target_id}.txt source=pmed{size.source_id} n={size.n_vertices} K={size.k} seed={seed}")


if __name__ == "__main__":
    main()
