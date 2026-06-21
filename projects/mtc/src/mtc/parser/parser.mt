import std.str
import std.vec as vec

import mtc.lexer.token
import mtc.ast.nodes


public struct Parser:
    tokens: vec.Vec[token.Token]
    pos: ptr_uint


extending Parser:
    public static function create(tokens: vec.Vec[token.Token]) -> Parser:
        return Parser(tokens = tokens, pos = 0)


    function at_end() -> bool:
        return this.pos >= this.tokens.len()


    function peek_tok() -> token.Token:
        let t = this.tokens.get(this.pos) else:
            return token.Token(kind = token.TokenKind.tk_eof, lexeme = "", line = 0, column = 0)
        return unsafe: read(t)


    function peek_kind() -> token.TokenKind:
        return this.peek_tok().kind


    function tok_line() -> ptr_uint:
        return this.peek_tok().line


    function tok_col() -> ptr_uint:
        return this.peek_tok().column


    function tok_lexeme() -> str:
        return this.peek_tok().lexeme


    editable function advance() -> void:
        this.pos += 1


    function check(kind: token.TokenKind) -> bool:
        return this.peek_kind() == kind


    function check_id(name: str) -> bool:
        return this.peek_kind() == token.TokenKind.tk_identifier and this.tok_lexeme() == name


    editable function match_kind(kind: token.TokenKind) -> bool:
        if this.check(kind):
            this.advance()
            return true
        return false


    editable function match_id(name: str) -> bool:
        if this.check_id(name):
            this.advance()
            return true
        return false


    editable function expect_id() -> str:
        if this.peek_kind() == token.TokenKind.tk_identifier:
            let name = this.tok_lexeme()
            this.advance()
            return name
        this.advance()
        return ""


    editable function expect(kind: token.TokenKind) -> bool:
        if this.check(kind):
            this.advance()
            return true
        if not this.at_end():
            this.advance()
        return false


    editable function skip_newlines() -> void:
        while this.match_kind(token.TokenKind.tk_newline):
            pass


    editable function skip_indent() -> void:
        if this.match_kind(token.TokenKind.tk_indent):
            pass


    editable function skip_dedent() -> void:
        if this.match_kind(token.TokenKind.tk_dedent):
            pass


    editable function skip_bracketed(open: token.TokenKind, close: token.TokenKind) -> void:
        if this.match_kind(open):
            var depth: ptr_uint = 1
            while not this.at_end() and depth > 0:
                if this.check(open):
                    depth += 1
                else if this.check(close):
                    depth -= 1
                this.advance()


    public editable function parse() -> nodes.SourceFile:
        var imports = vec.Vec[nodes.Import].create()
        var decls = vec.Vec[nodes.Decl].create()
        this.skip_newlines()

        while not this.at_end():
            this.skip_newlines()
            if not this.check(token.TokenKind.tk_import):
                break
            this.parse_import(ref_of(imports))

        while not this.at_end() and this.peek_kind() != token.TokenKind.tk_eof:
            this.skip_newlines()
            if this.at_end() or this.peek_kind() == token.TokenKind.tk_eof:
                break
            var decl = this.parse_declaration()
            if decl.name != "":
                decls.push(decl)

        return nodes.SourceFile(module_name = "", imports = imports, decls = decls, line = 1)


    editable function parse_import(imports: ref[vec.Vec[nodes.Import]]) -> void:
        let line = this.tok_line()
        let col = this.tok_col()
        this.expect(token.TokenKind.tk_import)
        var first = this.expect_id()
        while this.match_kind(token.TokenKind.tk_dot):
            var part = this.expect_id()
            pass
        var alias = ""
        if this.match_kind(token.TokenKind.tk_as):
            alias = this.expect_id()
        imports.push(nodes.Import(path = first, alias = alias, line = line, column = col))


    function check_next(kind: token.TokenKind) -> bool:
        if this.pos + 1 >= this.tokens.len():
            return false
        let t = this.tokens.get(this.pos + 1) else:
            return false
        return unsafe: read(t).kind == kind


    function empty_fields() -> vec.Vec[nodes.Field]:
        return vec.Vec[nodes.Field].create()

    function empty_params() -> vec.Vec[nodes.Param]:
        return vec.Vec[nodes.Param].create()

    function empty_members() -> vec.Vec[nodes.EnumMember]:
        return vec.Vec[nodes.EnumMember].create()

    function empty_arms() -> vec.Vec[nodes.VariantArm]:
        return vec.Vec[nodes.VariantArm].create()

    function empty_methods() -> vec.Vec[nodes.Decl]:
        return vec.Vec[nodes.Decl].create()

    function empty_impls() -> vec.Vec[str]:
        return vec.Vec[str].create()


    ## --- DECLARATIONS ---

    editable function parse_declaration() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()

        if this.match_kind(token.TokenKind.tk_public):
            var decl = this.parse_declaration_inner()
            decl.is_public = true
            return decl
        return this.parse_declaration_inner()


    editable function parse_declaration_inner() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()

        if this.check(token.TokenKind.tk_function):
            return this.parse_function_def(false, false)
        if this.check(token.TokenKind.tk_const) and this.check_next(token.TokenKind.tk_function):
            this.advance()
            return this.parse_function_def(true, false)
        if this.check(token.TokenKind.tk_async):
            this.advance()
            return this.parse_function_def(false, true)
        if this.check(token.TokenKind.tk_external):
            this.advance()
            return this.parse_extern_function()
        if this.check(token.TokenKind.tk_foreign):
            this.advance()
            return this.parse_foreign_function()
        if this.check(token.TokenKind.tk_struct):
            return this.parse_struct()
        if this.check(token.TokenKind.tk_enum):
            return this.parse_enum()
        if this.check(token.TokenKind.tk_flags):
            return this.parse_flags()
        if this.check(token.TokenKind.tk_variant):
            return this.parse_variant()
        if this.check(token.TokenKind.tk_interface):
            return this.parse_interface()
        if this.check(token.TokenKind.tk_type):
            return this.parse_type_alias()
        if this.check(token.TokenKind.tk_opaque):
            return this.parse_opaque()
        if this.check(token.TokenKind.tk_union):
            return this.parse_union()
        if this.check(token.TokenKind.tk_const):
            return this.parse_const_var(true)
        if this.check(token.TokenKind.tk_var):
            return this.parse_const_var(false)
        if this.check(token.TokenKind.tk_event):
            return this.parse_event()
        if this.check(token.TokenKind.tk_extending):
            return this.parse_extending()
        if this.check(token.TokenKind.tk_static_assert):
            this.advance()
            this.skip_bracketed(token.TokenKind.tk_lparen, token.TokenKind.tk_rparen)
            this.skip_newlines()
            return nodes.Decl(kind = nodes.DeclKind.const_decl, name = "", line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())
        if this.check(token.TokenKind.tk_attribute):
            this.advance()
            this.skip_expr_value()
            this.skip_newlines()
            return nodes.Decl(kind = nodes.DeclKind.const_decl, name = "", line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())
        if this.check(token.TokenKind.tk_when):
            this.advance()
            this.skip_expr_value()
            if this.expect(token.TokenKind.tk_colon):
                pass
            this.skip_newlines()
            if this.match_kind(token.TokenKind.tk_indent):
                this.skip_block_body()
            return nodes.Decl(kind = nodes.DeclKind.const_decl, name = "when", line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())
        if this.check(token.TokenKind.tk_inline):
            this.advance()
            if this.check(token.TokenKind.tk_for) or this.check(token.TokenKind.tk_while) or this.check(token.TokenKind.tk_match) or this.check(token.TokenKind.tk_if):
                this.advance()
                this.skip_expr_value()
                if this.expect(token.TokenKind.tk_colon):
                    pass
                this.skip_newlines()
                if this.match_kind(token.TokenKind.tk_indent):
                    this.skip_block_body()
            return nodes.Decl(kind = nodes.DeclKind.const_decl, name = "inline", line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())

        this.advance()
        return nodes.Decl(kind = nodes.DeclKind.const_decl, name = "", line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())


    editable function parse_function_def(is_const: bool, is_async: bool) -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.expect(token.TokenKind.tk_function)
        let name = this.expect_id()
        this.skip_bracketed(token.TokenKind.tk_lbracket, token.TokenKind.tk_rbracket)
        var params = this.empty_params()
        this.expect(token.TokenKind.tk_lparen)
        this.parse_param_list(ref_of(params))
        this.expect(token.TokenKind.tk_rparen)
        var rtype = ""
        if this.match_kind(token.TokenKind.tk_arrow):
            rtype = this.parse_type_text()
        this.expect(token.TokenKind.tk_colon)
        this.skip_newlines()
        this.skip_indent()
        var body = this.parse_block()
        var count = body.len()
        body.release()
        return nodes.Decl(kind = nodes.DeclKind.function_def, name = name, params = params, return_text = rtype, is_const_fn = is_const, is_async = is_async, stmt_count = count, line = line, column = col, type_name = "", value_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())


    editable function parse_extern_function() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.expect(token.TokenKind.tk_function)
        let name = this.expect_id()
        var params = this.empty_params()
        this.expect(token.TokenKind.tk_lparen)
        this.parse_param_list(ref_of(params))
        this.expect(token.TokenKind.tk_rparen)
        var rtype = ""
        if this.match_kind(token.TokenKind.tk_arrow):
            rtype = this.parse_type_text()
        if this.check(token.TokenKind.tk_ellipsis):
            this.advance()
        return nodes.Decl(kind = nodes.DeclKind.extern_function, name = name, params = params, return_text = rtype, is_extern = true, line = line, column = col, type_name = "", value_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())


    editable function parse_foreign_function() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.expect(token.TokenKind.tk_function)
        let name = this.expect_id()
        var params = this.empty_params()
        this.expect(token.TokenKind.tk_lparen)
        this.parse_param_list(ref_of(params))
        this.expect(token.TokenKind.tk_rparen)
        var rtype = ""
        if this.match_kind(token.TokenKind.tk_arrow):
            rtype = this.parse_type_text()
        var mapping = ""
        if this.match_kind(token.TokenKind.tk_equal):
            mapping = this.parse_type_text()
        return nodes.Decl(kind = nodes.DeclKind.foreign_function, name = name, params = params, return_text = rtype, type_name = mapping, line = line, column = col, value_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())


    editable function parse_struct() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        var impls = this.empty_impls()
        if this.match_id("implements"):
            while not this.check(token.TokenKind.tk_colon):
                impls.push(this.expect_id())
                if not this.match_kind(token.TokenKind.tk_comma):
                    break
        this.expect(token.TokenKind.tk_colon)
        this.skip_newlines()
        this.skip_indent()
        var fields = this.empty_fields()
        while not this.at_end() and not this.check(token.TokenKind.tk_dedent):
            this.skip_newlines()
            if this.check(token.TokenKind.tk_dedent):
                break
            if this.check(token.TokenKind.tk_public) or this.check(token.TokenKind.tk_event):
                while not this.at_end() and not this.check(token.TokenKind.tk_newline) and not this.check(token.TokenKind.tk_dedent):
                    this.advance()
                continue
            let fname = this.expect_id()
            this.expect(token.TokenKind.tk_colon)
            let ftype = this.parse_type_text()
            fields.push(nodes.Field(name = fname, type_text = ftype, line = line, column = col))
        this.skip_dedent()
        return nodes.Decl(kind = nodes.DeclKind.struct_decl, name = name, impl_list = impls, fields = fields, line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), return_text = "", members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods())


    editable function parse_enum() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        var btype = ""
        if this.match_kind(token.TokenKind.tk_colon):
            btype = this.parse_type_text()
        this.skip_newlines()
        this.skip_indent()
        var members = this.empty_members()
        while not this.at_end() and not this.check(token.TokenKind.tk_dedent):
            this.skip_newlines()
            if this.check(token.TokenKind.tk_dedent):
                break
            let mname = this.expect_id()
            var mval = ""
            if this.match_kind(token.TokenKind.tk_equal):
                mval = this.parse_value_text()
            members.push(nodes.EnumMember(name = mname, value_text = mval, line = line, column = col))
        this.skip_dedent()
        return nodes.Decl(kind = nodes.DeclKind.enum_decl, name = name, type_name = btype, members = members, line = line, column = col, value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())


    editable function parse_flags() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        var btype = ""
        if this.match_kind(token.TokenKind.tk_colon):
            btype = this.parse_type_text()
        this.skip_newlines()
        this.skip_indent()
        var members = this.empty_members()
        while not this.at_end() and not this.check(token.TokenKind.tk_dedent):
            this.skip_newlines()
            if this.check(token.TokenKind.tk_dedent):
                break
            let mname = this.expect_id()
            var mval = ""
            if this.match_kind(token.TokenKind.tk_equal):
                mval = this.parse_value_text()
            members.push(nodes.EnumMember(name = mname, value_text = mval, line = line, column = col))
        this.skip_dedent()
        return nodes.Decl(kind = nodes.DeclKind.flags_decl, name = name, type_name = btype, members = members, line = line, column = col, value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())


    editable function parse_variant() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        this.skip_bracketed(token.TokenKind.tk_lbracket, token.TokenKind.tk_rbracket)
        this.expect(token.TokenKind.tk_colon)
        this.skip_newlines()
        this.skip_indent()
        var arms = this.empty_arms()
        while not this.at_end() and not this.check(token.TokenKind.tk_dedent):
            this.skip_newlines()
            if this.check(token.TokenKind.tk_dedent):
                break
            let aname = this.expect_id()
            var afields = this.empty_fields()
            if this.match_kind(token.TokenKind.tk_lparen):
                while not this.check(token.TokenKind.tk_rparen):
                    let fname = this.expect_id()
                    this.expect(token.TokenKind.tk_colon)
                    let ftype = this.parse_type_text()
                    afields.push(nodes.Field(name = fname, type_text = ftype, line = line, column = col))
                    if not this.match_kind(token.TokenKind.tk_comma):
                        break
                this.expect(token.TokenKind.tk_rparen)
            arms.push(nodes.VariantArm(name = aname, fields = afields))
        this.skip_dedent()
        return nodes.Decl(kind = nodes.DeclKind.variant_decl, name = name, arms = arms, line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), methods = this.empty_methods(), impl_list = this.empty_impls())


    editable function parse_interface() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        this.skip_bracketed(token.TokenKind.tk_lbracket, token.TokenKind.tk_rbracket)
        this.expect(token.TokenKind.tk_colon)
        this.skip_newlines()
        this.skip_indent()
        var methods = this.empty_methods()
        while not this.at_end() and not this.check(token.TokenKind.tk_dedent):
            this.skip_newlines()
            if this.check(token.TokenKind.tk_dedent):
                break
            this.match_kind(token.TokenKind.tk_static)
            this.match_kind(token.TokenKind.tk_editable)
            this.expect(token.TokenKind.tk_function)
            let mname = this.expect_id()
            var mparams = this.empty_params()
            this.expect(token.TokenKind.tk_lparen)
            this.parse_param_list(ref_of(mparams))
            this.expect(token.TokenKind.tk_rparen)
            var rtype = ""
            if this.match_kind(token.TokenKind.tk_arrow):
                rtype = this.parse_type_text()
            methods.push(nodes.Decl(kind = nodes.DeclKind.function_def, name = mname, params = mparams, return_text = rtype, line = line, column = col, type_name = "", value_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls()))
        this.skip_dedent()
        return nodes.Decl(kind = nodes.DeclKind.interface_decl, name = name, methods = methods, line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), impl_list = this.empty_impls())


    editable function parse_type_alias() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        this.expect(token.TokenKind.tk_equal)
        let target = this.parse_type_text()
        return nodes.Decl(kind = nodes.DeclKind.type_alias, name = name, type_name = target, line = line, column = col, value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())


    editable function parse_opaque() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        var impls = this.empty_impls()
        if this.match_id("implements"):
            while not this.check(token.TokenKind.tk_newline) and not this.at_end():
                impls.push(this.expect_id())
                if not this.match_kind(token.TokenKind.tk_comma):
                    break
        return nodes.Decl(kind = nodes.DeclKind.opaque_decl, name = name, impl_list = impls, line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods())


    editable function parse_union() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        this.expect(token.TokenKind.tk_colon)
        this.skip_newlines()
        this.skip_indent()
        var fields = this.empty_fields()
        while not this.at_end() and not this.check(token.TokenKind.tk_dedent):
            this.skip_newlines()
            if this.check(token.TokenKind.tk_dedent):
                break
            if this.check(token.TokenKind.tk_public) or this.check(token.TokenKind.tk_event):
                while not this.at_end() and not this.check(token.TokenKind.tk_newline) and not this.check(token.TokenKind.tk_dedent):
                    this.advance()
                continue
            let fname = this.expect_id()
            this.expect(token.TokenKind.tk_colon)
            let ftype = this.parse_type_text()
            fields.push(nodes.Field(name = fname, type_text = ftype, line = line, column = col))
        this.skip_dedent()
        return nodes.Decl(kind = nodes.DeclKind.union_decl, name = name, fields = fields, line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), return_text = "", members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())


    editable function parse_const_var(is_const: bool) -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()

        if this.match_kind(token.TokenKind.tk_arrow):
            var vtype = this.parse_type_text()
            this.expect(token.TokenKind.tk_colon)
            this.skip_newlines()
            this.skip_indent()
            var body = this.parse_block()
            var count = body.len()
            body.release()
            return nodes.Decl(kind = if is_const: nodes.DeclKind.const_decl else: nodes.DeclKind.var_decl, name = name, type_name = vtype, stmt_count = count, line = line, column = col, value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())

        this.expect(token.TokenKind.tk_colon)
        let vtype = this.parse_type_text()
        if this.match_kind(token.TokenKind.tk_equal):
            this.skip_expr_value()
        return nodes.Decl(kind = if is_const: nodes.DeclKind.const_decl else: nodes.DeclKind.var_decl, name = name, type_name = vtype, line = line, column = col, value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())


    editable function parse_event() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        if this.match_kind(token.TokenKind.tk_lbracket):
            if this.check(token.TokenKind.tk_integer):
                this.advance()
            this.expect(token.TokenKind.tk_rbracket)
        return nodes.Decl(kind = nodes.DeclKind.event_decl, name = name, line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls())


    editable function parse_extending() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let type_name = this.expect_id()
        this.expect(token.TokenKind.tk_colon)
        this.skip_newlines()
        this.skip_indent()
        var methods = this.empty_methods()
        while not this.at_end() and not this.check(token.TokenKind.tk_dedent):
            this.skip_newlines()
            if this.check(token.TokenKind.tk_dedent):
                break
            this.match_kind(token.TokenKind.tk_static)
            this.match_kind(token.TokenKind.tk_editable)
            this.expect(token.TokenKind.tk_function)
            let mname = this.expect_id()
            this.skip_bracketed(token.TokenKind.tk_lbracket, token.TokenKind.tk_rbracket)
            this.expect(token.TokenKind.tk_lparen)
            while not this.check(token.TokenKind.tk_rparen) and not this.at_end():
                this.advance()
            this.expect(token.TokenKind.tk_rparen)
            var rtype = ""
            if this.match_kind(token.TokenKind.tk_arrow):
                rtype = this.parse_type_text()
            this.expect(token.TokenKind.tk_colon)
            this.skip_newlines()
            this.skip_indent()
            this.skip_block_body()
            methods.push(nodes.Decl(kind = nodes.DeclKind.function_def, name = mname, return_text = rtype, line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls()))
        this.skip_dedent()
        return nodes.Decl(kind = nodes.DeclKind.extending_block, name = type_name, methods = methods, line = line, column = col, type_name = "", value_text = "", params = this.empty_params(), return_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), impl_list = this.empty_impls())


    editable function parse_value_text() -> str:
        var first = ""
        if not this.at_end() and this.peek_kind() != token.TokenKind.tk_newline and this.peek_kind() != token.TokenKind.tk_dedent and this.peek_kind() != token.TokenKind.tk_colon:
            first = this.tok_lexeme()
        this.skip_expr_value()
        return first


    editable function parse_param_list(params: ref[vec.Vec[nodes.Param]]) -> void:
        while not this.check(token.TokenKind.tk_rparen) and not this.at_end():
            if this.check(token.TokenKind.tk_ellipsis):
                this.advance()
                break
            if this.check(token.TokenKind.tk_in) or this.check(token.TokenKind.tk_out) or this.check(token.TokenKind.tk_inout) or this.check(token.TokenKind.tk_consuming):
                this.advance()
            let pname = this.expect_id()
            this.expect(token.TokenKind.tk_colon)
            let ptype = this.parse_type_text()
            if this.match_kind(token.TokenKind.tk_as):
                this.parse_type_text()
            params.push(nodes.Param(name = pname, type_text = ptype, line = this.tok_line(), column = this.tok_col()))
            if not this.match_kind(token.TokenKind.tk_comma):
                break


    editable function parse_type_text() -> str:
        if this.check(token.TokenKind.tk_identifier):
            var text = this.expect_id()
            if text == "ptr" or text == "ref" or text == "span" or text == "dyn" or text == "array" or text == "const_ptr":
                if this.match_kind(token.TokenKind.tk_lbracket):
                    this.skip_bracketed(token.TokenKind.tk_lbracket, token.TokenKind.tk_rbracket)
                if this.match_kind(token.TokenKind.tk_at):
                    this.advance()
                    if this.match_kind(token.TokenKind.tk_lbracket):
                        this.skip_bracketed(token.TokenKind.tk_lbracket, token.TokenKind.tk_rbracket)
                if this.match_kind(token.TokenKind.tk_question):
                    pass
            else:
                if this.match_kind(token.TokenKind.tk_lbracket):
                    this.skip_bracketed(token.TokenKind.tk_lbracket, token.TokenKind.tk_rbracket)
                if this.match_kind(token.TokenKind.tk_question):
                    pass
            return text

        if this.check(token.TokenKind.tk_fn) or this.check(token.TokenKind.tk_proc):
            var text = this.tok_lexeme()
            this.advance()
            if this.match_kind(token.TokenKind.tk_lparen):
                this.skip_bracketed(token.TokenKind.tk_lparen, token.TokenKind.tk_rparen)
            if this.match_kind(token.TokenKind.tk_arrow):
                this.parse_type_text()
            return text

        if this.match_kind(token.TokenKind.tk_question):
            return "?"
        return ""


    ## --- EXPRESSION PARSING ---

    public editable function parse_expression() -> nodes.Expr:
        return this.parse_or()


    editable function parse_or() -> nodes.Expr:
        var expr = this.parse_and()
        while this.match_kind(token.TokenKind.tk_or):
            var right = this.parse_and()
            expr = nodes.Expr(kind = nodes.ExprKind.binary_op, operator = "or", left_text = expr.name, right_text = right.name, line = this.tok_line(), column = this.tok_col())
        return expr


    editable function parse_and() -> nodes.Expr:
        var expr = this.parse_equality()
        while this.match_kind(token.TokenKind.tk_and):
            var right = this.parse_equality()
            expr = nodes.Expr(kind = nodes.ExprKind.binary_op, operator = "and", left_text = expr.name, right_text = right.name, line = this.tok_line(), column = this.tok_col())
        return expr


    editable function parse_equality() -> nodes.Expr:
        var expr = this.parse_comparison()
        while this.check(token.TokenKind.tk_equal_equal) or this.check(token.TokenKind.tk_bang_equal):
            var op = if this.peek_kind() == token.TokenKind.tk_equal_equal: "==" else: "!="
            this.advance()
            var right = this.parse_comparison()
            expr = nodes.Expr(kind = nodes.ExprKind.binary_op, operator = op, left_text = expr.name, right_text = right.name, line = this.tok_line(), column = this.tok_col())
        return expr


    editable function parse_comparison() -> nodes.Expr:
        var expr = this.parse_additive()
        while this.check(token.TokenKind.tk_less) or this.check(token.TokenKind.tk_less_equal) or this.check(token.TokenKind.tk_greater) or this.check(token.TokenKind.tk_greater_equal):
            var op = this.tok_lexeme()
            this.advance()
            var right = this.parse_additive()
            expr = nodes.Expr(kind = nodes.ExprKind.binary_op, operator = op, left_text = expr.name, right_text = right.name, line = this.tok_line(), column = this.tok_col())
        return expr


    editable function parse_additive() -> nodes.Expr:
        var expr = this.parse_multiplicative()
        while this.check(token.TokenKind.tk_plus) or this.check(token.TokenKind.tk_minus):
            var op = this.tok_lexeme()
            this.advance()
            var right = this.parse_multiplicative()
            expr = nodes.Expr(kind = nodes.ExprKind.binary_op, operator = op, left_text = expr.name, right_text = right.name, line = this.tok_line(), column = this.tok_col())
        return expr


    editable function parse_multiplicative() -> nodes.Expr:
        var expr = this.parse_unary()
        while this.check(token.TokenKind.tk_star) or this.check(token.TokenKind.tk_slash) or this.check(token.TokenKind.tk_percent):
            var op = this.tok_lexeme()
            this.advance()
            var right = this.parse_unary()
            expr = nodes.Expr(kind = nodes.ExprKind.binary_op, operator = op, left_text = expr.name, right_text = right.name, line = this.tok_line(), column = this.tok_col())
        return expr


    editable function parse_unary() -> nodes.Expr:
        if this.match_kind(token.TokenKind.tk_not) or this.match_kind(token.TokenKind.tk_minus):
            var op = this.tok_lexeme()
            if op == "":
                op = "-"
            var operand = this.parse_unary()
            return nodes.Expr(kind = nodes.ExprKind.unary_op, operator = op, name = operand.name, line = this.tok_line(), column = this.tok_col())
        if this.match_kind(token.TokenKind.tk_await):
            var expr = this.parse_unary()
            return nodes.Expr(kind = nodes.ExprKind.await_expr, name = expr.name, line = this.tok_line(), column = this.tok_col())
        return this.parse_postfix()


    editable function parse_postfix() -> nodes.Expr:
        var expr = this.parse_primary()

        while true:
            if this.match_kind(token.TokenKind.tk_dot):
                var member = this.expect_id()
                expr = nodes.Expr(kind = nodes.ExprKind.member_access, name = member, left_text = expr.name, line = this.tok_line(), column = this.tok_col())
            else if this.match_kind(token.TokenKind.tk_as):
                var bind = this.expect_id()
                expr = nodes.Expr(kind = nodes.ExprKind.identifier, name = bind, left_text = expr.name, line = this.tok_line(), column = this.tok_col())
            else if this.match_kind(token.TokenKind.tk_lparen):
                var args = vec.Vec[nodes.Expr].create()
                if not this.check(token.TokenKind.tk_rparen):
                    while true:
                        var arg = this.parse_expression()
                        args.push(arg)
                        if not this.match_kind(token.TokenKind.tk_comma):
                            break
                this.expect(token.TokenKind.tk_rparen)
                expr = nodes.Expr(kind = nodes.ExprKind.call, name = expr.name, left_text = expr.name, line = this.tok_line(), column = this.tok_col())
            else if this.match_kind(token.TokenKind.tk_lbracket):
                var idx = this.parse_expression()
                this.expect(token.TokenKind.tk_rbracket)
                expr = nodes.Expr(kind = nodes.ExprKind.index_access, name = idx.name, left_text = expr.name, line = this.tok_line(), column = this.tok_col())
            else if this.match_kind(token.TokenKind.tk_question):
                expr = nodes.Expr(kind = nodes.ExprKind.await_expr, name = expr.name, line = this.tok_line(), column = this.tok_col())
            else:
                break
        return expr


    editable function parse_primary() -> nodes.Expr:
        let line = this.tok_line()
        let col = this.tok_col()
        let kind = this.peek_kind()

        if kind == token.TokenKind.tk_integer:
            var lex = this.tok_lexeme()
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.integer_literal, lexeme = lex, name = lex, line = line, column = col)

        if kind == token.TokenKind.tk_float:
            var lex = this.tok_lexeme()
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.float_literal, lexeme = lex, name = lex, line = line, column = col)

        if kind == token.TokenKind.tk_string or kind == token.TokenKind.tk_cstring:
            var lex = this.tok_lexeme()
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.string_literal, lexeme = lex, name = lex, line = line, column = col)

        if kind == token.TokenKind.tk_char_literal:
            var lex = this.tok_lexeme()
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.char_literal, lexeme = lex, name = lex, line = line, column = col)

        if kind == token.TokenKind.tk_true or kind == token.TokenKind.tk_false:
            var lex = this.tok_lexeme()
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.boolean_literal, lexeme = lex, name = lex, line = line, column = col)

        if kind == token.TokenKind.tk_null:
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.null_literal, name = "null", line = line, column = col)

        if kind == token.TokenKind.tk_identifier:
            var name = this.tok_lexeme()
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.identifier, name = name, lexeme = name, line = line, column = col)

        if kind == token.TokenKind.tk_proc:
            this.advance()
            if this.match_kind(token.TokenKind.tk_lparen):
                while not this.check(token.TokenKind.tk_rparen) and not this.at_end():
                    this.advance()
                this.expect(token.TokenKind.tk_rparen)
            if this.match_kind(token.TokenKind.tk_arrow):
                this.parse_type_text()
            if this.match_kind(token.TokenKind.tk_colon):
                this.skip_newlines()
                if this.match_kind(token.TokenKind.tk_indent):
                    this.parse_block()
                else:
                    this.parse_expression()
            return nodes.Expr(kind = nodes.ExprKind.proc_expr, name = "proc", line = line, column = col)

        if kind == token.TokenKind.tk_if:
            this.advance()
            this.parse_expression()
            if this.match_kind(token.TokenKind.tk_colon):
                this.parse_expression()
                if this.match_kind(token.TokenKind.tk_else):
                    if this.check(token.TokenKind.tk_colon):
                        this.advance()
                    this.parse_expression()
            return nodes.Expr(kind = nodes.ExprKind.if_expr, name = "if", line = line, column = col)

        if kind == token.TokenKind.tk_match:
            this.advance()
            this.parse_expression()
            if this.match_kind(token.TokenKind.tk_colon):
                this.skip_newlines()
                if this.match_kind(token.TokenKind.tk_indent):
                    while not this.at_end() and not this.check(token.TokenKind.tk_dedent):
                        this.skip_newlines()
                        if this.check(token.TokenKind.tk_dedent):
                            break
                        this.parse_expression()
                        if this.check(token.TokenKind.tk_colon):
                            this.advance()
                            this.skip_newlines()
            if this.match_kind(token.TokenKind.tk_indent):
                while not this.at_end() and not this.check(token.TokenKind.tk_dedent) and this.peek_kind() != token.TokenKind.tk_eof:
                    this.skip_newlines()
                    if this.check(token.TokenKind.tk_dedent) or this.peek_kind() == token.TokenKind.tk_eof:
                        break
                    this.parse_expression()
                    if this.match_kind(token.TokenKind.tk_as):
                        this.expect_id()
                    if this.check(token.TokenKind.tk_colon):
                        this.advance()
                    this.skip_newlines()
                    if this.match_kind(token.TokenKind.tk_indent):
                        this.parse_block()
                    else if not this.check(token.TokenKind.tk_dedent):
                        this.parse_expression()
                this.skip_dedent()
            return nodes.Expr(kind = nodes.ExprKind.match_expr, name = "match", line = line, column = col)

        if kind == token.TokenKind.tk_unsafe:
            this.advance()
            if this.match_kind(token.TokenKind.tk_colon):
                this.parse_expression()
            else:
                this.skip_newlines()
                if this.match_kind(token.TokenKind.tk_indent):
                    this.parse_block()
            return nodes.Expr(kind = nodes.ExprKind.if_expr, name = "unsafe", line = line, column = col)

        if this.match_kind(token.TokenKind.tk_lparen):
            var expr = this.parse_expression()
            this.expect(token.TokenKind.tk_rparen)
            return expr

        if this.check(token.TokenKind.tk_less):
            var lex = ""
            this.advance()
            if this.match_kind(token.TokenKind.tk_minus):
                lex = "<-"
                var target = this.parse_expression()
                return nodes.Expr(kind = nodes.ExprKind.prefix_cast, name = target.name, lexeme = lex, line = line, column = col)
            return nodes.Expr(kind = nodes.ExprKind.identifier, name = "<", line = line, column = col)

        this.skip_expr_value()
        return nodes.Expr(kind = nodes.ExprKind.identifier, name = "?", line = line, column = col)


    ## --- STATEMENT / BLOCK PARSING ---

    editable function skip_expr_value() -> void:
        var depth: ptr_uint = 0
        while not this.at_end() and this.pos < this.tokens.len():
            let kind = this.peek_kind()
            if kind == token.TokenKind.tk_newline or kind == token.TokenKind.tk_dedent or kind == token.TokenKind.tk_eof:
                break
            if kind == token.TokenKind.tk_colon and depth == 0:
                break
            if kind == token.TokenKind.tk_lparen or kind == token.TokenKind.tk_lbracket:
                depth += 1
            else if kind == token.TokenKind.tk_rparen or kind == token.TokenKind.tk_rbracket:
                if depth > 0:
                    depth -= 1
            this.advance()


    editable function parse_block() -> vec.Vec[nodes.Stmt]:
        var stmts = vec.Vec[nodes.Stmt].create()
        while not this.at_end() and not this.check(token.TokenKind.tk_dedent) and this.peek_kind() != token.TokenKind.tk_eof:
            this.skip_newlines()
            if this.check(token.TokenKind.tk_dedent) or this.peek_kind() == token.TokenKind.tk_eof:
                break
            var stmt = this.parse_statement()
            stmts.push(stmt)
        this.skip_dedent()
        return stmts


    editable function skip_block_body() -> void:
        var stmts = this.parse_block()
        stmts.release()


    editable function parse_statement() -> nodes.Stmt:
        let line = this.tok_line()
        let col = this.tok_col()
        let kind = this.peek_kind()

        if kind == token.TokenKind.tk_if or kind == token.TokenKind.tk_while or kind == token.TokenKind.tk_for or kind == token.TokenKind.tk_match or kind == token.TokenKind.tk_when:
            this.advance()
            this.parse_expression()
            if this.check(token.TokenKind.tk_colon):
                this.advance()
            this.skip_newlines()
            if this.match_kind(token.TokenKind.tk_indent):
                this.parse_block()
            if kind == token.TokenKind.tk_if and this.match_kind(token.TokenKind.tk_else):
                if this.check(token.TokenKind.tk_if):
                    this.parse_statement()
                else:
                    if this.check(token.TokenKind.tk_colon):
                        this.advance()
                    this.skip_newlines()
                    if this.match_kind(token.TokenKind.tk_indent):
                        this.parse_block()
            var stmt_kind = nodes.StmtKind.if_stmt
            if kind == token.TokenKind.tk_while:
                stmt_kind = nodes.StmtKind.while_stmt
            else if kind == token.TokenKind.tk_for:
                stmt_kind = nodes.StmtKind.for_stmt
            else if kind == token.TokenKind.tk_match:
                stmt_kind = nodes.StmtKind.match_stmt
            else if kind == token.TokenKind.tk_when:
                stmt_kind = nodes.StmtKind.block
            return nodes.Stmt(kind = stmt_kind, line = line, column = col)

        if kind == token.TokenKind.tk_inline:
            this.advance()
            if this.check(token.TokenKind.tk_for) or this.check(token.TokenKind.tk_while) or this.check(token.TokenKind.tk_match) or this.check(token.TokenKind.tk_if):
                this.advance()
                this.parse_expression()
                if this.check(token.TokenKind.tk_colon):
                    this.advance()
                this.skip_newlines()
                if this.match_kind(token.TokenKind.tk_indent):
                    this.parse_block()
            return nodes.Stmt(kind = nodes.StmtKind.block, line = line, column = col)

        if kind == token.TokenKind.tk_let or kind == token.TokenKind.tk_var:
            this.advance()
            var name = this.expect_id()
            if this.match_kind(token.TokenKind.tk_colon):
                this.parse_type_text()
            if this.match_kind(token.TokenKind.tk_equal) or this.check(token.TokenKind.tk_colon):
                this.parse_expression()
            if this.match_kind(token.TokenKind.tk_else):
                if this.check(token.TokenKind.tk_colon):
                    this.advance()
                this.skip_newlines()
                if this.match_kind(token.TokenKind.tk_indent):
                    this.parse_block()
            return nodes.Stmt(kind = if kind == token.TokenKind.tk_let: nodes.StmtKind.local_let else: nodes.StmtKind.local_var, name = name, line = line, column = col)

        if kind == token.TokenKind.tk_return:
            this.advance()
            if not this.check(token.TokenKind.tk_newline) and not this.check(token.TokenKind.tk_dedent):
                this.parse_expression()
            return nodes.Stmt(kind = nodes.StmtKind.return_stmt, line = line, column = col)

        if kind == token.TokenKind.tk_defer:
            this.advance()
            if this.check(token.TokenKind.tk_colon):
                this.advance()
                this.skip_newlines()
                if this.match_kind(token.TokenKind.tk_indent):
                    this.parse_block()
            else:
                this.parse_expression()
            return nodes.Stmt(kind = nodes.StmtKind.defer_stmt, line = line, column = col)

        if kind == token.TokenKind.tk_unsafe:
            this.advance()
            if this.check(token.TokenKind.tk_colon):
                this.parse_expression()
            else:
                this.skip_newlines()
                if this.match_kind(token.TokenKind.tk_indent):
                    this.parse_block()
            return nodes.Stmt(kind = nodes.StmtKind.unsafe_stmt, line = line, column = col)

        if kind == token.TokenKind.tk_break:
            this.advance()
            return nodes.Stmt(kind = nodes.StmtKind.break_stmt, line = line, column = col)

        if kind == token.TokenKind.tk_continue:
            this.advance()
            return nodes.Stmt(kind = nodes.StmtKind.continue_stmt, line = line, column = col)

        if kind == token.TokenKind.tk_pass:
            this.advance()
            return nodes.Stmt(kind = nodes.StmtKind.pass_stmt, line = line, column = col)

        if kind == token.TokenKind.tk_parallel:
            this.advance()
            if this.match_kind(token.TokenKind.tk_for):
                this.parse_expression()
                if this.check(token.TokenKind.tk_colon):
                    this.advance()
                this.skip_newlines()
                if this.match_kind(token.TokenKind.tk_indent):
                    this.parse_block()
            else if this.check(token.TokenKind.tk_colon):
                this.advance()
                this.skip_newlines()
                if this.match_kind(token.TokenKind.tk_indent):
                    this.parse_block()
            return nodes.Stmt(kind = nodes.StmtKind.for_stmt, line = line, column = col)

        if kind == token.TokenKind.tk_static_assert or kind == token.TokenKind.tk_emit:
            this.advance()
            this.skip_bracketed(token.TokenKind.tk_lparen, token.TokenKind.tk_rparen)
            return nodes.Stmt(kind = nodes.StmtKind.block, line = line, column = col)

        if kind == token.TokenKind.tk_gather:
            this.advance()
            this.parse_expression()
            return nodes.Stmt(kind = nodes.StmtKind.block, line = line, column = col)

        var expr = this.parse_expression()
        if this.check(token.TokenKind.tk_colon):
            this.advance()
            this.skip_newlines()
            if this.match_kind(token.TokenKind.tk_indent):
                this.parse_block()
        return nodes.Stmt(kind = nodes.StmtKind.expression_stmt, name = expr.name, line = line, column = col)
