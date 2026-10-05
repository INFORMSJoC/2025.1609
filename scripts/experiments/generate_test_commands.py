#!/usr/bin/env python3
"""Expand semantic MPCLP experiment JSON into deterministic shell commands."""

import argparse
import itertools
import json
import math
import os
import re
import shlex
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, NamedTuple, Optional, Sequence, Set, Tuple


ROOT = Path(__file__).resolve().parents[2]


class Dataset(NamedTuple):
    instance_ids: range
    radius_pairs: Tuple[Tuple[int, int], ...]


DATASETS = {  # type: Dict[str, Dataset]
    "T1": Dataset(range(1, 41), ((5, 20), (10, 25))),
    "T2": Dataset(range(1, 41), ((1, 20), (2, 20))),
    "CoordPmed-T1": Dataset(range(41, 81), ((5, 20), (10, 25))),
    "CoordPmed-T2": Dataset(range(41, 81), ((1, 20), (2, 20))),
}


BASE_ARGS = {  # type: Dict[str, Any]
    "init": 1,
    "pre": 1,
    "cutM": 1,
    "cutP": 1,
    "cutC": 1,
    "msg": "default",
    "timelimit": 3600,
    "EPS": "1e-3",
    "is_Euclidean": 0,
    "node_space": 5,
    "which_first": "both",
    "prob_func": "linear",
    # Named in every command and in every run name, like the other base settings:
    # the archived logs of the paper all carry the token, and a run that leaves
    # co-location to the solver default would otherwise be named for a setting it
    # never stated.
    "colocation": 1,
}


# Each recipe method is passed to the solver as methods=<setting of the paper>.
# The switches a name stands for live in the solver (METHOD_PRESETS in
# src/common/param.jl), so the generated commands stay free of them.
METHODS = {  # type: Dict[str, Dict[str, Any]]
    "BnC-B": {"methods": "BnC-B"},
    "bBnC-I": {"methods": "bBnC-I"},
    "bBnC-I+E": {"methods": "bBnC-I+E"},
    "bBnC-I+L": {"methods": "bBnC-I+L"},
    "bBnC-I+E+L": {"methods": "bBnC-I+E+L"},
    # The K-median comparison solves the full setting of the paper with pmed=1.
    "Kmedian": {"methods": "bBnC-I+E+L", "pmed": 1},
}


SEMANTIC_ARGS = {  # type: Dict[str, str]
    "theta": "theta",
    "time_limit": "timelimit",
    "probability_function": "prob_func",
    "co_location": "colocation",
    "epsilon": "EPS",
    "node_space": "node_space",
    "mixture_low_share": "mixture_low_share",
    "mixture_low_min": "mixture_low_min",
    "mixture_low_max": "mixture_low_max",
    "mixture_high_min": "mixture_high_min",
    "mixture_high_max": "mixture_high_max",
    "mixture_seed": "mixture_seed",
}


class Run(NamedTuple):
    run_id: str
    command: str
    stdout_path: Path
    stderr_path: Path


def fail(message: str) -> ValueError:
    return ValueError(message)


def load_spec(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise fail(f"experiment spec does not exist: {path}") from exc
    except json.JSONDecodeError as exc:
        raise fail(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise fail("experiment spec must be a JSON object")
    return value


def require_string_list(spec: Mapping[str, Any], key: str) -> List[str]:
    value = spec.get(key)
    if not isinstance(value, list) or not value or not all(isinstance(x, str) and x for x in value):
        raise fail(f"{key} must be a non-empty list of strings")
    if len(value) != len(set(value)):
        raise fail(f"{key} contains duplicate values")
    return value


def validate_relative_path(value: Any, key: str) -> Path:
    if not isinstance(value, str) or not value:
        raise fail(f"{key} must be a non-empty relative path")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise fail(f"{key} must stay within the project workspace: {value}")
    return path


def normalize_scalar(value: Any) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, float):
        if not math.isfinite(value):
            raise fail("numeric parameters must be finite")
        return format(value, ".15g")
    if isinstance(value, (str, int)) and not isinstance(value, bool):
        text = str(value)
        if not text or any(character.isspace() for character in text):
            raise fail(f"parameter values must be non-empty scalars without whitespace: {value!r}")
        return text
    raise fail(f"unsupported parameter value: {value!r}")


def semantic_args(values: Mapping[str, Any]) -> Dict[str, str]:
    unknown = sorted(set(values) - set(SEMANTIC_ARGS))
    if unknown:
        raise fail(f"unsupported semantic parameter(s): {', '.join(unknown)}")
    return {SEMANTIC_ARGS[key]: normalize_scalar(value) for key, value in values.items()}


def grid_rows(grid: Any) -> List[Dict[str, Any]]:
    if not isinstance(grid, dict) or not grid:
        raise fail("parameter_grid must be a non-empty object")
    keys = sorted(grid)
    unknown = sorted(set(keys) - set(SEMANTIC_ARGS))
    if unknown:
        raise fail(f"unsupported parameter_grid key(s): {', '.join(unknown)}")
    value_lists = []  # type: List[List[Any]]
    for key in keys:
        values = grid[key]
        if not isinstance(values, list) or not values:
            raise fail(f"parameter_grid.{key} must be a non-empty list")
        normalized = [normalize_scalar(value) for value in values]
        if len(normalized) != len(set(normalized)):
            raise fail(f"parameter_grid.{key} contains duplicate values")
        value_lists.append(values)
    return [dict(zip(keys, values)) for values in itertools.product(*value_lists)]


def slug(value: str, limit: int = 24) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-") or "run"
    return result[:limit].rstrip("-")


def make_run_id(identity: Mapping[str, Any]) -> str:
    """Return the identifier of a run, which is also the name of its log.

    The parts of the identifier are documented in scripts/experiments/README.md.
    """
    arguments = identity["arguments"]
    if not isinstance(arguments, Mapping):
        raise fail("run identity arguments must be an object")

    def value(key: str) -> str:
        return normalize_scalar(arguments[key])

    parts = [
        slug(str(identity["dataset"])),
        slug(Path(str(identity["instance"])).stem),
        f"r{value('r')}",
        f"R{value('R')}",
        f"theta{value('theta')}",
        slug(str(identity["method"])),
    ]

    probability_function = arguments.get("prob_func")
    if probability_function is not None:
        parts.append(slug(normalize_scalar(probability_function)))

    if probability_function is not None and normalize_scalar(probability_function).lower() in {
        "facility_mixture",
        "facility_mix",
        "low_high",
    }:
        if "mixture_low_share" in arguments:
            low_percentage = int(float(value("mixture_low_share")) * 100 + 0.5)
            parts.append(f"lh{low_percentage:02d}{100 - low_percentage:02d}")
        if "mixture_low_min" in arguments and "mixture_low_max" in arguments:
            parts.append(f"low{value('mixture_low_min')}to{value('mixture_low_max')}")
        if "mixture_high_min" in arguments and "mixture_high_max" in arguments:
            parts.append(f"high{value('mixture_high_min')}to{value('mixture_high_max')}")
        if "mixture_seed" in arguments:
            parts.append(f"seed{value('mixture_seed')}")

    if "colocation" in arguments:
        parts.append("coloc" if value("colocation") == "1" else "nocoloc")
    parts.append(f"tl{value('timelimit')}")

    if value("EPS") != normalize_scalar(BASE_ARGS["EPS"]):
        parts.append(f"eps{value('EPS')}")
    if value("node_space") != normalize_scalar(BASE_ARGS["node_space"]):
        parts.append(f"nodespace{value('node_space')}")
    return "-".join(parts)


def command_from_args(arguments: Mapping[str, Any], stdout_path: Path, stderr_path: Path) -> str:
    ordered = ["methods", "fn", "theta", "r", "R"]
    keys = ordered + sorted(set(arguments) - set(ordered))
    argv = ["julia", "src/mgclp.jl"] + [f"{key}={arguments[key]}" for key in keys]
    return " ".join(shlex.quote(value) for value in argv) + (
        f" > {shlex.quote(str(stdout_path))} 2> {shlex.quote(str(stderr_path))}"
    )


def select_instances(dataset: Dataset, selected: Any) -> Sequence[int]:
    if selected is None:
        return list(dataset.instance_ids)
    if not isinstance(selected, list) or not selected or not all(type(item) is int for item in selected):
        raise fail("instance_ids must be a non-empty list of integers")
    if len(selected) != len(set(selected)):
        raise fail("instance_ids contains duplicate values")
    invalid = [item for item in selected if item not in dataset.instance_ids]
    if invalid:
        raise fail(f"instance_ids not available in selected dataset: {invalid}")
    return selected


def expand_spec(spec: Mapping[str, Any]) -> Tuple[List[Run], int, Path]:
    if spec.get("schema_version") == 2:
        if spec.get("project") != "MPCLP":
            raise fail('project must be "MPCLP"')
        output_dir = validate_relative_path(spec.get("output_dir"), "output_dir")
        blocks = spec.get("experiment_blocks")
        if not isinstance(blocks, list) or not blocks:
            raise fail("experiment_blocks must be a non-empty list")

        combined_runs = []  # type: List[Run]
        maximum_time_limit = 0
        seen_ids = set()  # type: Set[str]
        seen_outputs = set()  # type: Set[Path]
        for index, block in enumerate(blocks, start=1):
            if not isinstance(block, dict):
                raise fail(f"experiment_blocks[{index - 1}] must be an object")
            block_spec = dict(block)
            block_spec.update(
                {
                    "schema_version": 1,
                    "project": "MPCLP",
                    "output_dir": str(output_dir),
                }
            )
            block_spec.pop("name", None)
            block_runs, block_time_limit, _ = expand_spec(block_spec)
            maximum_time_limit = max(maximum_time_limit, block_time_limit)
            for run in block_runs:
                if (
                    run.run_id in seen_ids
                    or run.stdout_path in seen_outputs
                    or run.stderr_path in seen_outputs
                ):
                    raise fail(
                        f"duplicate run across experiment blocks: {run.run_id} "
                        f"(block {index})"
                    )
                seen_ids.add(run.run_id)
                seen_outputs.update((run.stdout_path, run.stderr_path))
                combined_runs.append(run)
        return combined_runs, maximum_time_limit, output_dir

    if spec.get("schema_version") != 1:
        raise fail("schema_version must be 1 or 2")
    if spec.get("project") != "MPCLP":
        raise fail('project must be "MPCLP"')

    dataset_names = require_string_list(spec, "datasets")
    method_names = require_string_list(spec, "methods")
    unknown_datasets = sorted(set(dataset_names) - set(DATASETS))
    unknown_methods = sorted(set(method_names) - set(METHODS))
    if unknown_datasets:
        raise fail(f"unknown dataset(s): {', '.join(unknown_datasets)}")
    if unknown_methods:
        raise fail(f"unknown method(s): {', '.join(unknown_methods)}")

    fixed = spec.get("fixed_args", {})
    if not isinstance(fixed, dict):
        raise fail("fixed_args must be an object")
    grid = spec.get("parameter_grid")
    overlap = sorted(set(fixed) & set(grid if isinstance(grid, dict) else {}))
    if overlap:
        raise fail(f"parameters cannot be both fixed and gridded: {', '.join(overlap)}")
    fixed_cli = semantic_args(fixed)
    rows = grid_rows(grid)
    output_dir = validate_relative_path(spec.get("output_dir"), "output_dir")

    time_limit_texts = [fixed_cli.get("timelimit", normalize_scalar(BASE_ARGS["timelimit"]))]
    if "time_limit" in (grid if isinstance(grid, dict) else {}):
        time_limit_texts = [normalize_scalar(row["time_limit"]) for row in rows]
    try:
        time_limits = [float(value) for value in time_limit_texts]
    except ValueError as exc:
        raise fail("time_limit must be numeric") from exc
    if any(value <= 0 for value in time_limits):
        raise fail("time_limit must be positive")
    time_limit = math.ceil(max(time_limits))

    runs = []  # type: List[Run]
    seen_ids = set()  # type: Set[str]
    seen_outputs = set()  # type: Set[Path]
    for dataset_name in dataset_names:
        dataset = DATASETS[dataset_name]
        instances = select_instances(dataset, spec.get("instance_ids"))
        for instance_id, (radius, large_radius), method_name, row in itertools.product(
            instances, dataset.radius_pairs, method_names, rows
        ):
            instance = f"data/pmed{instance_id}.txt"
            if not (ROOT / instance).is_file():
                raise fail(f"instance file does not exist: {instance}")
            row_cli = semantic_args(row)
            arguments = dict(BASE_ARGS)  # type: Dict[str, Any]
            arguments.update(METHODS[method_name])
            arguments.update(fixed_cli)
            arguments.update(row_cli)
            arguments.update({"fn": instance, "r": radius, "R": large_radius})
            identity = {
                "schema_version": 1,
                "project": "MPCLP",
                "dataset": dataset_name,
                "instance": instance,
                "method": method_name,
                "arguments": {key: normalize_scalar(value) for key, value in arguments.items()},
            }
            run_id = make_run_id(identity)
            stdout_path = output_dir / f"{run_id}.out"
            stderr_path = output_dir / f"{run_id}.err"
            if run_id in seen_ids or stdout_path in seen_outputs or stderr_path in seen_outputs:
                raise fail(f"duplicate run identity or output path: {run_id}")
            seen_ids.add(run_id)
            seen_outputs.update((stdout_path, stderr_path))
            runs.append(
                Run(
                    run_id=run_id,
                    command=command_from_args(arguments, stdout_path, stderr_path),
                    stdout_path=stdout_path,
                    stderr_path=stderr_path,
                )
            )
    return runs, time_limit, output_dir


def render_commands(runs: Iterable[Run], time_limit: int, parallelism: int) -> str:
    run_list = list(runs)
    waves = math.ceil(len(run_list) / parallelism)
    estimated_seconds = waves * time_limit
    header = [
        "#!/usr/bin/env bash",
        "# Generated by scripts/experiments/generate_test_commands.py; edit the JSON source, not this file.",
        f"# command_count={len(run_list)}",
        f"# maximum_time_limit_per_command_seconds={time_limit}",
        f"# planning_parallelism={parallelism}",
        f"# estimated_waves={waves}",
        f"# estimated_wall_time_upper_bound_seconds={estimated_seconds}",
        "# Estimate excludes queue time, startup overhead, retries, and data transfer.",
    ]
    return "\n".join(header + [run.command for run in run_list]) + "\n"


def summary(runs: Sequence[Run], time_limit: int, parallelism: int, destination: str) -> str:
    waves = math.ceil(len(runs) / parallelism)
    seconds = waves * time_limit
    return (
        f"validated {len(runs)} commands; maximum_time_limit={time_limit}s; parallelism={parallelism}; "
        f"waves={waves}; wall_time_upper_bound={seconds}s; output={destination}; "
        "queue/startup/retry/data-transfer time excluded"
    )


def execution_preflight(output_dir: Path, command_path: Path, root: Path = ROOT) -> str:
    entrypoint = root / "src/mgclp.jl"
    if not entrypoint.is_file():
        raise fail(f"solver entrypoint does not exist: {entrypoint}")

    julia = shutil.which("julia")
    if julia is None:
        raise fail("Julia executable was not found on PATH")

    result_dir = root / output_dir
    resolved_command_path = command_path if command_path.is_absolute() else root / command_path
    directories = [
        ("result output directory", result_dir),
        ("command-file directory", resolved_command_path.parent),
    ]
    checked = []  # type: List[str]
    for label, directory in directories:
        try:
            directory.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            raise fail(f"cannot create {label}: {directory}: {exc}") from exc
        if not directory.is_dir():
            raise fail(f"{label} is not a directory: {directory}")
        if not os.access(str(directory), os.W_OK):
            raise fail(f"{label} is not writable: {directory}")
        checked.append(str(directory))

    return (
        f"preflight passed: julia={julia}; entrypoint={entrypoint}; "
        f"result_dir={checked[0]}; command_dir={checked[1]}"
    )


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate independently executable MPCLP commands from semantic experiment JSON."
    )
    parser.add_argument("spec", type=Path, help="experiment JSON path")
    parser.add_argument("--output", type=Path, help="generated .sh path (required unless --dry-run)")
    parser.add_argument("--dry-run", action="store_true", help="validate and print commands without writing")
    parser.add_argument(
        "--parallelism",
        type=int,
        default=1,
        help="planning concurrency used only for the runtime upper bound (default: 1)",
    )
    args = parser.parse_args(argv)
    if not args.dry_run and args.output is None:
        parser.error("--output is required unless --dry-run is used")
    if args.parallelism < 1:
        parser.error("--parallelism must be positive")
    return args


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    try:
        runs, time_limit, output_dir = expand_spec(load_spec(args.spec))
        rendered = render_commands(runs, time_limit, args.parallelism)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if args.dry_run:
        sys.stdout.write(rendered)
        print(summary(runs, time_limit, args.parallelism, "dry-run (no files written)"), file=sys.stderr)
        return 0

    assert args.output is not None
    try:
        preflight = execution_preflight(output_dir, args.output)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    resolved_output = args.output if args.output.is_absolute() else ROOT / args.output
    resolved_output.write_text(rendered, encoding="utf-8")
    os.chmod(resolved_output, resolved_output.stat().st_mode | 0o111)
    print(preflight)
    print(summary(runs, time_limit, args.parallelism, str(args.output)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
