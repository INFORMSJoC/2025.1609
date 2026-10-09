# One record panel: list records side by side as booktabs LaTeX.
#
# This is the plain listing of the instances a study solved, as opposed to the
# aggregated comparison tables that awk/comparison_table.awk lays out.
#
# Specification records (tab separated; see tables/table5.recipe.yaml):
#
#   order_key <column|->                record order of the listing
#   empty <value>                       text of an empty cell
#   split_after <n>                     records of the left panel
#   separator <latex>                   column separator between the panels
#   column <field> <label> <align> <format type> <digits=n>
#
# Driver contract (-v): input, spec.

BEGIN {
    load_input()
    classify_columns()
    read_spec()
    order_records()
    emit_table()
}

function read_spec(    line, count, fields, i, j, mark, name) {
    split_after = 0
    separator = "@{\\qquad}"
    empty = "--"
    while ((getline line < spec) > 0) {
        if (line == "" || substr(line, 1, 1) == "#") continue
        count = split(line, fields, "\t")
        if (fields[1] == "order_key") order_key = (fields[2] == "-" ? "" : fields[2])
        else if (fields[1] == "empty") empty = fields[2]
        else if (fields[1] == "split_after") split_after = fields[2] + 0
        else if (fields[1] == "separator") separator = fields[2]
        else if (fields[1] == "column") {
            column_count++
            record_field[column_count] = fields[2]
            record_label[column_count] = fields[3]
            record_align[column_count] = (fields[4] == "" ? "l" : fields[4])
            record_type[column_count] = fields[5]
            for (j = 6; j <= count; j++) {
                mark = index(fields[j], "=")
                name = substr(fields[j], 1, mark - 1)
                if (name == "digits") record_digits[column_count] = substr(fields[j], mark + 1) + 0
            }
        } else {
            fail("unknown record-panel specification record: " fields[1])
        }
    }
    close(spec)
    if (column_count == 0) fail("the record-panel specification has no columns")
    for (i = 1; i <= column_count; i++) {
        require_column(record_field[i])
    }
}

# Panel rows are the records in the order the specification asks for.
function order_records(    i, count, fields, value, slot) {
    count = 0
    for (i = 2; i <= nlines; i++) row_index[++count] = i
    npanel_rows = count
    if (order_key == "" || !(order_key in column)) return
    for (i = 2; i <= count; i++) {
        value = row_index[i]
        split(data_line[value], fields, FS)
        slot = i - 1
        while (slot >= 1 && after(row_index[slot], value, fields)) {
            row_index[slot + 1] = row_index[slot]
            slot--
        }
        row_index[slot + 1] = value
    }
}

function after(left, right, fields,    left_fields, left_value, right_value) {
    split(data_line[left], left_fields, FS)
    left_value = left_fields[column[order_key]]
    right_value = fields[column[order_key]]
    if (numeric_column[order_key]) return left_value + 0 > right_value + 0
    return left_value > right_value
}

function emit_table(    slot, text, rows) {
    text = ""
    for (slot = 1; slot <= column_count; slot++) text = text record_align[slot]
    text = text separator
    for (slot = 1; slot <= column_count; slot++) text = text record_align[slot]
    print "\\begin{tabular}{" text "}"
    print "\\toprule"
    text = ""
    for (slot = 1; slot <= column_count; slot++) {
        text = text (slot > 1 ? " & " : "") record_label[slot]
    }
    print text " & " text row_end()
    print "\\midrule"
    rows = split_after
    if (npanel_rows - split_after > rows) rows = npanel_rows - split_after
    for (slot = 1; slot <= rows; slot++) {
        print panel_cells(slot) " & " panel_cells(split_after + slot) row_end()
    }
    print "\\bottomrule"
    print "\\end{tabular}"
}

# Cells of one panel row, blank where that panel has no record left.
function panel_cells(row,    slot, fields, text) {
    text = ""
    for (slot = 1; slot <= column_count; slot++) {
        text = text (slot > 1 ? " & " : "")
        if (row >= 1 && row <= npanel_rows) {
            split(data_line[row_index[row]], fields, FS)
            text = text format_cell(fields[column[record_field[slot]]], \
                                    record_type[slot], record_digits[slot])
        }
    }
    return text
}

function format_cell(value, type, digits) {
    if (value == "") return empty
    if (type == "" || type == "text") return value
    if (type == "integer") return round_half_up(value + 0, 0)
    if (type == "fixed") return sprintf("%.*f", (digits == 0 ? 1 : digits), value + 0)
    fail("unsupported record-panel format: " type)
}

function row_end() {
    return " \\\\"
}
