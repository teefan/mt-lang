import std.c.stdio as c
import std.str as text_ops
import std.string as string

const float_buffer_capacity: ptr_uint = 64
const integer_digit_buffer_capacity: ptr_uint = 64


public function append(output: ref[string.String], text: str) -> void:
    output.append(text)


public function format(text: str) -> string.String:
    return string.String.from_str(text)


public function append_format(output: ref[string.String], text: str) -> void:
    output.append(text)


public function assign_format(output: ref[string.String], text: str) -> void:
    output.clear()
    output.append(text)


public function append_str(output: ref[string.String], text: str) -> void:
    append(output, text)


public function append_cstr(output: ref[string.String], c_text: cstr) -> void:
    output.append(text_ops.cstr_as_str(c_text))


public function append_bool(output: ref[string.String], bool_value: bool) -> void:
    if bool_value:
        output.append("true")
    else:
        output.append("false")


function append_formatted_float(output: ref[string.String], format: cstr, number: double) -> void:
    var buffer = zero[array[char, 64]]
    let written = c.snprintf(ptr_of(buffer[0]), float_buffer_capacity, format, number)
    if written < 0 or ptr_uint<-written >= float_buffer_capacity:
        fatal("fmt could not format float")

    output.append(text_ops.chars_as_str(ptr_of(buffer[0])))


public function append_float(output: ref[string.String], number: float) -> void:
    append_formatted_float(output, c"%g", double<-number)


public function append_double(output: ref[string.String], number: double) -> void:
    append_formatted_float(output, c"%g", number)


public function append_double_precision(output: ref[string.String], number: double, precision: int) -> void:
    var buffer = zero[array[char, 64]]
    let written = c.snprintf(ptr_of(buffer[0]), float_buffer_capacity, c"%.*f", precision, number)
    if written < 0 or ptr_uint<-written >= float_buffer_capacity:
        fatal("fmt could not format float with precision")

    output.append(text_ops.chars_as_str(ptr_of(buffer[0])))


function radix_digit_byte(digit: ulong, uppercase: bool) -> ubyte:
    if digit < 10:
        return ubyte<-(48ul + digit)

    if uppercase:
        return ubyte<-(65ul + (digit - 10))

    return ubyte<-(97ul + (digit - 10))


function append_ulong_radix(output: ref[string.String], number: ulong, base: ulong, uppercase: bool) -> void:
    if number == 0:
        output.push_byte(48)
        return

    var digits: array[ubyte, 64]
    var count: ptr_uint = 0
    var remaining = number
    while remaining != 0:
        let digit = remaining % base
        digits[count] = radix_digit_byte(digit, uppercase)
        remaining = remaining / base
        count += 1

    while count > 0:
        count -= 1
        output.push_byte(digits[count])


public function append_ulong_hex(output: ref[string.String], number: ulong) -> void:
    append_ulong_radix(output, number, 16, false)


public function append_ulong_hex_upper(output: ref[string.String], number: ulong) -> void:
    append_ulong_radix(output, number, 16, true)


public function append_long_hex(output: ref[string.String], number: long) -> void:
    if number < 0:
        output.append("-")
        append_ulong_hex(output, ulong<-(-(number + 1)) + 1)
        return

    append_ulong_hex(output, ulong<-number)


public function append_long_hex_upper(output: ref[string.String], number: long) -> void:
    if number < 0:
        output.append("-")
        append_ulong_hex_upper(output, ulong<-(-(number + 1)) + 1)
        return

    append_ulong_hex_upper(output, ulong<-number)


public function append_ulong_oct(output: ref[string.String], number: ulong) -> void:
    append_ulong_radix(output, number, 8, false)


public function append_long_oct(output: ref[string.String], number: long) -> void:
    if number < 0:
        output.append("-")
        append_ulong_oct(output, ulong<-(-(number + 1)) + 1)
        return

    append_ulong_oct(output, ulong<-number)


public function append_ulong_bin(output: ref[string.String], number: ulong) -> void:
    append_ulong_radix(output, number, 2, false)


public function append_long_bin(output: ref[string.String], number: long) -> void:
    if number < 0:
        output.append("-")
        append_ulong_bin(output, ulong<-(-(number + 1)) + 1)
        return

    append_ulong_bin(output, ulong<-number)


public function append_ptr_uint(output: ref[string.String], number: ptr_uint) -> void:
    if number == 0:
        output.push_byte(48)
        return

    var digits: array[ubyte, 32]
    var count: ptr_uint = 0
    var remaining = number
    while remaining != 0:
        let digit = remaining % 10
        digits[count] = ubyte<-(48z + digit)
        remaining = remaining / 10
        count += 1

    while count > 0:
        count -= 1
        output.push_byte(digits[count])


public function append_ulong(output: ref[string.String], number: ulong) -> void:
    if number == 0:
        output.push_byte(48)
        return

    var digits: array[ubyte, 32]
    var count: ptr_uint = 0
    var remaining = number
    while remaining != 0:
        let digit = remaining % 10
        digits[count] = ubyte<-(48ul + digit)
        remaining = remaining / 10
        count += 1

    while count > 0:
        count -= 1
        output.push_byte(digits[count])


public function append_uint(output: ref[string.String], number: uint) -> void:
    append_ptr_uint(output, ptr_uint<-number)


public function append_long(output: ref[string.String], number: long) -> void:
    if number < 0:
        output.append("-")
        append_ulong(output, ulong<-(-(number + 1)) + 1)
        return

    append_ulong(output, ulong<-number)


public function append_int(output: ref[string.String], number: int) -> void:
    if number < 0:
        output.append("-")
        append_ptr_uint(output, ptr_uint<-(-(long<-number)))
        return

    append_ptr_uint(output, ptr_uint<-number)


public function to_string_ptr_uint(value: ptr_uint) -> string.String:
    var result = string.String.create()
    append_ptr_uint(ref_of(result), value)
    return result


public function to_string_int(value: int) -> string.String:
    var result = string.String.create()
    append_int(ref_of(result), value)
    return result


# Reflective debug formatter for any value. Scalars render directly; a struct
# renders as `{ field = value, ... }`, recursing into each field via its
# compile-time `field.type`. Types other than the listed primitives and structs
# of such fields are unsupported (they fail at specialization).
public function format_value[T](output: ref[string.String], value: const_ptr[T]) -> void:
    unsafe:
        inline if T == int:
            append_int(output, read(ptr[int]<-value))
        else if T == uint:
            append_uint(output, read(ptr[uint]<-value))
        else if T == long:
            append_long(output, read(ptr[long]<-value))
        else if T == ulong:
            append_ulong(output, read(ptr[ulong]<-value))
        else if T == ptr_uint:
            append_ptr_uint(output, read(ptr[ptr_uint]<-value))
        else if T == ptr_int:
            append_long(output, long<-read(ptr[ptr_int]<-value))
        else if T == byte:
            append_int(output, int<-read(ptr[byte]<-value))
        else if T == short:
            append_int(output, int<-read(ptr[short]<-value))
        else if T == ubyte:
            append_uint(output, uint<-read(ptr[ubyte]<-value))
        else if T == ushort:
            append_uint(output, uint<-read(ptr[ushort]<-value))
        else if T == char:
            append_int(output, int<-read(ptr[char]<-value))
        else if T == bool:
            append_bool(output, read(ptr[bool]<-value))
        else if T == float:
            append_float(output, read(ptr[float]<-value))
        else if T == double:
            append_double(output, read(ptr[double]<-value))
        else if T == str:
            append_str(output, read(ptr[str]<-value))
        else if T == cstr:
            append_cstr(output, read(ptr[cstr]<-value))
        else:
            output.append("{ ")
            var first = true
            inline for field in fields_of(T):
                if not first:
                    output.append(", ")

                first = false
                output.append(field.name)
                output.append(" = ")
                let offset = offset_of(T, field)
                format_value[field.type](output, const_ptr[field.type]<-(ptr[ubyte]<-value + offset))

            output.append(" }")
