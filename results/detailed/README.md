# Detailed instance-wise results

These four CSVs report the results of Tables 3, 4 and 5 of the paper instance by
instance. On top of what the aggregated tables show, they carry the objective
value of the optimal solution (or of the best incumbent), the upper bound
returned by CPLEX, the number of cuts of each type, and the co-location
statistics of the solution.

| File | Contents |
|---|---|
| `Table3_detailed.csv` | B&C-B and B&C-I on testset T1, the original ORlib pmed instances |
| `Table4_detailed.csv` | bB&C-I, bB&C-I+E, bB&C-I+L and bB&C-I+E+L on testset T1 |
| `Table5_detailed.csv` | bB&C-I, bB&C-I+E, bB&C-I+L and bB&C-I+E+L on testset T2, the facility-mixture instances |
| `T2_BnC-I_detailed.csv` | B&C-I on testset T2, with the result columns of `Table3_detailed.csv` |

The rows are the runs behind `results/summarized/T1/summary.csv` and
`results/summarized/T2/summary.csv`, and the per-run solver logs of the same runs
are shipped under `results/T1` and `results/T2`; [../README.md](../README.md)
documents both.

## Algorithm names

The first header line of each file groups the columns by algorithm, under the
names the paper uses:

- **B&C-B**: the branch-and-cut algorithm based on formulation (MILP-B) of
  [Alvarez-Miranda and Sinnl (2019)](https://doi.org/10.1016/j.cor.2019.04.003),
  separating inequalities (16c) and (16d).
- **bB&C-I**: the basic version of the proposed algorithm, based on formulation
  (MILP), separating only the submodular inequalities (15a).
- **bB&C-I+E**: `bB&C-I` with the enhanced outer-approximation inequalities (EOA).
- **bB&C-I+L**: `bB&C-I` with the lifted subadditive inequalities (LS).
- **bB&C-I+E+L**: `bB&C-I` with both (EOA) and (LS), i.e. the proposed B&C-I.

## CSV layout

Every file has two header lines: the first names the algorithm groups, the second
the metrics within each group.

In `Table3_detailed.csv` and `Table4_detailed.csv`, the `id` of a row is
`instance-r-R-theta` and covers every `(r, R, theta)` setting at once, e.g.
`1-5-20-0.2` is instance `1` with `r = 5`, `R = 20` and `theta = 0.2`. In the two
testset-T2 files the `id` is `instance-r-R-theta-low-percentage`, and `r`, `R`,
`theta` and the low facility-probability percentage are repeated in their own
columns for easier filtering.

## Columns

### Instance parameters

- **id**: identifier of the instance and its parameters, as described above.
- **|I|**: number of customers, equal to the number of candidate facility locations.
- **K**: number of facilities to open.
- **r, R**: inner and outer coverage radii; separate columns in the testset-T2 files.
- **theta**: dependency parameter that weighs the correlated-coverage and the independent-coverage components; a separate column in the testset-T2 files.
- **low p_i (%)**: percentage of facilities drawn from the low-probability range (`10`, `50` or `90`); the high-probability percentage is its complement to 100.
- **#C1**: number of fully covered customer-location pairs.
- **#CP**: number of partially covered customer-location pairs.

### Results, repeated for every algorithm group

- **T**: CPU time in seconds; `TL` marks a run that reached the time limit.
- **N**: number of branch-and-bound nodes explored.
- **Gap(%)**: final optimality gap in percent.
- **RGap(%)**: LP relaxation gap at the root node in percent.
- **Obj**: objective value of the optimal solution (or of the best incumbent).
- **UB**: upper bound at termination.
- **nCL**: number of sites at which facilities are co-located; reported in `Table3_detailed.csv` and `T2_BnC-I_detailed.csv`.
- **mCL**: maximum number of facilities opened at a single site; reported in the same two files.
- **#Cut**: number of cuts generated.
- **#MaxSM**: number of submodular cuts generated for max terms.
- **#ProdSM**: number of submodular cuts generated for product terms; reported for the binary settings.
- **#OA**: number of outer-approximation cuts generated for product terms.
- **#EOA**: number of enhanced outer-approximation cuts generated for product terms.
- **#LS**: number of lifted subadditive cuts generated for product terms.
