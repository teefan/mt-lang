module std.fmt

import std.c.stdio as c
import std.str as text_ops
import std.string as string

const float_buffer_capacity: usize = 64

pub def append(output: ref[string.String], text: str) -> void:
    output.append(text)
    return

pub def string(text: str) -> string.String:
    return string.String.from_str(text)

pub def append_str(output: ref[string.String], text: str) -> void:
    append(output, text)
    return

pub def append_cstr(output: ref[string.String], c_text: cstr) -> void:
    output.append(text_ops.cstr_as_str(c_text))
    return

pub def append_bool(output: ref[string.String], bool_value: bool) -> void:
    if bool_value:
        output.append("true")
    else:
        output.append("false")
    return

def append_formatted_float(output: ref[string.String], format: cstr, number: f64) -> void:
    var buffer = zero[array[char, 64]]()
    let written = c.snprintf(ptr_of(ref_of(buffer[0])), float_buffer_capacity, format, number)
    if written < 0 or usize<-written >= float_buffer_capacity:
        panic("fmt could not format float")

    unsafe:
        append_cstr(output, cstr<-ptr_of(ref_of(buffer[0])))
    return

pub def append_f32(output: ref[string.String], number: f32) -> void:
    append_formatted_float(output, c"%g", f64<-number)
    return

pub def append_f64(output: ref[string.String], number: f64) -> void:
    append_formatted_float(output, c"%g", number)
    return

pub def append_f64_precision(output: ref[string.String], number: f64, precision: i32) -> void:
    var buffer = zero[array[char, 64]]()
    let written = c.snprintf(ptr_of(ref_of(buffer[0])), float_buffer_capacity, c"%.*f", precision, number)
    if written < 0 or usize<-written >= float_buffer_capacity:
        panic("fmt could not format float with precision")

    unsafe:
        append_cstr(output, cstr<-ptr_of(ref_of(buffer[0])))
    return

pub def append_usize(output: ref[string.String], number: usize) -> void:
    if number == 0:
        output.push_byte(u8<-48)
        return

    var digits: array[u8, 32]
    var count: usize = 0
    var remaining = number
    while remaining != 0:
        let digit = remaining % usize<-10
        digits[count] = u8<-(usize<-48 + digit)
        remaining = remaining / usize<-10
        count += 1

    while count > 0:
        count -= 1
        output.push_byte(digits[count])
    return

pub def append_u64(output: ref[string.String], number: u64) -> void:
    if number == 0:
        output.push_byte(u8<-48)
        return

    var digits: array[u8, 32]
    var count: usize = 0
    var remaining = number
    while remaining != 0:
        let digit = remaining % u64<-10
        digits[count] = u8<-(u64<-48 + digit)
        remaining = remaining / u64<-10
        count += 1

    while count > 0:
        count -= 1
        output.push_byte(digits[count])
    return

pub def append_u32(output: ref[string.String], number: u32) -> void:
    append_usize(output, usize<-number)
    return

pub def append_i64(output: ref[string.String], number: i64) -> void:
    if number < 0:
        output.append("-")
        append_u64(output, u64<-(-(number + 1)) + u64<-1)
        return

    append_u64(output, u64<-number)
    return

pub def append_i32(output: ref[string.String], number: i32) -> void:
    if number < 0:
        output.append("-")
        append_usize(output, usize<-(-i64<-number))
        return

    append_usize(output, usize<-number)
    return

pub def to_string_usize(value: usize) -> string.String:
    var result = string.String.create()
    append_usize(ref_of(result), value)
    return result

pub def to_string_i32(value: i32) -> string.String:
    var result = string.String.create()
    append_i32(ref_of(result), value)
    return result
