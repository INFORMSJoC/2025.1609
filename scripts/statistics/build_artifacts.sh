#!/usr/bin/env bash
# Rebuild the paper-facing MPCLP figures and tables from public summary data.
#
# The statistics are computed by the awk programs in scripts/statistics/awk and
# drawn by scripts/statistics/render.py; no external engine is required.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PYTHON=${PYTHON:-python3}

cd "$REPO_ROOT"

if ! command -v "$PYTHON" >/dev/null 2>&1 && [[ ! -x "$PYTHON" ]]; then
	echo "ERROR: Python interpreter not found: $PYTHON" >&2
	exit 2
fi

if ! command -v awk >/dev/null 2>&1; then
	echo "ERROR: awk not found; the artifact statistics need it." >&2
	exit 2
fi

# Extra arguments go to the builder, e.g. --output-dir <dir>.
exec "$PYTHON" scripts/statistics/build.py all "$@"
