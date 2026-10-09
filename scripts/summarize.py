#!/usr/bin/env python3
"""Build Research OS control-plane and record-level summaries for MPCLP.

Stdout is reserved for exactly one JSON object.  Diagnostics go to stderr.
The optional record artifact is written atomically and never changes raw logs.
"""
import argparse
import csv
import json
import math
import os
import re
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


NUMBER = r"[-+0-9.eE]+"
FILENAME = re.compile(
    r"^mgclp(?P<data>\d+)-(?P<r>\d+)-(?P<R>\d+)-(?P<theta>[0-9.]+)-(?P<body>.+)\.out$"
)
SEMANTIC_FILENAME = re.compile(
    r"^t(?P<testset>\d+)-pmed(?P<data>\d+)-r(?P<r>\d+)-R(?P<R>\d+)-"
    r"theta(?P<theta>[0-9.]+)-(?P<body>.+)-tl(?P<timelimit>\d+)(?:-.+)?\.out$"
)
# The methods of the paper, with the labels the summaries use for them: the
# setting a run expanded to, and the method it belongs to.
METHOD_LABELS = {  # type: Dict[str, Tuple[str, str]]
    "bBnC-I": ("Str0+VI0", "Str0+VI0"),
    "bBnC-I+E": ("Str1+VI0", "Str1+VI0"),
    "bBnC-I+L": ("Str0+VI1", "Str0+VI1"),
    "bBnC-I+E+L": ("Str1+VI1+LocalSearch1", "Str1+VI1"),
}
# Log file names carry the slug of a method name; longest token first.
LOG_TOKENS = ("bbnc-i-e-l", "bbnc-i-l", "bbnc-i-e", "bbnc-i")
LOG_TOKEN_METHOD = {
    "bbnc-i": "bBnC-I",
    "bbnc-i-e": "bBnC-I+E",
    "bbnc-i-l": "bBnC-I+L",
    "bbnc-i-e-l": "bBnC-I+E+L",
}
BINARY_TOKENS = ("bin", "bnc-b")
# The runs recorded before the methods were named carry <s><str>-<v><cutF>[-l1]
# tokens in their log names, and the same labels with capitals in their job
# names; both are recognized so that those runs can still be summarized.
LEGACY_TOKEN = re.compile(r"^s(?P<str>[01])-v(?P<cutF>[01])(?P<ls>-l1)?(?![a-z0-9])")
LEGACY_JOB_LABEL = re.compile(r"^[sS](?P<str>[01])\+[vV](?P<cutF>[01])(?P<ls>\+L1)?$")


def starts_with_token(body: str, token: str) -> bool:
    """Report whether a log body starts with the complete method token.

    The token has to end on a non-alphanumeric character, so that the token of one
    setting does not match the log name of another one.
    """
    return re.match(re.escape(token) + r"(?![a-z0-9])", body) is not None


def setting_and_method(body: str) -> Tuple[Optional[str], Optional[str]]:
    """Return the labels of the setting and of the method of a log body."""
    for token in LOG_TOKENS:
        if starts_with_token(body, token):
            return METHOD_LABELS[LOG_TOKEN_METHOD[token]]
    legacy = LEGACY_TOKEN.match(body)
    if legacy:
        label = "Str{0}+VI{1}".format(legacy.group("str"), legacy.group("cutF"))
        return (label + "+LocalSearch1" if legacy.group("ls") else label), label
    return None, None


def canonical_setting(value: str) -> str:
    """Label of a setting given by the name of a job or by a log name token."""
    legacy = LEGACY_JOB_LABEL.match(value)
    if legacy:
        label = "Str{0}+VI{1}".format(legacy.group("str"), legacy.group("cutF"))
        return label + "+LocalSearch1" if legacy.group("ls") else label
    return METHOD_LABELS.get(value, (value, ""))[0]
FATAL_ERROR = re.compile(
    r"ERROR:|LoadError|Segmentation fault|license[^\n]*error", re.IGNORECASE
)
BASE_RECORD_COLUMNS = [
    "family", "method", "mode", "coloc", "setting", "data", "r", "R",
    "theta", "p_s", "status", "time", "node", "gap", "rgap", "obj",
    "obj_calc", "k", "ncl", "nl", "mcl", "nvar", "ncut",
    "sum_etaM_solution", "sum_etaP_solution", "path",
]
EXPERIMENT_COLUMNS = [
    "variant", "testset", "lh", "low_share", "high_share", "seed", "ncl_nl", "i_count",
]
RECORD_COLUMNS = BASE_RECORD_COLUMNS + EXPERIMENT_COLUMNS


def finite_mean(values: List[float]) -> Optional[float]:
    return None if not values else sum(values) / len(values)


def number_or_none(value: Any) -> Optional[float]:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def text_number(value: Optional[float]) -> str:
    return "" if value is None else format(value, ".15g")


def method_name(mode: Optional[str], coloc: Optional[str], setting: Optional[str]) -> Optional[str]:
    if mode == "KMED":
        return "KMED"
    if mode not in {"Int", "Bin"} or coloc not in {"ColocOn", "NoCoLoc"}:
        return None
    suffix = "NC-" if coloc == "NoCoLoc" else ""
    return "B&C-{0}{1}".format(suffix, "I" if mode == "Int" else "B")


def parse_filename(path: Path) -> Dict[str, Any]:
    semantic = SEMANTIC_FILENAME.match(path.name)
    if semantic:
        body = semantic.group("body")
        is_kmedian = body.startswith("kmedian-")
        setting, method = setting_and_method(body)
        if is_kmedian:
            mode, method, setting = "KMED", "KMED", None
        elif any(starts_with_token(body, token) for token in BINARY_TOKENS):
            mode, method, setting = "Bin", "B&C-B", None
        else:
            mode = "Int" if setting is not None else None
        coloc = "NoCoLoc" if "-nocoloc" in body else "ColocOn" if "-coloc" in body else None
        theta = semantic.group("theta").rstrip("0").rstrip(".") or "0"
        lh_match = re.search(r"-lh(?P<lh>\d{4})(?:-|$)", body)
        seed_match = re.search(r"-seed(?P<seed>\d+)(?:-|$)", body)
        lh = lh_match.group("lh") if lh_match else None
        return {
            "family": "facility_mixture" if "facility-mixture" in body else "pmed",
            "method": method,
            "mode": mode,
            "coloc": coloc,
            "setting": setting,
            "data": semantic.group("data"),
            "r": semantic.group("r"),
            "R": semantic.group("R"),
            "theta": theta,
            "testset": "T{0}".format(semantic.group("testset")),
            "lh": lh,
            "low_share": None if not lh else text_number(int(lh[:2]) / 100.0),
            "high_share": None if not lh else text_number(int(lh[2:]) / 100.0),
            "seed": seed_match.group("seed") if seed_match else None,
        }

    match = FILENAME.match(path.name)
    if not match:
        return {}
    body = match.group("body")
    mode_match = re.search(r"(?:^|-)(Int|Bin)(?:-|$)", body)
    mode = mode_match.group(1) if mode_match else ("KMED" if "theta1" in body else None)
    coloc = "NoCoLoc" if "NoCoLoc" in body else "ColocOn" if "ColocOn" in body else None
    setting_match = re.search(r"(?:ColocOn|NoCoLoc)\+(.+)$", body)
    setting = setting_match.group(1) if setting_match else ""
    setting = canonical_setting(setting)
    sp_match = re.search(r"-sp(?P<sp>\d+)(?:-|$)", body)
    lh_match = re.search(r"-lh(?P<lh>\d{4})(?:-|$)", body)
    seed_match = re.search(r"-seed(?P<seed>\d+)(?:-|$)", body)
    lh = lh_match.group("lh") if lh_match else None
    metadata = {
        "family": "facility_mixture" if "facility_mixture" in body else None,
        "method": method_name(mode, coloc, setting),
        "mode": mode,
        "coloc": coloc,
        "setting": setting or None,
        "data": match.group("data"),
        "r": match.group("r"),
        "R": match.group("R"),
        "theta": match.group("theta").rstrip("0").rstrip(".") or "0",
        "p_s": None if not sp_match else text_number(int(sp_match.group("sp")) / 10.0),
        "lh": lh,
        "low_share": None if not lh else text_number(int(lh[:2]) / 100.0),
        "high_share": None if not lh else text_number(int(lh[2:]) / 100.0),
        "seed": seed_match.group("seed") if seed_match else None,
    }
    return metadata


def parse_log(path: Path) -> Optional[Dict[str, Any]]:
    values = {}  # type: Dict[str, Any]
    ncl_dist = 0
    nl_dist = 0
    mcl = 0
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError as exc:
        print("Cannot read {0}: {1}".format(path, exc), file=sys.stderr)
        return None
    for raw_line in lines:
        line = raw_line.strip()
        matches = (
            ("status", r"^Termination Status:\s*(\S+)"),
            ("time", rf"^Solve Time:\s*({NUMBER})"),
            ("node", rf"^Number of Nodes:\s*({NUMBER})"),
            ("gap", rf"^Current gap:\s*({NUMBER})"),
            ("obj", rf"^Objective Value:\s*({NUMBER})"),
            ("obj_calc", rf"^Objective Value \(calc\):\s*({NUMBER})"),
            ("root_best_bound", rf"^Root Best Bound\s+({NUMBER})"),
            ("best_bound", rf"^Best Bound:\s*({NUMBER})"),
            ("best_integer", rf"^Best Integer:\s*({NUMBER})"),
            ("k", r"^K\s+(\d+)"),
            ("i_count", r"^\|V\|\s+(\d+)"),
            ("nvar", r"^Reduced MIP has\s+\d+\s+rows,\s+(\d+)\s+columns"),
            ("sum_etaM_solution", rf"^sum_etaM\s*=\s*{NUMBER}\s*/\s*({NUMBER})"),
            ("sum_etaP_solution", rf"^sum_etaP\s*=\s*{NUMBER}\s*/\s*({NUMBER})"),
        )
        for field, pattern in matches:
            found = re.match(pattern, line)
            if found:
                values[field] = found.group(1) if field == "status" else number_or_none(found.group(1))
        found = re.match(r"^Number of Closed Sites:\s*(\d+)\s*/\s*(\d+)", line)
        if found:
            values["ncl_reported"], values["nl_reported"] = int(found.group(1)), int(found.group(2))
        found = re.match(r"^([1-9]\d*):\s*(.*)", line)
        if found:
            facilities = int(found.group(1))
            sites = [item for item in found.group(2).split(",") if item.strip()]
            nl_dist += len(sites)
            if facilities > 1:
                ncl_dist += len(sites)
            mcl = max(mcl, facilities)
        if re.match(r"^(max|prod_oa|prod_oa_mir|prod_bin|prod_sm|prod_sm_C|prod_sm_fixed|prod_sm_lift|prod_local|facet)\s", line):
            values["ncut"] = values.get("ncut", 0) + sum(int(v) for v in re.findall(r"\]\s+(\d+)\s*/", line))
    status = values.get("status")
    # A printed termination status is terminal evidence.  Keep future solver
    # terminal enums instead of maintaining a brittle allow-list; the one
    # explicit nonterminal MOI value is not a completed record.
    if not status or status == "OPTIMIZE_NOT_CALLED":
        return None
    if status == "OPTIMAL" and values.get("gap") is None:
        values["gap"] = 0.0
    if values.get("gap") is None:
        best_bound, best_integer = values.get("best_bound"), values.get("best_integer")
        if best_bound is not None and best_integer not in {None, 0.0}:
            values["gap"] = max((best_bound - best_integer) / abs(best_integer) * 100.0, 0.0)
    if nl_dist:
        values["ncl"], values["nl"], values["mcl"] = ncl_dist, nl_dist, mcl or None
    elif "ncl_reported" in values:
        values["ncl"], values["nl"] = values["ncl_reported"], values["nl_reported"]
    best, obj_calc = values.get("root_best_bound"), values.get("obj_calc")
    if best is not None and obj_calc not in {None, 0.0}:
        values["rgap"] = 0.0 if status == "OPTIMAL" and (values.get("node") or 0) <= 3 else max((best - obj_calc) / obj_calc * 100.0, 0.0)
    return values


def raw_record(path: Path, workspace: Path, values: Dict[str, Any]) -> Dict[str, str]:
    record = {key: "" for key in RECORD_COLUMNS}
    for key, value in parse_filename(path).items():
        record[key] = "" if value is None else str(value)
    for key in ("status", "time", "node", "gap", "rgap", "obj", "obj_calc", "k", "ncl", "nl", "mcl", "nvar", "ncut", "sum_etaM_solution", "sum_etaP_solution", "i_count"):
        value = values.get(key)
        record[key] = str(value) if key == "status" and value is not None else text_number(number_or_none(value))
    if record["ncl"] and record["nl"] and number_or_none(record["nl"]) not in {None, 0.0}:
        record["ncl_nl"] = text_number(number_or_none(record["ncl"]) / number_or_none(record["nl"]))
    record["path"] = str(path.relative_to(workspace))
    return record


def parse_summary_csv(path: Path, allow_empty: bool = False) -> Optional[Tuple[List[Dict[str, str]], List[str]]]:
    try:
        source = path.open(newline="", errors="replace")
    except OSError as exc:
        print("Cannot read {0}: {1}; falling back to raw logs".format(path, exc), file=sys.stderr)
        return None
    records = []  # type: List[Dict[str, str]]
    with source:
        reader = csv.DictReader(source)
        fields = list(reader.fieldnames or [])
        if not {"status", "path"}.issubset(set(fields)) or not ({"obj", "obj_calc"} & set(fields)):
            print("Ignoring {0}: invalid summary.csv schema; falling back to raw logs".format(path), file=sys.stderr)
            return None
        for row_number, row in enumerate(reader, start=2):
            status = (row.get("status") or "").strip()
            if not status:
                print("Ignoring {0} row {1}: missing status".format(path, row_number), file=sys.stderr)
                continue
            record = {key: (row.get(key) or "").strip() for key in RECORD_COLUMNS}
            record["status"] = status
            path_metadata = parse_filename(Path(record["path"])) if record["path"] else {}
            for key, value in path_metadata.items():
                # The semantic filename is the run identity source of truth.
                # This also migrates older summaries that stored values such as
                # data="pmed1" or omitted facility-mixture dimensions.
                if key in record and value is not None:
                    record[key] = str(value)
            if status == "OPTIMAL" and not record["gap"]:
                record["gap"] = "0"
            records.append(record)
    if not records and not allow_empty:
        print("Ignoring {0}: no valid records; falling back to raw logs".format(path), file=sys.stderr)
        return None
    return records, RECORD_COLUMNS


def write_records_atomic(path: Path, records: List[Dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile("w", newline="", encoding="utf-8", dir=str(path.parent), prefix=".{0}.".format(path.name), suffix=".tmp", delete=False) as handle:
            temp_name = handle.name
            writer = csv.DictWriter(handle, fieldnames=RECORD_COLUMNS, lineterminator="\n")
            writer.writeheader()
            writer.writerows({key: record.get(key, "") for key in RECORD_COLUMNS} for record in records)
            handle.flush()
            os.fsync(handle.fileno())
        validated = parse_summary_csv(Path(temp_name), allow_empty=True)
        if validated is None or len(validated[0]) != len(records):
            raise ValueError("record CSV failed schema validation")
        os.replace(temp_name, str(path))
        temp_name = None
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except OSError:
                pass


def record_value(record: Dict[str, str], key: str) -> Optional[float]:
    aliases = {"runtime": "time", "nodes": "node", "objective": "obj_calc"}
    column = aliases.get(key, key)
    value = number_or_none(record.get(column))
    if key == "objective" and value is None:
        value = number_or_none(record.get("obj"))
    return value


def metadata(record: Dict[str, str]) -> Dict[str, Any]:
    data = record.get("data") or ""
    return {
        "instance": (
            "pmed{0}".format(data) if record.get("family") == "pmed"
            else "mgclp{0}".format(data) if data else None
        ),
        "r": record.get("r") or None, "R": record.get("R") or None,
        "theta": record.get("theta") or None, "mode": record.get("mode") or None,
        "colocation": record.get("coloc") or None, "setting": record.get("setting") or None,
    }


def grouped_summary(records: List[Dict[str, str]], key: str) -> Dict[str, Dict[str, Any]]:
    column = "coloc" if key == "colocation" else key
    groups = defaultdict(list)  # type: Dict[str, List[Dict[str, str]]]
    for record in records:
        groups[record.get(column) or "unknown"].append(record)
    return {
        value: {
            "runs": len(members),
            "optimal": sum(member["status"] == "OPTIMAL" for member in members),
            "avg_runtime_seconds": finite_mean([v for v in (record_value(m, "runtime") for m in members) if v is not None]),
            "avg_gap_percent": finite_mean([v for v in (record_value(m, "gap") for m in members) if v is not None]),
        }
        for value, members in sorted(groups.items())
    }


def sample_record(record: Dict[str, str], category: str) -> Dict[str, Any]:
    sample = {"category": category, "path": record.get("path") or None}
    for key, value in metadata(record).items():
        if value is not None:
            sample[key] = value
    if record.get("status"):
        sample["status"] = record["status"]
    return sample


def relative_artifact(path: Path, workspace: Path) -> Optional[str]:
    try:
        return str(path.resolve().relative_to(workspace.resolve())) if path.is_file() else None
    except ValueError:
        return None


def command_paths(workspace: Path) -> Tuple[Optional[Path], List[Path], List[Path]]:
    command_file = workspace / "cmd.sh"
    if not command_file.is_file():
        return None, [], []
    stdout_paths = []  # type: List[Path]
    stderr_paths = []  # type: List[Path]
    try:
        lines = command_file.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        print("Cannot read {0}: {1}".format(command_file, exc), file=sys.stderr)
        return command_file, [], []

    def resolve_redirect(raw_path: str) -> Path:
        path = Path(raw_path)
        if path.is_absolute():
            return path
        parent_parts = path.parent.parts
        if parent_parts and tuple(workspace.parts[-len(parent_parts):]) == parent_parts:
            return workspace / path.name
        return workspace / path

    for line in lines:
        if not line.lstrip().startswith("julia "):
            continue
        stdout_match = re.search(r"(?<!\d)>\s*(?:'([^']+)'|\"([^\"]+)\"|(\S+))", line)
        stderr_match = re.search(r"2>\s*(?:'([^']+)'|\"([^\"]+)\"|(\S+))", line)
        if stdout_match:
            stdout_paths.append(resolve_redirect(next(value for value in stdout_match.groups() if value)))
        if stderr_match:
            stderr_paths.append(resolve_redirect(next(value for value in stderr_match.groups() if value)))
    return command_file, stdout_paths, stderr_paths


def nonempty_and_fatal_error_logs(paths: List[Path], workspace: Path) -> Tuple[List[str], List[str]]:
    nonempty = []  # type: List[str]
    fatal = []  # type: List[str]
    for path in paths:
        try:
            if not path.is_file() or path.stat().st_size == 0:
                continue
            relative = str(path.relative_to(workspace))
            nonempty.append(relative)
            if FATAL_ERROR.search(path.read_text(encoding="utf-8", errors="replace")):
                fatal.append(relative)
        except (OSError, ValueError) as exc:
            print("Cannot inspect {0}: {1}".format(path, exc), file=sys.stderr)
    return nonempty, fatal


def expected_file_entries(paths: List[Path]) -> Dict[Path, os.DirEntry]:
    """Find expected files with one directory scan per parent directory."""
    by_parent = defaultdict(set)  # type: Dict[Path, set]
    for path in paths:
        by_parent[path.parent].add(path.name)
    found = {}  # type: Dict[Path, os.DirEntry]
    for parent, names in by_parent.items():
        try:
            with os.scandir(str(parent)) as entries:
                for entry in entries:
                    if entry.name in names and entry.is_file():
                        found[parent / entry.name] = entry
        except OSError as exc:
            print("Cannot scan {0}: {1}".format(parent, exc), file=sys.stderr)
    return found


def summarize_progress(workspace: Path) -> Dict[str, Any]:
    """Return command/output progress without parsing solver log contents."""
    workspace = workspace.resolve()
    command_file, expected_out_paths, expected_err_paths = command_paths(workspace)
    if command_file is None:
        raise ValueError("progress-only mode requires <workspace>/cmd.sh")
    expected_commands = len(expected_out_paths)
    out_entries = expected_file_entries(expected_out_paths)
    err_entries = expected_file_entries(expected_err_paths)
    missing_outputs = [
        str(path.relative_to(workspace)) for path in expected_out_paths
        if path not in out_entries
    ]
    nonempty_error_logs = []  # type: List[str]
    for path, entry in err_entries.items():
        try:
            if entry.stat().st_size > 0:
                nonempty_error_logs.append(str(path.relative_to(workspace)))
        except OSError as exc:
            print("Cannot stat {0}: {1}".format(path, exc), file=sys.stderr)
    started = len(out_entries)
    remaining = len(missing_outputs)
    return {
        "schema_version": 1,
        "project": "mpclp",
        "workspace": str(workspace),
        "progress_only": True,
        "metrics": {
            "expected_runs": expected_commands,
            "started_runs": started,
            "remaining_runs": remaining,
            "started_percent": (
                round(started / expected_commands * 100.0, 2)
                if expected_commands else None
            ),
        },
        "input_validation": {
            "command_file": str(command_file.relative_to(workspace)),
            "out_files": started,
            "error_files": len(err_entries),
            "missing_outputs": remaining,
            "missing_output_samples": missing_outputs[:10],
            "nonempty_error_logs": len(nonempty_error_logs),
            "nonempty_error_log_samples": sorted(nonempty_error_logs)[:10],
        },
        "guidance": {
            "next_action": "wait_for_remaining_commands" if remaining else "run_full_summary",
            "reason": (
                "Progress mode checks file presence only; run the full summary after all commands start."
            ),
        },
    }


def summarize(workspace: Path, records_output: Optional[Path] = None, force_raw: bool = False) -> Dict[str, Any]:
    workspace = workspace.resolve()
    canonical_csv = workspace / "summary.csv"
    command_file, expected_out_paths, expected_err_paths = command_paths(workspace)
    expected_commands = len(expected_out_paths) if expected_out_paths else None
    out_files = (
        sorted(path for path in expected_out_paths if path.is_file())
        if expected_commands is not None
        else sorted(workspace.rglob("*.out"))
    )
    err_files = (
        sorted(path for path in expected_err_paths if path.is_file())
        if expected_commands is not None
        else sorted(workspace.rglob("*.err"))
    )
    missing_outputs = (
        [str(path.relative_to(workspace)) for path in expected_out_paths if not path.is_file()]
        if expected_commands is not None
        else []
    )
    if expected_commands is not None and not out_files:
        present = sorted(workspace.rglob("*.out"))
        if present:
            print(
                "Warning: {0} names {1} run(s) and none of their .out files exist, while "
                "the directory holds {2} .out file(s) that it does not name, so this "
                "summary would be empty. The list is probably from another experiment "
                "specification; remove it to summarize the logs that are here.".format(
                    str(command_file.relative_to(workspace)), expected_commands, len(present)
                ),
                file=sys.stderr,
            )
    nonempty_error_logs, fatal_error_logs = nonempty_and_fatal_error_logs(err_files, workspace)
    parsed_csv = parse_summary_csv(canonical_csv) if canonical_csv.is_file() and not force_raw else None
    uses_summary_csv = parsed_csv is not None
    records = parsed_csv[0] if parsed_csv else []  # type: List[Dict[str, str]]
    empty_logs = []  # type: List[str]
    incomplete_logs = []  # type: List[str]
    if not uses_summary_csv:
        for path in out_files:
            relative = str(path.relative_to(workspace))
            try:
                if path.stat().st_size == 0:
                    empty_logs.append(relative)
                    continue
            except OSError as exc:
                print("Cannot stat {0}: {1}".format(path, exc), file=sys.stderr)
                incomplete_logs.append(relative)
                continue
            values = parse_log(path)
            if values is None:
                incomplete_logs.append(relative)
                continue
            records.append(raw_record(path, workspace, values))

    if records_output is not None:
        write_records_atomic(records_output, records)
        checked = parse_summary_csv(records_output, allow_empty=True)
        if checked is None or len(checked[0]) != len(records):
            raise ValueError("written records artifact failed validation")

    status_counts = Counter(record["status"] for record in records)
    optimal = status_counts["OPTIMAL"]
    nonoptimal = len(records) - optimal
    missing_metrics = {
        metric: sum(record_value(record, metric) is None for record in records)
        for metric in ("runtime", "nodes", "gap", "objective")
    }
    expected_scope_complete = expected_commands is None or not missing_outputs
    complete = (
        bool(records) and expected_scope_complete and not empty_logs and not incomplete_logs
        and not fatal_error_logs and nonoptimal == 0
    )
    ready = (
        bool(records) and expected_scope_complete and not empty_logs and not incomplete_logs
        and not fatal_error_logs
    )
    failure_samples = [sample_record(record, "nonoptimal") for record in records if record["status"] != "OPTIMAL"]
    failure_samples.extend({"category": "empty", "path": path} for path in empty_logs)
    failure_samples.extend({"category": "unparseable_or_nonterminal", "path": path} for path in incomplete_logs)
    failure_samples.extend({"category": "missing_output", "path": path} for path in missing_outputs)
    failure_samples.extend({"category": "fatal_error_log", "path": path} for path in fatal_error_logs)
    if complete:
        next_action, reason = "analyze_results", "All discovered records are parseable and optimal."
    elif ready:
        next_action, reason = "analyze_available_results_and_rerun_missing", "Readable records exist, but the experiment is not fully complete."
    else:
        next_action, reason = "inspect_incomplete_outputs_and_rerun", "Empty or unparseable outputs make the current statistical scope unreliable."

    runtimes = [v for v in (record_value(record, "runtime") for record in records) if v is not None]
    gaps = [v for v in (record_value(record, "gap") for record in records) if v is not None]
    nodes = [v for v in (record_value(record, "nodes") for record in records) if v is not None]
    average_runtime = finite_mean(runtimes)
    artifact_candidates = [workspace / "summary.report.md"]
    if uses_summary_csv:
        artifact_candidates.append(canonical_csv)
    if records_output is not None:
        artifact_candidates.append(records_output)
    artifacts = sorted(set(filter(None, (relative_artifact(path, workspace) for path in artifact_candidates))))
    return {
        "schema_version": 1, "record_schema_version": 1, "project": "mpclp",
        "workspace": str(workspace), "experiment_status": "complete" if complete else "incomplete",
        "ready_for_analysis": ready,
        "metrics": {
            "runs": len(records), "optimal": optimal, "nonoptimal": nonoptimal,
            "expected_runs": expected_commands, "started_runs": len(out_files),
            "avg_runtime_seconds": average_runtime, "total_runtime_seconds": sum(runtimes),
            "avg_gap_percent": finite_mean(gaps), "max_gap_percent": max(gaps) if gaps else None,
            "avg_nodes": finite_mean(nodes),
        },
        "status_counts": dict(sorted(status_counts.items())), "missing_metrics": missing_metrics,
        "input_validation": {
            "source": "summary.csv" if uses_summary_csv else "raw .out files", "out_files": len(out_files),
            "command_file": None if command_file is None else str(command_file.relative_to(workspace)),
            "expected_commands": expected_commands, "started_commands": len(out_files),
            "missing_outputs": len(missing_outputs), "missing_output_samples": missing_outputs[:10],
            "error_files": len(err_files), "nonempty_error_logs": len(nonempty_error_logs),
            "fatal_error_logs": len(fatal_error_logs),
            "nonempty_error_log_samples": nonempty_error_logs[:10],
            "fatal_error_log_samples": fatal_error_logs[:10],
            "empty_logs": len(empty_logs), "incomplete_logs": len(incomplete_logs),
            "empty_log_samples": empty_logs[:10], "incomplete_log_samples": incomplete_logs[:10],
            "failure_samples": failure_samples[:10],
        },
        "groups": {"mode": grouped_summary(records, "mode"), "colocation": grouped_summary(records, "colocation")},
        "display": {"highlights": [
            {"label": "Runs", "value": str(len(records))},
            {"label": "Optimal", "value": "{0}/{1}".format(optimal, len(records))},
            {"label": "Mean time", "value": "-" if average_runtime is None else "{0:.2f} s".format(average_runtime)},
        ]},
        "artifacts": artifacts, "guidance": {"next_action": next_action, "reason": reason},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Emit a Research OS JSON summary for an MPCLP result workspace.")
    parser.add_argument("workspace", type=Path, help="Result directory containing MPCLP .out files.")
    parser.add_argument("--records-output", type=Path, help="Atomically write the record-level summary CSV.")
    parser.add_argument("--force-raw", action="store_true", help="Rebuild records from raw logs even when summary.csv exists.")
    parser.add_argument(
        "--progress-only", action="store_true",
        help="Quickly count expected, started, remaining, and nonempty-error files without parsing .out logs.",
    )
    parser.add_argument("--pretty", action="store_true", help="Indent JSON for manual inspection.")
    args = parser.parse_args()
    workspace = args.workspace.expanduser().resolve()
    if not workspace.is_dir():
        parser.error("workspace is not a directory: {0}".format(workspace))
    records_output = args.records_output.expanduser().resolve() if args.records_output else None
    try:
        if args.progress_only and (records_output is not None or args.force_raw):
            parser.error("--progress-only cannot be combined with --records-output or --force-raw")
        payload = (
            summarize_progress(workspace) if args.progress_only
            else summarize(workspace, records_output=records_output, force_raw=args.force_raw)
        )
        print(json.dumps(payload, indent=2 if args.pretty else None, sort_keys=True, allow_nan=False))
    except (OSError, ValueError) as exc:
        print("summarize failed: {0}".format(exc), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
