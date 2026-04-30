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
        return u8<-read(source.data + index)

def skip_space(lexer: ref[Lexer]) -> void:
    while lexer.index < lexer.source.len and ascii.is_space(byte_at(lexer.source, lexer.index)):
        lexer.index += 1
    return

def match_keyword(lexer: ref[Lexer], keyword: str) -> bool:
    if lexer.source.len - lexer.index < keyword.len:
        return false

    var index: usize = 0
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
        if current == u8<-34:
            let stop = lexer.index
            lexer.index += 1
            return ok(slice_token(TokenKind.string_value, lexer.source, start, stop))
        elif current < u8<-32:
            return err(Error.unexpected_char)
        elif current == u8<-92:
            lexer.index += 1
            if lexer.index >= lexer.source.len:
                return err(Error.unexpected_end)

            let escaped = byte_at(lexer.source, lexer.index)
            if escaped == u8<-34 or escaped == u8<-47 or escaped == u8<-92 or escaped == u8<-98 or escaped == u8<-102 or escaped == u8<-110 or escaped == u8<-114 or escaped == u8<-116:
                lexer.index += 1
            elif escaped == u8<-117:
                lexer.index += 1
                var digit_count: usize = 0
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
    if byte_at(lexer.source, lexer.index) == u8<-45:
        lexer.index += 1
        if lexer.index >= lexer.source.len:
            return err(Error.invalid_number)

    let first_digit = byte_at(lexer.source, lexer.index)
    if first_digit == u8<-48:
        lexer.index += 1
    elif first_digit >= u8<-49 and first_digit <= u8<-57:
        while lexer.index < lexer.source.len and ascii.is_digit(byte_at(lexer.source, lexer.index)):
            lexer.index += 1
    else:
        return err(Error.invalid_number)

    if lexer.index < lexer.source.len and byte_at(lexer.source, lexer.index) == u8<-46:
        lexer.index += 1
        if lexer.index >= lexer.source.len or not ascii.is_digit(byte_at(lexer.source, lexer.index)):
            return err(Error.invalid_number)
        while lexer.index < lexer.source.len and ascii.is_digit(byte_at(lexer.source, lexer.index)):
            lexer.index += 1

    if lexer.index < lexer.source.len:
        let exponent = byte_at(lexer.source, lexer.index)
        if exponent == u8<-101 or exponent == u8<-69:
            lexer.index += 1
            if lexer.index < lexer.source.len:
                let sign = byte_at(lexer.source, lexer.index)
                if sign == u8<-43 or sign == u8<-45:
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
    if current == u8<-123:
        lexer.index += 1
        return ok(token(TokenKind.left_brace))
    elif current == u8<-125:
        lexer.index += 1
        return ok(token(TokenKind.right_brace))
    elif current == u8<-91:
        lexer.index += 1
        return ok(token(TokenKind.left_bracket))
    elif current == u8<-93:
        lexer.index += 1
        return ok(token(TokenKind.right_bracket))
    elif current == u8<-58:
        lexer.index += 1
        return ok(token(TokenKind.colon))
    elif current == u8<-44:
        lexer.index += 1
        return ok(token(TokenKind.comma))
    elif current == u8<-34:
        lexer.index += 1
        return read_string(lexer)
    elif current == u8<-45 or ascii.is_digit(current):
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

pub def append_i32(output: ref[string.String], value: i32) -> void:
    fmt.append_i32(output, value)
    return

pub def append_usize(output: ref[string.String], value: usize) -> void:
    fmt.append_usize(output, value)
    return

def append_hex_nibble(output: ref[string.String], nibble: u8) -> void:
    if nibble < u8<-10:
        output.push_byte(u8<-48 + nibble)
    else:
        output.push_byte(u8<-65 + (nibble - u8<-10))
    return

pub def append_string(output: ref[string.String], text_value: str) -> void:
    output.append("\"")
    var index: usize = 0
    while index < text_value.len:
        let byte = byte_at(text_value, index)
        if byte == u8<-34:
            output.append("\\\"")
        elif byte == u8<-92:
            output.append("\\\\")
        elif byte == u8<-8:
            output.append("\\b")
        elif byte == u8<-12:
            output.append("\\f")
        elif byte == u8<-10:
            output.append("\\n")
        elif byte == u8<-13:
            output.append("\\r")
        elif byte == u8<-9:
            output.append("\\t")
        elif byte < u8<-32:
            output.append("\\u00")
            append_hex_nibble(output, byte >> 4)
            append_hex_nibble(output, byte & u8<-15)
        else:
            output.push_byte(byte)
        index += 1
    output.append("\"")
    return
