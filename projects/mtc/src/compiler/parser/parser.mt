## Parser — Token stream → AST.
##
## Recursive descent with operator precedence climbing for expressions.

import compiler.lexer.token as token_mod
import compiler.lexer.token_kind as tk
import compiler.parser.ast as ast
import compiler.parser.operators as ops_mod
import compiler.parser.token_cursor as cursor_mod
import std.vec

type T = tk.TokenKind
type B = ops_mod.BinaryOp

struct Parser:
    cur: cursor_mod.Cursor


public function parse(tokens: span[token_mod.Token]) -> ptr[ast.SourceFile]:
    var p = Parser(cur = cursor_mod.create(tokens))
    return p.parse_module()


## ── zero pointer helper ────────────────────────────────────────────

function zero_ptr[T]() -> ptr[T]:
    return zero[ptr[T]]


## ── extending Parser ────────────────────────────────────────────────

extending Parser:
    ## ── module ──────────────────────────────────────────────────────

    editable function parse_module() -> ptr[ast.SourceFile]:
        var imports = vec.Vec[ptr[ast.Decl]].create()
        var decls = vec.Vec[ptr[ast.Decl]].create()

        while not this.cur.at_end():
            this.skip_newlines()
            if this.cur.at_end():
                break

            let tok = this.cur.current()
            if tok.kind == T.tk_kw_import:
                let import_decl = this.parse_import()
                imports.push(import_decl)
            else:
                let decl = this.parse_declaration()
                decls.push(decl)

        return zero_ptr[ast.SourceFile]()


    ## ── imports ─────────────────────────────────────────────────────

    editable function parse_import() -> ptr[ast.Decl]:
        var parts = vec.Vec[ast.IdentId].create()
        this.expect(T.tk_kw_import)
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

        return zero_ptr[ast.Decl]()


    ## ── declarations ────────────────────────────────────────────────

    editable function parse_declaration() -> ptr[ast.Decl]:
        let tok = this.cur.current()
        match tok.kind:
            T.tk_kw_function:
                return this.parse_function_def()
            _:
                this.skip_to_newline()
                return zero_ptr[ast.Decl]()


    ## ── function definition ─────────────────────────────────────────

    editable function parse_function_def() -> ptr[ast.Decl]:
        this.expect(T.tk_kw_function)

        let name_tok = this.cur.current()
        this.expect(T.tk_identifier)

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
                loc = this.span_of(param_name.start, param_name.end),
            ))

        this.expect(T.tk_rparen)

        var ret_type = zero_ptr[ast.Type]()
        if not this.cur.at_end() and this.cur.current().kind == T.tk_arrow:
            this.cur.advance()
            ret_type = this.parse_type()

        this.expect(T.tk_colon)
        let body = this.parse_statements()

        return zero_ptr[ast.Decl]()


    ## ── type ────────────────────────────────────────────────────────

    editable function parse_type() -> ptr[ast.Type]:
        this.expect(T.tk_identifier)
        return zero_ptr[ast.Type]()


    ## ── statements ──────────────────────────────────────────────────

    editable function parse_statements() -> ptr[ast.Stmt]:
        var stmts = vec.Vec[ptr[ast.Stmt]].create()

        while true:
            this.skip_newlines()
            if this.cur.at_end():
                break
            if this.at_indent_end():
                break

            let stmt = this.parse_statement()
            stmts.push(stmt)

        return zero_ptr[ast.Stmt]()


    editable function parse_statement() -> ptr[ast.Stmt]:
        let tok = this.cur.current()
        match tok.kind:
            T.tk_kw_return:
                return this.parse_return_stmt()
            T.tk_kw_let | T.tk_kw_var:
                return this.parse_local_decl()
            _:
                return this.parse_expression_stmt()


    ## ── return ──────────────────────────────────────────────────────

    editable function parse_return_stmt() -> ptr[ast.Stmt]:
        this.expect(T.tk_kw_return)
        var val_expr = zero_ptr[ast.Expr]()
        if not this.cur.at_end() and not this.is_stmt_terminator(this.cur.current().kind):
            val_expr = this.parse_expression()
        return zero_ptr[ast.Stmt]()


    ## ── expression statement ────────────────────────────────────────

    editable function parse_expression_stmt() -> ptr[ast.Stmt]:
        let expr = this.parse_expression()
        return zero_ptr[ast.Stmt]()


    ## ── local declaration ───────────────────────────────────────────

    editable function parse_local_decl() -> ptr[ast.Stmt]:
        let kind_tok = this.cur.current()
        var kind = ast.DeclKind.dk_let
        if kind_tok.kind == T.tk_kw_var:
            kind = ast.DeclKind.dk_var
        this.cur.advance()

        this.expect(T.tk_identifier)

        var type_ref = zero_ptr[ast.Type]()
        if this.cur.current().kind == T.tk_colon:
            this.cur.advance()
            type_ref = this.parse_type()

        var val_expr = zero_ptr[ast.Expr]()
        if this.cur.current().kind == T.tk_equal:
            this.cur.advance()
            val_expr = this.parse_expression()

        return zero_ptr[ast.Stmt]()


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

            this.cur.advance()
            let next_prec = prec + 1
            let right = this.parse_binary(next_prec)
            left = zero_ptr[ast.Expr]()

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
                return zero_ptr[ast.Expr]()
            T.tk_string:
                this.cur.advance()
                return zero_ptr[ast.Expr]()
            T.tk_lparen:
                return this.parse_paren_or_tuple()
            _:
                this.cur.advance()
                return zero_ptr[ast.Expr]()


    editable function parse_identifier() -> ptr[ast.Expr]:
        let tok = this.cur.current()
        this.cur.advance()

        if this.cur.at_end():
            return zero_ptr[ast.Expr]()

        let next = this.cur.current()
        if next.kind == T.tk_lparen:
            return this.parse_call(tok)

        if next.kind == T.tk_lbracket:
            return this.parse_specialization(tok)

        return zero_ptr[ast.Expr]()


    editable function parse_integer() -> ptr[ast.Expr]:
        this.cur.advance()
        return zero_ptr[ast.Expr]()


    ## ── call ────────────────────────────────────────────────────────

    editable function parse_call(callee_tok: token_mod.Token) -> ptr[ast.Expr]:
        this.expect(T.tk_lparen)
        var args = vec.Vec[ptr[ast.Expr]].create()

        while true:
            if this.cur.current().kind == T.tk_rparen:
                break
            if args.len > 0:
                this.expect(T.tk_comma)
            let arg = this.parse_expression()
            args.push(arg)

        this.expect(T.tk_rparen)
        return zero_ptr[ast.Expr]()


    ## ── specialization ──────────────────────────────────────────────

    editable function parse_specialization(callee_tok: token_mod.Token) -> ptr[ast.Expr]:
        this.expect(T.tk_lbracket)
        var ta_args = vec.Vec[ptr[ast.Type]].create()

        while true:
            if this.cur.current().kind == T.tk_rbracket:
                break
            if ta_args.len > 0:
                this.expect(T.tk_comma)
            let arg = this.parse_type()
            ta_args.push(arg)

        this.expect(T.tk_rbracket)
        return zero_ptr[ast.Expr]()


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


    function kind_to_binary_op(kind: tk.TokenKind) -> ops_mod.BinaryOp:
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
        while not this.cur.at_end() and this.cur.current().kind == T.tk_newline:
            this.cur.advance()


    function at_indent_end() -> bool:
        if this.cur.at_end():
            return true
        let kind = this.cur.current().kind
        return kind == T.tk_dedent or kind == T.tk_eof


    function is_stmt_terminator(kind: tk.TokenKind) -> bool:
        return kind == T.tk_newline or kind == T.tk_dedent or kind == T.tk_eof


    editable function skip_to_newline() -> void:
        while not this.cur.at_end() and not this.is_stmt_terminator(this.cur.current().kind):
            this.cur.advance()


    function span_of(start: ptr_uint, end: ptr_uint) -> ast.Span:
        return ast.Span(start = start, len = end - start, line = 0, col = 0)
