module std.fmt

import std.c.stdio as c
import std.str as text_ops
import std.string as string

const float_buffer_capacity: usize = 64

pub def append(output: ref[string.String], text: str) -> void:
    value(output).append(text)
    return

pub def string(text: str) -> string.String:
    return string.String.from_str(text)

pub def append_str(output: ref[string.String], text: str) -> void:
    append(output, text)
    return

pub def append_cstr(output: ref[string.String], c_text: cstr) -> void:
    value(output).append(text_ops.cstr_as_str(c_text))
    return

pub def append_bool(output: ref[string.String], bool_value: bool) -> void:
    if bool_value:
        value(output).append("true")
    else:
        value(output).append("false")
    return

def append_formatted_float(output: ref[string.String], format: cstr, number: f64) -> void:
    var buffer = zero[array[char, 64]]()
    let written = c.snprintf(raw(addr(buffer[0])), float_buffer_capacity, format, number)
    if written < 0 or cast[usize](written) >= float_buffer_capacity:
        panic("fmt could not format float")

    unsafe:
        append_cstr(output, cast[cstr](raw(addr(buffer[0]))))
    return

pub def append_f32(output: ref[string.String], number: f32) -> void:
    append_formatted_float(output, c"%g", cast[f64](number))
    return

pub def append_f64(output: ref[string.String], number: f64) -> void:
    append_formatted_float(output, c"%g", number)
    return

pub def append_usize(output: ref[string.String], number: usize) -> void:
    if number == 0:
        value(output).push_byte(cast[u8](48))
        return

    var digits: array[u8, 32]
    var count: usize = 0
    var remaining = number
    while remaining != 0:
        let digit = remaining % cast[usize](10)
        digits[count] = cast[u8](cast[usize](48) + digit)
        remaining = remaining / cast[usize](10)
        count += 1

    while count > 0:
        count -= 1
        value(output).push_byte(digits[count])
    return

pub def append_u64(output: ref[string.String], number: u64) -> void:
    if number == 0:
        value(output).push_byte(cast[u8](48))
        return

    var digits: array[u8, 32]
    var count: usize = 0
    var remaining = number
    while remaining != 0:
        let digit = remaining % cast[u64](10)
        digits[count] = cast[u8](cast[u64](48) + digit)
        remaining = remaining / cast[u64](10)
        count += 1

    while count > 0:
        count -= 1
        value(output).push_byte(digits[count])
    return

pub def append_u32(output: ref[string.String], number: u32) -> void:
    append_usize(output, cast[usize](number))
    return

pub def append_i64(output: ref[string.String], number: i64) -> void:
    if number < 0:
        value(output).append("-")
        append_u64(output, cast[u64](-(number + 1)) + cast[u64](1))
        return

    append_u64(output, cast[u64](number))
    return

pub def append_i32(output: ref[string.String], number: i32) -> void:
    if number < 0:
        value(output).append("-")
        append_usize(output, cast[usize](-cast[i64](number)))
        return

    append_usize(output, cast[usize](number))
    return

pub def to_string_usize(value: usize) -> string.String:
    var result = string.String.create()
    append_usize(addr(result), value)
    return result

pub def to_string_i32(value: i32) -> string.String:
    var result = string.String.create()
    append_i32(addr(result), value)
    return result
