module std.fmt

import std.string as string

pub def append_str(output: ref[string.String], value: str) -> void:
    string.append(output, value)
    return

pub def append_bool(output: ref[string.String], value: bool) -> void:
    if value:
        string.append(output, "true")
    else:
        string.append(output, "false")
    return

pub def append_usize(output: ref[string.String], value: usize) -> void:
    if value == 0:
        string.push_byte(output, cast[u8](48))
        return

    var digits: array[u8, 32]
    var count: usize = 0
    var remaining = value
    while remaining != 0:
        let digit = remaining % cast[usize](10)
        digits[count] = cast[u8](cast[usize](48) + digit)
        remaining = remaining / cast[usize](10)
        count += 1

    while count > 0:
        count -= 1
        string.push_byte(output, digits[count])
    return

pub def append_i32(output: ref[string.String], value: i32) -> void:
    if value < 0:
        string.append(output, "-")
        append_usize(output, cast[usize](-cast[i64](value)))
        return

    append_usize(output, cast[usize](value))
    return

pub def to_string_usize(value: usize) -> string.String:
    var result = string.create()
    append_usize(addr(result), value)
    return result

pub def to_string_i32(value: i32) -> string.String:
    var result = string.create()
    append_i32(addr(result), value)
    return result
