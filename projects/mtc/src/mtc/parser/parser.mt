## Self-hosted parser — transforms a token stream into an AST.
##
## Mirrors the Ruby parser (lib/milk_tea/core/parser.rb) architecture,
## algorithms, and AST node structure.
##
## Loop guard: every while-loop increments a step counter; at 100,000 steps
## the parser aborts to prevent infinite loops during development.

import std.vec as vec

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.lexer.lexer as lexer
import mtc.parser.token_stream as ts


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
        skip_to_sync_point(s)
        return
    unsafe:
        let t = read(tok)
        let lexeme = token_mod.token_lexeme(t, s.source)
        let kn = token_mod.kind_name(t.kind)
        parser_error_at(s, msg, t.line, t.column, lexeme, kn)
    skip_to_sync_point(s)


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
    # Skip at least one token past the current position to avoid
    # re-syncing to the same token that caused the error.
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

function is_declaration_start(s: ref[ParserState]) -> bool:
    return (
        check(s, tk.TokenKind.tk_const) or check(s, tk.TokenKind.tk_var)
        or check(s, tk.TokenKind.tk_function) or check(s, tk.TokenKind.tk_public)
        or check(s, tk.TokenKind.tk_struct) or check(s, tk.TokenKind.tk_enum)
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
    consume(s, tk.TokenKind.identifier, msg)

function consume_end_of_statement(s: ref[ParserState]) -> void:
    if s.in_inline_block_body:
        return
    if check(s, tk.TokenKind.dedent):
        return
    consume(s, tk.TokenKind.newline, c"expected end of statement")

function is_keyword_token(tok: token_mod.Token) -> bool:
    # Tokens that ARE keywords have tk_ prefix kind values.
    # Tokens that are truly identifiers have TokenKind.identifier.
    return tok.kind != tk.TokenKind.identifier

function previous_lexeme(s: ref[ParserState]) -> str:
    let tok = previous(s) else:
        return ""
    unsafe:
        let t = read(tok)
        return tlexeme_from_state(s, t)

function tlexeme_from_state(s: ref[ParserState], tok: token_mod.Token) -> str:
    # Tokens don't store lexemes — we'd need source. Use "" for now.
    # The parser doesn't need lexemes for AST construction.
    return ""


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
    )
    parse_source_file(ref_of(state))
    return true


public function parse_reporting(source: str, errors: ref[vec.Vec[ParseDiagnostic]]) -> bool:
    var state = ParserState(
        stream = ts.create(lexer.lex(source)),
        source = source,
        step_counter = 0,
        in_inline_block_body = false,
        recovery_errors = ptr_of(errors),
    )
    var nodes = parse_source_file(ref_of(state))
    return errors.len() == 0


# =============================================================================
#  Source file
# =============================================================================

function parse_source_file(s: ref[ParserState]) -> ptr_uint:
    skip_newlines(s)
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


# =============================================================================
#  Import
# =============================================================================

function parse_import(s: ref[ParserState]) -> void:
    parse_qualified_name(s)
    if match_kind(s, tk.TokenKind.tk_as):
        consume_name(s, c"expected import alias")
    consume_end_of_statement(s)


function parse_qualified_name(s: ref[ParserState]) -> void:
    consume_name(s, c"expected identifier")
    while match_kind(s, tk.TokenKind.dot):
        consume_name(s, c"expected identifier after '.'")


# =============================================================================
#  Declaration dispatch
# =============================================================================

function skip_attribute_content(s: ref[ParserState]) -> void:
    # Consume attribute name and optional (arguments) inside @[...]
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


function parse_declaration(s: ref[ParserState]) -> void:
    # Skip @[attribute] applications
    while match_kind(s, tk.TokenKind.at):
        consume(s, tk.TokenKind.lbracket, c"expected '[' after @")
        skip_attribute_content(s)
        consume(s, tk.TokenKind.rbracket, c"expected ']' after attribute")
        skip_newlines(s)

    if match_kind(s, tk.TokenKind.tk_const):
        parse_const_decl(s)
    else if match_kind(s, tk.TokenKind.tk_var):
        parse_var_decl(s)
    else if match_kind(s, tk.TokenKind.tk_function):
        parse_function_def(s)
    else if match_kind(s, tk.TokenKind.tk_public):
        # public <declaration> — re-enter parse_declaration
        skip_newlines(s)
        parse_declaration(s)
    else if match_kind(s, tk.TokenKind.tk_struct):
        parse_struct_decl(s)
    else if match_kind(s, tk.TokenKind.tk_type):
        parse_type_alias(s)
    else if match_kind(s, tk.TokenKind.tk_enum):
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


# =============================================================================
#  Declaration stubs
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
    parse_params(s)
    if match_kind(s, tk.TokenKind.arrow):
        parse_type_ref(s)
    parse_block(s)


function parse_params(s: ref[ParserState]) -> void:
    consume(s, tk.TokenKind.lparen, c"expected '('")
    while not eof(s) and not check(s, tk.TokenKind.rparen):
        consume_name(s, c"expected parameter name")
        consume(s, tk.TokenKind.colon, c"expected ':' after parameter name")
        parse_type_ref(s)
        if not match_kind(s, tk.TokenKind.comma):
            break
    consume(s, tk.TokenKind.rparen, c"expected ')'")


function parse_type_ref(s: ref[ParserState]) -> void:
    consume_name(s, c"expected type name")
    while match_kind(s, tk.TokenKind.dot):
        consume_name(s, c"expected type name after '.'")
    if match_kind(s, tk.TokenKind.lbracket):
        # Generic type arguments — parse until rbracket
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
    if match_kind(s, tk.TokenKind.question):
        pass


function parse_block(s: ref[ParserState]) -> void:
    consume(s, tk.TokenKind.colon, c"expected ':' before block")
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented block")
        parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of block")
    else:
        # Inline block — single statement follows
        parse_statement(s)


function parse_block_body(s: ref[ParserState]) -> void:
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        step(s)
        parse_statement(s)
        skip_newlines(s)


# =============================================================================
#  Statements
# =============================================================================

function parse_statement(s: ref[ParserState]) -> void:
    if match_kind(s, tk.TokenKind.tk_let):
        parse_local_decl(s)
    else if match_kind(s, tk.TokenKind.tk_var):
        parse_local_decl(s)
    else if match_kind(s, tk.TokenKind.tk_if):
        parse_if_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_while):
        parse_while_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_for):
        parse_for_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_match):
        parse_match_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_return):
        parse_return_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_break):
        consume_end_of_statement(s)
    else if match_kind(s, tk.TokenKind.tk_continue):
        consume_end_of_statement(s)
    else if match_kind(s, tk.TokenKind.tk_pass):
        consume_end_of_statement(s)
    else if match_kind(s, tk.TokenKind.tk_defer):
        parse_defer_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_unsafe):
        parse_unsafe_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_static_assert):
        parse_static_assert(s)
    else if match_kind(s, tk.TokenKind.tk_when):
        parse_when_stmt(s)
    else if match_kind(s, tk.TokenKind.tk_parallel):
        if check(s, tk.TokenKind.tk_for):
            advance(s)
            parse_for_stmt(s)
        else:
            parse_parallel_block(s)
    else if match_kind(s, tk.TokenKind.tk_gather):
        parse_gather_stmt(s)
    else:
        parse_expression_stmt(s)


function parse_local_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected variable name")
    if match_kind(s, tk.TokenKind.colon):
        parse_type_ref(s)
    if match_kind(s, tk.TokenKind.equal):
        parse_expression(s)
    if match_kind(s, tk.TokenKind.tk_else):
        # let ... else: guard block
        if match_kind(s, tk.TokenKind.tk_as):
            consume_name(s, c"expected error binding name")
        consume(s, tk.TokenKind.colon, c"expected ':' after else")
        consume(s, tk.TokenKind.newline, c"expected newline after else:")
        consume(s, tk.TokenKind.indent, c"expected indented else body")
        parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of else body")
        return
    if match_kind(s, tk.TokenKind.question):
        pass
    consume_end_of_statement(s)


function parse_if_stmt(s: ref[ParserState]) -> void:
    parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after if condition")
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented if body")
        parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of if body")
    else:
        # Inline if
        parse_statement(s)
    if match_kind(s, tk.TokenKind.tk_else):
        consume(s, tk.TokenKind.colon, c"expected ':' after else")
        if match_kind(s, tk.TokenKind.newline):
            consume(s, tk.TokenKind.indent, c"expected indented else body")
            parse_block_body(s)
            consume(s, tk.TokenKind.dedent, c"expected end of else body")
        else if match_kind(s, tk.TokenKind.tk_if):
            # else if
            parse_if_stmt(s)
        else:
            # Inline else
            parse_statement(s)


function parse_while_stmt(s: ref[ParserState]) -> void:
    parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after while condition")
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented while body")
        parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of while body")
    else:
        parse_statement(s)
        consume_end_of_statement(s)


function parse_for_stmt(s: ref[ParserState]) -> void:
    consume_name(s, c"expected loop variable")
    if match_kind(s, tk.TokenKind.comma):
        parse_loop_bindings(s)
    consume(s, tk.TokenKind.tk_in, c"expected 'in' after for bindings")
    parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after for iterable")
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented for body")
        parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of for body")


function parse_loop_bindings(s: ref[ParserState]) -> void:
    consume_name(s, c"expected loop variable")
    while match_kind(s, tk.TokenKind.comma):
        consume_name(s, c"expected loop variable")


function parse_match_stmt(s: ref[ParserState]) -> void:
    parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after match expression")
    consume(s, tk.TokenKind.newline, c"expected newline after match header")
    consume(s, tk.TokenKind.indent, c"expected indented match body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        skip_newlines(s)
        parse_match_arm(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of match body")


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


function parse_match_arm(s: ref[ParserState]) -> void:
    if is_wildcard_match(s):
        pass
    else:
        parse_pattern(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after match pattern")
    if match_kind(s, tk.TokenKind.newline):
        consume(s, tk.TokenKind.indent, c"expected indented match arm body")
        parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of match arm body")


function parse_pattern(s: ref[ParserState]) -> void:
    # Consume the pattern expression — integer, string, identifier, enum/variant path.
    # Simplification: consume at least one token, then handle dotted paths.
    if check(s, tk.TokenKind.colon) or check(s, tk.TokenKind.newline):
        return
    advance(s)
    while match_kind(s, tk.TokenKind.dot):
        consume_name(s, c"expected member name after '.'")


function parse_return_stmt(s: ref[ParserState]) -> void:
    if check(s, tk.TokenKind.newline) or check(s, tk.TokenKind.dedent):
        consume_end_of_statement(s)
        return
    else:
        parse_expression(s)
        consume_end_of_statement(s)


function parse_defer_stmt(s: ref[ParserState]) -> void:
    if match_kind(s, tk.TokenKind.colon):
        if match_kind(s, tk.TokenKind.newline):
            consume(s, tk.TokenKind.indent, c"expected indented defer body")
            parse_block_body(s)
            consume(s, tk.TokenKind.dedent, c"expected end of defer body")
        else:
            # Inline defer: statement
            parse_statement(s)
    else:
        # defer expr
        parse_expression(s)
        consume_end_of_statement(s)


function parse_unsafe_stmt(s: ref[ParserState]) -> void:
    if match_kind(s, tk.TokenKind.colon):
        consume(s, tk.TokenKind.newline, c"expected newline after unsafe:")
        consume(s, tk.TokenKind.indent, c"expected indented unsafe body")
        parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of unsafe body")
    else:
        parse_unsafe_expr(s)
        consume_end_of_statement(s)


function parse_unsafe_expr(s: ref[ParserState]) -> void:
    parse_expression(s)


function parse_expression_stmt(s: ref[ParserState]) -> void:
    parse_expression(s)
    # Check for compound assignment operator
    if (
        check(s, tk.TokenKind.equal) or check(s, tk.TokenKind.plus_equal)
        or check(s, tk.TokenKind.minus_equal) or check(s, tk.TokenKind.star_equal)
        or check(s, tk.TokenKind.slash_equal) or check(s, tk.TokenKind.percent_equal)
        or check(s, tk.TokenKind.amp_equal) or check(s, tk.TokenKind.pipe_equal)
        or check(s, tk.TokenKind.caret_equal) or check(s, tk.TokenKind.shift_left_equal)
        or check(s, tk.TokenKind.shift_right_equal)
    ):
        advance(s)
        parse_expression(s)
    consume_end_of_statement(s)


function parse_parallel_block(s: ref[ParserState]) -> void:
    consume(s, tk.TokenKind.colon, c"expected ':' after parallel")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented parallel body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        parse_statement(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of parallel body")


function parse_gather_stmt(s: ref[ParserState]) -> void:
    parse_expression(s)
    while match_kind(s, tk.TokenKind.comma):
        parse_expression(s)
    consume_end_of_statement(s)


# =============================================================================
#  Expressions
# =============================================================================

function parse_expression(s: ref[ParserState]) -> void:
    parse_range(s)


function parse_range(s: ref[ParserState]) -> void:
    parse_or(s)
    if match_kind(s, tk.TokenKind.dot_dot):
        parse_or(s)


function parse_or(s: ref[ParserState]) -> void:
    parse_and(s)
    while match_kind(s, tk.TokenKind.tk_or):
        parse_and(s)


function parse_and(s: ref[ParserState]) -> void:
    parse_comparison(s)
    while match_kind(s, tk.TokenKind.tk_and):
        parse_comparison(s)


function parse_comparison(s: ref[ParserState]) -> void:
    parse_bitwise(s)
    while (
        check(s, tk.TokenKind.equal_equal) or check(s, tk.TokenKind.bang_equal)
        or check(s, tk.TokenKind.less) or check(s, tk.TokenKind.less_equal)
        or check(s, tk.TokenKind.greater) or check(s, tk.TokenKind.greater_equal)
    ):
        advance(s)
        parse_bitwise(s)


function parse_bitwise(s: ref[ParserState]) -> void:
    parse_term(s)
    while (
        check(s, tk.TokenKind.pipe) or check(s, tk.TokenKind.caret) or check(s, tk.TokenKind.amp)
        or check(s, tk.TokenKind.shift_left) or check(s, tk.TokenKind.shift_right)
    ):
        advance(s)
        parse_term(s)


function parse_term(s: ref[ParserState]) -> void:
    parse_factor(s)
    while check(s, tk.TokenKind.plus) or check(s, tk.TokenKind.minus):
        advance(s)
        parse_factor(s)


function parse_factor(s: ref[ParserState]) -> void:
    parse_unary(s)
    while check(s, tk.TokenKind.star) or check(s, tk.TokenKind.slash) or check(s, tk.TokenKind.percent):
        advance(s)
        parse_unary(s)


function parse_unary(s: ref[ParserState]) -> void:
    if (
        match_kind(s, tk.TokenKind.tk_not) or check(s, tk.TokenKind.minus)
        or check(s, tk.TokenKind.plus) or check(s, tk.TokenKind.tilde)
    ):
        advance(s)
        parse_unary(s)
    else:
        parse_postfix(s)


function parse_postfix(s: ref[ParserState]) -> void:
    parse_primary(s)
    while true:
        step(s)
        if match_kind(s, tk.TokenKind.dot):
            consume_name(s, c"expected member name after '.'")
        else if match_kind(s, tk.TokenKind.lbracket):
            parse_expression(s)
            consume(s, tk.TokenKind.rbracket, c"expected ']'")
        else if match_kind(s, tk.TokenKind.lparen):
            parse_call_args(s)
            consume(s, tk.TokenKind.rparen, c"expected ')'")
        else:
            break


function parse_primary(s: ref[ParserState]) -> void:
    if match_kind(s, tk.TokenKind.integer) or match_kind(s, tk.TokenKind.float_literal):
        pass
    else if match_kind(s, tk.TokenKind.string) or match_kind(s, tk.TokenKind.cstring):
        pass
    else if match_kind(s, tk.TokenKind.char_literal):
        pass
    else if match_kind(s, tk.TokenKind.tk_true):
        pass
    else if match_kind(s, tk.TokenKind.tk_false):
        pass
    else if match_kind(s, tk.TokenKind.tk_null):
        pass
    else if match_name(s):
        pass
    else if match_kind(s, tk.TokenKind.lparen):
        parse_expression(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
    else if match_kind(s, tk.TokenKind.tk_if):
        # if expression
        parse_expression(s)
        consume(s, tk.TokenKind.colon, c"expected ':' after if condition")
        parse_expression(s)
        consume(s, tk.TokenKind.tk_else, c"expected 'else' in if expression")
        consume(s, tk.TokenKind.colon, c"expected ':' after else")
        parse_expression(s)
    else if match_kind(s, tk.TokenKind.tk_match):
        parse_match_expr(s)
    else if match_kind(s, tk.TokenKind.tk_proc):
        parse_proc_expr(s)
    else if match_kind(s, tk.TokenKind.tk_size_of) or match_kind(s, tk.TokenKind.tk_align_of):
        consume(s, tk.TokenKind.lparen, c"expected '('")
        parse_type_ref(s)
        consume(s, tk.TokenKind.rparen, c"expected ')'")
    else if match_kind(s, tk.TokenKind.tk_detach):
        parse_expression(s)
    else if match_kind(s, tk.TokenKind.tk_unsafe):
        consume(s, tk.TokenKind.colon, c"expected ':' after unsafe")
        parse_expression(s)
    else if check(s, tk.TokenKind.less):
        # prefix cast T<-expr
        advance(s)
        advance(s)  # skip - and <
        parse_type_ref(s)
        parse_expression(s)
        pass
    else:
        parser_error_naked(s, c"expected expression")


function parse_call_args(s: ref[ParserState]) -> void:
    if check(s, tk.TokenKind.rparen):
        return
    while true:
        step(s)
        parse_expression(s)
        if not match_kind(s, tk.TokenKind.comma):
            break


function parse_match_expr(s: ref[ParserState]) -> void:
    parse_expression(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after match expression")
    consume(s, tk.TokenKind.newline, c"expected newline after match header")
    consume(s, tk.TokenKind.indent, c"expected indented match body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        parse_match_expr_arm(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of match body")


function parse_match_expr_arm(s: ref[ParserState]) -> void:
    if is_wildcard_match(s):
        pass
    else:
        parse_pattern(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after match pattern")
    parse_expression(s)
    consume_end_of_statement(s)


function parse_proc_expr(s: ref[ParserState]) -> void:
    parse_params(s)
    if match_kind(s, tk.TokenKind.arrow):
        parse_type_ref(s)
    if match_kind(s, tk.TokenKind.colon):
        if match_kind(s, tk.TokenKind.newline):
            consume(s, tk.TokenKind.indent, c"expected indented proc body")
            parse_block_body(s)
            consume(s, tk.TokenKind.dedent, c"expected end of proc body")
        else:
            parse_expression(s)


# =============================================================================
#  Declaration stubs (continued)
# =============================================================================

function parse_struct_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected struct name")
    consume(s, tk.TokenKind.colon, c"expected ':' after struct name")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented struct body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        parse_struct_member(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of struct body")


function parse_struct_member(s: ref[ParserState]) -> void:
    consume_name(s, c"expected field name")
    consume(s, tk.TokenKind.colon, c"expected ':' after field name")
    parse_type_ref(s)
    consume_end_of_statement(s)


function parse_type_alias(s: ref[ParserState]) -> void:
    consume_name(s, c"expected type alias name")
    consume(s, tk.TokenKind.equal, c"expected '=' after type alias name")
    parse_type_ref(s)
    consume_end_of_statement(s)


function parse_enum_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected enum name")
    consume(s, tk.TokenKind.colon, c"expected ':' after enum name")
    parse_type_ref(s)
    consume(s, tk.TokenKind.newline, c"expected newline")
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
    consume(s, tk.TokenKind.colon, c"expected ':' after variant name")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented variant body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        consume_name(s, c"expected arm name")
        if match_kind(s, tk.TokenKind.lparen):
            while not check(s, tk.TokenKind.rparen) and not eof(s):
                advance(s)
            consume(s, tk.TokenKind.rparen, c"expected ')'")
        consume_end_of_statement(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of variant body")


function parse_interface_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected interface name")
    consume(s, tk.TokenKind.colon, c"expected ':' after interface name")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented interface body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        parse_interface_method(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of interface body")


function parse_interface_method(s: ref[ParserState]) -> void:
    if match_kind(s, tk.TokenKind.tk_editable):
        pass
    else if match_kind(s, tk.TokenKind.tk_static):
        pass
    consume(s, tk.TokenKind.tk_function, c"expected function in interface")
    consume_name(s, c"expected method name")
    parse_params(s)
    if match_kind(s, tk.TokenKind.arrow):
        parse_type_ref(s)
    consume_end_of_statement(s)


function parse_opaque_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected opaque type name")
    consume_end_of_statement(s)


function parse_extending_block(s: ref[ParserState]) -> void:
    parse_type_ref(s)
    consume(s, tk.TokenKind.colon, c"expected ':' after extending type")
    consume(s, tk.TokenKind.newline, c"expected newline")
    consume(s, tk.TokenKind.indent, c"expected indented extending body")
    skip_newlines(s)
    while not check(s, tk.TokenKind.dedent) and not eof(s):
        parse_extending_method(s)
        skip_newlines(s)
    consume(s, tk.TokenKind.dedent, c"expected end of extending body")


function parse_extending_method(s: ref[ParserState]) -> void:
    if match_kind(s, tk.TokenKind.tk_editable):
        pass
    else if match_kind(s, tk.TokenKind.tk_static):
        pass
    consume(s, tk.TokenKind.tk_function, c"expected function in extending block")
    consume_name(s, c"expected method name")
    parse_params(s)
    if match_kind(s, tk.TokenKind.arrow):
        parse_type_ref(s)
    parse_block(s)


function parse_extern_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected function name")
    parse_params(s)
    consume(s, tk.TokenKind.arrow, c"expected '->' before external return type")
    parse_type_ref(s)
    consume_end_of_statement(s)


function parse_foreign_decl(s: ref[ParserState]) -> void:
    consume_name(s, c"expected function name")
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
    consume(s, tk.TokenKind.string, c"expected string message")
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
    skip_newlines(s)
    while not eof(s):
        parse_expression(s)
        consume(s, tk.TokenKind.colon, c"expected ':' after when pattern")
        consume(s, tk.TokenKind.newline, c"expected newline")
        consume(s, tk.TokenKind.indent, c"expected indented when body")
        skip_newlines(s)
        parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of when body")
        skip_newlines(s)
        if not check_name(s):
            break


function parse_when_stmt(s: ref[ParserState]) -> void:
    skip_newlines(s)
    while not eof(s):
        parse_expression(s)
        consume(s, tk.TokenKind.colon, c"expected ':' after when pattern")
        consume(s, tk.TokenKind.newline, c"expected newline")
        consume(s, tk.TokenKind.indent, c"expected indented when body")
        skip_newlines(s)
        parse_block_body(s)
        consume(s, tk.TokenKind.dedent, c"expected end of when body")
        skip_newlines(s)
        if not check_name(s):
            break


function parse_attribute_decl(s: ref[ParserState]) -> void:
    consume(s, tk.TokenKind.lbracket, c"expected '[' after attribute")
    consume_name(s, c"expected attribute target")
    consume(s, tk.TokenKind.rbracket, c"expected ']'")
    consume_name(s, c"expected attribute name")
    if match_kind(s, tk.TokenKind.lparen):
        parse_params(s)
    consume_end_of_statement(s)
