## Self-hosted parser — transforms a token stream into an AST.
##
## Mirrors the Ruby parser (lib/milk_tea/core/parser.rb) architecture,
## algorithms, and AST node structure.
##
## Loop guard: every while-loop increments a step counter; at 100,000 steps
## the parser aborts to prevent infinite loops during development.

import std.map as map_mod
import std.str
import std.string as string
import std.vec as vec
import std.mem.heap as heap_mod

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.lexer.lexer as lexer
import mtc.parser.token_stream as ts
import mtc.parser.ast as ast
import mtc.parser.state as pstate
import mtc.parser.literal_parsing as lparse


## Diagnostic with position info — re-exported from parser/state.mt.

# =============================================================================
#  Parser state (now in parser/state.mt)
# =============================================================================

function step(s: ref[pstate.ParserState]) -> void:
    pstate.step(s)

function peek(s: ref[pstate.ParserState]) -> ptr[token_mod.Token]?:
    return pstate.peek(s)

function advance(s: ref[pstate.ParserState]) -> void:
    pstate.advance(s)

function previous(s: ref[pstate.ParserState]) -> ptr[token_mod.Token]?:
    return pstate.previous(s)

function previous_token(s: ref[pstate.ParserState]) -> ptr[token_mod.Token]:
    return pstate.previous_token(s)

function check(s: ref[pstate.ParserState], kind: tk.TokenKind) -> bool:
    return pstate.check(s, kind)

function match_kind(s: ref[pstate.ParserState], kind: tk.TokenKind) -> bool:
    return pstate.match_kind(s, kind)

function consume(s: ref[pstate.ParserState], kind: tk.TokenKind, msg: cstr) -> void:
    pstate.consume(s, kind, msg)

function parser_error_naked(s: ref[pstate.ParserState], msg: cstr) -> void:
    pstate.parser_error_naked(s, msg)

function parser_error_at(s: ref[pstate.ParserState], msg: cstr, line: ptr_uint, col: ptr_uint, lexeme: str, kind: str) -> void:
    pstate.parser_error_at(s, msg, line, col, lexeme, kind)


function consume_or_sync(s: ref[pstate.ParserState], kind: tk.TokenKind, msg: cstr) -> void:
    if check(s, kind):
        advance(s)
        return
    let tok = peek(s) else:
        parser_error_naked(s, msg)
        return
    unsafe:
        let t = read(tok)
        let lexeme = token_mod.token_lexeme(t, s.source)
        let kn = token_mod.kind_name(t.kind)
        parser_error_at(s, msg, t.line, t.column, lexeme, kn)
    synchronize_to_statement_boundary(s)


function skip_to_sync_point(s: ref[pstate.ParserState]) -> void:
    var depth: int = 0
    if not eof(s):
        advance(s)

    while not eof(s):
        step(s)
        if check(s, tk.TokenKind.lparen) or check(s, tk.TokenKind.lbracket):
            depth += 1
        else if check(s, tk.TokenKind.rparen) or check(s, tk.TokenKind.rbracket):
            if depth > 0:
                depth -= 1
        else if depth == 0 and check(s, tk.TokenKind.newline):
            advance(s)
            return
        else if depth == 0 and check(s, tk.TokenKind.dedent):
            return
        else if depth == 0 and is_declaration_start(s):
            return
        advance(s)


function synchronize_to_statement_boundary(s: ref[pstate.ParserState]) -> void:
    while not eof(s):
        if check(s, tk.TokenKind.indent):
            recover_statement_block_body(s)
            continue
        if check(s, tk.TokenKind.dedent):
            return
        if check(s, tk.TokenKind.newline):
            advance(s)
            if check(s, tk.TokenKind.indent):
                recover_statement_block_body(s)
            return
        advance(s)


function recover_statement_block_body(s: ref[pstate.ParserState]) -> void:
    if check(s, tk.TokenKind.indent):
        advance(s)
    skip_newlines(s)
    while not eof(s) and not check(s, tk.TokenKind.dedent):
        step(s)
        if check(s, tk.TokenKind.newline):
            advance(s)
            skip_newlines(s)
            continue
        parse_statement(s)
        skip_newlines(s)
    if check(s, tk.TokenKind.dedent):
        advance(s)


function synchronize_to_match_arm_boundary(s: ref[pstate.ParserState]) -> void:
    while not eof(s):
        if check(s, tk.TokenKind.dedent):
            return
        if check(s, tk.TokenKind.newline):
            advance(s)
            if check(s, tk.TokenKind.indent):
                recover_match_arm_block(s)
            return
        advance(s)


function recover_match_arm_block(s: ref[pstate.ParserState]) -> void:
    if check(s, tk.TokenKind.indent):
        advance(s)
    skip_newlines(s)
    while not eof(s) and not check(s, tk.TokenKind.dedent):
        step(s)
        if check(s, tk.TokenKind.newline):
            advance(s)
            skip_newlines(s)
            continue
        var recover_arms = vec.Vec[ast.MatchArm].create()
        parse_match_arm_into(s, ref_of(recover_arms))
        skip_newlines(s)
    if check(s, tk.TokenKind.dedent):
        advance(s)


function synchronize_to_top_level_boundary(s: ref[pstate.ParserState]) -> void:
    var seen_newline = false
    while not eof(s):
        if check(s, tk.TokenKind.newline):
            seen_newline = true
            advance(s)
            continue
        if check(s, tk.TokenKind.indent) or check(s, tk.TokenKind.dedent):
            advance(s)
            continue
        if seen_newline and (is_declaration_start(s) or check(s, tk.TokenKind.tk_import)):
            let tok_ptr = peek(s) else:
                return
            unsafe:
                if read(tok_ptr).column <= 1:
                    return
        advance(s)

function is_declaration_start(s: ref[pstate.ParserState]) -> bool:
    return (
        check(s, tk.TokenKind.tk_const) or check(s, tk.TokenKind.tk_var)
        or check(s, tk.TokenKind.tk_function) or check(s, tk.TokenKind.tk_public)
        or check(s, tk.TokenKind.tk_struct) or check(s, tk.TokenKind.tk_union)
        or check(s, tk.TokenKind.tk_enum) or check(s, tk.TokenKind.tk_flags)
        or check(s, tk.TokenKind.tk_type) or check(s, tk.TokenKind.tk_variant)
        or check(s, tk.TokenKind.tk_interface) or check(s, tk.TokenKind.tk_opaque)
        or check(s, tk.TokenKind.tk_extending) or check(s, tk.TokenKind.tk_async)
        or check(s, tk.TokenKind.tk_external) or check(s, tk.TokenKind.tk_foreign)
        or check(s, tk.TokenKind.tk_static_assert) or check(s, tk.TokenKind.tk_event)
        or check(s, tk.TokenKind.tk_when) or check(s, tk.TokenKind.tk_attribute)
        or check(s, tk.TokenKind.tk_import) or check(s, tk.TokenKind.tk_editable)
        or check(s, tk.TokenKind.tk_static)
    )

function eof(s: ref[pstate.ParserState]) -> bool:
    return ts.eof(ref_of(s.stream))

function skip_newlines(s: ref[pstate.ParserState]) -> void:
    ts.skip_newlines(ref_of(s.stream))

function check_name(s: ref[pstate.ParserState]) -> bool:
    return check(s, tk.TokenKind.identifier)

function match_name(s: ref[pstate.ParserState]) -> bool:
    if check_name(s):
        advance(s)
        return true
    return false

function consume_name(s: ref[pstate.ParserState], msg: cstr) -> void:
    let tok = peek(s) else:
        parser_error_naked(s, msg)
        return
    unsafe:
        let t = read(tok)
        if t.kind != tk.TokenKind.identifier or is_keyword_token(t):
            let lexeme = token_mod.token_lexeme(t, s.source)
            let kn = token_mod.kind_name(t.kind)
            parser_error_at(s, msg, t.line, t.column, lexeme, kn)
            advance(s)
            return
    advance(s)

function consume_name_allowing_keywords(s: ref[pstate.ParserState], msg: cstr) -> void:
    if check_name(s):
        advance(s)
        return
    let tok = peek(s) else:
        parser_error_naked(s, msg)
        skip_to_sync_point(s)
        return
    unsafe:
        let t = read(tok)
        if is_keyword_token(t):
            advance(s)
            return
    unsafe:
        let t = read(tok)
        let lexeme = token_mod.token_lexeme(t, s.source)
        let kn = token_mod.kind_name(t.kind)
        parser_error_at(s, msg, t.line, t.column, lexeme, kn)
        skip_to_sync_point(s)

function consume_end_of_statement(s: ref[pstate.ParserState]) -> void:
    if s.in_inline_block_body:
        return
    if not check(s, tk.TokenKind.newline):
        parser_error_naked(s, c"expected end of statement")
        return
    advance(s)

function is_keyword_token(tok: token_mod.Token) -> bool:
    # Keyword token kinds all have the tk_ prefix (values 51-122).
    # Tokens that are truly identifiers have TokenKind.identifier.
    return tok.kind >= tk.TokenKind.tk_align_of

function previous_lexeme(s: ref[pstate.ParserState]) -> str:
    let tok = previous(s) else:
        return ""
    unsafe:
        let t = read(tok)
        return token_mod.token_lexeme(t, s.source)


# =============================================================================
#  Name disambiguation infrastructure
# =============================================================================

const BUILTIN_TYPE_NAME_COUNT: ptr_uint = 46
const BUILTIN_TYPE_NAMES: array[str, 46] = array[str, 46](
    "bool", "byte", "ubyte", "char", "short", "ushort", "int", "uint",
    "long", "ulong", "ptr_int", "ptr_uint", "float", "double", "void",
    "str", "cstr", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4",
    "mat3", "mat4", "quat", "ptr", "const_ptr", "own", "ref", "span", "array",
    "str_buffer", "atomic", "Task", "Option", "Result", "SoA",
    "struct_handle", "field_handle", "callable_handle", "attribute_handle",
    "member_handle", "type", "EventError", "Subscription"
)

function builtin_type_names() -> span[str]:
    return BUILTIN_TYPE_NAMES.as_span()


function is_builtin_type_name(name: str) -> bool:
    let names = builtin_type_names()
    var i: ptr_uint = 0
    while i < names.len:
        if unsafe: read(names.data + i) == name:
            return true
        i += 1
    return false


function known_type_like_name(s: ref[pstate.ParserState], name: str) -> bool:
    if s.known_type_names.contains(name):
        return true
    if s.known_import_aliases.contains(name):
        return true
    var ci: ptr_uint = 0
    while ci < s.current_type_param_names.len():
        let tp_ptr = s.current_type_param_names.get(ci) else:
            break
        if unsafe: read(tp_ptr) == name:
            return true
        ci += 1
    return false


function check_next(s: ref[pstate.ParserState], kind: tk.TokenKind) -> bool:
    return ts.check_next(ref_of(s.stream), kind)


function type_name_token_check(tok_ptr: ptr[token_mod.Token]?) -> bool:
    if tok_ptr == null:
        return false
    unsafe:
        return read(tok_ptr).kind == tk.TokenKind.identifier


function keyword_token_check(tok_ptr: ptr[token_mod.Token]?) -> bool:
    if tok_ptr == null:
        return false
    unsafe:
        return is_keyword_token(read(tok_ptr))


function block_expression(expr: ptr[ast.Expr]?) -> bool:
    if expr == null:
        return false
    unsafe:
        let e = read(expr)
        return e is ast.Expr.expr_proc or e is ast.Expr.expr_match


function matching_rbracket_index(s: ref[pstate.ParserState], start_index: ptr_uint) -> Option[ptr_uint]:
    var depth: int = 0
    var index = start_index
    let token_count = s.stream.tokens.len()
    while index < token_count:
        let tok_opt = s.stream.tokens.get(index) else:
            break
        unsafe:
            let kind = read(tok_opt).kind
            if kind == tk.TokenKind.lbracket:
                depth += 1
            else if kind == tk.TokenKind.rbracket:
                depth -= 1
                if depth == 0:
                    return Option[ptr_uint].some(value = index)
        index += 1
    return Option[ptr_uint].none


# =============================================================================
#  Name seeding — pre-scans tokens to populate known-name maps
# =============================================================================

function seed_known_names(s: ref[pstate.ParserState]) -> void:
    let names = builtin_type_names()
    var ni: ptr_uint = 0
    while ni < names.len:
        let name = unsafe: read(names.data + ni)
        s.known_type_names.set(name, true)
        ni += 1

    var depth: int = 0
    var index: ptr_uint = 0
    let token_count = s.stream.tokens.len()
    while index < token_count:
        let tok_opt = s.stream.tokens.get(index) else:
            break
        var kind: tk.TokenKind
        unsafe:
            kind = read(tok_opt).kind

        if kind == tk.TokenKind.indent:
            depth += 1
        else if kind == tk.TokenKind.dedent:
            if depth > 0:
                depth -= 1
        else if kind == tk.TokenKind.tk_import and depth == 0:
            index = seed_import_alias(s, index + 1)
            continue
        else if kind == tk.TokenKind.tk_function and depth == 0:
            let name_opt = s.stream.tokens.get(index + 1)
            let tp_opt = s.stream.tokens.get(index + 2)
            if name_opt != null and tp_opt != null:
                unsafe:
                    if read(name_opt).kind == tk.TokenKind.identifier and read(tp_opt).kind == tk.TokenKind.lbracket:
                        s.known_generic_callable_names.set(token_mod.token_lexeme(read(name_opt), s.source), true)
                        index += 1
                        continue
        else if kind == tk.TokenKind.tk_async and depth == 0:
            let next_opt = s.stream.tokens.get(index + 1)
            if next_opt != null:
                unsafe:
                    if read(next_opt).kind == tk.TokenKind.tk_function:
                        let name_opt = s.stream.tokens.get(index + 2)
                        let tp_opt = s.stream.tokens.get(index + 3)
                        if name_opt != null and tp_opt != null:
                            if read(name_opt).kind == tk.TokenKind.identifier and read(tp_opt).kind == tk.TokenKind.lbracket:
                                s.known_generic_callable_names.set(token_mod.token_lexeme(read(name_opt), s.source), true)
                                index += 3
                                continue
        else if kind == tk.TokenKind.tk_foreign and depth == 0:
            let next_opt = s.stream.tokens.get(index + 1)
            if next_opt != null:
                unsafe:
                    if read(next_opt).kind == tk.TokenKind.tk_function:
                        let name_opt = s.stream.tokens.get(index + 2)
                        let tp_opt = s.stream.tokens.get(index + 3)
                        if name_opt != null and tp_opt != null:
                            if read(name_opt).kind == tk.TokenKind.identifier and read(tp_opt).kind == tk.TokenKind.lbracket:
                                s.known_generic_callable_names.set(token_mod.token_lexeme(read(name_opt), s.source), true)
                                index += 3
                                continue
        else if depth == 0 and (
            kind == tk.TokenKind.tk_struct or kind == tk.TokenKind.tk_union
            or kind == tk.TokenKind.tk_enum or kind == tk.TokenKind.tk_flags
            or kind == tk.TokenKind.tk_opaque or kind == tk.TokenKind.tk_type
            or kind == tk.TokenKind.tk_variant
        ):
            let name_opt = s.stream.tokens.get(index + 1)
            if name_opt != null:
                unsafe:
                    if read(name_opt).kind == tk.TokenKind.identifier:
                        s.known_type_names.set(token_mod.token_lexeme(read(name_opt), s.source), true)

        index += 1


function seed_import_alias(s: ref[pstate.ParserState], start_index: ptr_uint) -> ptr_uint:
    var cursor = start_index
    var last_part: Option[str] = Option[str].none
    let token_count = s.stream.tokens.len()
    while cursor < token_count:
        let tok_opt = s.stream.tokens.get(cursor) else:
            break
        unsafe:
            let t = read(tok_opt)
            if t.kind == tk.TokenKind.newline:
                break
            if t.kind == tk.TokenKind.tk_as:
                let alias_opt = s.stream.tokens.get(cursor + 1)
                if alias_opt != null and (unsafe: read(alias_opt).kind) == tk.TokenKind.identifier:
                    unsafe:
                        s.known_import_aliases.set(token_mod.token_lexeme(read(alias_opt), s.source), true)
                return cursor
            if t.kind == tk.TokenKind.identifier:
                unsafe:
                    last_part = Option[str].some(value = token_mod.token_lexeme(t, s.source))
        cursor += 1
    match last_part:
        Option.some as lp:
            s.known_import_aliases.set(lp.value, true)
        Option.none:
            pass
    return cursor


# =============================================================================
#  Generic comma-separated list helper
# =============================================================================

function parse_comma_separated_until(s: ref[pstate.ParserState], closing_type: tk.TokenKind,
                                      parse_item: proc(session: ref[pstate.ParserState]) -> void) -> void:
    if check(s, closing_type):
        return
    while true:
        step(s)
        parse_item(s)
        if not match_kind(s, tk.TokenKind.comma):
            break
        if check(s, closing_type):
            break

# =============================================================================
#  Literal value extraction (now in parser/literal_parsing.mt)
# =============================================================================

function parse_int_literal(lexeme: str) -> long:
    return lparse.parse_int_literal(lexeme)


function parse_float_literal(lexeme: str) -> double:
    return lparse.parse_float_literal(lexeme)


function parse_string_content(lexeme: str, is_cstring: bool) -> str:
    return lparse.parse_string_content(lexeme, is_cstring)


function parse_char_value(lexeme: str) -> ubyte:
    return lparse.parse_char_value(lexeme)


function decode_string_escape(ch: ubyte) -> ubyte:
    return lparse.decode_string_escape(ch)


function is_format_heredoc(lexeme: str) -> bool:
    return lparse.is_format_heredoc(lexeme)


function normalize_format_heredoc(lexeme: str) -> str:
    return lparse.normalize_format_heredoc(lexeme)


## Parse an `f"..."` (or `f<<-TAG` heredoc) format-string token into an
## `expr_format_string` with alternating text and interpolation parts.  Mirrors
## the Ruby lexer's part-splitting (which the self-host token model cannot carry)
## plus the parser's re-parse of each `#{expr}` and format spec.
function parse_format_string_expr(s: ref[pstate.ParserState], lexeme: str, line: ptr_uint, column: ptr_uint) -> own[ast.Expr]:
    var content: str = ""
    var decode_escapes = true
    if is_format_heredoc(lexeme):
        content = normalize_format_heredoc(lexeme)
        # Heredoc bodies are raw text — escape sequences are not processed.
        decode_escapes = false
    else if lexeme.len >= 3:
        content = lexeme.slice(2, lexeme.len - 3)

    var parts = vec.Vec[ast.FormatStringPart].create()
    var text = string.String.create()
    var i: ptr_uint = 0
    while i < content.len:
        let b = content.byte_at(i)
        if b == '#' and i + 1 < content.len and content.byte_at(i + 1) == '{':
            if text.len() > 0:
                parts.push(ast.FormatStringPart.fmt_text(value = text.as_str()))
                text = string.String.create()
            let expr_start = i + 2
            let expr_end = fmt_scan_interp_end(content, expr_start)
            let raw_source = content.slice(expr_start, expr_end - expr_start)
            let (src, spec_str) = fmt_split_interp_source(raw_source)
            let embedded = parse_embedded_expr(s, src)
            let spec = fmt_parse_spec(spec_str)
            parts.push(ast.FormatStringPart.fmt_expr(expression = embedded, format_spec = spec))
            i = expr_end + 1
        else if decode_escapes and b == '\\' and i + 1 < content.len:
            text.push_byte(lparse.decode_string_escape(content.byte_at(i + 1)))
            i += 2
        else:
            text.push_byte(b)
            i += 1

    if text.len() > 0:
        parts.push(ast.FormatStringPart.fmt_text(value = text.as_str()))

    var node = alloc_expr(s)
    unsafe:
        read(node) = ast.Expr.expr_format_string(parts = parts.as_span())
    return node


## Scan from just past `#{` to its matching `}`, tracking brace depth and
## skipping string contents.  Returns the index of the closing `}`.
function fmt_scan_interp_end(content: str, start: ptr_uint) -> ptr_uint:
    var depth: int = 1
    var i = start
    while i < content.len:
        let b = content.byte_at(i)
        if b == '"':
            i = fmt_skip_string(content, i)
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
    return content.len


## Advance past a `"..."` string literal starting at `index` (on the opening
## quote), honouring backslash escapes.  Returns the index just past the close.
function fmt_skip_string(content: str, index: ptr_uint) -> ptr_uint:
    var i = index + 1
    while i < content.len:
        let b = content.byte_at(i)
        if b == '"':
            return i + 1
        if b == '\\':
            i += 2
        else:
            i += 1
    return content.len


## Split an interpolation body into `(source, format_spec)` at the last
## top-level `:` whose suffix is a valid format spec (`.N`, `x`/`X`, `o`/`O`,
## `b`/`B`).  `format_spec` is "" when there is none.
function fmt_split_interp_source(raw: str) -> (str, str):
    var depth: int = 0
    var spec_index_set = false
    var spec_index: ptr_uint = 0
    var i: ptr_uint = 0
    while i < raw.len:
        let b = raw.byte_at(i)
        if b == '"':
            i = fmt_skip_string(raw, i)
            continue
        if b == '(' or b == '[' or b == '{':
            depth += 1
        else if b == ')' or b == ']' or b == '}':
            if depth > 0:
                depth -= 1
        else if b == ':' and depth == 0:
            if fmt_is_spec_suffix(raw.slice(i + 1, raw.len - i - 1)):
                spec_index = i
                spec_index_set = true
        i += 1
    if not spec_index_set:
        return (raw, "")
    return (raw.slice(0, spec_index), raw.slice(spec_index + 1, raw.len - spec_index - 1))


## True when a trimmed string is a valid format spec suffix.
function fmt_is_spec_suffix(suffix: str) -> bool:
    let t = suffix.trim_ascii_whitespace()
    if t.len == 0:
        return false
    if t.len == 1:
        let c = t.byte_at(0)
        return c == 'x' or c == 'X' or c == 'o' or c == 'O' or c == 'b' or c == 'B'
    if t.byte_at(0) == '.':
        var i: ptr_uint = 1
        while i < t.len:
            let d = t.byte_at(i)
            if d < '0' or d > '9':
                return false
            i += 1
        return true
    return false


## Parse a trimmed format-spec suffix into a `FormatSpec`, or null when empty.
function fmt_parse_spec(spec: str) -> ptr[ast.FormatSpec]?:
    let t = spec.trim_ascii_whitespace()
    if t.len == 0:
        return null
    var fs: ast.FormatSpec
    if t.byte_at(0) == '.':
        var val: int = 0
        var i: ptr_uint = 1
        while i < t.len:
            val = val * 10 + int<-(t.byte_at(i) - ubyte<-('0'))
            i += 1
        fs = ast.FormatSpec(spec_kind = ast.FormatSpecKind.precision, value = val, uppercase = false)
    else:
        let c = t.byte_at(0)
        if c == 'x':
            fs = ast.FormatSpec(spec_kind = ast.FormatSpecKind.hex, value = 0, uppercase = false)
        else if c == 'X':
            fs = ast.FormatSpec(spec_kind = ast.FormatSpecKind.hex, value = 0, uppercase = true)
        else if c == 'o':
            fs = ast.FormatSpec(spec_kind = ast.FormatSpecKind.octal, value = 0, uppercase = false)
        else if c == 'O':
            fs = ast.FormatSpec(spec_kind = ast.FormatSpecKind.octal, value = 0, uppercase = true)
        else if c == 'b':
            fs = ast.FormatSpec(spec_kind = ast.FormatSpecKind.binary, value = 0, uppercase = false)
        else if c == 'B':
            fs = ast.FormatSpec(spec_kind = ast.FormatSpecKind.binary, value = 0, uppercase = true)
        else:
            return null
    var p = heap_mod.must_alloc[ast.FormatSpec](1)
    unsafe:
        read(p) = fs
    return p


## Re-lex and parse the source text of an interpolation as a single expression,
## in a sub-parser that shares the parent's known-name context so type-name
## disambiguation inside the interpolation matches the surrounding module.
function parse_embedded_expr(s: ref[pstate.ParserState], source: str) -> ptr[ast.Expr]:
    let trimmed = source.trim_ascii_whitespace()
    var sub = pstate.ParserState(
        stream = ts.create(lexer.lex(trimmed)),
        source = trimmed,
        step_counter = 0,
        in_inline_block_body = false,
        recovery_errors = s.recovery_errors,
        known_type_names = s.known_type_names,
        known_import_aliases = s.known_import_aliases,
        known_generic_callable_names = s.known_generic_callable_names,
        current_type_param_names = s.current_type_param_names,
        suppress_errors = s.suppress_errors,
        error_suppressed = false,
    )
    return parse_expression(ref_of(sub))


function append_escaped_byte(buf: ref[string.String], ch: ubyte) -> void:
    lparse.append_escaped_byte(buf, ch)


# =============================================================================
#  AST node allocation
# =============================================================================

function alloc_expr(s: ref[pstate.ParserState]) -> own[ast.Expr]:
    return heap_mod.must_alloc[ast.Expr](1)

function alloc_stmt(s: ref[pstate.ParserState]) -> own[ast.Stmt]:
    return heap_mod.must_alloc[ast.Stmt](1)

function alloc_decl(s: ref[pstate.ParserState]) -> own[ast.Decl]:
    return heap_mod.must_alloc[ast.Decl](1)


# =============================================================================
#  Public API
# =============================================================================

public function parse(source: str) -> bool:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    var state = pstate.ParserState(
        stream = ts.create(lexer.lex_reporting(source, ref_of(lex_diags))),
        source = source,
        step_counter = 0,
        in_inline_block_body = false,
        recovery_errors = null,
        known_type_names = map_mod.Map[str, bool].create(),
        known_import_aliases = map_mod.Map[str, bool].create(),
        known_generic_callable_names = map_mod.Map[str, bool].create(),
        current_type_param_names = vec.Vec[str].create(),
        suppress_errors = false,
        error_suppressed = false,
    )
    lex_diags.release()
    seed_known_names(ref_of(state))
    let file = parse_source_file(ref_of(state))
    return source_file_decl_count(file) > 0


public function parse_reporting(source: str, errors: ref[vec.Vec[pstate.ParseDiagnostic]]) -> (bool, ptr_uint):
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    var state = pstate.ParserState(
        stream = ts.create(lexer.lex_reporting(source, ref_of(lex_diags))),
        source = source,
        step_counter = 0,
        in_inline_block_body = false,
        recovery_errors = ptr_of(errors),
        known_type_names = map_mod.Map[str, bool].create(),
        known_import_aliases = map_mod.Map[str, bool].create(),
        known_generic_callable_names = map_mod.Map[str, bool].create(),
        current_type_param_names = vec.Vec[str].create(),
        suppress_errors = false,
        error_suppressed = false,
    )
    lex_diags.release()
    seed_known_names(ref_of(state))
    let file = parse_source_file(ref_of(state))
    return (errors.len() == 0, source_file_decl_count(file))


## Parse a full source file into an AST SourceFile.  Collects recoverable
## errors into `errors`.  Used by the CLI `parse` command and the pretty
## printer.  The backing buffers of the produced spans are intentionally
## leaked (arena-style): the compiler processes one file per run and exits.
public function parse_source(source: str, errors: ref[vec.Vec[pstate.ParseDiagnostic]]) -> ast.SourceFile:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    var state = pstate.ParserState(
        stream = ts.create(lexer.lex_reporting(source, ref_of(lex_diags))),
        source = source,
        step_counter = 0,
        in_inline_block_body = false,
        recovery_errors = ptr_of(errors),
        known_type_names = map_mod.Map[str, bool].create(),
        known_import_aliases = map_mod.Map[str, bool].create(),
        known_generic_callable_names = map_mod.Map[str, bool].create(),
        current_type_param_names = vec.Vec[str].create(),
        suppress_errors = false,
        error_suppressed = false,
    )
    lex_diags.release()
    seed_known_names(ref_of(state))
    return parse_source_file(ref_of(state))


function source_file_decl_count(file: ast.SourceFile) -> ptr_uint:
    return file.imports.len + file.directives.len + file.declarations.len


# =============================================================================
#  Source file
# =============================================================================

function parse_source_file(s: ref[pstate.ParserState]) -> ast.SourceFile:
    skip_newlines(s)

    if check(s, tk.TokenKind.tk_external) and not check_next(s, tk.TokenKind.tk_function):
        advance(s)
        skip_newlines(s)
        return parse_raw_module_body(s)

    var imports = vec.Vec[ast.Decl].create()
    var declarations = vec.Vec[ast.Decl].create()

    while match_kind(s, tk.TokenKind.tk_import):
        let imp = parse_import(s)
        unsafe:
            imports.push(read(imp))
        skip_newlines(s)

    while not eof(s):
        step(s)
        let decl = parse_declaration(s)
        unsafe:
            declarations.push(read(decl))
        skip_newlines(s)

    return ast.SourceFile(
        module_kind = ast.ModuleKind.module_ordinary,
        imports = imports.as_span(),
        directives = span[ast.Decl](),
        declarations = declarations.as_span(),
        line = 1,
    )


function parse_raw_module_body(s: ref[pstate.ParserState]) -> ast.SourceFile:
    var imports = vec.Vec[ast.Decl].create()
    var directives = vec.Vec[ast.Decl].create()
    var declarations = vec.Vec[ast.Decl].create()

    while match_kind(s, tk.TokenKind.tk_import):
        let imp = parse_import(s)
        unsafe:
            imports.push(read(imp))
        skip_newlines(s)
    while check(s, tk.TokenKind.tk_link) or check(s, tk.TokenKind.tk_include) or check(s, tk.TokenKind.tk_compiler_flag):
        let directive = parse_raw_module_directive(s)
        unsafe:
            directives.push(read(directive))
        skip_newlines(s)
    while not eof(s):
        step(s)
        let decl = parse_external_declaration(s)
        unsafe:
            declarations.push(read(decl))
        skip_newlines(s)

    return ast.SourceFile(
        module_kind = ast.ModuleKind.module_raw,
        imports = imports.as_span(),
        directives = directives.as_span(),
        declarations = declarations.as_span(),
        line = 1,
    )


function parse_external_declaration(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    s.step_counter = 0
    if match_kind(s, tk.TokenKind.tk_const):
        return parse_const_decl(s, span[ast.AttributeApplication](), false)
    else if match_kind(s, tk.TokenKind.tk_type):
        return parse_type_alias(s, false)
    else if match_kind(s, tk.TokenKind.tk_struct):
        return parse_struct_decl(s, span[ast.AttributeApplication](), false)
    else if match_kind(s, tk.TokenKind.tk_union):
        return parse_union_decl(s, span[ast.AttributeApplication](), false)
    else if match_kind(s, tk.TokenKind.tk_enum):
        return parse_enum_decl(s, false, span[ast.AttributeApplication](), false)
    else if match_kind(s, tk.TokenKind.tk_flags):
        return parse_enum_decl(s, true, span[ast.AttributeApplication](), false)
    else if match_kind(s, tk.TokenKind.tk_opaque):
        return parse_opaque_decl(s, false)
    else if match_kind(s, tk.TokenKind.tk_external):
        if match_kind(s, tk.TokenKind.tk_function):
            return parse_extern_decl(s, span[ast.AttributeApplication]())
        else:
            parser_error_naked(s, c"expected function after external")
            advance(s)
            return decl_error_sentinel(s)
    else if match_kind(s, tk.TokenKind.tk_when):
        return parse_when_decl(s)
    else:
        parser_error_naked(s, c"expected external declaration")
        advance(s)
        return decl_error_sentinel(s)


function decl_error_sentinel(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    var err = alloc_expr(s)
    unsafe:
        read(err) = ast.Expr.expr_error(line = 0, column = 0, message = "declaration error")
    var node = alloc_decl(s)
    read(node) = ast.Decl.decl_static_assert(condition = err, message = null, line = 0)
    return node


# =============================================================================
#  Import
# =============================================================================

function parse_import(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    let tok = peek(s) else:
        return decl_error_sentinel(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(tok).line
        cn = read(tok).column
    let path = parse_qualified_name(s)
    var alias_name: Option[str] = Option[str].none
    if match_kind(s, tk.TokenKind.tk_as):
        consume_name(s, c"expected import alias")
        alias_name = Option[str].some(value = previous_lexeme(s))
    consume_end_of_statement(s)
    var node = alloc_decl(s)
    read(node) = ast.Decl.decl_import(path = path, alias_name = alias_name, line = ln, column = cn)
    return node


function parse_qualified_name(s: ref[pstate.ParserState]) -> ast.QualifiedName:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    var parts = vec.Vec[str].create()
    consume_name_allowing_keywords(s, c"expected identifier")
    parts.push(previous_lexeme(s))
    while match_kind(s, tk.TokenKind.dot):
        consume_name_allowing_keywords(s, c"expected identifier after '.'")
        parts.push(previous_lexeme(s))
    return ast.QualifiedName(parts = parts.as_span(), type_arguments = span[ast.TypeRef](), line = ln, column = cn)


# =============================================================================
#  Declaration dispatch
# =============================================================================

function parse_attribute_application(s: ref[pstate.ParserState]) -> ast.AttributeApplication:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    let name = parse_qualified_name(s)
    var arguments = span[ast.Argument]()
    if match_kind(s, tk.TokenKind.lparen):
        arguments = parse_call_args(s)
        consume(s, tk.TokenKind.rparen, c"expected ')' after attribute arguments")
    return ast.AttributeApplication(name = name, arguments = arguments, line = ln, column = cn)


function parse_attribute_applications(s: ref[pstate.ParserState]) -> span[ast.AttributeApplication]:
    var attrs = vec.Vec[ast.AttributeApplication].create()
    while match_kind(s, tk.TokenKind.at):
        consume(s, tk.TokenKind.lbracket, c"expected '[' after @")
        if not check(s, tk.TokenKind.rbracket):
            while true:
                step(s)
                attrs.push(parse_attribute_application(s))
                if not match_kind(s, tk.TokenKind.comma):
                    break
                if check(s, tk.TokenKind.rbracket):
                    break
        consume(s, tk.TokenKind.rbracket, c"expected ']' after attribute")
        skip_newlines(s)
    return attrs.as_span()


function skip_attribute_content(s: ref[pstate.ParserState]) -> void:
    var depth: int = 1
    while not eof(s) and depth > 0:
        step(s)
        if check(s, tk.TokenKind.lbracket):
            depth += 1
        else if check(s, tk.TokenKind.rbracket):
            depth -= 1
            if depth > 0:
                advance(s)
        else:
            advance(s)


# =============================================================================
#  External file support
# =============================================================================

function external_file_header(s: ref[pstate.ParserState]) -> bool:
    return check(s, tk.TokenKind.tk_external) and ts.check_next(ref_of(s.stream), tk.TokenKind.newline)


function parse_raw_module_directive(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    if match_kind(s, tk.TokenKind.tk_link):
        consume(s, tk.TokenKind.string, c"expected string after link")
        let value = parse_string_content(previous_lexeme(s), false)
        consume_end_of_statement(s)
        var node = alloc_decl(s)
        read(node) = ast.Decl.decl_link(value = value, line = ln, column = cn)
        return node
    else if match_kind(s, tk.TokenKind.tk_include):
        consume(s, tk.TokenKind.string, c"expected string after include")
        let value = parse_string_content(previous_lexeme(s), false)
        consume_end_of_statement(s)
        var node = alloc_decl(s)
        read(node) = ast.Decl.decl_include(value = value, line = ln, column = cn)
        return node
    else if match_kind(s, tk.TokenKind.tk_compiler_flag):
        consume(s, tk.TokenKind.string, c"expected string after compiler_flag")
        let value = parse_string_content(previous_lexeme(s), false)
        consume_end_of_statement(s)
        var node = alloc_decl(s)
        read(node) = ast.Decl.decl_compiler_flag(value = value, line = ln, column = cn)
        return node
    return decl_error_sentinel(s)


function parse_declaration(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    s.step_counter = 0
    let attrs = parse_attribute_applications(s)
    let visibility = match_kind(s, tk.TokenKind.tk_public)
    if visibility:
        skip_newlines(s)

    if match_kind(s, tk.TokenKind.tk_const):
        if match_kind(s, tk.TokenKind.tk_function):
            return parse_function_def(s, attrs, visibility, false, true)
        else:
            return parse_const_decl(s, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_var):
        return parse_var_decl(s, visibility)
    else if match_kind(s, tk.TokenKind.tk_function):
        return parse_function_def(s, attrs, visibility, false, false)
    else if match_kind(s, tk.TokenKind.tk_struct):
        return parse_struct_decl(s, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_union):
        return parse_union_decl(s, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_type):
        return parse_type_alias(s, visibility)
    else if match_kind(s, tk.TokenKind.tk_enum):
        return parse_enum_decl(s, false, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_flags):
        return parse_enum_decl(s, true, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_variant):
        return parse_variant_decl(s, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_interface):
        return parse_interface_decl(s, visibility)
    else if match_kind(s, tk.TokenKind.tk_opaque):
        return parse_opaque_decl(s, visibility)
    else if match_kind(s, tk.TokenKind.tk_extending):
        return parse_extending_block(s)
    else if match_kind(s, tk.TokenKind.tk_async):
        consume(s, tk.TokenKind.tk_function, c"expected function after async")
        return parse_function_def(s, attrs, visibility, true, false)
    else if match_kind(s, tk.TokenKind.tk_external):
        consume(s, tk.TokenKind.tk_function, c"expected function after external")
        return parse_extern_decl(s, attrs)
    else if match_kind(s, tk.TokenKind.tk_foreign):
        consume(s, tk.TokenKind.tk_function, c"expected function after foreign")
        return parse_foreign_decl(s, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_static_assert):
        return parse_static_assert(s)
    else if match_kind(s, tk.TokenKind.tk_event):
        return parse_event_decl(s, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_when):
        return parse_when_decl(s)
    else if match_kind(s, tk.TokenKind.tk_attribute):
        return parse_attribute_decl(s, visibility)
    else:
        parser_error_naked(s, c"expected declaration")
        advance(s)
        return decl_error_sentinel(s)


function parse_union_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected union name")
    let name = previous_lexeme(s)
    let c_name = parse_optional_c_name(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after union name")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented union body")
    skip_newlines(s)
    var fields = vec.Vec[ast.Field].create()
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        fields.push(parse_struct_member(s, span[ast.AttributeApplication]()))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of union body")
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_union(name = name, c_name = c_name, union_fields = fields.as_span(),
            visibility = visibility, union_attrs = attrs, line = ln, column = cn)
    return node


# =============================================================================
#  Declarations
# =============================================================================

function parse_const_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected constant name")
    let name = previous_lexeme(s)
    if match_kind(s, tk.TokenKind.arrow):
        # Block-bodied const: const NAME -> TYPE:
        let const_type = parse_type_ref(s)
        let block = parse_block(s)
        var node = alloc_decl(s)
        unsafe:
            read(node) = ast.Decl.decl_const(name = name, const_type = const_type, value = null,
                block_body = block, visibility = visibility, attributes = attrs, line = ln, column = cn)
        return node
    consume(s, tk.TokenKind.colon, c"expected ':' after constant name")
    let const_type = parse_type_ref(s)
    consume(s, tk.TokenKind.equal, c"expected '=' after constant type")
    let value = parse_expression(s)
    consume_end_of_statement(s)
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_const(name = name, const_type = const_type, value = value,
            block_body = null, visibility = visibility, attributes = attrs, line = ln, column = cn)
    return node


function parse_var_decl(s: ref[pstate.ParserState], visibility: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected variable name")
    let name = previous_lexeme(s)
    var var_type: ptr[ast.TypeRef]? = null
    if match_kind(s, tk.TokenKind.colon):
        var_type = parse_type_ref(s)
    var value: ptr[ast.Expr]? = null
    if match_kind(s, tk.TokenKind.equal):
        value = parse_expression(s)
    consume_end_of_statement(s)
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_var(name = name, var_type = var_type, value = value,
            visibility = visibility, line = ln, column = cn)
    return node


function parse_function_def(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool,
                            is_async: bool, is_const: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected function name")
    let name = previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    if match_kind(s, tk.TokenKind.lbracket):
        type_params = parse_declaration_type_params(s)
    let params = parse_params(s)
    var return_type: ptr[ast.TypeRef]? = null
    if match_kind(s, tk.TokenKind.arrow):
        return_type = parse_type_ref(s)
    let body = parse_block(s)
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_function(name = name, type_params = type_params, method_params = params,
            return_type = return_type, body = body, visibility = visibility, is_async = is_async,
            is_const = is_const, attributes = attrs, line = ln, column = cn)
    return node


## Parse `= c"name"` optional C-name suffix used by struct/union/opaque in
## external files.  Returns none when absent.
function parse_optional_c_name(s: ref[pstate.ParserState]) -> Option[str]:
    if match_kind(s, tk.TokenKind.equal):
        if match_kind(s, tk.TokenKind.cstring):
            return Option[str].some(value = parse_string_content(previous_lexeme(s), true))
        if match_kind(s, tk.TokenKind.string):
            return Option[str].some(value = parse_string_content(previous_lexeme(s), false))
    return Option[str].none


function parse_declaration_type_params(s: ref[pstate.ParserState]) -> span[ast.TypeParam]:
    var params = vec.Vec[ast.TypeParam].create()
    while not eof(s):
        if check(s, tk.TokenKind.rbracket):
            break
        let tp_tok = peek(s)
        var tln: ptr_uint = 0
        var tcn: ptr_uint = 0
        if tp_tok != null:
            unsafe:
                tln = read(tp_tok).line
                tcn = read(tp_tok).column
        if match_kind(s, tk.TokenKind.at):
            consume_name(s, c"expected lifetime name after @")
            var lt_name = str_prepend_at(previous_lexeme(s))
            params.push(ast.TypeParam(name = lt_name, constraints = span[ast.TypeParamConstraint](),
                is_value = false, value_type = null, is_lifetime = true, line = tln, column = tcn))
        else:
            consume_name(s, c"expected type parameter name")
            let tp_name = previous_lexeme(s)
            s.current_type_param_names.push(tp_name)
            var is_value = false
            var value_type: ptr[ast.TypeRef]? = null
            var constraints = vec.Vec[ast.TypeParamConstraint].create()
            if match_kind(s, tk.TokenKind.colon):
                is_value = true
                value_type = parse_type_ref(s)
            else if match_kind(s, tk.TokenKind.tk_implements):
                parse_type_param_constraints(s, ref_of(constraints))
            params.push(ast.TypeParam(name = tp_name, constraints = constraints.as_span(),
                is_value = is_value, value_type = value_type, is_lifetime = false, line = tln, column = tcn))
        if not match_kind(s, tk.TokenKind.comma):
            break
        if check(s, tk.TokenKind.rbracket):
            break
    consume(s, tk.TokenKind.rbracket, c"expected ']' after type parameters")
    return params.as_span()


function parse_type_param_constraints(s: ref[pstate.ParserState], constraints: ref[vec.Vec[ast.TypeParamConstraint]]) -> void:
    while true:
        let iface = parse_qualified_name(s)
        # Skip generic type-arguments on a constraint (Ruby renders the bare name).
        if match_kind(s, tk.TokenKind.lbracket):
            var depth: int = 1
            while not eof(s) and depth > 0:
                if check(s, tk.TokenKind.lbracket):
                    depth += 1
                else if check(s, tk.TokenKind.rbracket):
                    depth -= 1
                advance(s)
        constraints.push(ast.TypeParamConstraint(kind = ast.TypeParamConstraintKind.implement, interface_ref = iface))
        if not match_kind(s, tk.TokenKind.tk_and):
            break


function str_prepend_at(name: str) -> str:
    var buf = string.String.create()
    buf.append("@")
    buf.append(name)
    return buf.as_str()


function with_type_param_scope(s: ref[pstate.ParserState], body: proc(session: ref[pstate.ParserState]) -> void) -> void:
    var saved_count = s.current_type_param_names.len()
    body(s)
    while s.current_type_param_names.len() > saved_count:
        s.current_type_param_names.pop()


function parse_params(s: ref[pstate.ParserState]) -> span[ast.Param]:
    var params = vec.Vec[ast.Param].create()
    consume(s, tk.TokenKind.lparen, c"expected '('")
    while not eof(s) and not check(s, tk.TokenKind.rparen):
        if match_kind(s, tk.TokenKind.ellipsis):
            break
        if (check(s, tk.TokenKind.tk_out) or check(s, tk.TokenKind.tk_in)
            or check(s, tk.TokenKind.tk_inout) or check(s, tk.TokenKind.tk_consuming)):
            if check_next(s, tk.TokenKind.identifier) or check_next(s, tk.TokenKind.tk_function):
                advance(s)
        let tok = peek(s) else:
            break
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
        consume_name(s, c"expected parameter name")
        let name_str = previous_lexeme(s)
        consume(s, tk.TokenKind.colon, c"expected ':' after parameter name")
        var ptype = parse_type_ref(s)
        if match_kind(s, tk.TokenKind.tk_as):
            let _boundary = parse_type_ref(s)
        unsafe:
            var pm = ast.Param(name = name_str, param_type = read(ptype), line = ln, column = cn)
            params.push(pm)
        if not match_kind(s, tk.TokenKind.comma):
            break
    consume(s, tk.TokenKind.rparen, c"expected ')'")
    let result = params.as_span()
    return result


function parse_type_ref(s: ref[pstate.ParserState]) -> ptr[ast.TypeRef]:
    # fn(...) -> T
    if match_kind(s, tk.TokenKind.tk_fn):
        return parse_callable_type_ref(s, false)
    # proc(...) -> T
    if match_kind(s, tk.TokenKind.tk_proc):
        return parse_callable_type_ref(s, true)
    # dyn[Interface]
    if match_kind(s, tk.TokenKind.tk_dyn):
        return parse_dyn_type_ref(s)
    # @lifetime ref
    if match_kind(s, tk.TokenKind.at):
        let lt_tok = peek(s) else:
            fatal(c"unexpected eof after @ in type ref")
        var lt_ln: ptr_uint
        var lt_cn: ptr_uint
        unsafe:
            lt_ln = read(lt_tok).line
            lt_cn = read(lt_tok).column
        consume_name(s, c"expected lifetime name after @")
        let lt_name = previous_lexeme(s)
        var node = heap_mod.must_alloc[ast.TypeRef](1)
        unsafe:
            read(node) = ast.TypeRef(
                name = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef](), line = lt_ln, column = lt_cn),
                arguments = span[ast.TypeRef](), nullable = false,
                lifetime = Option[str].some(value = lt_name), line = lt_ln, column = lt_cn,
                fn_params = span[ast.Param](), fn_return = null,
                is_proc = false, is_fn = false,
                dyn_interface = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef]()),
                is_dyn = false, is_tuple = false
            )
        return node
    # (T, U) tuple type or (T) parenthesized type
    if match_kind(s, tk.TokenKind.lparen):
        return parse_tuple_or_parenthesized_type(s)

    # Named type ref
    return parse_named_type_ref(s, true)


function parse_callable_type_ref(s: ref[pstate.ParserState], is_proc_val: bool) -> ptr[ast.TypeRef]:
    let start_tok = peek(s) else:
        fatal(c"unexpected eof in callable type")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    consume(s, tk.TokenKind.lparen, c"expected '(' after fn/proc")
    var params_vec = vec.Vec[ast.Param].create()
    if not check(s, tk.TokenKind.rparen):
        while true:
            step(s)
            let ptok = peek(s) else:
                break
            var pln: ptr_uint
            var pcn: ptr_uint
            unsafe:
                pln = read(ptok).line
                pcn = read(ptok).column
            consume_name(s, c"expected parameter name in callable type")
            let pname = previous_lexeme(s)
            consume(s, tk.TokenKind.colon, c"expected ':' after parameter name")
            var ptype = parse_type_ref(s)
            unsafe:
                params_vec.push(ast.Param(name = pname, param_type = read(ptype), line = pln, column = pcn))
            if not match_kind(s, tk.TokenKind.comma):
                break
            if check(s, tk.TokenKind.rparen):
                break
    consume(s, tk.TokenKind.rparen, c"expected ')' after callable type params")
    consume(s, tk.TokenKind.arrow, c"expected '->' after callable type params")
    var ret_type = parse_type_ref(s)
    var node = heap_mod.must_alloc[ast.TypeRef](1)
    var params_span = params_vec.as_span()
    unsafe:
        read(node) = ast.TypeRef(
            name = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef](), line = ln, column = cn),
            arguments = span[ast.TypeRef](), nullable = false,
            lifetime = Option[str].none, line = ln, column = cn,
            fn_params = params_span, fn_return = ret_type,
            is_proc = is_proc_val, is_fn = not is_proc_val,
            dyn_interface = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef]()),
            is_dyn = false, is_tuple = false
        )
    return node


function parse_dyn_type_ref(s: ref[pstate.ParserState]) -> ptr[ast.TypeRef]:
    let start_tok = previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = start_tok.line
        cn = start_tok.column
    consume(s, tk.TokenKind.lbracket, c"expected '[' after dyn")
    consume_name(s, c"expected interface name after dyn[")
    let iface_name = previous_lexeme(s)
    var parts_vec = vec.Vec[str].create()
    parts_vec.push(iface_name)
    while match_kind(s, tk.TokenKind.dot):
        consume_name(s, c"expected interface name after '.'")
        parts_vec.push(previous_lexeme(s))
    # Optionally parse type arguments for generic interfaces like dyn[Mapper[int]]
    var iface_args = span[ast.TypeRef]()
    if match_kind(s, tk.TokenKind.lbracket):
        var iface_args_vec = vec.Vec[ast.TypeRef].create()
        if not check(s, tk.TokenKind.rbracket):
            while true:
                step(s)
                var ta = parse_type_argument(s)
                unsafe:
                    iface_args_vec.push(read(ta))
                if not match_kind(s, tk.TokenKind.comma):
                    break
                if check(s, tk.TokenKind.rbracket):
                    break
        consume(s, tk.TokenKind.rbracket, c"expected ']' after dyn interface type arguments")
        iface_args = iface_args_vec.as_span()
    var iface_qname = ast.QualifiedName(parts = parts_vec.as_span(), type_arguments = iface_args, line = ln, column = cn)
    consume(s, tk.TokenKind.rbracket, c"expected ']' after dyn interface")
    var nullable = match_kind(s, tk.TokenKind.question)
    var node = heap_mod.must_alloc[ast.TypeRef](1)
    unsafe:
        read(node) = ast.TypeRef(
            name = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef](), line = ln, column = cn),
            arguments = span[ast.TypeRef](), nullable = nullable,
            lifetime = Option[str].none, line = ln, column = cn,
            fn_params = span[ast.Param](), fn_return = null,
            is_proc = false, is_fn = false,
            dyn_interface = iface_qname,
            is_dyn = true, is_tuple = false
        )
    return node


function parse_tuple_or_parenthesized_type(s: ref[pstate.ParserState]) -> ptr[ast.TypeRef]:
    let start_tok = peek(s) else:
        fatal(c"unexpected eof in tuple type")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var first_type = parse_type_ref(s)
    if match_kind(s, tk.TokenKind.comma):
        var types_vec = vec.Vec[ast.TypeRef].create()
        unsafe:
            types_vec.push(read(first_type))
        while true:
            step(s)
            if check(s, tk.TokenKind.rparen):
                break
            var next_type = parse_type_ref(s)
            unsafe:
                types_vec.push(read(next_type))
            if not match_kind(s, tk.TokenKind.comma):
                break
            if check(s, tk.TokenKind.rparen):
                break
        consume(s, tk.TokenKind.rparen, c"expected ')' after tuple type elements")
        var nullable = match_kind(s, tk.TokenKind.question)
        var types_span = types_vec.as_span()
        var node = heap_mod.must_alloc[ast.TypeRef](1)
        unsafe:
            read(node) = ast.TypeRef(
                name = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef](), line = ln, column = cn),
                arguments = types_span, nullable = nullable,
                lifetime = Option[str].none, line = ln, column = cn,
                fn_params = span[ast.Param](), fn_return = null,
                is_proc = false, is_fn = false,
                dyn_interface = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef]()),
                is_dyn = false, is_tuple = true
            )
        return node
    consume(s, tk.TokenKind.rparen, c"expected ')' after type")
    return first_type


function parse_named_type_ref(s: ref[pstate.ParserState], allow_nullable: bool) -> ptr[ast.TypeRef]:
    let tok = peek(s) else:
        fatal(c"unexpected eof in type ref")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(tok).line
        cn = read(tok).column
    consume_name_allowing_keywords(s, c"expected type name")
    let first_name = previous_lexeme(s)
    var part_names = vec.Vec[str].create()
    part_names.push(first_name)
    while match_kind(s, tk.TokenKind.dot):
        consume_name_allowing_keywords(s, c"expected type name after '.'")
        part_names.push(previous_lexeme(s))
    var type_args_vec = vec.Vec[ast.TypeRef].create()
    var lifetime: Option[str] = Option[str].none
    if match_kind(s, tk.TokenKind.lbracket):
        if check(s, tk.TokenKind.at):
            advance(s)
            let lt_name_tok = peek(s) else:
                fatal(c"unexpected eof after @ in type arguments")
            unsafe:
                consume_name(s, c"expected lifetime name after @")
                lifetime = Option[str].some(value = previous_lexeme(s))
            # A trailing comma introduces further type arguments (e.g.
            # `ref[@a, T]`); a lifetime-only argument (`SliceView[@a]`) has none.
            let _lt_comma = match_kind(s, tk.TokenKind.comma)
        if not check(s, tk.TokenKind.rbracket):
            while true:
                step(s)
                var ta = parse_type_argument(s)
                unsafe:
                    type_args_vec.push(read(ta))
                if not match_kind(s, tk.TokenKind.comma):
                    break
                if check(s, tk.TokenKind.rbracket):
                    break
        consume(s, tk.TokenKind.rbracket, c"expected ']' after type arguments")
    var nullable = false
    if allow_nullable:
        nullable = match_kind(s, tk.TokenKind.question)
    var name_parts_span = part_names.as_span()
    var type_args_span = type_args_vec.as_span()
    var qname = ast.QualifiedName(parts = name_parts_span, type_arguments = type_args_span, line = ln, column = cn)
    var node = heap_mod.must_alloc[ast.TypeRef](1)
    unsafe:
        read(node) = ast.TypeRef(
            name = qname, arguments = type_args_span, nullable = nullable,
            lifetime = lifetime, line = ln, column = cn,
            fn_params = span[ast.Param](), fn_return = null,
            is_proc = false, is_fn = false,
            dyn_interface = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef]()),
            is_dyn = false, is_tuple = false
        )
    return node


function parse_type_argument(s: ref[pstate.ParserState]) -> ptr[ast.TypeRef]:
    if match_kind(s, tk.TokenKind.integer):
        let lex = previous_lexeme(s)
        var node = heap_mod.must_alloc[ast.TypeRef](1)
        var parts = vec.Vec[str].create()
        parts.push(lex)
        var span_parts = parts.as_span()
        unsafe:
            read(node) = ast.TypeRef(
                name = ast.QualifiedName(parts = span_parts, type_arguments = span[ast.TypeRef](), line = 0, column = 0),
                arguments = span[ast.TypeRef](), nullable = false,
                lifetime = Option[str].none, line = 0, column = 0,
                fn_params = span[ast.Param](), fn_return = null,
                is_proc = false, is_fn = false,
                dyn_interface = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef]()),
                is_dyn = false, is_tuple = false
            )
        return node
    if match_kind(s, tk.TokenKind.float_literal):
        let lex = previous_lexeme(s)
        var node = heap_mod.must_alloc[ast.TypeRef](1)
        var parts = vec.Vec[str].create()
        parts.push(lex)
        var span_parts = parts.as_span()
        unsafe:
            read(node) = ast.TypeRef(
                name = ast.QualifiedName(parts = span_parts, type_arguments = span[ast.TypeRef](), line = 0, column = 0),
                arguments = span[ast.TypeRef](), nullable = false,
                lifetime = Option[str].none, line = 0, column = 0,
                fn_params = span[ast.Param](), fn_return = null,
                is_proc = false, is_fn = false,
                dyn_interface = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef]()),
                is_dyn = false, is_tuple = false
            )
        return node
    # Fall back to a full type ref so callable (`fn(...)->T`), proc, dyn,
    # tuple and nullable type arguments are handled, not just named types.
    return parse_type_ref(s)


function parse_block(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    consume(s, tk.TokenKind.colon, c"expected ':' before block")
    consume(s, tk.TokenKind.newline, c"expected newline before block body")
    skip_newlines(s)
    consume(s, tk.TokenKind.indent, c"expected indented block")
    var body_span = parse_block_body(s)
    consume(s, tk.TokenKind.dedent, c"expected end of block")
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_block(statements = body_span)
    return node


function parse_block_body(s: ref[pstate.ParserState]) -> span[ast.Stmt]:
    var stmts = vec.Vec[ast.Stmt].create()
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        step(s)
        if check(s, tk.TokenKind.newline):
            advance(s)
            skip_newlines(s)
            continue
        var saved = s.stream.current
        let stmt = parse_statement(s)
        unsafe:
            stmts.push(read(stmt))
        skip_newlines(s)
    let result = stmts.as_span()
    return result


# =============================================================================
#  Statements
# =============================================================================

function parse_statement(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    if match_kind(s, tk.TokenKind.tk_let):
        return parse_local_decl(s, true)
    else if match_kind(s, tk.TokenKind.tk_var):
        return parse_local_decl(s, false)
    else if match_kind(s, tk.TokenKind.tk_if):
        return parse_if_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_while):
        return parse_while_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_for):
        return parse_for_stmt(s, false)
    else if match_kind(s, tk.TokenKind.tk_match):
        return parse_match_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_return):
        return parse_return_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_break):
        let tok = peek(s) else:
            return stmt_error_sentinel(s, c"unexpected eof in break")
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
        consume_end_of_statement(s)
        var node = alloc_stmt(s)
        read(node) = ast.Stmt.stmt_break(line = ln, column = cn)
        return node
    else if match_kind(s, tk.TokenKind.tk_continue):
        let tok = peek(s) else:
            return stmt_error_sentinel(s, c"unexpected eof in continue")
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
        consume_end_of_statement(s)
        var node = alloc_stmt(s)
        read(node) = ast.Stmt.stmt_continue(line = ln, column = cn)
        return node
    else if match_kind(s, tk.TokenKind.tk_pass):
        let tok = peek(s) else:
            return stmt_error_sentinel(s, c"unexpected eof in pass")
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
        consume_end_of_statement(s)
        var node = alloc_stmt(s)
        read(node) = ast.Stmt.stmt_pass(line = ln, column = cn)
        return node
    else if match_kind(s, tk.TokenKind.tk_defer):
        return parse_defer_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_unsafe):
        return parse_unsafe_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_static_assert):
        return parse_static_assert_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_when):
        return parse_when_stmt(s)
    else if check(s, tk.TokenKind.tk_parallel) and check_next(s, tk.TokenKind.tk_for):
        advance(s)
        advance(s)
        return parse_for_stmt(s, true)
    else if match_kind(s, tk.TokenKind.tk_parallel):
        return parse_parallel_block(s)
    else if match_kind(s, tk.TokenKind.tk_gather):
        return parse_gather_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_emit):
        return parse_emit_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_inline):
        if match_kind(s, tk.TokenKind.tk_for):
            return parse_inline_for_stmt(s)
        else if match_kind(s, tk.TokenKind.tk_while):
            return parse_inline_while_stmt(s)
        else if match_kind(s, tk.TokenKind.tk_match):
            return parse_inline_match_stmt(s)
        else if match_kind(s, tk.TokenKind.tk_if):
            return parse_inline_if_stmt(s)
        return parse_expression_stmt(s)
    else:
        return parse_expression_stmt(s)


function stmt_error_sentinel(s: ref[pstate.ParserState], msg: cstr) -> ptr[ast.Stmt]:
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_error(line = 0, column = 0, message = "parse error")
    return node


function parse_local_decl(s: ref[pstate.ParserState], is_let: bool) -> ptr[ast.Stmt]:
    let tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in local decl")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(tok).line
        cn = read(tok).column
    var name_str = ""
    var stmt_type: ptr[ast.TypeRef]? = null
    var value: ptr[ast.Expr]? = null
    var else_binding: Option[str] = Option[str].none
    var else_body: ptr[ast.Stmt]? = null
    var destructure_bindings: Option[span[str]] = Option[span[str]].none
    var destructure_type_name: Option[str] = Option[str].none

    if check(s, tk.TokenKind.lparen):
        destructure_bindings = parse_destructure_bindings(s)
    else if check_name(s) and check_next(s, tk.TokenKind.lparen):
        consume_name_allowing_keywords(s, c"expected type name")
        destructure_type_name = Option[str].some(value = previous_lexeme(s))
        destructure_bindings = parse_destructure_bindings(s)
    else if check_name(s) and check_next(s, tk.TokenKind.dot):
        advance(s)
        let first_part_name = previous_lexeme(s)
        while match_kind(s, tk.TokenKind.dot):
            consume_name(s, c"expected type name after '.'")
        consume(s, tk.TokenKind.lparen, c"expected '(' after destructure type name")
        destructure_type_name = Option[str].some(value = first_part_name)
        destructure_bindings = parse_destructure_bindings(s)
    else:
        consume_name(s, c"expected variable name")
        name_str = previous_lexeme(s)

    if destructure_bindings.is_some():
        consume(s, tk.TokenKind.equal, c"expected '=' after destructure pattern")
        value = parse_expression(s)
        consume_end_of_statement(s)
        var node = alloc_stmt(s)
        unsafe:
            read(node) = ast.Stmt.stmt_local(is_let = is_let, name = name_str, stmt_type = stmt_type, value = value,
                else_binding = else_binding, else_body = else_body,
                destructure_bindings = destructure_bindings,
                destructure_type_name = destructure_type_name, line = ln, column = cn)
        return node

    if match_kind(s, tk.TokenKind.colon):
        stmt_type = parse_type_ref(s)
    if match_kind(s, tk.TokenKind.equal):
        value = parse_expression(s)
    if match_kind(s, tk.TokenKind.tk_else):
        if match_kind(s, tk.TokenKind.tk_as):
            consume_name(s, c"expected error binding name")
            let bind_name = previous_lexeme(s)
            else_binding = Option[str].some(value = bind_name)
        consume(s, tk.TokenKind.colon, c"expected ':' after else")
        consume(s, tk.TokenKind.newline, c"expected newline after else:")
        consume(s, tk.TokenKind.indent, c"expected indented else body")
        var body_span = parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of else body")
        var body_stmt = alloc_stmt(s)
        unsafe:
            read(body_stmt) = ast.Stmt.stmt_block(statements = body_span)
        else_body = body_stmt
        var node = alloc_stmt(s)
        unsafe:
            read(node) = ast.Stmt.stmt_local(is_let = is_let, name = name_str, stmt_type = stmt_type, value = value,
                else_binding = else_binding, else_body = else_body,
                destructure_bindings = Option[span[str]].none,
                destructure_type_name = Option[str].none, line = ln, column = cn)
        return node
    if match_kind(s, tk.TokenKind.question):
        pass
    if stmt_type == null and value == null:
        parser_error_naked(s, c"local declaration requires an explicit type or initializer")
    if value != null and not block_expression(value):
        consume_end_of_statement(s)
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_local(is_let = is_let, name = name_str, stmt_type = stmt_type, value = value,
            else_binding = else_binding, else_body = else_body,
            destructure_bindings = Option[span[str]].none,
            destructure_type_name = Option[str].none, line = ln, column = cn)
    return node


function parse_destructure_bindings(s: ref[pstate.ParserState]) -> Option[span[str]]:
    consume(s, tk.TokenKind.lparen, c"expected '('")
    var bindings = vec.Vec[str].create()
    while true:
        let tok = peek(s) else:
            break
        if check(s, tk.TokenKind.rparen):
            break
        let bt = peek(s) else:
            break
        var name: str
        unsafe:
            name = token_mod.token_lexeme(read(bt), s.source)
        if name == "_":
            advance(s)
            bindings.push("_")
        else:
            consume_name(s, c"expected binding name in destructure pattern")
            bindings.push(previous_lexeme(s))
        if not match_kind(s, tk.TokenKind.comma):
            break
    consume(s, tk.TokenKind.rparen, c"expected ')' after destructure pattern")
    let result = bindings.as_span()
    return Option[span[str]].some(value = result)


function parse_if_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in if")
    var start_ln: ptr_uint
    unsafe:
        start_ln = read(start_tok).line
    var condition = parse_expression(s)
    var then_body = parse_if_branch_body(s)
    var branches = vec.Vec[ast.IfBranch].create()
    var branch = ast.IfBranch(condition = condition, body = then_body, line = start_ln, column = 0)
    branches.push(branch)
    var else_body: ptr[ast.Stmt]? = null
    var else_ln: ptr_uint = 0
    var else_col: ptr_uint = 0
    while check(s, tk.TokenKind.tk_else) and check_next(s, tk.TokenKind.tk_if):
        advance(s)
        advance(s)
        condition = parse_expression(s)
        var elif_body = parse_if_branch_body(s)
        var elif_branch = ast.IfBranch(condition = condition, body = elif_body, line = 0, column = 0)
        branches.push(elif_branch)
    if check(s, tk.TokenKind.tk_else):
        let else_tok = peek(s) else:
            return stmt_error_sentinel(s, c"unexpected eof in else")
        unsafe:
            else_ln = read(else_tok).line
            else_col = read(else_tok).column
        advance(s)
        else_body = parse_else_branch_body(s)
    var branches_span = branches.as_span()
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_if(branches = branches_span, else_body = else_body,
            is_inline = false, line = start_ln, else_line = else_ln, else_column = else_col)
    return node


function parse_if_branch_body(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    consume_or_sync(s, tk.TokenKind.colon, c"expected ':' after if condition")
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented body")
        var body_span = parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of body")
        var node = alloc_stmt(s)
        read(node) = ast.Stmt.stmt_block(statements = body_span)
        return node
    else:
        s.in_inline_block_body = true
        var result = parse_statement(s)
        s.in_inline_block_body = false
        return result


function parse_else_branch_body(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    consume(s, tk.TokenKind.colon, c"expected ':' after else")
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented else body")
        var body_span = parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of else body")
        var node = alloc_stmt(s)
        read(node) = ast.Stmt.stmt_block(statements = body_span)
        return node
    else:
        s.in_inline_block_body = true
        var result = parse_statement(s)
        s.in_inline_block_body = false
        return result


function parse_block_or_inline_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented body")
        var body_span = parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of body")
        var node = alloc_stmt(s)
        read(node) = ast.Stmt.stmt_block(statements = body_span)
        return node
    else:
        s.in_inline_block_body = true
        var result = parse_statement(s)
        s.in_inline_block_body = false
        consume_end_of_statement(s)
        return result


function parse_while_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in while")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var condition = parse_expression(s)
    consume_or_sync(s, tk.TokenKind.colon, c"expected ':' after while condition")
    var is_inline = false
    var body: ptr[ast.Stmt] = alloc_stmt(s)
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented while body")
        var body_span = parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of while body")
        unsafe:
            read(body) = ast.Stmt.stmt_block(statements = body_span)
    else:
        is_inline = true
        body = parse_statement(s)
        consume_end_of_statement(s)
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_while(condition = condition, body = body, is_inline = is_inline, line = ln, column = cn)
    return node


function parse_for_stmt(s: ref[pstate.ParserState], threaded: bool) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in for")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    consume_name(s, c"expected loop variable")
    var bindings = vec.Vec[ast.ForBinding].create()
    var first_binding = ast.ForBinding(name = previous_lexeme(s), line = ln, column = cn)
    bindings.push(first_binding)
    while match_kind(s, tk.TokenKind.comma):
        consume_name(s, c"expected loop variable")
        var b = ast.ForBinding(name = previous_lexeme(s), line = 0, column = 0)
        bindings.push(b)
    consume(s, tk.TokenKind.tk_in, c"expected 'in' after for bindings")
    var iterables = vec.Vec[ast.Expr].create()
    var iter = parse_expression(s)
    unsafe:
        iterables.push(read(iter))
    while match_kind(s, tk.TokenKind.comma):
        var next_iter = parse_expression(s)
        unsafe:
            iterables.push(read(next_iter))
    consume_or_sync(s, tk.TokenKind.colon, c"expected ':' after for iterable")
    var body = alloc_stmt(s)
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented for body")
        var body_span = parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of for body")
        body = alloc_stmt(s)
        unsafe:
            read(body) = ast.Stmt.stmt_block(statements = body_span)
    var bindings_span = bindings.as_span()
    var iterables_span = iterables.as_span()
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_for(bindings = bindings_span, iterables = iterables_span,
            body = body, is_inline = false, threaded = threaded, line = ln, column = cn)
    return node


function parse_match_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    var scrutinee = parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after match expression")
    var is_expr_form = not check(s, tk.TokenKind.newline)
    if is_expr_form:
        var arms = vec.Vec[ast.MatchExprArm].create()
        while true:
            step(s)
            parse_match_expr_arm_into(s, ref_of(arms))
            if not match_kind(s, tk.TokenKind.comma) and not check(s, tk.TokenKind.newline):
                break
        var arms_span = arms.as_span()
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_match(scrutinee = scrutinee, arms = arms_span, line = 0, column = 0)
        var stmt = alloc_stmt(s)
        unsafe:
            read(stmt) = ast.Stmt.stmt_expression(expression = node, line = 0)
        return stmt
    consume(s, tk.TokenKind.newline, c"expected newline after match header")
    consume(s, tk.TokenKind.indent, c"expected indented match body")
    skip_newlines(s)
    var arms = vec.Vec[ast.MatchArm].create()
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        skip_newlines(s)
        parse_match_arm_into(s, ref_of(arms))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of match body")
    var arms_span = arms.as_span()
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_match(scrutinee = scrutinee, arms = arms_span, is_inline = false, line = 0, column = 0)
    return node


function is_wildcard_match(s: ref[pstate.ParserState]) -> bool:
    if not check_name(s):
        return false
    let tok = peek(s) else:
        return false
    unsafe:
        let t = read(tok)
        let lexeme = token_mod.token_lexeme(t, s.source)
        if lexeme == "_":
            advance(s)
            return true
        return false


function parse_match_arm_into(s: ref[pstate.ParserState], arms: ref[vec.Vec[ast.MatchArm]]) -> void:
    var is_wild = false
    var patterns = vec.Vec[ptr[ast.Expr]].create()
    if match_kind(s, tk.TokenKind.tk_else):
        is_wild = true
    else if is_wildcard_match(s):
        is_wild = true
    else:
        patterns.push(parse_pattern(s))
        while match_kind(s, tk.TokenKind.pipe):
            patterns.push(parse_pattern(s))
    var binding_name: Option[str] = Option[str].none
    if match_kind(s, tk.TokenKind.tk_as):
        consume_name(s, c"expected binding name after as")
        binding_name = Option[str].some(value = previous_lexeme(s))
    consume(s, tk.TokenKind.colon, c"expected ':' after match pattern")
    var body = alloc_stmt(s)
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented match arm body")
        var body_span = parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of match arm body")
        body = alloc_stmt(s)
        unsafe:
            read(body) = ast.Stmt.stmt_block(statements = body_span)
    if is_wild:
        arms.push(ast.MatchArm(pattern = null, binding_name = binding_name, binding_line = 0, binding_column = 0, body = body))
        return
    # Expand `p1 | p2 | ...` into one arm per alternative sharing the body.
    var i: ptr_uint = 0
    while i < patterns.len():
        let pp = patterns.get(i) else:
            break
        unsafe:
            arms.push(ast.MatchArm(pattern = read(pp), binding_name = binding_name, binding_line = 0, binding_column = 0, body = body))
        i += 1


function parse_return_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in return")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var value: ptr[ast.Expr]? = null
    if not (check(s, tk.TokenKind.newline) or check(s, tk.TokenKind.dedent)):
        value = parse_expression(s)
    if value != null and not block_expression(value):
        consume_end_of_statement(s)
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_ret(value = value, line = ln, column = cn)
    return node


function parse_defer_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in defer")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var expression: ptr[ast.Expr]? = null
    var body: ptr[ast.Stmt]? = null
    if match_kind(s, tk.TokenKind.colon):
        if match_kind(s, tk.TokenKind.newline):
            consume(s, tk.TokenKind.indent, c"expected indented defer body")
            var body_span = parse_block_body(s)
            consume(s, tk.TokenKind.dedent, c"expected end of defer body")
            var block_node = alloc_stmt(s)
            unsafe:
                read(block_node) = ast.Stmt.stmt_block(statements = body_span)
            body = block_node
        else:
            body = parse_statement(s)
    else:
        expression = parse_expression(s)
        consume_end_of_statement(s)
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_defer(expression = expression, body = body, line = ln, column = cn)
    return node


function parse_unsafe_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in unsafe")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var body: ptr[ast.Stmt] = alloc_stmt(s)
    if match_kind(s, tk.TokenKind.colon):
        if match_kind(s, tk.TokenKind.newline):
            consume(s, tk.TokenKind.indent, c"expected indented unsafe body")
            var body_span = parse_block_body(s)
            consume(s, tk.TokenKind.dedent, c"expected end of unsafe body")
            body = alloc_stmt(s)
            unsafe:
                read(body) = ast.Stmt.stmt_block(statements = body_span)
        else:
            body = parse_statement(s)
    else:
        var expr_val = parse_expression(s)
        consume_end_of_statement(s)
        body = alloc_stmt(s)
        unsafe:
            read(body) = ast.Stmt.stmt_expression(expression = expr_val, line = ln)
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_unsafe(body = body, line = ln, column = cn)
    return node


function parse_static_assert_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    consume(s, tk.TokenKind.lparen, c"expected '(' after static_assert")
    var condition = parse_expression(s)
    consume(s, tk.TokenKind.comma, c"expected ',' after condition")
    var message_expr = parse_expression(s)
    consume(s, tk.TokenKind.rparen, c"expected ')'")
    consume_end_of_statement(s)
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_static_assert(condition = condition, message = message_expr, line = 0)
    return node


function parse_expression_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    var left = parse_expression(s)
    if (
        check(s, tk.TokenKind.equal) or check(s, tk.TokenKind.plus_equal)
        or check(s, tk.TokenKind.minus_equal) or check(s, tk.TokenKind.star_equal)
        or check(s, tk.TokenKind.slash_equal) or check(s, tk.TokenKind.percent_equal)
        or check(s, tk.TokenKind.amp_equal) or check(s, tk.TokenKind.pipe_equal)
        or check(s, tk.TokenKind.caret_equal) or check(s, tk.TokenKind.shift_left_equal)
        or check(s, tk.TokenKind.shift_right_equal)
    ):
        advance(s)
        let op = previous_lexeme(s)
        var right = parse_expression(s)
        if not block_expression(right):
            consume_end_of_statement(s)
        var node = alloc_stmt(s)
        read(node) = ast.Stmt.stmt_assignment(target = left, operator = op, value = right, line = 0, column = 0)
        return node
    if not block_expression(left):
        consume_end_of_statement(s)
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_expression(expression = left, line = 0)
    return node


function parse_parallel_block(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in parallel")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    consume(s, tk.TokenKind.colon, c"expected ':' after parallel")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented parallel body")
    skip_newlines(s)
    var bodies = vec.Vec[ast.Stmt].create()
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        let body_stmt = parse_statement(s)
        unsafe:
            bodies.push(read(body_stmt))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of parallel body")
    var bodies_span = bodies.as_span()
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_parallel_block(bodies = bodies_span, line = ln, column = cn)
    return node


function parse_gather_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    var handles = vec.Vec[ast.Expr].create()
    var first = parse_expression(s)
    unsafe:
        handles.push(read(first))
    while match_kind(s, tk.TokenKind.comma):
        var next_handle = parse_expression(s)
        unsafe:
            handles.push(read(next_handle))
    consume_end_of_statement(s)
    var handles_span = handles.as_span()
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_gather(handles = handles_span, line = 0, column = 0)
    return node


function parse_pattern(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    if check(s, tk.TokenKind.colon) or check(s, tk.TokenKind.newline):
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_error(line = 0, column = 0, message = "empty pattern")
        return node
    # Parse below bitwise-or precedence so a top-level `|` is treated as a
    # pattern alternative separator, not a bitwise-or operator.
    return parse_bitwise_xor(s)


function parse_when_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in when")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var discriminant = parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after when discriminant")
    consume(s, tk.TokenKind.newline, c"expected newline after when header")
    consume(s, tk.TokenKind.indent, c"expected indented when body")
    skip_newlines(s)
    var branches = vec.Vec[ast.WhenBranch].create()
    var else_body: ptr[ast.Stmt]? = null
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        skip_newlines(s)
        if check(s, tk.TokenKind.tk_else):
            advance(s)
            consume(s, tk.TokenKind.colon, c"expected ':' after else")
            else_body = parse_block_or_inline_stmt(s)
            skip_newlines(s)
            break
        var pat = parse_expression(s)
        var binding: Option[str] = Option[str].none
        if match_kind(s, tk.TokenKind.tk_as):
            consume_name(s, c"expected binding name after as")
            binding = Option[str].some(value = previous_lexeme(s))
        consume(s, tk.TokenKind.colon, c"expected ':' after when pattern")
        let branch_body = parse_block_or_inline_stmt(s)
        var wb = ast.WhenBranch(pattern = pat, binding_name = binding, binding_line = 0, binding_column = 0,
            body = stmt_ptr_to_span(s, branch_body))
        branches.push(wb)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of when body")
    var branches_span = branches.as_span()
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_when(discriminant = discriminant, branches = branches_span, else_body = else_body, line = ln, column = cn)
    return node


## Flatten a block/inline statement pointer into a statement span for
## containers (like when-branch bodies) that store span[Stmt].
function stmt_ptr_to_span(s: ref[pstate.ParserState], st: ptr[ast.Stmt]) -> span[ast.Stmt]:
    unsafe:
        match read(st):
            ast.Stmt.stmt_block as b:
                return b.statements
            _:
                var v = vec.Vec[ast.Stmt].create()
                v.push(read(st))
                return v.as_span()


function parse_emit_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in emit")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    let declaration = parse_declaration(s)
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_emit(declaration = declaration, line = ln, column = cn)
    return node


function parse_inline_for_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in inline for")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    consume_name(s, c"expected loop variable")
    var bindings = vec.Vec[ast.ForBinding].create()
    var first_b = ast.ForBinding(name = previous_lexeme(s), line = ln, column = cn)
    bindings.push(first_b)
    while match_kind(s, tk.TokenKind.comma):
        consume_name(s, c"expected loop variable")
        var b = ast.ForBinding(name = previous_lexeme(s), line = 0, column = 0)
        bindings.push(b)
    consume(s, tk.TokenKind.tk_in, c"expected 'in' in for loop")
    var iterables = vec.Vec[ast.Expr].create()
    var iter = parse_expression(s)
    unsafe:
        iterables.push(read(iter))
    while match_kind(s, tk.TokenKind.comma):
        var next_iter = parse_expression(s)
        unsafe:
            iterables.push(read(next_iter))
    consume(s, tk.TokenKind.colon, c"expected ':' after for iterable")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented block")
    var body_span = parse_block_body(s)
    consume(s, tk.TokenKind.dedent, c"expected end of block")
    var bindings_span = bindings.as_span()
    var iterables_span = iterables.as_span()
    var body = alloc_stmt(s)
    unsafe:
        read(body) = ast.Stmt.stmt_block(statements = body_span)
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_for(bindings = bindings_span, iterables = iterables_span,
            body = body, is_inline = true, threaded = false, line = ln, column = cn)
    return node


function parse_inline_while_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in inline while")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var condition = parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after while condition")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented body")
    var body_span = parse_block_body(s)
    consume(s, tk.TokenKind.dedent, c"expected end of body")
    var body = alloc_stmt(s)
    unsafe:
        read(body) = ast.Stmt.stmt_block(statements = body_span)
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_while(condition = condition, body = body, is_inline = true, line = ln, column = cn)
    return node


function parse_inline_match_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in inline match")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var scrutinee = parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after match expression")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented match body")
    skip_newlines(s)
    var arms = vec.Vec[ast.MatchArm].create()
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        skip_newlines(s)
        parse_match_arm_into(s, ref_of(arms))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of match body")
    var arms_span = arms.as_span()
    var node = alloc_stmt(s)
    read(node) = ast.Stmt.stmt_match(scrutinee = scrutinee, arms = arms_span, is_inline = true, line = ln, column = cn)
    return node


function parse_inline_if_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in inline if")
    var start_ln: ptr_uint
    unsafe:
        start_ln = read(start_tok).line
    var condition = parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after if condition")
    var then_body = parse_block_or_inline_stmt(s)
    var branches = vec.Vec[ast.IfBranch].create()
    var branch = ast.IfBranch(condition = condition, body = then_body, line = start_ln, column = 0)
    branches.push(branch)
    var else_body: ptr[ast.Stmt]? = null
    while match_kind(s, tk.TokenKind.tk_else):
        if match_kind(s, tk.TokenKind.tk_if):
            condition = parse_expression(s)
            consume(s, tk.TokenKind.colon, c"expected ':' after elif condition")
            var elif_body = parse_block_or_inline_stmt(s)
            var elif_branch = ast.IfBranch(condition = condition, body = elif_body, line = 0, column = 0)
            branches.push(elif_branch)
        else:
            consume(s, tk.TokenKind.colon, c"expected ':' after else")
            else_body = parse_block_or_inline_stmt(s)
            break
    var branches_span = branches.as_span()
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_if(branches = branches_span, else_body = else_body,
            is_inline = true, line = start_ln, else_line = 0, else_column = 0)
    return node

# =============================================================================
#  Expressions
# =============================================================================

function parse_expression(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    if match_kind(s, tk.TokenKind.tk_if):
        return parse_if_expression(s)
    if match_kind(s, tk.TokenKind.tk_match):
        return parse_match_expression(s)
    if match_kind(s, tk.TokenKind.tk_unsafe):
        return parse_unsafe_expression(s)
    return parse_range(s)


function parse_range(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_or(s)
    if match_kind(s, tk.TokenKind.dot_dot):
        var right = parse_or(s)
        var line_left: ptr_uint = 0
        var col_left: ptr_uint = 0
        let tok = previous_token(s)
        unsafe:
            line_left = tok.line
            col_left = tok.column
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_range(start_expr = left, end_expr = right, line = line_left, column = col_left)
        return node
    return left


function parse_or(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_and(s)
    while match_kind(s, tk.TokenKind.tk_or):
        let op = previous_lexeme(s)
        var right = parse_and(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_and(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_not(s)
    while match_kind(s, tk.TokenKind.tk_and):
        let op = previous_lexeme(s)
        var right = parse_not(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_not(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    if match_kind(s, tk.TokenKind.tk_not):
        let op = previous_lexeme(s)
        var operand = parse_not(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_unary_op(operator = op, operand = operand)
        return node
    return parse_is(s)


function parse_is(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_bitwise_or(s)
    # The arm pattern is parsed at `bitwise_or` precedence (not full expression),
    # so `e is A or e is B` groups as `(e is A) or (e is B)` — matching Ruby's
    # parse_is.  Using parse_expression here would greedily absorb the trailing
    # `or ...` into the pattern.  Left-associative via the `while` loop.
    while match_kind(s, tk.TokenKind.tk_is):
        var pattern = parse_bitwise_or(s)
        left = is_desugar(s, left, pattern)
    return left


function parse_bitwise_or(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_bitwise_xor(s)
    while match_kind(s, tk.TokenKind.pipe):
        let op = previous_lexeme(s)
        var right = parse_bitwise_xor(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_bitwise_xor(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_bitwise_and(s)
    while match_kind(s, tk.TokenKind.caret):
        let op = previous_lexeme(s)
        var right = parse_bitwise_and(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_bitwise_and(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_equality(s)
    while match_kind(s, tk.TokenKind.amp):
        let op = previous_lexeme(s)
        var right = parse_equality(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_equality(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_comparison(s)
    while check(s, tk.TokenKind.equal_equal) or check(s, tk.TokenKind.bang_equal):
        advance(s)
        let op = previous_lexeme(s)
        var right = parse_comparison(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_comparison(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_shift(s)
    while (
        check(s, tk.TokenKind.less) or check(s, tk.TokenKind.less_equal)
        or check(s, tk.TokenKind.greater) or check(s, tk.TokenKind.greater_equal)
    ):
        advance(s)
        let op = previous_lexeme(s)
        var right = parse_shift(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_shift(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_additive(s)
    while check(s, tk.TokenKind.shift_left) or check(s, tk.TokenKind.shift_right):
        advance(s)
        let op = previous_lexeme(s)
        var right = parse_additive(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_additive(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_multiplicative(s)
    while check(s, tk.TokenKind.plus) or check(s, tk.TokenKind.minus):
        advance(s)
        let op = previous_lexeme(s)
        var right = parse_multiplicative(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_multiplicative(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_unary(s)
    while check(s, tk.TokenKind.star) or check(s, tk.TokenKind.slash) or check(s, tk.TokenKind.percent):
        advance(s)
        let op = previous_lexeme(s)
        var right = parse_unary(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_unary(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    if match_kind(s, tk.TokenKind.tk_unsafe):
        return parse_unsafe_expression(s)
    if match_kind(s, tk.TokenKind.tk_await):
        var operand = parse_unary(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_await(expression = operand)
        return node
    if match_kind(s, tk.TokenKind.tk_detach):
        var detach_line: ptr_uint
        var detach_col: ptr_uint
        let dtok = previous_token(s)
        unsafe:
            detach_line = dtok.line
            detach_col = dtok.column
        var expr_val = parse_unary(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_detach(expression = expr_val, line = detach_line, column = detach_col)
        return node
    if check(s, tk.TokenKind.minus) or check(s, tk.TokenKind.tilde) or check(s, tk.TokenKind.plus):
        advance(s)
        let op = previous_lexeme(s)
        var operand = parse_unary(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_unary_op(operator = op, operand = operand)
        return node
    if check(s, tk.TokenKind.tk_out) or check(s, tk.TokenKind.tk_in) or check(s, tk.TokenKind.tk_inout):
        advance(s)
        let op = previous_lexeme(s)
        var operand = parse_unary(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_unary_op(operator = op, operand = operand)
        return node
    var cast_result = try_parse_prefix_cast_expression(s)
    match cast_result:
        Option.some as cast_payload:
            return cast_payload.value
        Option.none:
            pass
    return parse_postfix(s)


function parse_postfix(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_primary(s)
    while true:
        step(s)
        if match_kind(s, tk.TokenKind.dot):
            consume_name_allowing_keywords(s, c"expected member name after '.'")
            let member = previous_lexeme(s)
            let member_tok = previous_token(s)
            var node = alloc_expr(s)
            unsafe:
                let mt = read(member_tok)
                read(node) = ast.Expr.expr_member_access(
                    receiver = left,
                    member_name = member,
                    line = mt.line,
                    column = mt.column,
                )
            left = node
        else if check(s, tk.TokenKind.lbracket):
            if postfix_bracket_starts_specialization(s, left):
                var spec_result = try_parse_specialization(s, left)
                match spec_result:
                    Option.some as spec_val:
                        left = spec_val.value
                    Option.none:
                        advance(s)
                        var idx = parse_expression(s)
                        consume(s, tk.TokenKind.rbracket, c"expected ']'")
                        var node = alloc_expr(s)
                        read(node) = ast.Expr.expr_index_access(receiver = left, index = idx)
                        left = node
            else:
                advance(s)
                var idx = parse_expression(s)
                consume(s, tk.TokenKind.rbracket, c"expected ']'")
                var node = alloc_expr(s)
                read(node) = ast.Expr.expr_index_access(receiver = left, index = idx)
                left = node
        else if match_kind(s, tk.TokenKind.lparen):
            var args = parse_call_args(s)
            consume(s, tk.TokenKind.rparen, c"expected ')'")
            var node = alloc_expr(s)
            read(node) = ast.Expr.expr_call(callee = left, args = args)
            left = node
        else if match_kind(s, tk.TokenKind.question):
            var node = alloc_expr(s)
            read(node) = ast.Expr.expr_unary_op(operator = "?", operand = left)
            left = node
        else:
            break
    return left


function postfix_bracket_starts_specialization(s: ref[pstate.ParserState], left: ptr[ast.Expr]) -> bool:
    return specialization_target(left) and matching_rbracket_index(s, s.stream.current).is_some()


function specialization_target(left: ptr[ast.Expr]) -> bool:
    unsafe:
        let e = read(left)
        return e is ast.Expr.expr_identifier or e is ast.Expr.expr_member_access


function try_parse_specialization(s: ref[pstate.ParserState], left: ptr[ast.Expr]) -> Option[ptr[ast.Expr]]:
    let saved = s.stream.current
    # Speculatively parse the bracket as type arguments; if any error occurs
    # (e.g. the bracket actually holds an index expression like `arr[(a)+1]`),
    # suppress it and revert to index parsing — mirrors Ruby's rescue.
    let saved_suppress = s.suppress_errors
    let saved_flag = s.error_suppressed
    s.suppress_errors = true
    s.error_suppressed = false
    advance(s)
    var args_vec = vec.Vec[ast.TypeArgument].create()
    if not check(s, tk.TokenKind.rbracket):
        while true:
            step(s)
            var arg = parse_type_argument(s)
            var ta = ast.TypeArgument(value = arg)
            args_vec.push(ta)
            if not match_kind(s, tk.TokenKind.comma):
                break
            if check(s, tk.TokenKind.rbracket):
                break
    let closed = match_kind(s, tk.TokenKind.rbracket)
    let had_error = s.error_suppressed
    s.suppress_errors = saved_suppress
    s.error_suppressed = saved_flag
    if not closed or had_error:
        s.stream.current = saved
        return Option[ptr[ast.Expr]].none
    let args_span = args_vec.as_span()
    if match_kind(s, tk.TokenKind.lparen):
        var call_args = parse_call_args(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
        if not specialization_call_target(s, left, args_span, call_args):
            s.stream.current = saved
            return Option[ptr[ast.Expr]].none
        var spec = alloc_expr(s)
        unsafe:
            read(spec) = ast.Expr.expr_specialization(callee = left, arguments = args_span)
        var call = alloc_expr(s)
        unsafe:
            read(call) = ast.Expr.expr_call(callee = spec, args = call_args)
        return Option[ptr[ast.Expr]].some(value = call)
    if not specialization_value_target(s, left, args_span):
        s.stream.current = saved
        return Option[ptr[ast.Expr]].none
    var node = alloc_expr(s)
    read(node) = ast.Expr.expr_specialization(callee = left, arguments = args_span)
    return Option[ptr[ast.Expr]].some(value = node)


# =============================================================================
#  Specialization target disambiguation (mirrors Ruby parser/expressions.rb).
#  Without these checks a value index like `xs[0]` would be mis-parsed as a type
#  specialization; requiring definite/explicit type arguments reverts it to an
#  index access.
# =============================================================================

function is_identifier_named(callee: ptr[ast.Expr], name: str) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return id.name == name
            _:
                return false


function builtin_specialization_target(callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return (
                    id.name == "array" or id.name == "reinterpret" or id.name == "span"
                    or id.name == "zero" or id.name == "ptr" or id.name == "const_ptr"
                    or id.name == "ref" or id.name == "adapt" or id.name == "equal"
                    or id.name == "hash" or id.name == "order"
                )
            _:
                return false


function generic_callable_specialization_target(s: ref[pstate.ParserState], callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return s.known_generic_callable_names.contains(id.name)
            _:
                return false


function imported_member_specialization_target(s: ref[pstate.ParserState], callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as rid:
                        return s.known_import_aliases.contains(rid.name)
                    _:
                        return false
            _:
                return false


function callee_known_type_like(s: ref[pstate.ParserState], callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return known_type_like_name(s, id.name)
            _:
                return false


## A definite type argument: a callable type, or a single name that is a known
## type-like name (builtin type, declared type, alias, import alias, or type
## parameter).  A bare integer such as the `0` in `xs[0]` is not definite.
function definite_type_argument(s: ref[pstate.ParserState], arg: ptr[ast.TypeRef]) -> bool:
    unsafe:
        let t = read(arg)
        if t.is_fn or t.is_proc:
            return true
        if t.name.parts.len >= 1:
            return known_type_like_name(s, read(t.name.parts.data + 0))
        return false


function potential_named_literal_type_argument(arg: ptr[ast.TypeRef]) -> bool:
    unsafe:
        let t = read(arg)
        return t.arguments.len == 0 and not t.nullable


function explicit_specialization_argument(s: ref[pstate.ParserState], arg: ptr[ast.TypeRef]) -> bool:
    if definite_type_argument(s, arg):
        return true
    return potential_named_literal_type_argument(arg)


function all_definite_type_args(s: ref[pstate.ParserState], args: span[ast.TypeArgument]) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        unsafe:
            if not definite_type_argument(s, read(args.data + i).value):
                return false
        i += 1
    return true


function all_explicit_specialization_args(s: ref[pstate.ParserState], args: span[ast.TypeArgument]) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        unsafe:
            if not explicit_specialization_argument(s, read(args.data + i).value):
                return false
        i += 1
    return true


function all_call_args_named(call_args: span[ast.Argument]) -> bool:
    var i: ptr_uint = 0
    while i < call_args.len:
        unsafe:
            match read(call_args.data + i).arg_name:
                Option.some:
                    pass
                Option.none:
                    return false
        i += 1
    return true


## True when the `name[args]` form (no call) is a genuine type specialization
## rather than an index access.
function specialization_value_target(s: ref[pstate.ParserState], callee: ptr[ast.Expr], args: span[ast.TypeArgument]) -> bool:
    if is_identifier_named(callee, "zero") and all_explicit_specialization_args(s, args):
        return true
    if specialization_target(callee) and all_definite_type_args(s, args):
        return true
    if generic_callable_specialization_target(s, callee) and all_explicit_specialization_args(s, args):
        return true
    if imported_member_specialization_target(s, callee) and all_explicit_specialization_args(s, args):
        return true
    return false


## True when the `name[args](call_args)` form is a genuine specialized call.
function specialization_call_target(s: ref[pstate.ParserState], callee: ptr[ast.Expr], args: span[ast.TypeArgument], call_args: span[ast.Argument]) -> bool:
    if (is_identifier_named(callee, "default") or is_identifier_named(callee, "zero")) and not callee_known_type_like(s, callee) and not generic_callable_specialization_target(s, callee):
        return false
    if builtin_specialization_target(callee):
        return true
    if specialization_target(callee) and all_call_args_named(call_args):
        return true
    if generic_callable_specialization_target(s, callee) and all_explicit_specialization_args(s, args):
        return true
    if imported_member_specialization_target(s, callee) and all_explicit_specialization_args(s, args):
        return true
    return specialization_target(callee) and all_definite_type_args(s, args)


function parse_primary(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    if match_kind(s, tk.TokenKind.integer):
        let lex = previous_lexeme(s)
        let val = parse_int_literal(lex)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_integer_literal(lexeme = lex, value = val)
        return node
    else if match_kind(s, tk.TokenKind.float_literal):
        let lex = previous_lexeme(s)
        let val = parse_float_literal(lex)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_float_literal(lexeme = lex, value = val)
        return node
    else if match_kind(s, tk.TokenKind.string):
        let first_tok = previous_token(s)
        var all_lexeme: str
        unsafe:
            all_lexeme = token_mod.token_lexeme(read(first_tok), s.source)
        while check(s, tk.TokenKind.string) or check(s, tk.TokenKind.cstring):
            advance(s)
        let val = parse_string_content(all_lexeme, false)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_string_literal(lexeme = all_lexeme, value = val, is_cstring = false)
        return node
    else if match_kind(s, tk.TokenKind.cstring):
        let first_tok = previous_token(s)
        var all_lexeme: str
        unsafe:
            all_lexeme = token_mod.token_lexeme(read(first_tok), s.source)
        while check(s, tk.TokenKind.string) or check(s, tk.TokenKind.cstring):
            advance(s)
        let val = parse_string_content(all_lexeme, true)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_string_literal(lexeme = all_lexeme, value = val, is_cstring = true)
        return node
    else if match_kind(s, tk.TokenKind.char_literal):
        let lex = previous_lexeme(s)
        let val = parse_char_value(lex)
        let tok = previous_token(s)
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = tok.line
            cn = tok.column
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_char_literal(lexeme = lex, value = val, line = ln, column = cn)
        return node
    else if match_kind(s, tk.TokenKind.tk_true):
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_bool_literal(value = true)
        return node
    else if match_kind(s, tk.TokenKind.tk_false):
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_bool_literal(value = false)
        return node
    else if match_kind(s, tk.TokenKind.tk_null):
        let tok = previous_token(s)
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = tok.line
            cn = tok.column
        var target: ptr[ast.TypeRef]? = null
        if match_kind(s, tk.TokenKind.lbracket):
            target = parse_type_ref(s)
            consume(s, tk.TokenKind.rbracket, c"expected ']' after null type")
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_null_literal(target_type = target, line = ln, column = cn)
        return node
    else if match_name(s):
        let name_str = previous_lexeme(s)
        let tok = previous_token(s)
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = tok.line
            cn = tok.column
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_identifier(name = name_str, line = ln, column = cn)
        return node
    else if match_kind(s, tk.TokenKind.tk_fields_of):
        let tok = previous_token(s)
        var node = alloc_expr(s)
        unsafe:
            let t = read(tok)
            read(node) = ast.Expr.expr_identifier(name = token_mod.token_lexeme(t, s.source), line = t.line, column = t.column)
        return node
    else if match_kind(s, tk.TokenKind.tk_members_of):
        let tok = previous_token(s)
        var node = alloc_expr(s)
        unsafe:
            let t = read(tok)
            read(node) = ast.Expr.expr_identifier(name = token_mod.token_lexeme(t, s.source), line = t.line, column = t.column)
        return node
    else if match_kind(s, tk.TokenKind.tk_attributes_of):
        let tok = previous_token(s)
        var node = alloc_expr(s)
        unsafe:
            let t = read(tok)
            read(node) = ast.Expr.expr_identifier(name = token_mod.token_lexeme(t, s.source), line = t.line, column = t.column)
        return node
    else if match_kind(s, tk.TokenKind.tk_field_of):
        let tok = previous_token(s)
        var node = alloc_expr(s)
        unsafe:
            let t = read(tok)
            read(node) = ast.Expr.expr_identifier(name = token_mod.token_lexeme(t, s.source), line = t.line, column = t.column)
        return node
    else if match_kind(s, tk.TokenKind.tk_callable_of):
        let tok = previous_token(s)
        var node = alloc_expr(s)
        unsafe:
            let t = read(tok)
            read(node) = ast.Expr.expr_identifier(name = token_mod.token_lexeme(t, s.source), line = t.line, column = t.column)
        return node
    else if match_kind(s, tk.TokenKind.tk_attribute_of):
        let tok = previous_token(s)
        var node = alloc_expr(s)
        unsafe:
            let t = read(tok)
            read(node) = ast.Expr.expr_identifier(name = token_mod.token_lexeme(t, s.source), line = t.line, column = t.column)
        return node
    else if match_kind(s, tk.TokenKind.tk_has_attribute):
        let tok = previous_token(s)
        var node = alloc_expr(s)
        unsafe:
            let t = read(tok)
            read(node) = ast.Expr.expr_identifier(name = token_mod.token_lexeme(t, s.source), line = t.line, column = t.column)
        return node
    else if match_kind(s, tk.TokenKind.tk_attribute_arg):
        let tok = previous_token(s)
        var node = alloc_expr(s)
        unsafe:
            let t = read(tok)
            read(node) = ast.Expr.expr_identifier(name = token_mod.token_lexeme(t, s.source), line = t.line, column = t.column)
        return node
    else if match_kind(s, tk.TokenKind.lparen):
        let start_tok = previous_token(s)
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = start_tok.line
            cn = start_tok.column
        var first_expr: ptr[ast.Expr]
        if check_name(s) and check_next(s, tk.TokenKind.equal):
            var name_str: str
            let nt = peek(s) else:
                fatal(c"unexpected eof in named tuple field")
            unsafe:
                name_str = token_mod.token_lexeme(read(nt), s.source)
            advance(s)
            advance(s)
            var val = parse_expression(s)
            first_expr = alloc_expr(s)
            unsafe:
                read(first_expr) = ast.Expr.expr_named(name = name_str, value = val)
        else:
            first_expr = parse_expression(s)
        if match_kind(s, tk.TokenKind.comma):
            var elems = vec.Vec[ast.Expr].create()
            unsafe:
                elems.push(read(first_expr))
            while true:
                step(s)
                if check(s, tk.TokenKind.rparen):
                    break
                if check_name(s) and check_next(s, tk.TokenKind.equal):
                    var name_str: str
                    let nt2 = peek(s) else:
                        break
                    unsafe:
                        name_str = token_mod.token_lexeme(read(nt2), s.source)
                    advance(s)
                    advance(s)
                    var val2 = parse_expression(s)
                    var ne = alloc_expr(s)
                    unsafe:
                        read(ne) = ast.Expr.expr_named(name = name_str, value = val2)
                    unsafe:
                        elems.push(read(ne))
                else:
                    var next = parse_expression(s)
                    unsafe:
                        elems.push(read(next))
                if not match_kind(s, tk.TokenKind.comma):
                    break
                if check(s, tk.TokenKind.rparen):
                    break
            consume(s, tk.TokenKind.rparen, c"expected ')' after tuple elements")
            let elems_span = elems.as_span()
            var node = alloc_expr(s)
            read(node) = ast.Expr.expr_expression_list(elements = elems_span, line = ln, column = cn)
            return node
        consume(s, tk.TokenKind.rparen, c"expected ')' after expression")
        return first_expr
    else if match_kind(s, tk.TokenKind.tk_if):
        return parse_if_expression(s)
    else if match_kind(s, tk.TokenKind.tk_match):
        return parse_match_expression(s)
    else if match_kind(s, tk.TokenKind.tk_proc):
        return parse_proc_expr_after_proc(s)
    else if match_kind(s, tk.TokenKind.tk_size_of):
        consume(s, tk.TokenKind.lparen, c"expected '(' after size_of")
        var type_ref = parse_type_ref(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_sizeof(target_type = type_ref)
        return node
    else if match_kind(s, tk.TokenKind.tk_align_of):
        consume(s, tk.TokenKind.lparen, c"expected '(' after align_of")
        var type_ref = parse_type_ref(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_alignof(target_type = type_ref)
        return node
    else if match_kind(s, tk.TokenKind.tk_offset_of):
        consume(s, tk.TokenKind.lparen, c"expected '(' after offset_of")
        var type_ref = parse_type_ref(s)
        consume(s, tk.TokenKind.comma, c"expected ','")
        consume_name(s, c"expected field name")
        let field_name = previous_lexeme(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_offsetof(target_type = type_ref, field = field_name)
        return node
    else if match_kind(s, tk.TokenKind.fstring):
        let lex = previous_lexeme(s)
        let ftok = pstate.previous_token(s)
        var fline: ptr_uint = 0
        var fcol: ptr_uint = 0
        unsafe:
            fline = read(ftok).line
            fcol = read(ftok).column
        return parse_format_string_expr(s, lex, fline, fcol)
    else if match_kind(s, tk.TokenKind.at):
        consume(s, tk.TokenKind.lbracket, c"expected '[' after @")
        skip_attribute_content(s)
        consume(s, tk.TokenKind.rbracket, c"expected ']' after attribute")
        parser_error_naked(s, c"expected expression")
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_error(line = 0, column = 0, message = "unexpected @[attr] in expression")
        return node
    else:
        let tok_ptr = peek(s) else:
            parser_error_naked(s, c"expected expression")
            var node = alloc_expr(s)
            read(node) = ast.Expr.expr_error(line = 0, column = 0, message = "expected expression")
            return node
        var tok: token_mod.Token
        unsafe:
            tok = read(tok_ptr)
        if is_keyword_token(tok):
            advance(s)
            var ln: ptr_uint = tok.line
            var cn: ptr_uint = tok.column
            var node = alloc_expr(s)
            read(node) = ast.Expr.expr_identifier(name = token_mod.token_lexeme(tok, s.source), line = ln, column = cn)
            return node
        parser_error_naked(s, c"expected expression")
        advance(s)
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_error(line = 0, column = 0, message = "expected expression")
        return node


# =============================================================================
#  If expression
# =============================================================================

function parse_if_expression(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var condition = parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after if condition")
    var then_expr = parse_expression(s)
    consume(s, tk.TokenKind.tk_else, c"expected 'else' in if expression")
    consume(s, tk.TokenKind.colon, c"expected ':' after else")
    var else_expr = parse_expression(s)
    var node = alloc_expr(s)
    read(node) = ast.Expr.expr_if(condition = condition, then_expr = then_expr, else_expr = else_expr)
    return node


# =============================================================================
#  Match expression
# =============================================================================

function parse_match_expression(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var scrutinee = parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after match expression")
    consume(s, tk.TokenKind.newline, c"expected newline after match header")
    consume(s, tk.TokenKind.indent, c"expected indented match body")
    var arms = parse_match_expr_arms(s)
    consume(s, tk.TokenKind.dedent, c"expected end of match body")
    var node = alloc_expr(s)
    read(node) = ast.Expr.expr_match(scrutinee = scrutinee, arms = arms, line = 0, column = 0)
    return node


function parse_match_expr_arms(s: ref[pstate.ParserState]) -> span[ast.MatchExprArm]:
    var arms = vec.Vec[ast.MatchExprArm].create()
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        parse_match_expr_arm_into(s, ref_of(arms))
        skip_newlines(s)
    let result = arms.as_span()
    return result


function parse_match_expr_arm_into(s: ref[pstate.ParserState], arms: ref[vec.Vec[ast.MatchExprArm]]) -> void:
    var is_wild = false
    var patterns = vec.Vec[ptr[ast.Expr]].create()
    if match_kind(s, tk.TokenKind.tk_else):
        is_wild = true
    else if is_wildcard_match(s):
        is_wild = true
    else:
        patterns.push(parse_pattern(s))
        while match_kind(s, tk.TokenKind.pipe):
            patterns.push(parse_pattern(s))
    var binding_name: Option[str] = Option[str].none
    if match_kind(s, tk.TokenKind.tk_as):
        consume_name(s, c"expected binding name after as")
        binding_name = Option[str].some(value = previous_lexeme(s))
    consume(s, tk.TokenKind.colon, c"expected ':' after match pattern")
    var value = parse_expression(s)
    if not block_expression(value):
        consume_end_of_statement(s)
    if is_wild:
        arms.push(ast.MatchExprArm(pattern = null, binding_name = binding_name, binding_line = 0, binding_column = 0, value = value))
        return
    var i: ptr_uint = 0
    while i < patterns.len():
        let pp = patterns.get(i) else:
            break
        unsafe:
            arms.push(ast.MatchExprArm(pattern = read(pp), binding_name = binding_name, binding_line = 0, binding_column = 0, value = value))
        i += 1


# =============================================================================
#  Proc / fn expression
# =============================================================================

function parse_proc_expr_after_proc(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var params = parse_params(s)
    var return_type: ptr[ast.TypeRef]? = null
    if match_kind(s, tk.TokenKind.arrow):
        return_type = parse_type_ref(s)
    var body = parse_proc_body(s)
    var node = alloc_expr(s)
    read(node) = ast.Expr.expr_proc(method_params = params, return_type = return_type, body = body)
    return node


function parse_proc_body(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    if match_kind(s, tk.TokenKind.colon):
        if match_kind(s, tk.TokenKind.newline):
            consume(s, tk.TokenKind.indent, c"expected indented proc body")
            var stmts_span = parse_block_body(s)
            consume(s, tk.TokenKind.dedent, c"expected end of proc body")
            var block = alloc_stmt(s)
            unsafe:
                read(block) = ast.Stmt.stmt_block(statements = stmts_span)
            return block
        else:
            # Expression-body proc: proc() -> T: expr  (implicit return)
            var expr_val = parse_expression(s)
            var ret = alloc_stmt(s)
            unsafe:
                read(ret) = ast.Stmt.stmt_ret(value = expr_val, line = 0, column = 0)
            return ret
    var empty = alloc_stmt(s)
    unsafe:
        read(empty) = ast.Stmt.stmt_block(statements = span[ast.Stmt]())
    return empty


# =============================================================================
#  Unsafe expression
# =============================================================================

function parse_unsafe_expression(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    let tok = previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = tok.line
        cn = tok.column
    consume(s, tk.TokenKind.colon, c"expected ':' after unsafe")
    var expr_val = parse_expression(s)
    var node = alloc_expr(s)
    read(node) = ast.Expr.expr_unsafe(expression = expr_val, line = ln, column = cn)
    return node


# =============================================================================
#  is-operator desugaring
# =============================================================================

function is_desugar(s: ref[pstate.ParserState], left: ptr[ast.Expr], pattern: ptr[ast.Expr]) -> ptr[ast.Expr]:
    # expr is Pattern → match expr: Pattern: true; _: false
    var true_expr = alloc_expr(s)
    unsafe:
        read(true_expr) = ast.Expr.expr_bool_literal(value = true)
    var false_expr = alloc_expr(s)
    unsafe:
        read(false_expr) = ast.Expr.expr_bool_literal(value = false)

    var true_arm: ast.MatchExprArm = ast.MatchExprArm(
        pattern = pattern,
        binding_name = Option[str].none,
        binding_line = 0,
        binding_column = 0,
        value = true_expr
    )
    var false_arm: ast.MatchExprArm = ast.MatchExprArm(
        pattern = null,
        binding_name = Option[str].none,
        binding_line = 0,
        binding_column = 0,
        value = false_expr
    )
    # Build a heap-backed span of two arms (a stack array's span would dangle).
    var arms_vec = vec.Vec[ast.MatchExprArm].create()
    arms_vec.push(true_arm)
    arms_vec.push(false_arm)
    var arms_span = arms_vec.as_span()
    var node = alloc_expr(s)
    read(node) = ast.Expr.expr_match(scrutinee = left, arms = arms_span, line = 0, column = 0)
    return node


# =============================================================================
#  Prefix cast: T<-expr
# =============================================================================

function try_parse_prefix_cast_expression(s: ref[pstate.ParserState]) -> Option[ptr[ast.Expr]]:
    if not check_name(s):
        return Option[ptr[ast.Expr]].none
    let name_tok = peek(s) else:
        return Option[ptr[ast.Expr]].none
    var name_str: str
    unsafe:
        name_str = token_mod.token_lexeme(read(name_tok), s.source)
    if not known_type_like_name(s, name_str):
        return Option[ptr[ast.Expr]].none
    var saved = s.stream.current
    var target_type = parse_named_type_ref(s, true)
    if not check(s, tk.TokenKind.less):
        s.stream.current = saved
        return Option[ptr[ast.Expr]].none
    if not check_next(s, tk.TokenKind.minus):
        s.stream.current = saved
        return Option[ptr[ast.Expr]].none
    let lt_idx = s.stream.current
    advance(s)
    advance(s)
    var lt_opt = s.stream.tokens.get(lt_idx)
    var mn_opt = s.stream.tokens.get(lt_idx + 1)
    if lt_opt != null and mn_opt != null:
        unsafe:
            if read(lt_opt).end_offset != read(mn_opt).start_offset:
                s.stream.current = saved
                return Option[ptr[ast.Expr]].none
    var expr_val = parse_unary(s)
    var node = alloc_expr(s)
    var cast_line: ptr_uint = 0
    var cast_column: ptr_uint = 0
    unsafe:
        cast_line = read(name_tok).line
        cast_column = read(name_tok).column
    read(node) = ast.Expr.expr_prefix_cast(target_type = target_type, expression = expr_val, line = cast_line, column = cast_column)
    return Option[ptr[ast.Expr]].some(value = node)


# =============================================================================
#  Call arguments (producing)
# =============================================================================

function parse_call_args(s: ref[pstate.ParserState]) -> span[ast.Argument]:
    var args = vec.Vec[ast.Argument].create()
    if check(s, tk.TokenKind.rparen):
        return span[ast.Argument]()
    while true:
        step(s)
        if check(s, tk.TokenKind.rparen):
            break
        if check_name(s) and check_next(s, tk.TokenKind.equal):
            let name_tok = peek(s) else:
                break
            var arg_name: str
            unsafe:
                arg_name = token_mod.token_lexeme(read(name_tok), s.source)
            advance(s)
            advance(s)
            var val = parse_expression(s)
            var arg = ast.Argument(arg_name = Option[str].some(value = arg_name), arg_value = val)
            args.push(arg)
        else:
            var val = parse_expression(s)
            var arg = ast.Argument(arg_name = Option[str].none, arg_value = val)
            args.push(arg)
        if not match_kind(s, tk.TokenKind.comma):
            break
        if check(s, tk.TokenKind.rparen):
            break
    let result = args.as_span()
    return result


function parse_struct_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected struct name")
    let name = previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    if match_kind(s, tk.TokenKind.lbracket):
        type_params = parse_declaration_type_params(s)
    var impl_list = span[ast.QualifiedName]()
    if match_kind(s, tk.TokenKind.tk_implements):
        impl_list = parse_implements_list(s)
    let c_name = parse_optional_c_name(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after struct name")
    consume(s, tk.TokenKind.newline, c"expected newline")
    skip_newlines(s)
    consume(s, tk.TokenKind.indent, c"expected indented struct body")
    skip_newlines(s)
    var fields = vec.Vec[ast.Field].create()
    var events = vec.Vec[ast.Decl].create()
    var nested = vec.Vec[ast.Decl].create()
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        let member_attrs = parse_attribute_applications(s)
        let member_vis = match_kind(s, tk.TokenKind.tk_public)
        if match_kind(s, tk.TokenKind.tk_event):
            unsafe:
                events.push(read(parse_event_decl(s, member_attrs, member_vis)))
        else if match_kind(s, tk.TokenKind.tk_struct):
            unsafe:
                nested.push(read(parse_struct_decl(s, member_attrs, member_vis)))
        else:
            fields.push(parse_struct_member(s, member_attrs))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of struct body")
    var packed = false
    var alignment: int = 0
    extract_layout_attributes(attrs, ref_of(packed), ref_of(alignment))
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_struct(name = name, type_params = type_params, impl_list = impl_list,
            c_name = c_name, struct_fields = fields.as_span(), struct_events = events.as_span(),
            nested_types = nested.as_span(), struct_attrs = attrs, packed = packed, alignment = alignment,
            visibility = visibility, lifetime_params = span[ast.TypeParam](), line = ln, column = cn)
    return node


## Extract the built-in layout attributes from a declaration's attribute list:
## `@[packed]` sets `packed`; `@[align(N)]` with an integer-literal argument
## sets `alignment`.  Other attributes are user-defined and stay in the generic
## attribute list.
function extract_layout_attributes(attrs: span[ast.AttributeApplication], packed: ref[bool], alignment: ref[int]) -> void:
    var i: ptr_uint = 0
    while i < attrs.len:
        var applied: ast.AttributeApplication
        unsafe:
            applied = read(attrs.data + i)
        if applied.name.parts.len == 1:
            let attr_name = unsafe: read(applied.name.parts.data + 0)
            if attr_name == "packed":
                read(packed) = true
            if attr_name == "align" and applied.arguments.len == 1:
                unsafe:
                    match read(read(applied.arguments.data + 0).arg_value):
                        ast.Expr.expr_integer_literal as lit:
                            read(alignment) = int<-lit.value
                        _:
                            pass
        i += 1


function parse_struct_member(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication]) -> ast.Field:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected field name")
    let name = previous_lexeme(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after field name")
    let ftype = parse_type_ref(s)
    consume_end_of_statement(s)
    unsafe:
        return ast.Field(name = name, field_type = read(ftype), attributes = attrs, line = ln, column = cn)


## Parse a comma-separated `implements A, B` list (the `implements` keyword is
## consumed by the caller).  Generic type-arguments on each name are skipped,
## matching Ruby's QualifiedName rendering.
function parse_implements_list(s: ref[pstate.ParserState]) -> span[ast.QualifiedName]:
    var list = vec.Vec[ast.QualifiedName].create()
    while true:
        list.push(parse_qualified_name(s))
        if match_kind(s, tk.TokenKind.lbracket):
            var depth: int = 1
            while not eof(s) and depth > 0:
                if check(s, tk.TokenKind.lbracket):
                    depth += 1
                else if check(s, tk.TokenKind.rbracket):
                    depth -= 1
                advance(s)
        if not match_kind(s, tk.TokenKind.comma):
            break
    return list.as_span()


function parse_type_alias(s: ref[pstate.ParserState], visibility: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected type alias name")
    let name = previous_lexeme(s)
    consume(s, tk.TokenKind.equal, c"expected '=' after type alias name")
    let target = parse_type_ref(s)
    consume_end_of_statement(s)
    var node = alloc_decl(s)
    read(node) = ast.Decl.decl_type_alias(name = name, target = target, visibility = visibility, line = ln, column = cn)
    return node


function make_int_type_ref(s: ref[pstate.ParserState], ln: ptr_uint, cn: ptr_uint) -> ptr[ast.TypeRef]:
    var parts = vec.Vec[str].create()
    parts.push("int")
    var node = heap_mod.must_alloc[ast.TypeRef](1)
    unsafe:
        read(node) = ast.TypeRef(
            name = ast.QualifiedName(parts = parts.as_span(), type_arguments = span[ast.TypeRef](), line = ln, column = cn),
            arguments = span[ast.TypeRef](), nullable = false,
            lifetime = Option[str].none, line = ln, column = cn,
            fn_params = span[ast.Param](), fn_return = null,
            is_proc = false, is_fn = false,
            dyn_interface = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef]()),
            is_dyn = false, is_tuple = false
        )
    return node


function make_int_literal(s: ref[pstate.ParserState], value: int) -> ptr[ast.Expr]:
    var node = alloc_expr(s)
    read(node) = ast.Expr.expr_integer_literal(lexeme = int_to_dec(value), value = value)
    return node


## Advance the enum auto-increment counter after an explicit member value,
## matching the Ruby parser: a plain integer literal sets the counter to
## value+1, and a negated integer literal (`-3`) to -value+1; any other
## expression leaves the counter unchanged.
function enum_auto_after(value: ptr[ast.Expr], current: int) -> int:
    unsafe:
        match read(value):
            ast.Expr.expr_integer_literal as lit:
                return int<-(lit.value + 1)
            ast.Expr.expr_unary_op as un:
                if un.operator == "-":
                    match read(un.operand):
                        ast.Expr.expr_integer_literal as lit2:
                            return int<-(-lit2.value + 1)
                        _:
                            return current
                return current
            _:
                return current


function int_to_dec(value: int) -> str:
    if value == 0:
        return "0"
    var negative = value < 0
    var n = value
    if negative:
        n = -n
    var digits = string.String.create()
    while n > 0:
        let d = n % 10
        digits.push_byte(ubyte<-(d + 48))
        n = n / 10
    var rev = string.String.create()
    if negative:
        rev.push_byte(ubyte<-45)
    let raw = digits.as_str()
    var i = raw.len
    while i > 0:
        i -= 1
        rev.push_byte(raw.byte_at(i))
    return rev.as_str()


function parse_enum_decl(s: ref[pstate.ParserState], is_flags: bool, attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected enum name")
    let name = previous_lexeme(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after enum name")
    var backing_type: ptr[ast.TypeRef]? = null
    if check(s, tk.TokenKind.newline) or check(s, tk.TokenKind.indent):
        backing_type = make_int_type_ref(s, ln, cn)
    else:
        backing_type = parse_type_ref(s)
    consume(s, tk.TokenKind.newline, c"expected newline")
    skip_newlines(s)
    consume(s, tk.TokenKind.indent, c"expected indented enum body")
    skip_newlines(s)
    var members = vec.Vec[ast.EnumMember].create()
    var auto_value: int = 0
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        let mtok = peek(s)
        var mln: ptr_uint = 0
        var mcn: ptr_uint = 0
        if mtok != null:
            unsafe:
                mln = read(mtok).line
                mcn = read(mtok).column
        consume_name(s, c"expected member name")
        let mname = previous_lexeme(s)
        var mvalue: ptr[ast.Expr]? = null
        if match_kind(s, tk.TokenKind.equal):
            let explicit = parse_expression(s)
            mvalue = explicit
            auto_value = enum_auto_after(explicit, auto_value)
        else:
            mvalue = make_int_literal(s, auto_value)
            auto_value += 1
        consume_end_of_statement(s)
        members.push(ast.EnumMember(name = mname, value = mvalue, line = mln, column = mcn))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of enum body")
    var node = alloc_decl(s)
    let members_span = members.as_span()
    unsafe:
        if is_flags:
            read(node) = ast.Decl.decl_flags(name = name, backing_type = backing_type, flags_members = members_span,
                visibility = visibility, flags_attrs = attrs, line = ln, column = cn)
        else:
            read(node) = ast.Decl.decl_enum(name = name, backing_type = backing_type, enum_members = members_span,
                visibility = visibility, enum_attrs = attrs, line = ln, column = cn)
    return node


function parse_variant_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected variant name")
    let name = previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    if match_kind(s, tk.TokenKind.lbracket):
        type_params = parse_declaration_type_params(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after variant name")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented variant body")
    skip_newlines(s)
    var arms = vec.Vec[ast.VariantArm].create()
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        consume_name(s, c"expected arm name")
        let arm_name = previous_lexeme(s)
        var arm_fields = span[ast.Field]()
        if match_kind(s, tk.TokenKind.lparen):
            arm_fields = parse_variant_arm_fields(s)
        consume_end_of_statement(s)
        arms.push(ast.VariantArm(name = arm_name, arm_fields = arm_fields))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of variant body")
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_variant(name = name, type_params = type_params, variant_arms = arms.as_span(),
            visibility = visibility, variant_attrs = attrs, line = ln, column = cn)
    return node


function parse_variant_arm_fields(s: ref[pstate.ParserState]) -> span[ast.Field]:
    var fields = vec.Vec[ast.Field].create()
    while not check(s, tk.TokenKind.rparen) and not eof(s):
        let tok = peek(s)
        var ln: ptr_uint = 0
        var cn: ptr_uint = 0
        if tok != null:
            unsafe:
                ln = read(tok).line
                cn = read(tok).column
        consume_name(s, c"expected field name in variant arm")
        let fname = previous_lexeme(s)
        consume(s, tk.TokenKind.colon, c"expected ':' after field name")
        let ftype = parse_type_ref(s)
        unsafe:
            fields.push(ast.Field(name = fname, field_type = read(ftype),
                attributes = span[ast.AttributeApplication](), line = ln, column = cn))
        if not match_kind(s, tk.TokenKind.comma):
            break
    consume(s, tk.TokenKind.rparen, c"expected ')' after variant arm fields")
    return fields.as_span()


function parse_interface_decl(s: ref[pstate.ParserState], visibility: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected interface name")
    let name = previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    if match_kind(s, tk.TokenKind.lbracket):
        type_params = parse_declaration_type_params(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after interface name")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented interface body")
    skip_newlines(s)
    var methods = vec.Vec[ast.InterfaceMethod].create()
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        methods.push(parse_interface_method(s))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of interface body")
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_interface(name = name, type_params = type_params,
            interface_methods = methods.as_span(), visibility = visibility, line = ln, column = cn)
    return node


function parse_interface_method(s: ref[pstate.ParserState]) -> ast.InterfaceMethod:
    var is_async = match_kind(s, tk.TokenKind.tk_async)
    var kind = ast.MethodKind.mk_plain
    if match_kind(s, tk.TokenKind.tk_editable):
        kind = ast.MethodKind.mk_editable
    else if match_kind(s, tk.TokenKind.tk_static):
        kind = ast.MethodKind.mk_static
    consume(s, tk.TokenKind.tk_function, c"expected function in interface")
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected method name")
    let name = previous_lexeme(s)
    let params = parse_params(s)
    var return_type: ptr[ast.TypeRef]? = null
    if match_kind(s, tk.TokenKind.arrow):
        return_type = parse_type_ref(s)
    consume_end_of_statement(s)
    return ast.InterfaceMethod(name = name, method_params = params, return_type = return_type,
        method_kind = kind, is_async = is_async, attributes = span[ast.AttributeApplication](), line = ln, column = cn)


function parse_opaque_decl(s: ref[pstate.ParserState], visibility: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected opaque type name")
    let name = previous_lexeme(s)
    var impl_list = span[ast.QualifiedName]()
    if match_kind(s, tk.TokenKind.tk_implements):
        impl_list = parse_implements_list(s)
    let c_name = parse_optional_c_name(s)
    consume_end_of_statement(s)
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_opaque(name = name, opaque_implements = impl_list, c_name = c_name,
            visibility = visibility, line = ln, column = cn)
    return node


function parse_extending_block(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    let type_name = parse_type_ref(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after extending type")
    consume(s, tk.TokenKind.newline, c"expected newline")
    skip_newlines(s)
    consume(s, tk.TokenKind.indent, c"expected indented extending body")
    skip_newlines(s)
    var methods = vec.Vec[ast.Method].create()
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        methods.push(parse_extending_method(s))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of extending body")
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_extending_block(type_name = type_name, methods = methods.as_span(),
            line = ln, column = cn)
    return node


function parse_extending_method(s: ref[pstate.ParserState]) -> ast.Method:
    let attrs = parse_attribute_applications(s)
    var visibility = match_kind(s, tk.TokenKind.tk_public)
    var is_async = match_kind(s, tk.TokenKind.tk_async)
    var kind = ast.MethodKind.mk_plain
    if match_kind(s, tk.TokenKind.tk_editable):
        kind = ast.MethodKind.mk_editable
    else if match_kind(s, tk.TokenKind.tk_static):
        kind = ast.MethodKind.mk_static
    consume(s, tk.TokenKind.tk_function, c"expected function in extending block")
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected method name")
    let name = previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    if match_kind(s, tk.TokenKind.lbracket):
        type_params = parse_declaration_type_params(s)
    let params = parse_params(s)
    var return_type: ptr[ast.TypeRef]? = null
    if match_kind(s, tk.TokenKind.arrow):
        return_type = parse_type_ref(s)
    let body = parse_block(s)
    return ast.Method(name = name, type_params = type_params, method_params = params,
        return_type = return_type, body = body, method_kind = kind, visibility = visibility,
        is_async = is_async, attributes = attrs, line = ln, column = cn)


function parse_extern_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication]) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
    consume_name(s, c"expected function name")
    let name = previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    if match_kind(s, tk.TokenKind.lbracket):
        type_params = parse_declaration_type_params(s)
    let (params, variadic) = parse_foreign_params(s)
    var return_type: ptr[ast.TypeRef]? = null
    if match_kind(s, tk.TokenKind.arrow):
        return_type = parse_type_ref(s)
    var mapping: ptr[ast.Expr]? = null
    if match_kind(s, tk.TokenKind.equal):
        mapping = parse_expression(s)
    consume_end_of_statement(s)
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_extern_function(name = name, type_params = type_params, extern_params = params,
            return_type = return_type, variadic = variadic, attrs = attrs, line = ln, mapping = mapping)
    return node


function parse_foreign_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
    consume_name(s, c"expected function name")
    let name = previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    if match_kind(s, tk.TokenKind.lbracket):
        type_params = parse_declaration_type_params(s)
    let (params, variadic) = parse_foreign_params(s)
    consume(s, tk.TokenKind.arrow, c"expected '->' before foreign return type")
    let return_type = parse_type_ref(s)
    consume(s, tk.TokenKind.equal, c"expected '=' before foreign mapping")
    let mapping = parse_expression(s)
    consume_end_of_statement(s)
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_foreign_function(name = name, type_params = type_params, foreign_params = params,
            return_type = return_type, variadic = variadic, mapping = mapping, visibility = visibility,
            attrs = attrs, line = ln)
    return node


function parse_foreign_params(s: ref[pstate.ParserState]) -> (span[ast.ForeignParam], bool):
    var params = vec.Vec[ast.ForeignParam].create()
    var variadic = false
    consume(s, tk.TokenKind.lparen, c"expected '('")
    while not eof(s) and not check(s, tk.TokenKind.rparen):
        if match_kind(s, tk.TokenKind.ellipsis):
            variadic = true
            break
        var mode = ast.ForeignParamMode.fmode_plain
        if match_kind(s, tk.TokenKind.tk_out):
            mode = ast.ForeignParamMode.fmode_out
        else if match_kind(s, tk.TokenKind.tk_in):
            mode = ast.ForeignParamMode.fmode_in
        else if match_kind(s, tk.TokenKind.tk_inout):
            mode = ast.ForeignParamMode.fmode_inout
        else if match_kind(s, tk.TokenKind.tk_consuming):
            mode = ast.ForeignParamMode.fmode_consuming
        consume_name(s, c"expected parameter name")
        let name = previous_lexeme(s)
        consume(s, tk.TokenKind.colon, c"expected ':' after parameter name")
        let ptype = parse_type_ref(s)
        var boundary_type: Option[ast.TypeRef] = Option[ast.TypeRef].none
        if match_kind(s, tk.TokenKind.tk_as):
            let bt = parse_type_ref(s)
            unsafe:
                boundary_type = Option[ast.TypeRef].some(value = read(bt))
        unsafe:
            params.push(ast.ForeignParam(name = name, param_type = read(ptype), param_mode = mode,
                boundary_type = boundary_type))
        if not match_kind(s, tk.TokenKind.comma):
            break
    consume(s, tk.TokenKind.rparen, c"expected ')'")
    return (params.as_span(), variadic)


function parse_static_assert(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
    consume(s, tk.TokenKind.lparen, c"expected '(' after static_assert")
    let condition = parse_expression(s)
    consume(s, tk.TokenKind.comma, c"expected ',' after condition")
    let message = parse_expression(s)
    consume(s, tk.TokenKind.rparen, c"expected ')'")
    consume_end_of_statement(s)
    var node = alloc_decl(s)
    read(node) = ast.Decl.decl_static_assert(condition = condition, message = message, line = ln)
    return node


function parse_event_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume_name(s, c"expected event name")
    let name = previous_lexeme(s)
    consume(s, tk.TokenKind.lbracket, c"expected '[' after event name")
    consume(s, tk.TokenKind.integer, c"expected capacity")
    let capacity = int<-parse_int_literal(previous_lexeme(s))
    consume(s, tk.TokenKind.rbracket, c"expected ']'")
    var payload_type: ptr[ast.TypeRef]? = null
    if match_kind(s, tk.TokenKind.lparen):
        payload_type = parse_type_ref(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
    consume_end_of_statement(s)
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_event(name = name, capacity = capacity, payload_type = payload_type,
            visibility = visibility, attrs = attrs, line = ln, column = cn)
    return node


function parse_when_decl(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    let discriminant = parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after when discriminant")
    consume(s, tk.TokenKind.newline, c"expected newline after when header")
    consume(s, tk.TokenKind.indent, c"expected indented when body")
    skip_newlines(s)
    var branches = vec.Vec[ast.WhenDeclBranch].create()
    var else_body = span[ast.Decl]()
    var has_else = false
    while not eof(s):
        if check(s, tk.TokenKind.dedent):
            break
        skip_newlines(s)
        if check(s, tk.TokenKind.tk_else):
            advance(s)
            consume(s, tk.TokenKind.colon, c"expected ':' after else")
            else_body = parse_declaration_block(s)
            has_else = true
            break
        let pat = parse_expression(s)
        var binding: Option[str] = Option[str].none
        if match_kind(s, tk.TokenKind.tk_as):
            consume_name(s, c"expected binding name after as")
            binding = Option[str].some(value = previous_lexeme(s))
        consume(s, tk.TokenKind.colon, c"expected ':' after when pattern")
        let body = parse_declaration_block(s)
        branches.push(ast.WhenDeclBranch(pattern = pat, binding_name = binding, binding_line = 0,
            binding_column = 0, body = body))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of when body")
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_when(discriminant = discriminant, branches = branches.as_span(),
            else_body = else_body, has_else = has_else, line = ln, column = cn)
    return node


function parse_declaration_block(s: ref[pstate.ParserState]) -> span[ast.Decl]:
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented body")
    skip_newlines(s)
    var decls = vec.Vec[ast.Decl].create()
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        step(s)
        unsafe:
            decls.push(read(parse_declaration(s)))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of body")
    return decls.as_span()


function parse_attribute_decl(s: ref[pstate.ParserState], visibility: bool) -> ptr[ast.Decl]:
    let tok = peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    consume(s, tk.TokenKind.lbracket, c"expected '[' after attribute")
    var targets = vec.Vec[str].create()
    while true:
        consume_name_allowing_keywords(s, c"expected attribute target")
        targets.push(previous_lexeme(s))
        if not match_kind(s, tk.TokenKind.comma):
            break
    consume(s, tk.TokenKind.rbracket, c"expected ']'")
    consume_name_allowing_keywords(s, c"expected attribute name")
    let name = previous_lexeme(s)
    var params = span[ast.Param]()
    if check(s, tk.TokenKind.lparen):
        params = parse_signature(s)
    consume_end_of_statement(s)
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_attribute(name = name, targets = targets.as_span(), attr_params = params,
            visibility = visibility, line = ln, column = cn)
    return node


function parse_signature(s: ref[pstate.ParserState]) -> span[ast.Param]:
    var params = vec.Vec[ast.Param].create()
    consume(s, tk.TokenKind.lparen, c"expected '('")
    while not eof(s) and not check(s, tk.TokenKind.rparen):
        let tok = peek(s)
        var ln: ptr_uint = 0
        var cn: ptr_uint = 0
        if tok != null:
            unsafe:
                ln = read(tok).line
                cn = read(tok).column
        consume_name(s, c"expected parameter name")
        let name = previous_lexeme(s)
        consume(s, tk.TokenKind.colon, c"expected ':' after parameter name")
        let ptype = parse_type_ref(s)
        unsafe:
            params.push(ast.Param(name = name, param_type = read(ptype), line = ln, column = cn))
        if not match_kind(s, tk.TokenKind.comma):
            break
    consume(s, tk.TokenKind.rparen, c"expected ')'")
    return params.as_span()
