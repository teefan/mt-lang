import mtc.ast as ast
import mtc.lexer as lexer
import std.vec as vec
import std.string as string


# =============================================================================
# Parse error
# =============================================================================

struct ParseError:
    message: string.String
    line: int
    column: int
    kind: lexer.TokenKind
    lexeme: string.String
    path: string.String


function make_error(token: lexer.Token, message: str, path: str) -> ParseError:
    return ParseError(
        message = string.String.from_str(message),
        line = token.line,
        column = token.column,
        kind = token.kind,
        lexeme = token.lexeme,
        path = string.String.from_str(path),
    )


# =============================================================================
# Parser state
# =============================================================================

struct Parser:
    tokens: ptr[lexer.Token]
    token_count: ptr_uint
    current: ptr_uint
    path: string.String
    errors: vec.Vec[ParseError]
    known_type_names: vec.Vec[string.String]
    known_import_aliases: vec.Vec[string.String]
    known_generic_callable_names: vec.Vec[string.String]
    current_type_param_names: vec.Vec[string.String]
    in_inline_block_body: bool
    loop_guard: int


const LOOP_GUARD_MAX: int = 50000


function loop_guard_check(p: ref[Parser]) -> void:
    p.loop_guard += 1
    if p.loop_guard > LOOP_GUARD_MAX:
        fatal(c"parser loop guard exceeded")


function reset_guard(p: ref[Parser]) -> void:
    p.loop_guard = 0


function add_error(p: ref[Parser], token: lexer.Token, message: str) -> void:
    let kind_str = lexer.kind_name(token.kind)
    let detail = f"#{message} (got #{kind_str} '#{token.lexeme.as_str()}' at #{token.line}:#{token.column})"
    p.errors.push(make_error(token, detail, p.path.as_str()))


function expr_to_vec(expr: ast.Expr) -> vec.Vec[ast.Expr]:
    var v = vec.Vec[ast.Expr].create()
    v.push(expr)
    return v


function stmt_to_vec(stmt: ast.Stmt) -> vec.Vec[ast.Stmt]:
    var v = vec.Vec[ast.Stmt].create()
    v.push(stmt)
    return v


# =============================================================================
# Token stream helpers
# =============================================================================

function parser_eof(p: ref[Parser]) -> bool:
    return p.current >= p.token_count


function parser_peek(p: ref[Parser]) -> lexer.Token:
    if parser_eof(p):
        # Return a sentinel EOF token
        return placeholder_token()
    return unsafe: read(p.tokens + p.current)


function placeholder_token() -> lexer.Token:
    return lexer.Token(
        kind = lexer.TokenKind.eof,
        line = 0,
        column = 0,
        lexeme = string.String.from_str(""),
    )


function parser_advance(p: ref[Parser]) -> lexer.Token:
    if not parser_eof(p):
        p.current += 1
    return parser_previous(p)


function parser_previous(p: ref[Parser]) -> lexer.Token:
    if p.current == 0:
        fatal(c"parser previous at start")
    return unsafe: read(p.tokens + p.current - 1)


function parser_check(p: ref[Parser], kind: lexer.TokenKind) -> bool:
    if parser_eof(p):
        return false
    return parser_peek(p).kind == kind


function parser_check_name(p: ref[Parser]) -> bool:
    if parser_eof(p):
        return false
    return parser_peek(p).kind == lexer.TokenKind.identifier


function parser_match(p: ref[Parser], kind: lexer.TokenKind) -> bool:
    if not parser_check(p, kind):
        return false
    let _ = parser_advance(p)
    return true


function parser_match_name(p: ref[Parser]) -> bool:
    if not parser_check_name(p):
        return false
    let _ = parser_advance(p)
    return true


function parser_consume(p: ref[Parser], kind: lexer.TokenKind, message: str) -> lexer.Token:
    if parser_check(p, kind):
        return parser_advance(p)
    let token = parser_peek(p)
    add_error(p, token, message)
    if not parser_eof(p):
        let _ = parser_advance(p)
    return token


function parser_consume_name(p: ref[Parser], message: str) -> lexer.Token:
    let token = parser_peek(p)
    if is_keyword_token(token):
        add_error(p, token, message)
        let _ = parser_advance(p)
        return token
    if parser_check(p, lexer.TokenKind.identifier):
        return parser_advance(p)
    add_error(p, token, message)
    let _ = parser_advance(p)
    return token


function parser_consume_name_allowing_keywords(p: ref[Parser], message: str) -> lexer.Token:
    if parser_check_name(p):
        return parser_advance(p)
    if is_keyword_token(parser_peek(p)):
        return parser_advance(p)
    add_error(p, parser_peek(p), message)
    return parser_peek(p)


function token_kind_is_keyword(kind: lexer.TokenKind) -> bool:
    return kind >= lexer.TokenKind.kw_align_of and kind <= lexer.TokenKind.kw_while


function is_keyword_token(token: lexer.Token) -> bool:
    return token_kind_is_keyword(token.kind)


# =============================================================================
# Newline / statement handling
# =============================================================================

function parser_skip_newlines(p: ref[Parser]) -> void:
    reset_guard(p)
    while parser_check(p, lexer.TokenKind.newline):
        let _ = parser_advance(p)
        loop_guard_check(p)


function parser_consume_end_of_statement(p: ref[Parser]) -> void:
    if p.in_inline_block_body:
        return
    let _ = parser_consume(p, lexer.TokenKind.newline, "expected end of statement")


# =============================================================================
# Qualified name parsing
# =============================================================================

function parse_qualified_name(p: ref[Parser]) -> ast.QualifiedName:
    let first_token = parser_consume_name(p, "expected identifier")
    var parts = vec.Vec[str].create()
    parts.push(first_token.lexeme.as_str())
    reset_guard(p)
    while parser_match(p, lexer.TokenKind.dot):
        let next_token = parser_consume_name_allowing_keywords(p, "expected identifier after '.'")
        parts.push(next_token.lexeme.as_str())
        loop_guard_check(p)
    return ast.QualifiedName(
        parts = parts,
        type_arguments = vec.Vec[ast.TypeArgument].create(),
        line = first_token.line,
        column = first_token.column,
    )


# =============================================================================
# Public API
# =============================================================================

public struct ParseResult:
    source_file: ast.SourceFile
    errors: vec.Vec[ParseError]
    error_count: int


public function parse(tokens: vec.Vec[lexer.Token]) -> ParseResult:
    let items_ptr = tokens.data else:
        return ParseResult(
            source_file = ast.SourceFile(
                module_name = Option[str].none,
                module_kind = ast.ModuleKind.kind_module,
                imports = vec.Vec[ast.Import].create(),
                directives = vec.Vec[ast.Decl].create(),
                declarations = vec.Vec[ast.Decl].create(),
                line = 0,
                node_ids = vec.Vec[int].create(),
                node_path_ids = vec.Vec[str].create(),
            ),
            errors = vec.Vec[ParseError].create(),
            error_count = 0,
        )
    var p = Parser(
        tokens = items_ptr,
        token_count = tokens.len(),
        current = 0,
        path = string.String.create(),
        errors = vec.Vec[ParseError].create(),
        known_type_names = vec.Vec[string.String].create(),
        known_import_aliases = vec.Vec[string.String].create(),
        known_generic_callable_names = vec.Vec[string.String].create(),
        current_type_param_names = vec.Vec[string.String].create(),
        in_inline_block_body = false,
        loop_guard = 0,
    )
    seed_known_names(ref_of(p))
    let source_file = parse_source_file(ref_of(p))
    return ParseResult(
        source_file = source_file,
        errors = p.errors,
        error_count = int<-(p.errors.len()),
    )


function parse_source_file(p: ref[Parser]) -> ast.SourceFile:
    parser_skip_newlines(p)

    var imports = vec.Vec[ast.Import].create()
    var directives = vec.Vec[ast.Decl].create()
    var declarations = vec.Vec[ast.Decl].create()

    reset_guard(p)
    while parser_match(p, lexer.TokenKind.kw_import):
        imports.push(parse_import(p))
        parser_skip_newlines(p)
        loop_guard_check(p)

    reset_guard(p)
    while not parser_eof(p):
        declarations.push(parse_declaration(p))
        parser_skip_newlines(p)
        loop_guard_check(p)

    return ast.SourceFile(
        module_name = Option[str].none,
        module_kind = ast.ModuleKind.kind_module,
        imports = imports,
        directives = directives,
        declarations = declarations,
        line = 0,
        node_ids = vec.Vec[int].create(),
        node_path_ids = vec.Vec[str].create(),
    )


function parse_import(p: ref[Parser]) -> ast.Import:
    let import_token = parser_previous(p)
    var path = parse_qualified_name(p)
    var alias_name = Option[str].none
    var local_name: str
    var local_column = import_token.column

    let last_ptr = path.parts.last() else:
        fatal(c"parse_import empty path")
    unsafe:
        let last = read(last_ptr)
        local_name = last

    if parser_match(p, lexer.TokenKind.kw_as):
        let alias_token = parser_consume_name(p, "expected import alias")
        alias_name = Option[str].some(value = alias_token.lexeme.as_str())
        local_name = alias_token.lexeme.as_str()
        local_column = alias_token.column

    parser_consume_end_of_statement(p)
    return ast.Import(
        path = path,
        alias_name = alias_name,
        line = import_token.line,
        column = local_column,
        length = int<-(local_name.len),
    )


# =============================================================================
# Attribute applications
# =============================================================================

function parse_attribute_applications(p: ref[Parser]) -> vec.Vec[ast.AttributeApplication]:
    var attrs = vec.Vec[ast.AttributeApplication].create()
    reset_guard(p)
    while parser_match(p, lexer.TokenKind.at):
        let _ = parser_consume(p, lexer.TokenKind.lbracket, "expected '[' after '@'")
        reset_guard(p)
        while not parser_check(p, lexer.TokenKind.rbracket) and not parser_eof(p):
            let attr_token = parser_consume_name(p, "expected attribute name")
            var args = vec.Vec[str].create()
            if parser_match(p, lexer.TokenKind.lparen):
                reset_guard(p)
                while not parser_check(p, lexer.TokenKind.rparen) and not parser_eof(p):
                    if parser_check(p, lexer.TokenKind.string_literal):
                        let str_token = parser_advance(p)
                        args.push(str_token.lexeme.as_str())
                    else if parser_check(p, lexer.TokenKind.integer_literal):
                        let int_token = parser_advance(p)
                        args.push(int_token.lexeme.as_str())
                    else:
                        let _ = parser_advance(p)
                    if not parser_match(p, lexer.TokenKind.comma):
                        break
                    loop_guard_check(p)
                let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after attribute arguments")
            attrs.push(ast.AttributeApplication(name = attr_token.lexeme.as_str(), arguments = args, line = attr_token.line, column = attr_token.column))
            if not parser_match(p, lexer.TokenKind.comma):
                break
            loop_guard_check(p)
        let _ = parser_consume(p, lexer.TokenKind.rbracket, "expected ']' after attributes")
        parser_skip_newlines(p)
        loop_guard_check(p)
    return attrs


# =============================================================================
# Declaration parser
# =============================================================================

function parse_declaration(p: ref[Parser]) -> ast.Decl:
    var attributes = parse_attribute_applications(p)
    if parser_match(p, lexer.TokenKind.kw_function):
        return parse_func_def(p, false, false)
    if parser_match(p, lexer.TokenKind.kw_const):
        if parser_match(p, lexer.TokenKind.kw_function):
            return parse_func_def(p, true, false)
        return parse_const_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_var):
        return parse_var_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_struct):
        return parse_struct_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_enum):
        return parse_enum_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_flags):
        return parse_flags_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_union):
        return parse_union_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_variant):
        return parse_variant_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_opaque):
        return parse_opaque_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_interface):
        return parse_interface_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_foreign):
        return parse_foreign_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_external):
        return parse_extern_decl(p)
    if parser_match(p, lexer.TokenKind.kw_type):
        return parse_type_alias_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_public):
        return parse_pub_decl(p)
    if parser_match(p, lexer.TokenKind.kw_static_assert):
        return parse_static_assert_decl(p)
    if parser_match(p, lexer.TokenKind.kw_attribute):
        return parse_attribute_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_event):
        return parse_event_decl(p, false)
    if parser_match(p, lexer.TokenKind.kw_extending):
        return parse_extending_block(p, false)
    if parser_match(p, lexer.TokenKind.kw_async):
        let _ = parser_consume(p, lexer.TokenKind.kw_function, "expected function after async")
        return parse_func_def(p, false, true)

    add_error(p, parser_peek(p), "expected declaration")
    if not parser_eof(p):
        let _ = parser_advance(p)
    return ast.Decl.error_decl(
        line = parser_peek(p).line,
        column = parser_peek(p).column,
        message = "expected declaration",
    )


# =============================================================================
# Function parsing
# =============================================================================

function parse_func_def(p: ref[Parser], is_const: bool, is_async: bool) -> ast.Decl:
    let name_token = parser_consume_name(p, "expected function name")

    var type_params = parse_declaration_type_params(p)
    var params: vec.Vec[ast.Param]
    var return_type = Option[ast.TypeRef].none
    var body = Option[vec.Vec[ast.Stmt]].none

    let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after function name")
    params = vec.Vec[ast.Param].create()
    if not parser_check(p, lexer.TokenKind.rparen):
        reset_guard(p)
        while true:
            let param_token = parser_consume_name(p, "expected parameter name")
            let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after parameter name")
            let param_type = parse_type_ref(p)
            params.push(ast.Param(
                name = param_token.lexeme.as_str(),
                param_type = param_type,
                line = param_token.line,
                column = param_token.column,
            ))
            if not parser_match(p, lexer.TokenKind.comma):
                break
            loop_guard_check(p)
    let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after parameters")

    if parser_match(p, lexer.TokenKind.arrow):
        return_type = Option[ast.TypeRef].some(value = parse_type_ref(p))

    if parser_match(p, lexer.TokenKind.colon):
        body = Option[vec.Vec[ast.Stmt]].some(value = parse_block_body(p))
    else:
        parser_consume_end_of_statement(p)

    return ast.Decl.function_def(node = ast.FunctionDef(
        name = name_token.lexeme.as_str(),
        type_params = type_params,
        params = params,
        return_type = return_type,
        body = body,
        is_public = false,
        is_async = is_async,
        is_const = is_const,
        attributes = vec.Vec[ast.AttributeApplication].create(),
        line = name_token.line,
        column = name_token.column,
    ))


# =============================================================================
# Generic type params & implements
# =============================================================================

function parse_declaration_type_params(p: ref[Parser]) -> vec.Vec[ast.TypeParam]:
    var params = vec.Vec[ast.TypeParam].create()
    if not parser_match(p, lexer.TokenKind.lbracket):
        return params

    while not parser_check(p, lexer.TokenKind.rbracket):
        let name_token = parser_consume_name(p, "expected type parameter name")
        var constraints = vec.Vec[ast.TypeParamConstraint].create()
        if parser_match(p, lexer.TokenKind.kw_implements):
            while true:
                var qn = parse_qualified_name(p)
                if parser_match(p, lexer.TokenKind.lbracket):
                    var targs = vec.Vec[ast.TypeArgument].create()
                    reset_guard(p)
                    while not parser_check(p, lexer.TokenKind.rbracket) and not parser_eof(p):
                        if parser_check_name(p) or is_keyword_token(parser_peek(p)):
                            let atok = parser_advance(p)
                            targs.push(ast.TypeArgument(value = atok.lexeme.as_str()))
                        else if parser_check(p, lexer.TokenKind.integer_literal):
                            let atok = parser_advance(p)
                            targs.push(ast.TypeArgument(value = atok.lexeme.as_str()))
                        else:
                            let _ = parser_advance(p)
                        if not parser_match(p, lexer.TokenKind.comma):
                            break
                        loop_guard_check(p)
                    let _ = parser_consume(p, lexer.TokenKind.rbracket, "expected ']' after constraint type args")
                constraints.push(ast.TypeParamConstraint(
                    constraint_kind = ast.TypeParamConstraintKind.kind_implements,
                    interface_ref = qn,
                ))
                if not parser_match(p, lexer.TokenKind.kw_and):
                    break
        params.push(ast.TypeParam(name = name_token.lexeme.as_str(), constraints = constraints, line = name_token.line, column = name_token.column, length = int<-(name_token.lexeme.as_str().len)))
        if not parser_match(p, lexer.TokenKind.comma):
            break

    let _ = parser_consume(p, lexer.TokenKind.rbracket, "expected ']' after type parameters")
    return params


function parse_implements_clause(p: ref[Parser]) -> vec.Vec[ast.QualifiedName]:
    var impls = vec.Vec[ast.QualifiedName].create()
    if not parser_match(p, lexer.TokenKind.kw_implements):
        return impls

    while true:
        var name = parse_qualified_name(p)
        if parser_match(p, lexer.TokenKind.lbracket):
            var type_args = vec.Vec[ast.TypeArgument].create()
            reset_guard(p)
            while not parser_check(p, lexer.TokenKind.rbracket) and not parser_eof(p):
                if parser_check_name(p) or is_keyword_token(parser_peek(p)):
                    let arg_token = parser_advance(p)
                    type_args.push(ast.TypeArgument(value = arg_token.lexeme.as_str()))
                else if parser_check(p, lexer.TokenKind.integer_literal):
                    let arg_token = parser_advance(p)
                    type_args.push(ast.TypeArgument(value = arg_token.lexeme.as_str()))
                else:
                    let _ = parser_advance(p)
                if not parser_match(p, lexer.TokenKind.comma):
                    break
                loop_guard_check(p)
            let _ = parser_consume(p, lexer.TokenKind.rbracket, "expected ']' after implements type arguments")
            name = ast.QualifiedName(parts = name.parts, type_arguments = type_args, line = 0, column = 0)
        impls.push(name)
        if not parser_match(p, lexer.TokenKind.comma):
            break
    return impls


function parse_primary_expr_name(p: ref[Parser]) -> str:
    let token = parser_consume_name(p, "expected name")
    return token.lexeme.as_str()


# =============================================================================
# Method parsing (for extending blocks)
# =============================================================================

function parse_method_def(p: ref[Parser], _is_public: bool) -> ast.MethodDef:
    var is_method_async = parser_match(p, lexer.TokenKind.kw_async)
    var method_kind = parse_method_kind(p)

    let _ = parser_consume(p, lexer.TokenKind.kw_function, "expected function declaration")
    let name_token = parser_consume_name(p, "expected function name")

    let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after function name")
    var params = vec.Vec[ast.Param].create()
    if not parser_check(p, lexer.TokenKind.rparen):
        reset_guard(p)
        while true:
            let param_token = parser_consume_name(p, "expected parameter name")
            let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after parameter name")
            let param_type = parse_type_ref(p)
            params.push(ast.Param(name = param_token.lexeme.as_str(), param_type = param_type, line = param_token.line, column = param_token.column))
            if not parser_match(p, lexer.TokenKind.comma):
                break
            loop_guard_check(p)
    let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after parameters")

    var return_type = Option[ast.TypeRef].none
    if parser_match(p, lexer.TokenKind.arrow):
        return_type = Option[ast.TypeRef].some(value = parse_type_ref(p))

    var body = Option[vec.Vec[ast.Stmt]].none
    if parser_match(p, lexer.TokenKind.colon):
        body = Option[vec.Vec[ast.Stmt]].some(value = parse_block_body(p))
    else:
        parser_consume_end_of_statement(p)

    return ast.MethodDef(
        name = name_token.lexeme.as_str(), type_params = vec.Vec[ast.TypeParam].create(),
        params = params, return_type = return_type, body = body,
        method_kind = method_kind, is_public = false, is_async = is_method_async,
        attributes = vec.Vec[ast.AttributeApplication].create(),
        line = name_token.line, column = name_token.column,
    )


# =============================================================================
# Block parsing
# =============================================================================

function parse_block_body(p: ref[Parser]) -> vec.Vec[ast.Stmt]:
    let _ = parser_consume(p, lexer.TokenKind.newline, "expected newline before block")
    let _ = parser_consume(p, lexer.TokenKind.indent, "expected indented block body")

    var statements = vec.Vec[ast.Stmt].create()
    parser_skip_newlines(p)
    reset_guard(p)
    while not parser_check(p, lexer.TokenKind.dedent) and not parser_eof(p):
        statements.push(parse_statement(p))
        parser_skip_newlines(p)
        loop_guard_check(p)

    let _ = parser_consume(p, lexer.TokenKind.dedent, "expected end of block")
    return statements


# =============================================================================
# Statement parsing
# =============================================================================

function parse_statement(p: ref[Parser]) -> ast.Stmt:
    if parser_match(p, lexer.TokenKind.kw_let):
        return parse_local_decl(p, "let")
    if parser_match(p, lexer.TokenKind.kw_var):
        return parse_local_decl(p, "var")
    if parser_match(p, lexer.TokenKind.kw_if):
        return parse_if_stmt(p)
    if parser_match(p, lexer.TokenKind.kw_match):
        return parse_match_stmt(p)
    if parser_match(p, lexer.TokenKind.kw_while):
        return parse_while_stmt(p)
    if parser_match(p, lexer.TokenKind.kw_for):
        return parse_for_stmt(p)
    if parser_match(p, lexer.TokenKind.kw_return):
        return parse_return_stmt(p)
    if parser_match(p, lexer.TokenKind.kw_defer):
        return parse_defer_stmt(p)
    if parser_match(p, lexer.TokenKind.kw_break):
        let token = parser_previous(p)
        parser_consume_end_of_statement(p)
        return ast.Stmt.break_stmt(node = ast.BreakStmt(line = token.line, column = token.column, length = 0))
    if parser_match(p, lexer.TokenKind.kw_continue):
        let token = parser_previous(p)
        parser_consume_end_of_statement(p)
        return ast.Stmt.continue_stmt(node = ast.ContinueStmt(line = token.line, column = token.column, length = 0))
    if parser_match(p, lexer.TokenKind.kw_pass):
        let token = parser_previous(p)
        parser_consume_end_of_statement(p)
        return ast.Stmt.pass_stmt(node = ast.PassStmt(line = token.line, column = token.column, length = 0))
    if parser_match(p, lexer.TokenKind.kw_unsafe):
        return parse_unsafe_stmt(p)
    return parse_expression_stmt(p)


# =============================================================================
# Declaration stubs with loop guards
# =============================================================================

function parse_pub_decl(p: ref[Parser]) -> ast.Decl:
    if parser_match(p, lexer.TokenKind.kw_function): return parse_func_def(p, false, false)
    if parser_match(p, lexer.TokenKind.kw_const): return parse_const_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_var): return parse_var_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_struct): return parse_struct_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_enum): return parse_enum_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_flags): return parse_flags_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_union): return parse_union_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_variant): return parse_variant_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_opaque): return parse_opaque_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_interface): return parse_interface_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_foreign): return parse_foreign_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_event): return parse_event_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_type): return parse_type_alias_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_attribute): return parse_attribute_decl(p, true)
    if parser_match(p, lexer.TokenKind.kw_extending): return parse_extending_block(p, true)
    add_error(p, parser_peek(p), "expected exportable declaration after public")
    return ast.Decl.error_decl(line = parser_peek(p).line, column = parser_peek(p).column, message = "expected declaration")


# =============================================================================
# Type parsing
# =============================================================================

function parse_type_ref(p: ref[Parser]) -> ast.TypeRef:
    # Handle fn(...) and proc(...) callable type literals
    if parser_match(p, lexer.TokenKind.kw_fn) or parser_match(p, lexer.TokenKind.kw_proc):
        let fn_token = parser_previous(p)
        let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after fn/proc")
        if not parser_check(p, lexer.TokenKind.rparen):
            reset_guard(p)
            while true:
                let _pn = parser_consume_name(p, "expected parameter name")
                let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after parameter name")
                let _pt = parse_type_ref(p)
                if not parser_match(p, lexer.TokenKind.comma):
                    break
                loop_guard_check(p)
        let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after fn/proc parameters")
        let _ = parser_consume(p, lexer.TokenKind.arrow, "expected '->' after fn/proc parameters")
        let ret = parse_type_ref(p)
        var parts = vec.Vec[str].create()
        parts.push(fn_token.lexeme.as_str())
        return ast.TypeRef(
            name = ast.QualifiedName(parts = parts, type_arguments = vec.Vec[ast.TypeArgument].create(), line = fn_token.line, column = fn_token.column),
            arguments = vec.Vec[ast.TypeArgument].create(), nullable = false,
            lifetime = Option[str].none, line = 0, column = 0, length = 0,
        )

    let qname = parse_qualified_name(p)

    # Handle function type: fn(params) -> ret or proc(params) -> ret
    let first_part_ptr = qname.parts.get(0) else:
        fatal(c"type ref empty parts")
    let first_part = unsafe: read(first_part_ptr)

    if (first_part == "fn" or first_part == "proc") and qname.parts.len() == 1:
        if parser_check(p, lexer.TokenKind.lparen):
            let _ = parser_advance(p)
            if not parser_check(p, lexer.TokenKind.rparen):
                reset_guard(p)
                while true:
                    let _param = parser_consume_name(p, "expected parameter name")
                    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after parameter name")
                    let _ = parse_type_ref(p)
                    if not parser_match(p, lexer.TokenKind.comma):
                        break
                    loop_guard_check(p)
            let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after function type parameters")
            let _ = parser_consume(p, lexer.TokenKind.arrow, "expected '->' after function type parameters")
            let _ret = parse_type_ref(p)

    var arguments = vec.Vec[ast.TypeArgument].create()
    var nullable = false
    if parser_match(p, lexer.TokenKind.lbracket):
        reset_guard(p)
        while not parser_check(p, lexer.TokenKind.rbracket) and not parser_eof(p):
            if parser_check_name(p) or is_keyword_token(parser_peek(p)):
                let arg_token = parser_advance(p)
                arguments.push(ast.TypeArgument(value = arg_token.lexeme.as_str()))
            else if parser_check(p, lexer.TokenKind.integer_literal) or parser_check(p, lexer.TokenKind.float_literal):
                let arg_token = parser_advance(p)
                arguments.push(ast.TypeArgument(value = arg_token.lexeme.as_str()))
            else:
                let _ = parser_advance(p)
            if not parser_match(p, lexer.TokenKind.comma):
                break
            loop_guard_check(p)
        let _ = parser_consume(p, lexer.TokenKind.rbracket, "expected ']' after type arguments")
    if parser_match(p, lexer.TokenKind.question):
        nullable = true
    return ast.TypeRef(
        name = qname, arguments = arguments, nullable = nullable,
        lifetime = Option[str].none, line = 0, column = 0, length = 0,
    )


# =============================================================================
# Statement implementations
# =============================================================================

function parse_local_decl(p: ref[Parser], decl_kind: str) -> ast.Stmt:
    let keyword_token = parser_previous(p)
    let name_token = parser_consume_name(p, "expected variable name")

    var decl_type_opt = Option[ast.TypeRef].none
    var has_type = false
    if parser_match(p, lexer.TokenKind.colon):
        decl_type_opt = Option[ast.TypeRef].some(value = parse_type_ref(p))
        has_type = true

    var value_opt = vec.Vec[ast.Expr].create()
    var else_binding = Option[str].none
    var else_body = Option[vec.Vec[ast.Stmt]].none

    if parser_match(p, lexer.TokenKind.equal):
        value_opt = expr_to_vec(parse_expression(p))
        if parser_match(p, lexer.TokenKind.kw_else):
            if parser_match(p, lexer.TokenKind.kw_as):
                let binding_token = parser_consume_name(p, "expected error binding name after 'as'")
                else_binding = Option[str].some(value = binding_token.lexeme.as_str())
            let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after else guard")
            else_body = Option[vec.Vec[ast.Stmt]].some(value = parse_block_body(p))
        else:
            parser_consume_end_of_statement(p)
    else if decl_kind == "let" and not has_type:
        let _ = parser_consume(p, lexer.TokenKind.equal, "expected '=' after let name")
    else:
        parser_consume_end_of_statement(p)

    return ast.Stmt.local_decl(node = ast.LocalDecl(
        decl_kind = decl_kind, name = name_token.lexeme.as_str(),
        decl_type = decl_type_opt, value = value_opt,
        else_binding = else_binding, else_body = else_body,
        line = keyword_token.line, column = keyword_token.column,
        recovered_else = false,
        destructure_bindings = Option[vec.Vec[ast.ForBinding]].none,
        destructure_type_name = Option[ast.QualifiedName].none,
    ))


function parse_if_stmt(p: ref[Parser]) -> ast.Stmt:
    let keyword_token = parser_previous(p)
    let condition = parse_expression(p)
    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after if condition")
    let body = parse_block_body(p)

    var branches = vec.Vec[ast.IfBranch].create()
    branches.push(ast.IfBranch(condition = expr_to_vec(condition), body = body, line = keyword_token.line, column = keyword_token.column, length = 0))
    var else_body = Option[vec.Vec[ast.Stmt]].none

    reset_guard(p)
    while parser_match(p, lexer.TokenKind.kw_else):
        if parser_match(p, lexer.TokenKind.kw_if):
            let else_cond = parse_expression(p)
            let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after else if condition")
            let else_block = parse_block_body(p)
            branches.push(ast.IfBranch(condition = expr_to_vec(else_cond), body = else_block, line = 0, column = 0, length = 0))
        else:
            let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after else")
            else_body = Option[vec.Vec[ast.Stmt]].some(value = parse_block_body(p))
            break
        loop_guard_check(p)

    return ast.Stmt.if_stmt(node = ast.IfStmt(
        branches = branches,
        else_body = else_body,
        is_inline = false,
        line = keyword_token.line,
        else_line = 0,
        else_column = 0,
    ))


function parse_match_stmt(p: ref[Parser]) -> ast.Stmt:
    let keyword_token = parser_previous(p)
    let expr = parse_expression(p)
    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after match expression")
    let _ = parser_consume(p, lexer.TokenKind.newline, "expected newline after match colon")
    let _ = parser_consume(p, lexer.TokenKind.indent, "expected indented match arms")

    var arms = vec.Vec[ast.MatchArm].create()
    parser_skip_newlines(p)
    reset_guard(p)
    while not parser_check(p, lexer.TokenKind.dedent) and not parser_eof(p):
        arms.push(parse_match_arm(p))
        parser_skip_newlines(p)
        loop_guard_check(p)

    let _ = parser_consume(p, lexer.TokenKind.dedent, "expected dedent after match arms")
    return ast.Stmt.match_stmt(node = ast.MatchStmt(
        expression = expr_to_vec(expr),
        arms = arms,
        is_inline = false,
        line = keyword_token.line,
        column = keyword_token.column,
        length = 0,
    ))


function parse_match_arm(p: ref[Parser]) -> ast.MatchArm:
    let pattern = parse_expression(p)
    var binding_name = Option[str].none
    var binding_line: int = 0
    var binding_column: int = 0

    if parser_match(p, lexer.TokenKind.kw_as):
        let binding_token = parser_consume_name(p, "expected binding name after as")
        binding_name = Option[str].some(value = binding_token.lexeme.as_str())
        binding_line = binding_token.line
        binding_column = binding_token.column

    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after match pattern")
    let body = parse_block_body(p)
    return ast.MatchArm(pattern = expr_to_vec(pattern), binding_name = binding_name, binding_line = binding_line, binding_column = binding_column, body = body)


function parse_while_stmt(p: ref[Parser]) -> ast.Stmt:
    let keyword_token = parser_previous(p)
    let cond = parse_expression(p)
    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after while condition")
    let body = parse_block_body(p)
    return ast.Stmt.while_stmt(node = ast.WhileStmt(condition = expr_to_vec(cond), body = body, is_inline = false, line = keyword_token.line, column = keyword_token.column, length = 0))


function parse_for_stmt(p: ref[Parser]) -> ast.Stmt:
    let keyword_token = parser_previous(p)
    var bindings = vec.Vec[ast.ForBinding].create()
    var iterables = vec.Vec[ast.Expr].create()

    let binding_token = parser_consume_name(p, "expected for binding name")
    bindings.push(ast.ForBinding(name = binding_token.lexeme.as_str(), line = binding_token.line, column = binding_token.column))

    if parser_match(p, lexer.TokenKind.kw_in):
        if parser_check(p, lexer.TokenKind.dot_dot):
            let _ = parser_advance(p)
            let end_expr = parse_expression(p)
            iterables.push(end_expr)
        else:
            iterables.push(parse_expression(p))
        let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after for header")
        let body = parse_block_body(p)
        return ast.Stmt.for_stmt(node = ast.ForStmt(
            bindings = bindings, iterables = iterables, body = body,
            is_inline = false, threaded = false, line = keyword_token.line, column = keyword_token.column,
        ))

    iterables.push(ast.Expr.error_expr(line = 0, column = 0, length = 0, message = Option[str].none))
    return ast.Stmt.for_stmt(node = ast.ForStmt(
        bindings = bindings, iterables = iterables, body = vec.Vec[ast.Stmt].create(),
        is_inline = false, threaded = false, line = keyword_token.line, column = keyword_token.column,
    ))


function parse_return_stmt(p: ref[Parser]) -> ast.Stmt:
    let keyword_token = parser_previous(p)
    var val = vec.Vec[ast.Expr].create()
    if not parser_check(p, lexer.TokenKind.newline):
        val = expr_to_vec(parse_expression(p))
    parser_consume_end_of_statement(p)
    return ast.Stmt.return_stmt(node = ast.ReturnStmt(value = val, line = keyword_token.line, column = keyword_token.column, length = 0))


function parse_defer_stmt(p: ref[Parser]) -> ast.Stmt:
    let keyword_token = parser_previous(p)
    var val = vec.Vec[ast.Expr].create()
    if not parser_check(p, lexer.TokenKind.newline):
        val = expr_to_vec(parse_expression(p))
    if parser_match(p, lexer.TokenKind.colon):
        let body = parse_block_body(p)
        return ast.Stmt.defer_stmt(node = ast.DeferStmt(expression = val, body = Option[vec.Vec[ast.Stmt]].some(value = body), line = keyword_token.line, column = keyword_token.column, length = 0))
    parser_consume_end_of_statement(p)
    return ast.Stmt.defer_stmt(node = ast.DeferStmt(expression = val, body = Option[vec.Vec[ast.Stmt]].none, line = keyword_token.line, column = keyword_token.column, length = 0))


function parse_unsafe_stmt(p: ref[Parser]) -> ast.Stmt:
    let keyword_token = parser_previous(p)
    if parser_match(p, lexer.TokenKind.colon):
        let body = parse_block_body(p)
        return ast.Stmt.unsafe_stmt(node = ast.UnsafeStmt(body = body, line = keyword_token.line, column = keyword_token.column, length = 0))
    let expr = parse_expression(p)
    parser_consume_end_of_statement(p)
    var b = vec.Vec[ast.Stmt].create()
    b.push(ast.Stmt.expression_stmt(node = ast.ExpressionStmt(expression = expr_to_vec(expr), line = keyword_token.line)))
    return ast.Stmt.unsafe_stmt(node = ast.UnsafeStmt(body = b, line = keyword_token.line, column = keyword_token.column, length = 0))


function parse_expression_stmt(p: ref[Parser]) -> ast.Stmt:
    let expr = parse_expression(p)
    if parser_match(p, lexer.TokenKind.equal) or parser_match(p, lexer.TokenKind.plus_equal) or parser_match(p, lexer.TokenKind.minus_equal) or parser_match(p, lexer.TokenKind.star_equal) or parser_match(p, lexer.TokenKind.slash_equal) or parser_match(p, lexer.TokenKind.percent_equal) or parser_match(p, lexer.TokenKind.amp_equal) or parser_match(p, lexer.TokenKind.pipe_equal) or parser_match(p, lexer.TokenKind.caret_equal) or parser_match(p, lexer.TokenKind.shift_left_equal) or parser_match(p, lexer.TokenKind.shift_right_equal):
        let op_token = parser_previous(p)
        let value = parse_expression(p)
        parser_consume_end_of_statement(p)
        return ast.Stmt.assignment(node = ast.Assignment(
            target = expr_to_vec(expr), assign_op = op_token.lexeme.as_str(),
            value = expr_to_vec(value), line = 0, column = 0,
        ))
    parser_consume_end_of_statement(p)
    return ast.Stmt.expression_stmt(node = ast.ExpressionStmt(expression = expr_to_vec(expr), line = 0))


# =============================================================================
# Expression parsing
# =============================================================================

function parse_expression(p: ref[Parser]) -> ast.Expr:
    if parser_match(p, lexer.TokenKind.kw_if):
        return parse_if_expression(p)
    if parser_match(p, lexer.TokenKind.kw_match):
        return parse_match_expression(p)
    if parser_match(p, lexer.TokenKind.kw_unsafe):
        return parse_unsafe_expression(p)
    return parse_range(p)


function parse_range(p: ref[Parser]) -> ast.Expr:
    let expr = parse_or(p)
    if parser_match(p, lexer.TokenKind.dot_dot):
        let end_expr = parse_or(p)
        return ast.Expr.range_expr(
            start_exprs = expr_to_vec(expr), end_exprs = expr_to_vec(end_expr),
            line = 0, column = 0,
        )
    return expr


function parse_if_expression(p: ref[Parser]) -> ast.Expr:
    let cond = parse_or(p)
    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after condition in if expression")
    let then_expr = parse_expression(p)
    let _ = parser_consume(p, lexer.TokenKind.kw_else, "expected 'else' in if expression")
    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after 'else' in if expression")
    let else_expr = parse_expression(p)
    return ast.Expr.if_expr(
        condition = expr_to_vec(cond), then_expr = expr_to_vec(then_expr),
        else_expr = expr_to_vec(else_expr),
    )


function parse_match_expression(p: ref[Parser]) -> ast.Expr:
    let token = parser_previous(p)
    let expr = parse_expression(p)
    let arms = parse_match_expression_arms(p)
    return ast.Expr.match_expr(
        expression = expr_to_vec(expr), arms = arms,
        line = token.line, column = token.column, length = 0,
    )


function parse_match_expression_arms(p: ref[Parser]) -> vec.Vec[ast.MatchExprArm]:
    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' before match expression arms")
    let _ = parser_consume(p, lexer.TokenKind.newline, "expected newline before match expression arms")
    let _ = parser_consume(p, lexer.TokenKind.indent, "expected indented match expression arms")

    var arms = vec.Vec[ast.MatchExprArm].create()
    parser_skip_newlines(p)
    reset_guard(p)
    while not parser_check(p, lexer.TokenKind.dedent) and not parser_eof(p):
        let new_arms = parse_match_expression_arm(p)
        var ai: ptr_uint = 0
        while ai < new_arms.len():
            let a_ptr = new_arms.get(ai) else:
                fatal(c"missing arm")
            unsafe:
                arms.push(read(a_ptr))
            ai += 1
        parser_skip_newlines(p)
        loop_guard_check(p)

    let _ = parser_consume(p, lexer.TokenKind.dedent, "expected end of match expression arms")
    return arms


function parse_match_expression_arm(p: ref[Parser]) -> vec.Vec[ast.MatchExprArm]:
    var patterns = vec.Vec[ast.Expr].create()
    if parser_match(p, lexer.TokenKind.kw_else):
        patterns.push(ast.Expr.identifier(name = "_", line = 0, column = 0))
    else:
        patterns.push(parse_bitwise_xor(p))
        while parser_match(p, lexer.TokenKind.pipe):
            patterns.push(parse_bitwise_xor(p))

    var binding_name = Option[str].none
    var binding_line: int = 0
    var binding_column: int = 0
    if parser_match(p, lexer.TokenKind.kw_as):
        let binding_token = parser_consume_name(p, "expected binding name after 'as'")
        binding_name = Option[str].some(value = binding_token.lexeme.as_str())
        binding_line = binding_token.line
        binding_column = binding_token.column

    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after match expression arm pattern")
    let value = parse_expression(p)

    var result = vec.Vec[ast.MatchExprArm].create()
    var pi: ptr_uint = 0
    while pi < patterns.len():
        let pat_ptr = patterns.get(pi) else:
            fatal(c"missing pattern")
        unsafe:
            result.push(ast.MatchExprArm(
                pattern = expr_to_vec(read(pat_ptr)),
                binding_name = binding_name, binding_line = binding_line,
                binding_column = binding_column, value = expr_to_vec(value),
            ))
        pi += 1
    return result


function parse_unsafe_expression(p: ref[Parser]) -> ast.Expr:
    let token = parser_previous(p)
    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after unsafe in expression")
    let expr = parse_expression(p)
    return ast.Expr.unsafe_expr(
        expression = expr_to_vec(expr),
        line = token.line, column = token.column, length = 0,
    )


function parse_or(p: ref[Parser]) -> ast.Expr:
    var expr = parse_and(p)
    while parser_match(p, lexer.TokenKind.kw_or):
        let op = parser_previous(p)
        let right = parse_and(p)
        expr = ast.Expr.binary_op(operator = op.lexeme.as_str(), left = expr_to_vec(expr), right = expr_to_vec(right))
    return expr


function parse_and(p: ref[Parser]) -> ast.Expr:
    var expr = parse_not(p)
    while parser_match(p, lexer.TokenKind.kw_and):
        let op = parser_previous(p)
        let right = parse_not(p)
        expr = ast.Expr.binary_op(operator = op.lexeme.as_str(), left = expr_to_vec(expr), right = expr_to_vec(right))
    return expr


function parse_not(p: ref[Parser]) -> ast.Expr:
    if parser_match(p, lexer.TokenKind.kw_not):
        let operand = parse_not(p)
        return ast.Expr.unary_op(operator = "not", operand = expr_to_vec(operand))
    return parse_is(p)


function parse_is(p: ref[Parser]) -> ast.Expr:
    let expr = parse_bitwise_or(p)
    while parser_match(p, lexer.TokenKind.kw_is):
        let _arm = parse_bitwise_or(p)
    return expr


function parse_bitwise_or(p: ref[Parser]) -> ast.Expr:
    var expr = parse_bitwise_xor(p)
    while parser_match(p, lexer.TokenKind.pipe):
        let op = parser_previous(p)
        let right = parse_bitwise_xor(p)
        expr = ast.Expr.binary_op(operator = op.lexeme.as_str(), left = expr_to_vec(expr), right = expr_to_vec(right))
    return expr


function parse_bitwise_xor(p: ref[Parser]) -> ast.Expr:
    var expr = parse_bitwise_and(p)
    while parser_match(p, lexer.TokenKind.caret):
        let op = parser_previous(p)
        let right = parse_bitwise_and(p)
        expr = ast.Expr.binary_op(operator = op.lexeme.as_str(), left = expr_to_vec(expr), right = expr_to_vec(right))
    return expr


function parse_bitwise_and(p: ref[Parser]) -> ast.Expr:
    var expr = parse_equality(p)
    while parser_match(p, lexer.TokenKind.amp):
        let op = parser_previous(p)
        let right = parse_equality(p)
        expr = ast.Expr.binary_op(operator = op.lexeme.as_str(), left = expr_to_vec(expr), right = expr_to_vec(right))
    return expr


function parse_equality(p: ref[Parser]) -> ast.Expr:
    var expr = parse_comparison(p)
    while parser_match(p, lexer.TokenKind.equal_equal) or parser_match(p, lexer.TokenKind.bang_equal):
        let op = parser_previous(p)
        let right = parse_comparison(p)
        expr = ast.Expr.binary_op(operator = op.lexeme.as_str(), left = expr_to_vec(expr), right = expr_to_vec(right))
    return expr


function parse_comparison(p: ref[Parser]) -> ast.Expr:
    var expr = parse_shift(p)
    while parser_match(p, lexer.TokenKind.less) or parser_match(p, lexer.TokenKind.less_equal) or parser_match(p, lexer.TokenKind.greater) or parser_match(p, lexer.TokenKind.greater_equal):
        let op = parser_previous(p)
        let right = parse_shift(p)
        expr = ast.Expr.binary_op(operator = op.lexeme.as_str(), left = expr_to_vec(expr), right = expr_to_vec(right))
    return expr


function parse_shift(p: ref[Parser]) -> ast.Expr:
    var expr = parse_additive(p)
    while parser_match(p, lexer.TokenKind.shift_left) or parser_match(p, lexer.TokenKind.shift_right):
        let op = parser_previous(p)
        let right = parse_additive(p)
        expr = ast.Expr.binary_op(operator = op.lexeme.as_str(), left = expr_to_vec(expr), right = expr_to_vec(right))
    return expr


function parse_additive(p: ref[Parser]) -> ast.Expr:
    var expr = parse_multiplicative(p)
    while parser_match(p, lexer.TokenKind.plus) or parser_match(p, lexer.TokenKind.minus):
        let op = parser_previous(p)
        let right = parse_multiplicative(p)
        expr = ast.Expr.binary_op(operator = op.lexeme.as_str(), left = expr_to_vec(expr), right = expr_to_vec(right))
    return expr


function parse_multiplicative(p: ref[Parser]) -> ast.Expr:
    var expr = parse_unary(p)
    while parser_match(p, lexer.TokenKind.star) or parser_match(p, lexer.TokenKind.slash) or parser_match(p, lexer.TokenKind.percent):
        let op = parser_previous(p)
        let right = parse_unary(p)
        expr = ast.Expr.binary_op(operator = op.lexeme.as_str(), left = expr_to_vec(expr), right = expr_to_vec(right))
    return expr


# =============================================================================
# Unary operators
# =============================================================================

function parse_unary(p: ref[Parser]) -> ast.Expr:
    if parser_match(p, lexer.TokenKind.kw_unsafe):
        return parse_unsafe_expression(p)
    if parser_match(p, lexer.TokenKind.kw_await):
        let expr = parse_unary(p)
        return ast.Expr.await_expr(expression = expr_to_vec(expr))
    if parser_match(p, lexer.TokenKind.kw_detach):
        let expr = parse_unary(p)
        return ast.Expr.detach_expr(body_exprs = expr_to_vec(expr), line = 0, column = 0)
    if parser_match(p, lexer.TokenKind.minus) or parser_match(p, lexer.TokenKind.plus) or parser_match(p, lexer.TokenKind.tilde) or parser_match(p, lexer.TokenKind.kw_out) or parser_match(p, lexer.TokenKind.kw_in) or parser_match(p, lexer.TokenKind.kw_inout):
        let op_token = parser_previous(p)
        let operand = parse_unary(p)
        return ast.Expr.unary_op(operator = op_token.lexeme.as_str(), operand = expr_to_vec(operand))
    return parse_postfix(p)


# =============================================================================
# Postfix expressions
# =============================================================================

function parse_postfix(p: ref[Parser]) -> ast.Expr:
    var expr = parse_primary(p)

    reset_guard(p)
    while true:
        if parser_match(p, lexer.TokenKind.dot):
            let member_token = parser_consume_name_allowing_keywords(p, "expected member name after '.'")
            expr = ast.Expr.member_access(
                receiver = expr_to_vec(expr), member = member_token.lexeme.as_str(),
                line = member_token.line, column = member_token.column,
            )
        else if parser_match(p, lexer.TokenKind.lparen):
            expr = ast.Expr.call(callee = expr_to_vec(expr), arguments = parse_call_arguments(p))
        else if parser_match(p, lexer.TokenKind.lbracket):
            let index = parse_expression(p)
            let _ = parser_consume(p, lexer.TokenKind.rbracket, "expected ']' after index expression")
            expr = ast.Expr.index_access(receiver = expr_to_vec(expr), index = expr_to_vec(index))
        else if parser_match(p, lexer.TokenKind.question):
            expr = ast.Expr.unary_op(operator = "?", operand = expr_to_vec(expr))
        else:
            break
        loop_guard_check(p)

    return expr


function parse_call_arguments(p: ref[Parser]) -> vec.Vec[ast.Argument]:
    var args = vec.Vec[ast.Argument].create()
    if parser_check(p, lexer.TokenKind.rparen):
        let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after call arguments")
        return args

    reset_guard(p)
    while true:
        if parser_check_name(p):
            let saved = p.current
            let name_token = parser_advance(p)
            if parser_match(p, lexer.TokenKind.equal):
                let value = parse_expression(p)
                args.push(ast.Argument(name = Option[str].some(value = name_token.lexeme.as_str()), value = expr_to_vec(value)))
            else:
                p.current = saved
                args.push(ast.Argument(name = Option[str].none, value = expr_to_vec(parse_expression(p))))
        else:
            args.push(ast.Argument(name = Option[str].none, value = expr_to_vec(parse_expression(p))))
        if not parser_match(p, lexer.TokenKind.comma):
            break
        if parser_check(p, lexer.TokenKind.rparen):
            break
        loop_guard_check(p)

    let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after call arguments")
    return args


# =============================================================================
# Primary expressions
# =============================================================================

function parse_primary(p: ref[Parser]) -> ast.Expr:
    if parser_match(p, lexer.TokenKind.kw_size_of):
        return parse_sizeof_expr(p)
    if parser_match(p, lexer.TokenKind.kw_align_of):
        return parse_alignof_expr(p)
    if parser_match(p, lexer.TokenKind.kw_offset_of):
        return parse_offsetof_expr(p)
    if parser_match(p, lexer.TokenKind.kw_fn):
        return parse_fn_type_as_expr(p)
    if parser_match(p, lexer.TokenKind.kw_proc):
        return parse_proc_expr(p)

    if parser_check_name(p):
        let token = parser_advance(p)
        return ast.Expr.identifier(name = token.lexeme.as_str(), line = token.line, column = token.column)

    if parser_check(p, lexer.TokenKind.integer_literal):
        let token = parser_advance(p)
        return ast.Expr.integer_literal(node = ast.IntegerLiteral(lexeme = token.lexeme.as_str(), value = 0))

    if parser_check(p, lexer.TokenKind.float_literal):
        let token = parser_advance(p)
        return ast.Expr.float_literal(node = ast.FloatLiteral(lexeme = token.lexeme.as_str(), value = 0.0))

    if parser_check(p, lexer.TokenKind.string_literal):
        let token = parser_advance(p)
        return ast.Expr.string_literal(node = ast.StringLiteral(lexeme = token.lexeme.as_str(), value = token.lexeme.as_str(), is_cstring = false))

    if parser_check(p, lexer.TokenKind.cstring_literal):
        let token = parser_advance(p)
        return ast.Expr.string_literal(node = ast.StringLiteral(lexeme = token.lexeme.as_str(), value = token.lexeme.as_str(), is_cstring = true))

    if parser_check(p, lexer.TokenKind.format_string_literal):
        let token = parser_advance(p)
        return ast.Expr.format_string(node = ast.FormatString(parts = vec.Vec[ast.FormatStringPart].create()))

    if parser_check(p, lexer.TokenKind.heredoc_literal):
        let token = parser_advance(p)
        return ast.Expr.string_literal(node = ast.StringLiteral(lexeme = token.lexeme.as_str(), value = token.lexeme.as_str(), is_cstring = false))

    if parser_check(p, lexer.TokenKind.character_literal):
        let token = parser_advance(p)
        return ast.Expr.char_literal(node = ast.CharLiteral(lexeme = token.lexeme.as_str(), value = 0, line = token.line, column = token.column))

    if parser_check(p, lexer.TokenKind.kw_true):
        let token = parser_advance(p)
        return ast.Expr.boolean_literal(node = ast.BooleanLiteral(value = true))

    if parser_check(p, lexer.TokenKind.kw_false):
        let token = parser_advance(p)
        return ast.Expr.boolean_literal(node = ast.BooleanLiteral(value = false))

    if parser_check(p, lexer.TokenKind.kw_null):
        let token = parser_advance(p)
        var null_type = ""
        if parser_match(p, lexer.TokenKind.lbracket):
            let nt = parse_type_ref(p)
            null_type = ""
            let _ = parser_consume(p, lexer.TokenKind.rbracket, "expected ']' after type in null literal")
        return ast.Expr.null_literal(node = ast.NullLiteral(null_type = null_type, line = token.line, column = token.column))

    if parser_check(p, lexer.TokenKind.lparen):
        let _ = parser_advance(p)
        let first = parse_expression(p)
        if parser_match(p, lexer.TokenKind.comma):
            var elements = vec.Vec[ast.Expr].create()
            elements.push(first)
            reset_guard(p)
            while true:
                elements.push(parse_expression(p))
                if not parser_match(p, lexer.TokenKind.comma):
                    break
                if parser_check(p, lexer.TokenKind.rparen):
                    break
                loop_guard_check(p)
            let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after tuple elements")
            return ast.Expr.expression_list(node = ast.ExpressionList(elements = elements, line = 0, column = 0))
        let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after expression")
        return first

    if is_keyword_token(parser_peek(p)):
        let token = parser_advance(p)
        return ast.Expr.identifier(name = token.lexeme.as_str(), line = token.line, column = token.column)

    add_error(p, parser_peek(p), "expected expression")
    if not parser_eof(p):
        let _ = parser_advance(p)
    return ast.Expr.error_expr(line = 0, column = 0, length = 1, message = Option[str].some(value = "expected expression"))


function parse_sizeof_expr(p: ref[Parser]) -> ast.Expr:
    let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after size_of")
    let t = parse_type_ref(p)
    let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after size_of type")
    return ast.Expr.sizeof_expr(target_type = t)


function parse_alignof_expr(p: ref[Parser]) -> ast.Expr:
    let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after align_of")
    let t = parse_type_ref(p)
    let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after align_of type")
    return ast.Expr.alignof_expr(target_type = t)


function parse_offsetof_expr(p: ref[Parser]) -> ast.Expr:
    let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after offset_of")
    let t = parse_type_ref(p)
    let _ = parser_consume(p, lexer.TokenKind.comma, "expected ',' after offset_of type")
    let field = parser_consume_name(p, "expected field name in offset_of")
    let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after offset_of field")
    return ast.Expr.offsetof_expr(target_type = t, field = field.lexeme.as_str())


function parse_fn_type_as_expr(p: ref[Parser]) -> ast.Expr:
    let token = parser_previous(p)
    return ast.Expr.identifier(name = "fn", line = token.line, column = token.column)


function parse_proc_expr(p: ref[Parser]) -> ast.Expr:
    let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after proc")
    var params = vec.Vec[ast.Param].create()
    if not parser_check(p, lexer.TokenKind.rparen):
        reset_guard(p)
        while true:
            let param_token = parser_consume_name(p, "expected parameter name")
            let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after parameter name")
            let param_type = parse_type_ref(p)
            params.push(ast.Param(name = param_token.lexeme.as_str(), param_type = param_type, line = param_token.line, column = param_token.column))
            if not parser_match(p, lexer.TokenKind.comma):
                break
            loop_guard_check(p)
    let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after proc parameters")
    let _ = parser_consume(p, lexer.TokenKind.arrow, "expected '->' after proc parameters")
    let return_type = parse_type_ref(p)
    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' before proc body")
    var body_expr: ast.Expr
    if parser_match(p, lexer.TokenKind.newline):
        let _ = parser_consume(p, lexer.TokenKind.indent, "expected indented block")
        # Read the block body as statements
        var stmts = vec.Vec[ast.Stmt].create()
        parser_skip_newlines(p)
        reset_guard(p)
        while not parser_check(p, lexer.TokenKind.dedent) and not parser_eof(p):
            stmts.push(parse_statement(p))
            parser_skip_newlines(p)
            loop_guard_check(p)
        let _ = parser_consume(p, lexer.TokenKind.dedent, "expected end of block")
        body_expr = ast.Expr.identifier(name = "", line = 0, column = 0)
    else:
        body_expr = parse_expression(p)

    return ast.Expr.proc_expr(
        params = params, return_type = Option[ast.TypeRef].some(value = return_type),
        body = expr_to_vec(body_expr),
    )


# =============================================================================
# Declaration: const, var, struct, enum, flags, union
# =============================================================================

function parse_const_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let name_token = parser_consume_name(p, "expected constant name")
    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after constant name")
    let const_type = parse_type_ref(p)
    let _ = parser_consume(p, lexer.TokenKind.equal, "expected '=' after constant type")
    let value = parse_expression(p)
    parser_consume_end_of_statement(p)
    return ast.Decl.const_decl(node = ast.ConstDecl(
        name = name_token.lexeme.as_str(), const_type = const_type, value = expr_to_vec(value),
        block_body = Option[vec.Vec[ast.Stmt]].none, is_public = is_public,
        attributes = vec.Vec[ast.AttributeApplication].create(), line = keyword_token.line, column = name_token.column,
    ))


function parse_var_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let name_token = parser_consume_name(p, "expected variable name")
    var var_type_opt = Option[ast.TypeRef].none
    var value_opt = vec.Vec[ast.Expr].create()
    if parser_match(p, lexer.TokenKind.colon):
        var_type_opt = Option[ast.TypeRef].some(value = parse_type_ref(p))
    if parser_match(p, lexer.TokenKind.equal):
        value_opt = expr_to_vec(parse_expression(p))
    parser_consume_end_of_statement(p)
    return ast.Decl.var_decl(node = ast.VarDecl(
        name = name_token.lexeme.as_str(), var_type = var_type_opt, value = value_opt,
        is_public = is_public, line = keyword_token.line, column = name_token.column,
    ))


function parse_struct_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let name_token = parser_consume_name(p, "expected struct name")
    let type_params = parse_declaration_type_params(p)
    let impl_list = parse_implements_clause(p)
    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after struct name")
    let _ = parser_consume(p, lexer.TokenKind.newline, "expected newline after struct header")
    let _ = parser_consume(p, lexer.TokenKind.indent, "expected indented struct body")

    var fields = vec.Vec[ast.Field].create()
    var nested_types = vec.Vec[ast.Decl].create()
    parser_skip_newlines(p)
    reset_guard(p)
    while not parser_check(p, lexer.TokenKind.dedent) and not parser_eof(p):
        if parser_check(p, lexer.TokenKind.kw_struct):
            let _ = parser_advance(p)
            nested_types.push(parse_struct_decl(p, false))
        else if parser_check(p, lexer.TokenKind.at):
            let _attr = parse_attribute_applications(p)
        else:
            let field_name_token = parser_consume_name(p, "expected field name")
            let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after field name")
            let field_type = parse_type_ref(p)
            parser_consume_end_of_statement(p)
            fields.push(ast.Field(
                name = field_name_token.lexeme.as_str(), field_type = field_type,
                attributes = vec.Vec[ast.AttributeApplication].create(),
                line = field_name_token.line, column = field_name_token.column,
            ))
        parser_skip_newlines(p)
        loop_guard_check(p)

    let _ = parser_consume(p, lexer.TokenKind.dedent, "expected end of struct body")
    return ast.Decl.struct_decl(node = ast.StructDecl(
        name = name_token.lexeme.as_str(), type_params = type_params,
        impl_list = impl_list, c_name = Option[str].none,
        fields = fields, events = vec.Vec[ast.EventDecl].create(),
        nested_types = nested_types,
        attributes = vec.Vec[ast.AttributeApplication].create(), packed = false, alignment = Option[int].none,
        is_public = is_public, lifetime_params = vec.Vec[str].create(),
        line = keyword_token.line, column = name_token.column,
    ))


function default_type_ref() -> ast.TypeRef:
    var parts = vec.Vec[str].create()
    return ast.TypeRef(
        name = ast.QualifiedName(parts = parts, type_arguments = vec.Vec[ast.TypeArgument].create(), line = 0, column = 0),
        arguments = vec.Vec[ast.TypeArgument].create(), nullable = false,
        lifetime = Option[str].none, line = 0, column = 0, length = 0,
    )


function parse_enum_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let name_token = parser_consume_name(p, "expected enum name")

    var backing_type = default_type_ref()
    if parser_match(p, lexer.TokenKind.colon):
        if parser_check_name(p) or is_keyword_token(parser_peek(p)):
            backing_type = parse_type_ref(p)

    let _ = parser_consume(p, lexer.TokenKind.newline, "expected newline after enum header")
    let _ = parser_consume(p, lexer.TokenKind.indent, "expected indented enum body")

    var members = vec.Vec[ast.EnumMember].create()
    var auto_value: int = 0
    parser_skip_newlines(p)
    reset_guard(p)
    while not parser_check(p, lexer.TokenKind.dedent) and not parser_eof(p):
        let member_token = parser_consume_name(p, "expected member name")
        var value: ast.Expr
        if parser_match(p, lexer.TokenKind.equal):
            value = parse_expression(p)
            auto_value = 1
        else:
            value = ast.Expr.integer_literal(node = ast.IntegerLiteral(lexeme = "", value = auto_value))
            auto_value += 1
        parser_consume_end_of_statement(p)
        members.push(ast.EnumMember(name = member_token.lexeme.as_str(), value = expr_to_vec(value), line = member_token.line, column = member_token.column))
        parser_skip_newlines(p)
        loop_guard_check(p)

    let _ = parser_consume(p, lexer.TokenKind.dedent, "expected end of enum body")
    return ast.Decl.enum_decl(node = ast.EnumDecl(
        name = name_token.lexeme.as_str(), backing_type = backing_type, members = members,
        is_public = is_public, attributes = vec.Vec[ast.AttributeApplication].create(),
        line = keyword_token.line, column = name_token.column,
    ))


function parse_flags_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let name_token = parser_consume_name(p, "expected flags name")

    var backing_type = default_type_ref()
    if parser_match(p, lexer.TokenKind.colon):
        if parser_check_name(p) or is_keyword_token(parser_peek(p)):
            backing_type = parse_type_ref(p)

    let _ = parser_consume(p, lexer.TokenKind.newline, "expected newline after flags header")
    let _ = parser_consume(p, lexer.TokenKind.indent, "expected indented flags body")

    var members = vec.Vec[ast.EnumMember].create()
    var auto_value: int = 0
    parser_skip_newlines(p)
    reset_guard(p)
    while not parser_check(p, lexer.TokenKind.dedent) and not parser_eof(p):
        let member_token = parser_consume_name(p, "expected member name")
        var value: ast.Expr
        if parser_match(p, lexer.TokenKind.equal):
            value = parse_expression(p)
        else:
            var shift: int = auto_value
            if auto_value <= 0:
                shift = auto_value
            value = ast.Expr.integer_literal(node = ast.IntegerLiteral(lexeme = "", value = 1 << shift))
            auto_value += 1
        parser_consume_end_of_statement(p)
        members.push(ast.EnumMember(name = member_token.lexeme.as_str(), value = expr_to_vec(value), line = member_token.line, column = member_token.column))
        parser_skip_newlines(p)
        loop_guard_check(p)

    let _ = parser_consume(p, lexer.TokenKind.dedent, "expected end of flags body")
    return ast.Decl.flags_decl(node = ast.FlagsDecl(
        name = name_token.lexeme.as_str(), backing_type = backing_type, members = members,
        is_public = is_public, attributes = vec.Vec[ast.AttributeApplication].create(),
        line = keyword_token.line, column = name_token.column,
    ))


function parse_union_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let name_token = parser_consume_name(p, "expected union name")
    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after union name")
    let _ = parser_consume(p, lexer.TokenKind.newline, "expected newline after union header")
    let _ = parser_consume(p, lexer.TokenKind.indent, "expected indented union body")

    var fields = vec.Vec[ast.Field].create()
    parser_skip_newlines(p)
    reset_guard(p)
    while not parser_check(p, lexer.TokenKind.dedent) and not parser_eof(p):
        let field_token = parser_consume_name(p, "expected field name")
        let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after field name")
        let field_type = parse_type_ref(p)
        parser_consume_end_of_statement(p)
        fields.push(ast.Field(name = field_token.lexeme.as_str(), field_type = field_type, attributes = vec.Vec[ast.AttributeApplication].create(), line = field_token.line, column = field_token.column))
        parser_skip_newlines(p)
        loop_guard_check(p)

    let _ = parser_consume(p, lexer.TokenKind.dedent, "expected end of union body")
    return ast.Decl.union_decl(node = ast.UnionDecl(
        name = name_token.lexeme.as_str(), c_name = Option[str].none, fields = fields,
        is_public = is_public, attributes = vec.Vec[ast.AttributeApplication].create(),
        line = keyword_token.line, column = name_token.column,
    ))


# =============================================================================
# Remaining declaration stubs
# =============================================================================

function parse_variant_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let name_token = parser_consume_name(p, "expected variant name")
    let type_params = parse_declaration_type_params(p)

    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after variant name")
    let _ = parser_consume(p, lexer.TokenKind.newline, "expected newline after variant header")
    let _ = parser_consume(p, lexer.TokenKind.indent, "expected indented variant body")

    var arms = vec.Vec[ast.VariantArm].create()
    parser_skip_newlines(p)
    reset_guard(p)
    while not parser_check(p, lexer.TokenKind.dedent) and not parser_eof(p):
        let arm_token = parser_consume_name(p, "expected variant arm name")
        var fields = vec.Vec[ast.Field].create()
        if parser_match(p, lexer.TokenKind.lparen):
            reset_guard(p)
            while not parser_check(p, lexer.TokenKind.rparen) and not parser_eof(p):
                let field_token = parser_consume_name(p, "expected field name")
                let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after field name")
                let field_type = parse_type_ref(p)
                fields.push(ast.Field(name = field_token.lexeme.as_str(), field_type = field_type, attributes = vec.Vec[ast.AttributeApplication].create(), line = field_token.line, column = field_token.column))
                if not parser_match(p, lexer.TokenKind.comma):
                    break
                loop_guard_check(p)
            let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after variant arm fields")
        parser_consume_end_of_statement(p)
        arms.push(ast.VariantArm(name = arm_token.lexeme.as_str(), fields = fields))
        parser_skip_newlines(p)
        loop_guard_check(p)

    let _ = parser_consume(p, lexer.TokenKind.dedent, "expected end of variant body")
    return ast.Decl.variant_decl(node = ast.VariantDecl(
        name = name_token.lexeme.as_str(), type_params = type_params, arms = arms,
        is_public = is_public, attributes = vec.Vec[ast.AttributeApplication].create(),
        line = keyword_token.line, column = name_token.column,
    ))


function parse_opaque_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let name_token = parser_consume_name(p, "expected opaque type name")
    let type_params = parse_declaration_type_params(p)
    let impl_list = parse_implements_clause(p)
    var c_name = Option[str].none
    if parser_match(p, lexer.TokenKind.equal):
        let c_token = parser_consume(p, lexer.TokenKind.cstring_literal, "expected C string literal after '='")
        c_name = Option[str].some(value = c_token.lexeme.as_str())
    parser_consume_end_of_statement(p)
    return ast.Decl.opaque_decl(node = ast.OpaqueDecl(
        name = name_token.lexeme.as_str(), impl_list = impl_list, c_name = c_name,
        is_public = is_public, line = keyword_token.line, column = name_token.column,
    ))


function parse_interface_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let name_token = parser_consume_name(p, "expected interface name")
    let type_params = parse_declaration_type_params(p)

    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after interface name")
    let _ = parser_consume(p, lexer.TokenKind.newline, "expected newline after interface header")
    let _ = parser_consume(p, lexer.TokenKind.indent, "expected indented interface body")

    var methods = vec.Vec[ast.InterfaceMethodDecl].create()
    parser_skip_newlines(p)
    reset_guard(p)
    while not parser_check(p, lexer.TokenKind.dedent) and not parser_eof(p):
        methods.push(parse_interface_method(p))
        parser_skip_newlines(p)
        loop_guard_check(p)

    let _ = parser_consume(p, lexer.TokenKind.dedent, "expected end of interface body")
    return ast.Decl.interface_decl(node = ast.InterfaceDecl(
        name = name_token.lexeme.as_str(), type_params = type_params, methods = methods,
        is_public = is_public, line = keyword_token.line, column = name_token.column,
    ))


function parse_interface_method(p: ref[Parser]) -> ast.InterfaceMethodDecl:
    var is_method_async = parser_match(p, lexer.TokenKind.kw_async)
    var method_kind = parse_method_kind(p)

    if not parser_match(p, lexer.TokenKind.kw_function):
        let _ = parser_consume(p, lexer.TokenKind.kw_function, "expected function in interface method")

    let name_token = parser_consume_name(p, "expected function name")

    let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after function name")
    var params = vec.Vec[ast.Param].create()
    if not parser_check(p, lexer.TokenKind.rparen):
        reset_guard(p)
        while true:
            let param_token = parser_consume_name(p, "expected parameter name")
            let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after parameter name")
            let param_type = parse_type_ref(p)
            params.push(ast.Param(name = param_token.lexeme.as_str(), param_type = param_type, line = param_token.line, column = param_token.column))
            if not parser_match(p, lexer.TokenKind.comma):
                break
            loop_guard_check(p)
    let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after parameters")

    var return_type: ast.TypeRef
    if parser_match(p, lexer.TokenKind.arrow):
        return_type = parse_type_ref(p)
    else:
        return_type = default_type_ref()

    parser_consume_end_of_statement(p)
    return ast.InterfaceMethodDecl(
        name = name_token.lexeme.as_str(), params = params, return_type = return_type,
        method_kind = method_kind, is_async = is_method_async,
        attributes = vec.Vec[ast.AttributeApplication].create(),
        line = name_token.line, column = name_token.column,
    )

    parser_consume_end_of_statement(p)
    return ast.InterfaceMethodDecl(
        name = name_token.lexeme.as_str(), params = params, return_type = return_type,
        method_kind = method_kind, is_async = is_method_async,
        attributes = vec.Vec[ast.AttributeApplication].create(),
        line = name_token.line, column = name_token.column,
    )


function parse_method_kind(p: ref[Parser]) -> str:
    if parser_match(p, lexer.TokenKind.kw_editable):
        return "editable"
    if parser_match(p, lexer.TokenKind.kw_static):
        return "static"
    return "plain"


function parse_foreign_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let _ = parser_consume(p, lexer.TokenKind.kw_function, "expected function after foreign")
    let name_token = parser_consume_name(p, "expected function name")

    let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after function name")
    var params = vec.Vec[ast.ForeignParam].create()
    var variadic = false
    if not parser_check(p, lexer.TokenKind.rparen):
        reset_guard(p)
        while true:
            if parser_match(p, lexer.TokenKind.ellipsis):
                variadic = true
                break
            let param_token = parser_consume_name(p, "expected parameter name")
            var mode_str = Option[str].none
            var boundary = Option[str].none
            if pmatch_foreign_mode(p):
                mode_str = Option[str].some(value = parser_previous(p).lexeme.as_str())
            else if parser_match(p, lexer.TokenKind.colon):
                pass
            let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after parameter name")
            let param_type = parse_type_ref(p)
            if parser_match(p, lexer.TokenKind.kw_as):
                boundary = Option[str].some(value = parse_primary_expr_name(p))
                let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after boundary type")
                let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after boundary type")
            params.push(ast.ForeignParam(name = param_token.lexeme.as_str(), foreign_type = param_type, mode = mode_str, boundary_type = boundary))
            if not parser_match(p, lexer.TokenKind.comma):
                break
            loop_guard_check(p)
    let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after parameters")

    let _ = parser_consume(p, lexer.TokenKind.arrow, "expected '->' before foreign function return type")
    let return_type = parse_type_ref(p)
    let _ = parser_consume(p, lexer.TokenKind.equal, "expected '=' before foreign function mapping")
    let mapping = parse_expression(p)
    parser_consume_end_of_statement(p)
    return ast.Decl.foreign_function_decl(node = ast.ForeignFunctionDecl(
        name = name_token.lexeme.as_str(), type_params = vec.Vec[ast.TypeParam].create(),
        params = params, return_type = return_type, variadic = variadic, mapping = expr_to_vec(mapping),
        is_public = is_public, attributes = vec.Vec[ast.AttributeApplication].create(),
        line = keyword_token.line,
    ))


function pmatch_foreign_mode(p: ref[Parser]) -> bool:
    return parser_match(p, lexer.TokenKind.kw_out) or parser_match(p, lexer.TokenKind.kw_in) or parser_match(p, lexer.TokenKind.kw_inout) or parser_match(p, lexer.TokenKind.kw_consuming)


function parse_extern_decl(p: ref[Parser]) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let _ = parser_consume(p, lexer.TokenKind.kw_function, "expected function after external")
    let name_token = parser_consume_name(p, "expected function name")

    let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after function name")
    var params = vec.Vec[ast.ForeignParam].create()
    var variadic = false
    if not parser_check(p, lexer.TokenKind.rparen):
        reset_guard(p)
        while true:
            if parser_match(p, lexer.TokenKind.ellipsis):
                variadic = true
                break
            let param_token = parser_consume_name(p, "expected parameter name")
            let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after parameter name")
            let param_type = parse_type_ref(p)
            params.push(ast.ForeignParam(name = param_token.lexeme.as_str(), foreign_type = param_type, mode = Option[str].none, boundary_type = Option[str].none))
            if not parser_match(p, lexer.TokenKind.comma):
                break
            loop_guard_check(p)
    let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after parameters")

    let _ = parser_consume(p, lexer.TokenKind.arrow, "expected '->' before external function return type")
    let return_type = parse_type_ref(p)
    var mapping = vec.Vec[ast.Expr].create()
    if parser_match(p, lexer.TokenKind.equal):
        mapping = expr_to_vec(parse_expression(p))
    parser_consume_end_of_statement(p)
    return ast.Decl.extern_function_decl(node = ast.ExternFunctionDecl(
        name = name_token.lexeme.as_str(), type_params = vec.Vec[ast.TypeParam].create(),
        params = params, return_type = return_type, variadic = variadic,
        attributes = vec.Vec[ast.AttributeApplication].create(),
        line = keyword_token.line, mapping = mapping,
    ))


function parse_type_alias_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let name_token = parser_consume_name(p, "expected type alias name")
    let _ = parser_consume(p, lexer.TokenKind.equal, "expected '=' after type alias name")
    let target = parse_type_ref(p)
    parser_consume_end_of_statement(p)
    return ast.Decl.type_alias_decl(node = ast.TypeAliasDecl(
        name = name_token.lexeme.as_str(), target = target,
        is_public = is_public, line = keyword_token.line, column = name_token.column,
    ))


function parse_attribute_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let _ = parser_consume(p, lexer.TokenKind.lbracket, "expected '[' after attribute")
    var targets = vec.Vec[str].create()
    reset_guard(p)
    while not parser_check(p, lexer.TokenKind.rbracket):
        let target_token = parser_consume_name_allowing_keywords(p, "expected attribute target")
        targets.push(target_token.lexeme.as_str())
        if not parser_match(p, lexer.TokenKind.comma):
            break
        loop_guard_check(p)
    let _ = parser_consume(p, lexer.TokenKind.rbracket, "expected ']' after attribute targets")
    let name_token = parser_consume_name_allowing_keywords(p, "expected attribute name")
    let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after attribute name")
    var attr_params = vec.Vec[ast.Param].create()
    if not parser_check(p, lexer.TokenKind.rparen):
        reset_guard(p)
        while true:
            let param_token = parser_consume_name(p, "expected parameter name")
            let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after parameter name")
            let param_type = parse_type_ref(p)
            attr_params.push(ast.Param(name = param_token.lexeme.as_str(), param_type = param_type, line = param_token.line, column = param_token.column))
            if not parser_match(p, lexer.TokenKind.comma):
                break
            loop_guard_check(p)
    let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after attribute parameters")
    parser_consume_end_of_statement(p)
    return ast.Decl.attribute_decl(node = ast.AttributeDecl(
        name = name_token.lexeme.as_str(), targets = targets, params = attr_params,
        is_public = is_public, line = keyword_token.line, column = name_token.column,
    ))


function parse_event_decl(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let name_token = parser_consume_name(p, "expected event name")
    let _ = parser_consume(p, lexer.TokenKind.lbracket, "expected '[' after event name")
    let capacity_token = parser_consume(p, lexer.TokenKind.integer_literal, "expected positive integer capacity")
    let _ = parser_consume(p, lexer.TokenKind.rbracket, "expected ']' after event capacity")
    var payload_type = Option[ast.TypeRef].none
    if parser_match(p, lexer.TokenKind.lparen):
        payload_type = Option[ast.TypeRef].some(value = parse_type_ref(p))
        let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after event payload type")
    parser_consume_end_of_statement(p)
    return ast.Decl.event_decl(node = ast.EventDecl(
        name = name_token.lexeme.as_str(), capacity = 0,
        payload_type = payload_type, is_public = is_public,
        attributes = vec.Vec[ast.AttributeApplication].create(),
        line = keyword_token.line, column = name_token.column,
    ))


function parse_extending_block(p: ref[Parser], is_public: bool) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let type_name = parse_type_ref(p)

    let _ = parser_consume(p, lexer.TokenKind.colon, "expected ':' after extending type name")
    let _ = parser_consume(p, lexer.TokenKind.newline, "expected newline after extending header")
    let _ = parser_consume(p, lexer.TokenKind.indent, "expected indented extending body")

    var methods = vec.Vec[ast.MethodDef].create()
    parser_skip_newlines(p)
    reset_guard(p)
    while not parser_check(p, lexer.TokenKind.dedent) and not parser_eof(p):
        methods.push(parse_method_def(p, false))
        parser_skip_newlines(p)
        loop_guard_check(p)

    let _ = parser_consume(p, lexer.TokenKind.dedent, "expected end of extending body")
    return ast.Decl.extending_block(node = ast.ExtendingBlock(
        type_name = type_name, methods = methods,
        line = keyword_token.line, column = type_name.column,
    ))


function parse_static_assert_decl(p: ref[Parser]) -> ast.Decl:
    let keyword_token = parser_previous(p)
    let _ = parser_consume(p, lexer.TokenKind.lparen, "expected '(' after static_assert")
    let condition = parse_expression(p)
    let _ = parser_consume(p, lexer.TokenKind.comma, "expected ',' after static_assert condition")
    let message = parse_expression(p)
    let _ = parser_consume(p, lexer.TokenKind.rparen, "expected ')' after static_assert message")
    parser_consume_end_of_statement(p)
    return ast.Decl.static_assert_decl(node = ast.StaticAssert(
        condition = expr_to_vec(condition),
        message = Option[str].none,
        line = keyword_token.line,
    ))


# =============================================================================
# Known names seeding
# =============================================================================

function seed_known_names(p: ref[Parser]) -> void:
    var builtins: array[str, 16] = array[str, 16](
        "int", "uint", "byte", "ubyte", "short", "ushort",
        "long", "ulong", "float", "double", "bool", "void",
        "str", "ptr_int", "ptr_uint", "char",
    )
    var i: ptr_uint = 0
    while i < 16:
        var s = builtins[i]
        var owned = string.String.from_str(s)
        p.known_type_names.push(owned)
        i += 1

    var depth: int = 0
    var index: ptr_uint = 0
    while index < p.token_count:
        let token = unsafe: read(p.tokens + index)
        let kind = token.kind

        if kind == lexer.TokenKind.indent:
            depth += 1
        else if kind == lexer.TokenKind.dedent:
            if depth > 0:
                depth -= 1
        else if kind == lexer.TokenKind.kw_import and depth == 0:
            index = seed_import_alias(p, index + 1)
        else if kind == lexer.TokenKind.kw_struct and depth == 0:
            let next_idx = index + 1
            if next_idx < p.token_count:
                let next_token = unsafe: read(p.tokens + next_idx)
                if next_token.kind == lexer.TokenKind.identifier:
                    p.known_type_names.push(next_token.lexeme)
        else if kind == lexer.TokenKind.kw_function and depth == 0:
            let next_idx = index + 1
            if next_idx < p.token_count:
                let next_token = unsafe: read(p.tokens + next_idx)
                if next_token.kind == lexer.TokenKind.identifier:
                    let after_idx = index + 2
                    if after_idx < p.token_count:
                        let after_token = unsafe: read(p.tokens + after_idx)
                        if after_token.kind == lexer.TokenKind.lbracket:
                            p.known_generic_callable_names.push(next_token.lexeme)
        index += 1


function seed_import_alias(p: ref[Parser], start: ptr_uint) -> ptr_uint:
    var cursor = start
    var last_part = Option[string.String].none

    while cursor < p.token_count:
        let token = unsafe: read(p.tokens + cursor)
        let kind = token.kind

        if kind == lexer.TokenKind.newline:
            break

        if kind == lexer.TokenKind.kw_as:
            let next_idx = cursor + 1
            if next_idx < p.token_count:
                let next_token = unsafe: read(p.tokens + next_idx)
                if next_token.kind == lexer.TokenKind.identifier:
                    p.known_import_aliases.push(next_token.lexeme)
            return cursor

        if kind == lexer.TokenKind.identifier:
            last_part = Option[string.String].some(value = token.lexeme)
        cursor += 1

    match last_part:
        Option.some as payload:
            p.known_import_aliases.push(payload.value)
        Option.none:
            pass

    return cursor
