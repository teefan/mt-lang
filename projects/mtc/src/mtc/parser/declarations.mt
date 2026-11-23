## Declarations — const/var/function declarations, parameter lists, type
## references, and block bodies.  Extracted from parser.mt.

import std.str
import std.string as string
import std.vec as vec
import std.mem.heap as heap_mod

import mtc.lexer.token_kinds as tk
import mtc.parser.ast as ast
import mtc.parser.state as pstate
import mtc.parser.parser as parser
import mtc.parser.decl_forms as decl_forms
import mtc.parser.statements as statements
import mtc.parser.expressions as expressions


public function parse_const_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    parser.consume_name(s, c"expected constant name")
    let name = parser.previous_lexeme(s)
    if pstate.match_kind(s, tk.TokenKind.arrow):
        # Block-bodied const: const NAME -> TYPE:
        let const_type = parse_type_ref(s)
        let block = parse_block(s)
        var node = parser.alloc_decl(s)
        unsafe:
            read(node) = ast.Decl.decl_const(name = name, const_type = const_type, value = null,
                block_body = block, visibility = visibility, attributes = attrs, line = ln, column = cn)
        return node
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after constant name")
    let const_type = parse_type_ref(s)
    pstate.consume(s, tk.TokenKind.equal, c"expected '=' after constant type")
    let value = expressions.parse_expr(s)
    parser.consume_end_of_statement(s)
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_const(name = name, const_type = const_type, value = value,
            block_body = null, visibility = visibility, attributes = attrs, line = ln, column = cn)
    return node


public function parse_var_decl(s: ref[pstate.ParserState], visibility: bool) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    parser.consume_name(s, c"expected variable name")
    let name = parser.previous_lexeme(s)
    var var_type: ptr[ast.TypeRef]? = null
    if pstate.match_kind(s, tk.TokenKind.colon):
        var_type = parse_type_ref(s)
    var value: ptr[ast.Expr]? = null
    if pstate.match_kind(s, tk.TokenKind.equal):
        value = expressions.parse_expr(s)
    parser.consume_end_of_statement(s)
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_var(name = name, var_type = var_type, value = value,
            visibility = visibility, line = ln, column = cn)
    return node


public function parse_function_def(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool,
                            is_async: bool, is_const: bool) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    let panic_before_name = s.panic
    parser.consume_name(s, c"expected function name")
    let name = parser.previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    var lifetime_params = span[str]()
    if pstate.match_kind(s, tk.TokenKind.lbracket):
        let all_params = parse_declaration_type_params(s)
        var tps = vec.Vec[ast.TypeParam].create()
        var lts = vec.Vec[str].create()
        var pi: ptr_uint = 0
        while pi < all_params.len:
            let prm = unsafe: read(all_params.data + pi)
            if prm.is_lifetime:
                lts.push(prm.name)
            else:
                tps.push(prm)
            pi += 1
        type_params = tps.as_span()
        lifetime_params = lts.as_span()
    let params = parse_params(s)
    var return_type: ptr[ast.TypeRef]? = null
    if pstate.match_kind(s, tk.TokenKind.arrow):
        return_type = parse_type_ref(s)
    let body = parse_block(s)
    # The host's `parse_function_def` rescue: a signature or body that fails
    # still yields the declaration with its name and no params or body, so the
    # outline and the declaration list keep the declaration (the host's partial
    # `FunctionDef`).
    if s.panic and not panic_before_name and name.len > 0:
        s.panic = false
        var partial = parser.alloc_decl(s)
        unsafe:
            read(partial) = ast.Decl.decl_function(name = name, type_params = span[ast.TypeParam](), method_params = span[ast.Param](),
                return_type = null, body = null, visibility = visibility, is_async = is_async,
                is_const = is_const, attributes = attrs, line = ln, column = cn)
        return partial
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_function(name = name, type_params = type_params, method_params = params,
            return_type = return_type, body = body, visibility = visibility, is_async = is_async,
            is_const = is_const, attributes = attrs, line = ln, column = cn)
    return node


## Parse `= c"name"` optional C-name suffix used by struct/union/opaque in
## external files.  Returns none when absent.
public function parse_optional_c_name(s: ref[pstate.ParserState]) -> Option[str]:
    if pstate.match_kind(s, tk.TokenKind.equal):
        if pstate.match_kind(s, tk.TokenKind.cstring):
            return Option[str].some(value = parser.parse_string_content(parser.previous_lexeme(s), true))
        if pstate.match_kind(s, tk.TokenKind.string):
            return Option[str].some(value = parser.parse_string_content(parser.previous_lexeme(s), false))
    return Option[str].none


public function parse_declaration_type_params(s: ref[pstate.ParserState]) -> span[ast.TypeParam]:
    var params = vec.Vec[ast.TypeParam].create()
    while not parser.eof(s):
        if pstate.check(s, tk.TokenKind.rbracket):
            break
        let tp_tok = pstate.peek(s)
        var tln: ptr_uint = 0
        var tcn: ptr_uint = 0
        if tp_tok != null:
            unsafe:
                tln = read(tp_tok).line
                tcn = read(tp_tok).column
        if pstate.match_kind(s, tk.TokenKind.at):
            parser.consume_name_allowing_keywords(s, c"expected lifetime name after @")
            var lt_name = str_prepend_at(parser.previous_lexeme(s))
            params.push(ast.TypeParam(name = lt_name, constraints = span[ast.TypeParamConstraint](),
                is_value = false, value_type = null, is_lifetime = true, line = tln, column = tcn))
        else:
            parser.consume_name_allowing_keywords(s, c"expected type parameter name")
            let tp_name = parser.previous_lexeme(s)
            s.current_type_param_names.push(tp_name)
            var is_value = false
            var value_type: ptr[ast.TypeRef]? = null
            var constraints = vec.Vec[ast.TypeParamConstraint].create()
            if pstate.match_kind(s, tk.TokenKind.colon):
                is_value = true
                value_type = parse_type_ref(s)
            else if pstate.match_kind(s, tk.TokenKind.tk_implements):
                parse_type_param_constraints(s, ref_of(constraints))
            params.push(ast.TypeParam(name = tp_name, constraints = constraints.as_span(),
                is_value = is_value, value_type = value_type, is_lifetime = false, line = tln, column = tcn))
        if not pstate.match_kind(s, tk.TokenKind.comma):
            break
        if pstate.check(s, tk.TokenKind.rbracket):
            break
    pstate.consume(s, tk.TokenKind.rbracket, c"expected ']' after type parameters")
    return params.as_span()


function parse_type_param_constraints(s: ref[pstate.ParserState], constraints: ref[vec.Vec[ast.TypeParamConstraint]]) -> void:
    while true:
        let iface = decl_forms.parse_qualified_name_with_type_args(s)
        constraints.push(ast.TypeParamConstraint(kind = ast.TypeParamConstraintKind.implement, interface_ref = iface))
        if not pstate.match_kind(s, tk.TokenKind.tk_and):
            break


function str_prepend_at(name: str) -> str:
    var buf = string.String.create()
    buf.append("@")
    buf.append(name)
    return buf.as_str()


function with_type_param_scope(s: ref[pstate.ParserState], body: proc(session: ref[pstate.ParserState]) -> void) -> void:
    var saved_count = s.current_type_param_names.len()
    body(s)
    while s.current_type_param_names.len() > saved_count:
        s.current_type_param_names.pop()


public function parse_params(s: ref[pstate.ParserState]) -> span[ast.Param]:
    var params = vec.Vec[ast.Param].create()
    var seen_default = false
    pstate.consume(s, tk.TokenKind.lparen, c"expected '('")
    while not parser.eof(s) and not pstate.check(s, tk.TokenKind.rparen):
        if pstate.match_kind(s, tk.TokenKind.ellipsis):
            break
        if (pstate.check(s, tk.TokenKind.tk_out) or pstate.check(s, tk.TokenKind.tk_in)
            or pstate.check(s, tk.TokenKind.tk_inout) or pstate.check(s, tk.TokenKind.tk_consuming)):
            if parser.check_next(s, tk.TokenKind.identifier) or parser.check_next(s, tk.TokenKind.tk_function):
                pstate.advance(s)
        let tok = pstate.peek(s) else:
            break
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
        parser.consume_name(s, c"expected parameter name")
        let name_str = parser.previous_lexeme(s)
        pstate.consume(s, tk.TokenKind.colon, c"expected ':' after parameter name")
        var ptype = parse_type_ref(s)
        if pstate.match_kind(s, tk.TokenKind.tk_as):
            let _boundary = parse_type_ref(s)
        var default_value: ptr[ast.Expr]? = null
        if pstate.match_kind(s, tk.TokenKind.equal):
            default_value = expressions.parse_expr(s)
            seen_default = true
        else if seen_default:
            pstate.parser_error_naked(s, c"required parameter cannot follow a parameter with a default value")
        unsafe:
            var pm = ast.Param(name = name_str, param_type = read(ptype), line = ln, column = cn, default_value = default_value)
            params.push(pm)
        if not pstate.match_kind(s, tk.TokenKind.comma):
            break
    pstate.consume(s, tk.TokenKind.rparen, c"expected ')'")
    let result = params.as_span()
    return result


public function parse_type_ref(s: ref[pstate.ParserState]) -> ptr[ast.TypeRef]:
    # fn(...) -> T
    if pstate.match_kind(s, tk.TokenKind.tk_fn):
        return parse_callable_type_ref(s, false)
    # proc(...) -> T
    if pstate.match_kind(s, tk.TokenKind.tk_proc):
        return parse_callable_type_ref(s, true)
    # dyn[Interface]
    if pstate.match_kind(s, tk.TokenKind.tk_dyn):
        return parse_dyn_type_ref(s)
    # @lifetime ref
    if pstate.match_kind(s, tk.TokenKind.at):
        let at_tok = pstate.previous_token(s)
        var lt_ln: ptr_uint
        var lt_cn: ptr_uint
        unsafe:
            lt_ln = read(at_tok).line
            lt_cn = read(at_tok).column
        parser.consume_name_allowing_keywords(s, c"expected lifetime name after @")
        let lt_name = parser.previous_lexeme(s)
        var node = heap_mod.must_alloc[ast.TypeRef](1)
        unsafe:
            read(node) = ast.TypeRef(
                name = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef](), line = lt_ln, column = lt_cn),
                arguments = span[ast.TypeRef](), nullable = false,
                lifetime = Option[str].some(value = lt_name), line = lt_ln, column = lt_cn,
                length = lt_name.len + 1,
                lifetime_line = lt_ln, lifetime_column = lt_cn,
                fn_params = span[ast.Param](), fn_return = null,
                is_proc = false, is_fn = false,
                dyn_interface = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef]()),
                is_dyn = false, is_tuple = false
            )
        return node
    # (T, U) tuple type or (T) parenthesized type
    if pstate.match_kind(s, tk.TokenKind.lparen):
        return parse_tuple_or_parenthesized_type(s)

    # Named type ref
    return parse_named_type_ref(s, true)


function parse_callable_type_ref(s: ref[pstate.ParserState], is_proc_val: bool) -> ptr[ast.TypeRef]:
    let start_tok = pstate.peek(s) else:
        fatal(c"unexpected eof in callable type")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    pstate.consume(s, tk.TokenKind.lparen, c"expected '(' after fn/proc")
    var params_vec = vec.Vec[ast.Param].create()
    if not pstate.check(s, tk.TokenKind.rparen):
        while true:
            pstate.step(s)
            let ptok = pstate.peek(s) else:
                break
            var pln: ptr_uint
            var pcn: ptr_uint
            unsafe:
                pln = read(ptok).line
                pcn = read(ptok).column
            parser.consume_name(s, c"expected parameter name in callable type")
            let pname = parser.previous_lexeme(s)
            pstate.consume(s, tk.TokenKind.colon, c"expected ':' after parameter name")
            var ptype = parse_type_ref(s)
            unsafe:
                params_vec.push(ast.Param(name = pname, param_type = read(ptype), line = pln, column = pcn, default_value = null))
            if not pstate.match_kind(s, tk.TokenKind.comma):
                break
            if pstate.check(s, tk.TokenKind.rparen):
                break
    pstate.consume(s, tk.TokenKind.rparen, c"expected ')' after callable type params")
    pstate.consume(s, tk.TokenKind.arrow, c"expected '->' after callable type params")
    var ret_type = parse_type_ref(s)
    var node = heap_mod.must_alloc[ast.TypeRef](1)
    var params_span = params_vec.as_span()
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


function parse_dyn_type_ref(s: ref[pstate.ParserState]) -> ptr[ast.TypeRef]:
    let start_tok = pstate.previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = start_tok.line
        cn = start_tok.column
    pstate.consume(s, tk.TokenKind.lbracket, c"expected '[' after dyn")
    parser.consume_name(s, c"expected interface name after dyn[")
    let iface_name = parser.previous_lexeme(s)
    var iface_ln: ptr_uint = 0
    var iface_cn: ptr_uint = 0
    unsafe:
        iface_ln = read(pstate.previous_token(s)).line
        iface_cn = read(pstate.previous_token(s)).column
    var parts_vec = vec.Vec[str].create()
    parts_vec.push(iface_name)
    while pstate.match_kind(s, tk.TokenKind.dot):
        parser.consume_name(s, c"expected interface name after '.'")
        parts_vec.push(parser.previous_lexeme(s))
    # Optionally parse type arguments for generic interfaces like dyn[Mapper[int]]
    var iface_args = span[ast.TypeRef]()
    if pstate.match_kind(s, tk.TokenKind.lbracket):
        var iface_args_vec = vec.Vec[ast.TypeRef].create()
        if not pstate.check(s, tk.TokenKind.rbracket):
            while true:
                pstate.step(s)
                var ta = parse_type_argument(s)
                unsafe:
                    iface_args_vec.push(read(ta))
                if not pstate.match_kind(s, tk.TokenKind.comma):
                    break
                if pstate.check(s, tk.TokenKind.rbracket):
                    break
        pstate.consume(s, tk.TokenKind.rbracket, c"expected ']' after dyn interface type arguments")
        iface_args = iface_args_vec.as_span()
    var iface_qname = ast.QualifiedName(parts = parts_vec.as_span(), type_arguments = iface_args, line = iface_ln, column = iface_cn)
    pstate.consume(s, tk.TokenKind.rbracket, c"expected ']' after dyn interface")
    var nullable = pstate.match_kind(s, tk.TokenKind.question)
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
    return node


function parse_tuple_or_parenthesized_type(s: ref[pstate.ParserState]) -> ptr[ast.TypeRef]:
    let start_tok = pstate.peek(s) else:
        fatal(c"unexpected eof in tuple type")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(start_tok).line
        cn = read(start_tok).column
    var first_type = parse_type_ref(s)
    if pstate.match_kind(s, tk.TokenKind.comma):
        var types_vec = vec.Vec[ast.TypeRef].create()
        unsafe:
            types_vec.push(read(first_type))
        while true:
            pstate.step(s)
            if pstate.check(s, tk.TokenKind.rparen):
                break
            var next_type = parse_type_ref(s)
            unsafe:
                types_vec.push(read(next_type))
            if not pstate.match_kind(s, tk.TokenKind.comma):
                break
            if pstate.check(s, tk.TokenKind.rparen):
                break
        pstate.consume(s, tk.TokenKind.rparen, c"expected ')' after tuple type elements")
        var nullable = pstate.match_kind(s, tk.TokenKind.question)
        var types_span = types_vec.as_span()
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
    pstate.consume(s, tk.TokenKind.rparen, c"expected ')' after type")
    return first_type


public function parse_named_type_ref(s: ref[pstate.ParserState], allow_nullable: bool) -> ptr[ast.TypeRef]:
    let tok = pstate.peek(s) else:
        fatal(c"unexpected eof in type ref")
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = read(tok).line
        cn = read(tok).column
    parser.consume_name_allowing_keywords(s, c"expected type name")
    let first_name = parser.previous_lexeme(s)
    var part_names = vec.Vec[str].create()
    part_names.push(first_name)
    while pstate.match_kind(s, tk.TokenKind.dot):
        parser.consume_name_allowing_keywords(s, c"expected type name after '.'")
        part_names.push(parser.previous_lexeme(s))
    var type_args_vec = vec.Vec[ast.TypeRef].create()
    var lifetime: Option[str] = Option[str].none
    var lifetime_line: ptr_uint = 0
    var lifetime_column: ptr_uint = 0
    if pstate.match_kind(s, tk.TokenKind.lbracket):
        if pstate.check(s, tk.TokenKind.at):
            pstate.advance(s)
            unsafe:
                lifetime_line = read(pstate.previous_token(s)).line
                lifetime_column = read(pstate.previous_token(s)).column
            unsafe:
                parser.consume_name_allowing_keywords(s, c"expected lifetime name after @")
                lifetime = Option[str].some(value = parser.previous_lexeme(s))
            # A trailing comma introduces further type arguments (e.g.
            # `ref[@a, T]`); a lifetime-only argument (`SliceView[@a]`) has none.
            let _lt_comma = pstate.match_kind(s, tk.TokenKind.comma)
        if not pstate.check(s, tk.TokenKind.rbracket):
            while true:
                pstate.step(s)
                var ta = parse_type_argument(s)
                unsafe:
                    type_args_vec.push(read(ta))
                if not pstate.match_kind(s, tk.TokenKind.comma):
                    break
                if pstate.check(s, tk.TokenKind.rbracket):
                    break
        pstate.consume(s, tk.TokenKind.rbracket, c"expected ']' after type arguments")
    var nullable = false
    if allow_nullable:
        nullable = pstate.match_kind(s, tk.TokenKind.question)
    var name_parts_span = part_names.as_span()
    var type_args_span = type_args_vec.as_span()
    var qname = ast.QualifiedName(parts = name_parts_span, type_arguments = type_args_span, line = ln, column = cn)
    var name_len: ptr_uint = 0
    var pi: ptr_uint = 0
    while pi < part_names.len():
        let p = part_names.get(pi) else:
            break
        if pi > 0:
            name_len += 1
        unsafe:
            name_len += read(p).len
        pi += 1
    if nullable:
        name_len += 1
    var node = heap_mod.must_alloc[ast.TypeRef](1)
    unsafe:
        read(node) = ast.TypeRef(
            name = qname, arguments = type_args_span, nullable = nullable,
            lifetime = lifetime, line = ln, column = cn,
            length = name_len, lifetime_line = lifetime_line, lifetime_column = lifetime_column,
            fn_params = span[ast.Param](), fn_return = null,
            is_proc = false, is_fn = false,
            dyn_interface = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef]()),
            is_dyn = false, is_tuple = false
        )
    return node


public function parse_type_argument(s: ref[pstate.ParserState]) -> ptr[ast.TypeRef]:
    if pstate.match_kind(s, tk.TokenKind.integer):
        let lex = parser.previous_lexeme(s)
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
        return node
    if pstate.match_kind(s, tk.TokenKind.float_literal):
        let lex = parser.previous_lexeme(s)
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
        return node
    # Fall back to a full type ref so callable (`fn(...)->T`), proc, dyn,
    # tuple and nullable type arguments are handled, not just named types.
    return parse_type_ref(s)


public function parse_block(s: ref[pstate.ParserState]) -> ptr[ast.Stmt]:
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' before block")
    pstate.consume(s, tk.TokenKind.newline, c"expected newline before block body")
    parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.indent, c"expected indented block")
    var body_span = parse_block_body(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of block")
    var node = parser.alloc_stmt(s)
    read(node) = ast.Stmt.stmt_block(statements = body_span)
    return node


public function parse_block_body(s: ref[pstate.ParserState]) -> span[ast.Stmt]:
    var stmts = vec.Vec[ast.Stmt].create()
    parser.skip_newlines(s)
    while not pstate.check(s, tk.TokenKind.dedent) and not parser.eof(s):
        pstate.step(s)
        if pstate.check(s, tk.TokenKind.newline):
            pstate.advance(s)
            parser.skip_newlines(s)
            continue
        let stmt = statements.parse_statement(s)
        if s.panic:
            parser.recover_statement(s)
        else:
            unsafe:
                stmts.push(read(stmt))
        parser.skip_newlines(s)
    let result = stmts.as_span()
    return result
