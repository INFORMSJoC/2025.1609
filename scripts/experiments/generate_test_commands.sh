#!/usr/bin/env bash
# Generate <spec.output_dir>/cmd.sh from one semantic experiment JSON file.
# This script only generates commands. It never submits or executes them.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: bash scripts/experiments/generate_test_commands.sh <experiment.json> [output.sh]" >&2
  exit 2
fi

SPEC=$1
if [[ ! -f "$SPEC" ]]; then
  echo "ERROR: experiment JSON does not exist: $SPEC" >&2
  exit 2
fi

cd "$REPO_ROOT"

if [[ -n "${PYTHON:-}" ]]; then
  if command -v "$PYTHON" >/dev/null 2>&1; then
    PYTHON_BIN=$(command -v "$PYTHON")
  elif [[ -x "$PYTHON" ]]; then
    PYTHON_BIN=$PYTHON
  else
    echo "ERROR: requested PYTHON is not executable: $PYTHON" >&2
    exit 2
  fi
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN=$(command -v python3)
elif [[ -x "$HOME/miniconda3/bin/python3" ]]; then
  PYTHON_BIN=$HOME/miniconda3/bin/python3
elif command -v python >/dev/null 2>&1 \
  && python -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then
  PYTHON_BIN=$(command -v python)
else
  echo "ERROR: Python 3 was not found. Set PYTHON=/absolute/path/to/python3." >&2
  exit 2
fi

if ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)'; then
  echo "ERROR: selected interpreter is not Python 3: $PYTHON_BIN" >&2
  exit 2
fi
echo "Python interpreter: $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"

if [[ $# -eq 2 ]]; then
  OUTPUT=$2
else
  OUTPUT=$("$PYTHON_BIN" -c \
    'import json, os, sys; print(os.path.join(json.load(open(sys.argv[1]))["output_dir"], "cmd.sh"))' \
    "$SPEC")
fi

PARALLELISM=${PARALLELISM:-1}
LSF_TOTAL_CORES=${LSF_TOTAL_CORES:-72}
LSF_THREADS_PER_COMMAND=${LSF_THREADS_PER_COMMAND:-2}
LSF_PTILE=${LSF_PTILE:-36}
LSF_QUEUE=${LSF_QUEUE:-batch}
LSF_WRAPPER=${LSF_WRAPPER:-}

for value_name in LSF_TOTAL_CORES LSF_THREADS_PER_COMMAND LSF_PTILE; do
  value=${!value_name}
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: $value_name must be a positive integer: $value" >&2
    exit 2
  fi
done
if (( LSF_THREADS_PER_COMMAND >= LSF_PTILE )); then
  echo "ERROR: LSF_THREADS_PER_COMMAND must be smaller than LSF_PTILE." >&2
  exit 2
fi
if (( LSF_TOTAL_CORES % LSF_PTILE != 0 )); then
  echo "ERROR: LSF_TOTAL_CORES must be a multiple of LSF_PTILE." >&2
  exit 2
fi

"$PYTHON_BIN" "$SCRIPT_DIR/generate_test_commands.py" \
  "$SPEC" \
  --output "$OUTPUT" \
  --parallelism "$PARALLELISM"

echo "Generated cmd.sh: $OUTPUT"
echo "No commands were executed or submitted."

RESULT_DIR=$("$PYTHON_BIN" -c \
  'import json, sys; print(json.load(open(sys.argv[1]))["output_dir"])' \
  "$SPEC")
DEFAULT_JOB_NAME=$(basename "$RESULT_DIR")
DEFAULT_JOB_NAME=$(printf '%s' "$DEFAULT_JOB_NAME" | tr -cs '[:alnum:]_-' '-')
LSF_JOB_NAME=${LSF_JOB_NAME:-$DEFAULT_JOB_NAME}

if [[ -n "$LSF_WRAPPER" ]]; then
  if [[ "$LSF_WRAPPER" != /* ]]; then
    echo "ERROR: LSF_WRAPPER must be an absolute path: $LSF_WRAPPER" >&2
    exit 2
  fi
  echo "Optional LSF submit command (run from the repository root):"
  printf 'bsub -J %s -n %s -o %s/lsf-%%J.out -e %s/lsf-%%J.err -q %s -R "span[ptile=%s]" "mpirun %s %s %s %s"\n' \
    "$LSF_JOB_NAME" \
    "$LSF_TOTAL_CORES" \
    "$RESULT_DIR" \
    "$RESULT_DIR" \
    "$LSF_QUEUE" \
    "$LSF_PTILE" \
    "$LSF_WRAPPER" \
    "$OUTPUT" \
    "$LSF_THREADS_PER_COMMAND" \
    "$LSF_PTILE"
else
  echo "Set LSF_WRAPPER=/absolute/path/to/lsf to print an optional LSF command."
fi
