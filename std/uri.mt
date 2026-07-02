import std.path as path
import std.str as text
import std.string as string

const FILE_URI_PREFIX: str = "file://"


public function file_uri_from_path(path_text: str) -> string.String:
    var normalized = path.normalize_separators(path_text)
    defer normalized.release()

    var result = string.String.from_str(FILE_URI_PREFIX)
    append_percent_encoded_path(ref_of(result), normalized.as_str())
    return result


public function path_from_file_uri(uri: str) -> Option[string.String]:
    if not uri.starts_with(FILE_URI_PREFIX):
        return Option[string.String].none

    let encoded_path = uri.slice(FILE_URI_PREFIX.len, uri.len - FILE_URI_PREFIX.len)
    var decoded = percent_decode(encoded_path)?
    match owned_utf8_view(decoded):
        Option.none:
            decoded.release()
            return Option[string.String].none
        Option.some as view_payload:
            let decoded_path = view_payload.value
            if leading_slash_drive_path(decoded_path):
                let normalized = string.String.from_str(decoded_path.slice(1, decoded_path.len - 1))
                decoded.release()
                return Option[string.String].some(value= normalized)

            return Option[string.String].some(value= decoded)


public function percent_decode(text_value: str) -> Option[string.String]:
    var result = string.String.with_capacity(text_value.len)

    var index: ptr_uint = 0
    while index < text_value.len:
        let value = text_value.byte_at(index)
        if value != 37:
            result.push_byte(value)
            index += 1
            continue

        if index + 2 >= text_value.len:
            result.release()
            return Option[string.String].none

        let high = hex_digit_value(text_value.byte_at(index + 1))
        let low = hex_digit_value(text_value.byte_at(index + 2))
        if high < 0 or low < 0:
            result.release()
            return Option[string.String].none

        result.push_byte(ubyte<-(high * 16 + low))
        index += 3

    return Option[string.String].some(value= result)


function append_percent_encoded_path(output: ref[string.String], path_text: str) -> void:
    var index: ptr_uint = 0
    while index < path_text.len:
        let value = path_text.byte_at(index)
        if value == 47:
            output.push_byte(value)
        else if safe_path_byte(value):
            output.push_byte(value)
        else:
            append_percent_encoded_byte(output, value)
        index += 1


function append_percent_encoded_byte(output: ref[string.String], value: ubyte) -> void:
    output.push_byte(37)
    output.push_byte(hex_digit(value >> 4))
    output.push_byte(hex_digit(value & 0x0F))


function hex_digit(value: ubyte) -> ubyte:
    if value < 10:
        return (48 + value)

    return (65 + (value - 10))


function hex_digit_value(value: ubyte) -> int:
    if value >= 48 and value <= 57:
        return (value - 48ub)
    if value >= 65 and value <= 70:
        return 10 + int<-(value - 65ub)
    if value >= 97 and value <= 102:
        return 10 + int<-(value - 97ub)

    return -1


function safe_path_byte(value: ubyte) -> bool:
    return ascii_letter(value) or ascii_digit(value) or value == 95 or value == 46 or value == 45 or value == 42


function ascii_letter(value: ubyte) -> bool:
    return (value >= 65 and value <= 90) or (value >= 97 and value <= 122)


function ascii_digit(value: ubyte) -> bool:
    return value >= 48 and value <= 57


function leading_slash_drive_path(path_text: str) -> bool:
    return path_text.len >= 3 and path_text.byte_at(0) == 47 and ascii_letter(path_text.byte_at(1)) and path_text.byte_at(2) == 58


function owned_utf8_view(value: string.String) -> Option[str]:
    return text.utf8_byte_span_as_str(unsafe: span[ubyte](data = ptr[ubyte]<-value.data, len = value.len))
