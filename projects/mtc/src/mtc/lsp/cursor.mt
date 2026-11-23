## Cursor utilities — token-at-position resolution over the lexer token stream.
##
## Shared by navigation, rename, signature help, and completion so every
## position-based feature resolves identifiers the same way.  Token-based
## resolution is more precise than raw byte scanning: positions inside string
## literals and comments do not match identifier tokens.
##
## LSP positions are 0-based (line, character), with `character` counted in
## UTF-16 code units; lexer tokens are 1-based (line, column), with `column`
## counted in bytes.  Requests convert the position to a byte offset at the
## boundary (`workspace.position_byte_offset`), so the helpers here take byte
## offsets.

import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.fstring as fstring
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


## The innermost call at the cursor: its callee name and 0-based parameter.
public struct CallContext:
    name: str
    active_parameter: ptr_uint


## The identifier token at the LSP position (0-based line/character).
## A cursor immediately after the last character of an identifier still
## resolves to that identifier, matching editor conventions.
public function identifier_at(source: str, line: ptr_uint, character: ptr_uint) -> Option[CursorToken]:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()
    return identifier_at_in(tokens.as_span(), source, line, character)


## `identifier_at` over an existing token stream (the workspace's cached
## document tokens), so a request does not re-lex the file per lookup.
public function identifier_at_in(tokens: span[token_mod.Token], source: str, line: ptr_uint, character: ptr_uint) -> Option[CursorToken]:
    let target_line = line + 1
    let target_col = character + 1

    # Pass 1: exact containment [column, column + len).
    var ti: ptr_uint = 0
    while ti < tokens.len:
        let tok = unsafe: read(tokens.data + ti)
        if tok.kind == tk.TokenKind.identifier and tok.line == target_line:
            let len = tok.end_offset - tok.start_offset
            if target_col >= tok.column and target_col < tok.column + len:
                return Option[CursorToken].some(value = cursor_token(source, tok))
        ti += 1

    # Pass 2: end-inclusive — cursor sitting right after the identifier.
    ti = 0
    while ti < tokens.len:
        let tok = unsafe: read(tokens.data + ti)
        if tok.kind == tk.TokenKind.identifier and tok.line == target_line:
            let len = tok.end_offset - tok.start_offset
            if target_col == tok.column + len:
                return Option[CursorToken].some(value = cursor_token(source, tok))
        ti += 1

    return Option[CursorToken].none


## `interpolation_identifier_at_in` over an existing token stream.
public function interpolation_identifier_at_in(tokens: span[token_mod.Token], source: str, line: ptr_uint, character: ptr_uint) -> Option[CursorToken]:
    match interpolation_token_at_in(tokens, source, line, character):
        Option.some as tok:
            if tok.value.kind != tk.TokenKind.identifier:
                return Option[CursorToken].none
            let length = tok.value.end_offset - tok.value.start_offset
            return Option[CursorToken].some(value = CursorToken(
                text = source.slice(tok.value.start_offset, length),
                line = tok.value.line,
                column = tok.value.column,
                length = length,
            ))
        Option.none:
            return Option[CursorToken].none


## The token at the LSP position inside an f-string interpolation, whatever its
## kind: a hover ranges the inner token, and the caller decides what to resolve.
## Every f-string token is offered to the splitter, which only answers when the
## position falls inside one of its `#{…}` expressions.
public function interpolation_token_at(source: str, line: ptr_uint, character: ptr_uint) -> Option[fstring.FstringToken]:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()
    return interpolation_token_at_in(tokens.as_span(), source, line, character)


## `interpolation_token_at` over an existing token stream.
public function interpolation_token_at_in(tokens: span[token_mod.Token], source: str, line: ptr_uint, character: ptr_uint) -> Option[fstring.FstringToken]:
    let target_line = line + 1
    let target_col = character + 1
    var ti: ptr_uint = 0
    while ti < tokens.len:
        let tok = unsafe: read(tokens.data + ti)
        if tok.kind == tk.TokenKind.fstring:
            let lexeme = unsafe: token_mod.token_lexeme(tok, source)
            match fstring.interpolation_token_at(tok.start_offset, lexeme, tok.line, tok.column, target_line, target_col):
                Option.some as hit:
                    return Option[fstring.FstringToken].some(value = hit.value)
                Option.none:
                    pass
        ti += 1
    return Option[fstring.FstringToken].none


## The token at the LSP position regardless of kind, excluding the structural
## tokens the host never hovers (newline / indent / dedent / eof).  The host
## returns a hover range for keywords and builtins as well as identifiers.
public function token_at(source: str, line: ptr_uint, character: ptr_uint) -> Option[CursorToken]:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()
    return token_at_in(tokens.as_span(), source, line, character)


## `token_at` over an existing token stream.
public function token_at_in(tokens: span[token_mod.Token], source: str, line: ptr_uint, character: ptr_uint) -> Option[CursorToken]:
    let target_line = line + 1
    let target_col = character + 1

    # Pass 1: exact containment [column, column + len).
    var ti: ptr_uint = 0
    while ti < tokens.len:
        let tok = unsafe: read(tokens.data + ti)
        if hoverable_token_kind(tok.kind) and tok.line == target_line:
            let len = tok.end_offset - tok.start_offset
            if target_col >= tok.column and target_col < tok.column + len:
                return Option[CursorToken].some(value = cursor_token(source, tok))
        ti += 1

    # Pass 2: end-inclusive — cursor sitting right after the token.
    ti = 0
    while ti < tokens.len:
        let tok = unsafe: read(tokens.data + ti)
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


## The host's `find_call_context`: the callee before the innermost open `(` and
## the 0-based active parameter, counted as the top-level commas before the
## cursor.  `character` is the byte column `position_params` passes.
public function call_context_at(source: str, line: ptr_uint, character: ptr_uint) -> Option[CallContext]:
    var current: ptr_uint = 0
    var line_start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == '\n':
            if current == line:
                break
            current += 1
            line_start = i + 1
        i += 1

    var pos = line_start + character
    if pos > source.len:
        pos = source.len

    var depth: ptr_uint = 0
    var active_parameter: ptr_uint = 0
    var paren_pos: ptr_uint = 0
    var found_paren = false
    while pos > 0:
        pos -= 1
        let b = source.byte_at(pos)
        if b == ')' or b == ']':
            depth += 1
        else if b == '[':
            if depth == 0:
                return Option[CallContext].none
            depth -= 1
        else if b == '(':
            if depth == 0:
                paren_pos = pos
                found_paren = true
                break
            depth -= 1
        else if b == ',':
            if depth == 0:
                active_parameter += 1

    if not found_paren:
        return Option[CallContext].none

    # The identifier immediately before the `(`, skipping spaces and tabs.
    var end = paren_pos
    while end > 0 and (source.byte_at(end - 1) == ' ' or source.byte_at(end - 1) == '\t'):
        end -= 1
    if end == 0 or not utils.is_word_byte(source.byte_at(end - 1)):
        return Option[CallContext].none
    var start = end - 1
    while start > 0 and utils.is_word_byte(source.byte_at(start - 1)):
        start -= 1
    return Option[CallContext].some(value = CallContext(
        name = source.slice(start, end - start),
        active_parameter = active_parameter,
    ))


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


## The full dot-receiver path before the cursor as one contiguous slice of the
## line — `ctx.lookup|` gives "ctx.lookup" — or none when the chain contains a
## `[…]` group (the completion path joins skipped segments, so it is not a
## slice).  Used where the receiver is a field chain (`ctx.lookup.set`), which
## the immediate-receiver helpers cannot type.
public function dot_receiver_path_text_at(source: str, line: ptr_uint, character: ptr_uint) -> Option[str]:
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
    let path_end = ptr_uint<-idx

    var left: int = idx - 1
    var start_pos: int = -1
    while true:
        if left < 0 or not utils.is_word_byte(line_text.byte_at(ptr_uint<-left)):
            return Option[str].none
        while left >= 0 and utils.is_word_byte(line_text.byte_at(ptr_uint<-left)):
            left -= 1
        start_pos = left + 1
        if left >= 0 and line_text.byte_at(ptr_uint<-left) == 46:
            left -= 1
            continue
        break
    return Option[str].some(value = line_text.slice(ptr_uint<-start_pos, path_end - ptr_uint<-start_pos))


## True when the cursor's identifier is the member of a dot access (`x.mem|`),
## whatever the receiver shape — `read(p).get|` and `a[0].b|` included.  The
## text-based receiver path resolves only name/field chains; the hover falls
## back to the analyzer's recorded receiver type for the rest.
public function member_dot_at(source: str, line: ptr_uint, character: ptr_uint) -> bool:
    let line_text = source_line(source, line + 1)
    var pos = character
    if pos > line_text.len:
        pos = line_text.len

    while pos > 0 and utils.is_word_byte(line_text.byte_at(pos - 1)):
        pos -= 1
    return pos > 0 and line_text.byte_at(pos - 1) == 46


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


