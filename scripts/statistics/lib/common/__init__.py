"""Cross-project report-generation workflows and helpers.

Scope:
    Utilities in this package must not depend on MPCLP instance names, solver
    settings, TeX macros, result-folder conventions, or paper-specific labels.

Put code here when the same helper or workflow can be reused in another
computational paper repo with different models and experiment schemas. A common
module may provide a complete baseline workflow, such as style-preserving CSV
export, compared-setting aggregation, or profile-plot generation, as long as
project-specific labels, settings, paths, and schemas are supplied by callers.
"""
