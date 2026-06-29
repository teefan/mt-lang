import std.vec as vec

import lexer
import lexer.token as tok
import ast
import parser.blocks as blocks

public struct Parser:
    bp: blocks.BlockParser
    file_id: uint

extending Parser:
    public static function create(tokens: vec.Vec[tok.Token], file_id: uint) -> Parser:
        return Parser(bp = blocks.BlockParser.create(tokens), file_id = file_id)

    public editable function parse_file() -> ast.Module:
        var imports = vec.Vec[ast.AstDecl].create()
        var decls = vec.Vec[ast.AstDecl].create()
        while not this.bp.is_eof():
            this.bp.skip_newlines()
            if this.bp.is_eof():
                break
            if this.is_import():
                this.parse_import(imports)
            else:
                let decl = this.parse_declaration() else:
                    fatal(c"unexpected token in top-level")
                    break
                decls.push(decl)
        return ast.Module(imports = imports, declarations = decls, is_external = false, includes = vec.Vec[str].create(), links = vec.Vec[str].create())

    editable function is_import() -> bool:
        return this.bp.stream.check_keyword(tok.KeywordKind.kw_import)

    editable function parse_import(imports: ref[vec.Vec[ast.AstDecl]]) -> void:
        let _kw = this.bp.advance()
        var path = vec.Vec[str].create()
        var alias: str = ""
        let first = this.parse_ident()
        path.push(first)
        while this.bp.current_token().kind == tok.TokenKind.dot:
            let _dot = this.bp.advance()
            let part = this.parse_ident()
            path.push(part)
        if this.bp.stream.check_keyword(tok.KeywordKind.kw_as):
            let _as = this.bp.advance()
            alias = this.parse_ident()
        imports.push(ast.AstDecl.import_decl(module_path = path, alias = alias))

    editable function parse_declaration() -> Option[ast.AstDecl]:
        let tk = this.bp.current_token()
        if tk.kind == tok.TokenKind.keyword:
            let kw = tok.KeywordKind<-(tk.keyword_subkind)
            if kw == tok.KeywordKind.kw_function:
                return Option[ast.AstDecl].some(value = this.parse_function(false))
            else if kw == tok.KeywordKind.kw_external:
                let _ext = this.bp.advance()
                if this.bp.stream.check_keyword(tok.KeywordKind.kw_function):
                    return Option[ast.AstDecl].some(value = this.parse_external_function())
                return Option[ast.AstDecl].none
            else if kw == tok.KeywordKind.kw_const and this.peek_keyword(tok.KeywordKind.kw_function):
                return Option[ast.AstDecl].some(value = this.parse_const_function())
            else if kw == tok.KeywordKind.kw_const:
                return Option[ast.AstDecl].some(value = this.parse_const(false))
            else if kw == tok.KeywordKind.kw_struct:
                return Option[ast.AstDecl].some(value = this.parse_struct(false))
            else if kw == tok.KeywordKind.kw_enum:
                return Option[ast.AstDecl].some(value = this.parse_enum())
            else if kw == tok.KeywordKind.kw_flags:
                return Option[ast.AstDecl].some(value = this.parse_flags())
            else if kw == tok.KeywordKind.kw_union:
                return Option[ast.AstDecl].some(value = this.parse_union())
            else if kw == tok.KeywordKind.kw_variant:
                return Option[ast.AstDecl].some(value = this.parse_variant())
            else if kw == tok.KeywordKind.kw_interface:
                return Option[ast.AstDecl].some(value = this.parse_interface())
            else if kw == tok.KeywordKind.kw_opaque:
                return Option[ast.AstDecl].some(value = this.parse_opaque())
            else if kw == tok.KeywordKind.kw_extending:
                return Option[ast.AstDecl].some(value = this.parse_extending())
            else if kw == tok.KeywordKind.kw_type:
                return Option[ast.AstDecl].some(value = this.parse_type_alias(false))
            else if kw == tok.KeywordKind.kw_var:
                return Option[ast.AstDecl].some(value = this.parse_var_decl(false))
            else if kw == tok.KeywordKind.kw_public:
                let _pub = this.bp.advance()
                let next = this.bp.current_token()
                if next.kind == tok.TokenKind.keyword:
                    let nkw = tok.KeywordKind<-(next.keyword_subkind)
                    if nkw == tok.KeywordKind.kw_function:
                        return Option[ast.AstDecl].some(value = this.parse_function(true))
                    else if nkw == tok.KeywordKind.kw_const:
                        let _c = this.bp.advance()
                        if this.peek_keyword(tok.KeywordKind.kw_function):
                            return Option[ast.AstDecl].some(value = this.parse_public_const_function())
                        return Option[ast.AstDecl].some(value = this.parse_const(true))
                    else if nkw == tok.KeywordKind.kw_struct:
                        return Option[ast.AstDecl].some(value = this.parse_struct(true))
                    else if nkw == tok.KeywordKind.kw_var:
                        return Option[ast.AstDecl].some(value = this.parse_var_decl(true))
                return Option[ast.AstDecl].none
        return Option[ast.AstDecl].none

    # -- declaration parsers --

    editable function parse_function(is_public: bool) -> ast.AstDecl:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        let params = this.parse_params()
        let return_type = this.parse_return_type()
        this.expect_colon()
        let body = this.parse_block()
        return ast.AstDecl.function_decl(name = name, params = params, return_type = return_type, body = body, type_params = vec.Vec[ast.TypeParam].create(), is_async = false, is_const = false, is_public = is_public, docs = vec.Vec[str].create())

    editable function parse_external_function() -> ast.AstDecl:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        let params = this.parse_params()
        let return_type = this.parse_return_type()
        return ast.AstDecl.external_function_decl(name = name, params = params, return_type = return_type, is_variadic = false)

    editable function parse_const_function() -> ast.AstDecl:
        let _const = this.bp.advance()
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        let params = this.parse_params()
        let return_type = this.parse_return_type()
        this.expect_colon()
        let body = this.parse_block()
        return ast.AstDecl.function_decl(name = name, params = params, return_type = return_type, body = body, type_params = vec.Vec[ast.TypeParam].create(), is_async = false, is_const = true, is_public = false, docs = vec.Vec[str].create())

    editable function parse_public_const_function() -> ast.AstDecl:
        let _const = this.bp.advance()
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        let params = this.parse_params()
        let return_type = this.parse_return_type()
        this.expect_colon()
        let body = this.parse_block()
        return ast.AstDecl.function_decl(name = name, params = params, return_type = return_type, body = body, type_params = vec.Vec[ast.TypeParam].create(), is_async = false, is_const = true, is_public = true, docs = vec.Vec[str].create())

    editable function parse_const(is_public: bool) -> ast.AstDecl:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        this.expect(tok.TokenKind.colon)
        let type_ref = this.parse_type_ref()
        this.expect(tok.TokenKind.op_assign)
        let init = this.parse_expression()
        return ast.AstDecl.const_decl(name = name, type_ref = type_ref, init = init, is_public = is_public, docs = vec.Vec[str].create())

    editable function parse_struct(is_public: bool) -> ast.AstDecl:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        var type_params = vec.Vec[ast.TypeParam].create()
        var impls = vec.Vec[ast.TypeRef].create()
        var attrs = vec.Vec[ast.AttrApp].create()
        if this.bp.current_token().kind == tok.TokenKind.bracket_open:
            type_params = this.parse_type_params()
        if this.bp.stream.check_keyword(tok.KeywordKind.kw_implements):
            impls = this.parse_implements()
        this.expect_colon()
        let fields = this.parse_struct_fields()
        return ast.AstDecl.struct_decl(name = name, fields = fields, type_params = type_params, impls = impls, attrs = attrs, is_public = is_public, docs = vec.Vec[str].create())

    editable function parse_enum() -> ast.AstDecl:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        var backing_type: ast.TypeRef = ast.TypeRef.void_type
        if this.bp.current_token().kind == tok.TokenKind.colon:
            this.expect(tok.TokenKind.colon)
            backing_type = this.parse_type_ref()
        this.bp.skip_newlines()
        this.bp.enter_block()
        var members = vec.Vec[ast.EnumMember].create()
        while not this.bp.is_eof():
            this.bp.skip_newlines()
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.dedent:
                break
            let mname = this.parse_ident()
            var value: ast.AstExpr = ast.AstExpr.integer_literal(value_str = "0")
            if this.bp.current_token().kind == tok.TokenKind.op_assign:
                let _eq = this.bp.advance()
                value = this.parse_expression()
            members.push(ast.EnumMember(name = mname, value = value))
        this.bp.exit_block()
        return ast.AstDecl.enum_decl(name = name, backing_type = backing_type, members = members, attrs = vec.Vec[ast.AttrApp].create(), is_public = false)

    editable function parse_flags() -> ast.AstDecl:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        var backing_type: ast.TypeRef = ast.TypeRef.void_type
        if this.bp.current_token().kind == tok.TokenKind.colon:
            this.expect(tok.TokenKind.colon)
            backing_type = this.parse_type_ref()
        this.bp.skip_newlines()
        this.bp.enter_block()
        var members = vec.Vec[ast.FlagsMember].create()
        while not this.bp.is_eof():
            this.bp.skip_newlines()
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.dedent:
                break
            let mname = this.parse_ident()
            this.expect(tok.TokenKind.op_assign)
            let value = this.parse_expression()
            members.push(ast.FlagsMember(name = mname, value = value))
        this.bp.exit_block()
        return ast.AstDecl.flags_decl(name = name, backing_type = backing_type, members = members, attrs = vec.Vec[ast.AttrApp].create(), is_public = false)

    editable function parse_union() -> ast.AstDecl:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        this.expect_colon()
        let fields = this.parse_struct_fields()
        return ast.AstDecl.union_decl(name = name, fields = fields, attrs = vec.Vec[ast.AttrApp].create(), is_public = false)

    editable function parse_variant() -> ast.AstDecl:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        var type_params = vec.Vec[ast.TypeParam].create()
        if this.bp.current_token().kind == tok.TokenKind.bracket_open:
            type_params = this.parse_type_params()
        this.expect_colon()
        this.bp.skip_newlines()
        this.bp.enter_block()
        var arms = vec.Vec[ast.VariantArm].create()
        while not this.bp.is_eof():
            this.bp.skip_newlines()
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.dedent:
                break
            let arm_name = this.parse_ident()
            var arm_fields = vec.Vec[ast.StructField].create()
            if this.bp.current_token().kind == tok.TokenKind.paren_open:
                arm_fields = this.parse_variant_arm_fields()
            arms.push(ast.VariantArm(name = arm_name, fields = arm_fields))
        this.bp.exit_block()
        return ast.AstDecl.variant_decl(name = name, arms = arms, type_params = type_params, attrs = vec.Vec[ast.AttrApp].create(), is_public = false)

    editable function parse_variant_arm_fields() -> vec.Vec[ast.StructField]:
        let _open = this.bp.advance()
        var fields = vec.Vec[ast.StructField].create()
        while not this.bp.is_eof():
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.paren_close:
                let _close = this.bp.advance()
                return fields
            let fname = this.parse_ident()
            this.expect(tok.TokenKind.colon)
            let ftype = this.parse_type_ref()
            fields.push(ast.StructField(name = fname, type_ref = ftype, nested_structs = vec.Vec[ast.AstDecl].create(), attrs = vec.Vec[ast.AttrApp].create()))
            if this.bp.current_token().kind == tok.TokenKind.comma:
                let _comma = this.bp.advance()
        return fields

    editable function parse_interface() -> ast.AstDecl:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        var type_params = vec.Vec[ast.TypeParam].create()
        if this.bp.current_token().kind == tok.TokenKind.bracket_open:
            type_params = this.parse_type_params()
        this.bp.skip_newlines()
        this.bp.enter_block()
        var methods = vec.Vec[ast.IfaceMethod].create()
        while not this.bp.is_eof():
            this.bp.skip_newlines()
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.dedent:
                break
            var kind: ast.IfaceMethodKind = ast.IfaceMethodKind.iface_fn
            if this.bp.stream.check_keyword(tok.KeywordKind.kw_editable):
                let _e = this.bp.advance()
                kind = ast.IfaceMethodKind.iface_edit
            else if this.bp.stream.check_keyword(tok.KeywordKind.kw_static):
                let _s = this.bp.advance()
                kind = ast.IfaceMethodKind.iface_static
            let _fn = this.bp.advance()
            let mname = this.parse_ident()
            let params = this.parse_params()
            let return_type = this.parse_return_type()
            methods.push(ast.IfaceMethod(kind = kind, name = mname, params = params, return_type = return_type))
        this.bp.exit_block()
        return ast.AstDecl.interface_decl(name = name, methods = methods, type_params = type_params, is_public = false)

    editable function parse_opaque() -> ast.AstDecl:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        var impls = vec.Vec[ast.TypeRef].create()
        if this.bp.stream.check_keyword(tok.KeywordKind.kw_implements):
            impls = this.parse_implements()
        return ast.AstDecl.opaque_decl(name = name, impls = impls, attrs = vec.Vec[ast.AttrApp].create(), is_public = false)

    editable function parse_extending() -> ast.AstDecl:
        let _kw = this.bp.advance()
        let target = this.parse_type_ref()
        this.expect_colon()
        this.bp.enter_block()
        var methods = vec.Vec[ast.AstDecl].create()
        while not this.bp.is_eof():
            this.bp.skip_newlines()
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.dedent:
                break
            let decl = this.parse_declaration() else:
                fatal(c"expected method declaration in extending block")
                break
            methods.push(decl)
        this.bp.exit_block()
        return ast.AstDecl.extending_block(target_type = target, methods = methods)

    editable function parse_type_alias(is_public: bool) -> ast.AstDecl:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        this.expect(tok.TokenKind.op_assign)
        let type_ref = this.parse_type_ref()
        return ast.AstDecl.type_alias(name = name, type_ref = type_ref, is_public = is_public)

    editable function parse_var_decl(is_public: bool) -> ast.AstDecl:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        this.expect(tok.TokenKind.colon)
        let type_ref = this.parse_type_ref()
        var init: ast.AstExpr = ast.AstExpr.integer_literal(value_str = "0")
        if this.bp.current_token().kind == tok.TokenKind.op_assign:
            let _eq = this.bp.advance()
            init = this.parse_expression()
        return ast.AstDecl.var_decl(name = name, type_ref = type_ref, init = init, is_public = is_public)

    editable function parse_struct_fields() -> vec.Vec[ast.StructField]:
        this.bp.skip_newlines()
        this.bp.enter_block()
        var fields = vec.Vec[ast.StructField].create()
        while not this.bp.is_eof():
            this.bp.skip_newlines()
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.dedent:
                break
            let fname = this.parse_ident()
            this.expect(tok.TokenKind.colon)
            let ftype = this.parse_type_ref()
            fields.push(ast.StructField(name = fname, type_ref = ftype, nested_structs = vec.Vec[ast.AstDecl].create(), attrs = vec.Vec[ast.AttrApp].create()))
        this.bp.exit_block()
        return fields

    editable function parse_type_params() -> vec.Vec[ast.TypeParam]:
        let _open = this.bp.advance()
        var params = vec.Vec[ast.TypeParam].create()
        while not this.bp.is_eof():
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.bracket_close:
                let _close = this.bp.advance()
                return params
            let pname = this.parse_ident()
            var kind: ast.TypeParamKind = ast.TypeParamKind.tp_type
            var constraints = vec.Vec[ast.TypeRef].create()
            if this.bp.current_token().kind == tok.TokenKind.colon:
                this.expect(tok.TokenKind.colon)
                let _ct = this.parse_type_ref()
                kind = ast.TypeParamKind.tp_value
            else if this.bp.stream.check_keyword(tok.KeywordKind.kw_implements):
                let _impl = this.bp.advance()
                let first = this.parse_type_ref()
                constraints.push(first)
                while this.bp.stream.check_keyword(tok.KeywordKind.kw_and):
                    let _and = this.bp.advance()
                    let next = this.parse_type_ref()
                    constraints.push(next)
            params.push(ast.TypeParam(name = pname, kind = kind, constraints = constraints))
            if this.bp.current_token().kind == tok.TokenKind.comma:
                let _comma = this.bp.advance()
            else:
                break
        this.expect(tok.TokenKind.bracket_close)
        return params

    editable function parse_implements() -> vec.Vec[ast.TypeRef]:
        let _kw = this.bp.advance()
        var impls = vec.Vec[ast.TypeRef].create()
        let first = this.parse_type_ref()
        impls.push(first)
        while this.bp.current_token().kind == tok.TokenKind.comma:
            let _comma = this.bp.advance()
            let next = this.parse_type_ref()
            impls.push(next)
        return impls

    editable function parse_params() -> vec.Vec[ast.Param]:
        this.expect(tok.TokenKind.paren_open)
        var params = vec.Vec[ast.Param].create()
        while not this.bp.is_eof():
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.paren_close:
                let _close = this.bp.advance()
                return params
            if tk.kind == tok.TokenKind.ellipsis:
                let _e = this.bp.advance()
                this.expect(tok.TokenKind.paren_close)
                return params
            let pname = this.parse_ident()
            this.expect(tok.TokenKind.colon)
            let ptype = this.parse_type_ref()
            params.push(ast.Param(name = pname, type_ref = ptype))
            if this.bp.current_token().kind == tok.TokenKind.comma:
                let _comma = this.bp.advance()
            else:
                break
        this.expect(tok.TokenKind.paren_close)
        return params

    editable function parse_return_type() -> ast.TypeRef:
        if this.bp.current_token().kind == tok.TokenKind.arrow:
            let _arrow = this.bp.advance()
            return this.parse_type_ref()
        return ast.TypeRef.void_type

    editable function parse_type_ref() -> ast.TypeRef:
        let tk = this.bp.current_token()
        if tk.kind == tok.TokenKind.keyword:
            let kw = tok.KeywordKind<-(tk.keyword_subkind)
            if kw == tok.KeywordKind.kw_ptr:
                let _p = this.bp.advance()
                this.expect(tok.TokenKind.bracket_open)
                let inner = this.parse_type_ref()
                this.expect(tok.TokenKind.bracket_close)
                var result = ast.TypeRef.ptr_type(pointee = inner)
                return this.parse_nullable_suffix(result)
            else if kw == tok.KeywordKind.kw_const_ptr:
                let _p = this.bp.advance()
                this.expect(tok.TokenKind.bracket_open)
                let inner = this.parse_type_ref()
                this.expect(tok.TokenKind.bracket_close)
                var result = ast.TypeRef.const_ptr_type(pointee = inner)
                return this.parse_nullable_suffix(result)
            else if kw == tok.KeywordKind.kw_ref:
                let _r = this.bp.advance()
                this.expect(tok.TokenKind.bracket_open)
                let inner = this.parse_type_ref()
                this.expect(tok.TokenKind.bracket_close)
                var result = ast.TypeRef.ref_type(pointee = inner, lifetime = "")
                return this.parse_nullable_suffix(result)
            else if kw == tok.KeywordKind.kw_span:
                let _s = this.bp.advance()
                this.expect(tok.TokenKind.bracket_open)
                let inner = this.parse_type_ref()
                this.expect(tok.TokenKind.bracket_close)
                var result = ast.TypeRef.span_type(element = inner)
                return this.parse_nullable_suffix(result)
            else if kw == tok.KeywordKind.kw_array:
                let _a = this.bp.advance()
                this.expect(tok.TokenKind.bracket_open)
                let inner = this.parse_type_ref()
                this.expect(tok.TokenKind.comma)
                let _sz_tk = this.bp.advance()
                this.expect(tok.TokenKind.bracket_close)
                var result = ast.TypeRef.array_type(element = inner, size = 0u)
                return this.parse_nullable_suffix(result)
            else if kw == tok.KeywordKind.kw_fn:
                let _f = this.bp.advance()
                this.expect(tok.TokenKind.paren_open)
                var fn_params = vec.Vec[ast.FnParam].create()
                while not this.bp.is_eof():
                    let ftk = this.bp.current_token()
                    if ftk.kind == tok.TokenKind.paren_close:
                        break
                    let pname = this.parse_ident()
                    this.expect(tok.TokenKind.colon)
                    let ptype = this.parse_type_ref()
                    fn_params.push(ast.FnParam(name = pname, type_ref = ptype))
                    if this.bp.current_token().kind == tok.TokenKind.comma:
                        let _c = this.bp.advance()
                this.expect(tok.TokenKind.paren_close)
                this.expect(tok.TokenKind.arrow)
                let ret = this.parse_type_ref()
                var result = ast.TypeRef.fn_type(params = fn_params, return_type = ret)
                return this.parse_nullable_suffix(result)
        let name = this.parse_ident()
        var result = ast.TypeRef.named(name = name, type_args = vec.Vec[ast.TypeRef].create())
        return this.parse_nullable_suffix(result)

    editable function parse_nullable_suffix(base: ast.TypeRef) -> ast.TypeRef:
        if this.bp.current_token().kind == tok.TokenKind.question_mark:
            let _q = this.bp.advance()
            return ast.TypeRef.nullable_type(inner = base)
        return base

    editable function parse_block() -> vec.Vec[ast.AstStmt]:
        var stmts = vec.Vec[ast.AstStmt].create()
        this.bp.skip_newlines()
        this.bp.enter_block()
        while not this.bp.is_eof():
            this.bp.skip_newlines()
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.dedent:
                break
            let stmt = this.parse_statement() else:
                break
            stmts.push(stmt)
        this.bp.exit_block()
        return stmts

    editable function parse_statement() -> Option[ast.AstStmt]:
        let tk = this.bp.current_token()
        if tk.kind == tok.TokenKind.keyword:
            let kw = tok.KeywordKind<-(tk.keyword_subkind)
            if kw == tok.KeywordKind.kw_return:
                return Option[ast.AstStmt].some(value = this.parse_return())
            else if kw == tok.KeywordKind.kw_let:
                return Option[ast.AstStmt].some(value = this.parse_let())
            else if kw == tok.KeywordKind.kw_var:
                return Option[ast.AstStmt].some(value = this.parse_var())
            else if kw == tok.KeywordKind.kw_if:
                return Option[ast.AstStmt].some(value = this.parse_if())
            else if kw == tok.KeywordKind.kw_while:
                return Option[ast.AstStmt].some(value = this.parse_while())
            else if kw == tok.KeywordKind.kw_for:
                return Option[ast.AstStmt].some(value = this.parse_for())
            else if kw == tok.KeywordKind.kw_break:
                let _b = this.bp.advance()
                return Option[ast.AstStmt].some(value = ast.AstStmt.break_stmt)
            else if kw == tok.KeywordKind.kw_continue:
                let _c = this.bp.advance()
                return Option[ast.AstStmt].some(value = ast.AstStmt.continue_stmt)
            else if kw == tok.KeywordKind.kw_pass:
                let _p = this.bp.advance()
                return Option[ast.AstStmt].some(value = ast.AstStmt.pass_stmt)
            else if kw == tok.KeywordKind.kw_defer:
                return Option[ast.AstStmt].some(value = this.parse_defer())
            else if kw == tok.KeywordKind.kw_unsafe:
                return Option[ast.AstStmt].some(value = this.parse_unsafe())
            else if kw == tok.KeywordKind.kw_match:
                return Option[ast.AstStmt].some(value = this.parse_match())
            else if kw == tok.KeywordKind.kw_when:
                return Option[ast.AstStmt].some(value = this.parse_when())
            else if kw == tok.KeywordKind.kw_inline:
                return this.parse_inline()
        let expr = this.parse_expression()
        return Option[ast.AstStmt].some(value = ast.AstStmt.expr_stmt(expr = expr))

    editable function parse_return() -> ast.AstStmt:
        let _kw = this.bp.advance()
        var value: ast.AstExpr = ast.AstExpr.integer_literal(value_str = "0")
        let tk = this.bp.current_token()
        if tk.kind != tok.TokenKind.newline and tk.kind != tok.TokenKind.dedent and tk.kind != tok.TokenKind.eof:
            value = this.parse_expression()
        return ast.AstStmt.return_stmt(value = value)

    editable function parse_let() -> ast.AstStmt:
        let _kw = this.bp.advance()
        if this.bp.current_token().lexeme == "_":
            let _discard = this.bp.advance()
            this.expect(tok.TokenKind.op_assign)
            let init = this.parse_expression()
            var else_block: vec.Vec[ast.AstStmt] = vec.Vec[ast.AstStmt].create()
            if this.bp.stream.check_keyword(tok.KeywordKind.kw_else):
                let _else = this.bp.advance()
                this.expect_colon()
                else_block = this.parse_block()
            return ast.AstStmt.let_discard(init = init, else_block = else_block)
        let name = this.parse_ident()
        var type_ref: ast.TypeRef = ast.TypeRef.void_type
        if this.bp.current_token().kind == tok.TokenKind.colon:
            this.expect(tok.TokenKind.colon)
            type_ref = this.parse_type_ref()
        this.expect(tok.TokenKind.op_assign)
        let init = this.parse_expression()
        var else_block: vec.Vec[ast.AstStmt] = vec.Vec[ast.AstStmt].create()
        var else_error: str = ""
        if this.bp.stream.check_keyword(tok.KeywordKind.kw_else):
            let _else = this.bp.advance()
            if this.bp.stream.check_keyword(tok.KeywordKind.kw_as):
                let _as = this.bp.advance()
                else_error = this.parse_ident()
            this.expect_colon()
            else_block = this.parse_block()
        return ast.AstStmt.let_stmt(name = name, type_ref = type_ref, init = init, else_block = else_block, else_error_binding = else_error)

    editable function parse_var() -> ast.AstStmt:
        let _kw = this.bp.advance()
        let name = this.parse_ident()
        var type_ref: ast.TypeRef = ast.TypeRef.void_type
        if this.bp.current_token().kind == tok.TokenKind.colon:
            this.expect(tok.TokenKind.colon)
            type_ref = this.parse_type_ref()
        var init: ast.AstExpr = ast.AstExpr.integer_literal(value_str = "0")
        var else_block: vec.Vec[ast.AstStmt] = vec.Vec[ast.AstStmt].create()
        var else_error: str = ""
        if this.bp.current_token().kind == tok.TokenKind.op_assign:
            let _eq = this.bp.advance()
            init = this.parse_expression()
            if this.bp.stream.check_keyword(tok.KeywordKind.kw_else):
                let _else = this.bp.advance()
                if this.bp.stream.check_keyword(tok.KeywordKind.kw_as):
                    let _as = this.bp.advance()
                    else_error = this.parse_ident()
                this.expect_colon()
                else_block = this.parse_block()
        return ast.AstStmt.var_stmt(name = name, type_ref = type_ref, init = init, else_block = else_block, else_error_binding = else_error)

    editable function parse_if() -> ast.AstStmt:
        let _kw = this.bp.advance()
        let condition = this.parse_expression()
        this.expect_colon()
        var then_body: vec.Vec[ast.AstStmt] = vec.Vec[ast.AstStmt].create()
        var elifs = vec.Vec[ast.ElifBranch].create()
        var else_body: vec.Vec[ast.AstStmt] = vec.Vec[ast.AstStmt].create()
        this.bp.skip_newlines()
        if not this.bp.stream.check(tok.TokenKind.indent):
            let then_stmt = this.parse_statement() else:
                fatal(c"expected statement after inline if")
            var else_stmt: ast.AstStmt = ast.AstStmt.pass_stmt
            if this.bp.stream.check_keyword(tok.KeywordKind.kw_else_if):
                let _eif = this.bp.advance()
                let _eif_cond = this.parse_expression()
                this.expect_colon()
                let _stmt = this.parse_statement() else:
                    fatal(c"expected statement after inline else if")
            else if this.bp.stream.check_keyword(tok.KeywordKind.kw_else):
                let _else = this.bp.advance()
                this.expect_colon()
                let stmt_opt = this.parse_statement() else:
                    fatal(c"expected statement after inline else")
                else_stmt = stmt_opt
            return ast.AstStmt.if_inline(condition = condition, then_stmt = then_stmt, else_stmt = else_stmt)
        then_body = this.parse_block()
        while this.bp.stream.check_keyword(tok.KeywordKind.kw_else_if):
            let _eif = this.bp.advance()
            let eif_cond = this.parse_expression()
            this.expect_colon()
            let eif_body = this.parse_block()
            elifs.push(ast.ElifBranch(condition = eif_cond, body = eif_body))
        if this.bp.stream.check_keyword(tok.KeywordKind.kw_else):
            let _else = this.bp.advance()
            this.expect_colon()
            else_body = this.parse_block()
        return ast.AstStmt.if_stmt(condition = condition, then_body = then_body, elifs = elifs, else_body = else_body)

    editable function parse_block_body_only() -> vec.Vec[ast.AstStmt]:
        var stmts = vec.Vec[ast.AstStmt].create()
        while not this.bp.is_eof():
            this.bp.skip_newlines()
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.dedent or tk.kind == tok.TokenKind.eof:
                break
            let stmt = this.parse_statement() else:
                break
            stmts.push(stmt)
        return stmts

    editable function parse_while() -> ast.AstStmt:
        let _kw = this.bp.advance()
        let condition = this.parse_expression()
        this.expect_colon()
        let body = this.parse_block()
        return ast.AstStmt.while_stmt(condition = condition, body = body)

    editable function parse_for() -> ast.AstStmt:
        let _kw = this.bp.advance()
        let binding = this.parse_ident()
        if this.bp.stream.check_keyword(tok.KeywordKind.kw_in):
            let _in = this.bp.advance()
            let start = this.parse_expression()
            this.expect(tok.TokenKind.dot)
            this.expect(tok.TokenKind.dot)
            let end = this.parse_expression()
            this.expect_colon()
            let body = this.parse_block()
            return ast.AstStmt.for_range_literal(binding = binding, start = start, end = end, body = body)
        return ast.AstStmt.pass_stmt

    editable function parse_defer() -> ast.AstStmt:
        let _kw = this.bp.advance()
        if this.bp.current_token().kind == tok.TokenKind.colon:
            let _col = this.bp.advance()
            let body = this.parse_block()
            return ast.AstStmt.defer_stmt(stmts = body)
        let expr = this.parse_expression()
        return ast.AstStmt.defer_expr(expr = expr)

    editable function parse_unsafe() -> ast.AstStmt:
        let _kw = this.bp.advance()
        if this.bp.current_token().kind == tok.TokenKind.colon:
            let _col = this.bp.advance()
            let body = this.parse_block()
            return ast.AstStmt.unsafe_block(body = body)
        this.expect_colon()
        let expr = this.parse_expression()
        return ast.AstStmt.unsafe_expr(expr = expr)

    editable function parse_match() -> ast.AstStmt:
        let _kw = this.bp.advance()
        let scrutinee = this.parse_expression()
        this.expect_colon()
        this.bp.skip_newlines()
        this.bp.enter_block()
        var arms = vec.Vec[ast.MatchArm].create()
        while not this.bp.is_eof():
            this.bp.skip_newlines()
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.dedent:
                break
            let patterns = this.parse_match_patterns()
            this.expect_colon()
            let body = this.parse_block()
            arms.push(ast.MatchArm(patterns = patterns, body = body))
        this.bp.exit_block()
        return ast.AstStmt.match_stmt(scrutinee = scrutinee, arms = arms)

    editable function parse_match_patterns() -> vec.Vec[ast.MatchArmPatternKind]:
        var patterns = vec.Vec[ast.MatchArmPatternKind].create()
        let pat = this.parse_single_match_pattern()
        patterns.push(pat)
        while this.bp.current_token().kind == tok.TokenKind.op_bit_or:
            let _pipe = this.bp.advance()
            let next = this.parse_single_match_pattern()
            patterns.push(next)
        return patterns

    editable function parse_single_match_pattern() -> ast.MatchArmPatternKind:
        let tk = this.bp.current_token()
        if tk.lexeme == "_":
            let _w = this.bp.advance()
            return ast.MatchArmPatternKind.wildcard_p
        if tk.kind == tok.TokenKind.integer_literal:
            let _i = this.bp.advance()
            return ast.MatchArmPatternKind.integer_literal_p(value = tk.lexeme)
        if tk.kind == tok.TokenKind.string_literal:
            let _s = this.bp.advance()
            return ast.MatchArmPatternKind.string_literal_p(value = tk.lexeme)
        if tk.kind == tok.TokenKind.char_literal:
            let _c = this.bp.advance()
            return ast.MatchArmPatternKind.char_literal_p(value = tk.lexeme)
        let first = this.parse_ident()
        if this.bp.current_token().kind == tok.TokenKind.dot:
            let _dot = this.bp.advance()
            let second = this.parse_ident()
            if this.bp.current_token().kind == tok.TokenKind.dot:
                let _dot2 = this.bp.advance()
                let third = this.parse_ident()
                var fields = vec.Vec[ast.StructPatternField].create()
                if this.bp.current_token().kind == tok.TokenKind.paren_open:
                    fields = this.parse_pattern_fields()
                var payload_bind: str = ""
                if this.bp.stream.check_keyword(tok.KeywordKind.kw_as):
                    let _as = this.bp.advance()
                    payload_bind = this.parse_ident()
                return ast.MatchArmPatternKind.variant_arm_p(variant_name = first, arm_name = third, payload_bind = payload_bind, struct_fields = fields)
            var payload_bind2: str = ""
            if this.bp.stream.check_keyword(tok.KeywordKind.kw_as):
                let _as = this.bp.advance()
                payload_bind2 = this.parse_ident()
            if this.bp.current_token().kind == tok.TokenKind.paren_open:
                var fields = this.parse_pattern_fields()
                return ast.MatchArmPatternKind.variant_arm_p(variant_name = first, arm_name = second, payload_bind = payload_bind2, struct_fields = fields)
            return ast.MatchArmPatternKind.enum_member_p(enum_name = first, member_name = second)
        if this.bp.current_token().kind == tok.TokenKind.paren_open:
            var fields = this.parse_pattern_fields()
            return ast.MatchArmPatternKind.variant_arm_p(variant_name = "", arm_name = first, payload_bind = "", struct_fields = fields)
        return ast.MatchArmPatternKind.wildcard_p

    editable function parse_pattern_fields() -> vec.Vec[ast.StructPatternField]:
        let _open = this.bp.advance()
        var fields = vec.Vec[ast.StructPatternField].create()
        while not this.bp.is_eof():
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.paren_close:
                let _close = this.bp.advance()
                return fields
            if tk.lexeme == "_":
                let _d = this.bp.advance()
                fields.push(ast.StructPatternField(kind = ast.StructPatternFieldKind.discard))
            else:
                let fname = this.parse_ident()
                if this.bp.stream.check_keyword(tok.KeywordKind.kw_as):
                    let _as = this.bp.advance()
                    let alias = this.parse_ident()
                    fields.push(ast.StructPatternField(kind = ast.StructPatternFieldKind.bind(name = alias)))
                else if this.bp.current_token().kind == tok.TokenKind.op_assign:
                    let _eq = this.bp.advance()
                    let value = this.parse_expression()
                    fields.push(ast.StructPatternField(kind = ast.StructPatternFieldKind.equality(name = fname, expr = value)))
                else if this.is_operator(this.bp.current_token()):
                    let op = this.bp.current_token().lexeme
                    let _op = this.bp.advance()
                    let value = this.parse_expression()
                    fields.push(ast.StructPatternField(kind = ast.StructPatternFieldKind.guard(name = fname, op = op, expr = value)))
                else:
                    fields.push(ast.StructPatternField(kind = ast.StructPatternFieldKind.bind(name = fname)))
            if this.bp.current_token().kind == tok.TokenKind.comma:
                let _comma = this.bp.advance()
        this.expect(tok.TokenKind.paren_close)
        return fields

    editable function is_operator(tk: tok.Token) -> bool:
        return tk.kind == tok.TokenKind.op_eq or tk.kind == tok.TokenKind.op_ne or tk.kind == tok.TokenKind.op_lt or tk.kind == tok.TokenKind.op_le or tk.kind == tok.TokenKind.op_gt or tk.kind == tok.TokenKind.op_ge

    editable function parse_when() -> ast.AstStmt:
        let _kw = this.bp.advance()
        let discriminant = this.parse_expression()
        this.expect_colon()
        this.bp.enter_block()
        var branches = vec.Vec[ast.WhenBranch].create()
        var else_branch = vec.Vec[ast.AstStmt].create()
        while not this.bp.is_eof():
            this.bp.skip_newlines()
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.dedent:
                break
            if tk.lexeme == "_":
                let _w = this.bp.advance()
                this.expect_colon()
                else_branch = this.parse_block()
                continue
            let values = this.parse_expression_list()
            this.expect_colon()
            let body = this.parse_block()
            branches.push(ast.WhenBranch(values = values, body = body))
        this.bp.exit_block()
        return ast.AstStmt.when_stmt(discriminant = discriminant, branches = branches, else_branch = else_branch)

    editable function parse_expression_list() -> vec.Vec[ast.AstExpr]:
        var list = vec.Vec[ast.AstExpr].create()
        let first = this.parse_expression()
        list.push(first)
        while this.bp.current_token().kind == tok.TokenKind.op_bit_or:
            let _pipe = this.bp.advance()
            let next = this.parse_expression()
            list.push(next)
        return list

    editable function parse_inline() -> Option[ast.AstStmt]:
        let _kw = this.bp.advance()
        let tk = this.bp.current_token()
        if tk.kind == tok.TokenKind.keyword:
            let kw = tok.KeywordKind<-(tk.keyword_subkind)
            if kw == tok.KeywordKind.kw_for:
                let _f = this.bp.advance()
                this.parse_inline_for_body()
            else if kw == tok.KeywordKind.kw_while:
                let _w = this.bp.advance()
                this.parse_inline_while_body()
            else if kw == tok.KeywordKind.kw_match:
                let _m = this.bp.advance()
                this.parse_inline_match_body()
            else if kw == tok.KeywordKind.kw_if:
                let _i = this.bp.advance()
                this.parse_inline_if_body()
        return Option[ast.AstStmt].some(value = ast.AstStmt.pass_stmt)

    editable function parse_inline_for_body() -> void:
        let _binding = this.parse_ident()
        if this.bp.stream.check_keyword(tok.KeywordKind.kw_in):
            let _in = this.bp.advance()
            let _iterable = this.parse_expression()
        this.expect_colon()
        this.parse_block()

    editable function parse_inline_while_body() -> void:
        let _cond = this.parse_expression()
        this.expect_colon()
        this.parse_block()

    editable function parse_inline_match_body() -> void:
        let _scrutinee = this.parse_expression()
        this.bp.skip_newlines()
        this.bp.enter_block()
        this.bp.exit_block()

    editable function parse_inline_if_body() -> void:
        let _cond = this.parse_expression()
        this.expect_colon()
        this.parse_block()
        if this.bp.stream.check_keyword(tok.KeywordKind.kw_else):
            let _else = this.bp.advance()
            this.expect_colon()
            this.parse_block()

    editable function parse_expression() -> ast.AstExpr:
        return this.parse_assignment()

    editable function parse_assignment() -> ast.AstExpr:
        let left = this.parse_or()
        let tk = this.bp.current_token()
        if tk.kind == tok.TokenKind.op_assign:
            let _eq = this.bp.advance()
            let right = this.parse_or()
            return ast.AstExpr.binary(op = "=", left = left, right = right)
        return left

    editable function parse_or() -> ast.AstExpr:
        var left = this.parse_and()
        while this.bp.stream.check(tok.TokenKind.op_or):
            let _op = this.bp.advance()
            let right = this.parse_and()
            left = ast.AstExpr.binary(op = "or", left = left, right = right)
        return left

    editable function parse_and() -> ast.AstExpr:
        var left = this.parse_comparison()
        while this.bp.stream.check(tok.TokenKind.op_and):
            let _op = this.bp.advance()
            let right = this.parse_comparison()
            left = ast.AstExpr.binary(op = "and", left = left, right = right)
        return left

    editable function parse_comparison() -> ast.AstExpr:
        var left = this.parse_bitwise_or()
        while true:
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.op_eq or tk.kind == tok.TokenKind.op_ne:
                let op = tk.lexeme
                let _ = this.bp.advance()
                let right = this.parse_bitwise_or()
                left = ast.AstExpr.binary(op = op, left = left, right = right)
            else if tk.kind == tok.TokenKind.op_lt or tk.kind == tok.TokenKind.op_le:
                let op = tk.lexeme
                let _ = this.bp.advance()
                let right = this.parse_bitwise_or()
                left = ast.AstExpr.binary(op = op, left = left, right = right)
            else if tk.kind == tok.TokenKind.op_gt or tk.kind == tok.TokenKind.op_ge:
                let op = tk.lexeme
                let _ = this.bp.advance()
                let right = this.parse_bitwise_or()
                left = ast.AstExpr.binary(op = op, left = left, right = right)
            else:
                break
        return left

    editable function parse_bitwise_or() -> ast.AstExpr:
        var left = this.parse_bitwise_xor()
        while this.bp.stream.check(tok.TokenKind.op_bit_or):
            let _op = this.bp.advance()
            let right = this.parse_bitwise_xor()
            left = ast.AstExpr.binary(op = "|", left = left, right = right)
        return left

    editable function parse_bitwise_xor() -> ast.AstExpr:
        var left = this.parse_bitwise_and()
        while this.bp.stream.check(tok.TokenKind.op_bit_xor):
            let _op = this.bp.advance()
            let right = this.parse_bitwise_and()
            left = ast.AstExpr.binary(op = "^", left = left, right = right)
        return left

    editable function parse_bitwise_and() -> ast.AstExpr:
        var left = this.parse_shift()
        while this.bp.stream.check(tok.TokenKind.op_bit_and):
            let _op = this.bp.advance()
            let right = this.parse_shift()
            left = ast.AstExpr.binary(op = "&", left = left, right = right)
        return left

    editable function parse_shift() -> ast.AstExpr:
        var left = this.parse_additive()
        while this.bp.stream.check(tok.TokenKind.op_shl) or this.bp.stream.check(tok.TokenKind.op_shr):
            let op_tk = this.bp.advance()
            let op = op_tk.lexeme
            let right = this.parse_additive()
            left = ast.AstExpr.binary(op = op, left = left, right = right)
        return left

    editable function parse_additive() -> ast.AstExpr:
        var left = this.parse_multiplicative()
        while this.bp.stream.check(tok.TokenKind.op_add) or this.bp.stream.check(tok.TokenKind.op_sub):
            let op_tk = this.bp.advance()
            let op = op_tk.lexeme
            let right = this.parse_multiplicative()
            left = ast.AstExpr.binary(op = op, left = left, right = right)
        return left

    editable function parse_multiplicative() -> ast.AstExpr:
        var left = this.parse_unary()
        while this.bp.stream.check(tok.TokenKind.op_mul) or this.bp.stream.check(tok.TokenKind.op_div) or this.bp.stream.check(tok.TokenKind.op_mod):
            let op_tk = this.bp.advance()
            let op = op_tk.lexeme
            let right = this.parse_unary()
            left = ast.AstExpr.binary(op = op, left = left, right = right)
        return left

    editable function parse_unary() -> ast.AstExpr:
        let tk = this.bp.current_token()
        if tk.kind == tok.TokenKind.op_sub:
            let _ = this.bp.advance()
            let operand = this.parse_unary()
            return ast.AstExpr.unary(op = "-", operand = operand)
        else if tk.kind == tok.TokenKind.op_bit_not:
            let _ = this.bp.advance()
            let operand = this.parse_unary()
            return ast.AstExpr.unary(op = "~", operand = operand)
        else if tk.kind == tok.TokenKind.op_not:
            let _ = this.bp.advance()
            let operand = this.parse_unary()
            return ast.AstExpr.unary(op = "not", operand = operand)
        return this.parse_postfix()

    editable function parse_postfix() -> ast.AstExpr:
        var expr = this.parse_primary()
        while true:
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.dot:
                let _dot = this.bp.advance()
                let member = this.parse_ident()
                expr = ast.AstExpr.member(object = expr, member_name = member)
            else if tk.kind == tok.TokenKind.bracket_open:
                let _open = this.bp.advance()
                let index = this.parse_expression()
                this.expect(tok.TokenKind.bracket_close)
                expr = ast.AstExpr.index(object = expr, index = index)
            else if tk.kind == tok.TokenKind.paren_open:
                let args = this.parse_call_args()
                expr = ast.AstExpr.call(callee = expr, args = args)
            else if tk.kind == tok.TokenKind.question_mark:
                let _q = this.bp.advance()
                expr = ast.AstExpr.propagation(expr = expr)
            else if this.bp.stream.check_keyword(tok.KeywordKind.kw_with):
                let _w = this.bp.advance()
                let updates = this.parse_named_fields_in_parens()
                expr = ast.AstExpr.with_expr(expr = expr, updates = updates)
            else if this.bp.stream.check_keyword(tok.KeywordKind.kw_is):
                let _is = this.bp.advance()
                let vname = this.parse_ident()
                this.expect(tok.TokenKind.dot)
                let aname = this.parse_ident()
                expr = ast.AstExpr.is_expr(expr = expr, variant_name = vname, arm_name = aname)
            else:
                break
        return expr

    editable function parse_primary() -> ast.AstExpr:
        let tk = this.bp.current_token()
        if tk.kind == tok.TokenKind.integer_literal:
            let _i = this.bp.advance()
            return ast.AstExpr.integer_literal(value_str = tk.lexeme)
        if tk.kind == tok.TokenKind.float_literal:
            let _f = this.bp.advance()
            return ast.AstExpr.float_literal(value_str = tk.lexeme)
        if tk.kind == tok.TokenKind.string_literal:
            let _s = this.bp.advance()
            return ast.AstExpr.string_literal(value_str = tk.lexeme)
        if tk.kind == tok.TokenKind.char_literal:
            let _c = this.bp.advance()
            return ast.AstExpr.char_literal(value_str = tk.lexeme)
        if tk.kind == tok.TokenKind.cstring_literal:
            let _cs = this.bp.advance()
            return ast.AstExpr.cstring_literal(value_str = tk.lexeme)
        if tk.kind == tok.TokenKind.keyword:
            let kw = tok.KeywordKind<-(tk.keyword_subkind)
            if kw == tok.KeywordKind.kw_true:
                let _t = this.bp.advance()
                return ast.AstExpr.bool_literal(value = true)
            else if kw == tok.KeywordKind.kw_false:
                let _f = this.bp.advance()
                return ast.AstExpr.bool_literal(value = false)
            else if kw == tok.KeywordKind.kw_null:
                let _n = this.bp.advance()
                if this.bp.current_token().kind == tok.TokenKind.bracket_open:
                    let _br = this.bp.advance()
                    let target = this.parse_type_ref()
                    this.expect(tok.TokenKind.bracket_close)
                    return ast.AstExpr.typed_null_literal(target_type = target)
                return ast.AstExpr.null_literal
            else if kw == tok.KeywordKind.kw_if:
                let _if = this.bp.advance()
                let cond = this.parse_expression()
                this.expect_colon()
                let tv = this.parse_expression()
                this.bp.stream.check_keyword(tok.KeywordKind.kw_else)
                let _else = this.bp.advance()
                this.expect_colon()
                let ev = this.parse_expression()
                return ast.AstExpr.if_expr(condition = cond, then_val = tv, else_val = ev)
            else if kw == tok.KeywordKind.kw_match:
                return this.parse_match_expr()
        if tk.kind == tok.TokenKind.paren_open:
            return this.parse_tuple_or_paren()
        if tk.kind == tok.TokenKind.bracket_open:
            let _open = this.bp.advance()
            let inner = this.parse_expression()
            this.expect(tok.TokenKind.bracket_close)
            return inner
        return ast.AstExpr.identifier(name = this.parse_ident())

    editable function parse_match_expr() -> ast.AstExpr:
        let _kw = this.bp.advance()
        let scrutinee = this.parse_expression()
        this.expect_colon()
        this.bp.skip_newlines()
        this.bp.enter_block()
        var arms = vec.Vec[ast.MatchArmExpr].create()
        while not this.bp.is_eof():
            this.bp.skip_newlines()
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.dedent:
                break
            let patterns = this.parse_match_expr_patterns()
            this.expect(tok.TokenKind.colon)
            let value = this.parse_expression()
            arms.push(ast.MatchArmExpr(patterns = patterns, value = value))
        this.bp.exit_block()
        return ast.AstExpr.match_expr(scrutinee = scrutinee, arms = arms)

    editable function parse_match_expr_patterns() -> vec.Vec[ast.MatchPattern]:
        var pats = vec.Vec[ast.MatchPattern].create()
        let first = this.parse_single_expr_pattern()
        pats.push(first)
        while this.bp.current_token().kind == tok.TokenKind.op_bit_or:
            let _pipe = this.bp.advance()
            let next = this.parse_single_expr_pattern()
            pats.push(next)
        return pats

    editable function parse_single_expr_pattern() -> ast.MatchPattern:
        let tk = this.bp.current_token()
        if tk.lexeme == "_":
            let _w = this.bp.advance()
            return ast.MatchPattern(kind = ast.MatchPatternKind.wildcard)
        if tk.kind == tok.TokenKind.integer_literal:
            let _i = this.bp.advance()
            return ast.MatchPattern(kind = ast.MatchPatternKind.integer_literal(value = tk.lexeme))
        if tk.kind == tok.TokenKind.string_literal:
            let _s = this.bp.advance()
            return ast.MatchPattern(kind = ast.MatchPatternKind.string_literal(value = tk.lexeme))
        if tk.kind == tok.TokenKind.char_literal:
            let _c = this.bp.advance()
            return ast.MatchPattern(kind = ast.MatchPatternKind.char_literal(value = tk.lexeme))
        let first = this.parse_ident()
        if this.bp.current_token().kind == tok.TokenKind.dot:
            let _dot = this.bp.advance()
            let second = this.parse_ident()
            if this.bp.current_token().kind == tok.TokenKind.dot:
                let _dot2 = this.bp.advance()
                let third = this.parse_ident()
                var fields = vec.Vec[ast.StructPatternField].create()
                if this.bp.current_token().kind == tok.TokenKind.paren_open:
                    fields = this.parse_pattern_fields()
                var payload_bind: str = ""
                if this.bp.stream.check_keyword(tok.KeywordKind.kw_as):
                    let _as = this.bp.advance()
                    payload_bind = this.parse_ident()
                return ast.MatchPattern(kind = ast.MatchPatternKind.variant_arm(variant_name = first, arm_name = third, payload_bind = payload_bind, struct_fields = fields))
            var payload_bind2: str = ""
            if this.bp.stream.check_keyword(tok.KeywordKind.kw_as):
                let _as = this.bp.advance()
                payload_bind2 = this.parse_ident()
            if this.bp.current_token().kind == tok.TokenKind.paren_open:
                var fields = this.parse_pattern_fields()
                return ast.MatchPattern(kind = ast.MatchPatternKind.variant_arm(variant_name = first, arm_name = second, payload_bind = payload_bind2, struct_fields = fields))
            return ast.MatchPattern(kind = ast.MatchPatternKind.enum_member(enum_name = first, member_name = second))
        if this.bp.current_token().kind == tok.TokenKind.paren_open:
            var fields = this.parse_pattern_fields()
            return ast.MatchPattern(kind = ast.MatchPatternKind.variant_arm(variant_name = "", arm_name = first, payload_bind = "", struct_fields = fields))
        return ast.MatchPattern(kind = ast.MatchPatternKind.wildcard)

    editable function parse_tuple_or_paren() -> ast.AstExpr:
        let _open = this.bp.advance()
        let first = this.parse_expression()
        if this.bp.current_token().kind == tok.TokenKind.comma:
            var elements = vec.Vec[ast.AstExpr].create()
            elements.push(first)
            while this.bp.current_token().kind == tok.TokenKind.comma:
                let _c = this.bp.advance()
                let next = this.parse_expression()
                elements.push(next)
            this.expect(tok.TokenKind.paren_close)
            return ast.AstExpr.tuple(elements = elements)
        this.expect(tok.TokenKind.paren_close)
        return first

    editable function parse_call_args() -> vec.Vec[ast.CallArg]:
        let _open = this.bp.advance()
        var args = vec.Vec[ast.CallArg].create()
        while not this.bp.is_eof():
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.paren_close:
                let _close = this.bp.advance()
                return args
            if tk.kind == tok.TokenKind.identifier and this.is_named_arg_lookahead():
                let name = this.parse_ident()
                let _eq = this.bp.advance()
                let value = this.parse_expression()
                args.push(ast.CallArg(name = name, value = value))
            else:
                let value = this.parse_expression()
                args.push(ast.CallArg(name = "", value = value))
            if this.bp.current_token().kind == tok.TokenKind.comma:
                let _comma = this.bp.advance()
        this.expect(tok.TokenKind.paren_close)
        return args

    editable function parse_named_fields_in_parens() -> vec.Vec[ast.NamedField]:
        this.expect(tok.TokenKind.paren_open)
        var fields = vec.Vec[ast.NamedField].create()
        while not this.bp.is_eof():
            let tk = this.bp.current_token()
            if tk.kind == tok.TokenKind.paren_close:
                let _close = this.bp.advance()
                return fields
            let name = this.parse_ident()
            this.expect(tok.TokenKind.op_assign)
            let value = this.parse_expression()
            fields.push(ast.NamedField(name = name, value = value))
            if this.bp.current_token().kind == tok.TokenKind.comma:
                let _comma = this.bp.advance()
        this.expect(tok.TokenKind.paren_close)
        return fields

    editable function peek_keyword(kw: tok.KeywordKind) -> bool:
        let next = this.bp.stream.peek()
        return next.kind == tok.TokenKind.keyword and next.keyword_subkind == uint<-(kw)

    editable function is_named_arg_lookahead() -> bool:
        let current = this.bp.stream.peek()
        if current.kind != tok.TokenKind.identifier:
            return false
        let next_ptr = this.bp.stream.tokens.get(this.bp.stream.current + 1)
        let next = next_ptr else:
            return false
        unsafe:
            return read(next).kind == tok.TokenKind.op_assign

    editable function parse_ident() -> str:
        return this.bp.advance().lexeme

    editable function expect(kind: tok.TokenKind) -> void:
        if this.bp.current_token().kind == kind:
            let _ = this.bp.advance()
            return
        fatal(c"expected different token")

    editable function expect_colon() -> void:
        this.expect(tok.TokenKind.colon)
