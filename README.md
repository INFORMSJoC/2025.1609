[![INFORMS Journal on Computing Logo](https://INFORMSJoC.github.io/logos/INFORMS_Journal_on_Computing_Header.jpg)](https://pubsonline.informs.org/journal/ijoc)

# An efficient branch-and-cut algorithm for the multiple probabilistic covering location problem

This archive is distributed in association with the [INFORMS Journal on
Computing](https://pubsonline.informs.org/journal/ijoc) under the [MIT License](LICENSE).

The software and data in this repository are a snapshot of the software and data
that were used in the research reported on in the paper
[An efficient branch-and-cut algorithm for the multiple probabilistic covering
location problem](https://doi.org/10.1287/ijoc.2025.1609) by Yan-Ru Wang,
Wei-Kun Chen, and Ivana Ljubić.

## Cite

To cite the contents of this repository, please cite both the paper and this repo, using their respective DOIs.

https://doi.org/10.1287/ijoc.2025.1609

https://doi.org/10.1287/ijoc.2025.1609.cd

Below is the BibTex for citing this snapshot of the repository.

```
@misc{WangChenLjubic2026,
  author =        {Yan-Ru Wang and Wei-Kun Chen and Ivana Ljubi{\'c}},
  publisher =     {INFORMS Journal on Computing},
  title =         {An efficient branch-and-cut algorithm for the multiple probabilistic covering location problem},
  year =          {2026},
  doi =           {10.1287/ijoc.2025.1609.cd},
  url =           {https://github.com/INFORMSJoC/2025.1609},
  note =          {Available for download at https://github.com/INFORMSJoC/2025.1609},
}  
```

## Description

This repository provides the source code of the proposed branch-and-cut
algorithm, the instances it was tested on, and the scripts that rebuild the
figures and tables of the paper. The main folders are [src](src), [data](data),
[scripts](scripts), and [results](results).

- [src](src): the Julia implementation of the model, the bound strengthening and the cut families, together with the command line entry point `src/mgclp.jl`.
- [data](data): the instances used in the paper, the OR-Library p-median instances `pmed1`--`pmed40` and the coordinate instances `pmed41`--`pmed80`. Both formats, the source of every file and the citation to use are documented in [data/README.md](data/README.md); the OR-Library files are third-party data and are not covered by the MIT license of this repository.
- [scripts](scripts): the public entrypoints for running, summarizing and rebuilding, including the experiment recipes in [scripts/experiments](scripts/experiments) and the artifact pipeline in [scripts/statistics](scripts/statistics).
- [results](results): the compact record summaries of the two testsets, under `results/summarized/`, and the raw solver logs of `results/T1` and `results/T2` they were summarized from; this package ships both, so a summary can be rebuilt from its logs and checked here. The instance-wise results behind Tables 3, 4 and 5 of the paper are in [results/detailed](results/detailed), with the objective values, upper bounds, cut counts and co-location statistics the aggregated tables omit.

A rebuild writes its figures, tables and record exports to `output/artifacts/`,
which is not versioned either. The published results that Tables 1 and 5 compare
against are third-party data as well, documented in
[scripts/statistics/reference/README.md](scripts/statistics/reference/README.md).

Solver behaviour was verified while preparing this release with eight stratified
cases that compare termination status, objective value and optimality gap against
a recorded baseline; that baseline is an environment snapshot of the machine it
was produced on and is not part of this repository.

## Installation and set up

To run this code and reproduce the results presented in the paper, you must
install [Julia](https://julialang.org), [IBM ILOG
CPLEX](https://www.ibm.com/products/ilog-cplex-optimization-studio) with a valid
license, and Python. The dependencies are installed from the repository root:

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
python3 -m pip install -r requirements.txt
```

`Project.toml` lists the dependencies of the Julia solver, which
`Pkg.instantiate()` resolves for the Julia version in use, and `Manifest.toml`
records the versions this release was built with; `requirements.txt` pins the
Python packages used to draw the paper figures. CPLEX itself is proprietary
software and is not distributed here. Rebuilding the artifacts additionally needs
a POSIX `awk`; compiling the review document needs a LaTeX installation and
ghostscript, which converts the EPS figures.

The figures are reproduced byte for byte only under the pinned `matplotlib`,
which needs Python 3.11 or newer. Older releases run the pipeline down to 3.8,
but the figures then differ from the published ones in their metadata and, by a
fraction of a point, in their bounding boxes; below 3.8 the pipeline stops at
`\boldsymbol`, and where the pinned version cannot be installed at all, because
its wheel and the conda-forge build both want a newer `glibc`, `matplotlib==3.9.4`
is the newest release that builds.

## Usage

```bash
julia --project=. src/mgclp.jl methods=bBnC-I+E+L fn=data/pmed1.txt r=5 R=20 theta=0.2 timelimit=3600
```

`methods` selects the setting of the paper: `BnC-B`, `bBnC-I`, `bBnC-I+E`,
`bBnC-I+L` or `bBnC-I+E+L`, where `BnC` stands for the `B&C` of the paper, the `E`
is the enhanced outer-approximation inequalities, equation (18), and the `L` the
lifted subadditive inequalities of Section 4.2.

The `AS19` rows of Table 1 are not runs of this solver: they reproduce the
published results kept in
[scripts/statistics/reference](scripts/statistics/reference).

The recipes under [scripts/experiments](scripts/experiments) pass `methods=<name>`
together with the fixed setup the paper uses, and generate a whole batch of commands
from a semantic specification:

```bash
bash scripts/experiments/generate_test_commands.sh scripts/experiments/t1.json
```

This validates the specification and writes `<output_dir>/cmd.sh`; it never
executes or submits the generated commands. Raw logs are summarized into the
record summaries that the artifacts are rebuilt from:

```bash
python3 scripts/summarize.py results/T1 --records-output results/summarized/T1/summary.csv
python3 scripts/summarize.py results/T2 --records-output results/summarized/T2/summary.csv
```

## Replicating

To reproduce the computational results presented in the paper, please run:

```bash
bash scripts/statistics/build_artifacts.sh
```

This writes to `output/artifacts/` the `LaTeX` code of the four tables of the
paper (`T1-BinInt-Table1.tex`, `T2-FourSettings-Table2.tex`,
`T3-FourSettings-Table3.tex` and `T5-Newly-Solved-Table5.tex`), the 15 figures
(Figures 1--5, each as EPS), the record-level CSV behind every artifact, and
`paper_artifacts_review.tex`, which holds every figure and table with the caption
it carries in the paper;
[scripts/statistics/README.md](scripts/statistics/README.md) documents the
artifact map and how to build a single artifact.

Copy the tables from the `T*.tex` files into the [IJOC LaTeX
template](https://pubsonline.informs.org/pb-assets/LaTeX/INFORMS-IJOC-Template-6-10-2024-1718048501167.zip).
To compile them, add `\usepackage{booktabs}`, `\usepackage{multirow}` and
`\usepackage{xspace}` to the preamble, together with the macros the tables use;
all of them are defined in the preamble of
`output/artifacts/paper_artifacts_review.tex`, a self-contained document that
holds every figure and table of the paper and is compiled to review them.

The figures and tables are reproduced byte for byte from the two versioned
summaries, apart from the creation timestamp of EPS output; the figures do so
under the `matplotlib` version `requirements.txt` pins.

## Support

For questions about the paper or the code, submit an
[issue](https://github.com/INFORMSJoC/2025.1609/issues/new) in this repository or
contact the corresponding author.
