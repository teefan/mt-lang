## Linter control-flow helpers — structural AST analyses for dataflow-based
## lint rules: dead-assignment, unreachable-code, constant-condition,
## loop-single-iteration.
##
## These operate on the AST directly, following the pattern established by
## `definite_assignment.mt` (forward intersection at merge points) and
## `always_returns_body`.  No graph edges are needed — the CFG is implicit
## in the AST structure.

import std.map as map_mod
import std.vec as vec

import mtc.parser.ast as ast


# =============================================================================
#  Liveness — backward walk, tracks live names for dead-assignment
# =============================================================================

## A dead-write record: the name of a variable and the line where it was written.
public struct DeadWrite:
    name: str
    line: ptr_uint


## Return a list of dead writes: assignments where the written name is not in the
## live set immediately after the write.  Walks the body backward to track which
## names are live (read later) at each point.
public function collect_dead_writes(body: ptr[ast.Stmt]?) -> vec.Vec[DeadWrite]:
    var result = vec.Vec[DeadWrite].create()
    var live = vec.Vec[str].create()
    defer live.release()
    walk_body_backward(body, ref_of(result), ref_of(live))
    return result


## Walk a function-like body backward.  Dispatches on `stmt_block`, passing
## through other single-statement forms.
function walk_body_backward(stmt_ptr: ptr[ast.Stmt]?, result: ref[vec.Vec[DeadWrite]], live: ref[vec.Vec[str]]) -> void:
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


## Walk a single statement backward.  Removes writes from the live set, adds
## expression reads to it, and records dead writes for assignments whose target
## is not live.
function walk_stmt_backward(sp: ptr[ast.Stmt], result: ref[vec.Vec[DeadWrite]], live: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as l:
                add_expr_reads(l.value, live)
                if l.name != "_" and l.value != null and not is_live(live, l.name):
                    result.push(DeadWrite(name = l.name, line = l.line))
                remove_from_live(live, l.name)
            ast.Stmt.stmt_assignment as a:
                add_expr_reads(a.value, live)
                match read(a.target):
                    ast.Expr.expr_identifier as id:
                        if id.name != "_":
                            if not is_live(live, id.name) and a.operator == "=":
                                result.push(DeadWrite(name = id.name, line = a.line))
                            remove_from_live(live, id.name)
                    _:
                        pass
            ast.Stmt.stmt_expression as e:
                add_expr_reads(e.expression, live)
            ast.Stmt.stmt_ret as r:
                add_expr_reads(r.value, live)
            ast.Stmt.stmt_if as i:
                var bi = i.branches.len
                while bi > 0:
                    bi -= 1
                    let br = read(i.branches.data + bi)
                    walk_body_backward(br.body, result, live)
                    add_expr_reads(br.condition, live)
                walk_body_backward(i.else_body, result, live)
            ast.Stmt.stmt_while as w:
                # Conservative: body may or may not execute, so reads in the body
                # are live at the loop entry.  Reads in the condition always are.
                walk_body_backward(w.body, result, live)
                add_expr_reads(w.condition, live)
            ast.Stmt.stmt_for as f:
                walk_body_backward(f.body, result, live)
                var fi: ptr_uint = 0
                while fi < f.iterables.len:
                    add_expr_reads(f.iterables.data + fi, live)
                    fi += 1
            ast.Stmt.stmt_match as m:
                add_expr_reads(m.scrutinee, live)
                var ai = m.arms.len
                while ai > 0:
                    ai -= 1
                    walk_body_backward(read(m.arms.data + ai).body, result, live)
            ast.Stmt.stmt_unsafe as u:
                walk_body_backward(u.body, result, live)
            ast.Stmt.stmt_defer as d:
                add_expr_reads(d.expression, live)
            ast.Stmt.stmt_when as w:
                add_expr_reads(w.discriminant, live)
                walk_body_backward(w.else_body, result, live)
                var wi = w.branches.len
                while wi > 0:
                    wi -= 1
                    let br = read(w.branches.data + wi)
                    var bsi = br.body.len
                    while bsi > 0:
                        bsi -= 1
                        walk_stmt_backward(br.body.data + bsi, result, live)
            ast.Stmt.stmt_static_assert as s:
                add_expr_reads(s.condition, live)
            _:
                pass


## Walk an expression backward, adding all identifier reads to the live set.
function add_expr_reads(ep: ptr[ast.Expr]?, live: ref[vec.Vec[str]]) -> void:
    let p = ep else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_identifier as id:
                if id.name != "_":
                    add_to_live(live, id.name)
            ast.Expr.expr_binary_op as b:
                add_expr_reads(b.left, live)
                add_expr_reads(b.right, live)
            ast.Expr.expr_unary_op as u:
                add_expr_reads(u.operand, live)
            ast.Expr.expr_member_access as ma:
                add_expr_reads(ma.receiver, live)
            ast.Expr.expr_index_access as ix:
                add_expr_reads(ix.receiver, live)
                add_expr_reads(ix.index, live)
            ast.Expr.expr_call as cl:
                add_expr_reads(cl.callee, live)
                var ai: ptr_uint = 0
                while ai < cl.args.len:
                    add_expr_reads(read(cl.args.data + ai).arg_value, live)
                    ai += 1
            ast.Expr.expr_specialization as sp:
                add_expr_reads(sp.callee, live)
            ast.Expr.expr_prefix_cast as c:
                add_expr_reads(c.expression, live)
            ast.Expr.expr_await as aw:
                add_expr_reads(aw.expression, live)
            ast.Expr.expr_unsafe as us:
                add_expr_reads(us.expression, live)
            ast.Expr.expr_if as ife:
                add_expr_reads(ife.condition, live)
                add_expr_reads(ife.then_expr, live)
                add_expr_reads(ife.else_expr, live)
            ast.Expr.expr_detach as det:
                add_expr_reads(det.expression, live)
            ast.Expr.expr_format_string as fs:
                var fi: ptr_uint = 0
                while fi < fs.parts.len:
                    var part = read(fs.parts.data + fi)
                    match part:
                        ast.FormatStringPart.fmt_expr as fe:
                            add_expr_reads(fe.expression, live)
                        _:
                            pass
                    fi += 1
            _:
                pass


# =============================================================================
#  Live-set helpers
# =============================================================================

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
