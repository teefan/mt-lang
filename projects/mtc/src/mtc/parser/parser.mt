import std.str
import std.vec as vec
import std.mem.heap as heap

import mtc.lexer.token
import mtc.ast.nodes


public struct Parser:
    source_text: str
    tokens: vec.Vec[token.Token]
    pos: ptr_uint
    nested_decls: vec.Vec[nodes.Decl]


extending Parser:
    public static function create(source_text: str, tokens: vec.Vec[token.Token]) -> Parser:
        return Parser(source_text = source_text, tokens = tokens, pos = 0, nested_decls = vec.Vec[nodes.Decl].create())


    function at_end() -> bool:
        return this.pos >= this.tokens.len()


    function peek_tok() -> token.Token:
        let t = this.tokens.get(this.pos) else:
            return token.Token(kind = token.TokenKind.tk_eof, lexeme = "", line = 0, column = 0, src_offset = 0)
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
        var is_external = false
        this.skip_newlines()

        if this.match_kind(token.TokenKind.tk_external):
            is_external = true
            this.skip_newlines()

        while not this.at_end():
            this.skip_newlines()
            if not this.check(token.TokenKind.tk_import):
                break
            this.parse_import(ref_of(imports))

        if is_external:
            while not this.at_end():
                this.skip_newlines()
                if this.check(token.TokenKind.tk_include) or this.check(token.TokenKind.tk_link) or this.check(token.TokenKind.tk_compiler_flag):
                    this.advance()
                    this.skip_expr_value()
                else:
                    break

        while not this.at_end() and this.peek_kind() != token.TokenKind.tk_eof:
            this.skip_newlines()
            if this.at_end() or this.peek_kind() == token.TokenKind.tk_eof:
                break
            var decl = this.parse_declaration()
            if decl.name != "":
                decls.push(decl)
            var ni: ptr_uint = 0
            while ni < this.nested_decls.len():
                let nd = this.nested_decls.get(ni) else:
                    break
                let nested = unsafe: read(nd)
                if nested.name != "":
                    decls.push(nested)
                ni += 1
            this.nested_decls.clear()

        return nodes.SourceFile(module_name = "", imports = imports, decls = decls, is_external = is_external, line = 1)


    editable function parse_import(imports: ref[vec.Vec[nodes.Import]]) -> void:
        let line = this.tok_line()
        let col = this.tok_col()
        this.expect(token.TokenKind.tk_import)
        let first_tok = this.peek_tok()
        var path_start = first_tok.src_offset
        var path_len: ptr_uint = 0
        var first = this.expect_word()
        path_len += first.len
        while this.match_kind(token.TokenKind.tk_dot):
            path_len += 1
            var part = this.expect_word()
            path_len += part.len
        var alias = ""
        if this.match_kind(token.TokenKind.tk_as):
            alias = this.expect_id()
        var full_path = this.source_text.slice(path_start, path_len)
        imports.push(nodes.Import(path = full_path, alias = alias, line = line, column = col))


    editable function expect_word() -> str:
        if this.at_end():
            return ""
        let kind = this.peek_kind()
        if kind == token.TokenKind.tk_identifier:
            let name = this.tok_lexeme()
            this.advance()
            return name
        if kind >= token.TokenKind.tk_align_of and kind <= token.TokenKind.tk_while:
            let name = this.tok_lexeme()
            this.advance()
            return name
        this.advance()
        return ""


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
            return nodes.Decl(kind = nodes.DeclKind.const_decl, name = "", line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)
        if this.check(token.TokenKind.tk_attribute):
            this.advance()
            this.skip_expr_value()
            this.skip_newlines()
            return nodes.Decl(kind = nodes.DeclKind.const_decl, name = "", line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)
        if this.check(token.TokenKind.tk_when):
            this.advance()
            this.skip_expr_value()
            if this.expect(token.TokenKind.tk_colon):
                pass
            this.skip_newlines()
            if this.match_kind(token.TokenKind.tk_indent):
                this.skip_block_body()
            return nodes.Decl(kind = nodes.DeclKind.const_decl, name = "", line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)
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
            return nodes.Decl(kind = nodes.DeclKind.const_decl, name = "", line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)

        this.advance()
        return nodes.Decl(kind = nodes.DeclKind.const_decl, name = "", line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)


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
        var rtype_node: ptr[nodes.Type]? = null
        if this.match_kind(token.TokenKind.tk_arrow):
            rtype_node = this.parse_type()
        this.expect(token.TokenKind.tk_colon)
        this.skip_newlines()
        this.skip_indent()
        var body_start: ptr_uint = 0
        if not this.at_end():
            body_start = this.peek_tok().src_offset
        var body = this.parse_block()
        var body_end: ptr_uint = 0
        if not this.at_end():
            body_end = this.peek_tok().src_offset
        var count = unsafe: body.stmts.len()
        return nodes.Decl(kind = nodes.DeclKind.function_def, name = name, params = params, return_node = rtype_node, is_const_fn = is_const, is_async = is_async, stmt_count = count, body_block = body, line = line, column = col, type_node = null, value_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = body_start, body_src_end = body_end)


    editable function parse_extern_function() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.expect(token.TokenKind.tk_function)
        let name = this.expect_id()
        var params = this.empty_params()
        this.expect(token.TokenKind.tk_lparen)
        this.parse_param_list(ref_of(params))
        this.expect(token.TokenKind.tk_rparen)
        var rtype_node: ptr[nodes.Type]? = null
        if this.match_kind(token.TokenKind.tk_arrow):
            rtype_node = this.parse_type()
        if this.check(token.TokenKind.tk_ellipsis):
            this.advance()
        return nodes.Decl(kind = nodes.DeclKind.extern_function, name = name, params = params, return_node = rtype_node, is_extern = true, line = line, column = col, type_node = null, value_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)


    editable function parse_foreign_function() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.expect(token.TokenKind.tk_function)
        let name = this.expect_id()
        var params = this.empty_params()
        this.expect(token.TokenKind.tk_lparen)
        this.parse_param_list(ref_of(params))
        this.expect(token.TokenKind.tk_rparen)
        var rtype_node: ptr[nodes.Type]? = null
        if this.match_kind(token.TokenKind.tk_arrow):
            rtype_node = this.parse_type()
        var mapping = ""
        if this.match_kind(token.TokenKind.tk_equal):
            if this.check(token.TokenKind.tk_identifier):
                var mname = this.tok_lexeme()
                this.advance()
                var mp_ptr = this.tokens.get(this.pos - 1)
                var mp_start: ptr_uint = 0
                if mp_ptr != null:
                    mp_start = unsafe: read(mp_ptr).src_offset
                var mp_len: ptr_uint = mname.len
                while this.match_kind(token.TokenKind.tk_dot):
                    mp_len += 1
                    var part = this.expect_word()
                    mp_len += part.len
                mapping = this.source_text.slice(mp_start, mp_len)
        return nodes.Decl(kind = nodes.DeclKind.foreign_function, name = name, params = params, return_node = rtype_node, mapping = mapping, line = line, column = col, type_node = null, value_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), body_src_start = 0, body_src_end = 0)


    editable function parse_struct() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        this.skip_bracketed(token.TokenKind.tk_lbracket, token.TokenKind.tk_rbracket)
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
            if this.check(token.TokenKind.tk_public) or this.check(token.TokenKind.tk_event) or this.check(token.TokenKind.tk_at):
                while not this.at_end() and not this.check(token.TokenKind.tk_newline) and not this.check(token.TokenKind.tk_dedent):
                    this.advance()
                continue
            if this.check(token.TokenKind.tk_struct):
                var nested = this.parse_struct()
                this.nested_decls.push(nested)
                continue
            let fname = this.expect_id()
            this.expect(token.TokenKind.tk_colon)
            let ftype_node = this.parse_type()
            fields.push(nodes.Field(name = fname, type_node = ftype_node, line = line, column = col))
        this.skip_dedent()
        return nodes.Decl(kind = nodes.DeclKind.struct_decl, name = name, impl_list = impls, fields = fields, line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), return_node = null, members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), mapping = "")


    editable function parse_enum() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        var btype_node: ptr[nodes.Type]? = null
        if this.match_kind(token.TokenKind.tk_colon):
            btype_node = this.parse_type()
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
        return nodes.Decl(kind = nodes.DeclKind.enum_decl, name = name, type_node = btype_node, members = members, line = line, column = col, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)


    editable function parse_flags() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        var btype_node: ptr[nodes.Type]? = null
        if this.match_kind(token.TokenKind.tk_colon):
            btype_node = this.parse_type()
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
        return nodes.Decl(kind = nodes.DeclKind.flags_decl, name = name, type_node = btype_node, members = members, line = line, column = col, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)


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
                    let ftype_node = this.parse_type()
                    afields.push(nodes.Field(name = fname, type_node = ftype_node, line = line, column = col))
                    if not this.match_kind(token.TokenKind.tk_comma):
                        break
                this.expect(token.TokenKind.tk_rparen)
            arms.push(nodes.VariantArm(name = aname, fields = afields))
        this.skip_dedent()
        return nodes.Decl(kind = nodes.DeclKind.variant_decl, name = name, arms = arms, line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)


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
            var rtype_node: ptr[nodes.Type]? = null
            if this.match_kind(token.TokenKind.tk_arrow):
                rtype_node = this.parse_type()
            methods.push(nodes.Decl(kind = nodes.DeclKind.function_def, name = mname, params = mparams, return_node = rtype_node, line = line, column = col, type_node = null, value_text = "", fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0))
        this.skip_dedent()
        return nodes.Decl(kind = nodes.DeclKind.interface_decl, name = name, methods = methods, line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)


    editable function parse_type_alias() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        this.expect(token.TokenKind.tk_equal)
        let target_node = this.parse_type()
        return nodes.Decl(kind = nodes.DeclKind.type_alias, name = name, type_node = target_node, line = line, column = col, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)


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
        return nodes.Decl(kind = nodes.DeclKind.opaque_decl, name = name, impl_list = impls, line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), mapping = "")


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
            if this.check(token.TokenKind.tk_public) or this.check(token.TokenKind.tk_event) or this.check(token.TokenKind.tk_at):
                while not this.at_end() and not this.check(token.TokenKind.tk_newline) and not this.check(token.TokenKind.tk_dedent):
                    this.advance()
                continue
            let fname = this.expect_id()
            this.expect(token.TokenKind.tk_colon)
            let ftype_node = this.parse_type()
            fields.push(nodes.Field(name = fname, type_node = ftype_node, line = line, column = col))
        this.skip_dedent()
        return nodes.Decl(kind = nodes.DeclKind.union_decl, name = name, fields = fields, line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), return_node = null, members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)


    editable function parse_const_var(is_const: bool) -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()

        if this.match_kind(token.TokenKind.tk_arrow):
            var vtype_node = this.parse_type()
            this.expect(token.TokenKind.tk_colon)
            this.skip_newlines()
            this.skip_indent()
            var body_start: ptr_uint = 0
            if not this.at_end():
                body_start = this.peek_tok().src_offset
            var body = this.parse_block()
            var body_end: ptr_uint = 0
            if not this.at_end():
                body_end = this.peek_tok().src_offset
            var count = unsafe: body.stmts.len()
            return nodes.Decl(kind = if is_const: nodes.DeclKind.const_decl else: nodes.DeclKind.var_decl, name = name, type_node = vtype_node, stmt_count = count, body_block = body, line = line, column = col, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = body_start, body_src_end = body_end)

        this.expect(token.TokenKind.tk_colon)
        let vtype_node = this.parse_type()
        if this.match_kind(token.TokenKind.tk_equal):
            this.skip_expr_value()
        return nodes.Decl(kind = if is_const: nodes.DeclKind.const_decl else: nodes.DeclKind.var_decl, name = name, type_node = vtype_node, line = line, column = col, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)


    editable function parse_event() -> nodes.Decl:
        let line = this.tok_line()
        let col = this.tok_col()
        this.advance()
        let name = this.expect_id()
        if this.match_kind(token.TokenKind.tk_lbracket):
            if this.check(token.TokenKind.tk_integer):
                this.advance()
            this.expect(token.TokenKind.tk_rbracket)
        return nodes.Decl(kind = nodes.DeclKind.event_decl, name = name, line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)


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
            var rtype_node: ptr[nodes.Type]? = null
            if this.match_kind(token.TokenKind.tk_arrow):
                rtype_node = this.parse_type()
            this.expect(token.TokenKind.tk_colon)
            this.skip_newlines()
            this.skip_indent()
            this.skip_block_body()
            methods.push(nodes.Decl(kind = nodes.DeclKind.function_def, name = mname, return_node = rtype_node, line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), methods = this.empty_methods(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0))
        this.skip_dedent()
        return nodes.Decl(kind = nodes.DeclKind.extending_block, name = type_name, methods = methods, line = line, column = col, type_node = null, value_text = "", params = this.empty_params(), return_node = null, fields = this.empty_fields(), members = this.empty_members(), arms = this.empty_arms(), impl_list = this.empty_impls(), mapping = "", body_src_start = 0, body_src_end = 0)


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
            let ptype_node = this.parse_type()
            if this.match_kind(token.TokenKind.tk_as):
                this.parse_type()
            params.push(nodes.Param(name = pname, type_node = ptype_node, line = this.tok_line(), column = this.tok_col()))
            if not this.match_kind(token.TokenKind.tk_comma):
                break


    editable function parse_type() -> ptr[nodes.Type]?:
        var base = this.parse_type_base()
        if base == null:
            return null
        if this.match_kind(token.TokenKind.tk_question):
            var tp = self_alloc_type(nodes.TypeKind.type_nullable, "")
            unsafe:
                tp.inner = base
            return tp
        return base


    editable function parse_type_base() -> ptr[nodes.Type]?:
        let kind = this.peek_kind()

        if kind == token.TokenKind.tk_identifier:
            var name = this.tok_lexeme()
            this.advance()

            var tp_start: ptr_uint = name.len
            var prev_ptr = this.tokens.get(this.pos - 1)
            if prev_ptr != null:
                tp_start = unsafe: read(prev_ptr).src_offset

            var tp_len: ptr_uint = name.len
            while this.match_kind(token.TokenKind.tk_dot):
                tp_len += 1
                var part = this.expect_word()
                tp_len += part.len

            var full_name = this.source_text.slice(tp_start, tp_len)

            # Check for bracket args: ptr[int], vec.Vec[nodes.Decl], str_buffer[512]
            if this.match_kind(token.TokenKind.tk_lbracket):
                var inner_node: ptr[nodes.Type]? = null
                var size = ""

                if this.check(token.TokenKind.tk_rbracket):
                    pass
                else if this.check(token.TokenKind.tk_integer):
                    size = this.tok_lexeme()
                    this.advance()
                else:
                    inner_node = this.parse_type()
                    if this.match_kind(token.TokenKind.tk_comma):
                        if this.check(token.TokenKind.tk_integer):
                            size = this.tok_lexeme()
                            this.advance()
                        else:
                            this.parse_type()
                    # Skip additional type arguments (e.g. Pair[T, int] → skip "int")
                    while this.match_kind(token.TokenKind.tk_comma):
                        if this.check(token.TokenKind.tk_integer):
                            this.advance()
                        else if this.check(token.TokenKind.tk_rbracket):
                            break
                        else:
                            this.parse_type()

                # Skip lifetime annotation @[...]
                if this.match_kind(token.TokenKind.tk_at):
                    this.advance()
                    this.skip_bracketed(token.TokenKind.tk_lbracket, token.TokenKind.tk_rbracket)

                this.expect(token.TokenKind.tk_rbracket)

                var tp = self_alloc_type(nodes.TypeKind.type_constructed, full_name)
                unsafe:
                    tp.inner = inner_node
                    tp.size_text = size
                return tp

            var tp = self_alloc_type(nodes.TypeKind.type_named, full_name)
            return tp

        if kind == token.TokenKind.tk_fn or kind == token.TokenKind.tk_proc:
            this.advance()
            this.skip_bracketed(token.TokenKind.tk_lparen, token.TokenKind.tk_rparen)
            if this.match_kind(token.TokenKind.tk_arrow):
                this.parse_type()
            return self_alloc_type(nodes.TypeKind.type_named, "fn")

        return null


    ## --- EXPRESSION PARSING ---

    public editable function parse_expression() -> nodes.Expr:
        return this.parse_or()


    editable function parse_or() -> nodes.Expr:
        var expr = this.parse_and()
        while this.match_kind(token.TokenKind.tk_or):
            var right = this.parse_and()
            expr = nodes.Expr(kind = nodes.ExprKind.binary_op, name = "or", left = self_heapify(expr), right = self_heapify(right), args = self_empty_args(), line = this.tok_line(), column = this.tok_col())
        return expr


    editable function parse_and() -> nodes.Expr:
        var expr = this.parse_equality()
        while this.match_kind(token.TokenKind.tk_and):
            var right = this.parse_equality()
            expr = nodes.Expr(kind = nodes.ExprKind.binary_op, name = "and", left = self_heapify(expr), right = self_heapify(right), args = self_empty_args(), line = this.tok_line(), column = this.tok_col())
        return expr


    editable function parse_equality() -> nodes.Expr:
        var expr = this.parse_comparison()
        while this.check(token.TokenKind.tk_equal_equal) or this.check(token.TokenKind.tk_bang_equal):
            var op = if this.peek_kind() == token.TokenKind.tk_equal_equal: "==" else: "!="
            this.advance()
            var right = this.parse_comparison()
            expr = nodes.Expr(kind = nodes.ExprKind.binary_op, name = op, left = self_heapify(expr), right = self_heapify(right), args = self_empty_args(), line = this.tok_line(), column = this.tok_col())
        return expr


    editable function parse_comparison() -> nodes.Expr:
        var expr = this.parse_additive()
        while this.check(token.TokenKind.tk_less) or this.check(token.TokenKind.tk_less_equal) or this.check(token.TokenKind.tk_greater) or this.check(token.TokenKind.tk_greater_equal):
            var op = this.tok_lexeme()
            this.advance()
            var right = this.parse_additive()
            expr = nodes.Expr(kind = nodes.ExprKind.binary_op, name = op, left = self_heapify(expr), right = self_heapify(right), args = self_empty_args(), line = this.tok_line(), column = this.tok_col())
        return expr


    editable function parse_additive() -> nodes.Expr:
        var expr = this.parse_multiplicative()
        while this.check(token.TokenKind.tk_plus) or this.check(token.TokenKind.tk_minus):
            var op = this.tok_lexeme()
            this.advance()
            var right = this.parse_multiplicative()
            expr = nodes.Expr(kind = nodes.ExprKind.binary_op, name = op, left = self_heapify(expr), right = self_heapify(right), args = self_empty_args(), line = this.tok_line(), column = this.tok_col())
        return expr


    editable function parse_multiplicative() -> nodes.Expr:
        var expr = this.parse_unary()
        while this.check(token.TokenKind.tk_star) or this.check(token.TokenKind.tk_slash) or this.check(token.TokenKind.tk_percent):
            var op = this.tok_lexeme()
            this.advance()
            var right = this.parse_unary()
            expr = nodes.Expr(kind = nodes.ExprKind.binary_op, name = op, left = self_heapify(expr), right = self_heapify(right), args = self_empty_args(), line = this.tok_line(), column = this.tok_col())
        return expr


    editable function parse_unary() -> nodes.Expr:
        if this.match_kind(token.TokenKind.tk_not) or this.match_kind(token.TokenKind.tk_minus):
            var op = this.tok_lexeme()
            if op == "":
                op = "-"
            var operand = this.parse_unary()
            return nodes.Expr(kind = nodes.ExprKind.unary_op, name = op, left = self_heapify(operand), args = self_empty_args(), line = this.tok_line(), column = this.tok_col())
        if this.match_kind(token.TokenKind.tk_await):
            var expr = this.parse_unary()
            return nodes.Expr(kind = nodes.ExprKind.await_expr, left = self_heapify(expr), args = self_empty_args(), line = this.tok_line(), column = this.tok_col())
        return this.parse_postfix()


    editable function parse_postfix() -> nodes.Expr:
        var expr = this.parse_primary()

        while true:
            if this.match_kind(token.TokenKind.tk_dot):
                var member = this.expect_id()
                expr = nodes.Expr(kind = nodes.ExprKind.member_access, name = member, left = self_heapify(expr), args = self_empty_args(), line = this.tok_line(), column = this.tok_col())
            else if this.match_kind(token.TokenKind.tk_as):
                var bind = this.expect_id()
                expr = nodes.Expr(kind = nodes.ExprKind.identifier, name = bind, left = self_heapify(expr), args = self_empty_args(), line = this.tok_line(), column = this.tok_col())
            else if this.match_kind(token.TokenKind.tk_lparen):
                var call_args = self_empty_args()
                if not this.check(token.TokenKind.tk_rparen):
                    while true:
                        var arg: ptr[nodes.Expr]? = self_heapify(this.parse_expression())
                        call_args.push(arg)
                        if this.match_kind(token.TokenKind.tk_equal):
                            var named_val: ptr[nodes.Expr]? = self_heapify(this.parse_expression())
                            call_args.push(named_val)
                        if not this.match_kind(token.TokenKind.tk_comma):
                            break
                this.expect(token.TokenKind.tk_rparen)
                expr = nodes.Expr(kind = nodes.ExprKind.call, name = expr.name, left = self_heapify(expr), args = call_args, line = this.tok_line(), column = this.tok_col())
            else if this.match_kind(token.TokenKind.tk_lbracket):
                var idx = this.parse_expression()
                while this.match_kind(token.TokenKind.tk_comma):
                    this.parse_expression()
                this.expect(token.TokenKind.tk_rbracket)
                expr = nodes.Expr(kind = nodes.ExprKind.index_access, name = idx.name, left = self_heapify(expr), right = self_heapify(idx), args = self_empty_args(), line = this.tok_line(), column = this.tok_col())
            else if this.match_kind(token.TokenKind.tk_question):
                expr = nodes.Expr(kind = nodes.ExprKind.await_expr, left = self_heapify(expr), args = self_empty_args(), line = this.tok_line(), column = this.tok_col())
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
            return nodes.Expr(kind = nodes.ExprKind.integer_literal, lexeme = lex, name = lex, args = self_empty_args(), line = line, column = col)

        if kind == token.TokenKind.tk_float:
            var lex = this.tok_lexeme()
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.float_literal, lexeme = lex, name = lex, args = self_empty_args(), line = line, column = col)

        if kind == token.TokenKind.tk_string or kind == token.TokenKind.tk_cstring:
            var lex = this.tok_lexeme()
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.string_literal, lexeme = lex, name = lex, args = self_empty_args(), line = line, column = col)

        if kind == token.TokenKind.tk_char_literal:
            var lex = this.tok_lexeme()
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.char_literal, lexeme = lex, name = lex, args = self_empty_args(), line = line, column = col)

        if kind == token.TokenKind.tk_true or kind == token.TokenKind.tk_false:
            var lex = this.tok_lexeme()
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.boolean_literal, lexeme = lex, name = lex, args = self_empty_args(), line = line, column = col)

        if kind == token.TokenKind.tk_null:
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.null_literal, name = "null", args = self_empty_args(), line = line, column = col)

        if kind == token.TokenKind.tk_identifier:
            var name = this.tok_lexeme()
            this.advance()
            return nodes.Expr(kind = nodes.ExprKind.identifier, name = name, lexeme = name, args = self_empty_args(), line = line, column = col)

        if kind == token.TokenKind.tk_proc:
            this.advance()
            if this.match_kind(token.TokenKind.tk_lparen):
                while not this.check(token.TokenKind.tk_rparen) and not this.at_end():
                    this.advance()
                this.expect(token.TokenKind.tk_rparen)
            if this.match_kind(token.TokenKind.tk_arrow):
                this.parse_type()
            if this.match_kind(token.TokenKind.tk_colon):
                this.skip_newlines()
                if this.match_kind(token.TokenKind.tk_indent):
                    this.parse_block()
                else:
                    this.parse_expression()
            return nodes.Expr(kind = nodes.ExprKind.proc_expr, name = "proc", args = self_empty_args(), line = line, column = col)

        if kind == token.TokenKind.tk_if:
            this.advance()
            this.parse_expression()
            if this.match_kind(token.TokenKind.tk_colon):
                this.parse_expression()
                if this.match_kind(token.TokenKind.tk_else):
                    if this.check(token.TokenKind.tk_colon):
                        this.advance()
                    this.parse_expression()
            return nodes.Expr(kind = nodes.ExprKind.if_expr, name = "if", args = self_empty_args(), line = line, column = col)

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
            return nodes.Expr(kind = nodes.ExprKind.match_expr, name = "match", args = self_empty_args(), line = line, column = col)

        if kind == token.TokenKind.tk_unsafe:
            this.advance()
            if this.match_kind(token.TokenKind.tk_colon):
                var inner = self_heapify(this.parse_expression())
                return nodes.Expr(kind = nodes.ExprKind.await_expr, left = inner, args = self_empty_args(), line = line, column = col)

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
                return nodes.Expr(kind = nodes.ExprKind.prefix_cast, name = target.name, lexeme = lex, args = self_empty_args(), line = line, column = col)
            return nodes.Expr(kind = nodes.ExprKind.identifier, name = "<", args = self_empty_args(), line = line, column = col)

        this.skip_expr_value()
        return nodes.Expr(kind = nodes.ExprKind.identifier, name = "?", args = self_empty_args(), line = line, column = col)


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


    editable function parse_block() -> ptr[nodes.Block]:
        var block = self_alloc_block()
        while not this.at_end() and not this.check(token.TokenKind.tk_dedent) and this.peek_kind() != token.TokenKind.tk_eof:
            this.skip_newlines()
            if this.check(token.TokenKind.tk_dedent) or this.peek_kind() == token.TokenKind.tk_eof:
                break
            var stmt = this.parse_statement()
            unsafe:
                block.stmts.push(stmt)
        this.skip_dedent()
        return block


    editable function skip_block_body() -> void:
        var block = this.parse_block()
        unsafe:
            block.stmts.release()


    editable function parse_statement() -> nodes.Stmt:
        let line = this.tok_line()
        let col = this.tok_col()
        let kind = this.peek_kind()

        if kind == token.TokenKind.tk_if or kind == token.TokenKind.tk_while or kind == token.TokenKind.tk_for or kind == token.TokenKind.tk_match or kind == token.TokenKind.tk_when:
            this.advance()
            var cond_expr = self_heapify(this.parse_expression())
            if this.check(token.TokenKind.tk_colon):
                this.advance()
            this.skip_newlines()
            var body_block: ptr[nodes.Block]? = null
            if this.match_kind(token.TokenKind.tk_indent):
                body_block = this.parse_block()
            var else_block: ptr[nodes.Block]? = null
            if kind == token.TokenKind.tk_if and this.match_kind(token.TokenKind.tk_else):
                if this.check(token.TokenKind.tk_if):
                    this.parse_statement()
                else:
                    if this.check(token.TokenKind.tk_colon):
                        this.advance()
                    this.skip_newlines()
                    if this.match_kind(token.TokenKind.tk_indent):
                        else_block = this.parse_block()
            var stmt_kind = nodes.StmtKind.if_stmt
            if kind == token.TokenKind.tk_while:
                stmt_kind = nodes.StmtKind.while_stmt
            else if kind == token.TokenKind.tk_for:
                stmt_kind = nodes.StmtKind.for_stmt
            else if kind == token.TokenKind.tk_match:
                stmt_kind = nodes.StmtKind.match_stmt
            else if kind == token.TokenKind.tk_when:
                stmt_kind = nodes.StmtKind.block
            return nodes.Stmt(kind = stmt_kind, expr = cond_expr, body = body_block, else_body = else_block, line = line, column = col)

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
            var tp_node: ptr[nodes.Type]? = null
            if this.match_kind(token.TokenKind.tk_colon):
                tp_node = this.parse_type()
            var init_expr: ptr[nodes.Expr]? = null
            if this.match_kind(token.TokenKind.tk_equal):
                init_expr = self_heapify(this.parse_expression())
            else if this.check(token.TokenKind.tk_colon):
                this.parse_expression()
            var else_block: ptr[nodes.Block]? = null
            if this.match_kind(token.TokenKind.tk_else):
                if this.match_kind(token.TokenKind.tk_as):
                    this.expect_id()
                if this.check(token.TokenKind.tk_colon):
                    this.advance()
                this.skip_newlines()
                if this.match_kind(token.TokenKind.tk_indent):
                    else_block = this.parse_block()
            return nodes.Stmt(kind = if kind == token.TokenKind.tk_let: nodes.StmtKind.local_let else: nodes.StmtKind.local_var, name = name, type_node = tp_node, expr = init_expr, else_body = else_block, line = line, column = col)

        if kind == token.TokenKind.tk_return:
            this.advance()
            var ret_expr: ptr[nodes.Expr]? = null
            if not this.check(token.TokenKind.tk_newline) and not this.check(token.TokenKind.tk_dedent):
                ret_expr = self_heapify(this.parse_expression())
            return nodes.Stmt(kind = nodes.StmtKind.return_stmt, expr = ret_expr, line = line, column = col)

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
        var next_kind = this.peek_kind()
        if next_kind == token.TokenKind.tk_equal or next_kind == token.TokenKind.tk_plus_equal or next_kind == token.TokenKind.tk_minus_equal or next_kind == token.TokenKind.tk_star_equal or next_kind == token.TokenKind.tk_slash_equal or next_kind == token.TokenKind.tk_percent_equal or next_kind == token.TokenKind.tk_amp_equal or next_kind == token.TokenKind.tk_pipe_equal or next_kind == token.TokenKind.tk_caret_equal or next_kind == token.TokenKind.tk_shift_left_equal or next_kind == token.TokenKind.tk_shift_right_equal:
            var op = this.tok_lexeme()
            this.advance()
            var rhs = self_heapify(this.parse_expression())
            return nodes.Stmt(kind = nodes.StmtKind.expression_stmt, name = op, expr = self_heapify(expr), value = rhs, line = line, column = col)

        if this.check(token.TokenKind.tk_colon):
            this.advance()
            this.skip_newlines()
            if this.match_kind(token.TokenKind.tk_indent):
                this.parse_block()
        return nodes.Stmt(kind = nodes.StmtKind.expression_stmt, expr = self_heapify(expr), line = line, column = col)


function self_alloc_type(kind: nodes.TypeKind, name: str) -> ptr[nodes.Type]:
    let tp = heap.must_alloc[nodes.Type](1)
    unsafe:
        tp.kind = kind
        tp.name = name
        tp.inner = null
        tp.size_text = ""
    return tp


function self_heapify(expr: nodes.Expr) -> ptr[nodes.Expr]:
    let heap_expr = heap.must_alloc[nodes.Expr](1)
    unsafe: read(heap_expr) = expr
    return heap_expr

function self_empty_args() -> vec.Vec[ptr[nodes.Expr]?]:
    return vec.Vec[ptr[nodes.Expr]?].create()


function self_alloc_block() -> ptr[nodes.Block]:
    let blk = heap.must_alloc[nodes.Block](1)
    unsafe:
        blk.stmts = vec.Vec[nodes.Stmt].create()
    return blk

