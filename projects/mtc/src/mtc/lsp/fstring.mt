## Format-string interpolation splitting — shared by the semantic-token scanner
## (one entry per literal run and per re-lexed expression token) and the cursor
## helpers (an identifier inside `#{…}` resolves like one in the surrounding
## code).  The host keeps the split in its lexer's fstring literal parts; the
## self derives it from the token lexeme, so both consumers must agree.

import std.str
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk

## One format string's interpolation: the expression source (the format spec
## split off) and the 0-based index of the expression's first character in the
## lexeme.
public struct FstringPart:
    expr_start: ptr_uint
    source: str
    spec: str
    has_spec: bool

## A token of an interpolation expression, mapped back to document offsets,
## lines and 1-based byte columns.
public struct FstringToken:
    kind: tk.TokenKind
    start_offset: ptr_uint
    end_offset: ptr_uint
    line: ptr_uint
    column: ptr_uint


## The index of the `}` closing the interpolation that starts at `index`, with
## nested braces balanced and nested string literals skipped; the lexeme's end
## when it is unterminated.
public function interpolation_end(lexeme: str, index: ptr_uint) -> ptr_uint:
    var depth: ptr_uint = 1
    var i = index
    while i < lexeme.len:
        let b = lexeme.byte_at(i)
        if b == '"':
            i = skip_string(lexeme, i)
            continue
        if b == '{':
            depth += 1
            i += 1
            continue
        if b == '}':
            depth -= 1
            if depth == 0:
                return i
            i += 1
            continue
        i += 1
    return lexeme.len


## The index just past a nested string literal starting at `index` (its opening
## quote), escapes included.
public function skip_string(lexeme: str, index: ptr_uint) -> ptr_uint:
    var i = index + 1
    while i < lexeme.len:
        let b = lexeme.byte_at(i)
        if b == '"':
            return i + 1
        if b == '\\':
            i += 2
            continue
        i += 1
    return lexeme.len


## Split one interpolation into its expression and format spec (the host's
## `split_format_interpolation_source`: a top-level `:` whose suffix is a format
## spec wins, the last one if several match).
public function split_part(lexeme: str, expr_start: ptr_uint, expr_end: ptr_uint) -> FstringPart:
    let raw = lexeme.slice(expr_start, expr_end - expr_start)
    var depth: ptr_uint = 0
    var spec_index: ptr_uint = 0
    var found_spec = false
    var i: ptr_uint = 0
    while i < raw.len:
        let b = raw.byte_at(i)
        if b == '"':
            i = skip_string(raw, i)
            continue
        if b == '(' or b == '[' or b == '{':
            depth += 1
        else if b == ')' or b == ']' or b == '}':
            if depth > 0:
                depth -= 1
        else if b == ':':
            if depth == 0 and format_spec_suffix(raw.slice(i + 1, raw.len - i - 1)):
                spec_index = i
                found_spec = true
        i += 1
    if found_spec:
        return FstringPart(
            expr_start = expr_start,
            source = raw.slice(0, spec_index),
            spec = raw.slice(spec_index + 1, raw.len - spec_index - 1),
            has_spec = true,
        )
    return FstringPart(expr_start = expr_start, source = raw, spec = "", has_spec = false)


## The host's `format_spec_suffix?`: a trimmed `.digits` or one of the radix
## letters.
public function format_spec_suffix(suffix: str) -> bool:
    let trimmed = suffix.trim_ascii_whitespace()
    if trimmed.len == 0:
        return false
    if trimmed.len == 1:
        let b = trimmed.byte_at(0)
        return b == 'x' or b == 'X' or b == 'o' or b == 'O' or b == 'b' or b == 'B'
    if trimmed.byte_at(0) != '.':
        return false
    var i: ptr_uint = 1
    while i < trimmed.len:
        let b = trimmed.byte_at(i)
        if b < '0' or b > '9':
            return false
        i += 1
    return true


## The interpolation-expression token at the 1-based document position, or none.
## `token_start` is the fstring token's byte offset in `source`; the returned
## offsets are absolute document offsets, so callers can slice `source` without
## keeping the inner expression alive.
public function interpolation_token_at(
    token_start: ptr_uint,
    lexeme: str,
    token_line: ptr_uint,
    token_column: ptr_uint,
    target_line: ptr_uint,
    target_char: ptr_uint,
) -> Option[FstringToken]:
    var i: ptr_uint = 2
    while i < lexeme.len:
        let b = lexeme.byte_at(i)
        if b == '"':
            break
        if b == '#' and i + 1 < lexeme.len and lexeme.byte_at(i + 1) == '{':
            let expr_start = i + 2
            let expr_end = interpolation_end(lexeme, expr_start)
            if expr_end < expr_start:
                break
            let part = split_part(lexeme, expr_start, expr_end)
            match part_token_at(token_start, part, token_line, token_column, target_line, target_char):
                Option.some as hit:
                    return Option[FstringToken].some(value = hit.value)
                Option.none:
                    pass
            i = expr_end + 1
            continue
        if b == '\\' and i + 1 < lexeme.len:
            i += 2
            continue
        i += 1
    return Option[FstringToken].none


## The token of one interpolation part at the document position.
function part_token_at(
    token_start: ptr_uint,
    part: FstringPart,
    token_line: ptr_uint,
    token_column: ptr_uint,
    target_line: ptr_uint,
    target_char: ptr_uint,
) -> Option[FstringToken]:
    if part.source.len == 0:
        return Option[FstringToken].none
    var diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: diags.release()
    var sub_tokens = lexer_mod.lex_reporting(part.source, ref_of(diags))
    defer: sub_tokens.release()
    var ti: ptr_uint = 0
    while ti < sub_tokens.len():
        let tp = sub_tokens.get(ti) else:
            break
        let tok = unsafe: read(tp)
        if is_trivia(tok.kind):
            ti += 1
            continue
        let adjusted_line = token_line + tok.line - 1
        var adjusted_column = tok.column
        if tok.line == 1:
            adjusted_column = token_column + part.expr_start + tok.column - 1
        let length = tok.end_offset - tok.start_offset
        if adjusted_line == target_line and target_char >= adjusted_column and
           target_char < adjusted_column + length:
            return Option[FstringToken].some(value = FstringToken(
                kind = tok.kind,
                start_offset = token_start + part.expr_start + tok.start_offset,
                end_offset = token_start + part.expr_start + tok.end_offset,
                line = adjusted_line,
                column = adjusted_column,
            ))
        ti += 1
    return Option[FstringToken].none


function is_trivia(kind: tk.TokenKind) -> bool:
    return kind == tk.TokenKind.newline or kind == tk.TokenKind.indent or
        kind == tk.TokenKind.dedent or kind == tk.TokenKind.eof
