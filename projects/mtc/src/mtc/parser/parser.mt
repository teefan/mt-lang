## Self-hosted parser — transforms a token stream into an AST.
##
## Mirrors the Ruby parser (lib/milk_tea/core/parser.rb) architecture,
## algorithms, and AST node structure.
##
## Loop guard: every while-loop increments a step counter; at 100,000 steps
## the parser aborts to prevent infinite loops during development.

import std.hash
import std.map as map_mod
import std.str
import std.vec as vec
import std.mem.heap as heap_mod

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.lexer.lexer as lexer
import mtc.parser.token_stream as ts
import mtc.parser.ast as ast


## Diagnostic with position info — survives function scope (value type).
public struct ParseDiagnostic:
    line: ptr_uint
    column: ptr_uint
    message: cstr
    lexeme: str
    kind: str

const MAX_LOOP_STEPS: ptr_uint = 100000


# =============================================================================
#  Parser state
# =============================================================================

struct ParserState:
    stream: ts.TokenStream
    source: str
    step_counter: ptr_uint
    in_inline_block_body: bool
    recovery_errors: ptr[vec.Vec[ParseDiagnostic]]?
    known_type_names: map_mod.Map[str, bool]
    known_import_aliases: map_mod.Map[str, bool]
    known_generic_callable_names: map_mod.Map[str, bool]
    current_type_param_names: vec.Vec[str]


# =============================================================================
#  Loop guard
# =============================================================================

function step(s: ref[ParserState]) -> void:
    s.step_counter += 1
    if s.step_counter > MAX_LOOP_STEPS:
        let tok = peek(s) else:
            fatal(c"parse loop guard: exceeded max iterations (no token)")
        unsafe:
            let t = read(tok)
            let lexeme = token_mod.token_lexeme(t, s.source)
            let kn = token_mod.kind_name(t.kind)
            var buf: str_buffer[256]
            buf.assign("parse loop guard: stuck at L")
            buf.append_format(f"#{int<-(t.line)}")
            buf.append(":C")
            buf.append_format(f"#{int<-(t.column)}")
            buf.append(" lexeme='")
            buf.append(lexeme)
            buf.append("' kind=")
            buf.append(kn)
            fatal(buf.as_cstr())


# =============================================================================
#  Token access helpers
# =============================================================================

function peek(s: ref[ParserState]) -> ptr[token_mod.Token]?:
    return ts.peek(ref_of(s.stream))

function advance(s: ref[ParserState]) -> void:
    ts.advance(ref_of(s.stream))

function previous(s: ref[ParserState]) -> ptr[token_mod.Token]?:
    return ts.previous(ref_of(s.stream))

function previous_token(s: ref[ParserState]) -> ptr[token_mod.Token]:
    let tok = previous(s) else:
        fatal(c"parser bug: previous token is null")
    return tok

function check(s: ref[ParserState], kind: tk.TokenKind) -> bool:
    return ts.check(ref_of(s.stream), kind)

function match_kind(s: ref[ParserState], kind: tk.TokenKind) -> bool:
    return ts.match_kind(ref_of(s.stream), kind)

function consume(s: ref[ParserState], kind: tk.TokenKind, msg: cstr) -> void:
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
    advance(s)


function parser_error_naked(s: ref[ParserState], msg: cstr) -> void:
    parser_error_at(s, msg, 0, 0, "", "")


function parser_error_at(s: ref[ParserState], msg: cstr, line: ptr_uint, col: ptr_uint, lexeme: str, kind: str) -> void:
    unsafe:
        let errs_ptr = read(s).recovery_errors
        if errs_ptr == null:
            var buf: str_buffer[300]
            buf.assign_format(f"L#{int<-(line)}:#{int<-(col)} lexeme='")
            buf.append(lexeme)
            buf.append("' kind=")
            buf.append(kind)
            fatal(buf.as_cstr())
        var errs = read(errs_ptr)
        let diag = ParseDiagnostic(line = line, column = col, message = msg, lexeme = lexeme, kind = kind)
        errs.push(diag)
        read(errs_ptr) = errs


function skip_to_sync_point(s: ref[ParserState]) -> void:
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


function synchronize_to_statement_boundary(s: ref[ParserState]) -> void:
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


function recover_statement_block_body(s: ref[ParserState]) -> void:
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


function synchronize_to_match_arm_boundary(s: ref[ParserState]) -> void:
    while not eof(s):
        if check(s, tk.TokenKind.dedent):
            return
        if check(s, tk.TokenKind.newline):
            advance(s)
            if check(s, tk.TokenKind.indent):
                recover_match_arm_block(s)
            return
        advance(s)


function recover_match_arm_block(s: ref[ParserState]) -> void:
    if check(s, tk.TokenKind.indent):
        advance(s)
    skip_newlines(s)
    while not eof(s) and not check(s, tk.TokenKind.dedent):
        step(s)
        if check(s, tk.TokenKind.newline):
            advance(s)
            skip_newlines(s)
            continue
        parse_match_arm_producing(s)
        skip_newlines(s)
    if check(s, tk.TokenKind.dedent):
        advance(s)


function synchronize_to_top_level_boundary(s: ref[ParserState]) -> void:
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

function is_declaration_start(s: ref[ParserState]) -> bool:
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

function eof(s: ref[ParserState]) -> bool:
    return ts.eof(ref_of(s.stream))

function skip_newlines(s: ref[ParserState]) -> void:
    ts.skip_newlines(ref_of(s.stream))

function check_name(s: ref[ParserState]) -> bool:
    return check(s, tk.TokenKind.identifier)

function match_name(s: ref[ParserState]) -> bool:
    if check_name(s):
        advance(s)
        return true
    return false

function consume_name(s: ref[ParserState], msg: cstr) -> void:
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

function consume_name_allowing_keywords(s: ref[ParserState], msg: cstr) -> void:
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

function consume_end_of_statement(s: ref[ParserState]) -> void:
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

function previous_lexeme(s: ref[ParserState]) -> str:
    let tok = previous(s) else:
        return ""
    unsafe:
        let t = read(tok)
        return token_mod.token_lexeme(t, s.source)


# =============================================================================
#  Name disambiguation infrastructure
# =============================================================================

const BUILTIN_TYPE_NAME_COUNT: ptr_uint = 45
const BUILTIN_TYPE_NAMES: array[str, 45] = array[str, 45](
    "bool", "byte", "ubyte", "char", "short", "ushort", "int", "uint",
    "long", "ulong", "ptr_int", "ptr_uint", "float", "double", "void",
    "str", "cstr", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4",
    "mat3", "mat4", "quat", "ptr", "const_ptr", "ref", "span", "array",
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


function known_type_like_name(s: ref[ParserState], name: str) -> bool:
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


function check_next(s: ref[ParserState], kind: tk.TokenKind) -> bool:
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


function matching_rbracket_index(s: ref[ParserState], start_index: ptr_uint) -> Option[ptr_uint]:
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

function seed_known_names(s: ref[ParserState]) -> void:
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


function seed_import_alias(s: ref[ParserState], start_index: ptr_uint) -> ptr_uint:
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

function parse_comma_separated_until(s: ref[ParserState], closing_type: tk.TokenKind,
                                      parse_item: proc(session: ref[ParserState]) -> void) -> void:
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
#  Literal value extraction
# =============================================================================

const ZERO_BYTE_V: ubyte = '0'
const LOWER_X_V: ubyte = 'x'
const UPPER_X_V: ubyte = 'X'
const LOWER_B_V: ubyte = 'b'
const UPPER_B_V: ubyte = 'B'
const LOWER_E_V: ubyte = 'e'
const UPPER_E_V: ubyte = 'E'
const PLUS_BYTE_V: ubyte = '+'
const MINUS_BYTE_V: ubyte = '-'

function parse_int_literal(lexeme: str) -> int:
    if lexeme.len == 0:
        return 0
    var pos: ptr_uint = 0
    var negative = false
    var value: int = 0

    unsafe:
        let first = ubyte<-read(lexeme.data)
        if first == MINUS_BYTE_V:
            negative = true
            pos = 1

        if pos + 2 < lexeme.len:
            let second = ubyte<-read(lexeme.data + pos)
            let third = ubyte<-read(lexeme.data + pos + 1)
            if second == ZERO_BYTE_V and (third == LOWER_X_V or third == UPPER_X_V):
                pos += 2
                while pos < lexeme.len:
                    let b = ubyte<-read(lexeme.data + pos)
                    if b == '_':
                        pos += 1
                        continue
                    value = value * 16
                    if b >= '0' and b <= '9':
                        value += int<-(b - '0')
                    else if b >= 'a' and b <= 'f':
                        value += int<-(b - 'a' + 10)
                    else if b >= 'A' and b <= 'F':
                        value += int<-(b - 'A' + 10)
                    else:
                        break
                    pos += 1
                if negative:
                    return -value
                return value

            if second == ZERO_BYTE_V and (third == LOWER_B_V or third == UPPER_B_V):
                pos += 2
                while pos < lexeme.len:
                    let b = ubyte<-read(lexeme.data + pos)
                    if b == '_':
                        pos += 1
                        continue
                    if b == '0':
                        value = value * 2
                    else if b == '1':
                        value = value * 2 + 1
                    else:
                        break
                    pos += 1
                if negative:
                    return -value
                return value

        while pos < lexeme.len:
            let b = ubyte<-read(lexeme.data + pos)
            if b == '_':
                pos += 1
                continue
            if b >= '0' and b <= '9':
                value = value * 10 + int<-(b - '0')
            else:
                break
            pos += 1

    if negative:
        return -value
    return value


function parse_float_literal(lexeme: str) -> double:
    if lexeme.len == 0:
        return 0.0
    var pos: ptr_uint = 0
    var negative = false
    var exp_negative = false
    var int_part: int = 0
    var dec_part: int = 0
    var dec_div: int = 1
    var exp_part: int = 0
    var in_dec = false
    var in_exp = false

    unsafe:
        let first = ubyte<-read(lexeme.data)
        if first == MINUS_BYTE_V:
            negative = true
            pos = 1

        while pos < lexeme.len:
            let b = ubyte<-read(lexeme.data + pos)
            if b == '_':
                pos += 1
                continue
            if b == '.':
                in_dec = true
                pos += 1
                continue
            if b == LOWER_E_V or b == UPPER_E_V:
                in_exp = true
                pos += 1
                if pos < lexeme.len:
                    let sign = ubyte<-read(lexeme.data + pos)
                    if sign == MINUS_BYTE_V:
                        exp_negative = true
                        pos += 1
                    else if sign == PLUS_BYTE_V:
                        pos += 1
                continue
            if b >= '0' and b <= '9':
                let d = int<-(b - '0')
                if in_exp:
                    exp_part = exp_part * 10 + d
                else if in_dec:
                    dec_part = dec_part * 10 + d
                    dec_div *= 10
                else:
                    int_part = int_part * 10 + d
            else:
                break
            pos += 1

    var result: double = double<-(int_part)
    if dec_div > 1:
        result += double<-(dec_part) / double<-(dec_div)
    if exp_part != 0:
        var remaining = exp_part
        if exp_negative:
            while remaining > 0:
                result /= 10.0
                remaining -= 1
        else:
            while remaining > 0:
                result *= 10.0
                remaining -= 1

    if negative:
        return -result
    return result


function parse_string_content(lexeme: str, is_cstring: bool) -> str:
    if lexeme.len < 2:
        return lexeme
    if is_cstring:
        if lexeme.len < 3:
            return lexeme
        return unsafe: str(data = lexeme.data + 1, len = lexeme.len - 2)
    return unsafe: str(data = lexeme.data + 1, len = lexeme.len - 2)


function parse_char_value(lexeme: str) -> ubyte:
    if lexeme.len < 3:
        return 0
    # Skip opening '
    var pos: ptr_uint = 1
    var value: ubyte = 0
    unsafe:
        let b = ubyte<-read(lexeme.data + pos)
        if b == '\\':
            pos += 1
            let esc = ubyte<-read(lexeme.data + pos)
            if esc == 'n':
                return 10
            else if esc == 'r':
                return 13
            else if esc == 't':
                return 9
            else if esc == '0':
                return 0
            else if esc == '\\':
                return 92
            else if esc == '\'':
                return 39
            else if esc == '\"':
                return 34
            else if esc == 'x':
                # \xNN — two hex digits
                value = 0
                var hi = ubyte<-read(lexeme.data + pos + 1)
                var lo = ubyte<-read(lexeme.data + pos + 2)
                if hi >= '0' and hi <= '9':
                    value += (hi - '0') * 16
                else if hi >= 'a' and hi <= 'f':
                    value += (hi - 'a' + 10) * 16
                else if hi >= 'A' and hi <= 'F':
                    value += (hi - 'A' + 10) * 16
                if lo >= '0' and lo <= '9':
                    value += (lo - '0')
                else if lo >= 'a' and lo <= 'f':
                    value += (lo - 'a' + 10)
                else if lo >= 'A' and lo <= 'F':
                    value += (lo - 'A' + 10)
                return value
            return b
        return b


# =============================================================================
#  AST node allocation
# =============================================================================

function alloc_expr(s: ref[ParserState]) -> ptr[ast.Expr]:
    return heap_mod.must_alloc[ast.Expr](1)

function alloc_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
    return heap_mod.must_alloc[ast.Stmt](1)

function alloc_decl(s: ref[ParserState]) -> ptr[ast.Decl]:
    return heap_mod.must_alloc[ast.Decl](1)


# =============================================================================
#  Public API
# =============================================================================

public function parse(source: str) -> bool:
    var state = ParserState(
        stream = ts.create(lexer.lex(source)),
        source = source,
        step_counter = 0,
        in_inline_block_body = false,
        recovery_errors = null,
        known_type_names = map_mod.Map[str, bool].create(),
        known_import_aliases = map_mod.Map[str, bool].create(),
        known_generic_callable_names = map_mod.Map[str, bool].create(),
        current_type_param_names = vec.Vec[str].create(),
    )
    seed_known_names(ref_of(state))
    var decl_count = parse_source_file(ref_of(state))
    return decl_count > 0


public function parse_reporting(source: str, errors: ref[vec.Vec[ParseDiagnostic]]) -> (bool, ptr_uint):
    var state = ParserState(
        stream = ts.create(lexer.lex(source)),
        source = source,
        step_counter = 0,
        in_inline_block_body = false,
        recovery_errors = ptr_of(errors),
        known_type_names = map_mod.Map[str, bool].create(),
        known_import_aliases = map_mod.Map[str, bool].create(),
        known_generic_callable_names = map_mod.Map[str, bool].create(),
        current_type_param_names = vec.Vec[str].create(),
    )
    seed_known_names(ref_of(state))
    var nodes = parse_source_file(ref_of(state))
    return (errors.len() == 0, nodes)


# =============================================================================
#  Source file
# =============================================================================

function parse_source_file(s: ref[ParserState]) -> ptr_uint:
    skip_newlines(s)

    if check(s, tk.TokenKind.tk_external) and not check_next(s, tk.TokenKind.tk_function):
        advance(s)
        skip_newlines(s)
        return parse_raw_module_body(s)

    var count: ptr_uint = 0

    while match_kind(s, tk.TokenKind.tk_import):
        parse_import(s)
        count += 1
        skip_newlines(s)

    while not eof(s):
        step(s)
        parse_declaration(s)
        count += 1
        skip_newlines(s)

    return count


function parse_raw_module_body(s: ref[ParserState]) -> ptr_uint:
    var count: ptr_uint = 0
    while match_kind(s, tk.TokenKind.tk_import):
        parse_import(s)
        count += 1
        skip_newlines(s)
    while check(s, tk.TokenKind.tk_link) or check(s, tk.TokenKind.tk_include) or check(s, tk.TokenKind.tk_compiler_flag):
        parse_raw_module_directive(s)
        count += 1
        skip_newlines(s)
    while not eof(s):
        step(s)
        parse_external_declaration(s)
        count += 1
        skip_newlines(s)
    return count


function parse_external_declaration(s: ref[ParserState]) -> void:
    if match_kind(s, tk.TokenKind.tk_const):
        parse_const_decl(s)
    else if match_kind(s, tk.TokenKind.tk_type):
        parse_type_alias(s)
    else if match_kind(s, tk.TokenKind.tk_struct):
        parse_struct_decl(s)
    else if match_kind(s, tk.TokenKind.tk_union):
        parse_union_decl(s)
    else if match_kind(s, tk.TokenKind.tk_enum):
        parse_enum_decl(s)
    else if match_kind(s, tk.TokenKind.tk_flags):
        parse_enum_decl(s)
    else if match_kind(s, tk.TokenKind.tk_opaque):
        parse_opaque_decl(s)
    else if match_kind(s, tk.TokenKind.tk_external):
        if match_kind(s, tk.TokenKind.tk_function):
            parse_extern_decl(s)
        else:
            parser_error_naked(s, c"expected function after external")
            advance(s)
    else if match_kind(s, tk.TokenKind.tk_when):
        parse_when_stmt(s)
    else:
        parser_error_naked(s, c"expected external declaration")
        advance(s)


# =============================================================================
#  Import
# =============================================================================

function parse_import(s: ref[ParserState]) -> void:
    parse_qualified_name(s)
    if match_kind(s, tk.TokenKind.tk_as):
        consume_name(s, c"expected import alias")
    consume_end_of_statement(s)


function parse_qualified_name(s: ref[ParserState]) -> void:
    consume_name_allowing_keywords(s, c"expected identifier")
    while match_kind(s, tk.TokenKind.dot):
        consume_name_allowing_keywords(s, c"expected identifier after '.'")


# =============================================================================
#  Declaration dispatch
# =============================================================================

function parse_attribute_name_and_args(s: ref[ParserState]) -> void:
    consume_name_allowing_keywords(s, c"expected attribute name")
    while match_kind(s, tk.TokenKind.dot):
        consume_name_allowing_keywords(s, c"expected attribute name after '.'")
    if match_kind(s, tk.TokenKind.lparen):
        var depth: int = 1
        while not eof(s) and depth > 0:
            step(s)
            if check(s, tk.TokenKind.lparen):
                depth += 1
                advance(s)
            else if check(s, tk.TokenKind.rparen):
                depth -= 1
                advance(s)
            else:
                advance(s)


function skip_attribute_content(s: ref[ParserState]) -> void:
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

function external_file_header(s: ref[ParserState]) -> bool:
    return check(s, tk.TokenKind.tk_external) and ts.check_next(ref_of(s.stream), tk.TokenKind.newline)


function parse_raw_module_directive(s: ref[ParserState]) -> void:
    if match_kind(s, tk.TokenKind.tk_link):
        consume(s, tk.TokenKind.string, c"expected string after link")
        consume_end_of_statement(s)
    else if match_kind(s, tk.TokenKind.tk_include):
        consume(s, tk.TokenKind.string, c"expected string after include")
        consume_end_of_statement(s)
    else if match_kind(s, tk.TokenKind.tk_compiler_flag):
        consume(s, tk.TokenKind.string, c"expected string after compiler_flag")
        consume_end_of_statement(s)


function parse_declaration(s: ref[ParserState]) -> void:
    var packed = false
    var alignment: int = 0
    while match_kind(s, tk.TokenKind.at):
        consume(s, tk.TokenKind.lbracket, c"expected '[' after @")
        if not check(s, tk.TokenKind.rbracket):
            while true:
                step(s)
                parse_attribute_name_and_args(s)
                if not match_kind(s, tk.TokenKind.comma):
                    break
                if check(s, tk.TokenKind.rbracket):
                    break
        consume(s, tk.TokenKind.rbracket, c"expected ']' after attribute")
        skip_newlines(s)
    var _p = packed
    var _a = alignment

    if match_kind(s, tk.TokenKind.tk_const):
        if match_kind(s, tk.TokenKind.tk_function):
            parse_function_def(s)
        else:
            parse_const_decl(s)
    else if match_kind(s, tk.TokenKind.tk_var):
        parse_var_decl(s)
    else if match_kind(s, tk.TokenKind.tk_function):
        parse_function_def(s)
    else if match_kind(s, tk.TokenKind.tk_public):
        skip_newlines(s)
        parse_declaration(s)
    else if match_kind(s, tk.TokenKind.tk_struct):
        parse_struct_decl(s)
    else if match_kind(s, tk.TokenKind.tk_union):
        parse_union_decl(s)
    else if match_kind(s, tk.TokenKind.tk_type):
        parse_type_alias(s)
    else if match_kind(s, tk.TokenKind.tk_enum):
        parse_enum_decl(s)
    else if match_kind(s, tk.TokenKind.tk_flags):
        parse_enum_decl(s)
    else if match_kind(s, tk.TokenKind.tk_variant):
        parse_variant_decl(s)
    else if match_kind(s, tk.TokenKind.tk_interface):
        parse_interface_decl(s)
    else if match_kind(s, tk.TokenKind.tk_opaque):
        parse_opaque_decl(s)
    else if match_kind(s, tk.TokenKind.tk_extending):
        parse_extending_block(s)
    else if match_kind(s, tk.TokenKind.tk_async):
        consume(s, tk.TokenKind.tk_function, c"expected function after async")
        parse_function_def(s)
    else if match_kind(s, tk.TokenKind.tk_external):
        consume(s, tk.TokenKind.tk_function, c"expected function after external")
        parse_extern_decl(s)
    else if match_kind(s, tk.TokenKind.tk_foreign):
        consume(s, tk.TokenKind.tk_function, c"expected function after foreign")
        parse_foreign_decl(s)
    else if match_kind(s, tk.TokenKind.tk_static_assert):
        parse_static_assert(s)
    else if match_kind(s, tk.TokenKind.tk_event):
        parse_event_decl(s)
    else if match_kind(s, tk.TokenKind.tk_when):
        parse_when_decl(s)
    else if match_kind(s, tk.TokenKind.tk_attribute):
        parse_attribute_decl(s)
    else:
        parser_error_naked(s, c"expected declaration")
        advance(s)


function parse_union_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected union name")
    consume(s, tk.TokenKind.colon, c"expected ':' after union name")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented union body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        parse_struct_member(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of union body")


# =============================================================================
#  Declarations
# =============================================================================

function parse_const_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected constant name")
    if match_kind(s, tk.TokenKind.arrow):
        # Block-bodied const: const NAME -> TYPE:
        parse_type_ref(s)
        parse_block(s)
        return
    consume(s, tk.TokenKind.colon, c"expected ':' after constant name")
    parse_type_ref(s)
    consume(s, tk.TokenKind.equal, c"expected '=' after constant type")
    parse_expression(s)
    consume_end_of_statement(s)


function parse_var_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected variable name")
    if match_kind(s, tk.TokenKind.colon):
        parse_type_ref(s)
    if match_kind(s, tk.TokenKind.equal):
        parse_expression(s)
    consume_end_of_statement(s)


function parse_function_def(s: ref[ParserState]) -> void:
    consume_name(s, c"expected function name")
    if match_kind(s, tk.TokenKind.lbracket):
        parse_declaration_type_params(s)
    parse_params(s)
    if match_kind(s, tk.TokenKind.arrow):
        parse_type_ref(s)
    parse_block(s)


function parse_declaration_type_params(s: ref[ParserState]) -> void:
    while not eof(s):
        if check(s, tk.TokenKind.rbracket):
            break
        if match_kind(s, tk.TokenKind.at):
            consume_name(s, c"expected lifetime name after @")
            var lt = previous_lexeme(s)
        else:
            consume_name(s, c"expected type parameter name")
            var tp_name = previous_lexeme(s)
            s.current_type_param_names.push(tp_name)
            if match_kind(s, tk.TokenKind.colon):
                parse_type_ref(s)
        if not match_kind(s, tk.TokenKind.comma):
            break
    consume(s, tk.TokenKind.rbracket, c"expected ']' after type parameters")


function with_type_param_scope(s: ref[ParserState], body: proc(session: ref[ParserState]) -> void) -> void:
    var saved_count = s.current_type_param_names.len()
    body(s)
    while s.current_type_param_names.len() > saved_count:
        s.current_type_param_names.pop()


function parse_params(s: ref[ParserState]) -> void:
    consume(s, tk.TokenKind.lparen, c"expected '('")
    while not eof(s) and not check(s, tk.TokenKind.rparen):
        if match_kind(s, tk.TokenKind.ellipsis):
            break
        if (check(s, tk.TokenKind.tk_out) or check(s, tk.TokenKind.tk_in)
            or check(s, tk.TokenKind.tk_inout) or check(s, tk.TokenKind.tk_consuming)):
            if check_next(s, tk.TokenKind.identifier) or check_next(s, tk.TokenKind.tk_function):
                advance(s)
        consume_name(s, c"expected parameter name")
        consume(s, tk.TokenKind.colon, c"expected ':' after parameter name")
        parse_type_ref(s)
        if match_kind(s, tk.TokenKind.tk_as):
            parse_type_ref(s)
        if not match_kind(s, tk.TokenKind.comma):
            break
    consume(s, tk.TokenKind.rparen, c"expected ')'")


function parse_params_producing(s: ref[ParserState]) -> span[ast.Param]:
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
        var ptype = parse_type_ref_producing(s)
        if match_kind(s, tk.TokenKind.tk_as):
            parse_type_ref(s)
        unsafe:
            var pm = ast.Param(name = name_str, param_type = read(ptype), line = ln, column = cn)
            params.push(pm)
        if not match_kind(s, tk.TokenKind.comma):
            break
    consume(s, tk.TokenKind.rparen, c"expected ')'")
    let result = params.as_span()
    params.release()
    return result


function parse_type_ref(s: ref[ParserState]) -> void:
    var _tr = parse_type_ref_producing(s)


function parse_type_ref_producing(s: ref[ParserState]) -> ptr[ast.TypeRef]:
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


function parse_callable_type_ref(s: ref[ParserState], is_proc_val: bool) -> ptr[ast.TypeRef]:
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
            var ptype = parse_type_ref_producing(s)
            unsafe:
                params_vec.push(ast.Param(name = pname, param_type = read(ptype), line = pln, column = pcn))
            if not match_kind(s, tk.TokenKind.comma):
                break
            if check(s, tk.TokenKind.rparen):
                break
    consume(s, tk.TokenKind.rparen, c"expected ')' after callable type params")
    consume(s, tk.TokenKind.arrow, c"expected '->' after callable type params")
    var ret_type = parse_type_ref_producing(s)
    var node = heap_mod.must_alloc[ast.TypeRef](1)
    var params_span = params_vec.as_span()
    params_vec.release()
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


function parse_dyn_type_ref(s: ref[ParserState]) -> ptr[ast.TypeRef]:
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
    var iface_qname = ast.QualifiedName(parts = parts_vec.as_span(), type_arguments = span[ast.TypeRef](), line = ln, column = cn)
    # Optionally consume type arguments for generic interfaces like dyn[Mapper[int]]
    if match_kind(s, tk.TokenKind.lbracket):
        var depth: int = 1
        while not eof(s) and depth > 0:
            step(s)
            if check(s, tk.TokenKind.lbracket):
                depth += 1
                advance(s)
            else if check(s, tk.TokenKind.rbracket):
                depth -= 1
                advance(s)
            else:
                advance(s)
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
    parts_vec.release()
    return node


function parse_tuple_or_parenthesized_type(s: ref[ParserState]) -> ptr[ast.TypeRef]:
    let start_tok = peek(s) else:
        fatal(c"unexpected eof in tuple type")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var first_type = parse_type_ref_producing(s)
    if match_kind(s, tk.TokenKind.comma):
        var types_vec = vec.Vec[ast.TypeRef].create()
        unsafe:
            types_vec.push(read(first_type))
        while true:
            step(s)
            if check(s, tk.TokenKind.rparen):
                break
            var next_type = parse_type_ref_producing(s)
            unsafe:
                types_vec.push(read(next_type))
            if not match_kind(s, tk.TokenKind.comma):
                break
            if check(s, tk.TokenKind.rparen):
                break
        consume(s, tk.TokenKind.rparen, c"expected ')' after tuple type elements")
        var nullable = match_kind(s, tk.TokenKind.question)
        var types_span = types_vec.as_span()
        types_vec.release()
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


function parse_named_type_ref(s: ref[ParserState], allow_nullable: bool) -> ptr[ast.TypeRef]:
    let tok = peek(s) else:
        fatal(c"unexpected eof in type ref")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(tok).line
        cn = read(tok).column
    consume_name(s, c"expected type name")
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
                consume(s, tk.TokenKind.comma, c"expected ',' after lifetime in type arguments")
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
    part_names.release()
    type_args_vec.release()
    return node


function parse_type_argument(s: ref[ParserState]) -> ptr[ast.TypeRef]:
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
        parts.release()
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
        parts.release()
        return node
    return parse_named_type_ref(s, true)


function parse_block(s: ref[ParserState]) -> void:
    consume(s, tk.TokenKind.colon, c"expected ':' before block")
    consume(s, tk.TokenKind.newline, c"expected newline before block body")
    skip_newlines(s)
    consume(s, tk.TokenKind.indent, c"expected indented block")
    parse_block_body(s)
    consume(s, tk.TokenKind.dedent, c"expected end of block")


function parse_block_producing(s: ref[ParserState]) -> ptr[ast.Stmt]:
    consume(s, tk.TokenKind.colon, c"expected ':' before block")
    consume(s, tk.TokenKind.newline, c"expected newline before block body")
    skip_newlines(s)
    consume(s, tk.TokenKind.indent, c"expected indented block")
    var body_span = parse_block_body_producing(s)
    consume(s, tk.TokenKind.dedent, c"expected end of block")
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_block(statements = body_span)
    return node


function parse_block_body(s: ref[ParserState]) -> void:
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        step(s)
        if check(s, tk.TokenKind.newline):
            advance(s)
            skip_newlines(s)
            continue
        parse_statement(s)
        skip_newlines(s)


function parse_block_body_producing(s: ref[ParserState]) -> span[ast.Stmt]:
    var stmts = vec.Vec[ast.Stmt].create()
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        step(s)
        if check(s, tk.TokenKind.newline):
            advance(s)
            skip_newlines(s)
            continue
        let stmt = parse_statement(s)
        unsafe:
            stmts.push(read(stmt))
        skip_newlines(s)
    let result = stmts.as_span()
    stmts.release()
    return result


# =============================================================================
#  Statements
# =============================================================================

function parse_statement(s: ref[ParserState]) -> ptr[ast.Stmt]:
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
        unsafe:
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
        unsafe:
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
        unsafe:
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


function stmt_error_sentinel(s: ref[ParserState], msg: cstr) -> ptr[ast.Stmt]:
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_error(line = 0, column = 0, message = "parse error")
    return node


function parse_local_decl(s: ref[ParserState], is_let: bool) -> ptr[ast.Stmt]:
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
        stmt_type = parse_type_ref_producing(s)
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
        var body_span = parse_block_body_producing(s)
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


function parse_destructure_bindings(s: ref[ParserState]) -> Option[span[str]]:
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
    bindings.release()
    return Option[span[str]].some(value = result)


function parse_if_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
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
    while check(s, tk.TokenKind.tk_else) and check_next(s, tk.TokenKind.tk_if):
        advance(s)
        advance(s)
        condition = parse_expression(s)
        var elif_body = parse_if_branch_body(s)
        var elif_branch = ast.IfBranch(condition = condition, body = elif_body, line = 0, column = 0)
        branches.push(elif_branch)
    if match_kind(s, tk.TokenKind.tk_else):
        else_body = parse_else_branch_body(s)
    var branches_span = branches.as_span()
    branches.release()
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_if(branches = branches_span, else_body = else_body,
            is_inline = false, line = start_ln, else_line = 0, else_column = 0)
    return node


function parse_if_branch_body(s: ref[ParserState]) -> ptr[ast.Stmt]:
    consume(s, tk.TokenKind.colon, c"expected ':' after if condition")
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented body")
        var body_span = parse_block_body_producing(s)
        consume(s, tk.TokenKind.dedent, c"expected end of body")
        var node = alloc_stmt(s)
        unsafe:
            read(node) = ast.Stmt.stmt_block(statements = body_span)
        return node
    else:
        s.in_inline_block_body = true
        var result = parse_statement(s)
        s.in_inline_block_body = false
        return result


function parse_else_branch_body(s: ref[ParserState]) -> ptr[ast.Stmt]:
    consume(s, tk.TokenKind.colon, c"expected ':' after else")
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented else body")
        var body_span = parse_block_body_producing(s)
        consume(s, tk.TokenKind.dedent, c"expected end of else body")
        var node = alloc_stmt(s)
        unsafe:
            read(node) = ast.Stmt.stmt_block(statements = body_span)
        return node
    else:
        s.in_inline_block_body = true
        var result = parse_statement(s)
        s.in_inline_block_body = false
        return result


function parse_block_or_inline_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented body")
        var body_span = parse_block_body_producing(s)
        consume(s, tk.TokenKind.dedent, c"expected end of body")
        var node = alloc_stmt(s)
        unsafe:
            read(node) = ast.Stmt.stmt_block(statements = body_span)
        return node
    else:
        s.in_inline_block_body = true
        var result = parse_statement(s)
        s.in_inline_block_body = false
        consume_end_of_statement(s)
        return result


function parse_while_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in while")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var condition = parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after while condition")
    var is_inline = false
    var body = alloc_stmt(s)
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented while body")
        var body_span = parse_block_body_producing(s)
        consume(s, tk.TokenKind.dedent, c"expected end of while body")
        unsafe:
            read(body) = ast.Stmt.stmt_block(statements = body_span)
    else:
        is_inline = true
        body = parse_statement(s)
        consume_end_of_statement(s)
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_while(condition = condition, body = body, is_inline = is_inline, line = ln, column = cn)
    return node


function parse_for_stmt(s: ref[ParserState], threaded: bool) -> ptr[ast.Stmt]:
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
    consume(s, tk.TokenKind.colon, c"expected ':' after for iterable")
    var body = alloc_stmt(s)
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented for body")
        var body_span = parse_block_body_producing(s)
        consume(s, tk.TokenKind.dedent, c"expected end of for body")
        body = alloc_stmt(s)
        unsafe:
            read(body) = ast.Stmt.stmt_block(statements = body_span)
    var bindings_span = bindings.as_span()
    var iterables_span = iterables.as_span()
    bindings.release()
    iterables.release()
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_for(bindings = bindings_span, iterables = iterables_span,
            body = body, is_inline = false, threaded = threaded, line = ln, column = cn)
    return node


function parse_match_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
    var scrutinee = parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after match expression")
    var is_expr_form = not check(s, tk.TokenKind.newline)
    if is_expr_form:
        var arms = vec.Vec[ast.MatchExprArm].create()
        while true:
            step(s)
            let arm = parse_match_expr_arm(s)
            arms.push(arm)
            if not match_kind(s, tk.TokenKind.comma) and not check(s, tk.TokenKind.newline):
                break
        var arms_span = arms.as_span()
        arms.release()
        var node = alloc_expr(s)
        unsafe:
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
        let arm = parse_match_arm_producing(s)
        arms.push(arm)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of match body")
    var arms_span = arms.as_span()
    arms.release()
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_match(scrutinee = scrutinee, arms = arms_span, is_inline = false, line = 0, column = 0)
    return node


function parse_match_arm(s: ref[ParserState]) -> void:
    if match_kind(s, tk.TokenKind.tk_else):
        pass
    else if is_wildcard_match(s):
        pass
    else:
        parse_pattern(s)
    if match_kind(s, tk.TokenKind.tk_as):
        consume_name(s, c"expected binding name after as")
    consume(s, tk.TokenKind.colon, c"expected ':' after match pattern")
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented match arm body")
        parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of match arm body")


function is_wildcard_match(s: ref[ParserState]) -> bool:
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


function parse_match_arm_producing(s: ref[ParserState]) -> ast.MatchArm:
    var pattern: ptr[ast.Expr]? = null
    if match_kind(s, tk.TokenKind.tk_else):
        pass
    else if is_wildcard_match(s):
        pass
    else:
        pattern = parse_pattern_producing(s)
        while match_kind(s, tk.TokenKind.pipe):
            parse_pattern_producing(s)
    var binding_name: Option[str] = Option[str].none
    if match_kind(s, tk.TokenKind.tk_as):
        consume_name(s, c"expected binding name after as")
        binding_name = Option[str].some(value = previous_lexeme(s))
    consume(s, tk.TokenKind.colon, c"expected ':' after match pattern")
    var body = alloc_stmt(s)
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented match arm body")
        var body_span = parse_block_body_producing(s)
        consume(s, tk.TokenKind.dedent, c"expected end of match arm body")
        body = alloc_stmt(s)
        unsafe:
            read(body) = ast.Stmt.stmt_block(statements = body_span)
    return ast.MatchArm(pattern = pattern, binding_name = binding_name, binding_line = 0, binding_column = 0, body = body)


function parse_return_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
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
    unsafe:
        read(node) = ast.Stmt.stmt_ret(value = value, line = ln, column = cn)
    return node


function parse_defer_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in defer")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var expression: ptr[ast.Expr]? = null
    var body = alloc_stmt(s)
    if match_kind(s, tk.TokenKind.colon):
        if match_kind(s, tk.TokenKind.newline):
            consume(s, tk.TokenKind.indent, c"expected indented defer body")
            var body_span = parse_block_body_producing(s)
            consume(s, tk.TokenKind.dedent, c"expected end of defer body")
            body = alloc_stmt(s)
            unsafe:
                read(body) = ast.Stmt.stmt_block(statements = body_span)
        else:
            body = parse_statement(s)
    else:
        expression = parse_expression(s)
        consume_end_of_statement(s)
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_defer(expression = expression, body = body, line = ln, column = cn)
    return node


function parse_unsafe_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in unsafe")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var body = alloc_stmt(s)
    if match_kind(s, tk.TokenKind.colon):
        if match_kind(s, tk.TokenKind.newline):
            consume(s, tk.TokenKind.indent, c"expected indented unsafe body")
            var body_span = parse_block_body_producing(s)
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
    unsafe:
        read(node) = ast.Stmt.stmt_unsafe(body = body, line = ln, column = cn)
    return node


function parse_static_assert_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
    consume(s, tk.TokenKind.lparen, c"expected '(' after static_assert")
    var condition = parse_expression(s)
    consume(s, tk.TokenKind.comma, c"expected ',' after condition")
    var message_expr = parse_expression(s)
    consume(s, tk.TokenKind.rparen, c"expected ')'")
    consume_end_of_statement(s)
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_static_assert(condition = condition, message = "", line = 0)
    return node


function parse_expression_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
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
        unsafe:
            read(node) = ast.Stmt.stmt_assignment(target = left, operator = op, value = right, line = 0, column = 0)
        return node
    if not block_expression(left):
        consume_end_of_statement(s)
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_expression(expression = left, line = 0)
    return node


function parse_parallel_block(s: ref[ParserState]) -> ptr[ast.Stmt]:
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
        var wrapper = alloc_stmt(s)
        unsafe:
            read(wrapper) = ast.Stmt.stmt_block(statements = span[ast.Stmt]())
            bodies.push(read(wrapper))
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of parallel body")
    var bodies_span = bodies.as_span()
    bodies.release()
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_parallel_block(bodies = bodies_span, line = ln, column = cn)
    return node


function parse_gather_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
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
    handles.release()
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_gather(handles = handles_span, line = 0, column = 0)
    return node


function parse_pattern(s: ref[ParserState]) -> void:
    if check(s, tk.TokenKind.colon) or check(s, tk.TokenKind.newline):
        return
    advance(s)
    while match_kind(s, tk.TokenKind.dot):
        consume_name(s, c"expected member name after '.'")


function parse_pattern_producing(s: ref[ParserState]) -> ptr[ast.Expr]:
    if check(s, tk.TokenKind.colon) or check(s, tk.TokenKind.newline):
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_error(line = 0, column = 0, message = "empty pattern")
        return node
    var result = parse_expression(s)
    return result


function parse_when_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
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
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        skip_newlines(s)
        if check(s, tk.TokenKind.tk_else):
            advance(s)
            consume(s, tk.TokenKind.colon, c"expected ':' after else")
            var else_body_val = parse_block_or_inline_stmt(s)
            skip_newlines(s)
            break
        var pat = parse_expression(s)
        var binding: Option[str] = Option[str].none
        if match_kind(s, tk.TokenKind.tk_as):
            consume_name(s, c"expected binding name after as")
            binding = Option[str].some(value = previous_lexeme(s))
        var branch_body = parse_block_or_inline_stmt(s)
        var wb = ast.WhenBranch(pattern = pat, binding_name = binding, binding_line = 0, binding_column = 0, body = span[ast.Stmt]())
        branches.push(wb)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of when body")
    var branches_span = branches.as_span()
    branches.release()
    var null_body = alloc_stmt(s)
    unsafe:
        read(null_body) = ast.Stmt.stmt_block(statements = span[ast.Stmt]())
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_when(discriminant = discriminant, branches = branches_span, else_body = null_body, line = ln, column = cn)
    return node


function parse_emit_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
    let start_tok = peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in emit")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    parse_declaration(s)
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_emit(declaration = null, line = ln, column = cn)
    return node


function parse_inline_for_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
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
    var body_span = parse_block_body_producing(s)
    consume(s, tk.TokenKind.dedent, c"expected end of block")
    var bindings_span = bindings.as_span()
    var iterables_span = iterables.as_span()
    bindings.release()
    iterables.release()
    var body = alloc_stmt(s)
    unsafe:
        read(body) = ast.Stmt.stmt_block(statements = body_span)
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_for(bindings = bindings_span, iterables = iterables_span,
            body = body, is_inline = true, threaded = false, line = ln, column = cn)
    return node


function parse_inline_while_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
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
    var body_span = parse_block_body_producing(s)
    consume(s, tk.TokenKind.dedent, c"expected end of body")
    var body = alloc_stmt(s)
    unsafe:
        read(body) = ast.Stmt.stmt_block(statements = body_span)
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_while(condition = condition, body = body, is_inline = true, line = ln, column = cn)
    return node


function parse_inline_match_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
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
        let arm = parse_match_arm_producing(s)
        arms.push(arm)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of match body")
    var arms_span = arms.as_span()
    arms.release()
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_match(scrutinee = scrutinee, arms = arms_span, is_inline = true, line = ln, column = cn)
    return node


function parse_inline_if_stmt(s: ref[ParserState]) -> ptr[ast.Stmt]:
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
    branches.release()
    var node = alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_if(branches = branches_span, else_body = else_body,
            is_inline = true, line = start_ln, else_line = 0, else_column = 0)
    return node

# =============================================================================
#  Expressions
# =============================================================================

function parse_expression(s: ref[ParserState]) -> ptr[ast.Expr]:
    if match_kind(s, tk.TokenKind.tk_if):
        return parse_if_expression(s)
    if match_kind(s, tk.TokenKind.tk_match):
        return parse_match_expression(s)
    if match_kind(s, tk.TokenKind.tk_unsafe):
        return parse_unsafe_expression(s)
    return parse_range(s)


function parse_range(s: ref[ParserState]) -> ptr[ast.Expr]:
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
        unsafe:
            read(node) = ast.Expr.expr_range(start_expr = left, end_expr = right, line = line_left, column = col_left)
        return node
    return left


function parse_or(s: ref[ParserState]) -> ptr[ast.Expr]:
    var left = parse_and(s)
    while match_kind(s, tk.TokenKind.tk_or):
        let op = previous_lexeme(s)
        var right = parse_and(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_and(s: ref[ParserState]) -> ptr[ast.Expr]:
    var left = parse_not(s)
    while match_kind(s, tk.TokenKind.tk_and):
        let op = previous_lexeme(s)
        var right = parse_not(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_not(s: ref[ParserState]) -> ptr[ast.Expr]:
    if match_kind(s, tk.TokenKind.tk_not):
        let op = previous_lexeme(s)
        var operand = parse_not(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_unary_op(operator = op, operand = operand)
        return node
    return parse_is(s)


function parse_is(s: ref[ParserState]) -> ptr[ast.Expr]:
    var left = parse_bitwise_or(s)
    if match_kind(s, tk.TokenKind.tk_is):
        var pattern = parse_expression(s)
        return is_desugar(s, left, pattern)
    return left


function parse_bitwise_or(s: ref[ParserState]) -> ptr[ast.Expr]:
    var left = parse_bitwise_xor(s)
    while match_kind(s, tk.TokenKind.pipe):
        let op = previous_lexeme(s)
        var right = parse_bitwise_xor(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_bitwise_xor(s: ref[ParserState]) -> ptr[ast.Expr]:
    var left = parse_bitwise_and(s)
    while match_kind(s, tk.TokenKind.caret):
        let op = previous_lexeme(s)
        var right = parse_bitwise_and(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_bitwise_and(s: ref[ParserState]) -> ptr[ast.Expr]:
    var left = parse_equality(s)
    while match_kind(s, tk.TokenKind.amp):
        let op = previous_lexeme(s)
        var right = parse_equality(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_equality(s: ref[ParserState]) -> ptr[ast.Expr]:
    var left = parse_comparison(s)
    while check(s, tk.TokenKind.equal_equal) or check(s, tk.TokenKind.bang_equal):
        advance(s)
        let op = previous_lexeme(s)
        var right = parse_comparison(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_comparison(s: ref[ParserState]) -> ptr[ast.Expr]:
    var left = parse_shift(s)
    while (
        check(s, tk.TokenKind.less) or check(s, tk.TokenKind.less_equal)
        or check(s, tk.TokenKind.greater) or check(s, tk.TokenKind.greater_equal)
    ):
        advance(s)
        let op = previous_lexeme(s)
        var right = parse_shift(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_shift(s: ref[ParserState]) -> ptr[ast.Expr]:
    var left = parse_additive(s)
    while check(s, tk.TokenKind.shift_left) or check(s, tk.TokenKind.shift_right):
        advance(s)
        let op = previous_lexeme(s)
        var right = parse_additive(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_additive(s: ref[ParserState]) -> ptr[ast.Expr]:
    var left = parse_multiplicative(s)
    while check(s, tk.TokenKind.plus) or check(s, tk.TokenKind.minus):
        advance(s)
        let op = previous_lexeme(s)
        var right = parse_multiplicative(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_multiplicative(s: ref[ParserState]) -> ptr[ast.Expr]:
    var left = parse_unary(s)
    while check(s, tk.TokenKind.star) or check(s, tk.TokenKind.slash) or check(s, tk.TokenKind.percent):
        advance(s)
        let op = previous_lexeme(s)
        var right = parse_unary(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_unary(s: ref[ParserState]) -> ptr[ast.Expr]:
    if match_kind(s, tk.TokenKind.tk_unsafe):
        return parse_unsafe_expression(s)
    if match_kind(s, tk.TokenKind.tk_await):
        var operand = parse_unary(s)
        var node = alloc_expr(s)
        unsafe:
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
        unsafe:
            read(node) = ast.Expr.expr_detach(expression = expr_val, line = detach_line, column = detach_col)
        return node
    if check(s, tk.TokenKind.minus) or check(s, tk.TokenKind.tilde) or check(s, tk.TokenKind.plus):
        advance(s)
        let op = previous_lexeme(s)
        var operand = parse_unary(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_unary_op(operator = op, operand = operand)
        return node
    if check(s, tk.TokenKind.tk_out) or check(s, tk.TokenKind.tk_in) or check(s, tk.TokenKind.tk_inout):
        advance(s)
        let op = previous_lexeme(s)
        var operand = parse_unary(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_unary_op(operator = op, operand = operand)
        return node
    var cast_result = try_parse_prefix_cast_expression(s)
    match cast_result:
        Option.some as cast_payload:
            return cast_payload.value
        Option.none:
            pass
    return parse_postfix(s)


function parse_postfix(s: ref[ParserState]) -> ptr[ast.Expr]:
    var left = parse_primary(s)
    while true:
        step(s)
        if match_kind(s, tk.TokenKind.dot):
            consume_name(s, c"expected member name after '.'")
            let member = previous_lexeme(s)
            var node = alloc_expr(s)
            unsafe:
                read(node) = ast.Expr.expr_member_access(receiver = left, member_name = member, line = 0, column = 0)
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
                        unsafe:
                            read(node) = ast.Expr.expr_index_access(receiver = left, index = idx)
                        left = node
            else:
                advance(s)
                var idx = parse_expression(s)
                consume(s, tk.TokenKind.rbracket, c"expected ']'")
                var node = alloc_expr(s)
                unsafe:
                    read(node) = ast.Expr.expr_index_access(receiver = left, index = idx)
                left = node
        else if match_kind(s, tk.TokenKind.lparen):
            var args = parse_call_args(s)
            consume(s, tk.TokenKind.rparen, c"expected ')'")
            var node = alloc_expr(s)
            unsafe:
                read(node) = ast.Expr.expr_call(callee = left, args = args)
            left = node
        else if match_kind(s, tk.TokenKind.question):
            var node = alloc_expr(s)
            unsafe:
                read(node) = ast.Expr.expr_unary_op(operator = "?", operand = left)
            left = node
        else:
            break
    return left


function postfix_bracket_starts_specialization(s: ref[ParserState], left: ptr[ast.Expr]) -> bool:
    return specialization_target(left) and matching_rbracket_index(s, s.stream.current).is_some()


function specialization_target(left: ptr[ast.Expr]) -> bool:
    unsafe:
        let e = read(left)
        return e is ast.Expr.expr_identifier or e is ast.Expr.expr_member_access


function try_parse_specialization(s: ref[ParserState], left: ptr[ast.Expr]) -> Option[ptr[ast.Expr]]:
    let saved = s.stream.current
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
    if not closed:
        s.stream.current = saved
        args_vec.release()
        return Option[ptr[ast.Expr]].none
    if match_kind(s, tk.TokenKind.lparen):
        var call_args = parse_call_args(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
        var node = alloc_expr(s)
        let args_span = args_vec.as_span()
        var spec = alloc_expr(s)
        unsafe:
            read(spec) = ast.Expr.expr_specialization(callee = left, arguments = args_span)
        args_vec.release()
        var call = alloc_expr(s)
        unsafe:
            read(call) = ast.Expr.expr_call(callee = spec, args = call_args)
        return Option[ptr[ast.Expr]].some(value = call)
    var node = alloc_expr(s)
    let args_span = args_vec.as_span()
    unsafe:
        read(node) = ast.Expr.expr_specialization(callee = left, arguments = args_span)
    args_vec.release()
    return Option[ptr[ast.Expr]].some(value = node)


function parse_primary(s: ref[ParserState]) -> ptr[ast.Expr]:
    if match_kind(s, tk.TokenKind.integer):
        let lex = previous_lexeme(s)
        let val = parse_int_literal(lex)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_integer_literal(lexeme = lex, value = val)
        return node
    else if match_kind(s, tk.TokenKind.float_literal):
        let lex = previous_lexeme(s)
        let val = parse_float_literal(lex)
        var node = alloc_expr(s)
        unsafe:
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
        unsafe:
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
        unsafe:
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
        unsafe:
            read(node) = ast.Expr.expr_char_literal(lexeme = lex, value = val, line = ln, column = cn)
        return node
    else if match_kind(s, tk.TokenKind.tk_true):
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_bool_literal(value = true)
        return node
    else if match_kind(s, tk.TokenKind.tk_false):
        var node = alloc_expr(s)
        unsafe:
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
            target = parse_type_ref_producing(s)
            consume(s, tk.TokenKind.rbracket, c"expected ']' after null type")
        var node = alloc_expr(s)
        unsafe:
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
        unsafe:
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
                read(first_expr) = ast.Expr.expr_identifier(name = name_str, line = 0, column = 0)
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
                        read(ne) = ast.Expr.expr_identifier(name = name_str, line = 0, column = 0)
                    unsafe:
                        elems.push(read(ne))
                    let _v2 = val2
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
            elems.release()
            var node = alloc_expr(s)
            unsafe:
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
        var type_ref = parse_type_ref_producing(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_sizeof(target_type = type_ref)
        return node
    else if match_kind(s, tk.TokenKind.tk_align_of):
        consume(s, tk.TokenKind.lparen, c"expected '(' after align_of")
        var type_ref = parse_type_ref_producing(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_alignof(target_type = type_ref)
        return node
    else if match_kind(s, tk.TokenKind.tk_offset_of):
        consume(s, tk.TokenKind.lparen, c"expected '(' after offset_of")
        var type_ref = parse_type_ref_producing(s)
        consume(s, tk.TokenKind.comma, c"expected ','")
        consume_name(s, c"expected field name")
        let field_name = previous_lexeme(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_offsetof(target_type = type_ref, field = field_name)
        return node
    else if match_kind(s, tk.TokenKind.fstring):
        let lex = previous_lexeme(s)
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_string_literal(lexeme = lex, value = lex, is_cstring = false)
        return node
    else:
        let tok_ptr = peek(s) else:
            parser_error_naked(s, c"expected expression")
            var node = alloc_expr(s)
            unsafe:
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
            unsafe:
                read(node) = ast.Expr.expr_identifier(name = token_mod.token_lexeme(tok, s.source), line = ln, column = cn)
            return node
        parser_error_naked(s, c"expected expression")
        var node = alloc_expr(s)
        unsafe:
            read(node) = ast.Expr.expr_error(line = 0, column = 0, message = "expected expression")
        return node


# =============================================================================
#  If expression
# =============================================================================

function parse_if_expression(s: ref[ParserState]) -> ptr[ast.Expr]:
    var condition = parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after if condition")
    var then_expr = parse_expression(s)
    consume(s, tk.TokenKind.tk_else, c"expected 'else' in if expression")
    consume(s, tk.TokenKind.colon, c"expected ':' after else")
    var else_expr = parse_expression(s)
    var node = alloc_expr(s)
    unsafe:
        read(node) = ast.Expr.expr_if(condition = condition, then_expr = then_expr, else_expr = else_expr)
    return node


# =============================================================================
#  Match expression
# =============================================================================

function parse_match_expression(s: ref[ParserState]) -> ptr[ast.Expr]:
    var scrutinee = parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after match expression")
    consume(s, tk.TokenKind.newline, c"expected newline after match header")
    consume(s, tk.TokenKind.indent, c"expected indented match body")
    var arms = parse_match_expr_arms(s)
    consume(s, tk.TokenKind.dedent, c"expected end of match body")
    var node = alloc_expr(s)
    unsafe:
        read(node) = ast.Expr.expr_match(scrutinee = scrutinee, arms = arms, line = 0, column = 0)
    return node


function parse_match_expr_arms(s: ref[ParserState]) -> span[ast.MatchExprArm]:
    var arms = vec.Vec[ast.MatchExprArm].create()
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        let arm = parse_match_expr_arm(s)
        arms.push(arm)
        skip_newlines(s)
    let result = arms.as_span()
    arms.release()
    return result


function parse_match_expr_arm(s: ref[ParserState]) -> ast.MatchExprArm:
    var pattern: ptr[ast.Expr]? = null
    if match_kind(s, tk.TokenKind.tk_else):
        pass
    else if is_wildcard_match(s):
        pass
    else:
        pattern = parse_pattern_producing(s)
    var binding_name: Option[str] = Option[str].none
    if match_kind(s, tk.TokenKind.tk_as):
        consume_name(s, c"expected binding name after as")
        binding_name = Option[str].some(value = previous_lexeme(s))
    consume(s, tk.TokenKind.colon, c"expected ':' after match pattern")
    var value = parse_expression(s)
    if not block_expression(value):
        consume_end_of_statement(s)
    return ast.MatchExprArm(pattern = pattern, binding_name = binding_name, value = value)


# =============================================================================
#  Proc / fn expression
# =============================================================================

function parse_proc_expr_after_proc(s: ref[ParserState]) -> ptr[ast.Expr]:
    var params = parse_params_producing(s)
    var return_type: ptr[ast.TypeRef]? = null
    if match_kind(s, tk.TokenKind.arrow):
        return_type = parse_type_ref_producing(s)
    var body = parse_proc_body(s)
    var node = alloc_expr(s)
    unsafe:
        read(node) = ast.Expr.expr_proc(method_params = params, return_type = return_type, body = body)
    return node


function parse_proc_body(s: ref[ParserState]) -> ptr[ast.Stmt]:
    if match_kind(s, tk.TokenKind.colon):
        if match_kind(s, tk.TokenKind.newline):
            consume(s, tk.TokenKind.indent, c"expected indented proc body")
            var stmts_span = parse_block_body_producing(s)
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

function parse_unsafe_expression(s: ref[ParserState]) -> ptr[ast.Expr]:
    let tok = previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = tok.line
        cn = tok.column
    consume(s, tk.TokenKind.colon, c"expected ':' after unsafe")
    var expr_val = parse_expression(s)
    var node = alloc_expr(s)
    unsafe:
        read(node) = ast.Expr.expr_unsafe(expression = expr_val, line = ln, column = cn)
    return node


# =============================================================================
#  is-operator desugaring
# =============================================================================

function is_desugar(s: ref[ParserState], left: ptr[ast.Expr], pattern: ptr[ast.Expr]) -> ptr[ast.Expr]:
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
    # Build an array of two arms
    var arms_array: array[ast.MatchExprArm, 2] = array[ast.MatchExprArm, 2](true_arm, false_arm)
    var arms_span = arms_array.as_span()
    var node = alloc_expr(s)
    unsafe:
        read(node) = ast.Expr.expr_match(scrutinee = left, arms = arms_span, line = 0, column = 0)
    return node


# =============================================================================
#  Prefix cast: T<-expr
# =============================================================================

function try_parse_prefix_cast_expression(s: ref[ParserState]) -> Option[ptr[ast.Expr]]:
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
    var target_type = parse_named_type_ref(s, false)
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
    unsafe:
        read(node) = ast.Expr.expr_prefix_cast(target_type = target_type, expression = expr_val, line = 0, column = 0)
    return Option[ptr[ast.Expr]].some(value = node)


# =============================================================================
#  Call arguments (producing)
# =============================================================================

function parse_call_args(s: ref[ParserState]) -> span[ast.Argument]:
    var args = vec.Vec[ast.Argument].create()
    if check(s, tk.TokenKind.rparen):
        return span[ast.Argument]()
    while true:
        step(s)
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
    let result = args.as_span()
    args.release()
    return result


function parse_struct_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected struct name")
    if match_kind(s, tk.TokenKind.lbracket):
        parse_declaration_type_params(s)
    if match_kind(s, tk.TokenKind.tk_implements):
        skip_implements_clause(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after struct name")
    consume(s, tk.TokenKind.newline, c"expected newline")
    skip_newlines(s)
    consume(s, tk.TokenKind.indent, c"expected indented struct body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        if match_kind(s, tk.TokenKind.tk_event):
            parse_event_decl(s)
        else if check(s, tk.TokenKind.tk_struct):
            parse_struct_decl(s)
        else:
            parse_struct_member(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of struct body")


function parse_struct_member(s: ref[ParserState]) -> void:
    consume_name(s, c"expected field name")
    consume(s, tk.TokenKind.colon, c"expected ':' after field name")
    parse_type_ref(s)
    consume_end_of_statement(s)


function skip_implements_clause(s: ref[ParserState]) -> void:
    parse_qualified_name(s)
    while match_kind(s, tk.TokenKind.comma):
        parse_qualified_name(s)


function parse_type_alias(s: ref[ParserState]) -> void:
    consume_name(s, c"expected type alias name")
    consume(s, tk.TokenKind.equal, c"expected '=' after type alias name")
    parse_type_ref(s)
    consume_end_of_statement(s)


function parse_enum_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected enum name")
    if match_kind(s, tk.TokenKind.colon):
        if not (check(s, tk.TokenKind.newline) or check(s, tk.TokenKind.indent)):
            parse_type_ref(s)
    consume(s, tk.TokenKind.newline, c"expected newline")
    skip_newlines(s)
    consume(s, tk.TokenKind.indent, c"expected indented enum body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        consume_name(s, c"expected member name")
        if match_kind(s, tk.TokenKind.equal):
            parse_expression(s)
        consume_end_of_statement(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of enum body")


function parse_variant_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected variant name")
    if match_kind(s, tk.TokenKind.lbracket):
        parse_declaration_type_params(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after variant name")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented variant body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        consume_name(s, c"expected arm name")
        if match_kind(s, tk.TokenKind.lparen):
            var depth: int = 1
            while not eof(s) and depth > 0:
                step(s)
                if check(s, tk.TokenKind.lparen):
                    depth += 1
                    advance(s)
                else if check(s, tk.TokenKind.rparen):
                    depth -= 1
                    advance(s)
                else:
                    advance(s)
        consume_end_of_statement(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of variant body")


function parse_interface_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected interface name")
    if match_kind(s, tk.TokenKind.lbracket):
        parse_declaration_type_params(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after interface name")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented interface body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        parse_interface_method(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of interface body")


function parse_interface_method(s: ref[ParserState]) -> void:
    match_kind(s, tk.TokenKind.tk_async)
    match_kind(s, tk.TokenKind.tk_editable)
    match_kind(s, tk.TokenKind.tk_static)
    if not check(s, tk.TokenKind.tk_function):
        match_kind(s, tk.TokenKind.tk_editable)
        match_kind(s, tk.TokenKind.tk_static)
    consume(s, tk.TokenKind.tk_function, c"expected function in interface")
    consume_name(s, c"expected method name")
    parse_params(s)
    if match_kind(s, tk.TokenKind.arrow):
        parse_type_ref(s)
    consume_end_of_statement(s)


function parse_opaque_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected opaque type name")
    if match_kind(s, tk.TokenKind.tk_implements):
        skip_implements_clause(s)
    if match_kind(s, tk.TokenKind.equal):
        match_kind(s, tk.TokenKind.cstring)
    consume_end_of_statement(s)


function parse_extending_block(s: ref[ParserState]) -> void:
    parse_type_ref(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after extending type")
    consume(s, tk.TokenKind.newline, c"expected newline")
    skip_newlines(s)
    consume(s, tk.TokenKind.indent, c"expected indented extending body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        parse_extending_method(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of extending body")


function parse_extending_method(s: ref[ParserState]) -> void:
    if match_kind(s, tk.TokenKind.tk_public):
        pass
    else if match_kind(s, tk.TokenKind.tk_editable):
        pass
    else if match_kind(s, tk.TokenKind.tk_static):
        pass
    if not check(s, tk.TokenKind.tk_function):
        if match_kind(s, tk.TokenKind.tk_editable):
            pass
        else if match_kind(s, tk.TokenKind.tk_static):
            pass
    consume(s, tk.TokenKind.tk_function, c"expected function in extending block")
    consume_name(s, c"expected method name")
    if match_kind(s, tk.TokenKind.lbracket):
        parse_declaration_type_params(s)
    parse_params(s)
    if match_kind(s, tk.TokenKind.arrow):
        parse_type_ref(s)
    parse_block(s)


function parse_extern_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected function name")
    if match_kind(s, tk.TokenKind.lbracket):
        parse_declaration_type_params(s)
    parse_params(s)
    if match_kind(s, tk.TokenKind.arrow):
        parse_type_ref(s)
    if match_kind(s, tk.TokenKind.equal):
        parse_expression(s)
    consume_end_of_statement(s)


function parse_foreign_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected function name")
    if match_kind(s, tk.TokenKind.lbracket):
        parse_declaration_type_params(s)
    parse_params(s)
    consume(s, tk.TokenKind.arrow, c"expected '->' before foreign return type")
    parse_type_ref(s)
    consume(s, tk.TokenKind.equal, c"expected '=' before foreign mapping")
    parse_expression(s)
    consume_end_of_statement(s)


function parse_static_assert(s: ref[ParserState]) -> void:
    consume(s, tk.TokenKind.lparen, c"expected '(' after static_assert")
    parse_expression(s)
    consume(s, tk.TokenKind.comma, c"expected ',' after condition")
    parse_expression(s)
    consume(s, tk.TokenKind.rparen, c"expected ')'")
    consume_end_of_statement(s)


function parse_event_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected event name")
    consume(s, tk.TokenKind.lbracket, c"expected '[' after event name")
    consume(s, tk.TokenKind.integer, c"expected capacity")
    consume(s, tk.TokenKind.rbracket, c"expected ']'")
    if match_kind(s, tk.TokenKind.lparen):
        parse_type_ref(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
    consume_end_of_statement(s)


function parse_when_decl(s: ref[ParserState]) -> void:
    var discriminant = parse_expression(s)
    consume_end_of_statement(s)
    skip_newlines(s)
    while not eof(s):
        if check(s, tk.TokenKind.dedent):
            break
        skip_newlines(s)
        if match_kind(s, tk.TokenKind.tk_else):
            consume(s, tk.TokenKind.colon, c"expected ':' after else")
            consume(s, tk.TokenKind.newline, c"expected newline")
            consume(s, tk.TokenKind.indent, c"expected indented else body")
            skip_newlines(s)
            while not check(s, tk.TokenKind.dedent) and not eof(s):
                step(s)
                parse_declaration(s)
                skip_newlines(s)
            consume(s, tk.TokenKind.dedent, c"expected end of else body")
            break
        parse_expression(s)
        if match_kind(s, tk.TokenKind.tk_as):
            consume_name(s, c"expected binding name after as")
        consume(s, tk.TokenKind.colon, c"expected ':' after when pattern")
        consume(s, tk.TokenKind.newline, c"expected newline")
        consume(s, tk.TokenKind.indent, c"expected indented when branch body")
        skip_newlines(s)
        while not check(s, tk.TokenKind.dedent) and not eof(s):
            step(s)
            parse_declaration(s)
            skip_newlines(s)
        consume(s, tk.TokenKind.dedent, c"expected end of when branch body")
        skip_newlines(s)


function parse_attribute_decl(s: ref[ParserState]) -> void:
    consume(s, tk.TokenKind.lbracket, c"expected '[' after attribute")
    while true:
        consume_name(s, c"expected attribute target")
        if not match_kind(s, tk.TokenKind.comma):
            break
    consume(s, tk.TokenKind.rbracket, c"expected ']'")
    consume_name(s, c"expected attribute name")
    if match_kind(s, tk.TokenKind.lparen):
        parse_params(s)
    consume_end_of_statement(s)
