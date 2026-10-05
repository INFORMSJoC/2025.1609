# Raw per-record values of one figure.
#
# Output rows (tab separated), in record order:
#
#   series  name of the drawn series ("" when the figure draws a single series)
#   instance  record key, only there to identify a row while debugging
#   value   raw text of the measured cell, empty when the record has no value
#
# Nothing is aggregated here: the profile, its censoring and the bar heights are
# computed by the renderer from these values.  A line exists for every record of
# the figure, so a series can still be counted -- not just averaged -- from this
# file.
#
# Driver contract (-v):
#   input     path to the record CSV
#   x         column holding the measured value
#   group     column holding the series name ("" draws a single unnamed series)
#   instance  column identifying a record
#   filters   "column=value" pairs separated by ";"

BEGIN {
    load_input()
    classify_columns()
    require_column(x)
    x_index = column[x]
    if (group != "") {
        require_column(group)
        group_index = column[group]
    }
    instance_index = require_column(instance)
    parse_filter(filters)

    print "series\tinstance\tvalue"
    for (i = 2; i <= nlines; i++) {
        split(data_line[i], fields, FS)
        if (!row_passes_filter(fields)) continue
        name = (group_index == 0 ? "" : key_of(group, fields[group_index]))
        print name "\t" fields[instance_index] "\t" fields[x_index]
    }
}
