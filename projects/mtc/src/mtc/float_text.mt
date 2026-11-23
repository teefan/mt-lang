## Ruby-compatible floating-point text: `Float#to_s` for a double.
##
## A value whose `%.1f` form parses back unchanged keeps one decimal (`1.0`,
## `0.2`, `100000000000000000000.0`); every other value uses the shortest
## decimal string that round-trips, so `0.2` is not printed as
## `0.20000000000000001`.

import std.fmt as fmt
import std.libc as libc
import std.str
import std.string as string


## Render a double the way Ruby's `Float#to_s` does.
public function double_to_str(value: double) -> str:
    var one_decimal = string.String.create()
    fmt.append_double_precision(ref_of(one_decimal), value, 1)
    if parses_back_to(one_decimal.as_str(), value):
        return one_decimal.as_str()
    one_decimal.release()

    var precision = 1
    while precision <= 17:
        var candidate = string.String.create()
        fmt.append_double_g(ref_of(candidate), value, precision)
        if parses_back_to(candidate.as_str(), value):
            var styled = ruby_exponent_style(candidate.as_str())
            candidate.release()
            return styled.as_str()
        candidate.release()
        precision += 1

    var full = string.String.create()
    fmt.append_double_full(ref_of(full), value)
    return full.as_str()


## True when `text` parses back to exactly `value`.
function parses_back_to(text: str, value: double) -> bool:
    return libc.parse_double_to_end(text, null) == value


## An owned copy of `text` with Ruby's exponent spelling: `%g` writes `1e-07`
## where Ruby writes `1.0e-07`, so a fraction digit is inserted before the
## exponent when it is missing.
function ruby_exponent_style(text: str) -> string.String:
    var buf = string.String.create()
    let e_pos = text.find_substring("e") else:
        buf.append(text)
        return buf
    if text.contains_substring("."):
        buf.append(text)
        return buf
    buf.append(text.slice(0, e_pos))
    buf.append(".0")
    buf.append(text.slice(e_pos, text.len - e_pos))
    return buf
