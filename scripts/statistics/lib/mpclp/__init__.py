"""MPCLP-specific report-generation helpers and configuration.

Scope:
    Code in this package may depend on MPCLP solver settings, pmed instances,
    manuscript table/figure conventions, and the MPCLP result directory layout.

Do not put cross-project utilities here unless they are still entangled with
MPCLP-specific names or schemas. Once a helper is independent of MPCLP, move it
to scripts/statistics/lib/common/.
"""
