#!/usr/bin/env python3
"""Build research-task-v1 JSONL from MPCLP's generated task records."""

import argparse
import hashlib
import json
import re
import shlex
from pathlib import Path
from typing import Dict, List, Set


def normalize_task_id(task_name: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9._-]+", "-", task_name).strip("-.")
    if not normalized:
        normalized = "task"
    if len(normalized) > 128:
        digest = hashlib.sha1(task_name.encode("utf-8")).hexdigest()[:10]
        normalized = f"{normalized[:117]}-{digest}"
    return normalized


def metadata_from_args(task_name: str, argv: List[str]) -> Dict[str, object]:
    values = {}  # type: Dict[str, str]
    for item in argv[2:]:
        if "=" in item:
            key, value = item.split("=", 1)
            values[key] = value

    metadata = {  # type: Dict[str, object]
        "experiment": "MPCLP",
        "task_name": task_name,
    }
    data = values.get("fn")
    if data:
        metadata["instance"] = Path(data).stem
    for key in ("theta", "r", "R", "mode", "prob_func", "mixture_seed", "mixture_low_share"):
        if key in values:
            metadata[key] = values[key]
    return metadata


def build_tasks(records_path: Path, output_path: Path, time_limit_seconds: int) -> int:
    tasks = []
    seen_ids = set()  # type: Set[str]
    for line_number, raw_line in enumerate(records_path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw_line:
            continue
        try:
            task_name, command = raw_line.split("\t", 1)
        except ValueError as exc:
            raise ValueError(f"invalid task record at line {line_number}") from exc
        task_id = normalize_task_id(task_name)
        if task_id in seen_ids:
            raise ValueError(f"duplicate normalized task id: {task_id}")
        seen_ids.add(task_id)
        argv = shlex.split(command)
        if len(argv) < 2:
            raise ValueError(f"invalid command at line {line_number}")
        if Path(argv[0]).is_absolute() or any(Path(arg.split("=", 1)[-1]).is_absolute() for arg in argv[1:]):
            raise ValueError(f"absolute command path at line {line_number}")
        tasks.append(
            {
                "schema": "research-task-v1",
                "id": task_id,
                "command": {"executable": argv[0], "args": argv[1:]},
                "outputs": {"stdout": f"{task_name}.out", "stderr": f"{task_name}.err"},
                "resources": {"time_limit_seconds": time_limit_seconds, "cpus": 1},
                "metadata": metadata_from_args(task_name, argv),
            }
        )

    if not tasks:
        raise ValueError("task record file contains no tasks")
    output_path.write_text(
        "".join(json.dumps(task, sort_keys=True, separators=(",", ":")) + "\n" for task in tasks),
        encoding="utf-8",
    )
    return len(tasks)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("records", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--time-limit-seconds", type=int, required=True)
    args = parser.parse_args()
    if args.time_limit_seconds < 1:
        parser.error("--time-limit-seconds must be positive")
    count = build_tasks(args.records, args.output, args.time_limit_seconds)
    print(f"Wrote {count} tasks to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
