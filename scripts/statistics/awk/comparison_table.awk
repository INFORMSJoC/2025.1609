# One comparison table: compute every cell, then print the complete LaTeX
# tabular.
#
# The driver writes a tab-separated specification of the table (the recipe
# compiled into a flat contract); this program answers the statistical question
# a comparison table asks -- for one row, which instances belong to each cohort
# and what is the aggregated value of one metric for one method -- and lays the
# answer out as booktabs LaTeX.  Nothing outside this file knows how a table
# looks.
#
# Specification records (tab separated; see tables/tableN.recipe.yaml):
#
#   instance <column>                    record key used to identify instances
#   dimensions <d1,d2,...>               leading label columns
#   empty <value>                        text of a cell with no measurement
#   column_format <value>                tabular column specification
#   multirow <0|1>                       row labels span the two header rows
#   top_rule/mid_rule/bottom_rule <0|1>  booktabs rules
#   cmidrule_trim <none|r|lr,...>        trim argument of the block cmidrules
#   row_label <dimension> <macro>        header macro of a label column
#   multicolumn <dimension>              wrap that column's label in \multicolumn
#   metric <id> <field> <aggregation> <cohort> <fallback|->
#   metric_label <id> <macro>            header macro of a metric
#   metric_format <id> <type> <key=value>...   how a cell of that metric prints
#   cohort <id> <type> <field|-> <equals|-> <methods|->
#   cell <method> <metric> <cohort> <fallback|->
#   block <method> <label> <metrics>     one column group of the header
#   section <group_by> <order literal|->  one group of data rows
#   section_value <index> <dimension> <template|op:instance_count>
#   section_blank <index> <method> <metrics>   cells a section leaves empty
#   summary <index> <filter|->
#   summary_display <index> <dimension> <label|op:instance_count>
#   summary_label <index> <text>         label of a summary row with no display
#   summary_has_keep|summary_has_blank <index> <0|1>
#   summary_keep|summary_blank <index> <method> <metrics|->
#   summary_midrule <index> <0|1>
#
# Driver contract (-v): input, spec.

BEGIN {
    load_input()
    classify_columns()
    defaults()
    read_spec()
    require_column(instance_key)
    instance_index = column[instance_key]
    method_index = require_column("method")

    begin_table()
    for (section = 1; section <= section_count; section++) {
        ordered_groups(section)
        for (position = 1; position <= ngroups; position++) {
            select_rows(group_key[position])
            emit_section_row(section, position == ngroups)
        }
    }
    for (summary = 1; summary <= summary_count; summary++) {
        select_summary_rows(summary)
        emit_summary_row(summary)
    }
    end_table()
}

# ---------------------------------------------------------------------------
# Specification
# ---------------------------------------------------------------------------

function defaults() {
    empty = "--"
    multirow = 0
    top_rule = 1
    mid_rule = 1
    bottom_rule = 1
    cmidrule_trim = "lr"
}

function read_spec(    line, count, fields, i, separator) {
    section_count = 0
    summary_count = 0
    ncell = 0
    while ((getline line < spec) > 0) {
        if (line == "" || substr(line, 1, 1) == "#") continue
        count = split(line, fields, "\t")
        if (fields[1] == "instance") instance_key = fields[2]
        else if (fields[1] == "dimensions") dimension_count = split(fields[2], dimension_name, ",")
        else if (fields[1] == "metric") {
            metric_field[fields[2]] = fields[3]
            metric_aggregation[fields[2]] = fields[4]
            metric_cohort[fields[2]] = fields[5]
            metric_fallback[fields[2]] = (fields[6] == "-" ? "" : fields[6])
        } else if (fields[1] == "cohort") {
            cohort_kind[fields[2]] = fields[3]
            cohort_field[fields[2]] = (fields[4] == "-" ? "" : fields[4])
            cohort_equals[fields[2]] = (fields[5] == "-" ? "" : fields[5])
            cohort_methods[fields[2]] = (fields[6] == "-" ? "" : fields[6])
        } else if (fields[1] == "cell") {
            cell_method[++ncell] = fields[2]
            cell_metric[ncell] = fields[3]
            cell_cohort[ncell] = (fields[4] == "-" ? "" : fields[4])
            cell_fallback[ncell] = (fields[5] == "-" ? "" : fields[5])
        } else if (fields[1] == "section") {
            section_count++
            section_dimension_count[section_count] = split(fields[2], dimension_item, ",")
            for (i = 1; i <= section_dimension_count[section_count]; i++) {
                section_dimension[section_count, i] = dimension_item[i]
            }
            order_count[section_count] = split(fields[3], order_item, ";")
            for (i = 1; i <= order_count[section_count]; i++) {
                separator = index(order_item[i], ":")
                section_order_dimension[section_count, i] = substr(order_item[i], 1, separator - 1)
                section_order_value[section_count, i] = substr(order_item[i], separator + 1)
            }
        } else if (fields[1] == "summary") {
            summary_count++
            summary_filter[summary_count] = (fields[3] == "-" ? "" : fields[3])
        } else {
            read_layout(fields[1], fields, count)
        }
    }
    close(spec)
    if (instance_key == "") fail("the table specification has no instance key")
}

# Layout records describe the finished table rather than the statistics.
function read_layout(record, fields, count,    i, separator) {
    if (record == "empty") empty = fields[2]
    else if (record == "column_format") column_format = fields[2]
    else if (record == "multirow") multirow = fields[2] + 0
    else if (record == "top_rule") top_rule = fields[2] + 0
    else if (record == "mid_rule") mid_rule = fields[2] + 0
    else if (record == "bottom_rule") bottom_rule = fields[2] + 0
    else if (record == "cmidrule_trim") cmidrule_trim = fields[2]
    else if (record == "row_label") row_label[fields[2]] = fields[3]
    else if (record == "multicolumn") multicolumn[fields[2]] = 1
    else if (record == "metric_label") metric_label[fields[2]] = fields[3]
    else if (record == "metric_format") {
        metric_format_type[fields[2]] = fields[3]
        for (i = 4; i <= count; i++) {
            separator = index(fields[i], "=")
            metric_format_argument[fields[2], substr(fields[i], 1, separator - 1)] = \
                substr(fields[i], separator + 1)
        }
    } else if (record == "block") {
        block_count++
        block_method[block_count] = fields[2]
        block_label[block_count] = fields[3]
        block_metric_count[block_count] = split(fields[4], block_metric_item, ",")
        for (i = 1; i <= block_metric_count[block_count]; i++) {
            block_metric[block_count, i] = block_metric_item[i]
        }
    } else if (record == "section_value") section_value[fields[2], fields[3]] = fields[4]
    else if (record == "section_blank") section_blank[fields[2], fields[3]] = fields[4]
    else if (record == "summary_display") summary_display[fields[2], fields[3]] = fields[4]
    else if (record == "summary_label") summary_label[fields[2]] = fields[3]
    else if (record == "summary_has_keep") summary_has_keep[fields[2]] = fields[3] + 0
    else if (record == "summary_has_blank") summary_has_blank[fields[2]] = fields[3] + 0
    else if (record == "summary_keep") summary_keep[fields[2], fields[3]] = fields[4]
    else if (record == "summary_blank") summary_blank[fields[2], fields[3]] = fields[4]
    else if (record == "summary_midrule") summary_midrule[fields[2]] = fields[3] + 0
    else fail("unknown specification record: " record)
}

# ---------------------------------------------------------------------------
# Row selection
# ---------------------------------------------------------------------------

# Distinct value combinations of one section, in the declared row order.
function ordered_groups(section,    i, fields, j, name, key, value) {
    ngroups = 0
    delete group_seen
    for (i = 2; i <= nlines; i++) {
        split(data_line[i], fields, FS)
        key = ""
        for (j = 1; j <= section_dimension_count[section]; j++) {
            name = section_dimension[section, j]
            key = key name SUBSEP key_of(name, fields[column[name]]) SUBSEP
        }
        if (key in group_seen) continue
        group_seen[key] = 1
        group_key[++ngroups] = key
    }
    for (i = 2; i <= ngroups; i++) {
        value = group_key[i]
        j = i - 1
        while (j >= 1 && group_rank(value, section) < group_rank(group_key[j], section)) {
            group_key[j + 1] = group_key[j]
            j--
        }
        group_key[j + 1] = value
    }
}

# Sort key of one group: the declared position of every dimension first, its
# value as text second.  Group keys are flat name/value sequences.
function group_rank(key, section,    j, position, count) {
    rank = ""
    count = split(key, pair, SUBSEP)
    for (j = 1; j + 1 <= count; j += 2) {
        if (pair[j] == "") continue
        position = order_position(section, pair[j], pair[j + 1])
        rank = rank sprintf("%09d", position) "|" pair[j + 1] ";"
    }
    return rank
}

# Declared position of one value, or one past the end when it is not declared.
# A number only matches a numeric column and text only matches a text column,
# which is how the values were compared before.
function order_position(section, dimension, value,    j, literal) {
    for (j = 1; j <= order_count[section]; j++) {
        if (section_order_dimension[section, j] != dimension) continue
        literal = section_order_value[section, j]
        if (substr(literal, 1, 2) == "n:") {
            if (numeric_column[dimension] && value + 0 == substr(literal, 3) + 0) return j - 1
        } else if (!numeric_column[dimension] && value == substr(literal, 3)) {
            return j - 1
        }
    }
    return order_count[section]
}

# Keep the records of one row group, addressed by position in data_line, and
# remember the group key so the row can be labelled.
function select_rows(key,    i, fields, j, count, candidate) {
    nselected = 0
    delete selected_instance
    count = split(key, pair, SUBSEP)
    for (j = 1; j + 1 <= count; j += 2) {
        if (pair[j] == "") continue
        row_key[pair[j]] = pair[j + 1]
    }
    for (i = 2; i <= nlines; i++) {
        split(data_line[i], fields, FS)
        candidate = "matched"
        for (j = 1; j + 1 <= count; j += 2) {
            if (pair[j] == "") continue
            if (key_of(pair[j], fields[column[pair[j]]]) != pair[j + 1]) {
                candidate = "rejected"
                break
            }
        }
        if (candidate != "matched") continue
        selected[++nselected] = i
        selected_instance[fields[instance_index]] = 1
    }
}

# Summary rows use the whole record set, optionally reduced by a filter.
function select_summary_rows(summary,    i, fields, count, j, parts, name) {
    nselected = 0
    delete selected_instance
    delete row_key
    count = split(summary_filter[summary], item, ";")
    for (i = 2; i <= nlines; i++) {
        split(data_line[i], fields, FS)
        candidate = "matched"
        for (j = 1; j <= count; j++) {
            if (item[j] == "") continue
            split(item[j], parts, "=")
            name = parts[1]
            if (numeric_column[name]) {
                if (fields[column[name]] + 0 != parts[2] + 0) candidate = "rejected"
            } else if (fields[column[name]] != parts[2]) {
                candidate = "rejected"
            }
        }
        if (candidate != "matched") continue
        selected[++nselected] = i
        selected_instance[fields[instance_index]] = 1
    }
}

# ---------------------------------------------------------------------------
# Cells
# ---------------------------------------------------------------------------

# Aggregated value of one metric for one method over one cohort, or "-" when
# the cohort selects no record of that method.
function cell_value(method, metric, cohort, fallback,    name, count, truthy, i, fields, text) {
    if (cohort == "") {
        delete cohort_set
    } else {
        cohort_instances(cohort)
        if (ncohort == 0 && fallback != "") cohort_instances(fallback)
    }
    name = metric_field[metric]
    count = 0
    truthy = 0
    for (i = 1; i <= nselected; i++) {
        split(data_line[selected[i]], fields, FS)
        if (fields[method_index] != method) continue
        if (!(fields[instance_index] in cohort_set)) continue
        text = fields[column[name]]
        if (text == "") continue
        if (metric_aggregation[metric] == "count_true") {
            count++
            if (is_true(text)) truthy++
            continue
        }
        cell_value_buffer[++count] = text + 0
    }
    if (count == 0) return "-"
    if (metric_aggregation[metric] == "count_true") return num_text(truthy)
    if (metric_aggregation[metric] != "arithmetic_mean") {
        fail("unsupported metric aggregation: " metric_aggregation[metric])
    }
    return num_text(pairwise_sum(cell_value_buffer, 1, count) / count)
}

# Sum a range the way the published tables were summed.  The eight-way
# unrolled accumulation, and the split above 128 values, are what make the
# rounding of a mean reproducible: a plain left-to-right sum differs in the
# last digit often enough to change a displayed mean.
function pairwise_sum(values, low, high,    n, i, limit, half, r0, r1, r2, r3, r4, r5, r6, r7, res) {
    n = high - low + 1
    if (n <= 0) return 0
    if (n < 8) {
        res = 0
        for (i = low; i <= high; i++) res += values[i]
        return res
    }
    if (n > 128) {
        half = int(n / 2)
        half -= half % 8
        return pairwise_sum(values, low, low + half - 1) + pairwise_sum(values, low + half, high)
    }
    r0 = values[low]
    r1 = values[low + 1]
    r2 = values[low + 2]
    r3 = values[low + 3]
    r4 = values[low + 4]
    r5 = values[low + 5]
    r6 = values[low + 6]
    r7 = values[low + 7]
    limit = low + n - (n % 8)
    for (i = low + 8; i < limit; i += 8) {
        r0 += values[i]
        r1 += values[i + 1]
        r2 += values[i + 2]
        r3 += values[i + 3]
        r4 += values[i + 4]
        r5 += values[i + 5]
        r6 += values[i + 6]
        r7 += values[i + 7]
    }
    res = ((r0 + r1) + (r2 + r3)) + ((r4 + r5) + (r6 + r7))
    for (; i <= high; i++) res += values[i]
    return res
}

# Instances of the current row group that satisfy one cohort, left in the
# global cohort_set together with their count.
function cohort_instances(cohort,    i, fields, kind, field, methods, want, name, method, hit) {
    delete cohort_set
    delete matched
    kind = cohort_kind[cohort]
    field = cohort_field[cohort]
    methods = cohort_methods[cohort]
    want = cohort_equals[cohort]
    if (kind == "all") {
        for (i = 1; i <= nselected; i++) {
            split(data_line[selected[i]], fields, FS)
            if (!method_in_scope(fields[method_index], methods)) continue
            cohort_set[fields[instance_index]] = 1
        }
    } else {
        for (i = 1; i <= nselected; i++) {
            split(data_line[selected[i]], fields, FS)
            method = fields[method_index]
            if (!method_in_scope(method, methods)) continue
            name = fields[instance_index]
            if (numeric_column[field]) {
                hit = fields[column[field]] + 0 == want + 0
            } else {
                hit = fields[column[field]] == want
            }
            if (name in matched) {
                if (kind == "all_methods") matched[name] = matched[name] && hit
                else matched[name] = matched[name] || hit
            } else {
                matched[name] = hit
            }
        }
        for (name in matched) if (matched[name]) cohort_set[name] = 1
    }
    ncohort = 0
    for (name in cohort_set) ncohort++
}

function method_in_scope(method, methods,    count, j) {
    if (methods == "") return 1
    count = split(methods, item, ",")
    for (j = 1; j <= count; j++) if (item[j] == method) return 1
    return 0
}

function is_true(text) {
    if (text == "True" || text == "true" || text == "TRUE") return 1
    if (text == "False" || text == "false" || text == "FALSE") return 0
    return text + 0 != 0
}

# ---------------------------------------------------------------------------
# LaTeX
# ---------------------------------------------------------------------------

function begin_table(    i, count, offset, trim, command, text) {
    if (length(column_format) != dimension_count + ncell) {
        fail("latex column_format has " length(column_format) " columns for " \
             dimension_count + ncell " table columns")
    }
    print "\\begin{tabular}{" column_format "}"
    if (top_rule) print "\\toprule"
    text = ""
    for (i = 1; i <= dimension_count; i++) {
        text = text (i > 1 ? " & " : "")
        if (multirow) text = text "\\multirow{2}{*}{" dimension_header(i) "}"
    }
    offset = dimension_count + 1
    for (i = 1; i <= block_count; i++) {
        count = block_metric_count[i]
        text = text " & \\multicolumn{" count "}{c}{" block_label[i] "}"
        if (cmidrule_trim == "" || cmidrule_trim == "none") command = "\\cmidrule"
        else command = "\\cmidrule(" cmidrule_trim ")"
        header_rule[++nheader_rule] = command "{" offset "-" offset + count - 1 "}"
        offset += count
    }
    print text row_end()
    for (i = 1; i <= nheader_rule; i++) print header_rule[i]
    text = ""
    for (i = 1; i <= dimension_count; i++) {
        text = text (i > 1 ? " & " : "")
        if (!multirow) text = text dimension_header(i)
    }
    for (i = 1; i <= ncell; i++) text = text " & " metric_header(i)
    print text row_end()
    if (mid_rule) print "\\midrule"
}

function end_table() {
    if (bottom_rule) print "\\bottomrule"
    print "\\end{tabular}"
}

function dimension_header(slot) {
    if ((dimension_name[slot]) in row_label) return row_label[dimension_name[slot]]
    return dimension_name[slot]
}

function metric_header(slot) {
    if ((cell_metric[slot]) in metric_label) return metric_label[cell_metric[slot]]
    return cell_metric[slot]
}

function row_end() {
    return " \\\\"
}

# One data row.  The rule that separates two row sections closes the section
# here, so that a summary row can bring its own rule.
function emit_section_row(section, last,    i, text, value) {
    count_instances()
    text = ""
    for (i = 1; i <= dimension_count; i++) {
        value = section_value_text(section, dimension_name[i])
        if ((dimension_name[i]) in multicolumn && value != "") {
            value = "\\multicolumn{1}{l}{" value "}"
        }
        text = text (i > 1 ? " & " : "") value
    }
    for (i = 1; i <= ncell; i++) {
        text = text " & " cell_text(section, cell_method[i], cell_metric[i])
    }
    print text row_end()
    if (last && section < section_count) print "\\midrule"
}

function emit_summary_row(summary,    i, text, value, any) {
    count_instances()
    if (summary_midrule[summary]) print "\\midrule"
    any = ""
    for (i = 1; i <= dimension_count; i++) {
        value = summary_display[summary, dimension_name[i]]
        label_buffer[i] = value
        if (value != "" && value != "op:instance_count") any = "yes"
        if (value == "op:instance_count") any = "yes"
    }
    if (any == "") {
        value = summary_label[summary]
        if (value == "") value = "Total"
        label_buffer[dimension_count] = value
    }
    text = ""
    for (i = 1; i <= dimension_count; i++) {
        value = label_buffer[i]
        if (value == "op:instance_count") value = ninstances ""
        if ((dimension_name[i]) in multicolumn && value != "") {
            value = "\\multicolumn{1}{l}{" value "}"
        }
        text = text (i > 1 ? " & " : "") value
    }
    for (i = 1; i <= ncell; i++) text = text " & " summary_cell_text(summary, i)
    print text row_end()
}

function count_instances(    name) {
    ninstances = 0
    for (name in selected_instance) ninstances++
}

# Row labels: a declared template with {column} placeholders, or the number of
# instances the row covers.
function section_value_text(section, dimension,    template, i, name) {
    template = section_value[section, dimension]
    if (template == "") return ""
    if (template == "op:instance_count") return ninstances ""
    for (i = 1; i <= section_dimension_count[section]; i++) {
        name = section_dimension[section, i]
        template = replace_all(template, "{" name "}", row_key[name])
    }
    return template
}

# A cell of a data row: the cohort value of that metric, or the table's empty
# text where the section blanks the metric.
function cell_text(section, method, metric) {
    if (in_list(section_blank[section, method], metric)) return empty ""
    return format_metric(cell_of(method, metric), metric)
}

function summary_cell_text(summary, slot,    method, metric) {
    method = cell_method[slot]
    metric = cell_metric[slot]
    if (summary_has_keep[summary] && !in_list(summary_keep[summary, method], metric)) return empty ""
    if (in_list(summary_blank[summary, method], metric)) return empty ""
    return format_metric(cell_of(method, metric), metric)
}

function cell_of(method, metric,    i) {
    for (i = 1; i <= ncell; i++) {
        if (cell_method[i] == method && cell_metric[i] == metric) {
            return cell_value(method, metric, cell_cohort[i], cell_fallback[i])
        }
    }
    fail("table cell is not in any method block: " method "/" metric)
}

function in_list(list, item,    count, parts, i) {
    if (list == "" || list == "-") return 0
    count = split(list, parts, ",")
    for (i = 1; i <= count; i++) if (parts[i] == item) return 1
    return 0
}

function replace_all(text, from, to,    position) {
    for (;;) {
        position = index(text, from)
        if (position == 0) return text
        text = substr(text, 1, position - 1) to substr(text, position + length(from))
    }
}

# ---------------------------------------------------------------------------
# Number formatting
# ---------------------------------------------------------------------------

function format_metric(value, metric,    type, number) {
    if (value == "-") return empty ""
    type = metric_format_type[metric]
    # The value arrives as the text of a computed number, so every comparison
    # below is forced numeric: awk would otherwise compare "0.0" and 0 as text.
    number = value + 0
    if (type == "number") return sprintf("%.*f", int(metric_argument(metric, "precision", 3)), number)
    if (type == "fixed") return sprintf("%.*f", metric_digits(metric), number)
    if (type == "one_decimal") return sprintf("%.1f", number)
    if (type == "integer") return sprintf("%.0f", number)
    if (type == "integer_half_up") return round_half_up(number, 0)
    if (type == "decimal") {
        return sprintf("%.*f", int(metric_argument(metric, "digits", 3)), number) \
               metric_argument(metric, "suffix", "")
    }
    if (type == "decimal_with_small_positive") {
        if (number > 0 && number < metric_argument(metric, "threshold", .1) + 0) return metric_below(metric)
        return sprintf("%.*f", metric_digits(metric), number) metric_argument(metric, "suffix", "")
    }
    if (type == "time_with_limit") {
        if (number >= metric_argument(metric, "limit", 0) + 0) {
            return metric_argument(metric, "limit_value", "\\texttt{TL}")
        }
        return sprintf("%.*f", metric_digits(metric), number)
    }
    if (type == "time_with_limit_and_small_positive") {
        if (number >= metric_argument(metric, "limit", 0) + 0) return metric_argument(metric, "limit_value", "\\TL")
        if (number > 0 && number < metric_argument(metric, "threshold", .1) + 0) return metric_below(metric)
        return sprintf("%.*f", metric_digits(metric), number)
    }
    fail("unsupported comparison-table format: " type)
}

function metric_digits(metric) {
    return int(metric_argument(metric, "digits", metric_argument(metric, "precision", 1)))
}

function metric_below(metric,    threshold) {
    threshold = metric_argument(metric, "threshold", 0.1)
    return metric_argument(metric, "below", "$<$" sprintf("%g", threshold))
}

function metric_argument(metric, name, fallback) {
    if ((metric SUBSEP name) in metric_format_argument) return metric_format_argument[metric, name]
    return fallback
}
