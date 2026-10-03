## Cursor utilities — token-at-position resolution over the lexer token stream.
##
## Shared by navigation, rename, signature help, and completion so every
## position-based feature resolves identifiers the same way.  Token-based
## resolution is more precise than raw byte scanning: positions inside string
## literals and comments do not match identifier tokens.
##
## LSP positions are 0-based (line, character); lexer tokens are 1-based
## (line, column).  Character offsets are treated as byte offsets, which is
## exact for ASCII sources and approximate for multi-byte UTF-8.

import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.utils as utils
import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk


## An identifier token under the cursor.  `text` is a view into the caller's
## source buffer; `line`/`column` are 1-based lexer coordinates.
public struct CursorToken:
    text: str
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint


## The identifier token at the LSP position (0-based line/character).
## A cursor immediately after the last character of an identifier still
## resolves to that identifier, matching editor conventions.
public function identifier_at(source: str, line: ptr_uint, character: ptr_uint) -> Option[CursorToken]:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

    let target_line = line + 1
    let target_col = character + 1

    # Pass 1: exact containment [column, column + len).
    var ti: ptr_uint = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let tok = unsafe: read(tp)
        if tok.kind == tk.TokenKind.identifier and tok.line == target_line:
            let len = tok.end_offset - tok.start_offset
            if target_col >= tok.column and target_col < tok.column + len:
                return Option[CursorToken].some(value = cursor_token(source, tok))
        ti += 1

    # Pass 2: end-inclusive — cursor sitting right after the identifier.
    ti = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let tok = unsafe: read(tp)
        if tok.kind == tk.TokenKind.identifier and tok.line == target_line:
            let len = tok.end_offset - tok.start_offset
            if target_col == tok.column + len:
                return Option[CursorToken].some(value = cursor_token(source, tok))
        ti += 1

    return Option[CursorToken].none


## The token at the LSP position regardless of kind, excluding the structural
## tokens the host never hovers (newline / indent / dedent / eof).  The host
## returns a hover range for keywords and builtins as well as identifiers.
public function token_at(source: str, line: ptr_uint, character: ptr_uint) -> Option[CursorToken]:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

    let target_line = line + 1
    let target_col = character + 1

    # Pass 1: exact containment [column, column + len).
    var ti: ptr_uint = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let tok = unsafe: read(tp)
        if hoverable_token_kind(tok.kind) and tok.line == target_line:
            let len = tok.end_offset - tok.start_offset
            if target_col >= tok.column and target_col < tok.column + len:
                return Option[CursorToken].some(value = cursor_token(source, tok))
        ti += 1

    # Pass 2: end-inclusive — cursor sitting right after the token.
    ti = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let tok = unsafe: read(tp)
        if hoverable_token_kind(tok.kind) and tok.line == target_line:
            let len = tok.end_offset - tok.start_offset
            if target_col == tok.column + len:
                return Option[CursorToken].some(value = cursor_token(source, tok))
        ti += 1

    return Option[CursorToken].none


function hoverable_token_kind(kind: tk.TokenKind) -> bool:
    if kind == tk.TokenKind.newline or kind == tk.TokenKind.indent or kind == tk.TokenKind.dedent or kind == tk.TokenKind.eof:
        return false
    return true


## The callee name of the innermost call expression enclosing the LSP
## position: `foo(a, |)` resolves to "foo", `mod.method(|)` to "method",
## and `name[T](|)` to "name" (specialization brackets are skipped).
public function call_name_at(source: str, line: ptr_uint, character: ptr_uint) -> Option[str]:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

    let target_line = line + 1
    let target_col = character + 1

    # Stack of enclosing-call callee names ("" when the callee is not a
    # plain identifier, e.g. `(f())(x)`).
    var callee_stack = vec.Vec[str].create()
    defer: callee_stack.release()

    var ti: ptr_uint = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let tok = unsafe: read(tp)
        if tok.kind == tk.TokenKind.eof:
            break
        # Stop once the token starts at or beyond the cursor.
        if tok.line > target_line or (tok.line == target_line and tok.column >= target_col):
            break

        if tok.kind == tk.TokenKind.lparen:
            callee_stack.push(callee_before(source, ref_of(tokens), ti))
        else if tok.kind == tk.TokenKind.rparen:
            if callee_stack.len() > 0:
                let popped = callee_stack.pop()
                let _p = popped
        ti += 1

    let top = callee_stack.last() else:
        return Option[str].none
    let name = unsafe: read(top)
    if name.len == 0:
        return Option[str].none
    return Option[str].some(value = name)


## The callee identifier immediately before the lparen at `lparen_index`,
## skipping a specialization bracket group (`name[...](`) when present.
function callee_before(source: str, tokens: ref[vec.Vec[token_mod.Token]], lparen_index: ptr_uint) -> str:
    if lparen_index == 0:
        return ""

    var prev_index = lparen_index - 1
    var prev: token_mod.Token
    unsafe:
        let pp = tokens.get(prev_index) else:
            return ""
        prev = read(pp)

    # Skip `[...]` between the callee name and the call parens.
    if prev.kind == tk.TokenKind.rbracket:
        var depth: int = 1
        while prev_index > 0 and depth > 0:
            prev_index -= 1
            unsafe:
                let bp = tokens.get(prev_index) else:
                    return ""
                prev = read(bp)
            if prev.kind == tk.TokenKind.rbracket:
                depth += 1
            else if prev.kind == tk.TokenKind.lbracket:
                depth -= 1
        if depth != 0 or prev_index == 0:
            return ""
        prev_index -= 1
        unsafe:
            let np = tokens.get(prev_index) else:
                return ""
            prev = read(np)

    if prev.kind == tk.TokenKind.identifier:
        return token_text(source, prev)
    return ""


function cursor_token(source: str, tok: token_mod.Token) -> CursorToken:
    return CursorToken(
        text = token_text(source, tok),
        line = tok.line,
        column = tok.column,
        length = tok.end_offset - tok.start_offset
    )


## The lexeme of a token as a view into the source buffer.
public function token_text(source: str, tok: token_mod.Token) -> str:
    if tok.start_offset >= source.len or tok.end_offset > source.len or tok.end_offset <= tok.start_offset:
        return ""
    return unsafe: str(data = source.data + tok.start_offset, len = tok.end_offset - tok.start_offset)


## All identifier tokens whose lexeme equals `name`, in source order.  Token
## matching (rather than raw text scanning) means occurrences inside string
## literals and comments are excluded.
public function identifier_occurrences(source: str, name: str) -> vec.Vec[CursorToken]:
    var result = vec.Vec[CursorToken].create()
    if name.len == 0:
        return result

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

    var ti: ptr_uint = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let tok = unsafe: read(tp)
        if tok.kind == tk.TokenKind.identifier:
            if token_text(source, tok).equal(name):
                result.push(cursor_token(source, tok))
        ti += 1
    return result


## The identifier immediately before a `.` that precedes the cursor's current
## word (`vec.pu|` resolves to "vec"), or none when the cursor is not in a
## dot-member context.
public function dot_receiver_at(source: str, line: ptr_uint, character: ptr_uint) -> Option[str]:
    let line_text = source_line(source, line + 1)
    var pos = character
    if pos > line_text.len:
        pos = line_text.len

    # Skip back over the word prefix being typed.
    while pos > 0 and utils.is_word_byte(line_text.byte_at(pos - 1)):
        pos -= 1

    if pos == 0 or line_text.byte_at(pos - 1) != 46:
        return Option[str].none
    pos -= 1

    var start = pos
    while start > 0 and utils.is_word_byte(line_text.byte_at(start - 1)):
        start -= 1
    if start == pos:
        return Option[str].none
    return Option[str].some(value = line_text.slice(start, pos - start))


## The receiver of a *type* member access at the cursor: `Type.method`,
## `Type[T].method`, or `alias.Type.method`.  The name is the type (or value)
## identifier before the `.`, with any `[…]` argument list on the receiver
## skipped; the alias is set when the access is `alias.`-qualified.  The caller
## decides whether the name is a value (a method on a value) or a type (a static
## method), exactly as the host's receiver resolution does.
public struct TypeReceiver:
    name: str
    module_alias: str


public function type_receiver_at(source: str, line: ptr_uint, character: ptr_uint) -> Option[TypeReceiver]:
    let line_text = source_line(source, line + 1)
    var pos = character
    if pos > line_text.len:
        pos = line_text.len

    # Skip back over the identifier being hovered.
    while pos > 0 and utils.is_word_byte(line_text.byte_at(pos - 1)):
        pos -= 1
    if pos == 0 or line_text.byte_at(pos - 1) != '.':
        return Option[TypeReceiver].none
    pos -= 1

    # A receiver argument list (`Type[T]`) sits between the name and the dot.
    if pos > 0 and line_text.byte_at(pos - 1) == ']':
        var depth = 1
        pos -= 1
        while pos > 0 and depth > 0:
            let bracket_byte = line_text.byte_at(pos - 1)
            if bracket_byte == ']':
                depth += 1
            else if bracket_byte == '[':
                depth -= 1
            pos -= 1
        if depth != 0:
            return Option[TypeReceiver].none
        while pos > 0 and (line_text.byte_at(pos - 1) == ' ' or line_text.byte_at(pos - 1) == '\t'):
            pos -= 1

    let name_end = pos
    while pos > 0 and utils.is_word_byte(line_text.byte_at(pos - 1)):
        pos -= 1
    if pos == name_end:
        return Option[TypeReceiver].none
    let name = line_text.slice(pos, name_end - pos)

    var module_alias: str = ""
    if pos > 0 and line_text.byte_at(pos - 1) == '.':
        var alias_end = pos - 1
        while alias_end > 0 and utils.is_word_byte(line_text.byte_at(alias_end - 1)):
            alias_end -= 1
        if alias_end < pos - 1:
            module_alias = line_text.slice(alias_end, pos - 1 - alias_end)
    return Option[TypeReceiver].some(value = TypeReceiver(name = name, module_alias = module_alias))


## The full dot-receiver path at the cursor — the host's
## `find_dot_receiver_path`: every identifier segment before the hovered dot,
## joined by `.`, with `[…]` groups skipped (`a[0].b` gives `a.b`).  Unlike
## `dot_receiver_at` (which the hover/definition endpoints use and which
## requires a plain identifier), any dot context yields a path here — digit
## segments included — because the host falls back to its method table for a
## receiver it cannot resolve, so every dot position must answer that fallback.
public function member_receiver_path_at(source: str, line: ptr_uint, character: ptr_uint) -> Option[str]:
    let line_text = source_line(source, line + 1)
    var idx: int = int<-character
    if idx > int<-line_text.len:
        idx = int<-line_text.len
    idx -= 1
    # Walk back past the hovered identifier to its dot.
    while idx >= 0 and utils.is_word_byte(line_text.byte_at(ptr_uint<-idx)):
        idx -= 1
    if idx < 0 or line_text.byte_at(ptr_uint<-idx) != 46:
        return Option[str].none

    var segments = vec.Vec[str].create()
    defer: segments.release()
    var left: int = idx - 1
    while true:
        # Skip a `[…]` group and its contents.
        if left >= 0 and line_text.byte_at(ptr_uint<-left) == 93:
            var depth: int = 1
            left -= 1
            while left >= 0 and depth > 0:
                let b = line_text.byte_at(ptr_uint<-left)
                if b == 93:
                    depth += 1
                else if b == 91:
                    depth -= 1
                if depth > 0 and left > 0:
                    left -= 1
            left -= 1

        # Walk back over identifier characters.
        var start: int = left
        while start >= 0 and utils.is_word_byte(line_text.byte_at(ptr_uint<-start)):
            start -= 1
        if start < left:
            segments.push(line_text.slice(ptr_uint<-(start + 1), ptr_uint<-(left - start)))

        if start >= 0 and line_text.byte_at(ptr_uint<-start) == 46:
            left = start - 1
            continue
        break

    if segments.len() == 0:
        return Option[str].none
    var path = string.String.create()
    # Segments were collected right-to-left; join them in source order.
    var si: ptr_uint = segments.len()
    while si > 0:
        si -= 1
        if si + 1 < segments.len():
            path.push_byte(46)
        let seg = segments.get(si) else:
            break
        path.append(unsafe: read(seg))
    return Option[str].some(value = path.as_str())


## The text of 1-based line `line_no` in `source`, without the newline.
public function source_line(source: str, line_no: ptr_uint) -> str:
    if line_no == 0:
        return ""
    var current: ptr_uint = 1
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == '\n':
            if current == line_no:
                return source.slice(start, i - start)
            current += 1
            start = i + 1
        i += 1
    if current == line_no:
        return source.slice(start, source.len - start)
    return ""


## The 0-based character offset of the first whole-token occurrence of `name`
## in `line_text`, or none.  Whole-token matching prevents "arg" from
## matching inside "argv".
public function token_start_in_line(line_text: str, name: str) -> Option[ptr_uint]:
    if name.len == 0 or name.len > line_text.len:
        return Option[ptr_uint].none
    let limit = line_text.len - name.len
    var n: ptr_uint = 0
    while n <= limit:
        var matched = true
        var mi: ptr_uint = 0
        while mi < name.len:
            if line_text.byte_at(n + mi) != name.byte_at(mi):
                matched = false
                break
            mi += 1
        if matched:
            var before_ok = true
            if n > 0:
                before_ok = not utils.is_word_byte(line_text.byte_at(n - 1))
            var after_ok = true
            let after = n + name.len
            if after < line_text.len:
                after_ok = not utils.is_word_byte(line_text.byte_at(after))
            if before_ok and after_ok:
                return Option[ptr_uint].some(value = n)
        n += 1
    return Option[ptr_uint].none


