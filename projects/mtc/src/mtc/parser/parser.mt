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
import mtc.lexer.lexer as lexer_mod
import mtc.parser.token_stream as ts
import mtc.parser.ast as ast
import mtc.parser.state as pstate
import mtc.parser.literal_parsing as lparse
import mtc.parser.statements as statements
import mtc.parser.expressions as expressions
import mtc.parser.declarations as declarations
import mtc.parser.decl_forms as decl_forms


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


public function consume_or_sync(s: ref[pstate.ParserState], kind: tk.TokenKind, msg: cstr) -> void:
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
        statements.parse_statement(s)
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
        statements.parse_match_arm_into(s, ref_of(recover_arms))
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

## Rewind to the first error's token and clear the panic — the host's exception
## unwinding, emulated: the recovery points below then synchronize from the
## error's own position, exactly as `synchronize_to_*_boundary` would after a
## raised ParseError.
function rewind_to_panic(s: ref[pstate.ParserState]) -> void:
    s.stream.current = s.panic_index
    s.panic = false


## The `expr_error` the host substitutes for a failed initializer
## (`recovery_error_expr`): positioned at the error's own token.
public function panic_error_expr(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var node = alloc_expr(s)
    unsafe:
        read(node) = ast.Expr.expr_error(line = s.panic_line, column = s.panic_column, message = str.cstr_as_str(s.panic_message))
    return node


## Drop the partial statement and resume at the next statement boundary
## (host: `parse_statement_block_body`'s rescue).
public function recover_statement(s: ref[pstate.ParserState]) -> void:
    rewind_to_panic(s)
    synchronize_to_statement_boundary(s)


## Drop the partial declaration and resume at the next top-level boundary
## (host: `parse_source_file`'s rescue).
public function recover_top_level(s: ref[pstate.ParserState]) -> void:
    rewind_to_panic(s)
    synchronize_to_top_level_boundary(s)


## Drop the partial match arm and resume at the next arm boundary
## (host: `parse_match_arm_body`'s rescue).
public function recover_match_arm(s: ref[pstate.ParserState]) -> void:
    rewind_to_panic(s)
    synchronize_to_match_arm_boundary(s)


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

public function eof(s: ref[pstate.ParserState]) -> bool:
    return ts.eof(ref_of(s.stream))

public function skip_newlines(s: ref[pstate.ParserState]) -> void:
    ts.skip_newlines(ref_of(s.stream))

public function check_name(s: ref[pstate.ParserState]) -> bool:
    return check(s, tk.TokenKind.identifier)

public function match_name(s: ref[pstate.ParserState]) -> bool:
    if check_name(s):
        advance(s)
        return true
    return false

public function consume_name(s: ref[pstate.ParserState], msg: cstr) -> void:
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

public function consume_name_allowing_keywords(s: ref[pstate.ParserState], msg: cstr) -> void:
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

public function consume_end_of_statement(s: ref[pstate.ParserState]) -> void:
    if s.in_inline_block_body:
        return
    if not check(s, tk.TokenKind.newline):
        parser_error_naked(s, c"expected end of statement")
        return
    advance(s)

public function is_keyword_token(tok: token_mod.Token) -> bool:
    # Keyword token kinds all have the tk_ prefix (values 51-122).
    # Tokens that are truly identifiers have TokenKind.identifier.
    return tok.kind >= tk.TokenKind.tk_align_of

public function previous_lexeme(s: ref[pstate.ParserState]) -> str:
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


public function check_next(s: ref[pstate.ParserState], kind: tk.TokenKind) -> bool:
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


public function block_expr(expr: ptr[ast.Expr]?) -> bool:
    if expr == null:
        return false
    unsafe:
        let e = read(expr)
        return e is ast.Expr.expr_proc or e is ast.Expr.expr_match or e is ast.Expr.expr_if


public function matching_rbracket_index(s: ref[pstate.ParserState], start_index: ptr_uint) -> Option[ptr_uint]:
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

public function parse_int_literal(lexeme: str) -> long:
    return lparse.parse_int_literal(lexeme)


function parse_float_literal(lexeme: str) -> double:
    return lparse.parse_float_literal(lexeme)


public function parse_string_content(lexeme: str, is_cstring: bool) -> str:
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
            let start_pos = fmt_content_position(content, expr_start, line, column + 2)
            let embedded = parse_embedded_expr(s, src, start_pos.line, start_pos.column)
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
## Absolute position of `content[j]`, given the position of `content[0]`.
public struct FmtPos:
    line: ptr_uint
    column: ptr_uint


function fmt_content_position(content: str, j: ptr_uint, base_line: ptr_uint, base_column: ptr_uint) -> FmtPos:
    var nl_count: ptr_uint = 0
    var last_nl: int = -1
    var k: ptr_uint = 0
    while k < j:
        if content.byte_at(k) == 10:
            nl_count += 1
            last_nl = int<-k
        k += 1
    if nl_count == 0:
        return FmtPos(line = base_line, column = base_column + j)
    return FmtPos(line = base_line + nl_count, column = ptr_uint<-(int<-j - last_nl))


## Parse an interpolation's source with positions offset to the format string's
## location: pad the sub-source with the leading newlines/spaces the lexer needs
## to report absolute line/column, then drop the synthetic indentation tokens.
function parse_embedded_expr(s: ref[pstate.ParserState], source: str, line: ptr_uint, column: ptr_uint) -> ptr[ast.Expr]:
    var padded = string.String.create()
    var n: ptr_uint = 0
    while n + 1 < line:
        padded.push_byte('\n')
        n += 1
    var c: ptr_uint = 0
    while c + 1 < column:
        padded.push_byte(' ')
        c += 1
    padded.append(source)
    # `padded` is deliberately retained: the parsed expression's string views
    # (identifiers, literal lexemes) point into `padded_source`.
    let padded_source = padded.as_str()
    var raw_tokens = lexer_mod.lex(padded_source)
    var tokens = vec.Vec[token_mod.Token].create()
    var skipping = true
    var ti: ptr_uint = 0
    while ti < raw_tokens.len():
        let t = raw_tokens.get(ti) else:
            break
        unsafe:
            let kind = read(t).kind
            if skipping and (kind == tk.TokenKind.indent or kind == tk.TokenKind.newline or kind == tk.TokenKind.dedent):
                ti += 1
                continue
            skipping = false
            tokens.push(read(t))
        ti += 1
    raw_tokens.release()
    var sub = pstate.ParserState(
        stream = ts.create(tokens),
        source = padded_source,
        step_counter = 0,
        in_inline_block_body = false,
        recovery_errors = s.recovery_errors,
        known_type_names = s.known_type_names,
        known_import_aliases = s.known_import_aliases,
        known_generic_callable_names = s.known_generic_callable_names,
        current_type_param_names = s.current_type_param_names,
        suppress_errors = s.suppress_errors,
        total_steps = 0,
        error_suppressed = false,
        panic = false,
        panic_index = 0,
        panic_line = 0,
        panic_column = 0,
        panic_message = c"",
        pending_decls = vec.Vec[ast.Decl].create(),
    )
    tokens.release()
    let parsed = expressions.parse_expr(ref_of(sub))
    sub.stream.tokens.release()
    sub.pending_decls.release()
    return parsed


function append_escaped_byte(buf: ref[string.String], ch: ubyte) -> void:
    lparse.append_escaped_byte(buf, ch)


# =============================================================================
#  AST node allocation
# =============================================================================

public function alloc_expr(s: ref[pstate.ParserState]) -> own[ast.Expr]:
    return heap_mod.must_alloc[ast.Expr](1)

public function alloc_stmt(s: ref[pstate.ParserState]) -> own[ast.Stmt]:
    return heap_mod.must_alloc[ast.Stmt](1)

public function alloc_decl(s: ref[pstate.ParserState]) -> own[ast.Decl]:
    return heap_mod.must_alloc[ast.Decl](1)


## Release a finished parser state's owned scratch: the token stream copy, the
## known-name lookup maps, the type-parameter name list and the pending
## declaration buffer.  The AST holds no references into any of them — token
## lexemes are views into the source text and every AST list owns its own
## backing buffer.
function release_parser_scratch(s: ref[pstate.ParserState]) -> void:
    s.stream.tokens.release()
    s.known_type_names.release()
    s.known_import_aliases.release()
    s.known_generic_callable_names.release()
    s.current_type_param_names.release()
    s.pending_decls.release()


# =============================================================================
#  Public API
# =============================================================================

public function parse(source: str) -> bool:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    var lexed = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    var state = pstate.ParserState(
        stream = ts.create(lexed),
        source = source,
        step_counter = 0,
        in_inline_block_body = false,
        recovery_errors = null,
        known_type_names = map_mod.Map[str, bool].create(),
        known_import_aliases = map_mod.Map[str, bool].create(),
        known_generic_callable_names = map_mod.Map[str, bool].create(),
        current_type_param_names = vec.Vec[str].create(),
        suppress_errors = false,
        total_steps = 0,
        error_suppressed = false,
        panic = false,
        panic_index = 0,
        panic_line = 0,
        panic_column = 0,
        panic_message = c"",
        pending_decls = vec.Vec[ast.Decl].create(),
    )
    lexed.release()
    lex_diags.release()
    seed_known_names(ref_of(state))
    let file = parse_source_file(ref_of(state))
    release_parser_scratch(ref_of(state))
    return source_file_decl_count(file) > 0


public function parse_reporting(source: str, errors: ref[vec.Vec[pstate.ParseDiagnostic]]) -> (bool, ptr_uint):
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    var lexed = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    var state = pstate.ParserState(
        stream = ts.create(lexed),
        source = source,
        step_counter = 0,
        in_inline_block_body = false,
        recovery_errors = ptr_of(errors),
        known_type_names = map_mod.Map[str, bool].create(),
        known_import_aliases = map_mod.Map[str, bool].create(),
        known_generic_callable_names = map_mod.Map[str, bool].create(),
        current_type_param_names = vec.Vec[str].create(),
        suppress_errors = false,
        total_steps = 0,
        error_suppressed = false,
        panic = false,
        panic_index = 0,
        panic_line = 0,
        panic_column = 0,
        panic_message = c"",
        pending_decls = vec.Vec[ast.Decl].create(),
    )
    lexed.release()
    lex_diags.release()
    seed_known_names(ref_of(state))
    let file = parse_source_file(ref_of(state))
    release_parser_scratch(ref_of(state))
    return (errors.len() == 0, source_file_decl_count(file))


## Parse a full source file into an AST SourceFile.  Collects recoverable
## errors into `errors`.  Used by the CLI `parse` command and the pretty
## printer.  The backing buffers of the produced spans are intentionally
## leaked (arena-style): the compiler processes one file per run and exits.
public function parse_source(source: str, errors: ref[vec.Vec[pstate.ParseDiagnostic]]) -> ast.SourceFile:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    return parse_source_reporting(source, errors, ref_of(lex_diags))


## Like `parse_source`, additionally surfacing the lexer's recoverable
## diagnostics (unterminated literals, unclosed delimiters, …) to the caller.
## The loader converts them into `lex/error` diagnostics, mirroring the Ruby
## LSP pipeline's `lex_errors + parse_errors` collection.
public function parse_source_reporting(
    source: str,
    errors: ref[vec.Vec[pstate.ParseDiagnostic]],
    lex_errors: ref[vec.Vec[token_mod.LexDiagnostic]],
) -> ast.SourceFile:
    var lexed = lexer_mod.lex_reporting(source, lex_errors)
    var state = pstate.ParserState(
        stream = ts.create(lexed),
        source = source,
        step_counter = 0,
        in_inline_block_body = false,
        recovery_errors = ptr_of(errors),
        known_type_names = map_mod.Map[str, bool].create(),
        known_import_aliases = map_mod.Map[str, bool].create(),
        known_generic_callable_names = map_mod.Map[str, bool].create(),
        current_type_param_names = vec.Vec[str].create(),
        suppress_errors = false,
        total_steps = 0,
        error_suppressed = false,
        panic = false,
        panic_index = 0,
        panic_line = 0,
        panic_column = 0,
        panic_message = c"",
        pending_decls = vec.Vec[ast.Decl].create(),
    )
    lexed.release()
    seed_known_names(ref_of(state))
    let file = parse_source_file(ref_of(state))
    release_parser_scratch(ref_of(state))
    return file


function source_file_decl_count(file: ast.SourceFile) -> ptr_uint:
    return file.imports.len + file.directives.len + file.declarations.len


# =============================================================================
#  Source file
# =============================================================================

function parse_source_file(s: ref[pstate.ParserState]) -> ast.SourceFile:
    skip_newlines(s)

    if check(s, tk.TokenKind.tk_external) and not check_next(s, tk.TokenKind.tk_function):
        # The host records the `external` keyword's line as the module line.
        var external_line: ptr_uint = 0
        let etok = peek(s)
        if etok != null:
            unsafe:
                external_line = read(etok).line
        advance(s)
        skip_newlines(s)
        return parse_raw_module_body(s, external_line)

    var imports = vec.Vec[ast.Decl].create()
    var decls = vec.Vec[ast.Decl].create()

    while match_kind(s, tk.TokenKind.tk_import):
        let imp = parse_import(s)
        if s.panic:
            recover_top_level(s)
        else:
            unsafe:
                imports.push(read(imp))
        skip_newlines(s)

    while not eof(s):
        step(s)
        let decl = parse_decl(s)
        if s.panic:
            recover_top_level(s)
        else:
            unsafe:
                decls.push(read(decl))
            decl_forms.drain_pending_decls(s, ref_of(decls))
        skip_newlines(s)

    return ast.SourceFile(
        module_kind = ast.ModuleKind.module_ordinary,
        imports = imports.as_span(),
        directives = span[ast.Decl](),
        declarations = decls.as_span(),
        line = 1,
    )


function parse_raw_module_body(s: ref[pstate.ParserState], module_line: ptr_uint) -> ast.SourceFile:
    var imports = vec.Vec[ast.Decl].create()
    var directives = vec.Vec[ast.Decl].create()
    var decls = vec.Vec[ast.Decl].create()

    while match_kind(s, tk.TokenKind.tk_import):
        let imp = parse_import(s)
        if s.panic:
            recover_top_level(s)
        else:
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
        let decl = parse_external_decl(s)
        if s.panic:
            recover_top_level(s)
        else:
            unsafe:
                decls.push(read(decl))
        skip_newlines(s)

    return ast.SourceFile(
        module_kind = ast.ModuleKind.module_raw,
        imports = imports.as_span(),
        directives = directives.as_span(),
        declarations = decls.as_span(),
        line = module_line,
    )


function parse_external_decl(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    s.step_counter = 0
    if match_kind(s, tk.TokenKind.tk_const):
        return declarations.parse_const_decl(s, span[ast.AttributeApplication](), false)
    else if match_kind(s, tk.TokenKind.tk_type):
        return decl_forms.parse_type_alias(s, false)
    else if match_kind(s, tk.TokenKind.tk_struct):
        return decl_forms.parse_struct_decl(s, span[ast.AttributeApplication](), false)
    else if match_kind(s, tk.TokenKind.tk_union):
        return parse_union_decl(s, span[ast.AttributeApplication](), false)
    else if match_kind(s, tk.TokenKind.tk_enum):
        return decl_forms.parse_enum_decl(s, false, span[ast.AttributeApplication](), false)
    else if match_kind(s, tk.TokenKind.tk_flags):
        return decl_forms.parse_enum_decl(s, true, span[ast.AttributeApplication](), false)
    else if match_kind(s, tk.TokenKind.tk_opaque):
        return decl_forms.parse_opaque_decl(s, false)
    else if match_kind(s, tk.TokenKind.tk_external):
        if match_kind(s, tk.TokenKind.tk_function):
            return decl_forms.parse_extern_decl(s, span[ast.AttributeApplication]())
        else:
            parser_error_naked(s, c"expected function after external")
            advance(s)
            return decl_error_sentinel(s)
    else if match_kind(s, tk.TokenKind.tk_when):
        return decl_forms.parse_when_decl(s)
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
    var local_cn: ptr_uint = 0
    unsafe:
        local_cn = read(previous_token(s)).column
    let local_len = previous_lexeme(s).len
    consume_end_of_statement(s)
    var node = alloc_decl(s)
    read(node) = ast.Decl.decl_import(path = path, alias_name = alias_name, line = ln, column = local_cn, length = local_len)
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


public function parse_attribute_applications(s: ref[pstate.ParserState]) -> span[ast.AttributeApplication]:
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
    # The host constructs directive nodes with only `value:` (Ruby
    # `AST::LinkDirective.new(value:)`), leaving `line`/`column` nil.  `0` is
    # the self-host nil sentinel, rendered as `nil` by the sexpr dumper.
    if match_kind(s, tk.TokenKind.tk_link):
        consume(s, tk.TokenKind.string, c"expected string after link")
        let value = parse_string_content(previous_lexeme(s), false)
        consume_end_of_statement(s)
        var node = alloc_decl(s)
        read(node) = ast.Decl.decl_link(value = value, line = 0, column = 0)
        return node
    else if match_kind(s, tk.TokenKind.tk_include):
        consume(s, tk.TokenKind.string, c"expected string after include")
        let value = parse_string_content(previous_lexeme(s), false)
        consume_end_of_statement(s)
        var node = alloc_decl(s)
        read(node) = ast.Decl.decl_include(value = value, line = 0, column = 0)
        return node
    else if match_kind(s, tk.TokenKind.tk_compiler_flag):
        consume(s, tk.TokenKind.string, c"expected string after compiler_flag")
        let value = parse_string_content(previous_lexeme(s), false)
        consume_end_of_statement(s)
        var node = alloc_decl(s)
        read(node) = ast.Decl.decl_compiler_flag(value = value, line = 0, column = 0)
        return node
    return decl_error_sentinel(s)


public function parse_decl(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    s.step_counter = 0
    let attrs = parse_attribute_applications(s)
    let visibility = match_kind(s, tk.TokenKind.tk_public)
    if visibility:
        skip_newlines(s)

    if match_kind(s, tk.TokenKind.tk_const):
        if match_kind(s, tk.TokenKind.tk_function):
            return declarations.parse_function_def(s, attrs, visibility, false, true)
        else:
            return declarations.parse_const_decl(s, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_var):
        return declarations.parse_var_decl(s, visibility)
    else if match_kind(s, tk.TokenKind.tk_function):
        return declarations.parse_function_def(s, attrs, visibility, false, false)
    else if match_kind(s, tk.TokenKind.tk_struct):
        return decl_forms.parse_struct_decl(s, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_union):
        return parse_union_decl(s, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_type):
        return decl_forms.parse_type_alias(s, visibility)
    else if match_kind(s, tk.TokenKind.tk_enum):
        return decl_forms.parse_enum_decl(s, false, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_flags):
        return decl_forms.parse_enum_decl(s, true, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_variant):
        return decl_forms.parse_variant_decl(s, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_interface):
        return decl_forms.parse_interface_decl(s, visibility)
    else if match_kind(s, tk.TokenKind.tk_opaque):
        return decl_forms.parse_opaque_decl(s, visibility)
    else if match_kind(s, tk.TokenKind.tk_extending):
        return decl_forms.parse_extending_block(s)
    else if match_kind(s, tk.TokenKind.tk_async):
        consume(s, tk.TokenKind.tk_function, c"expected function after async")
        return declarations.parse_function_def(s, attrs, visibility, true, false)
    else if match_kind(s, tk.TokenKind.tk_external):
        consume(s, tk.TokenKind.tk_function, c"expected function after external")
        return decl_forms.parse_extern_decl(s, attrs)
    else if match_kind(s, tk.TokenKind.tk_foreign):
        consume(s, tk.TokenKind.tk_function, c"expected function after foreign")
        return decl_forms.parse_foreign_decl(s, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_static_assert):
        return decl_forms.parse_static_assert(s)
    else if match_kind(s, tk.TokenKind.tk_event):
        return decl_forms.parse_event_decl(s, attrs, visibility)
    else if match_kind(s, tk.TokenKind.tk_when):
        return decl_forms.parse_when_decl(s)
    else if match_kind(s, tk.TokenKind.tk_attribute):
        return decl_forms.parse_attribute_decl(s, visibility)
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
    let c_name = declarations.parse_optional_c_name(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after union name")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented union body")
    skip_newlines(s)
    var fields = vec.Vec[ast.Field].create()
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        fields.push(decl_forms.parse_struct_member(s, span[ast.AttributeApplication]()))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of union body")
    var node = alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_union(name = name, c_name = c_name, union_fields = fields.as_span(),
            visibility = visibility, union_attrs = attrs, line = ln, column = cn)
    return node



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
                    or id.name == "own" or id.name == "ref" or id.name == "adapt"
                    or id.name == "equal" or id.name == "hash" or id.name == "order"
                    or id.name == "simd" or id.name == "SoA"
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
        if t.is_fn or t.is_proc or t.is_tuple:
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
public function specialization_value_target(s: ref[pstate.ParserState], callee: ptr[ast.Expr], args: span[ast.TypeArgument]) -> bool:
    if is_identifier_named(callee, "zero") and all_explicit_specialization_args(s, args):
        return true
    if expressions.specialization_target(callee) and all_definite_type_args(s, args):
        return true
    if generic_callable_specialization_target(s, callee) and all_explicit_specialization_args(s, args):
        return true
    if imported_member_specialization_target(s, callee) and all_explicit_specialization_args(s, args):
        return true
    return false


## True when the `name[args](call_args)` form is a genuine specialized call.
public function specialization_call_target(s: ref[pstate.ParserState], callee: ptr[ast.Expr], args: span[ast.TypeArgument], call_args: span[ast.Argument]) -> bool:
    if (is_identifier_named(callee, "default") or is_identifier_named(callee, "zero")) and not callee_known_type_like(s, callee) and not generic_callable_specialization_target(s, callee):
        return false
    if builtin_specialization_target(callee):
        return true
    if expressions.specialization_target(callee) and all_call_args_named(call_args):
        return true
    if generic_callable_specialization_target(s, callee) and all_explicit_specialization_args(s, args):
        return true
    if imported_member_specialization_target(s, callee) and all_explicit_specialization_args(s, args):
        return true
    return expressions.specialization_target(callee) and all_definite_type_args(s, args)


public function parse_primary(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
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
            target = declarations.parse_type_ref(s)
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
        if (check_name(s) or keyword_token_check(peek(s))) and check_next(s, tk.TokenKind.equal):
            var name_str: str
            let nt = peek(s) else:
                fatal(c"unexpected eof in named tuple field")
            unsafe:
                name_str = token_mod.token_lexeme(read(nt), s.source)
            advance(s)
            advance(s)
            var val = expressions.parse_expr(s)
            first_expr = alloc_expr(s)
            unsafe:
                read(first_expr) = ast.Expr.expr_named(name = name_str, value = val)
        else:
            first_expr = expressions.parse_expr(s)
        if match_kind(s, tk.TokenKind.comma):
            var elems = vec.Vec[ast.Expr].create()
            unsafe:
                elems.push(read(first_expr))
            while true:
                step(s)
                if check(s, tk.TokenKind.rparen):
                    break
                if (check_name(s) or keyword_token_check(peek(s))) and check_next(s, tk.TokenKind.equal):
                    var name_str: str
                    let nt2 = peek(s) else:
                        break
                    unsafe:
                        name_str = token_mod.token_lexeme(read(nt2), s.source)
                    advance(s)
                    advance(s)
                    var val2 = expressions.parse_expr(s)
                    var ne = alloc_expr(s)
                    unsafe:
                        read(ne) = ast.Expr.expr_named(name = name_str, value = val2)
                    unsafe:
                        elems.push(read(ne))
                else:
                    var next = expressions.parse_expr(s)
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
        return parse_if_expr(s)
    else if match_kind(s, tk.TokenKind.tk_match):
        return parse_match_expr(s)
    else if match_kind(s, tk.TokenKind.tk_proc):
        return parse_proc_expr_after_proc(s)
    else if match_kind(s, tk.TokenKind.tk_size_of):
        consume(s, tk.TokenKind.lparen, c"expected '(' after size_of")
        var type_ref = declarations.parse_type_ref(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_sizeof(target_type = type_ref)
        return node
    else if match_kind(s, tk.TokenKind.tk_align_of):
        consume(s, tk.TokenKind.lparen, c"expected '(' after align_of")
        var type_ref = declarations.parse_type_ref(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
        var node = alloc_expr(s)
        read(node) = ast.Expr.expr_alignof(target_type = type_ref)
        return node
    else if match_kind(s, tk.TokenKind.tk_offset_of):
        consume(s, tk.TokenKind.lparen, c"expected '(' after offset_of")
        var type_ref = declarations.parse_type_ref(s)
        consume(s, tk.TokenKind.comma, c"expected ','")
        consume_name_allowing_keywords(s, c"expected field name")
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

public function parse_if_expr(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var condition = expressions.parse_expr(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after if condition")
    var then_expr: ptr[ast.Expr]
    var else_expr: ptr[ast.Expr]
    if check(s, tk.TokenKind.newline):
        # Block form: `if cond:` newline-indented expression, `else:` likewise.
        consume(s, tk.TokenKind.newline, c"expected newline after if condition")
        consume(s, tk.TokenKind.indent, c"expected indented if expression body")
        then_expr = expressions.parse_expr(s)
        consume_end_of_statement(s)
        consume(s, tk.TokenKind.dedent, c"expected end of if expression body")
        consume(s, tk.TokenKind.tk_else, c"expected 'else' in if expression")
        consume(s, tk.TokenKind.colon, c"expected ':' after else")
        consume(s, tk.TokenKind.newline, c"expected newline after else:")
        consume(s, tk.TokenKind.indent, c"expected indented else expression body")
        else_expr = expressions.parse_expr(s)
        consume_end_of_statement(s)
        consume(s, tk.TokenKind.dedent, c"expected end of else expression body")
    else:
        then_expr = expressions.parse_expr(s)
        consume(s, tk.TokenKind.tk_else, c"expected 'else' in if expression")
        consume(s, tk.TokenKind.colon, c"expected ':' after else")
        else_expr = expressions.parse_expr(s)
    var node = alloc_expr(s)
    read(node) = ast.Expr.expr_if(condition = condition, then_expr = then_expr, else_expr = else_expr)
    return node


# =============================================================================
#  Match expression
# =============================================================================

public function parse_match_expr(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var m_ln: ptr_uint = 0
    var m_cn: ptr_uint = 0
    unsafe:
        m_ln = read(previous_token(s)).line
        m_cn = read(previous_token(s)).column
    var scrutinee = expressions.parse_expr(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after match expression")
    consume(s, tk.TokenKind.newline, c"expected newline after match header")
    consume(s, tk.TokenKind.indent, c"expected indented match body")
    var arms = parse_match_expr_arms(s)
    consume(s, tk.TokenKind.dedent, c"expected end of match body")
    var node = alloc_expr(s)
    read(node) = ast.Expr.expr_match(scrutinee = scrutinee, arms = arms, line = m_ln, column = m_cn, length = 5, desugared_from_is = false)
    return node


function parse_match_expr_arms(s: ref[pstate.ParserState]) -> span[ast.MatchExprArm]:
    var arms = vec.Vec[ast.MatchExprArm].create()
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        parse_match_expr_arm_into(s, ref_of(arms))
        skip_newlines(s)
    let result = arms.as_span()
    return result


public function parse_match_expr_arm_into(s: ref[pstate.ParserState], arms: ref[vec.Vec[ast.MatchExprArm]]) -> void:
    var is_wild = false
    var wild_ln: ptr_uint = 0
    var wild_cn: ptr_uint = 0
    var patterns = vec.Vec[ptr[ast.Expr]].create()
    if match_kind(s, tk.TokenKind.tk_else):
        is_wild = true
        unsafe:
            wild_ln = read(previous_token(s)).line
            wild_cn = read(previous_token(s)).column
    else if statements.is_wildcard_match(s):
        is_wild = true
        unsafe:
            wild_ln = read(previous_token(s)).line
            wild_cn = read(previous_token(s)).column
    else:
        patterns.push(statements.parse_pattern(s))
        while match_kind(s, tk.TokenKind.pipe):
            patterns.push(statements.parse_pattern(s))
    var binding_name: Option[str] = Option[str].none
    var binding_line: ptr_uint = 0
    var binding_column: ptr_uint = 0
    if match_kind(s, tk.TokenKind.tk_as):
        let prev = pstate.previous(s) else:
            fatal(c"parse inner missing previous token")
        unsafe: binding_line = read(prev).line
        consume_name(s, c"expected binding name after as")
        binding_name = Option[str].some(value = previous_lexeme(s))
        unsafe: binding_column = read(previous_token(s)).column
    consume(s, tk.TokenKind.colon, c"expected ':' after match pattern")
    var value = expressions.parse_expr(s)
    if not block_expr(value):
        consume_end_of_statement(s)
    if is_wild:
        arms.push(ast.MatchExprArm(pattern = null, binding_name = binding_name, binding_line = binding_line, binding_column = binding_column, value = value,
            wildcard_line = wild_ln, wildcard_column = wild_cn))
        return
    var i: ptr_uint = 0
    while i < patterns.len():
        let pp = patterns.get(i) else:
            break
        unsafe:
            arms.push(ast.MatchExprArm(pattern = read(pp), binding_name = binding_name, binding_line = binding_line, binding_column = binding_column, value = value))
        i += 1


# =============================================================================
#  Proc / fn expression
# =============================================================================

function parse_proc_expr_after_proc(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var params = declarations.parse_params(s)
    var return_type: ptr[ast.TypeRef]? = null
    if match_kind(s, tk.TokenKind.arrow):
        return_type = declarations.parse_type_ref(s)
    var body = parse_proc_body(s)
    var node = alloc_expr(s)
    read(node) = ast.Expr.expr_proc(method_params = params, return_type = return_type, body = body)
    return node


function parse_proc_body(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    if match_kind(s, tk.TokenKind.colon):
        if match_kind(s, tk.TokenKind.newline):
            consume(s, tk.TokenKind.indent, c"expected indented proc body")
            var stmts_span = declarations.parse_block_body(s)
            consume(s, tk.TokenKind.dedent, c"expected end of proc body")
            var block = alloc_stmt(s)
            unsafe:
                read(block) = ast.Stmt.stmt_block(statements = stmts_span)
            return block
        else:
            # Expression-body proc: proc() -> T: expr  (implicit return)
            var expr_val = expressions.parse_expr(s)
            var ret = alloc_stmt(s)
            unsafe:
                read(ret) = ast.Stmt.stmt_ret(value = expr_val, line = 0, column = 0, length = 0)
            return ret
    var empty = alloc_stmt(s)
    unsafe:
        read(empty) = ast.Stmt.stmt_block(statements = span[ast.Stmt]())
    return empty


# =============================================================================
#  Unsafe expression
# =============================================================================

public function parse_unsafe_expr(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    let tok = previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = tok.line
        cn = tok.column
    consume(s, tk.TokenKind.colon, c"expected ':' after unsafe")
    var expr_val = expressions.parse_expr(s)
    var node = alloc_expr(s)
    read(node) = ast.Expr.expr_unsafe(expression = expr_val, line = ln, column = cn)
    return node


# =============================================================================
#  is-operator desugaring
# =============================================================================

public function is_desugar(s: ref[pstate.ParserState], left: ptr[ast.Expr], pattern: ptr[ast.Expr], is_ln: ptr_uint, is_cn: ptr_uint, pattern_len: ptr_uint) -> ptr[ast.Expr]:
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
        value = false_expr,
        wildcard_line = is_ln,
        wildcard_column = is_cn
    )
    # Build a heap-backed span of two arms (a stack array's span would dangle).
    var arms_vec = vec.Vec[ast.MatchExprArm].create()
    arms_vec.push(true_arm)
    arms_vec.push(false_arm)
    var arms_span = arms_vec.as_span()
    var node = alloc_expr(s)
    read(node) = ast.Expr.expr_match(scrutinee = left, arms = arms_span, line = is_ln, column = is_cn, length = pattern_len, desugared_from_is = true)
    return node


# =============================================================================
#  Prefix cast: T<-expr
# =============================================================================

public function try_parse_prefix_cast_expr(s: ref[pstate.ParserState]) -> Option[ptr[ast.Expr]]:
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
    var target_type = declarations.parse_named_type_ref(s, true)
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
    var expr_val = expressions.parse_unary(s)
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

public function parse_call_args(s: ref[pstate.ParserState]) -> span[ast.Argument]:
    var args = vec.Vec[ast.Argument].create()
    if check(s, tk.TokenKind.rparen):
        return span[ast.Argument]()
    while true:
        step(s)
        if check(s, tk.TokenKind.rparen):
            break
        if (check_name(s) or keyword_token_check(peek(s))) and check_next(s, tk.TokenKind.equal):
            let name_tok = peek(s) else:
                break
            var arg_name: str
            unsafe:
                arg_name = token_mod.token_lexeme(read(name_tok), s.source)
            advance(s)
            advance(s)
            var val = expressions.parse_expr(s)
            var arg = ast.Argument(arg_name = Option[str].some(value = arg_name), arg_value = val)
            args.push(arg)
        else:
            var val = expressions.parse_expr(s)
            var arg = ast.Argument(arg_name = Option[str].none, arg_value = val)
            args.push(arg)
        if not match_kind(s, tk.TokenKind.comma):
            break
        if check(s, tk.TokenKind.rparen):
            break
    let result = args.as_span()
    return result
