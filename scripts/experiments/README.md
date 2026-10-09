# Experiment specifications

These JSON files are the recipes of `scripts/experiments/generate_test_commands.sh`:

The JSON files in this directory are the source of truth for reproducible MPCLP
command generation. Generated command files and solver logs are local artifacts
and are excluded from Git.

Two of them carry the experiments of the paper: `t1_paper_all.json` and
`t2_paper_all.json` reproduce, name for name, the archived logs of testset T1 and
T2, which the versioned summaries were built from. They write to
`results/T1_Paper_All` and `results/T2_Paper_All`. `t1.json` is the smaller smoke
subset, two methods instead of five, and writes to `results/T1_Quick` so that a
quick run cannot be mixed with an archived run directory.

## Generate a command file

From the repository root:

```bash
bash scripts/experiments/generate_test_commands.sh scripts/experiments/t1.json
```

The wrapper validates the JSON, checks that Julia and `src/mgclp.jl` are
available, and writes `<output_dir>/cmd.sh`. It never runs or submits the
commands. Use `PARALLELISM=<n>` to change the generated command-file
parallelism, or call the Python entrypoint with `--dry-run` for a side-effect
free preview:

```bash
python3 scripts/experiments/generate_test_commands.py scripts/experiments/t1.json --dry-run
```

Generated batch commands intentionally use the active Julia environment on the
submission host (`julia src/mgclp.jl`). This preserves existing cluster
workflows. For a fully pinned public reproduction, activate the repository
environment in the job wrapper with `JULIA_PROJECT=.` after instantiating it.

An optional LSF command is printed only when the site-specific wrapper is
provided explicitly:

```bash
LSF_WRAPPER=/absolute/path/to/lsf \
  bash scripts/experiments/generate_test_commands.sh scripts/experiments/t1.json
```

The optional scheduler formatting can be adjusted with `LSF_TOTAL_CORES`,
`LSF_THREADS_PER_COMMAND`, `LSF_PTILE`, `LSF_QUEUE`, and `LSF_JOB_NAME`.
No cluster account or home-directory layout is assumed by the repository.

## Schema

Version 1 describes one Cartesian experiment block. Version 2 places several
non-Cartesian blocks in `experiment_blocks`. Common top-level fields are:

| Field | Meaning |
|---|---|
| `schema_version` | Specification version (`1` or `2`). |
| `project` | Must be `MPCLP`. |
| `datasets` | Project dataset identifiers. |
| `instance_ids` | Optional pmed instance subset. |
| `methods` | Semantic method identifiers. |
| `parameter_grid` | Values expanded by Cartesian product. |
| `fixed_args` | Values shared by every generated run. |
| `output_dir` | Repository-relative directory for logs and command files. |

Dataset identifiers are `T1`, `T2`, `CoordPmed-T1`, and `CoordPmed-T2`.
Method identifiers are the settings of the paper, `BnC-B`, `bBnC-I`, `bBnC-I+E`,
`bBnC-I+L` and `bBnC-I+E+L`, plus `Kmedian`, which solves the full setting of the
paper with `pmed=1` for the K-median comparison. The generator passes each method
to the solver as `methods=<name>`, so a generated command names the setting
instead of the switches it stands for.

Supported parameters include `theta`, `time_limit`, `probability_function`,
`co_location`, `epsilon`, `node_space`, and the facility-mixture parameters.
A parameter may be fixed or gridded, but not both.

A generated command writes its solver log to `<output_dir>/<run-id>.out`, next to
the `<run-id>.err` of its error stream; the run id encodes the run so that a log
can be traced back to its specification:

```text
t<testset>-pmed<instance>-r<r>-R<R>-theta<theta>-<method>-<prob_func>
    [-lh<low><high>-low<a>to<b>-high<a>to<b>-seed<n>]
    [-coloc|-nocoloc]-tl<timelimit>[-eps<epsilon>][-nodespace<n>]
```

| Part | Meaning |
|---|---|
| `t<testset>` | Testset, `t1` or `t2`. |
| `pmed<instance>` | Instance file, `data/pmed<instance>.txt`. |
| `r<r>`, `R<R>` | Inner and outer radius. |
| `theta<theta>` | Coverage probability; `theta1` for the K-median comparison. |
| `<method>` | Slug of a method name: `bnc-b`, `bbnc-i`, `bbnc-i-e`, `bbnc-i-l` and `bbnc-i-e-l` for `BnC-B`, `bBnC-I`, `bBnC-I+E`, `bBnC-I+L` and `bBnC-I+E+L`, and `kmedian`. |
| `<prob_func>` | Coverage probability function, `linear` or `facility-mixture`. |
| `lh<low><high>` | Facility mixture only: the low and high shares, e.g. `lh1090`. |
| `low<a>to<b>`, `high<a>to<b>` | Facility mixture only: the two intervals of the mixture. |
| `seed<n>` | Facility mixture only: the seed of the mixture. |
| `coloc` / `nocoloc` | Only for a run that fixes `colocation`: `1`, co-location allowed, or `0`. |
| `tl<timelimit>` | Time limit in seconds. |
| `eps<epsilon>`, `nodespace<n>` | Only when the run departs from `EPS=1e-3` or `node_space=5`. |

`summarize.py` reads the same name back into the method and the setting of a run,
so the run id of a batch has to be unique.

## The site-specific batch generator

`test.sh` is the older, cluster-facing entry point. It takes its parameters on
the command line (`-t/-r/-R/--instances/-s/-P ...`) instead of reading a JSON
recipe, and it writes the same two files, `<output_dir>/cmd.sh` and
`<output_dir>/tasks.jsonl`, into the directory given by `-o` (or an
`results/<date>_<suffix>` default).

```bash
bash scripts/experiments/test.sh -t "0.01" -s bBnC-I+E+L -o /tmp/mpclp-batch -b 0
```

Nothing is submitted and no git state is touched: with the default `-b 0` the
script only generates the commands. Submitting to a cluster (`-b 1`) and the
optional LSF/research-os formatting are site-specific and are left to the local
environment.
