# Paper artifact recipes

This directory rebuilds the paper-facing figures and tables from the public
summaries in `results/summarized/`. It holds code and recipes, plus the frozen
copy of one record export:

| Path | What it is |
|---|---|
| `recipe.yaml`, `style.yaml` | which figures exist, and the project-owned visual policy |
| `tables/*.recipe.yaml` | the four comparison/record tables |
| `t2-inputs.yaml` | which summaries and roles feed the facility-mixture T2 export |
| `build.py` | compiler and driver: recipe to statistics to artifact |
| `render.py` | draws the figures from the raw values awk exports |
| `awk/` | the statistics and LaTeX programs |
| `adapters/` | project the summaries into record-level CSVs |
| `tables/t3_foursettings.csv` | a frozen copy of the 2,880 records of Table 3 |

Everything generated -- the record exports, the intermediate statistics, and the
figures and tables themselves -- is written to `output/artifacts/`:

```
output/artifacts/
├── inputs/      record-level CSV of every artifact, plus its .manifest.json
├── stats/       what each awk program was asked and what it answered
├── Figure*.eps             15 figures
├── T*.tex                   Tables 1, 2, 3 and 5
├── table5_unsolved*.tex     Table 5's instances in the two review layouts
├── paper_artifacts_review.tex  all of them; the unsolved table in its original layout
└── check-report.txt         dataset validation report
```

## Rebuild everything

```bash
python3 -m pip install -r requirements.txt
bash scripts/statistics/build_artifacts.sh
```

The build needs Python and `awk`. It writes the review document but leaves the
compilation to you; compiling needs LaTeX and ghostscript, which converts the EPS
figures. It prints one
line per artifact and nothing else: the chatter of the adapters is kept, and
shown, only when a step fails. `MPLCONFIGDIR` is redirected under
`output/artifacts/mplconfig` so a rebuild never writes into your matplotlib
cache.

The statistics programs are written for POSIX awk and were verified under two
independent implementations: the awk of macOS (20200816) and GNU awk 5.4, which
produce identical statistics for every figure and every comparison table.

Every figure and every table is reproduced byte for byte from the previous
toolchain, except for the creation timestamp that EPS output embeds on every
run; the renderer therefore pins matplotlib (see `requirements.txt`). Compiling
the review document adds the embedded figure timestamps and the font subset that
pdfTeX rewrites on each run, which differ between two consecutive runs of the
same inputs as well.

## Public data baseline

Both summaries are versioned in `results/summarized/`; their SHA-256 hashes and status
counts are frozen here so a rebuild can be traced back to one input set:

| Input | Records | SHA-256 | Role |
|---|---:|---|---|
| `results/summarized/T1/summary.csv` | 1,200 | `4319cc01499995c2e7716f3ce8dc04f53b01f2bca51d1e45791fe9bf1ab826ea` | T1 method comparisons: Figure 1, Tables 1, 2 and 5 |
| `results/summarized/T2/summary.csv` | 4,560 | `f61ae5e61b750f34b4a580308a368c7b9a4d4bec7e1dd12763860e618a1239de` | Facility-mixture T2: Figures 2--5 and Table 3 |

Status counts are 946 `OPTIMAL` / 254 `TIME_LIMIT` for T1 and 3,813 `OPTIMAL` /
747 `TIME_LIMIT` for T2. Raw solver logs are not required for artifact
generation. The known-invalid `T2_Paper_All_0103` run (mixed probability-range
configuration) is excluded.

Table 3 records the four-settings co-location rows of the T2 summary: its 2,880
results agree value for value with that summary, and the export the table is
rendered from, `t3_foursettings_table3.csv`, is rebuilt from it by
`adapters/export_facility_mixture_t2.py`, like every other record export.
`tables/t3_foursettings.csv` is the versioned copy of those records; the recipe
names it, but `build_facility_table3()` renders the table from the export.

## Artifact map

| Paper artifact | Adapter data (under `output/artifacts/inputs/`) | Recipe |
|---|---|---|
| Figure 1 | `figure1_t1.csv` | `recipe.yaml` |
| Figure 2 | `figure2_t2_colocation_loss.csv` | `recipe.yaml` |
| Figure 3 | `figure3_t2_colocation_metrics.csv` | `recipe.yaml` |
| Figure 4 | `figure4_t2_solver_profiles.csv` | `recipe.yaml` |
| Figure 5 | `figure5_t2_gap_improvement.csv`, `figure5_t2_time_profiles.csv` | `recipe.yaml` |
| Table 1 | `t1_bin_int_table1.csv` | `tables/table1.recipe.yaml` |
| Table 2 | `t2_foursettings_table2.csv` | `tables/table2.recipe.yaml` |
| Table 3 | `t3_foursettings_table3.csv` | `tables/table3.recipe.yaml` |
| Table 5 | `table5_newly_solved.csv` | `tables/table5.recipe.yaml` |

`recipe.yaml` declares paper-facing intent only, `style.yaml` contains the
project-owned visual policies, and `build.py` compiles a selection of them into
the contract that the awk programs and `render.py` consume. Generated provenance
is written to `output/artifacts/artifact_provenance.json`.

## How an artifact is produced

1. An adapter under `adapters/` projects `results/summarized/*/summary.csv` into a
   record-level CSV under `output/artifacts/inputs/`.
2. `build.py` compiles `recipe.yaml` (figures) or a table recipe into a contract
   and calls the statistics programs in `awk/`.
3. The awk programs read the record CSV and write their output to
   `output/artifacts/stats/`. Tables come out of awk as finished LaTeX; figures
   come out of awk as raw per-record values, and `render.py` turns those values
   into profiles and bars and draws them:

   | Program | Question it answers | Output |
   |---|---|---|
   | `awk/comparison_table.awk` | which instances satisfy a cohort, what is one aggregated metric value, and how does the table look | the complete LaTeX tabular |
   | `awk/record_panel_table.awk` | how do the listed records read side by side | the complete LaTeX tabular |
   | `awk/series_values.awk` | what did every record of a figure measure | `series`, `instance`, `value` |
   | `awk/dataset_check.awk` | does the dataset satisfy the declared checks | `rows`, `duplicates`, `missing`, `error`, `warning` |
   | `awk/common.awk` | shared CSV, column-typing, ordering, rounding, and summation helpers | (no output) |

4. `render.py` only runs awk and draws: every `.tex` is written by awk, and the
   figures are computed (censoring, clipping, empirical profile, bar heights)
   and drawn in Python from the raw values.
5. A rebuild reproduces the released figures and tables byte for byte, apart from
   the creation timestamp that EPS output embeds on every run.

Means are summed with the eight-way unrolled pairwise accumulation described in
`awk/comparison_table.awk`, because a plain left-to-right sum rounds differently
often enough to change a published mean. A mean that lands exactly on a .5
boundary is rounded from the shortest decimal that reads back as the same double
(`round_half_up` in `awk/common.awk`), which is the direction the tables always
used.

## Validate or build selected artifacts

The recipe contains multiple datasets, so a selection needs explicit artifact
identifiers:

```bash
python3 scripts/statistics/build.py check --artifact Figure1-T1-Time-Profile
python3 scripts/statistics/build.py build --artifact Figure1-T1-Time-Profile
```

`check` validates the dataset of the selected artifacts and prints the report;
`build` validates and then renders.

Candidate T1 or T2 summaries can be built in isolated directories without
replacing the published artifacts:

```bash
python3 scripts/statistics/build.py t1 \
  --t1-summary /path/to/candidate-summary.csv \
  --output-dir /tmp/mpclp-t1-candidate

python3 scripts/statistics/build.py t2 \
  --t2-summary /path/to/candidate-summary.csv \
  --output-dir /tmp/mpclp-t2-candidate
```

The comparison-table recipes use arithmetic means. `T` and `N` use the
matched any-solved cohort; `G(%)` uses the any-unsolved cohort; and `LPG(%)`
uses every record with a root-gap value, regardless of final solve status.
