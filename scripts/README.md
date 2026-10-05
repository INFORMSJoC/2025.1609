# Script entrypoints

Run commands from the repository root so that relative data and environment
paths resolve consistently.

| Task | Command | Main output |
|---|---|---|
| Solve one instance | `julia --project=. src/mgclp.jl methods=bBnC-I+E+L fn=data/pmed1.txt theta=0.2 r=5 R=20` | Solver log on standard output |
| Generate a batch | `bash scripts/experiments/generate_test_commands.sh scripts/experiments/t1.json` | `<output_dir>/cmd.sh` |
| Validate a batch spec | `python3 scripts/experiments/generate_test_commands.py scripts/experiments/t1.json --dry-run` | Command preview only |
| Summarize raw logs | `python3 scripts/summarize.py <result-dir> --records-output <result-dir>/summary.csv` | One JSON summary on stdout and record CSV on disk |
| Rebuild paper artifacts | `bash scripts/statistics/build_artifacts.sh` | Figures and tables under `output/artifacts/` |

## Inputs and environment

- Julia dependencies are declared in `Project.toml`; install them with
  `julia --project=. -e 'using Pkg; Pkg.instantiate()'`.
- Generated batch commands keep the submission host's active Julia environment
  for compatibility. Set `JULIA_PROJECT=.` in a public reproduction job when
  the repository environment should be enforced.
- CPLEX.jl requires a working IBM ILOG CPLEX installation and license.
- The artifact layer requires `requirements.txt` (PyYAML and matplotlib) and a
  POSIX `awk`; compiling the review document it writes needs a LaTeX
  installation.
- Experiment JSON files are documented in `scripts/experiments/README.md`.
- Compact public result summaries and their record counts are documented in
  `results/README.md`.

`scripts/summarize.py` keeps `complete` separate from `ready_for_analysis` and
writes diagnostics to standard error, so it can be used in automated pipelines.
Raw `.out` and `.err` files are deliberately local; only compact summaries and
the adapter data needed by the paper are versioned.
