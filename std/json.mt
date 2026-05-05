module std.json

import std.ascii as ascii
import std.fmt as fmt
import std.string as string

pub enum TokenKind: ubyte
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

pub enum Error: ubyte
    unexpected_end = 1
    unexpected_char = 2
    invalid_escape = 3
    invalid_number = 4

pub struct Token:
    kind: TokenKind
    text: str

pub struct Lexer:
    source: str
    index: ptr_uint


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


def slice_token(kind: TokenKind, source: str, start: ptr_uint, stop: ptr_uint) -> Token:
    unsafe:
        return Token(kind = kind, text = str(data = source.data + start, len = stop - start))


def byte_at(source: str, index: ptr_uint) -> ubyte:
    unsafe:
        return ubyte<-read(source.data + index)


def skip_space(lexer: ref[Lexer]) -> void:
    while lexer.index < lexer.source.len and ascii.is_space(byte_at(lexer.source, lexer.index)):
        lexer.index += 1
    return


def match_keyword(lexer: ref[Lexer], keyword: str) -> bool:
    if lexer.source.len - lexer.index < keyword.len:
        return false

    var index: ptr_uint = 0
    while index < keyword.len:
        if byte_at(lexer.source, lexer.index + index) != byte_at(keyword, index):
            return false
        index += 1

    lexer.index += keyword.len
    return true


def read_string(lexer: ref[Lexer]) -> Result[Token, Error]:
    let start = lexer.index
    while lexer.index < lexer.source.len:
        let current = byte_at(lexer.source, lexer.index)
        if current == ubyte<-34:
            let stop = lexer.index
            lexer.index += 1
            return ok(slice_token(TokenKind.string_value, lexer.source, start, stop))
        elif current < ubyte<-32:
            return err(Error.unexpected_char)
        elif current == ubyte<-92:
            lexer.index += 1
            if lexer.index >= lexer.source.len:
                return err(Error.unexpected_end)

            let escaped = byte_at(lexer.source, lexer.index)
            if escaped == ubyte<-34 or escaped == ubyte<-47 or escaped == ubyte<-92 or escaped == ubyte<-98 or escaped == ubyte<-102 or escaped == ubyte<-110 or escaped == ubyte<-114 or escaped == ubyte<-116:
                lexer.index += 1
            elif escaped == ubyte<-117:
                lexer.index += 1
                var digit_count: ptr_uint = 0
                while digit_count < 4:
                    if lexer.index >= lexer.source.len:
                        return err(Error.unexpected_end)
                    if not ascii.is_hex_digit(byte_at(lexer.source, lexer.index)):
                        return err(Error.invalid_escape)
                    lexer.index += 1
                    digit_count += 1
            else:
                return err(Error.invalid_escape)
        else:
            lexer.index += 1

    return err(Error.unexpected_end)


def read_number(lexer: ref[Lexer]) -> Result[Token, Error]:
    let start = lexer.index
    if byte_at(lexer.source, lexer.index) == ubyte<-45:
        lexer.index += 1
        if lexer.index >= lexer.source.len:
            return err(Error.invalid_number)

    let first_digit = byte_at(lexer.source, lexer.index)
    if first_digit == ubyte<-48:
        lexer.index += 1
    elif first_digit >= ubyte<-49 and first_digit <= ubyte<-57:
        while lexer.index < lexer.source.len and ascii.is_digit(byte_at(lexer.source, lexer.index)):
            lexer.index += 1
    else:
        return err(Error.invalid_number)

    if lexer.index < lexer.source.len and byte_at(lexer.source, lexer.index) == ubyte<-46:
        lexer.index += 1
        if lexer.index >= lexer.source.len or not ascii.is_digit(byte_at(lexer.source, lexer.index)):
            return err(Error.invalid_number)
        while lexer.index < lexer.source.len and ascii.is_digit(byte_at(lexer.source, lexer.index)):
            lexer.index += 1

    if lexer.index < lexer.source.len:
        let exponent = byte_at(lexer.source, lexer.index)
        if exponent == ubyte<-101 or exponent == ubyte<-69:
            lexer.index += 1
            if lexer.index < lexer.source.len:
                let sign = byte_at(lexer.source, lexer.index)
                if sign == ubyte<-43 or sign == ubyte<-45:
                    lexer.index += 1
            if lexer.index >= lexer.source.len or not ascii.is_digit(byte_at(lexer.source, lexer.index)):
                return err(Error.invalid_number)
            while lexer.index < lexer.source.len and ascii.is_digit(byte_at(lexer.source, lexer.index)):
                lexer.index += 1

    return ok(slice_token(TokenKind.number_value, lexer.source, start, lexer.index))


pub def next(lexer: ref[Lexer]) -> Result[Token, Error]:
    skip_space(lexer)
    if lexer.index >= lexer.source.len:
        return ok(token(TokenKind.eof))

    let current = byte_at(lexer.source, lexer.index)
    if current == ubyte<-123:
        lexer.index += 1
        return ok(token(TokenKind.left_brace))
    elif current == ubyte<-125:
        lexer.index += 1
        return ok(token(TokenKind.right_brace))
    elif current == ubyte<-91:
        lexer.index += 1
        return ok(token(TokenKind.left_bracket))
    elif current == ubyte<-93:
        lexer.index += 1
        return ok(token(TokenKind.right_bracket))
    elif current == ubyte<-58:
        lexer.index += 1
        return ok(token(TokenKind.colon))
    elif current == ubyte<-44:
        lexer.index += 1
        return ok(token(TokenKind.comma))
    elif current == ubyte<-34:
        lexer.index += 1
        return read_string(lexer)
    elif current == ubyte<-45 or ascii.is_digit(current):
        return read_number(lexer)
    elif match_keyword(lexer, "true"):
        return ok(token(TokenKind.true_value))
    elif match_keyword(lexer, "false"):
        return ok(token(TokenKind.false_value))
    elif match_keyword(lexer, "null"):
        return ok(token(TokenKind.null_value))

    return err(Error.unexpected_char)


pub def append_null(output: ref[string.String]) -> void:
    output.append("null")
    return


pub def append_bool(output: ref[string.String], value: bool) -> void:
    fmt.append_bool(output, value)
    return


pub def append_int(output: ref[string.String], value: int) -> void:
    fmt.append_int(output, value)
    return


pub def append_ptr_uint(output: ref[string.String], value: ptr_uint) -> void:
    fmt.append_ptr_uint(output, value)
    return


def append_hex_nibble(output: ref[string.String], nibble: ubyte) -> void:
    if nibble < ubyte<-10:
        output.push_byte(ubyte<-48 + nibble)
    else:
        output.push_byte(ubyte<-65 + (nibble - ubyte<-10))
    return


pub def append_string(output: ref[string.String], text_value: str) -> void:
    output.append("\"")
    var index: ptr_uint = 0
    while index < text_value.len:
        let byte = byte_at(text_value, index)
        if byte == ubyte<-34:
            output.append("\\\"")
        elif byte == ubyte<-92:
            output.append("\\\\")
        elif byte == ubyte<-8:
            output.append("\\b")
        elif byte == ubyte<-12:
            output.append("\\f")
        elif byte == ubyte<-10:
            output.append("\\n")
        elif byte == ubyte<-13:
            output.append("\\r")
        elif byte == ubyte<-9:
            output.append("\\t")
        elif byte < ubyte<-32:
            output.append("\\u00")
            append_hex_nibble(output, byte >> 4)
            append_hex_nibble(output, byte & ubyte<-15)
        else:
            output.push_byte(byte)
        index += 1
    output.append("\"")
    return
