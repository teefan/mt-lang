import parser.token_stream as ts
import lexer.token as token
import parser.blocks as blocks
import parser.type_parsing as types
import parser.ast_types as ast
import std.log as log
import std.fmt as fmt

public function report_error(stream: ref[ts.TokenStream], message: str) -> void:
    let tok = ts.peek(stream)
    let kind_name = token.token_kind_name(tok.kind)
    var msg = fmt.format(f"#{stream.path}:#{tok.line}:#{tok.column}: error: #{message} (got #{tok.lexeme} / kind=#{kind_name})")
    defer msg.release()


# ---- Entry point ----

public function parse_expression(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    return parse_assignment(stream, builder, out_idx)


public function parse_expression_void(stream: ref[ts.TokenStream]) -> bool:
    var builder = ast.ExprBuilder.create()
    defer builder.release()
    var idx: ast.ExprIdx = ast.EXPR_NULL
    return parse_expression(stream, ref_of(builder), ref_of(idx))


public function is_assign_op(lexeme: str) -> bool:
    return (
        lexeme == "="
        or lexeme == "+=" or lexeme == "-=" or lexeme == "*=" or lexeme == "/="
        or lexeme == "%=" or lexeme == "&=" or lexeme == "|=" or lexeme == "^="
        or lexeme == "<<=" or lexeme == ">>="
    )


function parse_assignment(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_range(stream, builder, out_idx):
        return false
    let tok = ts.peek(stream)
    if tok.kind == token.TokenKind.symbol and is_assign_op(tok.lexeme):
        ts.advance(stream)
        var right: ast.ExprIdx = ast.EXPR_NULL
        if not parse_assignment(stream, builder, ref_of(right)):
            return false
        read(out_idx) = builder.push(ast.Expr.binary(op = tok.lexeme, left = read(out_idx), right = right, start_off = tok.start_offset, end_off = tok.end_offset))
    return true


# ---- Range ----

function parse_range(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_or(stream, builder, out_idx):
        return false

    if ts.check_symbol(stream, ".."):
        let tok = ts.peek(stream)
        ts.advance(stream)
        var right: ast.ExprIdx = ast.EXPR_NULL
        if not parse_or(stream, builder, ref_of(right)):
            return false
        read(out_idx) = builder.push(ast.Expr.range_op(left = read(out_idx), right = right, start_off = tok.start_offset, end_off = tok.end_offset))

    return true


# ---- Binary operator chain (low to high precedence) ----

function parse_or(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_and(stream, builder, out_idx):
        return false
    while ts.check_keyword(stream, "or"):
        let op_tok = ts.peek(stream)
        ts.advance(stream)
        var right: ast.ExprIdx = ast.EXPR_NULL
        if not parse_and(stream, builder, ref_of(right)):
            return false
        read(out_idx) = builder.push(ast.Expr.binary(op = "or", left = read(out_idx), right = right, start_off = op_tok.start_offset, end_off = op_tok.end_offset))
    return true


function parse_and(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_not(stream, builder, out_idx):
        return false
    while ts.check_keyword(stream, "and"):
        let op_tok = ts.peek(stream)
        ts.advance(stream)
        var right: ast.ExprIdx = ast.EXPR_NULL
        if not parse_not(stream, builder, ref_of(right)):
            return false
        read(out_idx) = builder.push(ast.Expr.binary(op = "and", left = read(out_idx), right = right, start_off = op_tok.start_offset, end_off = op_tok.end_offset))
    return true


function parse_not(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if ts.check_keyword(stream, "not"):
        let op_tok = ts.peek(stream)
        ts.advance(stream)
        if not parse_not(stream, builder, out_idx):
            return false
        read(out_idx) = builder.push(ast.Expr.unary(op = "not", operand = read(out_idx), start_off = op_tok.start_offset, end_off = op_tok.end_offset))
        return true
    return parse_is(stream, builder, out_idx)


function parse_is(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_bitwise_or(stream, builder, out_idx):
        return false
    if ts.check_keyword(stream, "is"):
        ts.advance(stream)
        var arm: ast.ExprIdx = ast.EXPR_NULL
        let _ = parse_bitwise_or(stream, builder, ref_of(arm))
    return true


function parse_bitwise_or(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_bitwise_xor(stream, builder, out_idx):
        return false
    while ts.check_symbol(stream, "|"):
        let op_tok = ts.peek(stream)
        ts.advance(stream)
        var right: ast.ExprIdx = ast.EXPR_NULL
        if not parse_bitwise_xor(stream, builder, ref_of(right)):
            return false
        read(out_idx) = builder.push(ast.Expr.binary(op = op_tok.lexeme, left = read(out_idx), right = right, start_off = op_tok.start_offset, end_off = op_tok.end_offset))
    return true


function parse_bitwise_xor(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_bitwise_and(stream, builder, out_idx):
        return false
    while ts.check_symbol(stream, "^"):
        let op_tok = ts.peek(stream)
        ts.advance(stream)
        var right: ast.ExprIdx = ast.EXPR_NULL
        if not parse_bitwise_and(stream, builder, ref_of(right)):
            return false
        read(out_idx) = builder.push(ast.Expr.binary(op = op_tok.lexeme, left = read(out_idx), right = right, start_off = op_tok.start_offset, end_off = op_tok.end_offset))
    return true


function parse_bitwise_and(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_equality(stream, builder, out_idx):
        return false
    while ts.check_symbol(stream, "&"):
        let op_tok = ts.peek(stream)
        ts.advance(stream)
        var right: ast.ExprIdx = ast.EXPR_NULL
        if not parse_equality(stream, builder, ref_of(right)):
            return false
        read(out_idx) = builder.push(ast.Expr.binary(op = op_tok.lexeme, left = read(out_idx), right = right, start_off = op_tok.start_offset, end_off = op_tok.end_offset))
    return true


function parse_equality(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_comparison(stream, builder, out_idx):
        return false
    while ts.check_symbol(stream, "==") or ts.check_symbol(stream, "!="):
        let op_tok = ts.peek(stream)
        ts.advance(stream)
        var right: ast.ExprIdx = ast.EXPR_NULL
        if not parse_comparison(stream, builder, ref_of(right)):
            return false
        read(out_idx) = builder.push(ast.Expr.binary(op = op_tok.lexeme, left = read(out_idx), right = right, start_off = op_tok.start_offset, end_off = op_tok.end_offset))
    return true


function parse_comparison(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_shift(stream, builder, out_idx):
        return false
    let tok = ts.peek(stream)
    if tok.kind == token.TokenKind.symbol and (
        tok.lexeme == "<" or tok.lexeme == "<=" or tok.lexeme == ">" or tok.lexeme == ">="
    ):
        ts.advance(stream)
        var right: ast.ExprIdx = ast.EXPR_NULL
        if not parse_shift(stream, builder, ref_of(right)):
            return false
        read(out_idx) = builder.push(ast.Expr.binary(op = tok.lexeme, left = read(out_idx), right = right, start_off = tok.start_offset, end_off = tok.end_offset))
    return true


function parse_shift(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_additive(stream, builder, out_idx):
        return false
    let tok = ts.peek(stream)
    if tok.kind == token.TokenKind.symbol and (tok.lexeme == "<<" or tok.lexeme == ">>"):
        ts.advance(stream)
        var right: ast.ExprIdx = ast.EXPR_NULL
        if not parse_additive(stream, builder, ref_of(right)):
            return false
        read(out_idx) = builder.push(ast.Expr.binary(op = tok.lexeme, left = read(out_idx), right = right, start_off = tok.start_offset, end_off = tok.end_offset))
    return true


function parse_additive(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_multiplicative(stream, builder, out_idx):
        return false
    let tok = ts.peek(stream)
    if tok.kind == token.TokenKind.symbol and (tok.lexeme == "+" or tok.lexeme == "-"):
        ts.advance(stream)
        var right: ast.ExprIdx = ast.EXPR_NULL
        if not parse_multiplicative(stream, builder, ref_of(right)):
            return false
        read(out_idx) = builder.push(ast.Expr.binary(op = tok.lexeme, left = read(out_idx), right = right, start_off = tok.start_offset, end_off = tok.end_offset))
    return true


function parse_multiplicative(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_unary(stream, builder, out_idx):
        return false
    let tok = ts.peek(stream)
    if tok.kind == token.TokenKind.symbol and (tok.lexeme == "*" or tok.lexeme == "/" or tok.lexeme == "%"):
        ts.advance(stream)
        var right: ast.ExprIdx = ast.EXPR_NULL
        if not parse_unary(stream, builder, ref_of(right)):
            return false
        read(out_idx) = builder.push(ast.Expr.binary(op = tok.lexeme, left = read(out_idx), right = right, start_off = tok.start_offset, end_off = tok.end_offset))
    return true


# ---- Prefix/Unary ----

function parse_unary(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if try_parse_prefix_cast(stream, builder, out_idx):
        return true

    if ts.check_keyword(stream, "unsafe"):
        let start_off = ts.peek(stream).start_offset
        ts.advance(stream)
        if not ts.match_symbol(stream, ":"):
            report_error(stream, "expected ':' after unsafe in expression")
            return false
        var body: ast.ExprIdx = ast.EXPR_NULL
        if not parse_expression(stream, builder, ref_of(body)):
            return false
        let end_off = ts.peek_prev(stream).end_offset
        read(out_idx) = builder.push(ast.Expr.unsafe_expr(body = body, start_off = start_off, end_off = end_off))
        return true

    if ts.check_keyword(stream, "await"):
        let start_off = ts.peek(stream).start_offset
        ts.advance(stream)
        if not parse_unary(stream, builder, out_idx):
            return false
        let end_off = ts.peek_prev(stream).end_offset
        read(out_idx) = builder.push(ast.Expr.await_expr(operand = read(out_idx), start_off = start_off, end_off = end_off))
        return true

    if ts.check_keyword(stream, "detach"):
        let start_off = ts.peek(stream).start_offset
        ts.advance(stream)
        if not parse_unary(stream, builder, out_idx):
            return false
        let end_off = ts.peek_prev(stream).end_offset
        read(out_idx) = builder.push(ast.Expr.detach_expr(operand = read(out_idx), start_off = start_off, end_off = end_off))
        return true

    let tok = ts.peek(stream)
    if tok.kind == token.TokenKind.symbol:
        if tok.lexeme == "-" or tok.lexeme == "+" or tok.lexeme == "~":
            let op = tok.lexeme
            ts.advance(stream)
            var operand: ast.ExprIdx = ast.EXPR_NULL
            if not parse_unary(stream, builder, ref_of(operand)):
                return false
            let end_off = ts.peek_prev(stream).end_offset
            read(out_idx) = builder.push(ast.Expr.unary(op = op, operand = operand, start_off = tok.start_offset, end_off = end_off))
            return true

    return parse_postfix(stream, builder, out_idx)


function try_parse_prefix_cast(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    let saved = ts.save_position(stream)
    let tok = ts.peek(stream)

    if tok.kind != token.TokenKind.identifier and tok.kind != token.TokenKind.keyword:
        return false

    var type_builder = ast.TypeBuilder.create()
    defer type_builder.release()
    var type_idx: ast.TypeExprIdx = ast.TYPE_EXPR_NULL
    if not types.parse_type_ref(stream, ref_of(type_builder), ref_of(type_idx)):
        ts.restore_position(stream, saved)
        return false

    if not ts.check_symbol(stream, "<"):
        ts.restore_position(stream, saved)
        return false

    let next_tok = ts.peek_next(stream, 1)
    if next_tok.kind != token.TokenKind.symbol or next_tok.lexeme != "-":
        ts.restore_position(stream, saved)
        return false

    let start_off = tok.start_offset
    ts.advance(stream)
    ts.advance(stream)

    var operand: ast.ExprIdx = ast.EXPR_NULL
    if not parse_unary(stream, builder, ref_of(operand)):
        return false
    let end_off = ts.peek_prev(stream).end_offset
    read(out_idx) = builder.push(ast.Expr.prefix_cast(
        cast_type = ts.source_slice(stream, start_off, next_tok.start_offset),
        operand = operand,
        start_off = start_off,
        end_off = end_off,
    ))
    return true


# ---- Postfix ----

function parse_postfix(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if not parse_primary(stream, builder, out_idx):
        return false

    while not ts.eof(stream):
        let tok = ts.peek(stream)

        if tok.kind == token.TokenKind.symbol:
            if tok.lexeme == ".":
                ts.advance(stream)
                let k = ts.peek_kind(stream)
                if k == token.TokenKind.identifier or k == token.TokenKind.keyword:
                    let member = ts.peek(stream).lexeme
                    ts.advance(stream)
                    let end_off = ts.peek_prev(stream).end_offset
                    read(out_idx) = builder.push(ast.Expr.postfix_access(member = member, start_off = tok.start_offset, end_off = end_off))
            else if tok.lexeme == "(":
                ts.advance(stream)
                blocks.parse_group_content(stream, "(", ")")
                let end_off = ts.peek_prev(stream).end_offset
                read(out_idx) = builder.push(ast.Expr.postfix_call(start_off = tok.start_offset, end_off = end_off))
            else if tok.lexeme == "[":
                ts.advance(stream)
                blocks.parse_group_content(stream, "[", "]")
                let end_off = ts.peek_prev(stream).end_offset
                read(out_idx) = builder.push(ast.Expr.postfix_index(start_off = tok.start_offset, end_off = end_off))
            else if tok.lexeme == "?":
                ts.advance(stream)
                let end_off = ts.peek_prev(stream).end_offset
                read(out_idx) = builder.push(ast.Expr.postfix_propagate(start_off = tok.start_offset, end_off = end_off))
            else:
                break
        else:
            break

    return true


# ---- Primary expressions ----

function parse_primary(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    if ts.check_keyword(stream, "proc"):
        let start_off = ts.peek(stream).start_offset
        ts.advance(stream)
        if not parse_proc_expr(stream):
            return false
        let end_off = ts.peek_prev(stream).end_offset
        read(out_idx) = builder.push(ast.Expr.proc_expr(start_off = start_off, end_off = end_off))
        return true

    if ts.check_keyword(stream, "if"):
        return parse_if_expr(stream, builder, out_idx)

    if ts.check_keyword(stream, "match"):
        return parse_match_expr(stream, builder, out_idx)

    if ts.check_keyword(stream, "unsafe"):
        let start_off = ts.peek(stream).start_offset
        ts.advance(stream)
        if not ts.match_symbol(stream, ":"):
            report_error(stream, "expected ':' after unsafe in expression")
            return false
        var body: ast.ExprIdx = ast.EXPR_NULL
        if not parse_expression(stream, builder, ref_of(body)):
            return false
        let end_off = ts.peek_prev(stream).end_offset
        read(out_idx) = builder.push(ast.Expr.unsafe_expr(body = body, start_off = start_off, end_off = end_off))
        return true

    if ts.check_keyword(stream, "size_of"):
        return parse_builtin_call(stream, builder, out_idx)
    if ts.check_keyword(stream, "align_of"):
        return parse_builtin_call(stream, builder, out_idx)
    if ts.check_keyword(stream, "offset_of"):
        let start_off = ts.peek(stream).start_offset
        ts.advance(stream)
        ts.match_symbol(stream, "(")
        var type_name: str = ""
        let _ = types.parse_type_ref_as_text(stream, ref_of(type_name))
        ts.match_symbol(stream, ",")
        var field_name: str = ""
        if ts.peek_kind(stream) == token.TokenKind.identifier:
            field_name = ts.peek(stream).lexeme
            ts.advance(stream)
        ts.match_symbol(stream, ")")
        let end_off = ts.peek_prev(stream).end_offset
        read(out_idx) = builder.push(ast.Expr.offset_of_call(type_name = type_name, field_name = field_name, start_off = start_off, end_off = end_off))
        return true

    if ts.check_keyword(stream, "true") or ts.check_keyword(stream, "false"):
        let tok = ts.peek(stream)
        ts.advance(stream)
        read(out_idx) = builder.push(ast.Expr.literal_bool(value = tok.lexeme == "true", start_off = tok.start_offset, end_off = tok.end_offset))
        return true

    if ts.check_keyword(stream, "null"):
        let tok = ts.peek(stream)
        ts.advance(stream)
        var end_off = tok.end_offset
        if ts.match_symbol(stream, "["):
            var type_name: str = ""
            let _ = types.parse_type_ref_as_text(stream, ref_of(type_name))
            let close = ts.peek(stream)
            if ts.match_symbol(stream, "]"):
                end_off = close.end_offset
        read(out_idx) = builder.push(ast.Expr.literal_null(start_off = tok.start_offset, end_off = end_off))
        return true

    let tok = ts.peek(stream)

    if tok.kind == token.TokenKind.symbol and tok.lexeme == "(":
        let start_off = tok.start_offset
        ts.advance(stream)

        if ts.check_symbol(stream, ")"):
            let end_off = ts.peek(stream).end_offset
            ts.advance(stream)
            read(out_idx) = builder.push(ast.Expr.group(inner = ast.EXPR_NULL, start_off = start_off, end_off = end_off))
            return true

        var inner: ast.ExprIdx = ast.EXPR_NULL
        if not parse_expression(stream, builder, ref_of(inner)):
            return false

        while ts.match_symbol(stream, ","):
            if ts.check_symbol(stream, ")"):
                break
            var next: ast.ExprIdx = ast.EXPR_NULL
            if not parse_expression(stream, builder, ref_of(next)):
                return false

        let end_off = ts.peek_prev(stream).end_offset
        read(out_idx) = builder.push(ast.Expr.group(inner = inner, start_off = start_off, end_off = end_off))
        let _ = ts.match_symbol(stream, ")")
        return true

    if (
        tok.kind == token.TokenKind.integer_literal
        or tok.kind == token.TokenKind.float_literal
        or tok.kind == token.TokenKind.char_literal
        or tok.kind == token.TokenKind.string_literal
        or tok.kind == token.TokenKind.cstring_literal
        or tok.kind == token.TokenKind.fstring_literal
    ):
        ts.advance(stream)
        let kind = tok.kind
        let lex = tok.lexeme
        let start_off = tok.start_offset
        let end_off = tok.end_offset
        if kind == token.TokenKind.integer_literal:
            read(out_idx) = builder.push(ast.Expr.literal_int(value = lex, start_off = start_off, end_off = end_off))
        else if kind == token.TokenKind.float_literal:
            read(out_idx) = builder.push(ast.Expr.literal_float(value = lex, start_off = start_off, end_off = end_off))
        else if kind == token.TokenKind.char_literal:
            read(out_idx) = builder.push(ast.Expr.literal_char(value = lex, start_off = start_off, end_off = end_off))
        else if kind == token.TokenKind.string_literal:
            read(out_idx) = builder.push(ast.Expr.literal_string(value = lex, start_off = start_off, end_off = end_off))
        else if kind == token.TokenKind.cstring_literal:
            read(out_idx) = builder.push(ast.Expr.literal_cstring(value = lex, start_off = start_off, end_off = end_off))
        else:
            read(out_idx) = builder.push(ast.Expr.literal_fstring(value = lex, start_off = start_off, end_off = end_off))
        return true

    if tok.kind == token.TokenKind.identifier:
        ts.advance(stream)
        read(out_idx) = builder.push(ast.Expr.identifier(name = tok.lexeme, start_off = tok.start_offset, end_off = tok.end_offset))
        return true

    if tok.kind == token.TokenKind.keyword:
        ts.advance(stream)
        read(out_idx) = builder.push(ast.Expr.identifier(name = tok.lexeme, start_off = tok.start_offset, end_off = tok.end_offset))
        return true

    report_error(stream, "expected expression")
    return false


function parse_builtin_call(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    let tok = ts.peek(stream)
    ts.advance(stream)
    if not ts.match_symbol(stream, "("):
        return false
    var type_name: str = ""
    let _ = types.parse_type_ref_as_text(stream, ref_of(type_name))
    let end_off = ts.peek_prev(stream).end_offset
    let _ = ts.match_symbol(stream, ")")
    read(out_idx) = builder.push(ast.Expr.builtin_call(name = tok.lexeme, start_off = tok.start_offset, end_off = end_off))
    return true


# ---- Proc expression ----

function parse_proc_expr(stream: ref[ts.TokenStream]) -> bool:
    if not ts.match_symbol(stream, "("):
        return false

    blocks.parse_group_content(stream, "(", ")")

    if ts.check_symbol(stream, "->"):
        ts.advance(stream)
        var type_name: str = ""
        let _ = types.parse_type_ref_as_text(stream, ref_of(type_name))

    if not ts.match_symbol(stream, ":"):
        return false

    return parse_body_or_expr(stream)


# ---- If expression ----

function parse_if_expr(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    let start_off = ts.peek_prev(stream).end_offset
    var cond: ast.ExprIdx = ast.EXPR_NULL
    if not parse_expression(stream, builder, ref_of(cond)):
        return false

    if not ts.match_symbol(stream, ":"):
        report_error(stream, "expected ':' after condition in if expression")
        return false

    var then_branch: ast.ExprIdx = ast.EXPR_NULL
    if not parse_expression(stream, builder, ref_of(then_branch)):
        return false

    var else_branch: ast.ExprIdx = ast.EXPR_NULL
    if ts.check_keyword(stream, "else"):
        ts.advance(stream)
        if not ts.match_symbol(stream, ":"):
            report_error(stream, "expected ':' after 'else' in if expression")
            return false
        let _ = parse_expression(stream, builder, ref_of(else_branch))

    let end_off = ts.peek_prev(stream).end_offset
    read(out_idx) = builder.push(ast.Expr.if_expr(cond = cond, then_branch = then_branch, else_branch = else_branch, start_off = start_off, end_off = end_off))
    return true


# ---- Match expression ----

function parse_match_expr(stream: ref[ts.TokenStream], builder: ref[ast.ExprBuilder], out_idx: ref[ast.ExprIdx]) -> bool:
    let start_off = ts.peek_prev(stream).end_offset
    var scrutinee: ast.ExprIdx = ast.EXPR_NULL
    if not parse_expression(stream, builder, ref_of(scrutinee)):
        return false

    if not ts.match_symbol(stream, ":"):
        return false
    if not ts.match_kind(stream, token.TokenKind.newline):
        return false
    if ts.match_kind(stream, token.TokenKind.indent):
        blocks.skip_to_dedent(stream)
        let end_off = ts.peek_prev(stream).end_offset
        read(out_idx) = builder.push(ast.Expr.match_expr(scrutinee = scrutinee, start_off = start_off, end_off = end_off))
        return true

    while not ts.eof(stream):
        let k = ts.peek_kind(stream)
        if k == token.TokenKind.dedent or k == token.TokenKind.eof:
            break
        if k == token.TokenKind.keyword:
            let lx = ts.peek(stream).lexeme
            if lx == "let" or lx == "var" or lx == "return" or lx == "defer" or lx == "if" or lx == "while" or lx == "for" or lx == "match" or lx == "unsafe" or lx == "static_assert" or lx == "emit" or lx == "gather" or lx == "pass" or lx == "break" or lx == "continue" or lx == "when" or lx == "inline" or lx == "parallel":
                break
        ts.advance(stream)
    let end_off = ts.peek_prev(stream).end_offset
    read(out_idx) = builder.push(ast.Expr.match_expr(scrutinee = scrutinee, start_off = start_off, end_off = end_off))
    return true


# ---- Block body / expression disambiguation ----

function parse_body_or_expr(stream: ref[ts.TokenStream]) -> bool:
    if ts.check_kind(stream, token.TokenKind.newline):
        ts.advance(stream)
        if ts.check_kind(stream, token.TokenKind.indent):
            ts.advance(stream)
            blocks.skip_to_dedent(stream)
            return true
        var builder = ast.ExprBuilder.create()
        defer builder.release()
        var idx: ast.ExprIdx = ast.EXPR_NULL
        return parse_expression(stream, ref_of(builder), ref_of(idx))

    var builder = ast.ExprBuilder.create()
    defer builder.release()
    var idx: ast.ExprIdx = ast.EXPR_NULL
    return parse_expression(stream, ref_of(builder), ref_of(idx))


# ---- Utility ----

function parse_expr_comma_list(stream: ref[ts.TokenStream], end_symbol: str) -> void:
    while not ts.check_symbol(stream, end_symbol) and not ts.eof(stream):
        var builder = ast.ExprBuilder.create()
        defer builder.release()
        var idx: ast.ExprIdx = ast.EXPR_NULL
        let _ = parse_expression(stream, ref_of(builder), ref_of(idx))
        if not ts.match_symbol(stream, ","):
            break
