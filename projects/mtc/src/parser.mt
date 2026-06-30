import std.str as text
import std.vec as vec
import lexer
import ast


public struct ParseError:
    message: str
    line: int
    column: int


struct Parser:
    tokens: vec.Vec[lexer.Token]
    current: ptr_uint
    known_type_names: vec.Vec[str]
    errors: vec.Vec[ParseError]


function parser_create(tokens: vec.Vec[lexer.Token]) -> Parser:
    var p = Parser(
        tokens = tokens,
        current = 0,
        known_type_names = vec.Vec[str].create(),
        errors = vec.Vec[ParseError].create(),
    )
    seed_known_names(ref_of(p))
    return p


# ── combinators ────────────────────────────────────────────────────────

function peek(p: ref[Parser]) -> lexer.Token:
    let self = unsafe: read(ptr[Parser]<-p)
    let t = self.tokens.get(self.current) else:
        fatal("parser: unexpected end of tokens")
    return unsafe: read(ptr[lexer.Token]<-t)


function advance(p: ref[Parser]) -> lexer.Token:
    let self = unsafe: read(ptr[Parser]<-p)
    let prev = peek(p)
    unsafe: read(ptr[Parser]<-p).current = self.current + 1
    return prev


function previous(p: ref[Parser]) -> lexer.Token:
    let self = unsafe: read(ptr[Parser]<-p)
    if self.current == 0:
        return peek(p)
    let t = self.tokens.get(self.current - 1) else:
        return peek(p)
    return unsafe: read(ptr[lexer.Token]<-t)


function eof(p: ref[Parser]) -> bool:
    let self = unsafe: read(ptr[Parser]<-p)
    if self.current >= self.tokens.len():
        return true
    return peek(p).kind == lexer.TOK_EOF


function check(p: ref[Parser], kind: int) -> bool:
    if eof(p):
        return false
    return peek(p).kind == kind


function match_token(p: ref[Parser], kind: int) -> bool:
    if not check(p, kind):
        return false
    let _ = advance(p)
    return true


function consume(p: ref[Parser], kind: int, message: str) -> lexer.Token:
    if match_token(p, kind):
        return previous(p)
    raise_error(p, message, peek(p))
    return peek(p)


function skip_newlines(p: ref[Parser]) -> void:
    while check(p, lexer.TOK_NEWLINE):
        let _ = advance(p)


function raise_error(p: ref[Parser], message: str, token: lexer.Token) -> void:
    unsafe:
        read(ptr[Parser]<-p).errors.push(ParseError(
            message = message, line = token.line, column = token.column))


function is_path_component_kind(kind: int) -> bool:
    return kind == lexer.TOK_IDENTIFIER or (kind >= 20 and kind <= 98)


# ── entry point ────────────────────────────────────────────────────────

public function parse(tokens: vec.Vec[lexer.Token]) -> ast.SourceFile:
    var p = parser_create(tokens)
    var exprs_vec = vec.Vec[ast.Expression].create()
    var result = parse_source_file(ref_of(p), ref_of(exprs_vec))
    p.known_type_names.release()
    p.errors.release()
    return ast.SourceFile(module_name = result.module_name,
        imports = result.imports, declarations = result.declarations,
        exprs = ast.ExpressionPool(exprs = exprs_vec))


function parse_source_file(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.SourceFile:
    var imports = vec.Vec[ast.Import].create()
    var declarations = vec.Vec[ast.Statement].create()

    skip_newlines(p)

    while match_token(p, lexer.TOK_KW_IMPORT):
        imports.push(parse_import(p))
        skip_newlines(p)

    while not eof(p):
        let decl = parse_declaration(p, pool)
        if decl.kind != 0:
            declarations.push(decl)
        skip_newlines(p)

    return ast.SourceFile(module_name = "", imports = imports,
        declarations = declarations,
        exprs = ast.ExpressionPool(exprs = vec.Vec[ast.Expression].create()))


# ── import ─────────────────────────────────────────────────────────────

function parse_import(p: ref[Parser]) -> ast.Import:
    let path = parse_qualified_name(p)
    let last_ptr = path.parts.last() else:
        fatal("parser: import path empty")
    var alias_name = unsafe: read(ptr[str]<-last_ptr)
    var col = previous(p).column

    if match_token(p, lexer.TOK_KW_AS):
        let name_token = consume(p, lexer.TOK_IDENTIFIER, "expected identifier after as")
        alias_name = name_token.lexeme
        col = name_token.column

    consume(p, lexer.TOK_NEWLINE, "expected newline after import")
    return ast.Import(path = path, alias_name = alias_name,
        line = previous(p).line, column = col)


function parse_qualified_name(p: ref[Parser]) -> ast.QualifiedName:
    var parts = vec.Vec[str].create()
    parts.push(consume_path_component(p, "expected identifier").lexeme)
    while match_token(p, lexer.TOK_DOT):
        parts.push(consume_path_component(p, "expected identifier after '.'").lexeme)
    return ast.QualifiedName(parts = parts)


function consume_path_component(p: ref[Parser], message: str) -> lexer.Token:
    if not eof(p) and is_path_component_kind(peek(p).kind):
        return advance(p)
    raise_error(p, message, peek(p))
    return peek(p)


# ── declarations ───────────────────────────────────────────────────────

function parse_declaration(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    skip_newlines(p)
    if check(p, lexer.TOK_KW_IMPORT):
        let _imp = parse_import(p)
        return stmt_empty()

    if match_token(p, lexer.TOK_KW_FUNCTION):
        return parse_function_def(p, pool)
    if match_token(p, lexer.TOK_KW_STRUCT):
        return parse_struct_decl(p)
    if match_token(p, lexer.TOK_KW_ENUM):
        return parse_enum_decl(p, pool)
    if match_token(p, lexer.TOK_KW_FLAGS):
        return parse_flags_decl(p, pool)
    if match_token(p, lexer.TOK_KW_VARIANT):
        return parse_variant_decl(p)
    if match_token(p, lexer.TOK_KW_OPAQUE):
        return parse_opaque_decl(p)
    if match_token(p, lexer.TOK_KW_INTERFACE):
        return parse_interface_decl(p)
    if match_token(p, lexer.TOK_KW_TYPE):
        return parse_type_alias_decl(p)
    if match_token(p, lexer.TOK_KW_VAR):
        return parse_var_decl(p, pool)
    if match_token(p, lexer.TOK_KW_CONST):
        return parse_const_decl(p, pool)
    if match_token(p, lexer.TOK_KW_LET):
        return parse_let_stmt(p, pool)
    if match_token(p, lexer.TOK_KW_RETURN):
        return parse_return_stmt(p, pool)

    let tok = peek(p)
    let _ = advance(p)
    return stmt_empty()


function stmt_empty() -> ast.Statement:
    return ast.Statement(kind = ast.STMT_EMPTY, name = "",
        stmt_type = type_void(), expr2 = 0, op_kind = 0, is_inline = false, expr = 0,
        children = vec.Vec[ast.Statement].create(), else_body = vec.Vec[ast.Statement].create(), bindings = vec.Vec[str].create(), line = 0, column = 0)


function type_void() -> ast.TypeRef:
    return ast.TypeRef(name_parts = vec.Vec[str].create(),
        type_args = vec.Vec[ast.TypeRef].create(), nullable = false, is_function_type = false)


function parse_function_def(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected function name")
    let _ = parse_params(p)
    let ret = parse_optional_return_type(p)
    var body = parse_block(p, pool)
    consume(p, lexer.TOK_NEWLINE, "expected newline after function body")

    return ast.Statement(kind = ast.STMT_FUNCTION, name = name_tok.lexeme,
        stmt_type = ret, expr2 = 0, op_kind = 0, is_inline = false, expr = 0, children = body,
        line = name_tok.line, column = name_tok.column)


function parse_struct_decl(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected struct name")
    consume(p, lexer.TOK_COLON, "expected colon after struct name")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")

    if not match_token(p, lexer.TOK_INDENT):
        return ast.Statement(kind = ast.STMT_STRUCT, name = name_tok.lexeme,
            stmt_type = type_void(),
            children = vec.Vec[ast.Statement].create(),
            line = name_tok.line, column = name_tok.column)

    var fields = vec.Vec[ast.Statement].create()
    while not eof(p) and not check(p, lexer.TOK_DEDENT):
        skip_newlines(p)
        if check(p, lexer.TOK_DEDENT):
            break
        let field_name = consume(p, lexer.TOK_IDENTIFIER, "expected field name")
        consume(p, lexer.TOK_COLON, "expected colon after field name")
        let field_type = parse_type_ref(p)
        consume(p, lexer.TOK_NEWLINE, "expected newline after field type")
        fields.push(ast.Statement(kind = ast.STMT_EMPTY,
            name = field_name.lexeme, stmt_type = field_type,
            children = vec.Vec[ast.Statement].create(),
            line = field_name.line, column = field_name.column))
        skip_newlines(p)

    while check(p, lexer.TOK_DEDENT):
        let _ = advance(p)

    return ast.Statement(kind = ast.STMT_STRUCT, name = name_tok.lexeme,
        stmt_type = type_void(), children = fields,
        line = name_tok.line, column = name_tok.column)

    skip_body(p)

    return ast.Statement(kind = ast.STMT_STRUCT, name = name_tok.lexeme,
        stmt_type = type_void(), expr2 = 0, op_kind = 0, is_inline = false, expr = 0,
        children = vec.Vec[ast.Statement].create(),
        line = name_tok.line, column = name_tok.column)


function parse_enum_decl(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected enum name")
    consume(p, lexer.TOK_COLON, "expected colon after enum name")
    let _bt = parse_type_ref(p)
    consume(p, lexer.TOK_NEWLINE, "expected newline after enum type")

    if not match_token(p, lexer.TOK_INDENT):
        return ast.Statement(kind = ast.STMT_ENUM, name = name_tok.lexeme,
            stmt_type = _bt, children = vec.Vec[ast.Statement].create(),
            line = name_tok.line, column = name_tok.column)

    var members = vec.Vec[ast.Statement].create()
    while not eof(p) and not check(p, lexer.TOK_DEDENT):
        skip_newlines(p)
        if check(p, lexer.TOK_DEDENT):
            break
        let m_name = consume(p, lexer.TOK_IDENTIFIER, "expected enum member name")
        var val_idx: ptr_uint = 0
        if match_token(p, lexer.TOK_EQUAL):
            val_idx = parse_expr(p, pool)
        members.push(ast.Statement(kind = ast.STMT_EMPTY,
            name = m_name.lexeme, stmt_type = type_void(),
            expr = int<-(val_idx),
            children = vec.Vec[ast.Statement].create(),
            line = m_name.line, column = m_name.column))
        consume(p, lexer.TOK_NEWLINE, "expected newline after enum member")
        skip_newlines(p)

    while check(p, lexer.TOK_DEDENT):
        let _ = advance(p)

    return ast.Statement(kind = ast.STMT_ENUM, name = name_tok.lexeme,
        stmt_type = _bt, children = members,
        line = name_tok.line, column = name_tok.column)


function parse_flags_decl(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    return parse_enum_decl(p, pool)


function parse_variant_decl(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected variant name")
    consume(p, lexer.TOK_COLON, "expected colon after variant name")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")

    if not match_token(p, lexer.TOK_INDENT):
        return ast.Statement(kind = ast.STMT_VARIANT, name = name_tok.lexeme,
            stmt_type = type_void(), children = vec.Vec[ast.Statement].create(),
            line = name_tok.line, column = name_tok.column)

    skip_body(p)
    return ast.Statement(kind = ast.STMT_VARIANT, name = name_tok.lexeme,
        stmt_type = type_void(), children = vec.Vec[ast.Statement].create(),
        line = name_tok.line, column = name_tok.column)


function parse_opaque_decl(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected opaque name")
    let line = name_tok.line
    if check(p, lexer.TOK_NEWLINE):
        let _ = advance(p)
    return ast.Statement(kind = ast.STMT_OPAQUE, name = name_tok.lexeme,
        stmt_type = type_void(), children = vec.Vec[ast.Statement].create(),
        line = line, column = name_tok.column)


function parse_interface_decl(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected interface name")
    consume(p, lexer.TOK_COLON, "expected colon after interface name")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")

    if not match_token(p, lexer.TOK_INDENT):
        return ast.Statement(kind = ast.STMT_INTERFACE, name = name_tok.lexeme,
            stmt_type = type_void(), children = vec.Vec[ast.Statement].create(),
            line = name_tok.line, column = name_tok.column)

    skip_body(p)
    return ast.Statement(kind = ast.STMT_INTERFACE, name = name_tok.lexeme,
        stmt_type = type_void(), children = vec.Vec[ast.Statement].create(),
        line = name_tok.line, column = name_tok.column)


function parse_type_alias_decl(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected type alias name")
    consume(p, lexer.TOK_EQUAL, "expected = after type alias name")
    let t = parse_type_ref(p)
    consume(p, lexer.TOK_NEWLINE, "expected newline after type alias")
    return ast.Statement(kind = ast.STMT_TYPE_ALIAS, name = name_tok.lexeme,
        stmt_type = t, children = vec.Vec[ast.Statement].create(),
        line = name_tok.line, column = name_tok.column)


function parse_var_decl(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected var name")
    var t = type_void()
    var val_idx: ptr_uint = 0
    if match_token(p, lexer.TOK_COLON):
        t = parse_type_ref(p)
    if match_token(p, lexer.TOK_EQUAL):
        val_idx = parse_expr(p, pool)
    consume(p, lexer.TOK_NEWLINE, "expected newline after var")
    return ast.Statement(kind = ast.STMT_VAR, name = name_tok.lexeme,
        stmt_type = t, expr = int<-(val_idx), children = vec.Vec[ast.Statement].create(),
        line = name_tok.line, column = name_tok.column)


function parse_const_decl(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected const name")
    consume(p, lexer.TOK_COLON, "expected colon after const name")
    let t = parse_type_ref(p)
    var val_idx: ptr_uint = 0

    if match_token(p, lexer.TOK_EQUAL):
        val_idx = parse_expr(p, pool)

    consume(p, lexer.TOK_NEWLINE, "expected newline after const")
    return ast.Statement(kind = ast.STMT_CONST, name = name_tok.lexeme,
        stmt_type = t, expr2 = 0, op_kind = 0, is_inline = false, expr = int<-(val_idx),
        children = vec.Vec[ast.Statement].create(),
        line = name_tok.line, column = name_tok.column)


function parse_let_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected variable name")
    var t = type_void()
    var val_idx: ptr_uint = 0

    if match_token(p, lexer.TOK_COLON):
        t = parse_type_ref(p)
    if match_token(p, lexer.TOK_EQUAL):
        val_idx = parse_expr(p, pool)

    consume(p, lexer.TOK_NEWLINE, "expected newline after let")
    return ast.Statement(kind = ast.STMT_LET, name = name_tok.lexeme,
        stmt_type = t, expr2 = 0, op_kind = 0, is_inline = false, expr = int<-(val_idx),
        children = vec.Vec[ast.Statement].create(),
        line = name_tok.line, column = name_tok.column)


# ── type parsing ───────────────────────────────────────────────────────

function parse_params(p: ref[Parser]) -> vec.Vec[ast.Param]:
    var params = vec.Vec[ast.Param].create()
    consume(p, lexer.TOK_LPAREN, "expected '(' for parameter list")

    while not eof(p) and not check(p, lexer.TOK_RPAREN):
        let param_name = consume(p, lexer.TOK_IDENTIFIER, "expected parameter name")
        consume(p, lexer.TOK_COLON, "expected colon after parameter name")
        let param_type = parse_type_ref(p)
        params.push(ast.Param(name = param_name.lexeme, param_type = param_type))
        if not match_token(p, lexer.TOK_COMMA):
            break

    consume(p, lexer.TOK_RPAREN, "expected ')' after parameter list")
    return params


function parse_optional_return_type(p: ref[Parser]) -> ast.TypeRef:
    if match_token(p, lexer.TOK_ARROW):
        return parse_type_ref(p)
    return type_void()


function parse_type_ref(p: ref[Parser]) -> ast.TypeRef:
    var nullable = false

    if check(p, lexer.TOK_QUESTION):
        nullable = true
        let _ = advance(p)

    let first = consume_path_component(p, "expected type name")
    var parts = vec.Vec[str].create()
    parts.push(first.lexeme)

    while match_token(p, lexer.TOK_DOT):
        let part = consume_path_component(p, "expected identifier after '.'")
        parts.push(part.lexeme)

    var type_args = vec.Vec[ast.TypeRef].create()
    if match_token(p, lexer.TOK_LBRACKET):
        while not eof(p) and not check(p, lexer.TOK_RBRACKET):
            type_args.push(parse_type_ref(p))
            if not match_token(p, lexer.TOK_COMMA):
                break
        consume(p, lexer.TOK_RBRACKET, "expected ']' after type arguments")

    return ast.TypeRef(name_parts = parts, type_args = type_args,
        nullable = nullable, is_function_type = false)


# ── expressions ────────────────────────────────────────────────────────

function parse_expr(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ptr_uint:
    return parse_additive(p, pool)


function parse_additive(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ptr_uint:
    var left = parse_multiplicative(p, pool)
    while check(p, lexer.TOK_PLUS) or check(p, lexer.TOK_MINUS):
        let op_kind = peek(p).kind
        let _ = advance(p)
        let right = parse_multiplicative(p, pool)
        left = pool_push(pool, ast.Expression(kind = ast.EXPR_BINARY, int_value = 0,
            float_value = 0.0, str_value = "", bool_value = true, ident = "",
            op_kind = op_kind, lhs_idx = left, rhs_idx = right, callee_idx = 0,
            args = vec.Vec[ptr_uint].create(), line = previous(p).line, column = previous(p).column))
    return left


function parse_multiplicative(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ptr_uint:
    var left = parse_unary(p, pool)
    while check(p, lexer.TOK_STAR) or check(p, lexer.TOK_SLASH) or check(p, lexer.TOK_PERCENT):
        let op_kind = peek(p).kind
        let _ = advance(p)
        let right = parse_unary(p, pool)
        left = pool_push(pool, ast.Expression(kind = ast.EXPR_BINARY, int_value = 0,
            float_value = 0.0, str_value = "", bool_value = true, ident = "",
            op_kind = op_kind, lhs_idx = left, rhs_idx = right, callee_idx = 0,
            args = vec.Vec[ptr_uint].create(), line = previous(p).line, column = previous(p).column))
    return left


function parse_unary(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ptr_uint:
    let op = peek(p).kind
    if op == lexer.TOK_MINUS or op == lexer.TOK_KW_NOT:
        let _ = advance(p)
        let operand = parse_unary(p, pool)
        return pool_push(pool, ast.Expression(kind = ast.EXPR_UNARY, int_value = 0,
            float_value = 0.0, str_value = "", bool_value = true, ident = "",
            op_kind = op, lhs_idx = operand, rhs_idx = 0, callee_idx = 0,
            args = vec.Vec[ptr_uint].create(), line = previous(p).line, column = previous(p).column))
    return parse_postfix(p, pool)


function parse_postfix(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ptr_uint:
    var left = parse_primary(p, pool)

    while true:
        if check(p, lexer.TOK_DOT):
            let _ = advance(p)
            let member = consume(p, lexer.TOK_IDENTIFIER, "expected member name")
            left = pool_push(pool, ast.Expression(kind = ast.EXPR_MEMBER, int_value = 0,
                float_value = 0.0, str_value = member.lexeme, bool_value = true, ident = "",
                op_kind = 0, lhs_idx = left, rhs_idx = 0, callee_idx = 0,
                args = vec.Vec[ptr_uint].create(), line = previous(p).line, column = previous(p).column))
            continue

        if check(p, lexer.TOK_LPAREN):
            let _ = advance(p)
            var args = vec.Vec[ptr_uint].create()
            while not check(p, lexer.TOK_RPAREN) and not eof(p):
                args.push(parse_expr(p, pool))
                if not match_token(p, lexer.TOK_COMMA):
                    break
            consume(p, lexer.TOK_RPAREN, "expected ')'")
            left = pool_push(pool, ast.Expression(kind = ast.EXPR_CALL, int_value = 0,
                float_value = 0.0, str_value = "", bool_value = true, ident = "",
                op_kind = 0, lhs_idx = left, rhs_idx = 0, callee_idx = 0,
                args = args, line = previous(p).line, column = previous(p).column))
            continue

        break

    return left


function parse_primary(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ptr_uint:
    if check(p, lexer.TOK_INTEGER):
        let tok = advance(p)
        return pool_push(pool, ast.Expression(kind = ast.EXPR_INTEGER, int_value = 0,
            float_value = 0.0, str_value = tok.lexeme, bool_value = true, ident = "",
            op_kind = 0, lhs_idx = 0, rhs_idx = 0, callee_idx = 0,
            args = vec.Vec[ptr_uint].create(), line = tok.line, column = tok.column))
    if check(p, lexer.TOK_FLOAT):
        let tok = advance(p)
        return pool_push(pool, ast.Expression(kind = ast.EXPR_FLOAT, int_value = 0,
            float_value = 0.0, str_value = tok.lexeme, bool_value = true, ident = "",
            op_kind = 0, lhs_idx = 0, rhs_idx = 0, callee_idx = 0,
            args = vec.Vec[ptr_uint].create(), line = tok.line, column = tok.column))
    if check(p, lexer.TOK_STRING):
        let tok = advance(p)
        return pool_push(pool, ast.Expression(kind = ast.EXPR_STRING, int_value = 0,
            float_value = 0.0, str_value = tok.lexeme, bool_value = true, ident = "",
            op_kind = 0, lhs_idx = 0, rhs_idx = 0, callee_idx = 0,
            args = vec.Vec[ptr_uint].create(), line = tok.line, column = tok.column))
    if check(p, lexer.TOK_KW_TRUE):
        let tok = advance(p)
        return pool_push(pool, ast.Expression(kind = ast.EXPR_BOOLEAN, int_value = 0,
            float_value = 0.0, str_value = "", bool_value = true, ident = "",
            op_kind = 0, lhs_idx = 0, rhs_idx = 0, callee_idx = 0,
            args = vec.Vec[ptr_uint].create(), line = tok.line, column = tok.column))
    if check(p, lexer.TOK_KW_FALSE):
        let tok = advance(p)
        return pool_push(pool, ast.Expression(kind = ast.EXPR_BOOLEAN, int_value = 0,
            float_value = 0.0, str_value = "", bool_value = false, ident = "",
            op_kind = 0, lhs_idx = 0, rhs_idx = 0, callee_idx = 0,
            args = vec.Vec[ptr_uint].create(), line = tok.line, column = tok.column))
    if check(p, lexer.TOK_KW_NULL):
        let tok = advance(p)
        return pool_push(pool, ast.Expression(kind = ast.EXPR_NULL, int_value = 0,
            float_value = 0.0, str_value = "", bool_value = false, ident = "",
            op_kind = 0, lhs_idx = 0, rhs_idx = 0, callee_idx = 0,
            args = vec.Vec[ptr_uint].create(), line = tok.line, column = tok.column))
    if check(p, lexer.TOK_LPAREN):
        let _ = advance(p)
        let inner = parse_expr(p, pool)
        consume(p, lexer.TOK_RPAREN, "expected ')'")
        return inner
    if is_path_component_kind(peek(p).kind):
        let tok = advance(p)
        return pool_push(pool, ast.Expression(kind = ast.EXPR_IDENTIFIER, int_value = 0,
            float_value = 0.0, str_value = "", bool_value = true, ident = tok.lexeme,
            op_kind = 0, lhs_idx = 0, rhs_idx = 0, callee_idx = 0,
            args = vec.Vec[ptr_uint].create(), line = tok.line, column = tok.column))
    let tok = advance(p)
    return pool_push(pool, ast.Expression(kind = ast.EXPR_ERROR, int_value = 0,
        float_value = 0.0, str_value = "", bool_value = false, ident = "",
        op_kind = 0, lhs_idx = 0, rhs_idx = 0, callee_idx = 0,
        args = vec.Vec[ptr_uint].create(), line = tok.line, column = tok.column))



function pool_push(pool: ref[vec.Vec[ast.Expression]], expr: ast.Expression) -> ptr_uint:
    let idx = pool.len()
    pool.push(expr)
    return idx


# ── block parsing ──────────────────────────────────────────────────────

function parse_block(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> vec.Vec[ast.Statement]:
    var body = vec.Vec[ast.Statement].create()
    if not match_token(p, lexer.TOK_COLON):
        return body
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
    if not match_token(p, lexer.TOK_INDENT):
        return body
    return parse_block_body(p, pool)


function skip_body(p: ref[Parser]) -> void:
    var tick: int = 0
    while not eof(p) and not check(p, lexer.TOK_DEDENT):
        let _ = advance(p)
        tick += 1
        if tick >= 10000:
            break
    while check(p, lexer.TOK_DEDENT):
        let _ = advance(p)


function parse_statement(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    skip_newlines(p)
    if check(p, lexer.TOK_KW_RETURN):
        return parse_return_stmt(p, pool)
    if check(p, lexer.TOK_KW_LET):
        return parse_let_stmt(p, pool)
    if check(p, lexer.TOK_KW_IF):
        return parse_if_stmt(p, pool)
    if check(p, lexer.TOK_KW_WHILE):
        return parse_while_stmt(p, pool)
    if check(p, lexer.TOK_KW_FOR):
        return parse_for_stmt(p, pool)
    if check(p, lexer.TOK_KW_DEFER):
        return parse_defer_stmt(p, pool)
    return parse_assign_or_expr_stmt(p, pool)


function parse_if_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let tok = advance(p)
    let cond = parse_expr(p, pool)
    consume(p, lexer.TOK_COLON, "expected ':' after if condition")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
    consume(p, lexer.TOK_INDENT, "expected indent for if body")
    var body = parse_block_body(p, pool)
    var else_b = vec.Vec[ast.Statement].create()
    if match_token(p, lexer.TOK_KW_ELSE):
        consume(p, lexer.TOK_COLON, "expected ':' after else")
        if check(p, lexer.TOK_KW_IF):
            else_b.push(parse_if_stmt(p, pool))
        else:
            consume(p, lexer.TOK_NEWLINE, "expected newline after else colon")
            consume(p, lexer.TOK_INDENT, "expected indent for else body")
            else_b = parse_block_body(p, pool)
    return ast.Statement(kind = ast.STMT_IF, name = "", stmt_type = type_void(),
        expr = int<-(cond), children = body, else_body = else_b,
        line = tok.line, column = tok.column)


function parse_while_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let tok = advance(p)
    var is_inline = false
    if check(p, lexer.TOK_COLON):
        is_inline = true
    let cond = parse_expr(p, pool)
    consume(p, lexer.TOK_COLON, "expected ':' after while condition")
    var body = vec.Vec[ast.Statement].create()
    if is_inline:
        body.push(parse_statement(p, pool))
    else:
        consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
        consume(p, lexer.TOK_INDENT, "expected indent for while body")
        body = parse_block_body(p, pool)
    return ast.Statement(kind = ast.STMT_WHILE, name = "", stmt_type = type_void(),
        expr = int<-(cond), children = body, is_inline = is_inline,
        line = tok.line, column = tok.column)


function parse_for_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let tok = advance(p)
    var bindings = vec.Vec[str].create()
    bindings.push(consume(p, lexer.TOK_IDENTIFIER, "expected for variable").lexeme)
    while match_token(p, lexer.TOK_COMMA):
        bindings.push(consume(p, lexer.TOK_IDENTIFIER, "expected for variable").lexeme)
    consume(p, lexer.TOK_KW_IN, "expected 'in' after for bindings")
    var iterables = vec.Vec[ptr_uint].create()
    consume(p, lexer.TOK_LPAREN, "expected '(' for iterables")
    while not check(p, lexer.TOK_RPAREN) and not eof(p):
        iterables.push(parse_expr(p, pool))
        if not match_token(p, lexer.TOK_COMMA):
            break
    consume(p, lexer.TOK_RPAREN, "expected ')'")
    consume(p, lexer.TOK_COLON, "expected ':' after for")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
    consume(p, lexer.TOK_INDENT, "expected indent for for body")
    var body = parse_block_body(p, pool)
    return ast.Statement(kind = ast.STMT_FOR, name = "", stmt_type = type_void(),
        expr = 0, children = body, bindings = bindings,
        line = tok.line, column = tok.column)


function parse_defer_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let tok = advance(p)
    consume(p, lexer.TOK_COLON, "expected ':' after defer")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
    consume(p, lexer.TOK_INDENT, "expected indent for defer body")
    var body = parse_block_body(p, pool)
    return ast.Statement(kind = ast.STMT_DEFER, name = "", stmt_type = type_void(),
        expr = 0, children = body,
        line = tok.line, column = tok.column)


function parse_assign_or_expr_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let tok = peek(p)
    let lhs = parse_expr(p, pool)

    if check(p, lexer.TOK_EQUAL) or check(p, lexer.TOK_PLUS_EQUAL) or check(p, lexer.TOK_MINUS_EQUAL) or check(p, lexer.TOK_STAR_EQUAL) or check(p, lexer.TOK_SLASH_EQUAL):
        let op = peek(p).kind
        let _ = advance(p)
        let rhs = parse_expression_stmt_tail(p, pool, lhs, op, tok)
        return rhs

    consume(p, lexer.TOK_NEWLINE, "expected newline")
    return ast.Statement(kind = ast.STMT_EXPR, name = "", stmt_type = type_void(),
        expr = int<-(lhs), line = tok.line, column = tok.column)


function parse_expression_stmt_tail(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]],
                                    lhs_idx: ptr_uint, op_k: int, tok: lexer.Token) -> ast.Statement:
    let rhs = parse_expr(p, pool)
    consume(p, lexer.TOK_NEWLINE, "expected newline")
    return ast.Statement(kind = ast.STMT_ASSIGN, name = "", stmt_type = type_void(),
        expr = int<-(lhs_idx), expr2 = int<-(rhs), op_kind = op_k,
        line = tok.line, column = tok.column)


function parse_block_body(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> vec.Vec[ast.Statement]:
    var body = vec.Vec[ast.Statement].create()
    var limit: int = 0
    while not eof(p) and not check(p, lexer.TOK_DEDENT):
        body.push(parse_statement(p, pool))
        skip_newlines(p)
        limit += 1
        if limit >= 1000:
            break
    while check(p, lexer.TOK_DEDENT):
        let _ = advance(p)
    return body


function parse_return_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let tok = advance(p)
    var val_idx: ptr_uint = 0
    if not check(p, lexer.TOK_NEWLINE) and not check(p, lexer.TOK_DEDENT):
        val_idx = parse_expr(p, pool)
    consume(p, lexer.TOK_NEWLINE, "expected newline after return")
    return ast.Statement(kind = ast.STMT_RETURN, name = "", stmt_type = type_void(),
        expr = int<-(val_idx), line = tok.line, column = tok.column)


# ── known names pre-scan ───────────────────────────────────────────────

function seed_known_names(p: ref[Parser]) -> void:
    var known = unsafe: read(ptr[Parser]<-p).known_type_names
    var tokens_ref = unsafe: read(ptr[Parser]<-p).tokens

    var index: ptr_uint = 0
    while index < tokens_ref.len():
        let t_ptr = tokens_ref.get(index) else:
            break
        let tok = unsafe: read(ptr[lexer.Token]<-t_ptr)
        if tok.kind == lexer.TOK_KW_STRUCT or tok.kind == lexer.TOK_KW_FUNCTION:
            let next_idx = index + 1
            if next_idx < tokens_ref.len():
                let next_ptr = tokens_ref.get(next_idx) else:
                    break
                let next_tok = unsafe: read(ptr[lexer.Token]<-next_ptr)
                if next_tok.kind == lexer.TOK_IDENTIFIER:
                    var found = false
                    var ki: ptr_uint = 0
                    while ki < known.len():
                        let kp = known.get(ki) else:
                            break
                        if unsafe: read(ptr[str]<-kp).equal(next_tok.lexeme):
                            found = true
                            break
                        ki += 1
                    if not found:
                        known.push(next_tok.lexeme)
        index += 1