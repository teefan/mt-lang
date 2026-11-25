## trailing-list-comma rule — a redundant comma before a call's `)`.
## Token-based; extracted from linter/linter.mt.

import std.map as map_mod
import std.vec as vec

import mtc.parser.ast as ast
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk
import mtc.linter.linter as linter_mod


## Combine a line and column into a single map key.  Columns are well below
## 1_000_000 in any realistic source line.
function location_key(line: ptr_uint, column: ptr_uint) -> ptr_uint:
    return line * 1000000 + column


public function lint_trailing_commas(
    decls: span[ast.Decl],
    ts: span[token_mod.Token],
    path: str,
    warnings: ref[vec.Vec[linter_mod.Warning]]
) -> void:

    # Map each token's (line, column) to its index, first-occurrence wins.
    var loc_index = map_mod.Map[ptr_uint, ptr_uint].create()
    defer: loc_index.release()
    var i: ptr_uint = 0
    while i < ts.len:
        unsafe:
            let t = read(ts.data + i)
            let key = location_key(t.line, t.column)
            if not loc_index.contains(key):
                loc_index.set(key, i)
        i += 1

    # Dedup by comma site so a call reached via multiple walks warns once.
    var warned = map_mod.Map[ptr_uint, bool].create()
    defer: warned.release()

    var di: ptr_uint = 0
    while di < decls.len:
        unsafe:
            match read(decls.data + di):
                ast.Decl.decl_const as c:
                    tc_expr_opt(c.value, ts, ref_of(loc_index), ref_of(warned), path, warnings)
                ast.Decl.decl_var as v:
                    tc_expr_opt(v.value, ts, ref_of(loc_index), ref_of(warned), path, warnings)
                ast.Decl.decl_function as fun:
                    tc_body(fun.body, ts, ref_of(loc_index), ref_of(warned), path, warnings)
                ast.Decl.decl_extending_block as ex:
                    var j: ptr_uint = 0
                    while j < ex.methods.len:
                        tc_body(read(ex.methods.data + j).body, ts, ref_of(loc_index), ref_of(warned), path, warnings)
                        j += 1
                _:
                    pass
        di += 1


## Report the trailing comma before the matching `)` of `call`, if any.
function check_trailing_comma(
    callee: ptr[ast.Expr],
    args: span[ast.Argument],
    ts: span[token_mod.Token],
    loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]],
    warned: ref[map_mod.Map[ptr_uint, bool]],
    path: str,
    warnings: ref[vec.Vec[linter_mod.Warning]]
) -> void:
    if args.len == 0:
        return
    let callee_line = linter_mod.expression_line(callee)
    let callee_col = linter_mod.expression_column(callee)
    if callee_line == 0 or callee_col == 0:
        return
    let idx_ptr = loc_index.get(location_key(callee_line, callee_col)) else:
        return
    let callee_idx = unsafe: read(idx_ptr)

    # Find the opening paren after the callee.
    var lparen_idx: ptr_uint = 0
    var have_lparen = false
    var cursor = callee_idx
    while cursor < ts.len:
        unsafe:
            let t = read(ts.data + cursor)
            if t.kind == tk.TokenKind.lparen:
                lparen_idx = cursor
                have_lparen = true
                break
            if t.kind == tk.TokenKind.newline and t.line > callee_line:
                break
        cursor += 1
    if not have_lparen:
        return

    # Track a comma seen at depth 0; a non-trivia token clears it, so it only
    # survives if it sits immediately before the closing paren.
    var paren_depth: int = 0
    var bracket_depth: int = 0
    var have_comma = false
    var comma_line: ptr_uint = 0
    var comma_col: ptr_uint = 0
    cursor = lparen_idx + 1
    while cursor < ts.len:
        unsafe:
            let t = read(ts.data + cursor)
            let k = t.kind
            if k == tk.TokenKind.lparen:
                paren_depth += 1
            else if k == tk.TokenKind.rparen:
                if paren_depth == 0 and bracket_depth == 0:
                    if have_comma:
                        let key = location_key(comma_line, comma_col)
                        if not warned.contains(key):
                            warned.set(key, true)
                            linter_mod.push_warning_at(
                                warnings,
                                path,
                                comma_line,
                                comma_col,
                                1,
                                "trailing-list-comma",
                                "trailing comma in call argument list is redundant",
                                "hint"
                            )
                    return
                if paren_depth > 0:
                    paren_depth -= 1
            else if k == tk.TokenKind.lbracket:
                bracket_depth += 1
            else if k == tk.TokenKind.rbracket:
                if bracket_depth > 0:
                    bracket_depth -= 1
            else if k == tk.TokenKind.comma:
                if paren_depth == 0 and bracket_depth == 0:
                    have_comma = true
                    comma_line = t.line
                    comma_col = t.column
            else:
                if paren_depth == 0 and bracket_depth == 0 and not is_trivia_token(k):
                    have_comma = false
        cursor += 1


function is_trivia_token(k: tk.TokenKind) -> bool:
    return k == tk.TokenKind.newline or k == tk.TokenKind.indent or k == tk.TokenKind.dedent or k == tk.TokenKind.eof


function tc_expr_opt(
    expr: ptr[ast.Expr]?,
    ts: span[token_mod.Token],
    loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]],
    warned: ref[map_mod.Map[ptr_uint, bool]],
    path: str,
    warnings: ref[vec.Vec[linter_mod.Warning]]
) -> void:
    let ep = expr else:
        return
    tc_expr(ep, ts, loc_index, warned, path, warnings)


function tc_expr(
    expr: ptr[ast.Expr],
    ts: span[token_mod.Token],
    loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]],
    warned: ref[map_mod.Map[ptr_uint, bool]],
    path: str,
    warnings: ref[vec.Vec[linter_mod.Warning]]
) -> void:
    unsafe:
        match read(expr):
            ast.Expr.expr_call as call:
                check_trailing_comma(call.callee, call.args, ts, loc_index, warned, path, warnings)
                tc_expr(call.callee, ts, loc_index, warned, path, warnings)
                var i: ptr_uint = 0
                while i < call.args.len:
                    tc_expr(read(call.args.data + i).arg_value, ts, loc_index, warned, path, warnings)
                    i += 1
            ast.Expr.expr_binary_op as b:
                tc_expr(b.left, ts, loc_index, warned, path, warnings)
                tc_expr(b.right, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_unary_op as u:
                tc_expr(u.operand, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_member_access as m:
                tc_expr(m.receiver, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_index_access as ix:
                tc_expr(ix.receiver, ts, loc_index, warned, path, warnings)
                tc_expr(ix.index, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_specialization as sp:
                tc_expr(sp.callee, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_if as iff:
                tc_expr(iff.condition, ts, loc_index, warned, path, warnings)
                tc_expr(iff.then_expr, ts, loc_index, warned, path, warnings)
                tc_expr(iff.else_expr, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_match as mm:
                tc_expr(mm.scrutinee, ts, loc_index, warned, path, warnings)
                var ai: ptr_uint = 0
                while ai < mm.arms.len:
                    tc_expr(read(mm.arms.data + ai).value, ts, loc_index, warned, path, warnings)
                    ai += 1
            ast.Expr.expr_proc as pr:
                tc_body(pr.body, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_await as aw:
                tc_expr(aw.expression, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_detach as dt:
                tc_expr(dt.expression, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_named as nm:
                tc_expr(nm.value, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_range as rg:
                tc_expr(rg.start_expr, ts, loc_index, warned, path, warnings)
                tc_expr(rg.end_expr, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_prefix_cast as pc:
                tc_expr(pc.expression, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_unsafe as us:
                tc_expr(us.expression, ts, loc_index, warned, path, warnings)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    tc_expr(el.elements.data + ei, ts, loc_index, warned, path, warnings)
                    ei += 1
            _:
                pass


## Faithful port of Ruby's walk_statement_lists: process a list's direct-
## statement expressions, then recurse into nested statement lists.  Combined
## with the `warned` dedup this reproduces Ruby's exact warning order.
function tc_body(
    body: ptr[ast.Stmt]?,
    ts: span[token_mod.Token],
    loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]],
    warned: ref[map_mod.Map[ptr_uint, bool]],
    path: str,
    warnings: ref[vec.Vec[linter_mod.Warning]]
) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                tc_statement_list(blk.statements, ts, loc_index, warned, path, warnings)
            _:
                tc_each_statement_expr(bp, ts, loc_index, warned, path, warnings)
                tc_recurse_statement(bp, ts, loc_index, warned, path, warnings)


function tc_statement_list(
    stmts: span[ast.Stmt],
    ts: span[token_mod.Token],
    loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]],
    warned: ref[map_mod.Map[ptr_uint, bool]],
    path: str,
    warnings: ref[vec.Vec[linter_mod.Warning]]
) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            tc_each_statement_expr(stmts.data + i, ts, loc_index, warned, path, warnings)
        i += 1
    i = 0
    while i < stmts.len:
        unsafe:
            tc_recurse_statement(stmts.data + i, ts, loc_index, warned, path, warnings)
        i += 1


function tc_recurse_statement(
    stmt: ptr[ast.Stmt],
    ts: span[token_mod.Token],
    loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]],
    warned: ref[map_mod.Map[ptr_uint, bool]],
    path: str,
    warnings: ref[vec.Vec[linter_mod.Warning]]
) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    tc_body(read(iff.branches.data + bi).body, ts, loc_index, warned, path, warnings)
                    bi += 1
                tc_body(iff.else_body, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_match as mt:
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    tc_body(read(mt.arms.data + ai).body, ts, loc_index, warned, path, warnings)
                    ai += 1
            ast.Stmt.stmt_unsafe as un:
                tc_body(un.body, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_for as fr:
                tc_body(fr.body, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_while as wh:
                tc_body(wh.body, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_defer as df:
                tc_body(df.body, ts, loc_index, warned, path, warnings)
            _:
                pass


## The direct expressions of a statement (Ruby's each_statement_expression) —
## does not descend into nested statement bodies, except for the transparent
## `when` / `unsafe` / error blocks.
function tc_each_statement_expr(
    stmt: ptr[ast.Stmt],
    ts: span[token_mod.Token],
    loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]],
    warned: ref[map_mod.Map[ptr_uint, bool]],
    path: str,
    warnings: ref[vec.Vec[linter_mod.Warning]]
) -> void:
    unsafe:
        match read(stmt):
            ast.Stmt.stmt_local as loc:
                tc_expr_opt(loc.value, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_assignment as asgn:
                tc_expr(asgn.target, ts, loc_index, warned, path, warnings)
                tc_expr(asgn.value, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    tc_expr(read(iff.branches.data + bi).condition, ts, loc_index, warned, path, warnings)
                    bi += 1
            ast.Stmt.stmt_while as wh:
                tc_expr(wh.condition, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_for as fr:
                var ii: ptr_uint = 0
                while ii < fr.iterables.len:
                    tc_expr(fr.iterables.data + ii, ts, loc_index, warned, path, warnings)
                    ii += 1
            ast.Stmt.stmt_match as mt:
                tc_expr(mt.scrutinee, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_ret as r:
                tc_expr_opt(r.value, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_defer as df:
                tc_expr_opt(df.expression, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_expression as ex:
                tc_expr(ex.expression, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_static_assert as sa:
                tc_expr(sa.condition, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_when as wn:
                tc_expr(wn.discriminant, ts, loc_index, warned, path, warnings)
                var wbi: ptr_uint = 0
                while wbi < wn.branches.len:
                    let br = read(wn.branches.data + wbi)
                    var wsi: ptr_uint = 0
                    while wsi < br.body.len:
                        tc_each_statement_expr(br.body.data + wsi, ts, loc_index, warned, path, warnings)
                        wsi += 1
                    wbi += 1
                tc_each_stmt_expr_in_body(wn.else_body, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_unsafe as un:
                tc_each_stmt_expr_in_body(un.body, ts, loc_index, warned, path, warnings)
            ast.Stmt.stmt_error_block as eb:
                tc_each_statement_expr(eb.body, ts, loc_index, warned, path, warnings)
            _:
                pass


function tc_each_stmt_expr_in_body(
    body: ptr[ast.Stmt]?,
    ts: span[token_mod.Token],
    loc_index: ref[map_mod.Map[ptr_uint, ptr_uint]],
    warned: ref[map_mod.Map[ptr_uint, bool]],
    path: str,
    warnings: ref[vec.Vec[linter_mod.Warning]]
) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    tc_each_statement_expr(blk.statements.data + i, ts, loc_index, warned, path, warnings)
                    i += 1
            _:
                tc_each_statement_expr(bp, ts, loc_index, warned, path, warnings)
