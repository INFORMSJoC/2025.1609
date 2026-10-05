# Published computational results

`summarized/` holds the compact, record-level summaries that regenerate the
paper artifacts. The raw solver logs behind them sit next to it, one directory
per experiment, and this package ships them, so each summary can be rebuilt from
its logs and checked against the hash in
[../scripts/statistics/README.md](../scripts/statistics/README.md). They are the
logs of `scripts/experiments/t1_paper_all.json` and `t2_paper_all.json`, which
reproduce their names exactly.

| Path | Experiment | Records | Statuses |
|---|---|---:|---|
| `summarized/T1/summary.csv` | T1, original ORlib pmed instances and the main method comparisons | 1,200 | 946 `OPTIMAL`, 254 `TIME_LIMIT` |
| `summarized/T2/summary.csv` | T2, facility-mixture co-location and method comparisons | 4,560 | 3,813 `OPTIMAL`, 747 `TIME_LIMIT` |

Both files use the stable record schema produced by `scripts/summarize.py`.
They preserve per-run parameters, termination status, runtime, node count,
gap, objective values, and source-log identifiers without publishing the raw
log forest. Their SHA-256 hashes and artifact roles are declared in
`scripts/statistics/README.md`, together with the artifact pipeline that consumes them.

The adapter layer under `scripts/statistics/` converts these summaries into
the record-level CSVs used by the paper figures and tables. See
`scripts/statistics/README.md` for commands and the exact artifact map.

## Raw logs

`T1/` and `T2/` hold the solver logs the two summaries were built from, named
exactly as the `path` column of the summary that references them and built by the
generator, whose fields are documented in
[scripts/experiments/README.md](../scripts/experiments/README.md). Every file was
retrieved from the run host and checked against the SHA-256 recorded at the
source. This package ships them, so a clone can rebuild each summary from the
logs it carries:

```bash
python3 scripts/summarize.py results/T1 --records-output /tmp/t1-summary.csv
```

Re-summarizing the shipped logs reproduces both versioned summaries byte for
byte (`summarize.py` is the same code path that produced them); the hash each
rebuild must print is listed in
[../scripts/statistics/README.md](../scripts/statistics/README.md). The whole
chain from raw log to published figure can therefore be re-checked from this
directory.
