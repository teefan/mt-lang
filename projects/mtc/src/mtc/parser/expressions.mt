## Expressions — the precedence-climbing expression parser and its
## specialization-target disambiguation.  Extracted from parser.mt.

import std.vec as vec

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.parser.ast as ast
import mtc.parser.state as pstate
import mtc.parser.parser as parser
import mtc.parser.declarations as declarations


public function parse_expr(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    if pstate.match_kind(s, tk.TokenKind.tk_if):
        return parser.parse_if_expr(s)
    if pstate.match_kind(s, tk.TokenKind.tk_match):
        return parser.parse_match_expr(s)
    if pstate.match_kind(s, tk.TokenKind.tk_unsafe):
        return parser.parse_unsafe_expr(s)
    return parse_range(s)


## Column of a pattern/expression's own token (0 when it carries none).
function expr_column_of(ep: ptr[ast.Expr]) -> ptr_uint:
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as x:
                return x.column
            ast.Expr.expr_char_literal as x:
                return x.column
            ast.Expr.expr_null_literal as x:
                return x.column
            ast.Expr.expr_member_access as x:
                return x.column
            ast.Expr.expr_match as x:
                return x.column
            ast.Expr.expr_detach as x:
                return x.column
            ast.Expr.expr_expression_list as x:
                return x.column
            ast.Expr.expr_range as x:
                return x.column
            ast.Expr.expr_prefix_cast as x:
                return x.column
            ast.Expr.expr_unsafe as x:
                return x.column
            ast.Expr.expr_error as x:
                return x.column
            _:
                pass
    return 0


function parse_range(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_or(s)
    if pstate.match_kind(s, tk.TokenKind.dot_dot):
        let dd_tok = pstate.previous_token(s)
        var dd_ln: ptr_uint = 0
        unsafe:
            dd_ln = read(dd_tok).line
        var right = parse_or(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_range(start_expr = left, end_expr = right, line = dd_ln, column = expr_column_of(left))
        return node
    return left


function parse_or(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_and(s)
    while pstate.match_kind(s, tk.TokenKind.tk_or):
        let op = parser.previous_lexeme(s)
        var right = parse_and(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_and(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_not(s)
    while pstate.match_kind(s, tk.TokenKind.tk_and):
        let op = parser.previous_lexeme(s)
        var right = parse_not(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_not(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    if pstate.match_kind(s, tk.TokenKind.tk_not):
        let op = parser.previous_lexeme(s)
        var operand = parse_not(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_unary_op(operator = op, operand = operand)
        return node
    return parse_is(s)


function parse_is(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_bitwise_or(s)
    # The arm pattern is parsed at `bitwise_or` precedence (not full expression),
    # so `e is A or e is B` groups as `(e is A) or (e is B)` — matching Ruby's
    # parse_is.  Using parse_expr here would greedily absorb the trailing
    # `or ...` into the pattern.  Left-associative via the `while` loop.
    while pstate.match_kind(s, tk.TokenKind.tk_is):
        let is_tok = pstate.previous_token(s)
        var is_ln: ptr_uint = 0
        var is_cn: ptr_uint = 0
        unsafe:
            is_ln = read(is_tok).line
            is_cn = read(is_tok).column
        var pattern = parse_bitwise_or(s)
        var pattern_len: ptr_uint = 0
        unsafe:
            pattern_len = token_mod.token_lexeme(read(pstate.previous_token(s)), s.source).len
        left = parser.is_desugar(s, left, pattern, is_ln, is_cn, pattern_len)
    return left


function parse_bitwise_or(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_bitwise_xor(s)
    while pstate.match_kind(s, tk.TokenKind.pipe):
        let op = parser.previous_lexeme(s)
        var right = parse_bitwise_xor(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


public function parse_bitwise_xor(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_bitwise_and(s)
    while pstate.match_kind(s, tk.TokenKind.caret):
        let op = parser.previous_lexeme(s)
        var right = parse_bitwise_and(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_bitwise_and(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_equality(s)
    while pstate.match_kind(s, tk.TokenKind.amp):
        let op = parser.previous_lexeme(s)
        var right = parse_equality(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_equality(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_comparison(s)
    while pstate.check(s, tk.TokenKind.equal_equal) or pstate.check(s, tk.TokenKind.bang_equal):
        pstate.advance(s)
        let op = parser.previous_lexeme(s)
        var right = parse_comparison(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_comparison(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_shift(s)
    while (
        pstate.check(s, tk.TokenKind.less) or pstate.check(s, tk.TokenKind.less_equal)
        or pstate.check(s, tk.TokenKind.greater) or pstate.check(s, tk.TokenKind.greater_equal)
    ):
        pstate.advance(s)
        let op = parser.previous_lexeme(s)
        var right = parse_shift(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_shift(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_additive(s)
    while pstate.check(s, tk.TokenKind.shift_left) or pstate.check(s, tk.TokenKind.shift_right):
        pstate.advance(s)
        let op = parser.previous_lexeme(s)
        var right = parse_additive(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_additive(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_multiplicative(s)
    while pstate.check(s, tk.TokenKind.plus) or pstate.check(s, tk.TokenKind.minus):
        pstate.advance(s)
        let op = parser.previous_lexeme(s)
        var right = parse_multiplicative(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


function parse_multiplicative(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parse_unary(s)
    while pstate.check(s, tk.TokenKind.star) or pstate.check(s, tk.TokenKind.slash) or pstate.check(s, tk.TokenKind.percent):
        pstate.advance(s)
        let op = parser.previous_lexeme(s)
        var right = parse_unary(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_binary_op(operator = op, left = left, right = right)
        left = node
    return left


public function parse_unary(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    if pstate.match_kind(s, tk.TokenKind.tk_unsafe):
        return parser.parse_unsafe_expr(s)
    if pstate.match_kind(s, tk.TokenKind.tk_await):
        var operand = parse_unary(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_await(expression = operand)
        return node
    if pstate.match_kind(s, tk.TokenKind.tk_detach):
        var detach_line: ptr_uint
        var detach_col: ptr_uint
        let dtok = pstate.previous_token(s)
        unsafe:
            detach_line = dtok.line
            detach_col = dtok.column
        var expr_val = parse_unary(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_detach(expression = expr_val, line = detach_line, column = detach_col)
        return node
    if pstate.check(s, tk.TokenKind.minus) or pstate.check(s, tk.TokenKind.tilde) or pstate.check(s, tk.TokenKind.plus):
        pstate.advance(s)
        let op = parser.previous_lexeme(s)
        var operand = parse_unary(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_unary_op(operator = op, operand = operand)
        return node
    if pstate.check(s, tk.TokenKind.tk_out) or pstate.check(s, tk.TokenKind.tk_in) or pstate.check(s, tk.TokenKind.tk_inout):
        pstate.advance(s)
        let op = parser.previous_lexeme(s)
        var operand = parse_unary(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_unary_op(operator = op, operand = operand)
        return node
    var cast_result = parser.try_parse_prefix_cast_expr(s)
    match cast_result:
        Option.some as cast_payload:
            return cast_payload.value
        Option.none:
            pass
    return parse_postfix(s)


function parse_postfix(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    var left = parser.parse_primary(s)
    while true:
        pstate.step(s)
        if pstate.match_kind(s, tk.TokenKind.dot):
            parser.consume_name_allowing_keywords(s, c"expected member name after '.'")
            let member = parser.previous_lexeme(s)
            let member_tok = pstate.previous_token(s)
            var node = parser.alloc_expr(s)
            unsafe:
                let mt = read(member_tok)
                read(node) = ast.Expr.expr_member_access(
                    receiver = left,
                    member_name = member,
                    line = mt.line,
                    column = mt.column,
                )
            left = node
        else if pstate.check(s, tk.TokenKind.lbracket):
            if postfix_bracket_starts_specialization(s, left):
                var spec_result = try_parse_specialization(s, left)
                match spec_result:
                    Option.some as spec_val:
                        left = spec_val.value
                    Option.none:
                        pstate.advance(s)
                        var idx = parse_expr(s)
                        pstate.consume(s, tk.TokenKind.rbracket, c"expected ']'")
                        var node = parser.alloc_expr(s)
                        read(node) = ast.Expr.expr_index_access(receiver = left, index = idx)
                        left = node
            else:
                pstate.advance(s)
                var idx = parse_expr(s)
                pstate.consume(s, tk.TokenKind.rbracket, c"expected ']'")
                var node = parser.alloc_expr(s)
                read(node) = ast.Expr.expr_index_access(receiver = left, index = idx)
                left = node
        else if pstate.match_kind(s, tk.TokenKind.lparen):
            var args = parser.parse_call_args(s)
            pstate.consume(s, tk.TokenKind.rparen, c"expected ')' after call arguments")
            var node = parser.alloc_expr(s)
            read(node) = ast.Expr.expr_call(callee = left, args = args)
            left = node
        else if pstate.match_kind(s, tk.TokenKind.question):
            var node = parser.alloc_expr(s)
            read(node) = ast.Expr.expr_unary_op(operator = "?", operand = left)
            left = node
        else:
            break
    return left


function postfix_bracket_starts_specialization(s: ref[pstate.ParserState], left: ptr[ast.Expr]) -> bool:
    return specialization_target(left) and parser.matching_rbracket_index(s, s.stream.current).is_some()


public function specialization_target(left: ptr[ast.Expr]) -> bool:
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
    pstate.advance(s)
    var args_vec = vec.Vec[ast.TypeArgument].create()
    if not pstate.check(s, tk.TokenKind.rbracket):
        while true:
            pstate.step(s)
            var arg = declarations.parse_type_argument(s)
            var ta = ast.TypeArgument(value = arg)
            args_vec.push(ta)
            if not pstate.match_kind(s, tk.TokenKind.comma):
                break
            if pstate.check(s, tk.TokenKind.rbracket):
                break
    let closed = pstate.match_kind(s, tk.TokenKind.rbracket)
    let had_error = s.error_suppressed
    s.suppress_errors = saved_suppress
    s.error_suppressed = saved_flag
    if not closed or had_error:
        s.stream.current = saved
        return Option[ptr[ast.Expr]].none
    let args_span = args_vec.as_span()
    if pstate.match_kind(s, tk.TokenKind.lparen):
        var call_args = parser.parse_call_args(s)
        pstate.consume(s, tk.TokenKind.rparen, c"expected ')' after call arguments")
        if not parser.specialization_call_target(s, left, args_span, call_args):
            s.stream.current = saved
            return Option[ptr[ast.Expr]].none
        var spec = parser.alloc_expr(s)
        unsafe:
            read(spec) = ast.Expr.expr_specialization(callee = left, arguments = args_span)
        var call = parser.alloc_expr(s)
        unsafe:
            read(call) = ast.Expr.expr_call(callee = spec, args = call_args)
        return Option[ptr[ast.Expr]].some(value = call)
    if not parser.specialization_value_target(s, left, args_span):
        s.stream.current = saved
        return Option[ptr[ast.Expr]].none
    var node = parser.alloc_expr(s)
    read(node) = ast.Expr.expr_specialization(callee = left, arguments = args_span)
    return Option[ptr[ast.Expr]].some(value = node)
