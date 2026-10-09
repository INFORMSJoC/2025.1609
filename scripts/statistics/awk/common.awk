# Shared helpers for the MPCLP artifact statistics (POSIX awk).
#
# The adapter exports under output/artifacts/inputs are plain CSV files without
# quoted separators, so splitting on "," is sufficient.  These helpers
# reproduce exactly the parts of the previous pandas-based reader that the
# published numbers depend on:
#
#   * column lookup by name,
#   * the string form of a parsed cell, which is what the style registry keys
#     series by,
#   * equality filters written as "column=value".
#
# Load this file before a statistics or table script:
#   awk -v input=... -f common.awk -f series_values.awk

BEGIN {
    FS = ","
    OFS = ","
    CONVFMT = "%.17g"
}

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

# Read the whole input once: the statistics need two passes (column typing,
# then aggregation) and every artifact input is well under a megabyte.  The
# adapter exports use CRLF line endings, so the carriage return is dropped here
# the way a universal-newline reader would.
function load_input(    count, line) {
    count = 0
    while ((getline line < input) > 0) {
        sub(/\r$/, "", line)
        data_line[++count] = line
    }
    close(input)
    if (count == 0) fail("no rows read from " input)
    nlines = count
    read_header(data_line[1])
}

function read_header(line, fields, count, i) {
    count = split(line, fields, ",")
    nheader = count
    for (i = 1; i <= count; i++) {
        header_name[i] = fields[i]
        column[fields[i]] = i
    }
}

function require_column(name) {
    if (!(name in column)) fail("input has no column named " name)
    return column[name]
}

function fail(message) {
    print "error: " message > "/dev/stderr"
    exit 2
}

# ---------------------------------------------------------------------------
# Cell typing
#
# A column is numeric when every non-empty cell parses as a number.  Numeric
# columns are then split into integer and floating columns because their string
# forms differ ("1090" versus "1090.0"), and those forms are what the recipes
# and the style registry use as series keys.
# ---------------------------------------------------------------------------

function is_number(text) {
    return text ~ /^[-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$/
}

function classify_columns(    i, j, text, name) {
    for (i = 1; i <= nheader; i++) {
        numeric_column[header_name[i]] = 1
        fractional_column[header_name[i]] = 0
    }
    for (i = 2; i <= nlines; i++) {
        split(data_line[i], fields, FS)
        for (j = 1; j <= nheader; j++) {
            text = fields[j]
            if (text == "") continue
            name = header_name[j]
            if (numeric_column[name] && !is_number(text)) {
                numeric_column[name] = 0
            } else if (numeric_column[name] && text ~ /[.eE]/) {
                fractional_column[name] = 1
            }
        }
    }
}

# Shortest decimal text that reads back as exactly v.  This is the string form
# the previous implementation produced for the same value, so the style keys
# still match.
function num_text(v, precision, text) {
    if (v == int(v) && v < 1e16 && v > -1e16) return sprintf("%.1f", v)
    for (precision = 1; precision <= 17; precision++) {
        text = sprintf("%.*g", precision, v)
        if (text + 0 == v) break
    }
    return text
}

# Text of an integer cell without sign noise or leading zeros.
function int_text(text, sign, digits) {
    sign = (text ~ /^-/) ? "-" : ""
    digits = text
    sub(/^[-+]/, "", digits)
    sub(/^0+/, "", digits)
    if (digits == "") digits = "0"
    return sign digits
}

# Full-precision text of a cell, used for coordinates and table inputs.
function value_of(name, text) {
    if (text == "") return ""
    if (numeric_column[name]) return num_text(text + 0)
    return text
}

# String form of a cell, used as a series or group key.
function key_of(name, text) {
    if (text == "") return ""
    if (numeric_column[name]) {
        if (fractional_column[name]) return num_text(text + 0)
        return int_text(text)
    }
    return text
}

# ---------------------------------------------------------------------------
# Filters
#
# "column=value" pairs separated by ";".  A numeric column compares
# numerically, every other column compares as text, which is what the previous
# implementation did after type inference.
# ---------------------------------------------------------------------------

function parse_filter(spec, count, i, pair, parts) {
    nfilter = 0
    if (spec == "") return
    count = split(spec, filter_pair, ";")
    for (i = 1; i <= count; i++) {
        pair = filter_pair[i]
        if (pair == "") continue
        split(pair, parts, "=")
        require_column(parts[1])
        filter_index[nfilter] = column[parts[1]]
        filter_name[nfilter] = parts[1]
        filter_value[nfilter] = parts[2]
        nfilter++
    }
}

function row_passes_filter(fields,    i, text) {
    for (i = 0; i < nfilter; i++) {
        text = fields[filter_index[i]]
        if (numeric_column[filter_name[i]]) {
            if (text + 0 != filter_value[i] + 0) return 0
        } else if (text != filter_value[i]) {
            return 0
        }
    }
    return 1
}

# ---------------------------------------------------------------------------
# Decimal rounding
#
# Tables print their computed means through half-up rounding of the shortest
# decimal that reads back as the same double: that is the decimal the tables
# were always rounded from, so a mean that lands exactly on a .5 boundary keeps
# its direction.
# ---------------------------------------------------------------------------

function round_half_up(value, digits,    text, negative, point, whole, fraction, kept, carry) {
    text = shortest_decimal(value)
    negative = (substr(text, 1, 1) == "-")
    if (negative) text = substr(text, 2)
    text = expand_decimal(text)
    point = index(text, ".")
    if (point == 0) {
        whole = text
        fraction = ""
    } else {
        whole = substr(text, 1, point - 1)
        fraction = substr(text, point + 1)
    }
    kept = substr(fraction, 1, digits)
    while (length(kept) < digits) kept = kept "0"
    if (substr(fraction, digits + 1, 1) >= "5") {
        carry = increment_digits(whole kept)
        whole = substr(carry, 1, length(carry) - digits)
        kept = (digits > 0 ? substr(carry, length(carry) - digits + 1) : "")
        if (whole == "") whole = "0"
    }
    if (digits == 0) return (negative ? "-" : "") whole ""
    return (negative ? "-" : "") whole "." kept
}

# Add one to a digit string, carrying as far left as needed.
function increment_digits(text,    i, c) {
    for (i = length(text); i >= 1; i--) {
        c = substr(text, i, 1)
        if (c != "9") return substr(text, 1, i - 1) (c + 1) substr(text, i + 1)
        text = substr(text, 1, i - 1) "0" substr(text, i + 1)
    }
    return "1" text
}

# Shortest decimal string that reads back as the same double, in whatever
# notation printf chooses.
function shortest_decimal(value,    digits, text) {
    for (digits = 1; digits <= 17; digits++) {
        text = sprintf("%.*g", digits, value)
        if (text + 0 == value) return text
    }
    return sprintf("%.17g", value)
}

# Rewrite exponent notation ("1.23e-05") as plain decimal ("0.0000123").
function expand_decimal(text,    mark, mantissa, exponent, sign, point, digits_text, zeros, i) {
    mark = index(text, "e")
    if (mark == 0) mark = index(text, "E")
    if (mark == 0) return text
    mantissa = substr(text, 1, mark - 1)
    exponent = substr(text, mark + 1) + 0
    sign = (substr(mantissa, 1, 1) == "-") ? "-" : ""
    if (sign == "-") mantissa = substr(mantissa, 2)
    point = index(mantissa, ".")
    if (point == 0) {
        digits_text = mantissa
        point = length(mantissa) + 1
    } else {
        digits_text = substr(mantissa, 1, point - 1) substr(mantissa, point + 1)
    }
    point += exponent
    if (point <= 0) {
        zeros = ""
        for (i = 1; i <= -point + 1; i++) zeros = zeros "0"
        return sign "0." zeros digits_text
    }
    if (point >= length(digits_text) + 1) {
        zeros = ""
        for (i = 1; i <= point - 1 - length(digits_text); i++) zeros = zeros "0"
        return sign digits_text zeros
    }
    return sign substr(digits_text, 1, point) "." substr(digits_text, point + 1)
}

# ---------------------------------------------------------------------------
# Series order and sorting
# ---------------------------------------------------------------------------

# Split a comma-separated command-line list into list[1..n].
function split_list(text,    total, i) {
    delete list
    if (text == "") return 0
    total = split(text, list_item, ",")
    for (i = 1; i <= total; i++) list[i] = list_item[i]
    return total
}

# Draw order of the series found in the data: the declared order first, then
# the remaining series in order of first appearance.
function draw_order(present, npresent, declared, ndeclared,    i, name) {
    ndraw = 0
    for (i = 1; i <= ndeclared; i++) {
        name = declared[i]
        if ((name in present) && !(name in drawn)) {
            drawn[name] = 1
            draw_list[++ndraw] = name
        }
    }
    for (i = 1; i <= npresent; i++) {
        name = present[i]
        if (!(name in drawn)) draw_list[++ndraw] = name
    }
}

# Ascending numeric sort; the series hold at most a few thousand values.
function sort_numbers(values, low, high,    pivot, left, right, swap) {
    if (low >= high) return
    pivot = values[int((low + high) / 2)]
    left = low
    right = high
    while (left <= right) {
        while (values[left] < pivot) left++
        while (values[right] > pivot) right--
        if (left <= right) {
            swap = values[left]
            values[left] = values[right]
            values[right] = swap
            left++
            right--
        }
    }
    sort_numbers(values, low, right)
    sort_numbers(values, left, high)
}

# Ascending text sort used for deterministic tie-breaking.
function sort_text(values, low, high,    pivot, left, right, swap) {
    if (low >= high) return
    pivot = values[int((low + high) / 2)] ""
    left = low
    right = high
    while (left <= right) {
        while (values[left] "" < pivot) left++
        while (values[right] "" > pivot) right--
        if (left <= right) {
            swap = values[left]
            values[left] = values[right]
            values[right] = swap
            left++
            right--
        }
    }
    sort_text(values, low, right)
    sort_text(values, left, high)
}
