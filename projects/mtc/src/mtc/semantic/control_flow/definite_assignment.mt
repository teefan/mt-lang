## Definite-assignment analysis — AST walk that verifies every variable read
## is preceded by a definite assignment (write) on all paths leading to the read.
##
## Uses the CFG builder's binding-ID pre-scan for consistent ID assignment,
## then performs a forward dataflow over the AST with intersection at control-flow
## merge points (if/else, match).

import std.map as map_mod
import std.str
import std.vec as vec

import mtc.parser.ast as ast
import mtc.semantic.control_flow.builder as cfgb


## A diagnostic for a read-before-assignment error.
public struct Diag:
    name: str
    line: ptr_uint
    column: ptr_uint


## Check a function body for reads before definite assignment.  Parameters are
## treated as pre-assigned.  Returns diagnostics for each violation found.
public function check(params: span[ast.Param], body: ptr[ast.Stmt]) -> vec.Vec[Diag]:
    var diags = vec.Vec[Diag].create()

    var cfg = cfgb.empty_cfg()
    cfgb.build_cfg_into(ref_of(cfg), params, body)

    var assigned = map_mod.Map[ptr_uint, bool].create()
    # Lexical scope stack of in-scope local names.  An identifier read is only a
    # tracked local read when its name is currently in scope; names that are not
    # (import aliases, module symbols, out-of-scope block locals, or forward
    # references) resolve elsewhere and are invisible to this pass — mirroring the
    # Ruby reference's scope-aware binding resolution.
    var scopes = vec.Vec[str].create()
    unsafe:
        var pi: ptr_uint = 0
        while pi < params.len:
            let p = read(params.data + pi)
            scopes.push(p.name)
            let id_ptr = cfg.binding_map.get(p.name) else:
                pi += 1
                continue
            assigned.set(read(id_ptr), true)
            pi += 1

    check_stmt(body, ref_of(assigned), ref_of(cfg.binding_map), ref_of(diags), ref_of(scopes))
    scopes.release()
    assigned.release()
    return diags


## ---------------------------------------------------------------------------
##  Statement checking
## ---------------------------------------------------------------------------

function check_stmt(stmt_ptr: ptr[ast.Stmt]?, assigned: ref[map_mod.Map[ptr_uint, bool]], binding_map: ref[map_mod.Map[str, ptr_uint]], diags: ref[vec.Vec[Diag]], scopes: ref[vec.Vec[str]]) -> void:
    if stmt_ptr == null:
        return
    unsafe:
        match read(ptr[ast.Stmt]<-stmt_ptr):
            ast.Stmt.stmt_block as b:
                let mark = scopes.len()
                var i: ptr_uint = 0
                while i < b.statements.len:
                    check_stmt(b.statements.data + i, assigned, binding_map, diags, scopes)
                    i += 1
                truncate_scope(scopes, mark)
            ast.Stmt.stmt_local as l:
                check_expr(l.value, assigned, binding_map, diags, scopes)
                if not l.name.equal("_"):
                    mark_assigned(binding_map, assigned, l.name)
                    scopes.push(l.name)
            ast.Stmt.stmt_assignment as a:
                check_expr(a.value, assigned, binding_map, diags, scopes)
                mark_assigned_target(a.target, assigned, binding_map)
            ast.Stmt.stmt_if as i:
                var bi: ptr_uint = 0
                var after_assigned = map_mod.Map[ptr_uint, bool].create()
                var first_branch = true
                while bi < i.branches.len:
                    let br = read(i.branches.data + bi)
                    check_expr(br.condition, assigned, binding_map, diags, scopes)
                    var branch_assigned = copy_assigned(assigned)
                    check_stmt(br.body, ref_of(branch_assigned), binding_map, diags, scopes)
                    intersect_assigned(ref_of(after_assigned), ref_of(branch_assigned), ref_of(first_branch))
                    branch_assigned.release()
                    first_branch = false
                    bi += 1
                if i.else_body != null:
                    var else_assigned = copy_assigned(assigned)
                    check_stmt(i.else_body, ref_of(else_assigned), binding_map, diags, scopes)
                    intersect_assigned(ref_of(after_assigned), ref_of(else_assigned), ref_of(first_branch))
                    else_assigned.release()
                else:
                    intersect_assigned(ref_of(after_assigned), assigned, ref_of(first_branch))
                swap_assigned(assigned, ref_of(after_assigned))
                after_assigned.release()
            ast.Stmt.stmt_while as w:
                check_expr(w.condition, assigned, binding_map, diags, scopes)
                var body_assigned = copy_assigned(assigned)
                check_stmt(w.body, ref_of(body_assigned), binding_map, diags, scopes)
                body_assigned.release()
            ast.Stmt.stmt_for as fr:
                var fi: ptr_uint = 0
                while fi < fr.iterables.len:
                    check_expr(fr.iterables.data + fi, assigned, binding_map, diags, scopes)
                    fi += 1
                var for_assigned = copy_assigned(assigned)
                check_stmt(fr.body, ref_of(for_assigned), binding_map, diags, scopes)
                for_assigned.release()
            ast.Stmt.stmt_match as m:
                check_expr(m.scrutinee, assigned, binding_map, diags, scopes)
                var after_assigned = map_mod.Map[ptr_uint, bool].create()
                var first_branch = true
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    let arm = read(m.arms.data + ai)
                    var arm_assigned = copy_assigned(assigned)
                    check_stmt(arm.body, ref_of(arm_assigned), binding_map, diags, scopes)
                    intersect_assigned(ref_of(after_assigned), ref_of(arm_assigned), ref_of(first_branch))
                    arm_assigned.release()
                    first_branch = false
                    ai += 1
                swap_assigned(assigned, ref_of(after_assigned))
                after_assigned.release()
            ast.Stmt.stmt_ret as r:
                check_expr(r.value, assigned, binding_map, diags, scopes)
            ast.Stmt.stmt_defer as d:
                check_expr(d.expression, assigned, binding_map, diags, scopes)
                # Defer body does not affect the current flow; skip it.
            ast.Stmt.stmt_expression as e:
                check_expr(e.expression, assigned, binding_map, diags, scopes)
            ast.Stmt.stmt_unsafe as u:
                check_stmt(u.body, assigned, binding_map, diags, scopes)
            ast.Stmt.stmt_break:
                pass
            ast.Stmt.stmt_continue:
                pass
            ast.Stmt.stmt_pass:
                pass
            _:
                pass


## ---------------------------------------------------------------------------
##  Expression checking — validates every identifier read is assigned.
## ---------------------------------------------------------------------------

function check_expr(ep: ptr[ast.Expr]?, assigned: ref[map_mod.Map[ptr_uint, bool]], binding_map: ref[map_mod.Map[str, ptr_uint]], diags: ref[vec.Vec[Diag]], scopes: ref[vec.Vec[str]]) -> void:
    if ep == null:
        return
    unsafe:
        match read(ptr[ast.Expr]<-ep):
            ast.Expr.expr_identifier as id:
                if not id.name.equal("_") and scope_has(scopes, id.name):
                    let bid = binding_map.get(id.name)
                    if bid != null:
                        let id_val = read(bid)
                        if not assigned.contains(id_val):
                            diags.push(Diag(name = id.name, line = id.line, column = id.column))
            ast.Expr.expr_binary_op as b:
                check_expr(b.left, assigned, binding_map, diags, scopes)
                check_expr(b.right, assigned, binding_map, diags, scopes)
            ast.Expr.expr_unary_op as u:
                check_expr(u.operand, assigned, binding_map, diags, scopes)
            ast.Expr.expr_member_access as ma:
                check_expr(ma.receiver, assigned, binding_map, diags, scopes)
            ast.Expr.expr_index_access as ix:
                check_expr(ix.receiver, assigned, binding_map, diags, scopes)
                check_expr(ix.index, assigned, binding_map, diags, scopes)
            ast.Expr.expr_call as cl:
                check_expr(cl.callee, assigned, binding_map, diags, scopes)
                var ai: ptr_uint = 0
                while ai < cl.args.len:
                    let arg = read(cl.args.data + ai)
                    check_expr(arg.arg_value, assigned, binding_map, diags, scopes)
                    ai += 1
            ast.Expr.expr_prefix_cast as c:
                check_expr(c.expression, assigned, binding_map, diags, scopes)
            ast.Expr.expr_await as aw:
                check_expr(aw.expression, assigned, binding_map, diags, scopes)
            ast.Expr.expr_unsafe as us:
                check_expr(us.expression, assigned, binding_map, diags, scopes)
            ast.Expr.expr_if as ife:
                check_expr(ife.condition, assigned, binding_map, diags, scopes)
                check_expr(ife.then_expr, assigned, binding_map, diags, scopes)
                check_expr(ife.else_expr, assigned, binding_map, diags, scopes)
            ast.Expr.expr_detach as det:
                check_expr(det.expression, assigned, binding_map, diags, scopes)
            ast.Expr.expr_format_string as fs:
                var fi: ptr_uint = 0
                while fi < fs.parts.len:
                    var part: ast.FormatStringPart = read(fs.parts.data + fi)
                    match part:
                        ast.FormatStringPart.fmt_expr as fe:
                            check_expr(fe.expression, assigned, binding_map, diags, scopes)
                        _:
                            pass
                    fi += 1
            _:
                pass


## Truncate the scope stack back to `mark`, dropping names declared since.
function truncate_scope(scopes: ref[vec.Vec[str]], mark: ptr_uint) -> void:
    while scopes.len() > mark:
        let _dropped = scopes.pop()


## True when `name` is currently an in-scope local (declared in some active
## lexical frame).  Names that resolve outside the locals (import aliases,
## module symbols) return false and are skipped by the read check.
function scope_has(scopes: ref[vec.Vec[str]], name: str) -> bool:
    var i: ptr_uint = 0
    while i < scopes.len():
        let p = scopes.get(i) else:
            break
        unsafe:
            if read(p).equal(name):
                return true
        i += 1
    return false


## ---------------------------------------------------------------------------
##  Set helpers — maps of ptr_uint → bool used as ID sets.
## ---------------------------------------------------------------------------

function mark_assigned(binding_map: ref[map_mod.Map[str, ptr_uint]], assigned: ref[map_mod.Map[ptr_uint, bool]], name: str) -> void:
    let bid = binding_map.get(name)
    if bid != null:
        unsafe:
            assigned.set(read(bid), true)

function mark_assigned_target(target: ptr[ast.Expr], assigned: ref[map_mod.Map[ptr_uint, bool]], binding_map: ref[map_mod.Map[str, ptr_uint]]) -> void:
    unsafe:
        match read(target):
            ast.Expr.expr_identifier as id:
                mark_assigned(binding_map, assigned, id.name)
            _:
                pass

function copy_assigned(src: ref[map_mod.Map[ptr_uint, bool]]) -> map_mod.Map[ptr_uint, bool]:
    var result = map_mod.Map[ptr_uint, bool].create()
    var entries = src.entries()
    while true:
        if not entries.next():
            break
        unsafe:
            result.set(read(entries.current().key), true)
    return result

## Intersect `branch` into `result`.  When `init` is true, `branch` is the first
## branch and its contents are copied directly into `result`.
function intersect_assigned(result: ref[map_mod.Map[ptr_uint, bool]], branch: ref[map_mod.Map[ptr_uint, bool]], init: ref[bool]) -> void:
    if read(init):
        var entries = branch.entries()
        while true:
            if not entries.next():
                break
            unsafe:
                result.set(read(entries.current().key), true)
        read(init) = false
    else:
        var to_remove = vec.Vec[ptr_uint].create()
        var entries = result.entries()
        while true:
            if not entries.next():
                break
            unsafe:
                let k = read(entries.current().key)
                if not branch.contains(k):
                    to_remove.push(k)
        var i: ptr_uint = 0
        while i < to_remove.len():
            let kr = to_remove.get(i) else:
                break
            unsafe:
                let _removed = result.remove(read(kr))
            i += 1
        to_remove.release()

function swap_assigned(target: ref[map_mod.Map[ptr_uint, bool]], source: ref[map_mod.Map[ptr_uint, bool]]) -> void:
    clear_map(target)
    var entries = source.entries()
    while true:
        if not entries.next():
            break
        unsafe:
            target.set(read(entries.current().key), true)

function clear_map(m: ref[map_mod.Map[ptr_uint, bool]]) -> void:
    var to_remove = vec.Vec[ptr_uint].create()
    var entries = m.entries()
    while true:
        if not entries.next():
            break
        unsafe:
            to_remove.push(read(entries.current().key))
    var i: ptr_uint = 0
    while i < to_remove.len():
        let kr = to_remove.get(i) else:
            break
        unsafe:
            let _removed = m.remove(read(kr))
        i += 1
    to_remove.release()
