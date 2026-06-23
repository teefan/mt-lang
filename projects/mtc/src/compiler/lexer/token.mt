## Token struct — the output of the lexer.
##
## Each token records its kind, byte span in the source, and location.
## For identifiers and keywords: `ident` holds the interned IdentId (> 0).
## For non-identifier tokens: `ident` is 0.
## Special literal values (integer, float, string) are recovered from the span.

import compiler.lexer.token_kind as tk

public type IdentId = ptr_uint

public struct Token:
    kind: tk.TokenKind
    start: ptr_uint
    end: ptr_uint
    line: ptr_uint
    col: ptr_uint
    ident: ptr_uint


public function create_ident(
    kind: tk.TokenKind,
    start: ptr_uint,
    end: ptr_uint,
    line: ptr_uint,
    col: ptr_uint,
    ident: ptr_uint,
) -> Token:
    return Token(
        kind = kind,
        start = start,
        end = end,
        line = line,
        col = col,
        ident = ident,
    )


public function create_symbol(
    kind: tk.TokenKind,
    start: ptr_uint,
    end: ptr_uint,
    line: ptr_uint,
    col: ptr_uint,
) -> Token:
    return Token(
        kind = kind,
        start = start,
        end = end,
        line = line,
        col = col,
        ident = 0,
    )


## ── character classification (inline, no FFI) ───────────────────

public function is_alpha(ch: ubyte) -> bool:
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')


public function is_digit(ch: ubyte) -> bool:
    return ch >= '0' and ch <= '9'


public function is_alnum(ch: ubyte) -> bool:
    return is_alpha(ch) or is_digit(ch)


public function is_ident_start(ch: ubyte) -> bool:
    return is_alpha(ch) or ch == '_'


public function is_ident_part(ch: ubyte) -> bool:
    return is_alnum(ch) or ch == '_'


public function is_hex_digit(ch: ubyte) -> bool:
    return is_digit(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F')


public function is_octal_digit(ch: ubyte) -> bool:
    return ch >= '0' and ch <= '7'


public function is_binary_digit(ch: ubyte) -> bool:
    return ch == '0' or ch == '1'


public function is_space(ch: ubyte) -> bool:
    return ch == ' ' or ch == 9


public function is_newline(ch: ubyte) -> bool:
    return ch == 10


public function is_digit_or_uscore(ch: ubyte) -> bool:
    return is_digit(ch) or ch == '_'


public function is_hex_digit_or_uscore(ch: ubyte) -> bool:
    return is_hex_digit(ch) or ch == '_'
