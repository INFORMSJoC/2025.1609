# Instance data

The 80 instances behind the paper. `pmed1.txt`--`pmed40.txt` are the OR-Library
p-median instances; `pmed41.txt`--`pmed80.txt` are coordinate-format instances
generated from the same size grid. The solver reads either format with
`fn=data/pmedN.txt`, and `src/common/readdata.jl` is the authoritative
description of how both are parsed.

## `pmed1.txt` -- `pmed40.txt` (OR-Library)

These 40 files are the p-median instances of the OR-Library, redistributed here
unchanged so that the published results can be reproduced. They are third-party
data: they are **not** covered by this repository's MIT license, and any reuse
should cite

> Beasley, J. E. (1990). Collection of test data sets for a variety of
> operations research (OR) problems.
> <http://people.brunel.ac.uk/~mastjjb/jeb/info.html>

The format, as read by `Read_Pmed_Uncapacited`, is a header

    n_vertex n_edge K

followed by `n_edge` rows of

    vertex_i vertex_j distance

The rows give the edges of an undirected graph; the solver completes the graph
with all-pairs shortest paths (Floyd--Warshall) and uses the resulting distance
matrix as the cost matrix. `K` is the number of facilities to locate.

## `pmed41.txt` -- `pmed80.txt` (generated)

`pmed41.txt`--`pmed80.txt` follow the same size grid as `pmed1.txt`--`pmed40.txt`
(`pmedN+40` copies the vertex count and `K` of `pmedN`) but replace the OR-Library
graph by independently drawn coordinates and Euclidean distances:

    n_locations n_customers K COORD_PMED seed=<seed> source=pmed<id>
    CUSTOMERS
    id x y                       (n_customers rows)
    LOCATIONS
    id x y                       (n_locations rows)

Their customer and candidate-location coordinates are drawn uniformly from
`[0, 100]^2` with `seed = 20260707 + source_id`, and every file records its own
seed and source instance in the header. Regenerate the whole set with

```bash
python3 scripts/experiments/generate_coord_pmed_instances.py
```

which reproduces these files byte for byte. Unlike the OR-Library files, these
instances are original to this work and are covered by the repository license.
