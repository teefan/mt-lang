## Specialization target disambiguation — decide when `xs[...]` is a type
## specialization rather than an index access (mirrors Ruby
## parser/expressions.rb).  Extracted from parser.mt.

import std.str
import std.vec as vec

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.parser.ast as ast
import mtc.parser.state as pstate
import mtc.parser.parser as parser
import mtc.parser.declarations as declarations
import mtc.parser.expressions as expressions
import mtc.parser.expression_forms as expression_forms


function is_identifier_named(callee: ptr[ast.Expr], name: str) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return id.name == name
            _:
                return false


function builtin_specialization_target(callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return (
                    id.name == "array" or id.name == "reinterpret" or id.name == "span"
                    or id.name == "zero" or id.name == "ptr" or id.name == "const_ptr"
                    or id.name == "own" or id.name == "ref" or id.name == "adapt"
                    or id.name == "equal" or id.name == "hash" or id.name == "order"
                    or id.name == "simd" or id.name == "SoA"
                )
            _:
                return false


function generic_callable_specialization_target(s: ref[pstate.ParserState], callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return s.known_generic_callable_names.contains(id.name)
            _:
                return false


function imported_member_specialization_target(s: ref[pstate.ParserState], callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as rid:
                        return s.known_import_aliases.contains(rid.name)
                    _:
                        return false
            _:
                return false


function callee_known_type_like(s: ref[pstate.ParserState], callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return parser.known_type_like_name(s, id.name)
            _:
                return false


## A definite type argument: a callable type, or a single name that is a known
## type-like name (builtin type, declared type, alias, import alias, or type
## parameter).  A bare integer such as the `0` in `xs[0]` is not definite.
function definite_type_argument(s: ref[pstate.ParserState], arg: ptr[ast.TypeRef]) -> bool:
    unsafe:
        let t = read(arg)
        if t.is_fn or t.is_proc or t.is_tuple:
            return true
        if t.name.parts.len >= 1:
            return parser.known_type_like_name(s, read(t.name.parts.data + 0))
        return false


function potential_named_literal_type_argument(arg: ptr[ast.TypeRef]) -> bool:
    unsafe:
        let t = read(arg)
        return t.arguments.len == 0 and not t.nullable


function explicit_specialization_argument(s: ref[pstate.ParserState], arg: ptr[ast.TypeRef]) -> bool:
    if definite_type_argument(s, arg):
        return true
    return potential_named_literal_type_argument(arg)


function all_definite_type_args(s: ref[pstate.ParserState], args: span[ast.TypeArgument]) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        unsafe:
            if not definite_type_argument(s, read(args.data + i).value):
                return false
        i += 1
    return true


function all_explicit_specialization_args(s: ref[pstate.ParserState], args: span[ast.TypeArgument]) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        unsafe:
            if not explicit_specialization_argument(s, read(args.data + i).value):
                return false
        i += 1
    return true


function all_call_args_named(call_args: span[ast.Argument]) -> bool:
    var i: ptr_uint = 0
    while i < call_args.len:
        unsafe:
            match read(call_args.data + i).arg_name:
                Option.some:
                    pass
                Option.none:
                    return false
        i += 1
    return true


## True when the `name[args]` form (no call) is a genuine type specialization
## rather than an index access.
public function specialization_value_target(
    s: ref[pstate.ParserState],
    callee: ptr[ast.Expr],
    args: span[ast.TypeArgument]
) -> bool:
    if is_identifier_named(callee, "zero") and all_explicit_specialization_args(s, args):
        return true
    if expressions.specialization_target(callee) and all_definite_type_args(s, args):
        return true
    if generic_callable_specialization_target(s, callee) and all_explicit_specialization_args(s, args):
        return true
    if imported_member_specialization_target(s, callee) and all_explicit_specialization_args(s, args):
        return true
    return false


## True when the `name[args](call_args)` form is a genuine specialized call.
public function specialization_call_target(
    s: ref[pstate.ParserState],
    callee: ptr[ast.Expr],
    args: span[ast.TypeArgument],
    call_args: span[ast.Argument]
) -> bool:
    if (is_identifier_named(
        callee,
        "default"
    ) or is_identifier_named(
        callee,
        "zero"
    )) and not callee_known_type_like(s, callee) and not generic_callable_specialization_target(s, callee):
        return false
    if builtin_specialization_target(callee):
        return true
    if expressions.specialization_target(callee) and all_call_args_named(call_args):
        return true
    if generic_callable_specialization_target(s, callee) and all_explicit_specialization_args(s, args):
        return true
    if imported_member_specialization_target(s, callee) and all_explicit_specialization_args(s, args):
        return true
    return expressions.specialization_target(callee) and all_definite_type_args(s, args)


public function parse_primary(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    if pstate.match_kind(s, tk.TokenKind.integer):
        let lex = parser.previous_lexeme(s)
        let val = parser.parse_int_literal(lex)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_integer_literal(lexeme = lex, value = val)
        return node
    else if pstate.match_kind(s, tk.TokenKind.float_literal):
        let lex = parser.previous_lexeme(s)
        let val = parser.parse_float_literal(lex)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_float_literal(lexeme = lex, value = val)
        return node
    else if pstate.match_kind(s, tk.TokenKind.string):
        return parse_string_primary(s, false)
    else if pstate.match_kind(s, tk.TokenKind.cstring):
        return parse_string_primary(s, true)
    else if pstate.match_kind(s, tk.TokenKind.char_literal):
        let lex = parser.previous_lexeme(s)
        let val = parser.parse_char_value(lex)
        let tok = pstate.previous_token(s)
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = tok.line
            cn = tok.column
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_char_literal(lexeme = lex, value = val, line = ln, column = cn)
        return node
    else if pstate.match_kind(s, tk.TokenKind.tk_true):
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_bool_literal(value = true)
        return node
    else if pstate.match_kind(s, tk.TokenKind.tk_false):
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_bool_literal(value = false)
        return node
    else if pstate.match_kind(s, tk.TokenKind.tk_null):
        let tok = pstate.previous_token(s)
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = tok.line
            cn = tok.column
        var target: ptr[ast.TypeRef]? = null
        if pstate.match_kind(s, tk.TokenKind.lbracket):
            target = declarations.parse_type_ref(s)
            pstate.consume(s, tk.TokenKind.rbracket, c"expected ']' after null type")
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_null_literal(target_type = target, line = ln, column = cn)
        return node
    else if parser.match_name(s):
        let name_str = parser.previous_lexeme(s)
        let tok = pstate.previous_token(s)
        var ln: ptr_uint
        var cn: ptr_uint
        unsafe:
            ln = tok.line
            cn = tok.column
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_identifier(name = name_str, line = ln, column = cn)
        return node
    else if keyword_identifier_matches(s):
        return parse_keyword_identifier(s)
    else if pstate.match_kind(s, tk.TokenKind.lparen):
        return parse_paren_primary(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_if):
        return expression_forms.parse_if_expr(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_match):
        return expression_forms.parse_match_expr(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_proc):
        return expression_forms.parse_proc_expr_after_proc(s)
    else if pstate.match_kind(s, tk.TokenKind.tk_size_of):
        pstate.consume(s, tk.TokenKind.lparen, c"expected '(' after size_of")
        var type_ref = declarations.parse_type_ref(s)
        pstate.consume(s, tk.TokenKind.rparen, c"expected ')'")
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_sizeof(target_type = type_ref)
        return node
    else if pstate.match_kind(s, tk.TokenKind.tk_align_of):
        pstate.consume(s, tk.TokenKind.lparen, c"expected '(' after align_of")
        var type_ref = declarations.parse_type_ref(s)
        pstate.consume(s, tk.TokenKind.rparen, c"expected ')'")
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_alignof(target_type = type_ref)
        return node
    else if pstate.match_kind(s, tk.TokenKind.tk_offset_of):
        pstate.consume(s, tk.TokenKind.lparen, c"expected '(' after offset_of")
        var type_ref = declarations.parse_type_ref(s)
        pstate.consume(s, tk.TokenKind.comma, c"expected ','")
        parser.consume_name_allowing_keywords(s, c"expected field name")
        let field_name = parser.previous_lexeme(s)
        pstate.consume(s, tk.TokenKind.rparen, c"expected ')'")
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_offsetof(target_type = type_ref, field = field_name)
        return node
    else if pstate.match_kind(s, tk.TokenKind.fstring):
        let lex = parser.previous_lexeme(s)
        let ftok = pstate.previous_token(s)
        var fline: ptr_uint = 0
        var fcol: ptr_uint = 0
        unsafe:
            fline = read(ftok).line
            fcol = read(ftok).column
        return parser.parse_format_string_expr(s, lex, fline, fcol)
    else if pstate.match_kind(s, tk.TokenKind.at):
        pstate.consume(s, tk.TokenKind.lbracket, c"expected '[' after @")
        parser.skip_attribute_content(s)
        pstate.consume(s, tk.TokenKind.rbracket, c"expected ']' after attribute")
        pstate.parser_error_naked(s, c"expected expression")
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_error(line = 0, column = 0, message = "unexpected @[attr] in expression")
        return node
    else:
        let tok_ptr = pstate.peek(s) else:
            pstate.parser_error_naked(s, c"expected expression")
            var node = parser.alloc_expr(s)
            read(node) = ast.Expr.expr_error(line = 0, column = 0, message = "expected expression")
            return node
        var tok: token_mod.Token
        unsafe:
            tok = read(tok_ptr)
        if parser.is_keyword_token(tok):
            pstate.advance(s)
            var ln: ptr_uint = tok.line
            var cn: ptr_uint = tok.column
            var node = parser.alloc_expr(s)
            read(node) = ast.Expr.expr_identifier(name = token_mod.token_lexeme(tok, s.source), line = ln, column = cn)
            return node
        pstate.parser_error_naked(s, c"expected expression")
        pstate.advance(s)
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_error(line = 0, column = 0, message = "expected expression")
        return node


## Adjacent string/cstring tokens form one literal; `is_cstring` selects the
## escape policy and the AST flag.
function parse_string_primary(s: ref[pstate.ParserState], is_cstring: bool) -> ptr[ast.Expr]:
    let first_tok = pstate.previous_token(s)
    var all_lexeme: str
    unsafe:
        all_lexeme = token_mod.token_lexeme(read(first_tok), s.source)
    while pstate.check(s, tk.TokenKind.string) or pstate.check(s, tk.TokenKind.cstring):
        pstate.advance(s)
    let val = parser.parse_string_content(all_lexeme, is_cstring)
    var node = parser.alloc_expr(s)
    read(node) = ast.Expr.expr_string_literal(lexeme = all_lexeme, value = val, is_cstring = is_cstring)
    return node


## Match one of the reflection keywords that parse as a bare identifier.
function keyword_identifier_matches(s: ref[pstate.ParserState]) -> bool:
    if pstate.match_kind(s, tk.TokenKind.tk_fields_of):
        return true
    if pstate.match_kind(s, tk.TokenKind.tk_members_of):
        return true
    if pstate.match_kind(s, tk.TokenKind.tk_attributes_of):
        return true
    if pstate.match_kind(s, tk.TokenKind.tk_field_of):
        return true
    if pstate.match_kind(s, tk.TokenKind.tk_callable_of):
        return true
    if pstate.match_kind(s, tk.TokenKind.tk_attribute_of):
        return true
    if pstate.match_kind(s, tk.TokenKind.tk_has_attribute):
        return true
    return pstate.match_kind(s, tk.TokenKind.tk_attribute_arg)


## Build an identifier from the reflection keyword just consumed.
function parse_keyword_identifier(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    let tok = pstate.previous_token(s)
    var node = parser.alloc_expr(s)
    unsafe:
        let t = read(tok)
        read(node) = ast.Expr.expr_identifier(
            name = token_mod.token_lexeme(t, s.source),
            line = t.line,
            column = t.column
        )
    return node


## Parenthesized expression, named tuple field, or tuple expression list.
function parse_paren_primary(s: ref[pstate.ParserState]) -> ptr[ast.Expr]:
    let start_tok = pstate.previous_token(s)
    var ln: ptr_uint
    var cn: ptr_uint
    unsafe:
        ln = start_tok.line
        cn = start_tok.column
    var first_expr: ptr[ast.Expr]
    if (parser.check_name(s) or parser.keyword_token_check(pstate.peek(s))) and parser.check_next(
        s,
        tk.TokenKind.equal
    ):
        var name_str: str
        let nt = pstate.peek(s) else:
            fatal(c"unexpected eof in named tuple field")
        unsafe:
            name_str = token_mod.token_lexeme(read(nt), s.source)
        pstate.advance(s)
        pstate.advance(s)
        var val = expressions.parse_expr(s)
        first_expr = parser.alloc_expr(s)
        unsafe:
            read(first_expr) = ast.Expr.expr_named(name = name_str, value = val)
    else:
        first_expr = expressions.parse_expr(s)
    if pstate.match_kind(s, tk.TokenKind.comma):
        var elems = vec.Vec[ast.Expr].create()
        unsafe:
            elems.push(read(first_expr))
        while true:
            pstate.step(s)
            if pstate.check(s, tk.TokenKind.rparen):
                break
            if (parser.check_name(s) or parser.keyword_token_check(pstate.peek(s))) and parser.check_next(
                s,
                tk.TokenKind.equal
            ):
                var name_str: str
                let nt2 = pstate.peek(s) else:
                    break
                unsafe:
                    name_str = token_mod.token_lexeme(read(nt2), s.source)
                pstate.advance(s)
                pstate.advance(s)
                var val2 = expressions.parse_expr(s)
                var ne = parser.alloc_expr(s)
                unsafe:
                    read(ne) = ast.Expr.expr_named(name = name_str, value = val2)
                unsafe:
                    elems.push(read(ne))
            else:
                var next = expressions.parse_expr(s)
                unsafe:
                    elems.push(read(next))
            if not pstate.match_kind(s, tk.TokenKind.comma):
                break
            if pstate.check(s, tk.TokenKind.rparen):
                break
        pstate.consume(s, tk.TokenKind.rparen, c"expected ')' after tuple elements")
        let elems_span = elems.as_span()
        var node = parser.alloc_expr(s)
        read(node) = ast.Expr.expr_expression_list(elements = elems_span, line = ln, column = cn)
        return node
    pstate.consume(s, tk.TokenKind.rparen, c"expected ')' after expression")
    return first_expr
