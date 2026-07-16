## Linter control-flow helpers — structural AST analyses for dataflow-based
## lint rules: dead-assignment, unreachable-code, constant-condition,
## loop-single-iteration.
##
## These operate on the AST directly, following the pattern established by
## `definite_assignment.mt` (forward intersection at merge points) and
## `always_returns_body`.  No graph edges are needed — the CFG is implicit
## in the AST structure.

import std.map as map_mod
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast


# =============================================================================
#  Reachability — walks AST, marks reachable nodes by line
# =============================================================================

## Collect line numbers of all reachable statements in a body, assuming the
## entry is reachable.  Used by `unreachable-code` to find dead statements.
public function reachable_lines(body: ptr[ast.Stmt]?) -> map_mod.Map[ptr_uint, bool]:
    var reachable = map_mod.Map[ptr_uint, bool].create()
    mark_reachable(body, ref_of(reachable))
    return reachable


function mark_reachable(stmt_ptr: ptr[ast.Stmt]?, reachable: ref[map_mod.Map[ptr_uint, bool]]) -> void:
    if stmt_ptr == null:
        return
    unsafe:
        match read(stmt_ptr):
            ast.Stmt.stmt_ret as r:
                reachable.set(r.line, true)
            ast.Stmt.stmt_local as l:
                reachable.set(l.line, true)
            ast.Stmt.stmt_assignment as a:
                reachable.set(a.line, true)
            ast.Stmt.stmt_expression as e:
                reachable.set(e.line, true)
            ast.Stmt.stmt_if as i:
                reachable.set(i.line, true)
                var bi: ptr_uint = 0
                while bi < i.branches.len:
                    mark_reachable(read(i.branches.data + bi).body, reachable)
                    bi += 1
                mark_reachable(i.else_body, reachable)
            ast.Stmt.stmt_while as w:
                reachable.set(w.line, true)
                mark_reachable(w.body, reachable)
            ast.Stmt.stmt_for as f:
                reachable.set(f.line, true)
                mark_reachable(f.body, reachable)
            ast.Stmt.stmt_match as m:
                reachable.set(m.line, true)
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    mark_reachable(read(m.arms.data + ai).body, reachable)
                    ai += 1
            ast.Stmt.stmt_block as b:
                mark_block_reachable(b.statements, reachable)
            ast.Stmt.stmt_unsafe as u:
                mark_reachable(u.body, reachable)
            ast.Stmt.stmt_defer as d:
                mark_reachable(d.body, reachable)
            ast.Stmt.stmt_static_assert as s:
                reachable.set(s.line, true)
            ast.Stmt.stmt_when as w:
                var wi: ptr_uint = 0
                while wi < w.branches.len:
                    mark_block_reachable(read(w.branches.data + wi).body, reachable)
                    wi += 1
                mark_reachable(w.else_body, reachable)
            _:
                pass


function mark_block_reachable(stmts: span[ast.Stmt], reachable: ref[map_mod.Map[ptr_uint, bool]]) -> void:
    var alive = true
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            if alive:
                mark_reachable(stmts.data + si, reachable)
            # After a terminating statement, remaining statements are dead.
            if alive and stmt_terminates(stmts.data + si):
                alive = false
        si += 1


function stmt_terminates(sp: ptr[ast.Stmt]) -> bool:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_ret:
                return true
            ast.Stmt.stmt_expression as e:
                return is_fatal_call(e.expression)
            ast.Stmt.stmt_static_assert as s:
                return is_false_literal(s.condition)
            _:
                return false


function is_fatal_call(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as id:
                        return id.name == "fatal"
                    _:
                        return false
            _:
                return false


function is_false_literal(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_bool_literal as b:
                return not b.value
            _:
                return false


# =============================================================================
#  Liveness — backward walk, tracks live names
# =============================================================================

## A dead-write record: the name of a variable and the line where it was written.
public struct DeadWrite:
    name: str
    line: ptr_uint


## Return a list of (name, line) pairs where an assignment writes a value that is
## not live afterward (the written name is not in the live set at the write point).
public function collect_dead_writes(body: ptr[ast.Stmt]?) -> vec.Vec[DeadWrite]:
    var result = vec.Vec[DeadWrite].create()
    var live = vec.Vec[str].create()
    defer live.release()
    walk_stmts_backward(body, ref_of(result), ref_of(live))
    return result


function walk_stmts_backward(stmt_ptr: ptr[ast.Stmt]?, result: ref[vec.Vec[DeadWrite]], live: ref[vec.Vec[str]]) -> void:
    if stmt_ptr == null:
        return
    unsafe:
        match read(stmt_ptr):
            ast.Stmt.stmt_block as b:
                var i = b.statements.len
                while i > 0:
                    i -= 1
                    walk_stmt_backward(b.statements.data + i, result, live)
            _:
                walk_stmt_backward(stmt_ptr, result, live)


function walk_stmt_backward(sp: ptr[ast.Stmt], result: ref[vec.Vec[DeadWrite]], live: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as l:
                # write phase: after the initializer reads, the name is defined
                collect_expr_names_backward(l.value, result, live)
                # The local name is now defined; remove it from live (it's dead before the write)
                remove_from_live(live, l.name)
            ast.Stmt.stmt_assignment as a:
                collect_expr_names_backward(a.value, result, live)
                match read(a.target):
                    ast.Expr.expr_identifier as id:
                        if id.name != "_":
                            if not is_live(live, id.name) and a.operator == "=":
                                result.push(DeadWrite(name = id.name, line = a.line))
                            remove_from_live(live, id.name)
                    _:
                        pass
            ast.Stmt.stmt_expression as e:
                collect_expr_names_backward(e.expression, result, live)
            ast.Stmt.stmt_ret as r:
                collect_expr_names_backward(r.value, result, live)
            ast.Stmt.stmt_if as i:
                # After the if: live is whatever was live before (no writes here)
                # Before each branch: process the branch body, then the condition
                var bi = i.branches.len
                while bi > 0:
                    bi -= 1
                    let br = read(i.branches.data + bi)
                    walk_stmts_backward(br.body, result, live)
                    collect_expr_names_backward(br.condition, result, live)
                walk_stmts_backward(i.else_body, result, live)
            ast.Stmt.stmt_while as w:
                # Conservative: body may or may not execute, so reads in the body
                # are live at the loop entry. Reads in the condition are always live.
                walk_stmts_backward(w.body, result, live)
                collect_expr_names_backward(w.condition, result, live)
            ast.Stmt.stmt_for as f:
                walk_stmts_backward(f.body, result, live)
                var fi: ptr_uint = 0
                while fi < f.iterables.len:
                    collect_expr_names_backward(f.iterables.data + fi, result, live)
                    fi += 1
            ast.Stmt.stmt_match as m:
                collect_expr_names_backward(m.scrutinee, result, live)
                var ai = m.arms.len
                while ai > 0:
                    ai -= 1
                    walk_stmts_backward(read(m.arms.data + ai).body, result, live)
            ast.Stmt.stmt_unsafe as u:
                walk_stmts_backward(u.body, result, live)
            ast.Stmt.stmt_defer as d:
                collect_expr_names_backward(d.expression, result, live)
                # Defer body does not affect current flow.
            ast.Stmt.stmt_when as w:
                collect_expr_names_backward(w.discriminant, result, live)
                walk_stmts_backward(w.else_body, result, live)
                var wi = w.branches.len
                while wi > 0:
                    wi -= 1
                    let br = read(w.branches.data + wi)
                    var bsi = br.body.len
                    while bsi > 0:
                        bsi -= 1
                        walk_stmt_backward(br.body.data + bsi, result, live)
            ast.Stmt.stmt_static_assert as s:
                collect_expr_names_backward(s.condition, result, live)
            _:
                pass


function collect_expr_names_backward(ep: ptr[ast.Expr]?, result: ref[vec.Vec[DeadWrite]], live: ref[vec.Vec[str]]) -> void:
    let p = ep else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_identifier as id:
                if id.name != "_":
                    add_to_live(live, id.name)
            ast.Expr.expr_binary_op as b:
                collect_expr_names_backward(b.left, result, live)
                collect_expr_names_backward(b.right, result, live)
            ast.Expr.expr_unary_op as u:
                collect_expr_names_backward(u.operand, result, live)
            ast.Expr.expr_member_access as ma:
                collect_expr_names_backward(ma.receiver, result, live)
            ast.Expr.expr_index_access as ix:
                collect_expr_names_backward(ix.receiver, result, live)
                collect_expr_names_backward(ix.index, result, live)
            ast.Expr.expr_call as cl:
                collect_expr_names_backward(cl.callee, result, live)
                var ai: ptr_uint = 0
                while ai < cl.args.len:
                    collect_expr_names_backward(read(cl.args.data + ai).arg_value, result, live)
                    ai += 1
            ast.Expr.expr_specialization as sp:
                collect_expr_names_backward(sp.callee, result, live)
            ast.Expr.expr_prefix_cast as c:
                collect_expr_names_backward(c.expression, result, live)
            ast.Expr.expr_await as aw:
                collect_expr_names_backward(aw.expression, result, live)
            ast.Expr.expr_unsafe as us:
                collect_expr_names_backward(us.expression, result, live)
            ast.Expr.expr_if as ife:
                collect_expr_names_backward(ife.condition, result, live)
                collect_expr_names_backward(ife.then_expr, result, live)
                collect_expr_names_backward(ife.else_expr, result, live)
            ast.Expr.expr_detach as det:
                collect_expr_names_backward(det.expression, result, live)
            ast.Expr.expr_format_string as fs:
                var fi: ptr_uint = 0
                while fi < fs.parts.len:
                    var part = read(fs.parts.data + fi)
                    match part:
                        ast.FormatStringPart.fmt_expr as fe:
                            collect_expr_names_backward(fe.expression, result, live)
                        _:
                            pass
                    fi += 1
            _:
                pass


function is_live(live: ref[vec.Vec[str]], name: str) -> bool:
    var i: ptr_uint = 0
    while i < live.len():
        let vp = live.get(i) else:
            break
        if unsafe: read(vp) == name:
            return true
        i += 1
    return false


function add_to_live(live: ref[vec.Vec[str]], name: str) -> void:
    var i: ptr_uint = 0
    while i < live.len():
        let vp = live.get(i) else:
            break
        if unsafe: read(vp) == name:
            return
        i += 1
    live.push(name)


function remove_from_live(live: ref[vec.Vec[str]], name: str) -> void:
    var i: ptr_uint = 0
    while i < live.len():
        let vp = live.get(i) else:
            break
        if unsafe: read(vp) == name:
            let _last = live.swap_remove(i)
            return
        i += 1
