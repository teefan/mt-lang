## Parser — Token stream → AST.
##
## Recursive descent with operator precedence climbing for expressions.
## All AST nodes are arena-allocated via Parser.arena.

import compiler.lexer.token as token_mod
import compiler.lexer.token_kind as tk
import compiler.parser.ast as ast
import compiler.parser.operators as ops_mod
import compiler.parser.token_cursor as cursor_mod
import std.intern
import std.mem.arena
import std.vec

type T = tk.TokenKind
type B = ops_mod.BinaryOp

struct Parser:
    cur: cursor_mod.Cursor
    arena: arena.Arena
    source: span[ubyte]
    interner: ptr[intern.Interner]
    ## Pre-interned type constructor names for O(1) ident comparison.
    id_underscore: ast.IdentId
    id_ptr: ast.IdentId
    id_const_ptr: ast.IdentId
    id_span: ast.IdentId
    id_ref: ast.IdentId
    id_array: ast.IdentId


## ── entry ───────────────────────────────────────────────────────────

public function parse(
    source: span[ubyte],
    tokens: span[token_mod.Token],
    interner: ptr[intern.Interner],
) -> ptr[ast.SourceFile]:
    var p = Parser(
        cur = cursor_mod.create(tokens),
        arena = arena.create(32 * 1024 * 1024),
        source = source,
        interner = interner,
        id_underscore = 0,
        id_ptr = 0,
        id_const_ptr = 0,
        id_span = 0,
        id_ref = 0,
        id_array = 0,
    )
    p.init_interned_ids()
    let file = p.parse_module()
    return file




## ── extending Parser ────────────────────────────────────────────────

extending Parser:
    ## ── interned identifiers ──────────────────────────────────────────

    editable function init_interned_ids() -> void:
        unsafe:
            this.id_underscore = this.interner.intern("_")
            this.id_ptr = this.interner.intern("ptr")
            this.id_const_ptr = this.interner.intern("const_ptr")
            this.id_span = this.interner.intern("span")
            this.id_ref = this.interner.intern("ref")
            this.id_array = this.interner.intern("array")


    ## ── list-end helper ──────────────────────────────────────────
    ##
    ## Consumes DEDENT that may appear before a closing delimiter
    ## (rparen or rbracket) in multiline parameter/field lists.
    ## Used by all comma-separated list parsers.

    editable function consume_list_end(kind: tk.TokenKind) -> void:
        this.skip_newlines()
        if this.cur.current().kind == T.tk_dedent:
            this.cur.advance()
            this.skip_newlines()
        this.expect(kind)

    ## ── arena helpers ───────────────────────────────────────────────

    editable function new_decl(value: ast.Decl) -> ptr[ast.Decl]:
        let p = this.arena.alloc[ast.Decl](1) else:
            fatal(c"parser: arena exhausted")
        unsafe: read(p) = value
        return p

    editable function new_stmt(value: ast.Stmt) -> ptr[ast.Stmt]:
        let p = this.arena.alloc[ast.Stmt](1) else:
            fatal(c"parser: arena exhausted")
        unsafe: read(p) = value
        return p

    editable function new_expr(value: ast.Expr) -> ptr[ast.Expr]:
        let p = this.arena.alloc[ast.Expr](1) else:
            fatal(c"parser: arena exhausted")
        unsafe: read(p) = value
        return p

    editable function new_type(value: ast.Type) -> ptr[ast.Type]:
        let p = this.arena.alloc[ast.Type](1) else:
            fatal(c"parser: arena exhausted")
        unsafe: read(p) = value
        return p

    editable function new_file(value: ast.SourceFile) -> ptr[ast.SourceFile]:
        let p = this.arena.alloc[ast.SourceFile](1) else:
            fatal(c"parser: arena exhausted")
        unsafe: read(p) = value
        return p

    editable function new_pattern(value: ast.Pattern) -> ptr[ast.Pattern]:
        let p = this.arena.alloc[ast.Pattern](1) else:
            fatal(c"parser: arena exhausted")
        unsafe: read(p) = value
        return p

    editable function span_of_params(src: ref[vec.Vec[ast.Param]]) -> span[ast.Param]:
        if src.len == 0:
            return span[ast.Param](data = zero[ptr[ast.Param]], len = 0)
        let storage = this.arena.alloc[ast.Param](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ast.Param](data = storage, len = src.len)

    editable function span_of_exprs(src: ref[vec.Vec[ptr[ast.Expr]]]) -> span[ptr[ast.Expr]]:
        if src.len == 0:
            return span[ptr[ast.Expr]](data = zero[ptr[ptr[ast.Expr]]], len = 0)
        let storage = this.arena.alloc[ptr[ast.Expr]](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ptr[ast.Expr]](data = storage, len = src.len)

    editable function span_of_stmts(src: ref[vec.Vec[ptr[ast.Stmt]]]) -> span[ptr[ast.Stmt]]:
        if src.len == 0:
            return span[ptr[ast.Stmt]](data = zero[ptr[ptr[ast.Stmt]]], len = 0)
        let storage = this.arena.alloc[ptr[ast.Stmt]](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ptr[ast.Stmt]](data = storage, len = src.len)

    editable function span_of_types(src: ref[vec.Vec[ptr[ast.Type]]]) -> span[ptr[ast.Type]]:
        if src.len == 0:
            return span[ptr[ast.Type]](data = zero[ptr[ptr[ast.Type]]], len = 0)
        let storage = this.arena.alloc[ptr[ast.Type]](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ptr[ast.Type]](data = storage, len = src.len)

    editable function span_of_fields(src: ref[vec.Vec[ast.Field]]) -> span[ast.Field]:
        if src.len == 0:
            return span[ast.Field](data = zero[ptr[ast.Field]], len = 0)
        let storage = this.arena.alloc[ast.Field](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ast.Field](data = storage, len = src.len)

    editable function span_of_methods(src: ref[vec.Vec[ast.ExtendingMethod]]) -> span[ast.ExtendingMethod]:
        if src.len == 0:
            return span[ast.ExtendingMethod](data = zero[ptr[ast.ExtendingMethod]], len = 0)
        let storage = this.arena.alloc[ast.ExtendingMethod](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ast.ExtendingMethod](data = storage, len = src.len)

    editable function span_of_ident_ids(src: ref[vec.Vec[ast.IdentId]]) -> span[ast.IdentId]:
        if src.len == 0:
            return span[ast.IdentId](data = zero[ptr[ast.IdentId]], len = 0)
        let storage = this.arena.alloc[ast.IdentId](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ast.IdentId](data = storage, len = src.len)

    editable function span_of_tuple_fields(src: ref[vec.Vec[ast.TupleField]]) -> span[ast.TupleField]:
        if src.len == 0:
            return span[ast.TupleField](data = zero[ptr[ast.TupleField]], len = 0)
        let storage = this.arena.alloc[ast.TupleField](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ast.TupleField](data = storage, len = src.len)

    editable function span_of_bindings(src: ref[vec.Vec[ast.ForBinding]]) -> span[ast.ForBinding]:
        if src.len == 0:
            return span[ast.ForBinding](data = zero[ptr[ast.ForBinding]], len = 0)
        let storage = this.arena.alloc[ast.ForBinding](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ast.ForBinding](data = storage, len = src.len)

    editable function span_of_enum_members(src: ref[vec.Vec[ast.EnumMember]]) -> span[ast.EnumMember]:
        if src.len == 0:
            return span[ast.EnumMember](data = zero[ptr[ast.EnumMember]], len = 0)
        let storage = this.arena.alloc[ast.EnumMember](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ast.EnumMember](data = storage, len = src.len)

    editable function span_of_variant_arms(src: ref[vec.Vec[ast.VariantArmDecl]]) -> span[ast.VariantArmDecl]:
        if src.len == 0:
            return span[ast.VariantArmDecl](data = zero[ptr[ast.VariantArmDecl]], len = 0)
        let storage = this.arena.alloc[ast.VariantArmDecl](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ast.VariantArmDecl](data = storage, len = src.len)

    editable function span_of_match_arms(src: ref[vec.Vec[ast.MatchArm]]) -> span[ast.MatchArm]:
        if src.len == 0:
            return span[ast.MatchArm](data = zero[ptr[ast.MatchArm]], len = 0)
        let storage = this.arena.alloc[ast.MatchArm](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ast.MatchArm](data = storage, len = src.len)

    editable function span_of_branches(src: ref[vec.Vec[ast.IfBranch]]) -> span[ast.IfBranch]:
        if src.len == 0:
            return span[ast.IfBranch](data = zero[ptr[ast.IfBranch]], len = 0)
        let storage = this.arena.alloc[ast.IfBranch](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ast.IfBranch](data = storage, len = src.len)

    editable function span_of_pattern_fields(src: ref[vec.Vec[ast.PatternField]]) -> span[ast.PatternField]:
        if src.len == 0:
            return span[ast.PatternField](data = zero[ptr[ast.PatternField]], len = 0)
        let storage = this.arena.alloc[ast.PatternField](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ast.PatternField](data = storage, len = src.len)

    ## ── module ──────────────────────────────────────────────────────

    editable function parse_module() -> ptr[ast.SourceFile]:
        var imports = vec.Vec[ptr[ast.Decl]].create()
        var decls = vec.Vec[ptr[ast.Decl]].create()

        while not this.cur.at_end():
            this.skip_newlines()
            if this.cur.at_end():
                break
            if this.at_indent_end():
                if this.cur.current().kind == T.tk_dedent:
                    this.cur.advance()
                break

            let tok = this.cur.current()
            if tok.kind == T.tk_kw_import:
                let import_decl = this.parse_import()
                imports.push(import_decl)
            else:
                let decl = this.parse_declaration()
                decls.push(decl)

        let file = ast.SourceFile(name = "", imports = imports, decls = decls)
        return this.new_file(file)


    ## ── imports ─────────────────────────────────────────────────────

    editable function parse_import() -> ptr[ast.Decl]:
        var parts = vec.Vec[ast.IdentId].create()
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_import)
        let start = start_tok.start
        while true:
            let tok = this.cur.current()
            parts.push(tok.ident)
            this.cur.advance()
            if this.cur.at_end() or this.cur.current().kind != T.tk_dot:
                break
            this.cur.advance()

        var alias: ast.IdentId = 0
        if not this.cur.at_end() and this.cur.current().kind == T.tk_kw_as:
            this.cur.advance()
            alias = this.cur.current().ident
            this.cur.advance()

        let end = this.cur_end()
        let path_span = this.span_of_ident_ids(ref_of(parts))
        let loc = this.make_loc(start, end)
        let decl = ast.Decl.import_decl(path = path_span, alias = alias, loc = loc)
        return this.new_decl(decl)


    ## ── declarations ────────────────────────────────────────────────

    editable function parse_declaration() -> ptr[ast.Decl]:
        var vis = ast.Visibility.priv
        var tok = this.cur.current()
        if tok.kind == T.tk_kw_public:
            vis = ast.Visibility.pub
            this.cur.advance()
            tok = this.cur.current()

        match tok.kind:
            T.tk_kw_function:
                return this.parse_function_def(vis)
            T.tk_kw_struct:
                return this.parse_struct_def(vis)
            T.tk_kw_enum:
                return this.parse_enum_def(vis)
            T.tk_kw_variant:
                return this.parse_variant_decl(vis)
            T.tk_kw_extending:
                return this.parse_extending()
            T.tk_kw_type:
                return this.parse_type_alias(vis)
            T.tk_kw_external:
                return this.parse_external_decl(vis)
            _:
                this.skip_to_newline()
                let loc = this.make_loc(tok.start, this.cur_end())
                let decl = ast.Decl.error_decl(loc = loc)
                return this.new_decl(decl)


    ## ── function definition ─────────────────────────────────────────

    editable function parse_function_def(vis: ast.Visibility) -> ptr[ast.Decl]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_function)

        let name_tok = this.cur.current()
        this.expect(T.tk_identifier)
        let name = name_tok.ident

        this.expect(T.tk_lparen)
        var params = vec.Vec[ast.Param].create()

        while true:
            this.skip_newlines()
            if this.cur.current().kind == T.tk_rparen:
                break
            if this.at_indent_end():
                break
            if params.len > 0:
                this.skip_newlines()
                if this.cur.current().kind == T.tk_rparen or this.at_indent_end():
                    break
                this.expect(T.tk_comma)
                this.skip_newlines()
            if this.at_indent_end():
                break

            let param_name = this.cur.current()
            this.expect(T.tk_identifier)
            this.expect(T.tk_colon)
            let param_type = this.parse_type()
            params.push(ast.Param(
                name = param_name.ident,
                type_ref = param_type,
                loc = this.make_loc(param_name.start, param_name.end),
            ))

        this.consume_list_end(T.tk_rparen)

        var ret_type = zero[ptr[ast.Type]]
        if not this.cur.at_end() and this.cur.current().kind == T.tk_arrow:
            this.cur.advance()
            ret_type = this.parse_type()

        var body = zero[ptr[ast.Stmt]]
        if not this.cur.at_end() and this.cur.current().kind == T.tk_colon:
            this.cur.advance()
            body = this.parse_statements()

        if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
            this.cur.advance()

        let end = this.cur_end()
        let params_span = this.span_of_params(ref_of(params))
        let empty_tparams = span[ast.TypeParam](data = zero[ptr[ast.TypeParam]], len = 0)

        let decl = ast.Decl.function_def(
            name = name,
            type_params = empty_tparams,
            params = params_span,
            return_type = ret_type,
            body = body,
            visibility = vis,
            is_async = false,
            is_const = false,
            loc = this.make_loc(start_tok.start, end),
        )
        return this.new_decl(decl)


    ## ── struct definition ────────────────────────────────────────────

    editable function parse_struct_def(vis: ast.Visibility) -> ptr[ast.Decl]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_struct)

        let name_tok = this.cur.current()
        this.expect(T.tk_identifier)
        let name = name_tok.ident

        this.expect(T.tk_colon)
        this.expect(T.tk_indent)

        var fields = vec.Vec[ast.Field].create()

        while true:
            this.skip_newlines()
            if this.cur.at_end():
                break
            if this.cur.current().kind == T.tk_dedent:
                break
            if this.at_indent_end():
                break

            let field_name_tok = this.cur.current()
            this.expect(T.tk_identifier)
            this.expect(T.tk_colon)
            let field_type = this.parse_type()
            fields.push(ast.Field(
                name = field_name_tok.ident,
                type_ref = field_type,
                loc = this.make_loc(field_name_tok.start, this.cur_end()),
            ))

        if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
            this.cur.advance()
            this.skip_newlines()

        let end = this.cur_end()
        let fields_span = this.span_of_fields(ref_of(fields))
        let decl = ast.Decl.struct_decl(
            name = name,
            fields = fields_span,
            visibility = vis,
            loc = this.make_loc(start_tok.start, end),
        )
        return this.new_decl(decl)


    ## ── enum definition ──────────────────────────────────────────────

    editable function parse_enum_def(vis: ast.Visibility) -> ptr[ast.Decl]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_enum)

        let name_tok = this.cur.current()
        this.expect(T.tk_identifier)
        let name = name_tok.ident

        this.expect(T.tk_colon)
        let backing = this.parse_type()

        this.expect(T.tk_indent)

        var members = vec.Vec[ast.EnumMember].create()

        while true:
            this.skip_newlines()
            if this.cur.at_end():
                break
            if this.cur.current().kind == T.tk_dedent:
                break
            if this.at_indent_end():
                break

            let member_name_tok = this.cur.current()
            this.expect(T.tk_identifier)
            var val_expr = zero[ptr[ast.Expr]]
            if this.cur.current().kind == T.tk_equal:
                this.cur.advance()
                val_expr = this.parse_expression()

            members.push(ast.EnumMember(
                name = member_name_tok.ident,
                value = val_expr,
                loc = this.make_loc(member_name_tok.start, this.cur_end()),
            ))

        if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
            this.cur.advance()

        let end = this.cur_end()
        let members_span = this.span_of_enum_members(ref_of(members))
        let decl = ast.Decl.enum_decl(
            name = name,
            backing = backing,
            members = members_span,
            visibility = vis,
            loc = this.make_loc(start_tok.start, end),
        )
        return this.new_decl(decl)


    ## ── variant definition ────────────────────────────────────────────

    editable function parse_variant_decl(vis: ast.Visibility) -> ptr[ast.Decl]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_variant)
        let name_tok = this.cur.current()
        this.expect(T.tk_identifier)
        let name = name_tok.ident
        this.expect(T.tk_colon)
        this.expect(T.tk_indent)
        var arms = vec.Vec[ast.VariantArmDecl].create()
        while true:
            this.skip_newlines()
            if this.cur.at_end():
                break
            if this.cur.current().kind == T.tk_dedent:
                break
            if this.at_indent_end():
                break
            let arm_name_tok = this.cur.current()
            this.expect(T.tk_identifier)
            var arm_fields = vec.Vec[ast.Field].create()
            if not this.cur.at_end() and this.cur.current().kind == T.tk_lparen:
                this.cur.advance()
                while true:
                    this.skip_newlines()
                    if this.cur.current().kind == T.tk_rparen:
                        break
                    if this.at_indent_end():
                        break
                    if arm_fields.len > 0:
                        this.skip_newlines()
                        if this.cur.current().kind == T.tk_rparen or this.at_indent_end():
                            break
                        this.expect(T.tk_comma)
                        this.skip_newlines()
                    if this.at_indent_end():
                        break
                    let field_name_tok = this.cur.current()
                    this.expect(T.tk_identifier)
                    this.expect(T.tk_colon)
                    let field_type = this.parse_type()
                    arm_fields.push(ast.Field(
                        name = field_name_tok.ident,
                        type_ref = field_type,
                        loc = this.make_loc(field_name_tok.start, this.cur_end()),
                    ))
                this.consume_list_end(T.tk_rparen)
            arms.push(ast.VariantArmDecl(
                name = arm_name_tok.ident,
                fields = this.span_of_fields(ref_of(arm_fields)),
                loc = this.make_loc(arm_name_tok.start, this.cur_end()),
            ))
        if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
            this.cur.advance()
        let end = this.cur_end()
        let arms_span = this.span_of_variant_arms(ref_of(arms))
        let decl = ast.Decl.variant_decl(
            name = name,
            arms = arms_span,
            visibility = vis,
            loc = this.make_loc(start_tok.start, end),
        )
        return this.new_decl(decl)


    ## ── type alias ───────────────────────────────────────────────────

    editable function parse_type_alias(vis: ast.Visibility) -> ptr[ast.Decl]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_type)

        let name_tok = this.cur.current()
        this.expect(T.tk_identifier)
        let name = name_tok.ident

        this.expect(T.tk_equal)
        let target = this.parse_type()

        let end = this.cur_end()
        let decl = ast.Decl.type_alias(
            name = name,
            target = target,
            visibility = vis,
            loc = this.make_loc(start_tok.start, end),
        )
        return this.new_decl(decl)


    ## ── external declaration ──────────────────────────────────────────

    editable function parse_external_decl(vis: ast.Visibility) -> ptr[ast.Decl]:
        this.expect(T.tk_kw_external)

        if this.cur.current().kind == T.tk_kw_function:
            return this.parse_function_def(vis)
        if this.cur.current().kind == T.tk_kw_var:
            return this.parse_function_def(vis)

        ## bare `external` keyword for external file header
        let tok = this.cur.current()
        this.skip_to_newline()
        let loc = this.make_loc(tok.start, this.cur_end())
        let decl = ast.Decl.error_decl(loc = loc)
        return this.new_decl(decl)

    editable function parse_extending() -> ptr[ast.Decl]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_extending)

        let type_name_tok = this.cur.current()
        this.expect(T.tk_identifier)
        let type_name = type_name_tok.ident

        this.expect(T.tk_colon)
        this.expect(T.tk_indent)

        var methods = vec.Vec[ast.ExtendingMethod].create()

        while true:
            this.skip_newlines()
            if this.cur.at_end():
                break
            if this.cur.current().kind == T.tk_dedent:
                break
            if this.at_indent_end():
                break

            let method = this.parse_extending_method()
            methods.push(method)

        if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
            this.cur.advance()

        let end = this.cur_end()
        let methods_span = this.span_of_methods(ref_of(methods))
        let decl = ast.Decl.extending_decl(
            type_name = type_name,
            methods = methods_span,
            loc = this.make_loc(start_tok.start, end),
        )
        return this.new_decl(decl)


    editable function parse_extending_method() -> ast.ExtendingMethod:
        let start = this.cur.current().start
        var kind = ast.MethodKind.mk_plain

        if this.cur.current().kind == T.tk_kw_public:
            this.cur.advance()
        if this.cur.current().kind == T.tk_kw_editable:
            kind = ast.MethodKind.mk_editable
            this.cur.advance()
        else if this.cur.current().kind == T.tk_kw_static:
            kind = ast.MethodKind.mk_static
            this.cur.advance()

        this.expect(T.tk_kw_function)

        let name_tok = this.cur.current()
        this.expect(T.tk_identifier)
        let name = name_tok.ident

        this.expect(T.tk_lparen)
        var params = vec.Vec[ast.Param].create()

        while true:
            this.skip_newlines()
            if this.cur.current().kind == T.tk_rparen:
                break
            if this.at_indent_end():
                break
            if params.len > 0:
                this.skip_newlines()
                if this.cur.current().kind == T.tk_rparen or this.at_indent_end():
                    break
                this.expect(T.tk_comma)
                this.skip_newlines()
            if this.at_indent_end():
                break
            let param_name = this.cur.current()
            this.expect(T.tk_identifier)
            this.expect(T.tk_colon)
            let param_type = this.parse_type()
            params.push(ast.Param(
                name = param_name.ident,
                type_ref = param_type,
                loc = this.make_loc(param_name.start, param_name.end),
            ))

        this.consume_list_end(T.tk_rparen)

        var ret_type = zero[ptr[ast.Type]]
        if not this.cur.at_end() and this.cur.current().kind == T.tk_arrow:
            this.cur.advance()
            ret_type = this.parse_type()

        this.expect(T.tk_colon)
        let body = this.parse_statements()

        if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
            this.cur.advance()

        let end = this.cur_end()
        let params_span = this.span_of_params(ref_of(params))
        return ast.ExtendingMethod(
            name = name,
            params = params_span,
            return_type = ret_type,
            body = body,
            method_kind = kind,
            loc = this.make_loc(start, end),
        )


    ## ── type ────────────────────────────────────────────────────────

    editable function parse_type() -> ptr[ast.Type]:
        let base = this.parse_type_suffix()
        if not this.cur.at_end() and this.cur.current().kind == T.tk_question:
            let qmark = this.cur.current()
            this.cur.advance()
            let loc = this.make_loc(qmark.start, qmark.end)
            let t = ast.Type.nullable_type(inner = base, loc = loc)
            return this.new_type(t)
        return base


    editable function parse_type_suffix() -> ptr[ast.Type]:
        ## Peek at the identifier BEFORE parsing, so we can dispatch on
        ## type-constructor names (ptr / span / ref / etc.) after primary.
        var base_tok: token_mod.Token
        base_tok.kind = T.tk_eof
        base_tok.ident = 0
        base_tok.start = 0
        base_tok.end = 0
        base_tok.line = 0
        base_tok.col = 0
        if not this.cur.at_end() and this.cur.current().kind == T.tk_identifier:
            base_tok = this.cur.current()

        let base = this.parse_type_primary()

        var has_mod = false
        var mod_prefix: ast.IdentId
        if base_tok.kind == T.tk_eof:
            return base
        if this.cur.at_end():
            return base

        unsafe:
            match read(base):
                ast.Type.qualified_type(module_id, type_name, _):
                    base_tok.ident = type_name
                    mod_prefix = module_id
                    has_mod = true
                _:
                    pass

        if this.cur.current().kind != T.tk_lbracket:
            return base

        this.cur.advance()
        let result = this.parse_type_constructor(base_tok, has_mod, mod_prefix)
        this.expect(T.tk_rbracket)
        return result


    editable function parse_type_constructor(
        base_tok: token_mod.Token,
        has_mod: bool,
        mod_prefix: ast.IdentId,
    ) -> ptr[ast.Type]:
        if this.is_type_ptr(base_tok):
            let pointee = this.parse_type()
            return this.new_type(ast.Type.pointer_type(
                pointee = pointee,
                is_const = false,
                loc = this.make_loc(base_tok.start, this.cur_end()),
            ))

        if this.is_type_const_ptr(base_tok):
            let pointee = this.parse_type()
            return this.new_type(ast.Type.pointer_type(
                pointee = pointee,
                is_const = true,
                loc = this.make_loc(base_tok.start, this.cur_end()),
            ))

        if this.is_type_span(base_tok):
            let element = this.parse_type()
            return this.new_type(ast.Type.span_type(
                element = element,
                loc = this.make_loc(base_tok.start, this.cur_end()),
            ))

        if this.is_type_ref(base_tok):
            let pointee = this.parse_type()
            return this.new_type(ast.Type.ref_type(
                pointee = pointee,
                loc = this.make_loc(base_tok.start, this.cur_end()),
            ))

        if this.is_type_array(base_tok):
            let element = this.parse_type()
            this.expect(T.tk_comma)
            let size_tok = this.cur.current()
            this.expect(T.tk_integer)
            let size = this.read_ptruint(size_tok)
            return this.new_type(ast.Type.array_type(
                element = element,
                size = size,
                loc = this.make_loc(base_tok.start, this.cur_end()),
            ))

        ## Generic type with args: Name[T1, T2, ...] or Module.Name[T1, T2, ...]
        var type_args = vec.Vec[ptr[ast.Type]].create()
        type_args.push(this.parse_type())
        while not this.cur.at_end() and this.cur.current().kind == T.tk_comma:
            this.cur.advance()
            type_args.push(this.parse_type())
        if has_mod:
            return this.new_type(ast.Type.qualified_generic_type(
                module_id = mod_prefix,
                name = base_tok.ident,
                args = this.span_of_type_ptrs(ref_of(type_args)),
                loc = this.make_loc(base_tok.start, this.cur_end()),
            ))
        return this.new_type(ast.Type.generic_type(
            name = base_tok.ident,
            args = this.span_of_type_ptrs(ref_of(type_args)),
            loc = this.make_loc(base_tok.start, this.cur_end()),
        ))


    editable function parse_type_primary() -> ptr[ast.Type]:
        let tok = this.cur.current()

        if tok.kind == T.tk_kw_fn:
            this.cur.advance()
            return this.parse_fn_type(tok.start)

        if tok.kind == T.tk_kw_proc:
            this.cur.advance()
            return this.parse_proc_type(tok.start)

        return this.parse_named_type()


    editable function parse_named_type() -> ptr[ast.Type]:
        let tok = this.cur.current()
        this.expect(T.tk_identifier)
        let loc = this.make_loc(tok.start, tok.end)
        if not this.cur.at_end() and this.cur.current().kind == T.tk_dot:
            this.cur.advance()
            let member_tok = this.cur.current()
            this.expect(T.tk_identifier)
            let t = ast.Type.qualified_type(
                module_id = tok.ident,
                type_name = member_tok.ident,
                loc = this.make_loc(tok.start, member_tok.end),
            )
            return this.new_type(t)
        let t = ast.Type.named_type(name = tok.ident, loc = loc)
        return this.new_type(t)


    editable function expr_to_type(expr: ptr[ast.Expr]) -> ptr[ast.Type]:
        ## Convert an identifier expression to a named_type reference.
        ## Only used for <- cast left-hand-side.
        unsafe:
            match read(expr):
                ast.Expr.identifier(name, loc):
                    return this.new_type(ast.Type.named_type(name = name, loc = loc))
                _:
                    fatal(c"parser: expected type name before <-")


    editable function parse_fn_type(start: ptr_uint) -> ptr[ast.Type]:
        this.expect(T.tk_lparen)
        var params = vec.Vec[ast.Param].create()
        if this.cur.current().kind != T.tk_rparen:
            params.push(this.parse_one_param())
            while this.cur.current().kind == T.tk_comma:
                this.cur.advance()
                params.push(this.parse_one_param())
        this.expect(T.tk_rparen)
        this.expect(T.tk_arrow)
        let ret = this.parse_type()
        return this.new_type(ast.Type.fn_type(
            params = this.span_of_params(ref_of(params)),
            return_type = ret,
            loc = this.make_loc(start, this.cur_end()),
        ))


    editable function parse_proc_type(start: ptr_uint) -> ptr[ast.Type]:
        this.expect(T.tk_lparen)
        var params = vec.Vec[ast.Param].create()
        if this.cur.current().kind != T.tk_rparen:
            params.push(this.parse_one_param())
            while this.cur.current().kind == T.tk_comma:
                this.cur.advance()
                params.push(this.parse_one_param())
        this.expect(T.tk_rparen)
        this.expect(T.tk_arrow)
        let ret = this.parse_type()
        return this.new_type(ast.Type.proc_type(
            params = this.span_of_params(ref_of(params)),
            return_type = ret,
            loc = this.make_loc(start, this.cur_end()),
        ))


    ## ── statements ──────────────────────────────────────────────────

    editable function parse_statements() -> ptr[ast.Stmt]:
        var stmts = vec.Vec[ptr[ast.Stmt]].create()
        let start = this.cur.current().start

        while true:
            this.skip_newlines()
            if this.cur.at_end():
                break
            if this.at_indent_end():
                break

            let stmt = this.parse_statement()
            stmts.push(stmt)

        let end = this.cur_end()
        let stmts_span = this.span_of_stmts(ref_of(stmts))
        let loc = this.make_loc(start, end)
        let s = ast.Stmt.block(stmts = stmts_span, loc = loc)
        return this.new_stmt(s)


    editable function parse_statement() -> ptr[ast.Stmt]:
        let tok = this.cur.current()
        let start = tok.start
        match tok.kind:
            T.tk_kw_return:
                return this.parse_return_stmt()
            T.tk_kw_let | T.tk_kw_var:
                return this.parse_local_decl()
            T.tk_kw_if:
                return this.parse_if_stmt()
            T.tk_kw_while:
                return this.parse_while_stmt()
            T.tk_kw_unsafe:
                return this.parse_unsafe_stmt()
            T.tk_kw_match:
                return this.parse_match_stmt()
            T.tk_kw_for:
                return this.parse_for_stmt()
            T.tk_kw_break:
                this.cur.advance()
                let b_loc = this.make_loc(start, tok.end)
                return this.new_stmt(ast.Stmt.break_stmt(loc = b_loc))
            T.tk_kw_continue:
                this.cur.advance()
                let c_loc = this.make_loc(start, tok.end)
                return this.new_stmt(ast.Stmt.continue_stmt(loc = c_loc))
            T.tk_kw_pass:
                this.cur.advance()
                let loc = this.make_loc(start, tok.end)
                let s = ast.Stmt.pass_stmt(loc = loc)
                return this.new_stmt(s)
            _:
                return this.parse_expression_stmt()


    ## ── return ──────────────────────────────────────────────────────

    editable function parse_return_stmt() -> ptr[ast.Stmt]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_return)
        var val_expr = zero[ptr[ast.Expr]]
        if not this.cur.at_end() and not this.is_term(this.cur.current().kind):
            val_expr = this.parse_expression()
        let loc = this.make_loc(start_tok.start, this.cur_end())
        let s = ast.Stmt.return_stmt(value = val_expr, loc = loc)
        return this.new_stmt(s)


    ## ── if ───────────────────────────────────────────────────────────

    editable function parse_if_stmt() -> ptr[ast.Stmt]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_if)

        let condition = this.parse_expression()
        this.expect(T.tk_colon)
        this.expect(T.tk_indent)

        var then_body = this.parse_statements()

        if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
            this.cur.advance()

        var branches = vec.Vec[ast.IfBranch].create()
        branches.push(ast.IfBranch(
            condition = condition,
            body = then_body,
            loc = this.make_loc(start_tok.start, this.cur_end()),
        ))

        var else_body = zero[ptr[ast.Stmt]]
        if not this.cur.at_end() and this.cur.current().kind == T.tk_kw_else:
            this.cur.advance()
            if this.cur.current().kind == T.tk_colon:
                this.cur.advance()
                this.expect(T.tk_indent)
                else_body = this.parse_statements()
                if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
                    this.cur.advance()

        let end = this.cur_end()
        let branches_span = this.span_of_branches(ref_of(branches))
        let s = ast.Stmt.if_stmt(
            branches = branches_span,
            else_body = else_body,
            loc = this.make_loc(start_tok.start, end),
        )
        return this.new_stmt(s)


    ## ── while ─────────────────────────────────────────────────────────

    editable function parse_while_stmt() -> ptr[ast.Stmt]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_while)

        let condition = this.parse_expression()
        this.expect(T.tk_colon)
        this.expect(T.tk_indent)

        let body = this.parse_statements()

        if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
            this.cur.advance()

        let loc = this.make_loc(start_tok.start, this.cur_end())
        let s = ast.Stmt.while_stmt(condition = condition, body = body, loc = loc)
        return this.new_stmt(s)


    ## ── for ───────────────────────────────────────────────────────────

    editable function parse_for_stmt() -> ptr[ast.Stmt]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_for)

        let binding_tok = this.cur.current()
        this.expect(T.tk_identifier)
        let binding_name = binding_tok.ident

        this.expect(T.tk_kw_in)

        let iterable = this.parse_expression()
        this.expect(T.tk_colon)
        this.expect(T.tk_indent)

        let body = this.parse_statements()

        if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
            this.cur.advance()

        let end = this.cur_end()
        var bindings = vec.Vec[ast.ForBinding].create()
        bindings.push(ast.ForBinding(name = binding_name, loc = this.make_loc(binding_tok.start, binding_tok.end)))
        var iterables = vec.Vec[ptr[ast.Expr]].create()
        iterables.push(iterable)
        let s = ast.Stmt.for_stmt(
            bindings = this.span_of_bindings(ref_of(bindings)),
            iterables = this.span_of_exprs(ref_of(iterables)),
            body = body,
            loc = this.make_loc(start_tok.start, end),
        )
        return this.new_stmt(s)


    ## ── unsafe ────────────────────────────────────────────────────────

    editable function parse_unsafe_stmt() -> ptr[ast.Stmt]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_unsafe)
        this.expect(T.tk_colon)

        var body = zero[ptr[ast.Stmt]]
        if this.cur.current().kind == T.tk_indent:
            this.cur.advance()
            body = this.parse_statements()
            if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
                this.cur.advance()
        else:
            let expr = this.parse_expression()
            let loc = this.make_loc(start_tok.start, this.cur_end())
            let es = ast.Stmt.expression(expr = expr, loc = loc)
            body = this.new_stmt(es)

        let loc = this.make_loc(start_tok.start, this.cur_end())
        let s = ast.Stmt.unsafe_block(body = body, loc = loc)
        return this.new_stmt(s)


    ## ── match ─────────────────────────────────────────────────────────

    editable function parse_match_stmt() -> ptr[ast.Stmt]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_match)

        let scrutinee = this.parse_expression()
        this.expect(T.tk_colon)
        this.expect(T.tk_indent)

        var arms = vec.Vec[ast.MatchArm].create()

        while true:
            this.skip_newlines()
            if this.cur.at_end():
                break
            if this.cur.current().kind == T.tk_dedent:
                break
            if this.at_indent_end():
                break

            this.parse_match_arms(ref_of(arms))

        if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
            this.cur.advance()

        let end = this.cur_end()
        let arms_span = this.span_of_match_arms(ref_of(arms))
        let s = ast.Stmt.match_stmt(
            scrutinee = scrutinee,
            arms = arms_span,
            loc = this.make_loc(start_tok.start, end),
        )
        return this.new_stmt(s)


    editable function parse_match_arms(arms: ref[vec.Vec[ast.MatchArm]]) -> void:
        var patterns = vec.Vec[ptr[ast.Pattern]].create()

        let first = this.parse_match_pattern()
        patterns.push(first)

        while not this.cur.at_end() and this.cur.current().kind == T.tk_pipe:
            this.cur.advance()
            let next = this.parse_match_pattern()
            patterns.push(next)

        this.expect(T.tk_colon)
        this.expect(T.tk_indent)

        let body = this.parse_statements()

        if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
            this.cur.advance()

        var pi: ptr_uint = 0
        while pi < patterns.len:
            let pattern = patterns.at(pi) else:
                fatal(c"parser: vec access out of bounds")
            let loc = this.make_loc(0, 0)
            arms.push(ast.MatchArm(pattern = pattern, binding = 0, body = body, loc = loc))
            pi += 1


    editable function parse_match_pattern() -> ptr[ast.Pattern]:
        let tok = this.cur.current()

        if this.is_wildcard(tok):
            this.cur.advance()
            let loc = this.make_loc(tok.start, tok.end)
            let p = ast.Pattern.wildcard(loc = loc)
            return this.new_pattern(p)

        if tok.kind == T.tk_integer:
            let val = this.read_int(tok.start, tok.end)
            this.cur.advance()
            let loc = this.make_loc(tok.start, tok.end)
            let p = ast.Pattern.int_literal(value = val, loc = loc)
            return this.new_pattern(p)

        if tok.kind == T.tk_char_literal:
            let val = this.read_char(tok.start, tok.end)
            this.cur.advance()
            let loc = this.make_loc(tok.start, tok.end)
            let p = ast.Pattern.char_literal(value = val, loc = loc)
            return this.new_pattern(p)

        this.expect(T.tk_identifier)
        let name = tok.ident
        var loc = this.make_loc(tok.start, tok.end)

        if this.cur.current().kind == T.tk_dot:
            this.cur.advance()
            let member_tok = this.cur.current()
            this.expect(T.tk_identifier)
            loc = this.make_loc(tok.start, member_tok.end)

            var fields = vec.Vec[ast.PatternField].create()
            if not this.cur.at_end() and this.cur.current().kind == T.tk_lparen:
                this.cur.advance()
                while true:
                    let field_tok = this.cur.current()
                    if field_tok.kind == T.tk_rparen:
                        this.cur.advance()
                        break
                    if fields.len > 0:
                        this.expect(T.tk_comma)
                    if this.cur.current().kind == T.tk_rparen:
                        this.cur.advance()
                        break

                    if this.is_wildcard(this.cur.current()):
                        this.cur.advance()
                        fields.push(ast.PatternField(
                            name = 0,
                            value = zero[ptr[ast.Expr]],
                            is_guard = false,
                            loc = this.make_loc(field_tok.start, this.cur_end()),
                        ))
                    else:
                        this.expect(T.tk_identifier)
                        var fvalue = zero[ptr[ast.Expr]]
                        var fguard = false
                        if not this.cur.at_end() and this.cur.current().kind == T.tk_equal:
                            this.cur.advance()
                            fvalue = this.parse_expression()
                            fguard = true
                        fields.push(ast.PatternField(
                            name = field_tok.ident,
                            value = fvalue,
                            is_guard = fguard,
                            loc = this.make_loc(field_tok.start, this.cur_end()),
                        ))
                loc = this.make_loc(tok.start, this.cur_end())

            let p = ast.Pattern.variant_arm(
                type_name = name,
                arm_name = member_tok.ident,
                binding = 0,
                fields = this.span_of_pattern_fields(ref_of(fields)),
                loc = loc,
            )
            return this.new_pattern(p)

        let p = ast.Pattern.variant_arm(
            type_name = name,
            arm_name = 0,
            binding = 0,
            fields = span[ast.PatternField](data = zero[ptr[ast.PatternField]], len = 0),
            loc = loc,
        )
        return this.new_pattern(p)


    function is_wildcard(tok: token_mod.Token) -> bool:
        return tok.kind == T.tk_identifier and tok.ident == this.id_underscore


    function is_type_ptr(tok: token_mod.Token) -> bool:
        return tok.kind == T.tk_identifier and tok.ident == this.id_ptr


    function is_type_const_ptr(tok: token_mod.Token) -> bool:
        return tok.kind == T.tk_identifier and tok.ident == this.id_const_ptr


    function is_type_span(tok: token_mod.Token) -> bool:
        return tok.kind == T.tk_identifier and tok.ident == this.id_span


    function is_type_ref(tok: token_mod.Token) -> bool:
        return tok.kind == T.tk_identifier and tok.ident == this.id_ref


    function is_type_array(tok: token_mod.Token) -> bool:
        return tok.kind == T.tk_identifier and tok.ident == this.id_array


    editable function read_char(start: ptr_uint, end: ptr_uint) -> ubyte:
        var i: ptr_uint = start
        if i < end:
            unsafe:
                let first = read(this.source.data + i)
                if first == 39:
                    i += 1
        if i < end:
            unsafe:
                let ch = read(this.source.data + i)
                if ch == 92:
                    i += 1
                    if i < end:
                        let esc = read(this.source.data + i)
                        if esc == 110:
                            return 10
                        if esc == 114:
                            return 13
                        if esc == 116:
                            return 9
                        if esc == 48:
                            return 0
                        if esc == 120 and i + 2 < end:
                            return this.read_hex_byte(i + 1)
                        return esc
                    return 0
                return ch
        return 0


    function read_hex_byte(pos: ptr_uint) -> ubyte:
        var val: int = 0
        var j: ptr_uint = 0
        while j < 2:
            unsafe:
                let b = read(this.source.data + pos + j)
                if b >= 48 and b <= 57:
                    val = val * 16 + int<-b - 48
                else if b >= 65 and b <= 70:
                    val = val * 16 + int<-b - 65 + 10
                else if b >= 97 and b <= 102:
                    val = val * 16 + int<-b - 97 + 10
                else:
                    break
            j += 1
        return ubyte<-val


    ## ── expression statement ────────────────────────────────────────

    editable function parse_expression_stmt() -> ptr[ast.Stmt]:
        let start = this.cur.current().start
        let expr = this.parse_expression()

        if this.is_assign_op(this.cur.current().kind):
            let op = this.cur.current().kind
            this.cur.advance()
            let rhs = this.parse_expression()
            let loc = this.make_loc(start, this.cur_end())
            let s = ast.Stmt.assignment(target = expr, op = op, value = rhs, loc = loc)
            return this.new_stmt(s)

        let loc = this.make_loc(start, this.cur_end())
        let s = ast.Stmt.expression(expr = expr, loc = loc)
        return this.new_stmt(s)


    function is_assign_op(kind: tk.TokenKind) -> bool:
        if kind == tk.TokenKind.tk_equal:
            return true
        if kind == tk.TokenKind.tk_plus_equal:
            return true
        if kind == tk.TokenKind.tk_minus_equal:
            return true
        if kind == tk.TokenKind.tk_star_equal:
            return true
        if kind == tk.TokenKind.tk_slash_equal:
            return true
        if kind == tk.TokenKind.tk_percent_equal:
            return true
        if kind == tk.TokenKind.tk_amp_equal:
            return true
        if kind == tk.TokenKind.tk_pipe_equal:
            return true
        if kind == tk.TokenKind.tk_caret_equal:
            return true
        if kind == tk.TokenKind.tk_shift_left_equal:
            return true
        if kind == tk.TokenKind.tk_shift_right_equal:
            return true
        return false


    ## ── local declaration ───────────────────────────────────────────

    editable function parse_local_decl() -> ptr[ast.Stmt]:
        let kind_tok = this.cur.current()
        var kind = ast.DeclKind.dk_let
        if kind_tok.kind == T.tk_kw_var:
            kind = ast.DeclKind.dk_var
        this.cur.advance()

        let name_tok = this.cur.current()
        this.expect(T.tk_identifier)

        var type_ref = zero[ptr[ast.Type]]
        if this.cur.current().kind == T.tk_colon:
            this.cur.advance()
            type_ref = this.parse_type()

        var val_expr = zero[ptr[ast.Expr]]
        if this.cur.current().kind == T.tk_equal:
            this.cur.advance()
            val_expr = this.parse_expression()

        var else_binding: ast.IdentId = 0
        var else_body = zero[ptr[ast.Stmt]]

        if not this.cur.at_end() and this.cur.current().kind == T.tk_kw_else:
            this.cur.advance()
            if this.cur.current().kind == T.tk_kw_as:
                this.cur.advance()
                let bind_tok = this.cur.current()
                this.expect(T.tk_identifier)
                else_binding = bind_tok.ident
            this.expect(T.tk_colon)
            this.expect(T.tk_indent)
            else_body = this.parse_statements()
            if not this.cur.at_end() and this.cur.current().kind == T.tk_dedent:
                this.cur.advance()

        let loc = this.make_loc(kind_tok.start, this.cur_end())
        let s = ast.Stmt.local_decl(
            kind = kind,
            name = name_tok.ident,
            type_ref = type_ref,
            value = val_expr,
            else_binding = else_binding,
            else_body = else_body,
            loc = loc,
        )
        return this.new_stmt(s)


    ## ── expressions ─────────────────────────────────────────────────

    editable function parse_expression() -> ptr[ast.Expr]:
        return this.parse_binary(0)


    editable function parse_binary(min_prec: int) -> ptr[ast.Expr]:
        var left = this.parse_prefix()

        if not this.cur.at_end() and this.cur.current().kind == T.tk_dot_dot:
            let dot_start = this.cur.current().start
            this.cur.advance()
            let right = this.parse_binary(0)
            let loc = this.make_loc(dot_start, this.cur_end())
            let e = ast.Expr.range_expr(start = left, end = right, loc = loc)
            left = this.new_expr(e)

        if not this.cur.at_end() and this.cur.current().kind == T.tk_larrow:
            let target_type = this.expr_to_type(left)
            this.cur.advance()
            let right = this.parse_binary(11)
            let loc = this.make_loc(0, this.cur_end())
            let e = ast.Expr.cast_expr(target_type = target_type, expr = right, loc = loc)
            left = this.new_expr(e)

        while true:
            if this.cur.at_end():
                break

            let tok = this.cur.current()
            let prec = this.precedence(tok.kind)
            if prec < min_prec:
                break

            let op = this.kind_to_binary_op(tok.kind)
            this.cur.advance()
            let right = this.parse_binary(prec + 1)

            let loc = this.make_loc(tok.start, this.cur_end())
            let e = ast.Expr.binary_op(operator = op, left = left, right = right, loc = loc)
            left = this.new_expr(e)

        return left


    editable function parse_prefix() -> ptr[ast.Expr]:
        let tok = this.cur.current()
        match tok.kind:
            T.tk_minus:
                this.cur.advance()
                let operand = this.parse_prefix()
                let loc = this.make_loc(tok.start, this.cur_end())
                let e = ast.Expr.unary_op(operator = ops_mod.UnaryOp.uop_negate, operand = operand, loc = loc)
                return this.new_expr(e)
            T.tk_identifier:
                return this.parse_identifier()
            T.tk_integer:
                return this.parse_integer()
            T.tk_float:
                this.cur.advance()
                return this.alloc_error_expr(tok)
            T.tk_string:
                return this.parse_string()
            T.tk_kw_true:
                this.cur.advance()
                return this.new_expr(ast.Expr.bool_literal(value = true, loc = this.make_loc(tok.start, tok.end)))
            T.tk_kw_false:
                this.cur.advance()
                return this.new_expr(ast.Expr.bool_literal(value = false, loc = this.make_loc(tok.start, tok.end)))
            T.tk_kw_null:
                this.cur.advance()
                return this.new_expr(ast.Expr.null_literal(loc = this.make_loc(tok.start, tok.end)))
            T.tk_lparen:
                return this.parse_paren_or_tuple()
            _:
                this.cur.advance()
                return this.alloc_error_expr(tok)


    editable function parse_identifier() -> ptr[ast.Expr]:
        let tok = this.cur.current()
        this.cur.advance()

        var base = this.id_to_expr(tok)

        while true:
            if this.cur.at_end():
                return base
            let next = this.cur.current()
            if next.kind == T.tk_lparen:
                base = this.parse_call_expr(base, tok)
            else if next.kind == T.tk_lbracket:
                base = this.parse_specialization_expr(base)
            else if next.kind == T.tk_dot:
                this.cur.advance()
                let member_tok = this.cur.current()
                this.expect(T.tk_identifier)
                let loc = this.make_loc(tok.start, member_tok.end)
                let e = ast.Expr.member_access(receiver = base, member = member_tok.ident, loc = loc)
                base = this.new_expr(e)
            else:
                break

        return base


    editable function id_to_expr(tok: token_mod.Token) -> ptr[ast.Expr]:
        let loc = this.make_loc(tok.start, tok.end)
        let e = ast.Expr.identifier(name = tok.ident, loc = loc)
        return this.new_expr(e)


    editable function parse_integer() -> ptr[ast.Expr]:
        let tok = this.cur.current()
        this.cur.advance()
        let loc = this.make_loc(tok.start, tok.end)
        let value = this.read_int(tok.start, tok.end)
        let e = ast.Expr.integer_literal(value = value, loc = loc)
        return this.new_expr(e)


    function read_int(start: ptr_uint, end: ptr_uint) -> int:
        var val: int = 0
        var negative = false
        var i: ptr_uint = start
        if i < end:
            unsafe:
                let first = this.source.data + i
                if read(first) == 45:
                    negative = true
                    i += 1
        var base: int = 10
        if i + 1 < end:
            unsafe:
                let p = this.source.data + i
                if read(p) == 48:
                    let next = read(p + 1)
                    if next == 120 or next == 88:
                        base = 16
                        i += 2
                    else if next == 98 or next == 66:
                        base = 8
                        i += 2
        while i < end:
            unsafe:
                let ch = read(this.source.data + i)
                var digit: int = 0
                if ch >= 48 and ch <= 57:
                    digit = int<-ch - 48
                else if ch >= 65 and ch <= 70:
                    digit = int<-ch - 65 + 10
                else if ch >= 97 and ch <= 102:
                    digit = int<-ch - 97 + 10
                else:
                    break
                val = val * base + digit
            i += 1
        if negative:
            return 0 - val
        return val


    function read_ptruint(tok: token_mod.Token) -> ptr_uint:
        let v = this.read_int(tok.start, tok.end)
        return ptr_uint<-v


    editable function span_of_type_ptrs(src: ref[vec.Vec[ptr[ast.Type]]]) -> span[ptr[ast.Type]]:
        if src.len == 0:
            return span[ptr[ast.Type]](data = zero[ptr[ptr[ast.Type]]], len = 0)
        let storage = this.arena.alloc[ptr[ast.Type]](src.len) else:
            fatal(c"parser: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"parser: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ptr[ast.Type]](data = storage, len = src.len)


    editable function parse_one_param() -> ast.Param:
        let param_name = this.cur.current()
        this.expect(T.tk_identifier)
        this.expect(T.tk_colon)
        let param_type = this.parse_type()
        return ast.Param(
            name = param_name.ident,
            type_ref = param_type,
            loc = this.make_loc(param_name.start, param_name.end),
        )


    editable function parse_string() -> ptr[ast.Expr]:
        let tok = this.cur.current()
        this.cur.advance()
        let loc = this.make_loc(tok.start, tok.end)
        var is_cstr = tok.kind == T.tk_cstring
        ## TODO: extract string content from source bytes and create str value.
        ## Currently passes empty string; sufficient for error messages since the
        ## self-hosted compiler only uses cstrings in fatal() calls.
        let e = ast.Expr.string_literal(text = "", is_cstr = is_cstr, loc = loc)
        return this.new_expr(e)


    ## ── call ────────────────────────────────────────────────────────

    editable function parse_call_expr(callee: ptr[ast.Expr], name_tok: token_mod.Token) -> ptr[ast.Expr]:
        this.expect(T.tk_lparen)
        var args = vec.Vec[ptr[ast.Expr]].create()
        var fields = vec.Vec[ast.TupleField].create()
        var is_aggregate = false
        let start = name_tok.start

        while true:
            if this.cur.current().kind == T.tk_rparen:
                break
            if args.len > 0 or fields.len > 0:
                if this.cur.current().kind != T.tk_comma:
                    break
                this.cur.advance()

            if not is_aggregate and this.has_named_arg_ahead():
                is_aggregate = true

            if is_aggregate:
                let fn_tok = this.cur.current()
                this.expect(T.tk_identifier)
                this.expect(T.tk_equal)
                let fv = this.parse_expression()
                fields.push(ast.TupleField(
                    name = fn_tok.ident,
                    value = fv,
                    loc = this.make_loc(fn_tok.start, this.cur_end()),
                ))
            else:
                let arg = this.parse_expression()
                args.push(arg)

        this.expect(T.tk_rparen)
        let end = this.cur_end()

        if is_aggregate:
            var has_member = false
            var agg_type: ast.IdentId
            var agg_arm: ast.IdentId
            unsafe:
                match read(callee):
                    ast.Expr.member_access(receiver, member, _):
                        has_member = true
                        agg_arm = member
                        match read(receiver):
                            ast.Expr.identifier(name, _):
                                agg_type = name
                            _:
                                pass
                    ast.Expr.identifier(name, _):
                        agg_type = name
                    _:
                        pass
            let fields_span = this.span_of_tuple_fields(ref_of(fields))
            let loc = this.make_loc(start, end)
            if has_member:
                let e = ast.Expr.variant_ctor(
                    type_name = agg_type,
                    arm_name = agg_arm,
                    fields = fields_span,
                    loc = loc,
                )
                return this.new_expr(e)
            let e = ast.Expr.aggregate(type_name = agg_type, fields = fields_span, loc = loc)
            return this.new_expr(e)

        let args_span = this.span_of_exprs(ref_of(args))
        let loc = this.make_loc(start, end)
        let e = ast.Expr.call(callee = callee, args = args_span, loc = loc)
        return this.new_expr(e)


    function has_named_arg_ahead() -> bool:
        if this.cur.at_end():
            return false
        let tok = this.cur.current()
        if tok.kind != T.tk_identifier:
            return false
        let cur_pos = this.cur.pos
        let cur_end = this.cur.tokens.len
        if cur_pos + 1 >= cur_end:
            return false
        unsafe:
            let next_tok = read(this.cur.tokens.data + cur_pos + 1)
            return next_tok.kind == T.tk_equal


    function callee_ident(callee: ptr[ast.Expr]) -> ast.IdentId:
        unsafe:
            match read(callee):
                ast.Expr.identifier(name, _):
                    return name
                _:
                    return 0


    ## ── specialization ──────────────────────────────────────────────

    editable function parse_specialization_expr(callee: ptr[ast.Expr]) -> ptr[ast.Expr]:
        this.expect(T.tk_lbracket)
        var ta_args = vec.Vec[ptr[ast.Type]].create()

        while true:
            this.skip_newlines()
            if this.cur.current().kind == T.tk_rbracket:
                break
            if this.at_indent_end():
                break
            if ta_args.len > 0:
                this.skip_newlines()
                if this.cur.current().kind == T.tk_rbracket or this.at_indent_end():
                    break
                this.expect(T.tk_comma)
                this.skip_newlines()
            if this.at_indent_end():
                break
            let arg = this.parse_type()
            ta_args.push(arg)

        this.consume_list_end(T.tk_rbracket)
        let end = this.cur_end()
        let ta_span = this.span_of_types(ref_of(ta_args))
        let loc = this.make_loc(0, end)
        let e = ast.Expr.specialization(callee = callee, args = ta_span, loc = loc)
        return this.new_expr(e)


    ## ── parens / tuple ──────────────────────────────────────────────

    editable function parse_paren_or_tuple() -> ptr[ast.Expr]:
        this.cur.advance()
        let expr = this.parse_expression()
        this.expect(T.tk_rparen)
        return expr


    ## ── token helpers ───────────────────────────────────────────────

    editable function expect(kind: tk.TokenKind) -> void:
        if this.cur.current().kind != kind:
            this.skip_to_newline()
            return
        this.cur.advance()


    ## ── precedence ──────────────────────────────────────────────────

    function precedence(kind: tk.TokenKind) -> int:
        if kind == T.tk_kw_or:
            return 1
        if kind == T.tk_kw_and:
            return 2
        if kind == T.tk_pipe:
            return 3
        if kind == T.tk_caret:
            return 4
        if kind == T.tk_amp:
            return 5
        if kind == T.tk_equal_equal or kind == T.tk_bang_equal:
            return 6
        if kind == T.tk_less or kind == T.tk_less_equal or kind == T.tk_greater or kind == T.tk_greater_equal:
            return 7
        if kind == T.tk_shift_left or kind == T.tk_shift_right:
            return 8
        if kind == T.tk_plus or kind == T.tk_minus:
            return 9
        if kind == T.tk_star or kind == T.tk_slash or kind == T.tk_percent:
            return 10
        return -1


    function kind_to_binary_op(kind: tk.TokenKind) -> B:
        if kind == T.tk_plus:
            return B.op_add
        if kind == T.tk_minus:
            return B.op_sub
        if kind == T.tk_star:
            return B.op_mul
        if kind == T.tk_slash:
            return B.op_div
        if kind == T.tk_percent:
            return B.op_mod
        if kind == T.tk_amp:
            return B.op_bit_and
        if kind == T.tk_pipe:
            return B.op_bit_or
        if kind == T.tk_caret:
            return B.op_bit_xor
        if kind == T.tk_shift_left:
            return B.op_shift_left
        if kind == T.tk_shift_right:
            return B.op_shift_right
        if kind == T.tk_equal_equal:
            return B.op_eq
        if kind == T.tk_bang_equal:
            return B.op_ne
        if kind == T.tk_less:
            return B.op_lt
        if kind == T.tk_less_equal:
            return B.op_le
        if kind == T.tk_greater:
            return B.op_gt
        if kind == T.tk_greater_equal:
            return B.op_ge
        if kind == T.tk_kw_and:
            return B.op_logic_and
        if kind == T.tk_kw_or:
            return B.op_logic_or
        return B.op_add


    ## ── utilities ───────────────────────────────────────────────────

    editable function skip_newlines() -> void:
        while not this.cur.at_end():
            let k = this.cur.current().kind
            if k == T.tk_newline or k == T.tk_indent:
                this.cur.advance()
            else:
                break


    function at_indent_end() -> bool:
        if this.cur.at_end():
            return true
        let kind = this.cur.current().kind
        return kind == T.tk_dedent or kind == T.tk_eof


    function is_term(kind: tk.TokenKind) -> bool:
        return kind == T.tk_newline or kind == T.tk_dedent or kind == T.tk_eof


    editable function skip_to_newline() -> void:
        if this.cur.at_end():
            return
        let k = this.cur.current().kind
        if k == T.tk_dedent or k == T.tk_eof:
            return
        while not this.cur.at_end():
            let c = this.cur.current().kind
            if c == T.tk_newline or c == T.tk_dedent or c == T.tk_eof:
                break
            this.cur.advance()


    function make_loc(start: ptr_uint, end: ptr_uint) -> ast.Span:
        return ast.Span(start = start, len = end - start, line = 0, col = 0)


    function cur_end() -> ptr_uint:
        if this.cur.at_end():
            return 0
        return this.cur.current().start


    editable function make_identifier(tok: token_mod.Token) -> ptr[ast.Expr]:
        let loc = this.make_loc(tok.start, tok.end)
        let e = ast.Expr.identifier(name = tok.ident, loc = loc)
        return this.new_expr(e)


    editable function alloc_error_expr(tok: token_mod.Token) -> ptr[ast.Expr]:
        let loc = this.make_loc(tok.start, tok.end)
        let e = ast.Expr.error_expr(loc = loc)
        return this.new_expr(e)
