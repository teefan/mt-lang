## Parser — Token stream → AST.
##
## Recursive descent with operator precedence climbing for expressions.
## All AST nodes are arena-allocated via Parser.arena.

import compiler.lexer.token as token_mod
import compiler.lexer.token_kind as tk
import compiler.parser.ast as ast
import compiler.parser.operators as ops_mod
import compiler.parser.token_cursor as cursor_mod
import std.mem.arena
import std.vec

type T = tk.TokenKind
type B = ops_mod.BinaryOp

struct Parser:
    cur: cursor_mod.Cursor
    arena: arena.Arena


## ── entry ───────────────────────────────────────────────────────────

public function parse(
    source: span[ubyte],
    tokens: span[token_mod.Token],
) -> ptr[ast.SourceFile]:
    var p = Parser(
        cur = cursor_mod.create(tokens),
        arena = arena.create(256 * 1024),
    )
    let file = p.parse_module()
    return file




## ── extending Parser ────────────────────────────────────────────────

extending Parser:
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


    ## ── module ──────────────────────────────────────────────────────

    editable function parse_module() -> ptr[ast.SourceFile]:
        var imports = vec.Vec[ptr[ast.Decl]].create()
        var decls = vec.Vec[ptr[ast.Decl]].create()

        while not this.cur.at_end():
            this.skip_newlines()
            if this.cur.at_end():
                break
            if this.at_indent_end():
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
        let tok = this.cur.current()
        match tok.kind:
            T.tk_kw_function:
                return this.parse_function_def()
            _:
                this.skip_to_newline()
                let loc = this.make_loc(tok.start, this.cur_end())
                let decl = ast.Decl.error_decl(loc = loc)
                return this.new_decl(decl)


    ## ── function definition ─────────────────────────────────────────

    editable function parse_function_def() -> ptr[ast.Decl]:
        let start_tok = this.cur.current()
        this.expect(T.tk_kw_function)

        let name_tok = this.cur.current()
        this.expect(T.tk_identifier)
        let name = name_tok.ident

        this.expect(T.tk_lparen)
        var params = vec.Vec[ast.Param].create()

        while true:
            if this.cur.current().kind == T.tk_rparen:
                break
            if params.len > 0:
                this.expect(T.tk_comma)

            let param_name = this.cur.current()
            this.expect(T.tk_identifier)
            this.expect(T.tk_colon)
            let param_type = this.parse_type()
            params.push(ast.Param(
                name = param_name.ident,
                type_ref = param_type,
                loc = this.make_loc(param_name.start, param_name.end),
            ))

        let rparen_tok = this.cur.current()
        this.expect(T.tk_rparen)

        var ret_type = zero[ptr[ast.Type]]
        if not this.cur.at_end() and this.cur.current().kind == T.tk_arrow:
            this.cur.advance()
            ret_type = this.parse_type()

        this.expect(T.tk_colon)
        let body = this.parse_statements()

        let end = this.cur_end()
        let params_span = this.span_of_params(ref_of(params))
        let empty_tparams = span[ast.TypeParam](data = zero[ptr[ast.TypeParam]], len = 0)

        let decl = ast.Decl.function_def(
            name = name,
            type_params = empty_tparams,
            params = params_span,
            return_type = ret_type,
            body = body,
            visibility = ast.Visibility.priv,
            is_async = false,
            is_const = false,
            loc = this.make_loc(start_tok.start, end),
        )
        return this.new_decl(decl)


    ## ── type ────────────────────────────────────────────────────────

    editable function parse_type() -> ptr[ast.Type]:
        let tok = this.cur.current()
        this.expect(T.tk_identifier)
        let loc = this.make_loc(tok.start, tok.end)
        let t = ast.Type.named_type(name = tok.ident, loc = loc)
        return this.new_type(t)


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


    ## ── expression statement ────────────────────────────────────────

    editable function parse_expression_stmt() -> ptr[ast.Stmt]:
        let start = this.cur.current().start
        let expr = this.parse_expression()
        let loc = this.make_loc(start, this.cur_end())
        let s = ast.Stmt.expression(expr = expr, loc = loc)
        return this.new_stmt(s)


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

        let loc = this.make_loc(kind_tok.start, this.cur_end())
        let s = ast.Stmt.local_decl(
            kind = kind,
            name = name_tok.ident,
            type_ref = type_ref,
            value = val_expr,
            else_binding = 0,
            else_body = zero[ptr[ast.Stmt]],
            loc = loc,
        )
        return this.new_stmt(s)


    ## ── expressions ─────────────────────────────────────────────────

    editable function parse_expression() -> ptr[ast.Expr]:
        return this.parse_binary(0)


    editable function parse_binary(min_prec: int) -> ptr[ast.Expr]:
        var left = this.parse_prefix()

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
            T.tk_identifier:
                return this.parse_identifier()
            T.tk_integer:
                return this.parse_integer()
            T.tk_float:
                this.cur.advance()
                return this.alloc_error_expr(tok)
            T.tk_string:
                return this.parse_string()
            T.tk_lparen:
                return this.parse_paren_or_tuple()
            _:
                this.cur.advance()
                return this.alloc_error_expr(tok)


    editable function parse_identifier() -> ptr[ast.Expr]:
        let tok = this.cur.current()
        this.cur.advance()

        if this.cur.at_end():
            let loc = this.make_loc(tok.start, tok.end)
            let e = ast.Expr.identifier(name = tok.ident, loc = loc)
            return this.new_expr(e)

        let next = this.cur.current()
        if next.kind == T.tk_lparen:
            return this.parse_call(tok)

        if next.kind == T.tk_lbracket:
            return this.parse_specialization(tok)

        let loc = this.make_loc(tok.start, tok.end)
        let e = ast.Expr.identifier(name = tok.ident, loc = loc)
        return this.new_expr(e)


    editable function parse_integer() -> ptr[ast.Expr]:
        let tok = this.cur.current()
        this.cur.advance()
        let loc = this.make_loc(tok.start, tok.end)
        let e = ast.Expr.integer_literal(value = 0, loc = loc)
        return this.new_expr(e)


    editable function parse_string() -> ptr[ast.Expr]:
        let tok = this.cur.current()
        this.cur.advance()
        let loc = this.make_loc(tok.start, tok.end)
        let e = ast.Expr.string_literal(text = "", is_cstr = false, loc = loc)
        return this.new_expr(e)


    ## ── call ────────────────────────────────────────────────────────

    editable function parse_call(callee_tok: token_mod.Token) -> ptr[ast.Expr]:
        this.expect(T.tk_lparen)
        var args = vec.Vec[ptr[ast.Expr]].create()
        let start = callee_tok.start

        while true:
            if this.cur.current().kind == T.tk_rparen:
                break
            if args.len > 0:
                this.expect(T.tk_comma)
            let arg = this.parse_expression()
            args.push(arg)

        this.expect(T.tk_rparen)
        let end = this.cur_end()
        let callee = this.make_identifier(callee_tok)
        let args_span = this.span_of_exprs(ref_of(args))
        let loc = this.make_loc(start, end)
        let e = ast.Expr.call(callee = callee, args = args_span, loc = loc)
        return this.new_expr(e)


    ## ── specialization ──────────────────────────────────────────────

    editable function parse_specialization(callee_tok: token_mod.Token) -> ptr[ast.Expr]:
        this.expect(T.tk_lbracket)
        var ta_args = vec.Vec[ptr[ast.Type]].create()
        let start = callee_tok.start

        while true:
            if this.cur.current().kind == T.tk_rbracket:
                break
            if ta_args.len > 0:
                this.expect(T.tk_comma)
            let arg = this.parse_type()
            ta_args.push(arg)

        this.expect(T.tk_rbracket)
        let end = this.cur_end()
        let callee = this.make_identifier(callee_tok)
        let ta_span = this.span_of_types(ref_of(ta_args))
        let loc = this.make_loc(start, end)
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
