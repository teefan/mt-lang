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


# ── combinators ───────────────────────────────────────────────────────

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


# ── helpers ───────────────────────────────────────────────────────────

function type_void() -> ast.TypeRef:
    return ast.TypeRef(name_parts = vec.Vec[str].create(),
        type_args = vec.Vec[ast.TypeRef].create(), nullable = false, is_function_type = false)


# ── entry point ───────────────────────────────────────────────────────

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
        match decl:
            ast.Statement.empty:
                pass
            else:
                declarations.push(decl)
        skip_newlines(p)

    return ast.SourceFile(module_name = "", imports = imports,
        declarations = declarations,
        exprs = ast.ExpressionPool(exprs = vec.Vec[ast.Expression].create()))


# ── import ────────────────────────────────────────────────────────────

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


# ── declarations ──────────────────────────────────────────────────────

function parse_declaration(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    skip_newlines(p)
    if check(p, lexer.TOK_AT):
        let _ = advance(p)
        skip_to_newline(p)
        return ast.Statement.empty
    if check(p, lexer.TOK_KW_IMPORT):
        let _ = parse_import(p)
        return ast.Statement.empty
    if match_token(p, lexer.TOK_KW_PUBLIC):
        return parse_declaration(p, pool)  # recurse past public

    if match_token(p, lexer.TOK_KW_ASYNC):
        consume(p, lexer.TOK_KW_FUNCTION, "expected function after async")
        return parse_function_def(p, pool)
    if match_token(p, lexer.TOK_KW_CONST):
        if check(p, lexer.TOK_KW_FUNCTION):
            let _ = advance(p)
            return parse_function_def(p, pool)
        return parse_const_decl(p, pool)
    if match_token(p, lexer.TOK_KW_FUNCTION):
        return parse_function_def(p, pool)
    if match_token(p, lexer.TOK_KW_STRUCT):
        return parse_struct_decl(p)
    if match_token(p, lexer.TOK_KW_UNION):
        return parse_union_decl(p)
    if match_token(p, lexer.TOK_KW_ENUM):
        return parse_enum_decl(p, pool)
    if match_token(p, lexer.TOK_KW_FLAGS):
        return parse_enum_decl(p, pool)
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
    if match_token(p, lexer.TOK_KW_EXTENDING):
        return parse_extending_block(p)
    if match_token(p, lexer.TOK_KW_STATIC_ASSERT):
        return parse_static_assert_stmt(p, pool)
    if match_token(p, lexer.TOK_KW_ATTRIBUTE):
        return parse_attribute_decl(p)
    if match_token(p, lexer.TOK_KW_EVENT):
        return parse_event_decl(p)
    if match_token(p, lexer.TOK_KW_WHEN):
        return parse_when_decl(p, pool)
    if match_token(p, lexer.TOK_KW_EXTERNAL):
        return parse_extern_function_decl(p)

    let tok = peek(p)
    let _ = advance(p)
    return ast.Statement.empty


function parse_function_def(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected function name")
    var params = parse_params(p)
    let ret = parse_optional_return_type(p)
    var body = parse_block(p, pool)
    consume(p, lexer.TOK_NEWLINE, "expected newline after function body")

    return ast.Statement.function_decl(name = name_tok.lexeme, ret = ret, params = params, body = body)


function parse_struct_decl(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected struct name")
    consume(p, lexer.TOK_COLON, "expected colon after struct name")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")

    if not match_token(p, lexer.TOK_INDENT):
        return ast.Statement.struct_decl(name = name_tok.lexeme,
            fields = vec.Vec[ast.Statement].create())

    var fields = vec.Vec[ast.Statement].create()
    while not eof(p) and not check(p, lexer.TOK_DEDENT):
        skip_newlines(p)
        if check(p, lexer.TOK_DEDENT):
            break
        if check(p, lexer.TOK_KW_STRUCT):
            let _ = advance(p)
            let _ns = parse_struct_decl(p)
            skip_newlines(p)
            continue
        if check(p, lexer.TOK_AT):
            let _ = advance(p)
            skip_to_newline(p)
            continue
        if not check(p, lexer.TOK_IDENTIFIER):
            skip_to_newline(p)
            continue
        let fname = consume(p, lexer.TOK_IDENTIFIER, "expected field name")
        consume(p, lexer.TOK_COLON, "expected colon after field name")
        let ftype = parse_type_ref(p)
        consume(p, lexer.TOK_NEWLINE, "expected newline after field type")
        fields.push(ast.Statement.struct_field(name = fname.lexeme, ftype = ftype))
        skip_newlines(p)

    while check(p, lexer.TOK_DEDENT):
        let _ = advance(p)

    return ast.Statement.struct_decl(name = name_tok.lexeme, fields = fields)


function parse_const_decl(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected const name")
    consume(p, lexer.TOK_COLON, "expected colon after const name")
    let t = parse_type_ref(p)
    var val_idx: ptr_uint = 0
    if match_token(p, lexer.TOK_EQUAL):
        val_idx = parse_expr(p, pool)
    consume(p, lexer.TOK_NEWLINE, "expected newline after const")
    return ast.Statement.const_decl(name = name_tok.lexeme, ctype = t, value_idx = val_idx)


function parse_let_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let _ = advance(p)
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected variable name")
    var t = type_void()
    var val_idx: ptr_uint = 0
    if match_token(p, lexer.TOK_COLON):
        t = parse_type_ref(p)
    if match_token(p, lexer.TOK_EQUAL):
        val_idx = parse_expr(p, pool)
    consume(p, lexer.TOK_NEWLINE, "expected newline after let")
    return ast.Statement.let_decl(name = name_tok.lexeme, ltype = t, value_idx = val_idx)


# ── type parsing ──────────────────────────────────────────────────────

function parse_params(p: ref[Parser]) -> vec.Vec[ast.Param]:
    var params = vec.Vec[ast.Param].create()
    consume(p, lexer.TOK_LPAREN, "expected '(' for parameter list")
    while not eof(p) and not check(p, lexer.TOK_RPAREN):
        let pname = consume(p, lexer.TOK_IDENTIFIER, "expected parameter name")
        consume(p, lexer.TOK_COLON, "expected colon after parameter name")
        let ptype = parse_type_ref(p)
        params.push(ast.Param(name = pname.lexeme, param_type = ptype))
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

    if check(p, lexer.TOK_KW_FN) or check(p, lexer.TOK_KW_PROC):
        let _ = advance(p)
        parse_params(p)
        if match_token(p, lexer.TOK_ARROW):
            let _ = parse_type_ref(p)
        return ast.TypeRef(name_parts = vec.Vec[str].create(),
            type_args = vec.Vec[ast.TypeRef].create(), nullable = nullable, is_function_type = true)

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


function parse_enum_decl(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected enum name")
    consume(p, lexer.TOK_COLON, "expected colon after enum name")
    let bt = parse_type_ref(p)
    consume(p, lexer.TOK_NEWLINE, "expected newline after enum type")
    if not match_token(p, lexer.TOK_INDENT):
        return ast.Statement.enum_decl(name = name_tok.lexeme, backing = bt,
            members = vec.Vec[ast.Statement].create())
    var members = vec.Vec[ast.Statement].create()
    while not eof(p) and not check(p, lexer.TOK_DEDENT):
        skip_newlines(p)
        if check(p, lexer.TOK_DEDENT):
            break
        let mname = consume(p, lexer.TOK_IDENTIFIER, "expected enum member name")
        var mval: ptr_uint = 0
        if match_token(p, lexer.TOK_EQUAL):
            mval = parse_expr(p, pool)
        members.push(ast.Statement.const_decl(name = mname.lexeme,
            ctype = type_void(), value_idx = mval))
        consume(p, lexer.TOK_NEWLINE, "expected newline after enum member")
        skip_newlines(p)
    while check(p, lexer.TOK_DEDENT):
        let _ = advance(p)
    return ast.Statement.enum_decl(name = name_tok.lexeme, backing = bt, members = members)


function parse_variant_decl(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected variant name")
    consume(p, lexer.TOK_COLON, "expected colon after variant name")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
    if match_token(p, lexer.TOK_INDENT):
        skip_body(p)
    return ast.Statement.variant_decl(name = name_tok.lexeme)


function parse_opaque_decl(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected opaque name")
    if check(p, lexer.TOK_NEWLINE):
        let _ = advance(p)
    return ast.Statement.opaque_decl(name = name_tok.lexeme)


function parse_interface_decl(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected interface name")
    consume(p, lexer.TOK_COLON, "expected colon after interface name")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
    if match_token(p, lexer.TOK_INDENT):
        skip_body(p)
    return ast.Statement.interface_decl(name = name_tok.lexeme)


function parse_type_alias_decl(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected type alias name")
    consume(p, lexer.TOK_EQUAL, "expected = after type alias name")
    let t = parse_type_ref(p)
    consume(p, lexer.TOK_NEWLINE, "expected newline after type alias")
    return ast.Statement.type_alias_decl(name = name_tok.lexeme, target = t)


function parse_var_decl(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected var name")
    var t = type_void()
    var val_idx: ptr_uint = 0
    if match_token(p, lexer.TOK_COLON):
        t = parse_type_ref(p)
    if match_token(p, lexer.TOK_EQUAL):
        val_idx = parse_expr(p, pool)
    consume(p, lexer.TOK_NEWLINE, "expected newline after var")
    return ast.Statement.var_decl(name = name_tok.lexeme, vtype = t, value_idx = val_idx)


function parse_union_decl(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected union name")
    consume(p, lexer.TOK_COLON, "expected colon after union name")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
    if not match_token(p, lexer.TOK_INDENT):
        return ast.Statement.union_decl(name = name_tok.lexeme,
            fields = vec.Vec[ast.Statement].create())
    skip_body(p)
    return ast.Statement.union_decl(name = name_tok.lexeme,
        fields = vec.Vec[ast.Statement].create())


function parse_extending_block(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected type name after extending")
    consume(p, lexer.TOK_COLON, "expected colon after extending type")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
    if match_token(p, lexer.TOK_INDENT):
        skip_body(p)
    return ast.Statement.extending_block(name = name_tok.lexeme,
        methods = vec.Vec[ast.Statement].create())


function parse_static_assert_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    consume(p, lexer.TOK_LPAREN, "expected '(' after static_assert")
    let cond = parse_expr(p, pool)
    var msg = ""
    if match_token(p, lexer.TOK_COMMA):
        let msg_tok = consume(p, lexer.TOK_STRING, "expected string message")
        msg = msg_tok.lexeme
    consume(p, lexer.TOK_RPAREN, "expected ')'")
    consume(p, lexer.TOK_NEWLINE, "expected newline after static_assert")
    return ast.Statement.static_assert_stmt(cond_idx = cond, message = msg)


function parse_attribute_decl(p: ref[Parser]) -> ast.Statement:
    if check(p, lexer.TOK_LBRACKET):
        let _ = advance(p)
        while not check(p, lexer.TOK_RBRACKET) and not eof(p):
            let _ = advance(p)
        consume(p, lexer.TOK_RBRACKET, "expected ']'")
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected attribute name")
    if check(p, lexer.TOK_LPAREN):
        let _ = advance(p)
        while not check(p, lexer.TOK_RPAREN) and not eof(p):
            let _ = advance(p)
        consume(p, lexer.TOK_RPAREN, "expected ')'")
    consume(p, lexer.TOK_NEWLINE, "expected newline after attribute")
    return ast.Statement.attribute_decl(name = name_tok.lexeme,
        params = vec.Vec[ast.Statement].create())


function parse_event_decl(p: ref[Parser]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected event name")
    var capacity: ptr_uint = 0
    if check(p, lexer.TOK_LBRACKET):
        let _ = advance(p)
        if check(p, lexer.TOK_INTEGER):
            let cap_tok = advance(p)
            let _cap = cap_tok
        consume(p, lexer.TOK_RBRACKET, "expected ']'")
    if check(p, lexer.TOK_LPAREN):
        let _ = advance(p)
        while not check(p, lexer.TOK_RPAREN) and not eof(p):
            let _ = advance(p)
        consume(p, lexer.TOK_RPAREN, "expected ')'")
    consume(p, lexer.TOK_NEWLINE, "expected newline after event")
    return ast.Statement.event_decl(name = name_tok.lexeme, capacity = capacity)


function parse_when_decl(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected expression after when")
    if name_tok.kind != lexer.TOK_IDENTIFIER:
        let _ = parse_expr(p, pool)
    consume(p, lexer.TOK_COLON, "expected ':' after when")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
    if match_token(p, lexer.TOK_INDENT):
        skip_body(p)
    return ast.Statement.when_stmt(name = "", body = vec.Vec[ast.Statement].create())


function parse_extern_function_decl(p: ref[Parser]) -> ast.Statement:
    consume(p, lexer.TOK_KW_FUNCTION, "expected function after external")
    let name_tok = consume(p, lexer.TOK_IDENTIFIER, "expected function name")
    if check(p, lexer.TOK_LPAREN):
        parse_params(p)
    var ret = type_void()
    if match_token(p, lexer.TOK_ARROW):
        ret = parse_type_ref(p)
    consume(p, lexer.TOK_NEWLINE, "expected newline after extern function")
    return ast.Statement.extern_function_decl(name = name_tok.lexeme, ret = ret)


function skip_body_or_line(p: ref[Parser]) -> void:
    if check(p, lexer.TOK_COLON):
        consume(p, lexer.TOK_COLON, "expected ':'")
        consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
        if match_token(p, lexer.TOK_INDENT):
            skip_body(p)
    else:
        skip_to_newline(p)


# ── expressions ───────────────────────────────────────────────────────

function parse_expr(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ptr_uint:
    return parse_additive(p, pool)


function parse_additive(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ptr_uint:
    var left = parse_shift(p, pool)
    while check(p, lexer.TOK_PLUS) or check(p, lexer.TOK_MINUS) or check(p, lexer.TOK_DOT_DOT) or check(p, lexer.TOK_PIPE) or check(p, lexer.TOK_CARET) or check(p, lexer.TOK_AMP) or check(p, lexer.TOK_EQUAL_EQUAL) or check(p, lexer.TOK_BANG_EQUAL) or check(p, lexer.TOK_LESS) or check(p, lexer.TOK_GREATER) or check(p, lexer.TOK_LESS_EQUAL) or check(p, lexer.TOK_GREATER_EQUAL) or check(p, lexer.TOK_KW_AND) or check(p, lexer.TOK_KW_OR):
        let op_kind = peek(p).kind
        let _ = advance(p)
        let right = parse_shift(p, pool)
        left = pool_push(pool, ast.Expression(kind = ast.EXPR_BINARY, int_value = 0,
            float_value = 0.0, str_value = "", bool_value = true, ident = "",
            op_kind = op_kind, lhs_idx = left, rhs_idx = right, callee_idx = 0,
            args = vec.Vec[ptr_uint].create(), line = previous(p).line, column = previous(p).column))
    return left


function parse_shift(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ptr_uint:
    var left = parse_multiplicative(p, pool)
    while check(p, lexer.TOK_SHIFT_LEFT) or check(p, lexer.TOK_SHIFT_RIGHT):
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


# ── block parsing ─────────────────────────────────────────────────────

function parse_block(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> vec.Vec[ast.Statement]:
    var body = vec.Vec[ast.Statement].create()
    if not match_token(p, lexer.TOK_COLON):
        return body
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
    if not match_token(p, lexer.TOK_INDENT):
        return body
    return parse_block_body(p, pool)


function parse_block_body(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> vec.Vec[ast.Statement]:
    var body = vec.Vec[ast.Statement].create()
    var limit: int = 0
    while not eof(p) and not check(p, lexer.TOK_DEDENT):
        body.push(parse_statement(p, pool))
        skip_newlines(p)
        limit += 1
        if limit >= 500:
            break
    while check(p, lexer.TOK_DEDENT):
        let _ = advance(p)
    return body


function skip_body(p: ref[Parser]) -> void:
    var tick: int = 0
    while not eof(p) and not check(p, lexer.TOK_DEDENT):
        let _ = advance(p)
        tick += 1
        if tick >= 10000:
            break
    while check(p, lexer.TOK_DEDENT):
        let _ = advance(p)


# ── statements ────────────────────────────────────────────────────────

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
    if check(p, lexer.TOK_KW_WHEN):
        let _ = advance(p)
        skip_to_newline(p)
        return ast.Statement.empty
    if check(p, lexer.TOK_KW_MATCH):
        let _ = advance(p)
        skip_to_newline(p)
        return ast.Statement.empty
    if check(p, lexer.TOK_KW_UNSAFE):
        let _ = advance(p)
        skip_to_newline(p)
        return ast.Statement.empty
    if check(p, lexer.TOK_KW_PARALLEL):
        let _ = advance(p)
        skip_to_newline(p)
        return ast.Statement.empty
    if check(p, lexer.TOK_KW_GATHER):
        let _ = advance(p)
        skip_to_newline(p)
        return ast.Statement.empty
    if check(p, lexer.TOK_KW_STATIC_ASSERT):
        let _ = advance(p)
        skip_to_newline(p)
        return ast.Statement.empty
    if check(p, lexer.TOK_KW_EMIT):
        let _ = advance(p)
        skip_to_newline(p)
        return ast.Statement.empty
    return parse_assign_or_expr_stmt(p, pool)


function skip_to_newline(p: ref[Parser]) -> void:
    var limit: int = 0
    while not eof(p) and not check(p, lexer.TOK_NEWLINE):
        let _ = advance(p)
        limit += 1
        if limit >= 1000:
            break
    if check(p, lexer.TOK_NEWLINE):
        let _ = advance(p)


function parse_return_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let _ = advance(p)
    var val_idx: ptr_uint = 0
    if not check(p, lexer.TOK_NEWLINE) and not check(p, lexer.TOK_DEDENT):
        val_idx = parse_expr(p, pool)
    consume(p, lexer.TOK_NEWLINE, "expected newline after return")
    return ast.Statement.return_stmt(value_idx = val_idx)


function parse_if_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let _ = advance(p)
    let cond = parse_expr(p, pool)
    consume(p, lexer.TOK_COLON, "expected ':' after if condition")

    var body = vec.Vec[ast.Statement].create()
    var else_b = vec.Vec[ast.Statement].create()
    var is_inline = false

    if not check(p, lexer.TOK_NEWLINE):
        # inline if: `if cond : expr`
        is_inline = true
        body.push(parse_statement(p, pool))
    else:
        consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
        consume(p, lexer.TOK_INDENT, "expected indent for if body")
        body = parse_block_body(p, pool)

    if match_token(p, lexer.TOK_KW_ELSE):
        consume(p, lexer.TOK_COLON, "expected ':' after else")
        if check(p, lexer.TOK_KW_IF):
            else_b.push(parse_if_stmt(p, pool))
        else if not check(p, lexer.TOK_NEWLINE):
            else_b.push(parse_statement(p, pool))
        else:
            consume(p, lexer.TOK_NEWLINE, "expected newline after else colon")
            consume(p, lexer.TOK_INDENT, "expected indent for else body")
            else_b = parse_block_body(p, pool)

    if not is_inline:
        consume(p, lexer.TOK_NEWLINE, "expected newline after if")
    return ast.Statement.if_stmt(cond_idx = cond, body = body, else_body = else_b)


function parse_while_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let _ = advance(p)
    let cond = parse_expr(p, pool)
    consume(p, lexer.TOK_COLON, "expected ':' after while condition")
    var body = vec.Vec[ast.Statement].create()
    if not check(p, lexer.TOK_NEWLINE):
        body.push(parse_statement(p, pool))
    else:
        consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
        consume(p, lexer.TOK_INDENT, "expected indent for while body")
        body = parse_block_body(p, pool)
    return ast.Statement.while_stmt(cond_idx = cond, body = body)


function parse_for_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let _ = advance(p)
    let binding = consume(p, lexer.TOK_IDENTIFIER, "expected for variable").lexeme
    while match_token(p, lexer.TOK_COMMA):
        let _ = consume(p, lexer.TOK_IDENTIFIER, "expected for variable")
    consume(p, lexer.TOK_KW_IN, "expected 'in' after for bindings")

    var has_parens = check(p, lexer.TOK_LPAREN)
    if has_parens:
        let _ = advance(p)
    while not eof(p) and not check(p, lexer.TOK_COLON):
        if has_parens and check(p, lexer.TOK_RPAREN):
            break
        let _ = parse_expr(p, pool)
        if not match_token(p, lexer.TOK_COMMA):
            break
    if has_parens:
        consume(p, lexer.TOK_RPAREN, "expected ')'")

    consume(p, lexer.TOK_COLON, "expected ':' after for")
    var body = vec.Vec[ast.Statement].create()
    if not check(p, lexer.TOK_NEWLINE):
        body.push(parse_statement(p, pool))
    else:
        consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
        consume(p, lexer.TOK_INDENT, "expected indent for for body")
        body = parse_block_body(p, pool)
    return ast.Statement.for_stmt(binding = binding, body = body)


function parse_defer_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let _ = advance(p)
    consume(p, lexer.TOK_COLON, "expected ':' after defer")
    consume(p, lexer.TOK_NEWLINE, "expected newline after colon")
    consume(p, lexer.TOK_INDENT, "expected indent for defer body")
    var body = parse_block_body(p, pool)
    return ast.Statement.defer_stmt(body = body)


function parse_assign_or_expr_stmt(p: ref[Parser], pool: ref[vec.Vec[ast.Expression]]) -> ast.Statement:
    let lhs = parse_expr(p, pool)
    if check(p, lexer.TOK_EQUAL) or check(p, lexer.TOK_PLUS_EQUAL):
        let op = peek(p).kind
        let _ = advance(p)
        let rhs = parse_expr(p, pool)
        consume(p, lexer.TOK_NEWLINE, "expected newline")
        return ast.Statement.assign_stmt(target_idx = lhs, op_kind = op, value_idx = rhs)
    consume(p, lexer.TOK_NEWLINE, "expected newline")
    return ast.Statement.expr_stmt(value_idx = lhs)


# ── known names pre-scan ──────────────────────────────────────────────

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