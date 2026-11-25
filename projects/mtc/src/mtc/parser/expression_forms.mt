## Expression forms — if/match/proc/unsafe expressions, `is` desugaring, and
## the `T<-expr` prefix cast.  Extracted from parser.mt.

import std.vec as vec

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.parser.ast as ast
import mtc.parser.state as pstate
import mtc.parser.parser as parser
import mtc.parser.statements as statements
import mtc.parser.declarations as declarations
import mtc.parser.expressions as expressions


public function parse_if_expr(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var condition = expressions.parse_expr(s)
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after if condition")
    var then_expr: ptr[ast.Expr]
    var else_expr: ptr[ast.Expr]
    if pstate.check(s, tk.TokenKind.newline):
        # Block form: `if cond:` newline-indented expression, `else:` likewise.
        pstate.consume(s, tk.TokenKind.newline, c"expected newline after if condition")
        pstate.consume(s, tk.TokenKind.indent, c"expected indented if expression body")
        then_expr = expressions.parse_expr(s)
        parser.consume_end_of_statement(s)
        pstate.consume(s, tk.TokenKind.dedent, c"expected end of if expression body")
        pstate.consume(s, tk.TokenKind.tk_else, c"expected 'else' in if expression")
        pstate.consume(s, tk.TokenKind.colon, c"expected ':' after else")
        pstate.consume(s, tk.TokenKind.newline, c"expected newline after else:")
        pstate.consume(s, tk.TokenKind.indent, c"expected indented else expression body")
        else_expr = expressions.parse_expr(s)
        parser.consume_end_of_statement(s)
        pstate.consume(s, tk.TokenKind.dedent, c"expected end of else expression body")
    else:
        then_expr = expressions.parse_expr(s)
        pstate.consume(s, tk.TokenKind.tk_else, c"expected 'else' in if expression")
        pstate.consume(s, tk.TokenKind.colon, c"expected ':' after else")
        else_expr = expressions.parse_expr(s)
    var node = parser.alloc_expr(s)
    read(node) = ast.Expr.expr_if(condition = condition, then_expr = then_expr, else_expr = else_expr)
    return node

# =============================================================================
#  Match expression
# =============================================================================

public function parse_match_expr(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var m_ln: ptr_uint = 0
    var m_cn: ptr_uint = 0
    unsafe:
        m_ln = read(pstate.previous_token(s)).line
        m_cn = read(pstate.previous_token(s)).column
    var scrutinee = expressions.parse_expr(s)
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after match expression")
    pstate.consume(s, tk.TokenKind.newline, c"expected newline after match header")
    pstate.consume(s, tk.TokenKind.indent, c"expected indented match body")
    var arms = parse_match_expr_arms(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of match body")
    var node = parser.alloc_expr(s)
    read(node) = ast.Expr.expr_match(
        scrutinee = scrutinee,
        arms = arms,
        line = m_ln,
        column = m_cn,
        length = 5,
        desugared_from_is = false
    )
    return node


function parse_match_expr_arms(s: ref[pstate.ParserState]) -> span[ast.MatchExprArm]:
    var arms = vec.Vec[ast.MatchExprArm].create()
    parser.skip_newlines(s)
    while not pstate.check(s, tk.TokenKind.dedent) and not parser.eof(s):
        parse_match_expr_arm_into(s, ref_of(arms))
        parser.skip_newlines(s)
    let result = arms.as_span()
    return result


public function parse_match_expr_arm_into(s: ref[pstate.ParserState], arms: ref[vec.Vec[ast.MatchExprArm]]) -> void:
    var is_wild = false
    var wild_ln: ptr_uint = 0
    var wild_cn: ptr_uint = 0
    var patterns = vec.Vec[ptr[ast.Expr]].create()
    if pstate.match_kind(s, tk.TokenKind.tk_else):
        is_wild = true
        unsafe:
            wild_ln = read(pstate.previous_token(s)).line
            wild_cn = read(pstate.previous_token(s)).column
    else if statements.is_wildcard_match(s):
        is_wild = true
        unsafe:
            wild_ln = read(pstate.previous_token(s)).line
            wild_cn = read(pstate.previous_token(s)).column
    else:
        patterns.push(statements.parse_pattern(s))
        while pstate.match_kind(s, tk.TokenKind.pipe):
            patterns.push(statements.parse_pattern(s))
    var binding_name: Option[str] = Option[str].none
    var binding_line: ptr_uint = 0
    var binding_column: ptr_uint = 0
    if pstate.match_kind(s, tk.TokenKind.tk_as):
        let prev = pstate.previous(s) else:
            fatal(c"parse inner missing previous token")
        unsafe: binding_line = read(prev).line
        parser.consume_name(s, c"expected binding name after as")
        binding_name = Option[str].some(value = parser.previous_lexeme(s))
        unsafe: binding_column = read(pstate.previous_token(s)).column
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after match pattern")
    var value = expressions.parse_expr(s)
    if not parser.block_expr(value):
        parser.consume_end_of_statement(s)
    if is_wild:
        arms.push(ast.MatchExprArm(pattern = null, binding_name = binding_name, binding_line = binding_line, binding_column = binding_column, value = value,
            wildcard_line = wild_ln, wildcard_column = wild_cn))
        return
    var i: ptr_uint = 0
    while i < patterns.len():
        let pp = patterns.get(i) else:
            break
        unsafe:
            arms.push(ast.MatchExprArm(
                pattern = read(pp),
                binding_name = binding_name,
                binding_line = binding_line,
                binding_column = binding_column,
                value = value
            ))
        i += 1

# =============================================================================
#  Proc / fn expression
# =============================================================================

public function parse_proc_expr_after_proc(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var params = declarations.parse_params(s)
    var return_type: ptr[ast.TypeRef]? = null
    if pstate.match_kind(s, tk.TokenKind.arrow):
        return_type = declarations.parse_type_ref(s)
    var body = parse_proc_body(s)
    var node = parser.alloc_expr(s)
    read(node) = ast.Expr.expr_proc(method_params = params, return_type = return_type, body = body)
    return node


function parse_proc_body(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    if pstate.match_kind(s, tk.TokenKind.colon):
        if pstate.match_kind(s, tk.TokenKind.newline):
            pstate.consume(s, tk.TokenKind.indent, c"expected indented proc body")
            var stmts_span = declarations.parse_block_body(s)
            pstate.consume(s, tk.TokenKind.dedent, c"expected end of proc body")
            var block = parser.alloc_stmt(s)
            unsafe:
                read(block) = ast.Stmt.stmt_block(statements = stmts_span)
            return block
        else:
            # Expression-body proc: proc() -> T: expr  (implicit return)
            var expr_val = expressions.parse_expr(s)
            var ret = parser.alloc_stmt(s)
            unsafe:
                read(ret) = ast.Stmt.stmt_ret(value = expr_val, line = 0, column = 0, length = 0)
            return ret
    var empty = parser.alloc_stmt(s)
    unsafe:
        read(empty) = ast.Stmt.stmt_block(statements = span[ast.Stmt]())
    return empty

# =============================================================================
#  Unsafe expression
# =============================================================================

public function parse_unsafe_expr(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    let tok = pstate.previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = tok.line
        cn = tok.column
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after unsafe")
    var expr_val = expressions.parse_expr(s)
    var node = parser.alloc_expr(s)
    read(node) = ast.Expr.expr_unsafe(expression = expr_val, line = ln, column = cn)
    return node

# =============================================================================
#  is-operator desugaring
# =============================================================================

public function is_desugar(
    s: ref[pstate.ParserState],
    left: ptr[ast.Expr],
    pattern: ptr[ast.Expr],
    is_ln: ptr_uint,
    is_cn: ptr_uint,
    pattern_len: ptr_uint
) -> ptr[ast.Expr]:
    # expr is Pattern → match expr: Pattern: true; _: false
    var true_expr = parser.alloc_expr(s)
    unsafe:
        read(true_expr) = ast.Expr.expr_bool_literal(value = true)
    var false_expr = parser.alloc_expr(s)
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
    var node = parser.alloc_expr(s)
    read(node) = ast.Expr.expr_match(
        scrutinee = left,
        arms = arms_span,
        line = is_ln,
        column = is_cn,
        length = pattern_len,
        desugared_from_is = true
    )
    return node

# =============================================================================
#  Prefix cast: T<-expr
# =============================================================================

public function try_parse_prefix_cast_expr(s: ref[pstate.ParserState]) -> Option[ptr[ast.Expr]]:
    if not parser.check_name(s):
        return Option[ptr[ast.Expr]].none
    let name_tok = pstate.peek(s) else:
        return Option[ptr[ast.Expr]].none
    var name_str: str
    unsafe:
        name_str = token_mod.token_lexeme(read(name_tok), s.source)
    if not parser.known_type_like_name(s, name_str):
        return Option[ptr[ast.Expr]].none
    var saved = s.stream.current
    var target_type = declarations.parse_named_type_ref(s, true)
    if not pstate.check(s, tk.TokenKind.less):
        s.stream.current = saved
        return Option[ptr[ast.Expr]].none
    if not parser.check_next(s, tk.TokenKind.minus):
        s.stream.current = saved
        return Option[ptr[ast.Expr]].none
    let lt_idx = s.stream.current
    pstate.advance(s)
    pstate.advance(s)
    var lt_opt = s.stream.tokens.get(lt_idx)
    var mn_opt = s.stream.tokens.get(lt_idx + 1)
    if lt_opt != null and mn_opt != null:
        unsafe:
            if read(lt_opt).end_offset != read(mn_opt).start_offset:
                s.stream.current = saved
                return Option[ptr[ast.Expr]].none
    var expr_val = expressions.parse_unary(s)
    var node = parser.alloc_expr(s)
    var cast_line: ptr_uint = 0
    var cast_column: ptr_uint = 0
    unsafe:
        cast_line = read(name_tok).line
        cast_column = read(name_tok).column
    read(node) = ast.Expr.expr_prefix_cast(
        target_type = target_type,
        expression = expr_val,
        line = cast_line,
        column = cast_column
    )
    return Option[ptr[ast.Expr]].some(value = node)
