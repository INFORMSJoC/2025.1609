#!/usr/bin/env python3
"""MPCLP project configuration and naming registry.

Scope:
    MPCLP-specific constants that are shared by more than one report/export
    script. This includes canonical solver-setting keys, TeX/public labels,
    Testset-2 parameter grids, cut-name groups, and the repository root.

Use this file when a value is a stable MPCLP convention used across scripts.
Do not add computed statistics, table rendering, raw-log parsing, or one-off
experiment paths here; those belong in stats/style/report scripts or explicit
command-line arguments.
"""
from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]

TIME_LIMIT_SECONDS = 3600.0

TESTSET2_THETAS = ["0.01", "0.1", "0.2"]
STEP_PROB_VALUES = ["0.1", "0.2", "0.3", "0.4", "0.5"]
SELECTED_STEP_PROB_VALUES = ["0.1", "0.2", "0.5"]
TESTSET2_RADIUS_PAIRS = [("1", "20"), ("2", "20")]
PMED_DATA_IDS = list(range(1, 41))

FOURSETTINGS = [
    ("Str0+VI0", r"\testbasicInt"),
    ("Str1+VI0", r"\testbasicIntStr"),
    ("Str0+VI1", r"\testbasicIntVI"),
    ("Str1+VI1+LocalSearch1", r"\testbasicIntStrVI"),
]
FOURSETTING_KEYS = [key for key, _macro in FOURSETTINGS]

FOURSETTING_PUBLIC_COLUMNS = [
    ("Str0+VI0", "bB&C-I", "ncut_oa"),
    ("Str1+VI0", "bB&C-I+E", "ncut_eoa"),
    ("Str0+VI1", "bB&C-I+L", "ncut_oa"),
    ("Str1+VI1+LocalSearch1", "bB&C-I+E+L", "ncut_eoa"),
]

INT_FULL_METHOD = "Str1+VI1+LocalSearch1"
SETTING_ALIASES = {
    "Str0+VI0": "Str0+VI0",
    "Str1+VI0": "Str1+VI0",
    "Str0+VI1": "Str0+VI1",
    "Str0+VI1+LocalSearch1": "Str0+VI1",
    "Str1+VI1+LocalSearch1": "Str1+VI1+LocalSearch1",
}

CUT_NAMES = {
    "max",
    "prod_oa",
    "prod_oa_mir",
    "prod_bin",
    "prod_sm",
    "prod_sm_C",
    "prod_sm_fixed",
    "prod_sm_lift",
    "prod_local",
    "facet",
}
LS_CUT_NAMES = {"prod_sm_C", "prod_sm", "prod_sm_fixed", "prod_sm_lift", "prod_local", "facet"}
