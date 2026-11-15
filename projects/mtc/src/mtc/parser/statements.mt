## Statements — the statement dispatcher and every statement form (locals,
## control flow, match, defer, unsafe, parallel/gather, emit, and the inline
## forms).  Extracted from parser.mt.

import std.string as string
import std.vec as vec

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.parser.ast as ast
import mtc.parser.state as pstate
import mtc.parser.parser as parser


public function parse_statement(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    if pstate.match_kind(s, tk.TokenKind.tk_let):
        return parse_local_decl(s, true)
    else if pstate.match_kind(s, tk.TokenKind.tk_var):
        return parse_local_decl(s, false)
    else if pstate.match_kind(s, tk.TokenKind.tk_if):
        return parse_if_stmt(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_while):
        return parse_while_stmt(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_for):
        return parse_for_stmt(s, false)
    else if pstate.match_kind(s, tk.TokenKind.tk_match):
        return parse_match_stmt(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_return):
        return parse_return_stmt(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_break):
        let tok = pstate.previous_token(s)
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
        parser.consume_end_of_statement(s)
        var node = parser.alloc_stmt(s)
        read(node) = ast.Stmt.stmt_break(line = ln, column = cn)
        return node
    else if pstate.match_kind(s, tk.TokenKind.tk_continue):
        let tok = pstate.previous_token(s)
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
        parser.consume_end_of_statement(s)
        var node = parser.alloc_stmt(s)
        read(node) = ast.Stmt.stmt_continue(line = ln, column = cn)
        return node
    else if pstate.match_kind(s, tk.TokenKind.tk_pass):
        let tok = pstate.previous_token(s)
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
        parser.consume_end_of_statement(s)
        var node = parser.alloc_stmt(s)
        read(node) = ast.Stmt.stmt_pass(line = ln, column = cn)
        return node
    else if pstate.match_kind(s, tk.TokenKind.tk_defer):
        return parse_defer_stmt(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_unsafe):
        return parse_unsafe_stmt(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_static_assert):
        return parse_static_assert_stmt(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_when):
        return parse_when_stmt(s)
    else if pstate.check(s, tk.TokenKind.tk_parallel) and parser.check_next(s, tk.TokenKind.tk_for):
        pstate.advance(s)
        pstate.advance(s)
        return parse_for_stmt(s, true)
    else if pstate.match_kind(s, tk.TokenKind.tk_parallel):
        return parse_parallel_block(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_gather):
        return parse_gather_stmt(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_emit):
        return parse_emit_stmt(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_inline):
        let inline_tok = pstate.previous_token(s)
        if pstate.match_kind(s, tk.TokenKind.tk_for):
            return parse_inline_for_stmt(s)
        else if pstate.match_kind(s, tk.TokenKind.tk_while):
            return parse_inline_while_stmt(s, inline_tok)
        else if pstate.match_kind(s, tk.TokenKind.tk_match):
            return parse_inline_match_stmt(s)
        else if pstate.match_kind(s, tk.TokenKind.tk_if):
            return parse_inline_if_stmt(s)
        return parse_expression_stmt(s)
    else:
        return parse_expression_stmt(s)


function stmt_error_sentinel(s: ref[pstate.ParserState], msg: cstr) -> ptr[ast.Stmt]:
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_error(line = 0, column = 0, message = "parse error")
    return node


function parse_local_decl(s: ref[pstate.ParserState], is_let: bool) -> ptr[ast.Stmt]:
    let tok = pstate.previous_token(s)
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
    var else_binding_line: ptr_uint = 0
    var else_binding_column: ptr_uint = 0
    var final_cn = cn

    if pstate.check(s, tk.TokenKind.lparen):
        destructure_bindings = parse_destructure_bindings(s)
    else if parser.check_name(s) and parser.check_next(s, tk.TokenKind.lparen):
        parser.consume_name_allowing_keywords(s, c"expected type name")
        destructure_type_name = Option[str].some(value = parser.previous_lexeme(s))
        destructure_bindings = parse_destructure_bindings(s)
    else if parser.check_name(s) and parser.check_next(s, tk.TokenKind.dot):
        # Module-qualified destructure (`let types.Transform(x, y) = t`): keep the
        # whole dotted name, and let `parse_destructure_bindings` consume the `(`
        # exactly once, like the bare `let Transform(x, y)` branch above.
        pstate.advance(s)
        var qualified = string.String.create()
        qualified.append(parser.previous_lexeme(s))
        while pstate.match_kind(s, tk.TokenKind.dot):
            parser.consume_name(s, c"expected type name after '.'")
            qualified.append(".")
            qualified.append(parser.previous_lexeme(s))
        destructure_type_name = Option[str].some(value = qualified.as_str())
        destructure_bindings = parse_destructure_bindings(s)
    else:
        parser.consume_name(s, c"expected variable name")
        name_str = parser.previous_lexeme(s)
        unsafe:
            final_cn = read(pstate.previous_token(s)).column

    if destructure_bindings.is_some():
        pstate.consume(s, tk.TokenKind.equal, c"expected '=' after destructure pattern")
        value = parser.parse_expr(s)
        parser.consume_end_of_statement(s)
        var node = parser.alloc_stmt(s)
        unsafe:
            read(node) = ast.Stmt.stmt_local(is_let = is_let, name = name_str, stmt_type = stmt_type, value = value,
                else_binding = else_binding, else_body = else_body,
                destructure_bindings = destructure_bindings,
                destructure_type_name = destructure_type_name, line = ln, column = final_cn,
                else_binding_line = else_binding_line, else_binding_column = else_binding_column)
        return node

    if pstate.match_kind(s, tk.TokenKind.colon):
        stmt_type = parser.parse_type_ref(s)
    if pstate.match_kind(s, tk.TokenKind.equal):
        value = parser.parse_expr(s)
    if pstate.match_kind(s, tk.TokenKind.tk_else):
        if pstate.match_kind(s, tk.TokenKind.tk_as):
            parser.consume_name(s, c"expected error binding name")
            let bind_name = parser.previous_lexeme(s)
            else_binding = Option[str].some(value = bind_name)
            unsafe:
                else_binding_line = read(pstate.previous_token(s)).line
                else_binding_column = read(pstate.previous_token(s)).column
        pstate.consume(s, tk.TokenKind.colon, c"expected ':' after else")
        pstate.consume(s, tk.TokenKind.newline, c"expected newline after else:")
        pstate.consume(s, tk.TokenKind.indent, c"expected indented else body")
        var body_span = parser.parse_block_body(s)
        pstate.consume(s, tk.TokenKind.dedent, c"expected end of else body")
        var body_stmt = parser.alloc_stmt(s)
        unsafe:
            read(body_stmt) = ast.Stmt.stmt_block(statements = body_span)
        else_body = body_stmt
        var node = parser.alloc_stmt(s)
        unsafe:
            read(node) = ast.Stmt.stmt_local(is_let = is_let, name = name_str, stmt_type = stmt_type, value = value,
                else_binding = else_binding, else_body = else_body,
                destructure_bindings = Option[span[str]].none,
                destructure_type_name = Option[str].none, line = ln, column = final_cn,
                else_binding_line = else_binding_line, else_binding_column = else_binding_column)
        return node
    if pstate.match_kind(s, tk.TokenKind.question):
        pass
    if stmt_type == null and value == null:
        pstate.parser_error_naked(s, c"local declaration requires an explicit type or initializer")
    if value != null and not parser.block_expr(value):
        parser.consume_end_of_statement(s)
    # The host's `parse_local_decl` rescue: a binding whose initializer or
    # terminator failed keeps its name with an error-expression value, and the
    # partial statement's remainder is skipped.
    if s.panic and name_str.len > 0:
        value = parser.panic_error_expr(s)
        parser.recover_statement(s)
    var node = parser.alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_local(is_let = is_let, name = name_str, stmt_type = stmt_type, value = value,
            else_binding = else_binding, else_body = else_body,
            destructure_bindings = Option[span[str]].none,
            destructure_type_name = Option[str].none, line = ln, column = final_cn,
            else_binding_line = else_binding_line, else_binding_column = else_binding_column)
    return node


function parse_destructure_bindings(s: ref[pstate.ParserState]) -> Option[span[str]]:
    pstate.consume(s, tk.TokenKind.lparen, c"expected '('")
    var bindings = vec.Vec[str].create()
    while true:
        let tok = pstate.peek(s) else:
            break
        if pstate.check(s, tk.TokenKind.rparen):
            break
        let bt = pstate.peek(s) else:
            break
        var name: str
        unsafe:
            name = token_mod.token_lexeme(read(bt), s.source)
        if name == "_":
            pstate.advance(s)
            bindings.push("_")
        else:
            parser.consume_name(s, c"expected binding name in destructure pattern")
            bindings.push(parser.previous_lexeme(s))
        if not pstate.match_kind(s, tk.TokenKind.comma):
            break
    pstate.consume(s, tk.TokenKind.rparen, c"expected ')' after destructure pattern")
    let result = bindings.as_span()
    return Option[span[str]].some(value = result)


function parse_if_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = pstate.previous_token(s)
    var start_ln: ptr_uint
    var start_cn: ptr_uint
    unsafe:
        start_ln = read(start_tok).line
        start_cn = read(start_tok).column
    var condition = parser.parse_expr(s)
    var then_body = parse_if_branch_body(s)
    var branches = vec.Vec[ast.IfBranch].create()
    var branch = ast.IfBranch(condition = condition, body = then_body, line = start_ln, column = start_cn, length = 2)
    branches.push(branch)
    var else_body: ptr[ast.Stmt]? = null
    var else_ln: ptr_uint = 0
    var else_col: ptr_uint = 0
    while pstate.check(s, tk.TokenKind.tk_else) and parser.check_next(s, tk.TokenKind.tk_if):
        pstate.advance(s)
        pstate.advance(s)
        let elif_tok = pstate.previous_token(s)
        var elif_ln: ptr_uint = 0
        var elif_cn: ptr_uint = 0
        unsafe:
            elif_ln = read(elif_tok).line
            elif_cn = read(elif_tok).column
        condition = parser.parse_expr(s)
        var elif_body = parse_if_branch_body(s)
        var elif_branch = ast.IfBranch(condition = condition, body = elif_body, line = elif_ln, column = elif_cn, length = 2)
        branches.push(elif_branch)
    if pstate.check(s, tk.TokenKind.tk_else):
        let else_tok = pstate.peek(s) else:
            return stmt_error_sentinel(s, c"unexpected eof in else")
        unsafe:
            else_ln = read(else_tok).line
            else_col = read(else_tok).column
        pstate.advance(s)
        else_body = parse_else_branch_body(s)
    var branches_span = branches.as_span()
    var node = parser.alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_if(branches = branches_span, else_body = else_body,
            is_inline = false, line = start_ln, else_line = else_ln, else_column = else_col)
    return node


function parse_if_branch_body(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    parser.consume_or_sync(s, tk.TokenKind.colon, c"expected ':' after if condition")
    if pstate.match_kind(s, tk.TokenKind.newline):
        pstate.consume(s, tk.TokenKind.indent, c"expected indented body")
        var body_span = parser.parse_block_body(s)
        pstate.consume(s, tk.TokenKind.dedent, c"expected end of body")
        var node = parser.alloc_stmt(s)
        read(node) = ast.Stmt.stmt_block(statements = body_span)
        return node
    else:
        s.in_inline_block_body = true
        var result = parse_statement(s)
        s.in_inline_block_body = false
        return result


function parse_else_branch_body(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after else")
    if pstate.match_kind(s, tk.TokenKind.newline):
        pstate.consume(s, tk.TokenKind.indent, c"expected indented else body")
        var body_span = parser.parse_block_body(s)
        pstate.consume(s, tk.TokenKind.dedent, c"expected end of else body")
        var node = parser.alloc_stmt(s)
        read(node) = ast.Stmt.stmt_block(statements = body_span)
        return node
    else:
        s.in_inline_block_body = true
        var result = parse_statement(s)
        s.in_inline_block_body = false
        return result


function parse_block_or_inline_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    if pstate.match_kind(s, tk.TokenKind.newline):
        pstate.consume(s, tk.TokenKind.indent, c"expected indented body")
        var body_span = parser.parse_block_body(s)
        pstate.consume(s, tk.TokenKind.dedent, c"expected end of body")
        var node = parser.alloc_stmt(s)
        read(node) = ast.Stmt.stmt_block(statements = body_span)
        return node
    else:
        s.in_inline_block_body = true
        var result = parse_statement(s)
        s.in_inline_block_body = false
        parser.consume_end_of_statement(s)
        return result


function parse_while_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = pstate.previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var condition = parser.parse_expr(s)
    parser.consume_or_sync(s, tk.TokenKind.colon, c"expected ':' after while condition")
    var is_inline = false
    var body: ptr[ast.Stmt] = parser.alloc_stmt(s)
    if pstate.match_kind(s, tk.TokenKind.newline):
        pstate.consume(s, tk.TokenKind.indent, c"expected indented while body")
        var body_span = parser.parse_block_body(s)
        pstate.consume(s, tk.TokenKind.dedent, c"expected end of while body")
        unsafe:
            read(body) = ast.Stmt.stmt_block(statements = body_span)
    else:
        is_inline = true
        body = parse_statement(s)
        parser.consume_end_of_statement(s)
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_while(condition = condition, body = body, is_inline = is_inline, line = ln, column = cn, length = 5)
    return node


function parse_for_stmt(s: ref[pstate.ParserState], threaded: bool) -> ptr[ast.Stmt]:
    let start_tok = pstate.peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in for")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    parser.consume_name(s, c"expected loop variable")
    var bindings = vec.Vec[ast.ForBinding].create()
    var first_binding = ast.ForBinding(name = parser.previous_lexeme(s), line = ln, column = cn)
    bindings.push(first_binding)
    while pstate.match_kind(s, tk.TokenKind.comma):
        parser.consume_name(s, c"expected loop variable")
        var b_ln: ptr_uint = 0
        var b_cn: ptr_uint = 0
        unsafe:
            b_ln = read(pstate.previous_token(s)).line
            b_cn = read(pstate.previous_token(s)).column
        var b = ast.ForBinding(name = parser.previous_lexeme(s), line = b_ln, column = b_cn)
        bindings.push(b)
    pstate.consume(s, tk.TokenKind.tk_in, c"expected 'in' after for bindings")
    var iterables = vec.Vec[ast.Expr].create()
    var iter = parser.parse_expr(s)
    unsafe:
        iterables.push(read(iter))
    while pstate.match_kind(s, tk.TokenKind.comma):
        var next_iter = parser.parse_expr(s)
        unsafe:
            iterables.push(read(next_iter))
    parser.consume_or_sync(s, tk.TokenKind.colon, c"expected ':' after for iterable")
    var body = parser.alloc_stmt(s)
    if pstate.match_kind(s, tk.TokenKind.newline):
        pstate.consume(s, tk.TokenKind.indent, c"expected indented for body")
        var body_span = parser.parse_block_body(s)
        pstate.consume(s, tk.TokenKind.dedent, c"expected end of for body")
        body = parser.alloc_stmt(s)
        unsafe:
            read(body) = ast.Stmt.stmt_block(statements = body_span)
    var bindings_span = bindings.as_span()
    var iterables_span = iterables.as_span()
    var node = parser.alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_for(bindings = bindings_span, iterables = iterables_span,
            body = body, is_inline = false, threaded = threaded, line = ln, column = cn)
    return node


function parse_match_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    var m_ln: ptr_uint = 0
    var m_cn: ptr_uint = 0
    unsafe:
        m_ln = read(pstate.previous_token(s)).line
        m_cn = read(pstate.previous_token(s)).column
    var scrutinee = parser.parse_expr(s)
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after match expression")
    var is_expr_form = not pstate.check(s, tk.TokenKind.newline)
    if is_expr_form:
        var arms = vec.Vec[ast.MatchExprArm].create()
        while true:
            pstate.step(s)
            parser.parse_match_expr_arm_into(s, ref_of(arms))
            if not pstate.match_kind(s, tk.TokenKind.comma) and not pstate.check(s, tk.TokenKind.newline):
                break
        var arms_span = arms.as_span()
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_match(scrutinee = scrutinee, arms = arms_span, line = m_ln, column = m_cn, length = 5, desugared_from_is = false)
        var stmt = parser.alloc_stmt(s)
        unsafe:
            read(stmt) = ast.Stmt.stmt_expression(expression = node, line = m_ln)
        return stmt
    pstate.consume(s, tk.TokenKind.newline, c"expected newline after match header")
    pstate.consume(s, tk.TokenKind.indent, c"expected indented match body")
    parser.skip_newlines(s)
    var arms = vec.Vec[ast.MatchArm].create()
    while not pstate.check(s, tk.TokenKind.dedent) and not parser.eof(s):
        parser.skip_newlines(s)
        parse_match_arm_into(s, ref_of(arms))
        if s.panic:
            parser.recover_match_arm(s)
        parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of match body")
    var arms_span = arms.as_span()
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_match(scrutinee = scrutinee, arms = arms_span, is_inline = false, line = m_ln, column = m_cn)
    return node


public function is_wildcard_match(s: ref[pstate.ParserState]) -> bool:
    if not parser.check_name(s):
        return false
    let tok = pstate.peek(s) else:
        return false
    unsafe:
        let t = read(tok)
        let lexeme = token_mod.token_lexeme(t, s.source)
        if lexeme == "_":
            pstate.advance(s)
            return true
        return false


public function parse_match_arm_into(s: ref[pstate.ParserState], arms: ref[vec.Vec[ast.MatchArm]]) -> void:
    var is_wild = false
    var wild_ln: ptr_uint = 0
    var wild_cn: ptr_uint = 0
    var patterns = vec.Vec[ptr[ast.Expr]].create()
    if pstate.match_kind(s, tk.TokenKind.tk_else):
        is_wild = true
        unsafe:
            wild_ln = read(pstate.previous_token(s)).line
            wild_cn = read(pstate.previous_token(s)).column
    else if is_wildcard_match(s):
        is_wild = true
        unsafe:
            wild_ln = read(pstate.previous_token(s)).line
            wild_cn = read(pstate.previous_token(s)).column
    else:
        patterns.push(parse_pattern(s))
        while pstate.match_kind(s, tk.TokenKind.pipe):
            patterns.push(parse_pattern(s))
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
    var body = parser.alloc_stmt(s)
    if pstate.match_kind(s, tk.TokenKind.newline):
        pstate.consume(s, tk.TokenKind.indent, c"expected indented match arm body")
        var body_span = parser.parse_block_body(s)
        pstate.consume(s, tk.TokenKind.dedent, c"expected end of match arm body")
        body = parser.alloc_stmt(s)
        unsafe:
            read(body) = ast.Stmt.stmt_block(statements = body_span)
    if is_wild:
        if s.panic:
            return
        arms.push(ast.MatchArm(pattern = null, binding_name = binding_name, binding_line = binding_line, binding_column = binding_column, body = body,
            wildcard_line = wild_ln, wildcard_column = wild_cn))
        return
    # Expand `p1 | p2 | ...` into one arm per alternative sharing the body.
    var i: ptr_uint = 0
    while i < patterns.len():
        if s.panic:
            return
        let pp = patterns.get(i) else:
            break
        unsafe:
            arms.push(ast.MatchArm(pattern = read(pp), binding_name = binding_name, binding_line = binding_line, binding_column = binding_column, body = body))
        i += 1


function parse_return_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = pstate.previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var value: ptr[ast.Expr]? = null
    if not (pstate.check(s, tk.TokenKind.newline) or pstate.check(s, tk.TokenKind.dedent)):
        value = parser.parse_expr(s)
    if value != null and not parser.block_expr(value):
        parser.consume_end_of_statement(s)
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_ret(value = value, line = ln, column = cn, length = 6)
    return node


function parse_defer_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = pstate.previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var expression: ptr[ast.Expr]? = null
    var body: ptr[ast.Stmt]? = null
    if pstate.match_kind(s, tk.TokenKind.colon):
        if pstate.match_kind(s, tk.TokenKind.newline):
            pstate.consume(s, tk.TokenKind.indent, c"expected indented defer body")
            var body_span = parser.parse_block_body(s)
            pstate.consume(s, tk.TokenKind.dedent, c"expected end of defer body")
            var block_node = parser.alloc_stmt(s)
            unsafe:
                read(block_node) = ast.Stmt.stmt_block(statements = body_span)
            body = block_node
        else:
            body = parse_statement(s)
    else:
        expression = parser.parse_expr(s)
        parser.consume_end_of_statement(s)
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_defer(expression = expression, body = body, line = ln, column = cn)
    return node


function parse_unsafe_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = pstate.previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var body: ptr[ast.Stmt] = parser.alloc_stmt(s)
    if pstate.match_kind(s, tk.TokenKind.colon):
        if pstate.match_kind(s, tk.TokenKind.newline):
            pstate.consume(s, tk.TokenKind.indent, c"expected indented unsafe body")
            var body_span = parser.parse_block_body(s)
            pstate.consume(s, tk.TokenKind.dedent, c"expected end of unsafe body")
            body = parser.alloc_stmt(s)
            unsafe:
                read(body) = ast.Stmt.stmt_block(statements = body_span)
        else:
            body = parse_statement(s)
    else:
        var expr_val = parser.parse_expr(s)
        parser.consume_end_of_statement(s)
        body = parser.alloc_stmt(s)
        unsafe:
            read(body) = ast.Stmt.stmt_expression(expression = expr_val, line = ln)
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_unsafe(body = body, line = ln, column = cn)
    return node


function parse_static_assert_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    var sa_ln: ptr_uint = 0
    unsafe:
        sa_ln = read(pstate.previous_token(s)).line
    pstate.consume(s, tk.TokenKind.lparen, c"expected '(' after static_assert")
    var condition = parser.parse_expr(s)
    pstate.consume(s, tk.TokenKind.comma, c"expected ',' after condition")
    var message_expr = parser.parse_expr(s)
    pstate.consume(s, tk.TokenKind.rparen, c"expected ')'")
    parser.consume_end_of_statement(s)
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_static_assert(condition = condition, message = message_expr, line = sa_ln)
    return node


function parse_expression_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = pstate.peek(s)
    var start_ln: ptr_uint = 0
    if start_tok != null:
        unsafe:
            start_ln = read(start_tok).line
    var left = parser.parse_expr(s)
    if (
        pstate.check(s, tk.TokenKind.equal) or pstate.check(s, tk.TokenKind.plus_equal)
        or pstate.check(s, tk.TokenKind.minus_equal) or pstate.check(s, tk.TokenKind.star_equal)
        or pstate.check(s, tk.TokenKind.slash_equal) or pstate.check(s, tk.TokenKind.percent_equal)
        or pstate.check(s, tk.TokenKind.amp_equal) or pstate.check(s, tk.TokenKind.pipe_equal)
        or pstate.check(s, tk.TokenKind.caret_equal) or pstate.check(s, tk.TokenKind.shift_left_equal)
        or pstate.check(s, tk.TokenKind.shift_right_equal)
    ):
        pstate.advance(s)
        let op = parser.previous_lexeme(s)
        var op_cn: ptr_uint = 0
        unsafe:
            op_cn = read(pstate.previous_token(s)).column
        var right = parser.parse_expr(s)
        if not parser.block_expr(right):
            parser.consume_end_of_statement(s)
        var node = parser.alloc_stmt(s)
        read(node) = ast.Stmt.stmt_assignment(target = left, operator = op, value = right, line = start_ln, column = op_cn)
        return node
    if not parser.block_expr(left):
        parser.consume_end_of_statement(s)
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_expression(expression = left, line = start_ln)
    return node


function parse_parallel_block(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = pstate.previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after parallel")
    pstate.consume(s, tk.TokenKind.newline, c"expected newline")
    pstate.consume(s, tk.TokenKind.indent, c"expected indented parallel body")
    parser.skip_newlines(s)
    var bodies = vec.Vec[ast.Stmt].create()
    while not pstate.check(s, tk.TokenKind.dedent) and not parser.eof(s):
        let body_stmt = parse_statement(s)
        unsafe:
            bodies.push(read(body_stmt))
        parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of parallel body")
    var bodies_span = bodies.as_span()
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_parallel_block(bodies = bodies_span, line = ln, column = cn)
    return node


function parse_gather_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    var g_ln: ptr_uint = 0
    var g_cn: ptr_uint = 0
    unsafe:
        g_ln = read(pstate.previous_token(s)).line
        g_cn = read(pstate.previous_token(s)).column
    var handles = vec.Vec[ast.Expr].create()
    var first = parser.parse_expr(s)
    unsafe:
        handles.push(read(first))
    while pstate.match_kind(s, tk.TokenKind.comma):
        var next_handle = parser.parse_expr(s)
        unsafe:
            handles.push(read(next_handle))
    parser.consume_end_of_statement(s)
    var handles_span = handles.as_span()
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_gather(handles = handles_span, line = g_ln, column = g_cn)
    return node


public function parse_pattern(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    if pstate.check(s, tk.TokenKind.colon) or pstate.check(s, tk.TokenKind.newline):
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_error(line = 0, column = 0, message = "empty pattern")
        return node
    # Parse below bitwise-or precedence so a top-level `|` is treated as a
    # pattern alternative separator, not a bitwise-or operator.
    var pattern = parser.parse_bitwise_xor(s)
    # Integer/char range pattern: `start..stop`.
    var is_int_or_char = false
    unsafe:
        match read(pattern):
            ast.Expr.expr_integer_literal:
                is_int_or_char = true
            ast.Expr.expr_char_literal:
                is_int_or_char = true
            _:
                pass
    if is_int_or_char and pstate.match_kind(s, tk.TokenKind.dot_dot):
        let end_expr = parser.parse_bitwise_xor(s)
        let end_tok = pstate.previous_token(s)
        var dd_ln: ptr_uint = 0
        var dd_cn: ptr_uint = 0
        unsafe:
            dd_ln = read(end_tok).line
            dd_cn = read(end_tok).column
        var range_node = parser.alloc_expr(s)
        read(range_node) = ast.Expr.expr_range(start_expr = pattern, end_expr = end_expr, line = dd_ln, column = dd_cn)
        return range_node
    return pattern


function parse_when_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = pstate.previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var discriminant = parser.parse_expr(s)
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after when discriminant")
    pstate.consume(s, tk.TokenKind.newline, c"expected newline after when header")
    pstate.consume(s, tk.TokenKind.indent, c"expected indented when body")
    parser.skip_newlines(s)
    var branches = vec.Vec[ast.WhenBranch].create()
    var else_body: ptr[ast.Stmt]? = null
    while not pstate.check(s, tk.TokenKind.dedent) and not parser.eof(s):
        parser.skip_newlines(s)
        if pstate.check(s, tk.TokenKind.tk_else):
            pstate.advance(s)
            pstate.consume(s, tk.TokenKind.colon, c"expected ':' after else")
            else_body = parse_block_or_inline_stmt(s)
            parser.skip_newlines(s)
            break
        var pat = parser.parse_expr(s)
        var binding: Option[str] = Option[str].none
        if pstate.match_kind(s, tk.TokenKind.tk_as):
            parser.consume_name(s, c"expected binding name after as")
            binding = Option[str].some(value = parser.previous_lexeme(s))
        pstate.consume(s, tk.TokenKind.colon, c"expected ':' after when pattern")
        let branch_body = parse_block_or_inline_stmt(s)
        var wb = ast.WhenBranch(pattern = pat, binding_name = binding, binding_line = 0, binding_column = 0,
            body = stmt_ptr_to_span(s, branch_body))
        branches.push(wb)
        parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of when body")
    var branches_span = branches.as_span()
    var node = parser.alloc_stmt(s)
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
    let start_tok = pstate.previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    let declaration = parser.parse_decl(s)
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_emit(declaration = declaration, line = ln, column = cn)
    return node


function parse_inline_for_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = pstate.peek(s) else:
        return stmt_error_sentinel(s, c"unexpected eof in inline for")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    parser.consume_name(s, c"expected loop variable")
    var bindings = vec.Vec[ast.ForBinding].create()
    var first_b = ast.ForBinding(name = parser.previous_lexeme(s), line = ln, column = cn)
    bindings.push(first_b)
    while pstate.match_kind(s, tk.TokenKind.comma):
        parser.consume_name(s, c"expected loop variable")
        var b_ln: ptr_uint = 0
        var b_cn: ptr_uint = 0
        unsafe:
            b_ln = read(pstate.previous_token(s)).line
            b_cn = read(pstate.previous_token(s)).column
        var b = ast.ForBinding(name = parser.previous_lexeme(s), line = b_ln, column = b_cn)
        bindings.push(b)
    pstate.consume(s, tk.TokenKind.tk_in, c"expected 'in' in for loop")
    var iterables = vec.Vec[ast.Expr].create()
    var iter = parser.parse_expr(s)
    unsafe:
        iterables.push(read(iter))
    while pstate.match_kind(s, tk.TokenKind.comma):
        var next_iter = parser.parse_expr(s)
        unsafe:
            iterables.push(read(next_iter))
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after for iterable")
    pstate.consume(s, tk.TokenKind.newline, c"expected newline")
    pstate.consume(s, tk.TokenKind.indent, c"expected indented block")
    var body_span = parser.parse_block_body(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of block")
    var bindings_span = bindings.as_span()
    var iterables_span = iterables.as_span()
    var body = parser.alloc_stmt(s)
    unsafe:
        read(body) = ast.Stmt.stmt_block(statements = body_span)
    var node = parser.alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_for(bindings = bindings_span, iterables = iterables_span,
            body = body, is_inline = true, threaded = false, line = ln, column = cn)
    return node


function parse_inline_while_stmt(s: ref[pstate.ParserState], inline_tok: ptr[token_mod.Token]) -> ptr[ast.Stmt]:
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(inline_tok).line
        cn = read(inline_tok).column
    var condition = parser.parse_expr(s)
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after while condition")
    pstate.consume(s, tk.TokenKind.newline, c"expected newline")
    pstate.consume(s, tk.TokenKind.indent, c"expected indented body")
    var body_span = parser.parse_block_body(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of body")
    var body = parser.alloc_stmt(s)
    unsafe:
        read(body) = ast.Stmt.stmt_block(statements = body_span)
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_while(condition = condition, body = body, is_inline = true, line = ln, column = cn, length = 6)
    return node


function parse_inline_match_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = pstate.previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var scrutinee = parser.parse_expr(s)
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after match expression")
    pstate.consume(s, tk.TokenKind.newline, c"expected newline")
    pstate.consume(s, tk.TokenKind.indent, c"expected indented match body")
    parser.skip_newlines(s)
    var arms = vec.Vec[ast.MatchArm].create()
    while not pstate.check(s, tk.TokenKind.dedent) and not parser.eof(s):
        parser.skip_newlines(s)
        parse_match_arm_into(s, ref_of(arms))
        if s.panic:
            parser.recover_match_arm(s)
        parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of match body")
    var arms_span = arms.as_span()
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_match(scrutinee = scrutinee, arms = arms_span, is_inline = true, line = ln, column = cn)
    return node


function parse_inline_if_stmt(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    let start_tok = pstate.previous_token(s)
    var start_ln: ptr_uint
    var start_cn: ptr_uint
    unsafe:
        start_ln = read(start_tok).line
        start_cn = read(start_tok).column
    var condition = parser.parse_expr(s)
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after if condition")
    var then_body = parse_block_or_inline_stmt(s)
    var branches = vec.Vec[ast.IfBranch].create()
    var branch = ast.IfBranch(condition = condition, body = then_body, line = start_ln, column = start_cn, length = 2)
    branches.push(branch)
    var else_body: ptr[ast.Stmt]? = null
    while pstate.match_kind(s, tk.TokenKind.tk_else):
        if pstate.match_kind(s, tk.TokenKind.tk_if):
            let elif_tok = pstate.previous_token(s)
            var elif_ln: ptr_uint = 0
            var elif_cn: ptr_uint = 0
            unsafe:
                elif_ln = read(elif_tok).line
                elif_cn = read(elif_tok).column
            condition = parser.parse_expr(s)
            pstate.consume(s, tk.TokenKind.colon, c"expected ':' after elif condition")
            var elif_body = parse_block_or_inline_stmt(s)
            var elif_branch = ast.IfBranch(condition = condition, body = elif_body, line = elif_ln, column = elif_cn, length = 2)
            branches.push(elif_branch)
        else:
            pstate.consume(s, tk.TokenKind.colon, c"expected ':' after else")
            else_body = parse_block_or_inline_stmt(s)
            break
    var branches_span = branches.as_span()
    var node = parser.alloc_stmt(s)
    unsafe:
        read(node) = ast.Stmt.stmt_if(branches = branches_span, else_body = else_body,
            is_inline = true, line = start_ln, else_line = 0, else_column = 0)
    return node
