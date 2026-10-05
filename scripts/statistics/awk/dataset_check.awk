# Validate one adapter dataset against the checks declared in the recipe.
#
# Output is one "key<TAB>value" record per line:
#
#   rows <n>              number of data records
#   instances <n>         number of distinct instance keys
#   duplicates <n>        records beyond the first of each identity
#   missing <n>           declared experiment combinations that are absent
#   error <message>       one line per failed check
#   warning <message>     one line per advisory check
#
# Driver contract (-v): input (record CSV), spec (check specification), and
# instance (name of the instance column used by the combination check).
# The runtime column is taken from the specification.

BEGIN {
    load_input()
    classify_columns()
    read_spec()
    count_rows()
    check_columns()
    check_uniqueness()
    check_combinations()
    check_time_limit()
}

# ---------------------------------------------------------------------------
# Specification
# ---------------------------------------------------------------------------

function read_spec(    line, count, fields, i, j, pair) {
    instance_key = instance
    runtime_column = ""
    while ((getline line < spec) > 0) {
        if (line == "" || substr(line, 1, 1) == "#") continue
        count = split(line, fields, "\t")
        if (fields[1] == "required") required_count = split(fields[2], required_name, ",")
        else if (fields[1] == "unique") unique_count = split(fields[2], unique_name, ",")
        else if (fields[1] == "grid") grid_count = split(fields[2], grid_item, ";")
        else if (fields[1] == "time_limit") time_limit = fields[2] + 0
        else if (fields[1] == "tolerance") tolerance = fields[2] + 0
        else if (fields[1] == "runtime") runtime_column = fields[2]
        else if (fields[1] == "derived") {
            derived_name[++derived_count] = fields[2]
            derived_source[derived_count] = fields[3]
        }
        else if (fields[1] == "expected_instances") expected_instances = fields[2] + 0
        else fail("unknown check specification record: " fields[1])
    }
    close(spec)
    for (i = 1; i <= grid_count; i++) {
        split(grid_item[i], pair, "=")
        grid_name[i] = pair[1]
        grid_value_count[i] = split(pair[2], grid_value_item, ",")
        for (j = 1; j <= grid_value_count[i]; j++) grid_value[i, j] = grid_value_item[j]
    }
}

function report(kind, message) {
    print kind "\t" message
}

function is_derived(name,    i) {
    for (i = 1; i <= derived_count; i++) if (derived_name[i] == name) return 1
    return 0
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

function count_rows(    i, fields, name) {
    records = 0
    ninstances = 0
    for (i = 2; i <= nlines; i++) {
        split(data_line[i], fields, FS)
        records++
        name = value_of(instance_key, fields[column[instance_key]])
        if (name in seen_instance) continue
        seen_instance[name] = 1
        instance_list[++ninstances] = name
    }
    if (numeric_column[instance_key]) sort_numbers(instance_list, 1, ninstances)
    else sort_text(instance_list, 1, ninstances)
    print "rows\t" records
    print "instances\t" ninstances
    if (expected_instances > 0 && ninstances != expected_instances) {
        report("error", "Expected " expected_instances " distinct instances, found " ninstances ".")
    }
}

# Required columns must exist and must not be empty.  A column the recipe
# derives itself (the solved flag) counts as present.
function check_columns(    i, j, fields, name, nulls, absent) {
    for (i = 1; i <= required_count; i++) {
        name = required_name[i]
        if (is_derived(name)) continue
        if (!(name in column)) {
            absent = (absent == "" ? name : absent ", " name)
            continue
        }
        nulls = 0
        for (j = 2; j <= nlines; j++) {
            split(data_line[j], fields, FS)
            if (fields[column[name]] == "") nulls++
        }
        if (nulls > 0) report("error", "Missing values in required column: " name " (" nulls ").")
    }
    if (absent != "") report("error", "Missing required columns: " absent ".")
}

# The identity columns must identify at most one record.
function check_uniqueness(    i, j, fields, name, key) {
    duplicates = 0
    if (unique_count == 0) {
        print "duplicates\t0"
        return
    }
    for (j = 1; j <= unique_count; j++) {
        if (!(unique_name[j] in column)) {
            print "duplicates\t0"
            return
        }
    }
    for (i = 2; i <= nlines; i++) {
        split(data_line[i], fields, FS)
        key = ""
        for (j = 1; j <= unique_count; j++) {
            name = unique_name[j]
            key = key value_of(name, fields[column[name]]) SUBSEP
        }
        if (key in seen_identity) duplicates++
        else seen_identity[key] = 1
    }
    print "duplicates\t" duplicates
    if (duplicates > 0) report("error", "Duplicate records: " duplicates ".")
}

# Every declared combination of instance and grid values must be present.
function check_combinations(    i, j, fields, name, key, total) {
    missing = 0
    if (grid_count == 0 || !(instance_key in column)) {
        print "missing\t0"
        return
    }
    for (j = 1; j <= grid_count; j++) {
        if (!(grid_name[j] in column)) {
            print "missing\t0"
            return
        }
    }
    for (i = 2; i <= nlines; i++) {
        split(data_line[i], fields, FS)
        key = value_of(instance_key, fields[column[instance_key]])
        for (j = 1; j <= grid_count; j++) {
            name = grid_name[j]
            key = key SUBSEP value_of(name, fields[column[name]])
        }
        present[key] = 1
    }
    total = ninstances
    for (j = 1; j <= grid_count; j++) total *= grid_value_count[j]
    walk_combinations(1, "")
    print "missing\t" missing
    if (missing > 0) {
        report("error", "Missing experiment combinations: " missing " of " total ".")
    }
}

# Enumerate every instance crossed with the declared grid, in the order the
# recipe lists the values.
function walk_combinations(level, prefix,    i) {
    if (level == 1) {
        for (i = 1; i <= ninstances; i++) walk_combinations(2, instance_list[i])
        return
    }
    if (level > grid_count + 1) {
        if (!(prefix in present)) missing++
        return
    }
    for (i = 1; i <= grid_value_count[level - 1]; i++) {
        walk_combinations(level + 1, prefix SUBSEP value_of(grid_name[level - 1], grid_value[level - 1, i]))
    }
}

# The declared time limit must hold for the recorded runtimes.
function check_time_limit(    i, fields, over, limit) {
    if (time_limit <= 0) return
    if (tolerance < 0) {
        report("error", "time_limit_tolerance must be non-negative.")
        return
    }
    if (runtime_column == "" || !(runtime_column in column)) return
    limit = time_limit + tolerance
    over = 0
    for (i = 2; i <= nlines; i++) {
        split(data_line[i], fields, FS)
        if (fields[column[runtime_column]] != "" && fields[column[runtime_column]] + 0 > limit) over++
    }
    if (over > 0) {
        report("warning", "runtime exceeds time_limit + tolerance (" time_limit " + " tolerance ") in " over " records.")
    }
}
