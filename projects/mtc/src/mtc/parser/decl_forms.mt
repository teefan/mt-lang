## Declaration forms — structs, enums, variants, interfaces, opaque types,
## extending blocks, methods, extern/foreign declarations, events, `when`
## declarations, attributes, and signatures.  Extracted from parser.mt.

import std.str
import std.string as string
import std.vec as vec
import std.mem.heap as heap_mod

import mtc.lexer.token_kinds as tk
import mtc.parser.ast as ast
import mtc.parser.state as pstate
import mtc.parser.parser as parser
import mtc.parser.declarations as declarations
import mtc.parser.expressions as expressions


public function parse_struct_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    parser.consume_name(s, c"expected struct name")
    let name = parser.previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    var lifetime_params = span[str]()
    if pstate.match_kind(s, tk.TokenKind.lbracket):
        let all_params = declarations.parse_declaration_type_params(s)
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
    var impl_list = span[ast.QualifiedName]()
    if pstate.match_kind(s, tk.TokenKind.tk_implements):
        impl_list = parse_implements_list(s)
    let c_name = declarations.parse_optional_c_name(s)
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after struct name")
    pstate.consume(s, tk.TokenKind.newline, c"expected newline")
    parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.indent, c"expected indented struct body")
    parser.skip_newlines(s)
    var fields = vec.Vec[ast.Field].create()
    var events = vec.Vec[ast.Decl].create()
    var nested = vec.Vec[ast.Decl].create()
    var methods = vec.Vec[ast.Method].create()
    while not pstate.check(s, tk.TokenKind.dedent) and not parser.eof(s):
        let member_attrs = parser.parse_attribute_applications(s)
        let member_vis = pstate.match_kind(s, tk.TokenKind.tk_public)
        # `event`/`struct` are keywords, but they are also valid field names.
        # The host disambiguates with `!parser.check_next(:colon)`: `event: T` is a
        # field, while `event name` / `struct name` start declarations.
        if pstate.check(s, tk.TokenKind.tk_event) and not parser.check_next(s, tk.TokenKind.colon):
            pstate.match_kind(s, tk.TokenKind.tk_event)
            unsafe:
                events.push(read(parse_event_decl(s, member_attrs, member_vis)))
        else if pstate.check(s, tk.TokenKind.tk_struct) and not parser.check_next(s, tk.TokenKind.colon):
            pstate.match_kind(s, tk.TokenKind.tk_struct)
            unsafe:
                nested.push(read(parse_struct_decl(s, member_attrs, member_vis)))
        else if struct_member_is_method(s):
            methods.push(parse_method_def(s, member_attrs, member_vis))
        else:
            fields.push(parse_struct_member(s, member_attrs))
        parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of struct body")
    var packed = false
    var alignment: int = 0
    extract_layout_attributes(attrs, ref_of(packed), ref_of(alignment))
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_struct(name = name, type_params = type_params, impl_list = impl_list,
            c_name = c_name, struct_fields = fields.as_span(), struct_events = events.as_span(),
            nested_types = nested.as_span(), struct_attrs = attrs, packed = packed, alignment = alignment,
            visibility = visibility, lifetime_params = lifetime_params, line = ln, column = cn)
    # Inline struct-body methods desugar to an extending block appended after
    # the struct declaration, lowering to the same C as an explicit block.
    if methods.len() > 0:
        let type_name = make_named_type_ref(s, name, ln, cn)
        var ext = parser.alloc_decl(s)
        unsafe:
            read(ext) = ast.Decl.decl_extending_block(type_name = type_name, methods = methods.as_span(),
                line = ln, column = cn, is_inline = true)
        unsafe:
            s.pending_decls.push(read(ext))
    return node


## Move declarations synthesized while parsing another declaration (inline
## struct methods) into the enclosing declaration list.
public function drain_pending_decls(s: ref[pstate.ParserState], out_decls: ref[vec.Vec[ast.Decl]]) -> void:
    var i: ptr_uint = 0
    while i < s.pending_decls.len():
        let d = s.pending_decls.get(i) else:
            break
        unsafe:
            out_decls.push(read(d))
        i += 1
    s.pending_decls.clear()


## Extract the built-in layout attributes from a declaration's attribute list:
## `@[packed]` sets `packed`; `@[align(N)]` with an integer-literal argument
## sets `alignment`.  Other attributes are user-defined and stay in the generic
## attribute list.
function extract_layout_attributes(attrs: span[ast.AttributeApplication], packed: ref[bool], alignment: ref[int]) -> void:
    var i: ptr_uint = 0
    while i < attrs.len:
        var applied: ast.AttributeApplication
        unsafe:
            applied = read(attrs.data + i)
        if applied.name.parts.len == 1:
            let attr_name = unsafe: read(applied.name.parts.data + 0)
            if attr_name == "packed":
                read(packed) = true
            if attr_name == "align" and applied.arguments.len == 1:
                unsafe:
                    match read(read(applied.arguments.data + 0).arg_value):
                        ast.Expr.expr_integer_literal as lit:
                            read(alignment) = int<-lit.value
                        _:
                            pass
        i += 1


public function parse_struct_member(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication]) -> ast.Field:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    parser.consume_name_allowing_keywords(s, c"expected field name")
    let name = parser.previous_lexeme(s)
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after field name")
    let ftype = declarations.parse_type_ref(s)
    parser.consume_end_of_statement(s)
    unsafe:
        return ast.Field(name = name, field_type = read(ftype), attributes = attrs, line = ln, column = cn)


## Parse a comma-separated `implements A, B` list (the `implements` keyword is
## consumed by the caller).  Generic type-arguments on each name are skipped,
## matching Ruby's QualifiedName rendering.
## QualifiedName with optional `[T, ...]` type arguments (host
## `parse_qualified_name_with_type_arguments`).
public function parse_qualified_name_with_type_args(s: ref[pstate.ParserState]) -> ast.QualifiedName:
    let tok = pstate.peek(s) else:
        fatal(c"unexpected eof in qualified name")
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    unsafe:
        ln = read(tok).line
        cn = read(tok).column
    parser.consume_name_allowing_keywords(s, c"expected identifier")
    var parts_vec = vec.Vec[str].create()
    parts_vec.push(parser.previous_lexeme(s))
    while pstate.match_kind(s, tk.TokenKind.dot):
        parser.consume_name_allowing_keywords(s, c"expected identifier after '.'")
        parts_vec.push(parser.previous_lexeme(s))
    var targs = vec.Vec[ast.TypeRef].create()
    if pstate.match_kind(s, tk.TokenKind.lbracket):
        if not pstate.check(s, tk.TokenKind.rbracket):
            while true:
                pstate.step(s)
                let ta = declarations.parse_type_argument(s)
                unsafe:
                    targs.push(read(ta))
                if not pstate.match_kind(s, tk.TokenKind.comma):
                    break
                if pstate.check(s, tk.TokenKind.rbracket):
                    break
        pstate.consume(s, tk.TokenKind.rbracket, c"expected ']' after type arguments")
    return ast.QualifiedName(parts = parts_vec.as_span(), type_arguments = targs.as_span(), line = ln, column = cn)


function parse_implements_list(s: ref[pstate.ParserState]) -> span[ast.QualifiedName]:
    var list = vec.Vec[ast.QualifiedName].create()
    while true:
        list.push(parse_qualified_name_with_type_args(s))
        if not pstate.match_kind(s, tk.TokenKind.comma):
            break
    return list.as_span()


public function parse_type_alias(s: ref[pstate.ParserState], visibility: bool) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    parser.consume_name(s, c"expected type alias name")
    let name = parser.previous_lexeme(s)
    pstate.consume(s, tk.TokenKind.equal, c"expected '=' after type alias name")
    let target = declarations.parse_type_ref(s)
    parser.consume_end_of_statement(s)
    var node = parser.alloc_decl(s)
    read(node) = ast.Decl.decl_type_alias(name = name, target = target, visibility = visibility, line = ln, column = cn)
    return node


function make_named_type_ref(s: ref[pstate.ParserState], name: str, ln: ptr_uint, cn: ptr_uint) -> ptr[ast.TypeRef]:
    var parts = vec.Vec[str].create()
    parts.push(name)
    var node = heap_mod.must_alloc[ast.TypeRef](1)
    unsafe:
        read(node) = ast.TypeRef(
            name = ast.QualifiedName(parts = parts.as_span(), type_arguments = span[ast.TypeRef](), line = ln, column = cn),
            arguments = span[ast.TypeRef](), nullable = false,
            lifetime = Option[str].none, line = ln, column = cn,
            fn_params = span[ast.Param](), fn_return = null,
            is_proc = false, is_fn = false,
            dyn_interface = ast.QualifiedName(parts = span[str](), type_arguments = span[ast.TypeRef]()),
            is_dyn = false, is_tuple = false
        )
    return node


function make_int_type_ref(s: ref[pstate.ParserState], ln: ptr_uint, cn: ptr_uint) -> ptr[ast.TypeRef]:
    return make_named_type_ref(s, "int", ln, cn)


function make_int_literal(s: ref[pstate.ParserState], value: int) -> ptr[ast.Expr]:
    var node = parser.alloc_expr(s)
    read(node) = ast.Expr.expr_integer_literal(lexeme = int_to_dec(value), value = value)
    return node


## Advance the enum auto-increment counter after an explicit member value,
## matching the Ruby parser: a plain integer literal sets the counter to
## value+1, and a negated integer literal (`-3`) to -value+1; any other
## expression leaves the counter unchanged.
function enum_auto_after(value: ptr[ast.Expr], current: int) -> int:
    unsafe:
        match read(value):
            ast.Expr.expr_integer_literal as lit:
                return int<-(lit.value + 1)
            ast.Expr.expr_unary_op as un:
                if un.operator == "-":
                    match read(un.operand):
                        ast.Expr.expr_integer_literal as lit2:
                            return int<-(-lit2.value + 1)
                        _:
                            return current
                return current
            _:
                return current


function int_to_dec(value: int) -> str:
    if value == 0:
        return "0"
    var negative = value < 0
    var n = value
    if negative:
        n = -n
    var digits = string.String.create()
    while n > 0:
        let d = n % 10
        digits.push_byte(ubyte<-(d + 48))
        n = n / 10
    var rev = string.String.create()
    if negative:
        rev.push_byte(ubyte<-45)
    let raw = digits.as_str()
    var i = raw.len
    while i > 0:
        i -= 1
        rev.push_byte(raw.byte_at(i))
    return rev.as_str()


public function parse_enum_decl(s: ref[pstate.ParserState], is_flags: bool, attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    parser.consume_name(s, c"expected enum name")
    let name = parser.previous_lexeme(s)
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after enum name")
    var backing_type: ptr[ast.TypeRef]? = null
    if pstate.check(s, tk.TokenKind.newline) or pstate.check(s, tk.TokenKind.indent):
        backing_type = make_int_type_ref(s, ln, name.len + 1)
    else:
        backing_type = declarations.parse_type_ref(s)
    pstate.consume(s, tk.TokenKind.newline, c"expected newline")
    parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.indent, c"expected indented enum body")
    parser.skip_newlines(s)
    var members = vec.Vec[ast.EnumMember].create()
    var auto_value: int = 0
    while not pstate.check(s, tk.TokenKind.dedent) and not parser.eof(s):
        let mtok = pstate.peek(s)
        var mln: ptr_uint = 0
        var mcn: ptr_uint = 0
        if mtok != null:
            unsafe:
                mln = read(mtok).line
                mcn = read(mtok).column
        parser.consume_name_allowing_keywords(s, c"expected member name")
        let mname = parser.previous_lexeme(s)
        var mvalue: ptr[ast.Expr]? = null
        var value_explicit = false
        if pstate.match_kind(s, tk.TokenKind.equal):
            let explicit = expressions.parse_expr(s)
            mvalue = explicit
            value_explicit = true
            auto_value = enum_auto_after(explicit, auto_value)
        else:
            mvalue = make_int_literal(s, auto_value)
            auto_value += 1
        parser.consume_end_of_statement(s)
        members.push(ast.EnumMember(name = mname, value = mvalue, line = mln, column = mcn, value_explicit = value_explicit))
        parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of enum body")
    var node = parser.alloc_decl(s)
    let members_span = members.as_span()
    unsafe:
        if is_flags:
            read(node) = ast.Decl.decl_flags(name = name, backing_type = backing_type, flags_members = members_span,
                visibility = visibility, flags_attrs = attrs, line = ln, column = cn)
        else:
            read(node) = ast.Decl.decl_enum(name = name, backing_type = backing_type, enum_members = members_span,
                visibility = visibility, enum_attrs = attrs, line = ln, column = cn)
    return node


public function parse_variant_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    parser.consume_name(s, c"expected variant name")
    let name = parser.previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    var lifetime_params = span[str]()
    if pstate.match_kind(s, tk.TokenKind.lbracket):
        let all_params = declarations.parse_declaration_type_params(s)
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
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after variant name")
    pstate.consume(s, tk.TokenKind.newline, c"expected newline")
    pstate.consume(s, tk.TokenKind.indent, c"expected indented variant body")
    parser.skip_newlines(s)
    var arms = vec.Vec[ast.VariantArm].create()
    while not pstate.check(s, tk.TokenKind.dedent) and not parser.eof(s):
        parser.consume_name_allowing_keywords(s, c"expected arm name")
        let arm_name = parser.previous_lexeme(s)
        var arm_fields = span[ast.Field]()
        if pstate.match_kind(s, tk.TokenKind.lparen):
            arm_fields = parse_variant_arm_fields(s)
        parser.consume_end_of_statement(s)
        arms.push(ast.VariantArm(name = arm_name, arm_fields = arm_fields))
        parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of variant body")
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_variant(name = name, type_params = type_params, variant_arms = arms.as_span(),
            visibility = visibility, variant_attrs = attrs, line = ln, column = cn)
    return node


function parse_variant_arm_fields(s: ref[pstate.ParserState]) -> span[ast.Field]:
    var fields = vec.Vec[ast.Field].create()
    while not pstate.check(s, tk.TokenKind.rparen) and not parser.eof(s):
        let tok = pstate.peek(s)
        var ln: ptr_uint = 0
        var cn: ptr_uint = 0
        if tok != null:
            unsafe:
                ln = read(tok).line
                cn = read(tok).column
        parser.consume_name_allowing_keywords(s, c"expected field name in variant arm")
        let fname = parser.previous_lexeme(s)
        pstate.consume(s, tk.TokenKind.colon, c"expected ':' after field name")
        let ftype = declarations.parse_type_ref(s)
        unsafe:
            fields.push(ast.Field(name = fname, field_type = read(ftype),
                attributes = span[ast.AttributeApplication](), line = ln, column = cn))
        if not pstate.match_kind(s, tk.TokenKind.comma):
            break
    pstate.consume(s, tk.TokenKind.rparen, c"expected ')' after variant arm fields")
    return fields.as_span()


public function parse_interface_decl(s: ref[pstate.ParserState], visibility: bool) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    parser.consume_name(s, c"expected interface name")
    let name = parser.previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    var lifetime_params = span[str]()
    if pstate.match_kind(s, tk.TokenKind.lbracket):
        let all_params = declarations.parse_declaration_type_params(s)
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
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after interface name")
    pstate.consume(s, tk.TokenKind.newline, c"expected newline")
    pstate.consume(s, tk.TokenKind.indent, c"expected indented interface body")
    parser.skip_newlines(s)
    var methods = vec.Vec[ast.InterfaceMethod].create()
    while not pstate.check(s, tk.TokenKind.dedent) and not parser.eof(s):
        methods.push(parse_interface_method(s))
        parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of interface body")
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_interface(name = name, type_params = type_params,
            interface_methods = methods.as_span(), visibility = visibility, line = ln, column = cn)
    return node


function parse_interface_method(s: ref[pstate.ParserState]) -> ast.InterfaceMethod:
    var is_async = pstate.match_kind(s, tk.TokenKind.tk_async)
    var kind = ast.MethodKind.mk_plain
    if pstate.match_kind(s, tk.TokenKind.tk_editable):
        kind = ast.MethodKind.mk_editable
    else if pstate.match_kind(s, tk.TokenKind.tk_static):
        kind = ast.MethodKind.mk_static
    pstate.consume(s, tk.TokenKind.tk_function, c"expected function in interface")
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    parser.consume_name(s, c"expected method name")
    let name = parser.previous_lexeme(s)
    let params = declarations.parse_params(s)
    var return_type: ptr[ast.TypeRef]? = null
    if pstate.match_kind(s, tk.TokenKind.arrow):
        return_type = declarations.parse_type_ref(s)
    parser.consume_end_of_statement(s)
    return ast.InterfaceMethod(name = name, method_params = params, return_type = return_type,
        method_kind = kind, is_async = is_async, attributes = span[ast.AttributeApplication](), line = ln, column = cn)


public function parse_opaque_decl(s: ref[pstate.ParserState], visibility: bool) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    parser.consume_name(s, c"expected opaque type name")
    let name = parser.previous_lexeme(s)
    var impl_list = span[ast.QualifiedName]()
    if pstate.match_kind(s, tk.TokenKind.tk_implements):
        impl_list = parse_implements_list(s)
    let c_name = declarations.parse_optional_c_name(s)
    parser.consume_end_of_statement(s)
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_opaque(name = name, opaque_implements = impl_list, c_name = c_name,
            visibility = visibility, line = ln, column = cn)
    return node


public function parse_extending_block(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    let type_name = declarations.parse_type_ref(s)
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after extending type")
    pstate.consume(s, tk.TokenKind.newline, c"expected newline")
    parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.indent, c"expected indented extending body")
    parser.skip_newlines(s)
    var methods = vec.Vec[ast.Method].create()
    while not pstate.check(s, tk.TokenKind.dedent) and not parser.eof(s):
        methods.push(parse_extending_method(s))
        parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of extending body")
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_extending_block(type_name = type_name, methods = methods.as_span(),
            line = ln, column = cn, is_inline = false)
    return node


function parse_extending_method(s: ref[pstate.ParserState]) -> ast.Method:
    let attrs = parser.parse_attribute_applications(s)
    let visibility = pstate.match_kind(s, tk.TokenKind.tk_public)
    return parse_method_def(s, attrs, visibility)


## True when the current position starts an inline method inside a struct body
## rather than a field.  `function: int` stays a field named `function`; the
## declaration keywords are otherwise accepted as field names too.
function struct_member_is_method(s: ref[pstate.ParserState]) -> bool:
    if pstate.check(s, tk.TokenKind.tk_function):
        return not parser.check_next(s, tk.TokenKind.colon)
    if pstate.check(s, tk.TokenKind.tk_editable) or pstate.check(s, tk.TokenKind.tk_async):
        return parser.check_next(s, tk.TokenKind.tk_function)
    if pstate.check(s, tk.TokenKind.tk_static):
        return parser.check_next(s, tk.TokenKind.tk_function) or parser.check_next(s, tk.TokenKind.tk_const)
    if pstate.check(s, tk.TokenKind.tk_const):
        return parser.check_next(s, tk.TokenKind.tk_function)
    return false


## Parse a method declaration after its attributes and visibility modifier.
## Shared by `extending` blocks and inline struct-body methods.
function parse_method_def(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool) -> ast.Method:
    var is_async = pstate.match_kind(s, tk.TokenKind.tk_async)
    var kind = ast.MethodKind.mk_plain
    if pstate.match_kind(s, tk.TokenKind.tk_editable):
        kind = ast.MethodKind.mk_editable
    else if pstate.match_kind(s, tk.TokenKind.tk_static):
        kind = ast.MethodKind.mk_static
    var is_const = pstate.match_kind(s, tk.TokenKind.tk_const)
    pstate.consume(s, tk.TokenKind.tk_function, c"expected function in extending block")
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    parser.consume_name(s, c"expected method name")
    let name = parser.previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    var lifetime_params = span[str]()
    if pstate.match_kind(s, tk.TokenKind.lbracket):
        let all_params = declarations.parse_declaration_type_params(s)
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
    let params = declarations.parse_params(s)
    var return_type: ptr[ast.TypeRef]? = null
    if pstate.match_kind(s, tk.TokenKind.arrow):
        return_type = declarations.parse_type_ref(s)
    let body = declarations.parse_block(s)
    return ast.Method(name = name, type_params = type_params, method_params = params,
        return_type = return_type, body = body, method_kind = kind, visibility = visibility,
        is_async = is_async, is_const = is_const, attributes = attrs, line = ln, column = cn)


public function parse_extern_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication]) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
    parser.consume_name(s, c"expected function name")
    let name = parser.previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    var lifetime_params = span[str]()
    if pstate.match_kind(s, tk.TokenKind.lbracket):
        let all_params = declarations.parse_declaration_type_params(s)
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
    let (params, variadic) = parse_foreign_params(s)
    var return_type: ptr[ast.TypeRef]? = null
    if pstate.match_kind(s, tk.TokenKind.arrow):
        return_type = declarations.parse_type_ref(s)
    var mapping: ptr[ast.Expr]? = null
    if pstate.match_kind(s, tk.TokenKind.equal):
        mapping = expressions.parse_expr(s)
    parser.consume_end_of_statement(s)
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_extern_function(name = name, type_params = type_params, extern_params = params,
            return_type = return_type, variadic = variadic, attrs = attrs, line = ln, mapping = mapping)
    return node


public function parse_foreign_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
    parser.consume_name(s, c"expected function name")
    let name = parser.previous_lexeme(s)
    var type_params = span[ast.TypeParam]()
    var lifetime_params = span[str]()
    if pstate.match_kind(s, tk.TokenKind.lbracket):
        let all_params = declarations.parse_declaration_type_params(s)
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
    let (params, variadic) = parse_foreign_params(s)
    pstate.consume(s, tk.TokenKind.arrow, c"expected '->' before foreign return type")
    let return_type = declarations.parse_type_ref(s)
    pstate.consume(s, tk.TokenKind.equal, c"expected '=' before foreign mapping")
    let mapping = expressions.parse_expr(s)
    parser.consume_end_of_statement(s)
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_foreign_function(name = name, type_params = type_params, foreign_params = params,
            return_type = return_type, variadic = variadic, mapping = mapping, visibility = visibility,
            attrs = attrs, line = ln)
    return node


function parse_foreign_params(s: ref[pstate.ParserState]) -> (span[ast.ForeignParam], bool):
    var params = vec.Vec[ast.ForeignParam].create()
    var variadic = false
    pstate.consume(s, tk.TokenKind.lparen, c"expected '('")
    while not parser.eof(s) and not pstate.check(s, tk.TokenKind.rparen):
        if pstate.match_kind(s, tk.TokenKind.ellipsis):
            variadic = true
            break
        var mode = ast.ForeignParamMode.fmode_plain
        if pstate.match_kind(s, tk.TokenKind.tk_out):
            mode = ast.ForeignParamMode.fmode_out
        else if pstate.match_kind(s, tk.TokenKind.tk_in):
            mode = ast.ForeignParamMode.fmode_in
        else if pstate.match_kind(s, tk.TokenKind.tk_inout):
            mode = ast.ForeignParamMode.fmode_inout
        else if pstate.match_kind(s, tk.TokenKind.tk_consuming):
            mode = ast.ForeignParamMode.fmode_consuming
        parser.consume_name(s, c"expected parameter name")
        let name = parser.previous_lexeme(s)
        pstate.consume(s, tk.TokenKind.colon, c"expected ':' after parameter name")
        let ptype = declarations.parse_type_ref(s)
        var boundary_type: Option[ast.TypeRef] = Option[ast.TypeRef].none
        if pstate.match_kind(s, tk.TokenKind.tk_as):
            let bt = declarations.parse_type_ref(s)
            unsafe:
                boundary_type = Option[ast.TypeRef].some(value = read(bt))
        unsafe:
            params.push(ast.ForeignParam(name = name, param_type = read(ptype), param_mode = mode,
                boundary_type = boundary_type))
        if not pstate.match_kind(s, tk.TokenKind.comma):
            break
    pstate.consume(s, tk.TokenKind.rparen, c"expected ')'")
    return (params.as_span(), variadic)


public function parse_static_assert(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
    pstate.consume(s, tk.TokenKind.lparen, c"expected '(' after static_assert")
    let condition = expressions.parse_expr(s)
    pstate.consume(s, tk.TokenKind.comma, c"expected ',' after condition")
    let message = expressions.parse_expr(s)
    pstate.consume(s, tk.TokenKind.rparen, c"expected ')'")
    parser.consume_end_of_statement(s)
    var node = parser.alloc_decl(s)
    read(node) = ast.Decl.decl_static_assert(condition = condition, message = message, line = ln)
    return node


public function parse_event_decl(s: ref[pstate.ParserState], attrs: span[ast.AttributeApplication], visibility: bool) -> ptr[ast.Decl]:
    let tok = pstate.peek(s)
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    if tok != null:
        unsafe:
            ln = read(tok).line
            cn = read(tok).column
    parser.consume_name(s, c"expected event name")
    let name = parser.previous_lexeme(s)
    pstate.consume(s, tk.TokenKind.lbracket, c"expected '[' after event name")
    pstate.consume(s, tk.TokenKind.integer, c"expected capacity")
    let capacity = int<-parser.parse_int_literal(parser.previous_lexeme(s))
    pstate.consume(s, tk.TokenKind.rbracket, c"expected ']'")
    var payload_type: ptr[ast.TypeRef]? = null
    if pstate.match_kind(s, tk.TokenKind.lparen):
        payload_type = declarations.parse_type_ref(s)
        pstate.consume(s, tk.TokenKind.rparen, c"expected ')'")
    parser.consume_end_of_statement(s)
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_event(name = name, capacity = capacity, payload_type = payload_type,
            visibility = visibility, attrs = attrs, line = ln, column = cn)
    return node


public function parse_when_decl(s: ref[pstate.ParserState]) -> ptr[ast.Decl]:
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    unsafe:
        ln = read(pstate.previous_token(s)).line
        cn = read(pstate.previous_token(s)).column
    let discriminant = expressions.parse_expr(s)
    pstate.consume(s, tk.TokenKind.colon, c"expected ':' after when discriminant")
    pstate.consume(s, tk.TokenKind.newline, c"expected newline after when header")
    pstate.consume(s, tk.TokenKind.indent, c"expected indented when body")
    parser.skip_newlines(s)
    var branches = vec.Vec[ast.WhenDeclBranch].create()
    var else_body = span[ast.Decl]()
    var has_else = false
    var carried_set = false
    var carried_line: ptr_uint = 0
    var carried_column: ptr_uint = 0
    while not parser.eof(s):
        if pstate.check(s, tk.TokenKind.dedent):
            break
        parser.skip_newlines(s)
        if pstate.check(s, tk.TokenKind.tk_else):
            pstate.advance(s)
            pstate.consume(s, tk.TokenKind.colon, c"expected ':' after else")
            else_body = parse_declaration_block(s)
            has_else = true
            break
        let pat = expressions.parse_expr(s)
        var binding: Option[str] = Option[str].none
        if pstate.match_kind(s, tk.TokenKind.tk_as):
            parser.consume_name(s, c"expected binding name after as")
            binding = Option[str].some(value = parser.previous_lexeme(s))
            unsafe:
                carried_line = read(pstate.previous_token(s)).line
                carried_column = read(pstate.previous_token(s)).column
            carried_set = true
        pstate.consume(s, tk.TokenKind.colon, c"expected ':' after when pattern")
        let body = parse_declaration_block(s)
        if not carried_set:
            # Host parity: `binding_token ||= previous` reuses the first
            # branch's token for later branches that omit `as`.
            unsafe:
                carried_line = read(pstate.previous_token(s)).line
                carried_column = read(pstate.previous_token(s)).column
            carried_set = true
        branches.push(ast.WhenDeclBranch(pattern = pat, binding_name = binding, binding_line = carried_line,
            binding_column = carried_column, body = body))
        parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of when body")
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_when(discriminant = discriminant, branches = branches.as_span(),
            else_body = else_body, has_else = has_else, line = ln, column = cn)
    return node


function parse_declaration_block(s: ref[pstate.ParserState]) -> span[ast.Decl]:
    pstate.consume(s, tk.TokenKind.newline, c"expected newline")
    pstate.consume(s, tk.TokenKind.indent, c"expected indented body")
    parser.skip_newlines(s)
    var decls = vec.Vec[ast.Decl].create()
    while not pstate.check(s, tk.TokenKind.dedent) and not parser.eof(s):
        pstate.step(s)
        let decl = parser.parse_decl(s)
        if s.panic:
            parser.recover_top_level(s)
        else:
            unsafe:
                decls.push(read(decl))
            drain_pending_decls(s, ref_of(decls))
        parser.skip_newlines(s)
    pstate.consume(s, tk.TokenKind.dedent, c"expected end of body")
    return decls.as_span()


public function parse_attribute_decl(s: ref[pstate.ParserState], visibility: bool) -> ptr[ast.Decl]:
    var ln: ptr_uint = 0
    var cn: ptr_uint = 0
    pstate.consume(s, tk.TokenKind.lbracket, c"expected '[' after attribute")
    var targets = vec.Vec[str].create()
    while true:
        parser.consume_name_allowing_keywords(s, c"expected attribute target")
        targets.push(parser.previous_lexeme(s))
        if not pstate.match_kind(s, tk.TokenKind.comma):
            break
    pstate.consume(s, tk.TokenKind.rbracket, c"expected ']'")
    parser.consume_name_allowing_keywords(s, c"expected attribute name")
    let name = parser.previous_lexeme(s)
    unsafe:
        ln = read(pstate.previous_token(s)).line
        cn = read(pstate.previous_token(s)).column
    var params = span[ast.Param]()
    if pstate.check(s, tk.TokenKind.lparen):
        params = parse_signature(s)
    parser.consume_end_of_statement(s)
    var node = parser.alloc_decl(s)
    unsafe:
        read(node) = ast.Decl.decl_attribute(name = name, targets = targets.as_span(), attr_params = params,
            visibility = visibility, line = ln, column = cn)
    return node


function parse_signature(s: ref[pstate.ParserState]) -> span[ast.Param]:
    var params = vec.Vec[ast.Param].create()
    pstate.consume(s, tk.TokenKind.lparen, c"expected '('")
    while not parser.eof(s) and not pstate.check(s, tk.TokenKind.rparen):
        let tok = pstate.peek(s)
        var ln: ptr_uint = 0
        var cn: ptr_uint = 0
        if tok != null:
            unsafe:
                ln = read(tok).line
                cn = read(tok).column
        parser.consume_name(s, c"expected parameter name")
        let name = parser.previous_lexeme(s)
        pstate.consume(s, tk.TokenKind.colon, c"expected ':' after parameter name")
        let ptype = declarations.parse_type_ref(s)
        unsafe:
            params.push(ast.Param(name = name, param_type = read(ptype), line = ln, column = cn, default_value = null))
        if not pstate.match_kind(s, tk.TokenKind.comma):
            break
    pstate.consume(s, tk.TokenKind.rparen, c"expected ')'")
    return params.as_span()
