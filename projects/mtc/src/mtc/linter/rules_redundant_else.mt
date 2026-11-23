## redundant-else rule — flag an else block when every if/else-if branch
## returns.  Extracted from linter/linter.mt.

import std.vec as vec

import mtc.parser.ast as ast
import mtc.linter.linter as linter_mod


## A call/specialization to `fatal` or `static_assert(false)` never returns.
function terminating_expr(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                if terminating_callee(call.callee):
                    return true
                return static_assert_false(call.callee, call.args)
            ast.Expr.expr_specialization as sp:
                return terminating_callee(sp.callee)
            _:
                return false


function terminating_callee(callee: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                return id.name == "fatal"
            ast.Expr.expr_specialization as sp:
                return terminating_callee(sp.callee)
            _:
                return false


function static_assert_false(callee: ptr[ast.Expr], args: span[ast.Argument]) -> bool:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if id.name != "static_assert" or args.len == 0:
                    return false
                match read(read(args.data + 0).arg_value):
                    ast.Expr.expr_bool_literal as b:
                        return not b.value
                    _:
                        return false
            _:
                return false


## A `break` that would exit *this* loop — descends into conditionals but not
## into nested loops (whose breaks belong to them).
function stmt_can_break(stmt: ptr[ast.Stmt]) -> bool:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_break:
                return true
            ast.Stmt.stmt_block as blk:
                return stmts_can_break(blk.statements)
            ast.Stmt.stmt_local as loc:
                return body_can_break(loc.else_body)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    if body_can_break(read(iff.branches.data + bi).body):
                        return true
                    bi += 1
                return body_can_break(iff.else_body)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    if body_can_break(read(mt.arms.data + ai).body):
                        return true
                    ai += 1
                return false
            ast.Stmt.stmt_when as wn:
                var wi: ptr_uint = 0
                while wi < wn.branches.len:
                    if stmts_can_break(read(wn.branches.data + wi).body):
                        return true
                    wi += 1
                return body_can_break(wn.else_body)
            ast.Stmt.stmt_unsafe as un:
                return body_can_break(un.body)
            ast.Stmt.stmt_defer as df:
                return body_can_break(df.body)
            _:
                return false


function stmts_can_break(stmts: span[ast.Stmt]) -> bool:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            if stmt_can_break(stmts.data + i):
                return true
        i += 1
    return false


function body_can_break(body: ptr[ast.Stmt]?) -> bool:
    let bp = body else:
        return false
    return stmt_can_break(bp)


function is_true_literal(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_bool_literal as b:
                return b.value
            _:
                return false


## Mirrors the Ruby linter's `always_returns?` over a statement list: true when
## some statement unconditionally returns/terminates.
function always_returns_stmts(stmts: span[ast.Stmt]) -> bool:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            if stmt_always_returns(stmts.data + i):
                return true
        i += 1
    return false


public function always_returns_body(body: ptr[ast.Stmt]?) -> bool:
    let bp = body else:
        return false
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                return always_returns_stmts(blk.statements)
            _:
                return stmt_always_returns(bp)


public function block_is_nonempty(body: ptr[ast.Stmt]?) -> bool:
    let bp = body else:
        return false
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                return blk.statements.len > 0
            _:
                return true


function stmt_always_returns(stmt: ptr[ast.Stmt]) -> bool:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_ret:
                return true
            ast.Stmt.stmt_expression as ex:
                return terminating_expr(ex.expression)
            ast.Stmt.stmt_if as iff:
                if not block_is_nonempty(iff.else_body):
                    return false
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    if not always_returns_body(read(iff.branches.data + bi).body):
                        return false
                    bi += 1
                return always_returns_body(iff.else_body)
            ast.Stmt.stmt_while as wh:
                return is_true_literal(wh.condition) and not body_can_break(wh.body)
            ast.Stmt.stmt_match as mt:
                if mt.arms.len == 0:
                    return false
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    if not always_returns_body(read(mt.arms.data + ai).body):
                        return false
                    ai += 1
                return true
            ast.Stmt.stmt_when as wn:
                var any_branch = false
                var wi: ptr_uint = 0
                while wi < wn.branches.len:
                    any_branch = true
                    if not always_returns_stmts(read(wn.branches.data + wi).body):
                        return false
                    wi += 1
                if block_is_nonempty(wn.else_body):
                    any_branch = true
                    if not always_returns_body(wn.else_body):
                        return false
                return any_branch
            ast.Stmt.stmt_static_assert as sa:
                return is_false_literal(sa.condition)
            ast.Stmt.stmt_unsafe as un:
                return always_returns_body(un.body)
            _:
                return false


function is_false_literal(expr: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(expr):
            ast.Expr.expr_bool_literal as b:
                return not b.value
            _:
                return false


function first_block_statement_line(body: ptr[ast.Stmt]?) -> ptr_uint:
    let bp = body else:
        return 0
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                if blk.statements.len == 0:
                    return 0
                return statement_line(blk.statements.data + 0)
            _:
                return statement_line(bp)


public function statement_line(stmt: ptr[ast.Stmt]) -> ptr_uint:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_ret as r:
                return r.line
            ast.Stmt.stmt_if as iff:
                return iff.line
            ast.Stmt.stmt_while as wh:
                return wh.line
            ast.Stmt.stmt_for as fr:
                return fr.line
            ast.Stmt.stmt_match as mt:
                return mt.line
            ast.Stmt.stmt_expression as ex:
                return linter_mod.expression_line(ex.expression)
            ast.Stmt.stmt_local as loc:
                return loc.line
            ast.Stmt.stmt_assignment as asgn:
                return asgn.line
            ast.Stmt.stmt_when as wn:
                return wn.line
            ast.Stmt.stmt_parallel_block as pb:
                return pb.line
            ast.Stmt.stmt_gather as ga:
                return ga.line
            ast.Stmt.stmt_error_block as eb:
                return eb.line
            ast.Stmt.stmt_break as bk:
                return bk.line
            ast.Stmt.stmt_continue as ct:
                return ct.line
            ast.Stmt.stmt_pass as ps:
                return ps.line
            ast.Stmt.stmt_defer as df:
                return df.line
            ast.Stmt.stmt_unsafe as un:
                return un.line
            _:
                return 0


## Every if/else-if branch returns, so the else block is unnecessary nesting.
public function check_redundant_else(branches: span[ast.IfBranch], else_body: ptr[ast.Stmt]?, else_line: ptr_uint, else_column: ptr_uint, path: str, warnings: ref[vec.Vec[linter_mod.Warning]]) -> void:
    if not block_is_nonempty(else_body):
        return
    var bi: ptr_uint = 0
    while bi < branches.len:
        unsafe:
            if not always_returns_body(read(branches.data + bi).body):
                return
        bi += 1
    var line = else_line
    if line == 0:
        line = first_block_statement_line(else_body)
    linter_mod.push_warning_at(warnings, path, line, else_column, 4, "redundant-else", "else block is redundant because all preceding branches return", "warning")
