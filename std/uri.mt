import std.maybe as maybe
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


public function path_from_file_uri(uri: str) -> maybe.Maybe[string.String]:
    if not uri.starts_with(FILE_URI_PREFIX):
        return maybe.Maybe[string.String].none

    let encoded_path = uri.slice(FILE_URI_PREFIX.len, uri.len - FILE_URI_PREFIX.len)
    let decoded_result = percent_decode(encoded_path)
    match decoded_result:
        maybe.Maybe.none:
            return maybe.Maybe[string.String].none
        maybe.Maybe.some as payload:
            var decoded = payload.value
            match owned_utf8_view(decoded):
                maybe.Maybe.none:
                    decoded.release()
                    return maybe.Maybe[string.String].none
                maybe.Maybe.some as view_payload:
                    let decoded_path = view_payload.value
                    if leading_slash_drive_path(decoded_path):
                        var normalized = string.String.from_str(decoded_path.slice(1, decoded_path.len - 1))
                        decoded.release()
                        return maybe.Maybe[string.String].some(value= normalized)

                    return maybe.Maybe[string.String].some(value= decoded)


public function percent_decode(text_value: str) -> maybe.Maybe[string.String]:
    var result = string.String.with_capacity(text_value.len)

    var index: ptr_uint = 0
    while index < text_value.len:
        let byte = text_value.byte_at(index)
        if byte != ubyte<-37:
            result.push_byte(byte)
            index += 1
            continue

        if index + 2 >= text_value.len:
            result.release()
            return maybe.Maybe[string.String].none

        let high = hex_digit_value(text_value.byte_at(index + 1))
        let low = hex_digit_value(text_value.byte_at(index + 2))
        if high < 0 or low < 0:
            result.release()
            return maybe.Maybe[string.String].none

        result.push_byte(ubyte<-(high * 16 + low))
        index += 3

    return maybe.Maybe[string.String].some(value= result)


function append_percent_encoded_path(output: ref[string.String], path_text: str) -> void:
    var index: ptr_uint = 0
    while index < path_text.len:
        let byte = path_text.byte_at(index)
        if byte == ubyte<-47:
            output.push_byte(byte)
        elif safe_path_byte(byte):
            output.push_byte(byte)
        else:
            append_percent_encoded_byte(output, byte)
        index += 1

    return


function append_percent_encoded_byte(output: ref[string.String], byte: ubyte) -> void:
    output.push_byte(ubyte<-37)
    output.push_byte(hex_digit(byte >> ubyte<-4))
    output.push_byte(hex_digit(byte & ubyte<-0x0F))
    return


function hex_digit(value: ubyte) -> ubyte:
    if value < ubyte<-10:
        return ubyte<-(ubyte<-48 + value)

    return ubyte<-(ubyte<-65 + (value - ubyte<-10))


function hex_digit_value(byte: ubyte) -> int:
    if byte >= ubyte<-48 and byte <= ubyte<-57:
        return int<-(byte - ubyte<-48)
    if byte >= ubyte<-65 and byte <= ubyte<-70:
        return 10 + int<-(byte - ubyte<-65)
    if byte >= ubyte<-97 and byte <= ubyte<-102:
        return 10 + int<-(byte - ubyte<-97)

    return -1


function safe_path_byte(byte: ubyte) -> bool:
    return ascii_letter(byte) or ascii_digit(byte) or byte == ubyte<-95 or byte == ubyte<-46 or byte == ubyte<-45 or byte == ubyte<-42


function ascii_letter(byte: ubyte) -> bool:
    return (byte >= ubyte<-65 and byte <= ubyte<-90) or (byte >= ubyte<-97 and byte <= ubyte<-122)


function ascii_digit(byte: ubyte) -> bool:
    return byte >= ubyte<-48 and byte <= ubyte<-57


function leading_slash_drive_path(path_text: str) -> bool:
    return path_text.len >= 3 and path_text.byte_at(0) == ubyte<-47 and ascii_letter(path_text.byte_at(1)) and path_text.byte_at(2) == ubyte<-58


function owned_utf8_view(value: string.String) -> maybe.Maybe[str]:
    return text.utf8_byte_span_as_str(unsafe: span[ubyte](data = ptr[ubyte]<-value.data, len = value.len))
