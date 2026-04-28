module std.json

import std.ascii as ascii
import std.fmt as fmt
import std.string as string

pub enum TokenKind: u8
    left_brace = 1
    right_brace = 2
    left_bracket = 3
    right_bracket = 4
    colon = 5
    comma = 6
    string_value = 7
    number_value = 8
    true_value = 9
    false_value = 10
    null_value = 11
    eof = 12

pub enum Error: u8
    unexpected_end = 1
    unexpected_char = 2
    invalid_escape = 3
    invalid_number = 4

pub struct Token:
    kind: TokenKind
    text: str

pub struct Lexer:
    source: str
    index: usize

pub def create(source: str) -> Lexer:
    return Lexer(source = source, index = 0)

pub def left_brace() -> TokenKind:
    return TokenKind.left_brace

pub def right_brace() -> TokenKind:
    return TokenKind.right_brace

pub def left_bracket() -> TokenKind:
    return TokenKind.left_bracket

pub def right_bracket() -> TokenKind:
    return TokenKind.right_bracket

pub def colon() -> TokenKind:
    return TokenKind.colon

pub def comma() -> TokenKind:
    return TokenKind.comma

pub def string_value() -> TokenKind:
    return TokenKind.string_value

pub def number_value() -> TokenKind:
    return TokenKind.number_value

pub def true_value() -> TokenKind:
    return TokenKind.true_value

pub def false_value() -> TokenKind:
    return TokenKind.false_value

pub def null_value() -> TokenKind:
    return TokenKind.null_value

pub def eof() -> TokenKind:
    return TokenKind.eof

def token(kind: TokenKind) -> Token:
    return Token(kind = kind, text = "")

def slice_token(kind: TokenKind, source: str, start: usize, stop: usize) -> Token:
    unsafe:
        return Token(kind = kind, text = str(data = source.data + start, len = stop - start))

def byte_at(source: str, index: usize) -> u8:
    unsafe:
        return cast[u8](deref(source.data + index))

def skip_space(lexer: ref[Lexer]) -> void:
    while value(lexer).index < value(lexer).source.len and ascii.is_space(byte_at(value(lexer).source, value(lexer).index)):
        value(lexer).index += 1
    return

def match_keyword(lexer: ref[Lexer], keyword: str) -> bool:
    if value(lexer).source.len - value(lexer).index < keyword.len:
        return false

    var index: usize = 0
    while index < keyword.len:
        if byte_at(value(lexer).source, value(lexer).index + index) != byte_at(keyword, index):
            return false
        index += 1

    value(lexer).index += keyword.len
    return true

def read_string(lexer: ref[Lexer]) -> Result[Token, Error]:
    let start = value(lexer).index
    while value(lexer).index < value(lexer).source.len:
        let current = byte_at(value(lexer).source, value(lexer).index)
        if current == cast[u8](34):
            let stop = value(lexer).index
            value(lexer).index += 1
            return ok(slice_token(TokenKind.string_value, value(lexer).source, start, stop))
        elif current < cast[u8](32):
            return err(Error.unexpected_char)
        elif current == cast[u8](92):
            value(lexer).index += 1
            if value(lexer).index >= value(lexer).source.len:
                return err(Error.unexpected_end)

            let escaped = byte_at(value(lexer).source, value(lexer).index)
            if escaped == cast[u8](34) or escaped == cast[u8](47) or escaped == cast[u8](92) or escaped == cast[u8](98) or escaped == cast[u8](102) or escaped == cast[u8](110) or escaped == cast[u8](114) or escaped == cast[u8](116):
                value(lexer).index += 1
            elif escaped == cast[u8](117):
                value(lexer).index += 1
                var digit_count: usize = 0
                while digit_count < 4:
                    if value(lexer).index >= value(lexer).source.len:
                        return err(Error.unexpected_end)
                    if not ascii.is_hex_digit(byte_at(value(lexer).source, value(lexer).index)):
                        return err(Error.invalid_escape)
                    value(lexer).index += 1
                    digit_count += 1
            else:
                return err(Error.invalid_escape)
        else:
            value(lexer).index += 1

    return err(Error.unexpected_end)

def read_number(lexer: ref[Lexer]) -> Result[Token, Error]:
    let start = value(lexer).index
    if byte_at(value(lexer).source, value(lexer).index) == cast[u8](45):
        value(lexer).index += 1
        if value(lexer).index >= value(lexer).source.len:
            return err(Error.invalid_number)

    let first_digit = byte_at(value(lexer).source, value(lexer).index)
    if first_digit == cast[u8](48):
        value(lexer).index += 1
    elif first_digit >= cast[u8](49) and first_digit <= cast[u8](57):
        while value(lexer).index < value(lexer).source.len and ascii.is_digit(byte_at(value(lexer).source, value(lexer).index)):
            value(lexer).index += 1
    else:
        return err(Error.invalid_number)

    if value(lexer).index < value(lexer).source.len and byte_at(value(lexer).source, value(lexer).index) == cast[u8](46):
        value(lexer).index += 1
        if value(lexer).index >= value(lexer).source.len or not ascii.is_digit(byte_at(value(lexer).source, value(lexer).index)):
            return err(Error.invalid_number)
        while value(lexer).index < value(lexer).source.len and ascii.is_digit(byte_at(value(lexer).source, value(lexer).index)):
            value(lexer).index += 1

    if value(lexer).index < value(lexer).source.len:
        let exponent = byte_at(value(lexer).source, value(lexer).index)
        if exponent == cast[u8](101) or exponent == cast[u8](69):
            value(lexer).index += 1
            if value(lexer).index < value(lexer).source.len:
                let sign = byte_at(value(lexer).source, value(lexer).index)
                if sign == cast[u8](43) or sign == cast[u8](45):
                    value(lexer).index += 1
            if value(lexer).index >= value(lexer).source.len or not ascii.is_digit(byte_at(value(lexer).source, value(lexer).index)):
                return err(Error.invalid_number)
            while value(lexer).index < value(lexer).source.len and ascii.is_digit(byte_at(value(lexer).source, value(lexer).index)):
                value(lexer).index += 1

    return ok(slice_token(TokenKind.number_value, value(lexer).source, start, value(lexer).index))

pub def next(lexer: ref[Lexer]) -> Result[Token, Error]:
    skip_space(lexer)
    if value(lexer).index >= value(lexer).source.len:
        return ok(token(TokenKind.eof))

    let current = byte_at(value(lexer).source, value(lexer).index)
    if current == cast[u8](123):
        value(lexer).index += 1
        return ok(token(TokenKind.left_brace))
    elif current == cast[u8](125):
        value(lexer).index += 1
        return ok(token(TokenKind.right_brace))
    elif current == cast[u8](91):
        value(lexer).index += 1
        return ok(token(TokenKind.left_bracket))
    elif current == cast[u8](93):
        value(lexer).index += 1
        return ok(token(TokenKind.right_bracket))
    elif current == cast[u8](58):
        value(lexer).index += 1
        return ok(token(TokenKind.colon))
    elif current == cast[u8](44):
        value(lexer).index += 1
        return ok(token(TokenKind.comma))
    elif current == cast[u8](34):
        value(lexer).index += 1
        return read_string(lexer)
    elif current == cast[u8](45) or ascii.is_digit(current):
        return read_number(lexer)
    elif match_keyword(lexer, "true"):
        return ok(token(TokenKind.true_value))
    elif match_keyword(lexer, "false"):
        return ok(token(TokenKind.false_value))
    elif match_keyword(lexer, "null"):
        return ok(token(TokenKind.null_value))

    return err(Error.unexpected_char)

pub def append_null(output: ref[string.String]) -> void:
    string.append(output, "null")
    return

pub def append_bool(output: ref[string.String], value: bool) -> void:
    fmt.append_bool(output, value)
    return

pub def append_i32(output: ref[string.String], value: i32) -> void:
    fmt.append_i32(output, value)
    return

pub def append_usize(output: ref[string.String], value: usize) -> void:
    fmt.append_usize(output, value)
    return

def append_hex_nibble(output: ref[string.String], value: u8) -> void:
    if value < cast[u8](10):
        string.push_byte(output, cast[u8](48) + value)
    else:
        string.push_byte(output, cast[u8](65) + (value - cast[u8](10)))
    return

pub def append_string(output: ref[string.String], value: str) -> void:
    string.append(output, "\"")
    var index: usize = 0
    while index < value.len:
        let byte = byte_at(value, index)
        if byte == cast[u8](34):
            string.append(output, "\\\"")
        elif byte == cast[u8](92):
            string.append(output, "\\\\")
        elif byte == cast[u8](8):
            string.append(output, "\\b")
        elif byte == cast[u8](12):
            string.append(output, "\\f")
        elif byte == cast[u8](10):
            string.append(output, "\\n")
        elif byte == cast[u8](13):
            string.append(output, "\\r")
        elif byte == cast[u8](9):
            string.append(output, "\\t")
        elif byte < cast[u8](32):
            string.append(output, "\\u00")
            append_hex_nibble(output, byte >> 4)
            append_hex_nibble(output, byte & cast[u8](15))
        else:
            string.push_byte(output, byte)
        index += 1
    string.append(output, "\"")
    return
