# Literature reference tables

`table_1.csv`--`table_6.csv` hold the per-instance results published by

> Álvarez-Miranda, E., & Sinnl, M. (2019). An exact solution framework for the
> multiple gradual cover location problem. *Computers & Operations Research*,
> 108, 82--96.

They are third-party data, redistributed here only so that Tables 1 and 5 of the
paper can be rebuilt without the original publication at hand. They are **not**
covered by this repository's MIT license, and anyone reusing them should cite the
paper above.

The six tables partition the T1 grid: tables 1--3 are the `r = 5, R = 20` runs
and tables 4--6 the `r = 10, R = 25` runs, with `theta = 0.2`, `0.5` and `0.8`
for tables 1 and 4, 2 and 5, and 3 and 6 respectively. Each table has one row per
instance. The columns are the ones printed in that paper; the adapters read

1. column 1 -- instance id, which maps to `data/pmed<id>.txt`;
2. column 6 -- `t[s]`, the solver time, holding the literal `TL` when the run hit
   the time limit;
3. column 9 -- `g[%]`, the remaining gap in percent.

`prepare_t1_bin_int_table1.py` turns these rows into the `AS19` rows of Table 1,
and `prepare_table5_newly_solved.py` uses them to select the instances that the
literature left unsolved for Table 5.
