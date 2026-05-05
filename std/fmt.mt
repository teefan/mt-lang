module std.fmt

import std.c.stdio as c
import std.str as text_ops
import std.string as string

const float_buffer_capacity: ptr_uint = 64


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


def append_formatted_float(output: ref[string.String], format: cstr, number: double) -> void:
    var buffer = zero[array[char, 64]]
    let written = c.snprintf(ptr_of(buffer[0]), float_buffer_capacity, format, number)
    if written < 0 or ptr_uint<-written >= float_buffer_capacity:
        panic("fmt could not format float")

    unsafe:
        append_cstr(output, cstr<-ptr_of(buffer[0]))
    return


pub def append_float(output: ref[string.String], number: float) -> void:
    append_formatted_float(output, c"%g", double<-number)
    return


pub def append_double(output: ref[string.String], number: double) -> void:
    append_formatted_float(output, c"%g", number)
    return


pub def append_double_precision(output: ref[string.String], number: double, precision: int) -> void:
    var buffer = zero[array[char, 64]]
    let written = c.snprintf(ptr_of(buffer[0]), float_buffer_capacity, c"%.*f", precision, number)
    if written < 0 or ptr_uint<-written >= float_buffer_capacity:
        panic("fmt could not format float with precision")

    unsafe:
        append_cstr(output, cstr<-ptr_of(buffer[0]))
    return


pub def append_ptr_uint(output: ref[string.String], number: ptr_uint) -> void:
    if number == 0:
        output.push_byte(ubyte<-48)
        return

    var digits: array[ubyte, 32]
    var count: ptr_uint = 0
    var remaining = number
    while remaining != 0:
        let digit = remaining % ptr_uint<-10
        digits[count] = ubyte<-(ptr_uint<-48 + digit)
        remaining = remaining / ptr_uint<-10
        count += 1

    while count > 0:
        count -= 1
        output.push_byte(digits[count])
    return


pub def append_ulong(output: ref[string.String], number: ulong) -> void:
    if number == 0:
        output.push_byte(ubyte<-48)
        return

    var digits: array[ubyte, 32]
    var count: ptr_uint = 0
    var remaining = number
    while remaining != 0:
        let digit = remaining % ulong<-10
        digits[count] = ubyte<-(ulong<-48 + digit)
        remaining = remaining / ulong<-10
        count += 1

    while count > 0:
        count -= 1
        output.push_byte(digits[count])
    return


pub def append_uint(output: ref[string.String], number: uint) -> void:
    append_ptr_uint(output, ptr_uint<-number)
    return


pub def append_long(output: ref[string.String], number: long) -> void:
    if number < 0:
        output.append("-")
        append_ulong(output, ulong<-(-(number + 1)) + ulong<-1)
        return

    append_ulong(output, ulong<-number)
    return


pub def append_int(output: ref[string.String], number: int) -> void:
    if number < 0:
        output.append("-")
        append_ptr_uint(output, ptr_uint<-(-long<-number))
        return

    append_ptr_uint(output, ptr_uint<-number)
    return


pub def to_string_ptr_uint(value: ptr_uint) -> string.String:
    var result = string.String.create()
    append_ptr_uint(ref_of(result), value)
    return result


pub def to_string_int(value: int) -> string.String:
    var result = string.String.create()
    append_int(ref_of(result), value)
    return result
