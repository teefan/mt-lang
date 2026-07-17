## redundant-null-check — `x != null` guard on a value already narrowed non-null.
##
## Mirrors the Ruby linter's CFG NullabilityFlow with a structural forward walk
## (the `definite_assignment.mt` pattern): a set of names known non-null is
## threaded through each function body.  `if`/`while` conditions contribute
## edge refinements (`x != null` / `x == null`, composed through `not`, `and`,
## and `or`), writes kill narrowing, and control-flow merges intersect branch
## states.  A branch whose body always leaves the enclosing block (return,
## break, continue, fatal) contributes nothing to the merge, so
## `if x == null: return` narrows `x` for the rest of the body.
##
## The analysis is conservative: any imprecision drops names from the non-null
## set, which can only suppress warnings, never invent false ones.

import std.str
import std.vec as vec

import mtc.parser.ast as ast


## A redundant null check: the tested name and the line of the `if` branch.
public struct Diag:
    name: str
    line: ptr_uint


## A null-test refinement extracted from a condition.  `non_null_if_true`
## means the name is non-null on the true edge and null on the false edge;
## the inverse holds otherwise (an `x == null` test).
struct NullPair:
    name: str
    non_null_if_true: bool


public function check(file: ast.SourceFile) -> vec.Vec[Diag]:
    var diags = vec.Vec[Diag].create()
    var i: ptr_uint = 0
    while i < file.declarations.len:
        unsafe:
            match read(file.declarations.data + i):
                ast.Decl.decl_function as fun:
                    check_body(fun.body, ref_of(diags))
                ast.Decl.decl_extending_block as ex:
                    var j: ptr_uint = 0
                    while j < ex.methods.len:
                        check_body(read(ex.methods.data + j).body, ref_of(diags))
                        j += 1
                _:
                    pass
        i += 1
    return diags


function check_body(body: ptr[ast.Stmt]?, diags: ref[vec.Vec[Diag]]) -> void:
    var state = vec.Vec[str].create()
    defer state.release()
    walk_body(body, ref_of(state), diags)


# =============================================================================
#  Non-null set helpers
# =============================================================================

function set_contains(state: ref[vec.Vec[str]], name: str) -> bool:
    var i: ptr_uint = 0
    while i < state.len():
        let vp = state.get(i) else:
            break
        if unsafe: read(vp) == name:
            return true
        i += 1
    return false


function set_add(state: ref[vec.Vec[str]], name: str) -> void:
    if not set_contains(state, name):
        state.push(name)


function set_remove(state: ref[vec.Vec[str]], name: str) -> void:
    var i: ptr_uint = 0
    while i < state.len():
        let vp = state.get(i) else:
            break
        if unsafe: read(vp) == name:
            let _removed = state.swap_remove(i)
            return
        i += 1


function copy_set(state: ref[vec.Vec[str]]) -> vec.Vec[str]:
    var result = vec.Vec[str].with_capacity(state.len())
    var i: ptr_uint = 0
    while i < state.len():
        let vp = state.get(i) else:
            break
        unsafe:
            result.push(read(vp))
        i += 1
    return result


## Replace `target`'s contents with a copy of `source`.
function assign_set(target: ref[vec.Vec[str]], source: ref[vec.Vec[str]]) -> void:
    target.clear()
    var i: ptr_uint = 0
    while i < source.len():
        let vp = source.get(i) else:
            break
        unsafe:
            target.push(read(vp))
        i += 1


## Merge `other` into the accumulator `target` by intersection.  The first
## merged state seeds the accumulator.
function intersect_into(target: ref[vec.Vec[str]], other: ref[vec.Vec[str]], first: ref[bool]) -> void:
    if read(first):
        assign_set(target, other)
        read(first) = false
        return

    var i: ptr_uint = 0
    while i < target.len():
        let vp = target.get(i) else:
            break
        let name = unsafe: read(vp)
        if set_contains(other, name):
            i += 1
        else:
            let _removed = target.swap_remove(i)


# =============================================================================
#  Condition refinements — the Ruby builder's null_check_pairs
# =============================================================================

## Extract null-test refinements from a condition.  `positive` tracks whether
## the sub-expression is evaluated in a positive or negated context (`not`
## flips it).  Conjunctions narrow only when positive; disjunctions narrow
## only when negative (De Morgan).
function collect_null_pairs(ep: ptr[ast.Expr], positive: bool, pairs: ref[vec.Vec[NullPair]]) -> void:
    unsafe:
        match read(ep):
            ast.Expr.expr_unary_op as u:
                if u.operator == "not":
                    collect_null_pairs(u.operand, not positive, pairs)
            ast.Expr.expr_binary_op as b:
                if b.operator == "and":
                    if positive:
                        collect_null_pairs(b.left, positive, pairs)
                        collect_null_pairs(b.right, positive, pairs)
                else if b.operator == "or":
                    if not positive:
                        collect_null_pairs(b.left, positive, pairs)
                        collect_null_pairs(b.right, positive, pairs)
                else if b.operator == "==":
                    add_single_pair(b.left, b.right, positive, true, pairs)
                else if b.operator == "!=":
                    add_single_pair(b.left, b.right, positive, false, pairs)
            _:
                pass


function add_single_pair(
    left: ptr[ast.Expr],
    right: ptr[ast.Expr],
    positive: bool,
    null_on_true: bool,
    pairs: ref[vec.Vec[NullPair]]
) -> void:
    let name = null_compared_name(left, right)
    if name.len == 0:
        return

    # Ruby: direction = null_on_true == positive ? :null_if_true : :non_null_if_true
    let non_null_if_true = null_on_true != positive
    pairs.push(NullPair(name = name, non_null_if_true = non_null_if_true))


## The identifier name when one side is an identifier and the other a null
## literal; empty otherwise.  Ignored `_`-prefixed bindings yield empty.
function null_compared_name(left: ptr[ast.Expr], right: ptr[ast.Expr]) -> str:
    var name = ""
    unsafe:
        match read(left):
            ast.Expr.expr_identifier as li:
                match read(right):
                    ast.Expr.expr_null_literal:
                        name = li.name
                    _:
                        pass
            ast.Expr.expr_null_literal:
                match read(right):
                    ast.Expr.expr_identifier as ri:
                        name = ri.name
                    _:
                        pass
            _:
                pass

    if name.starts_with("_"):
        return ""

    return name


## True when the name appears in `pairs` with conflicting directions
## (e.g. `x != null and x == null`); conflicted names are dropped.
function pair_conflicted(pairs: ref[vec.Vec[NullPair]], name: str, non_null_if_true: bool) -> bool:
    var i: ptr_uint = 0
    while i < pairs.len():
        let pp = pairs.get(i) else:
            break
        unsafe:
            let p = read(pp)
            if p.name == name and p.non_null_if_true != non_null_if_true:
                return true
        i += 1
    return false


## Apply refinements for one edge of a condition: `cond_true` selects the
## true or false edge.  Adds names proven non-null, removes names proven null.
function apply_refinements(pairs: ref[vec.Vec[NullPair]], cond_true: bool, state: ref[vec.Vec[str]]) -> void:
    var i: ptr_uint = 0
    while i < pairs.len():
        let pp = pairs.get(i) else:
            break
        unsafe:
            let p = read(pp)
            if not pair_conflicted(pairs, p.name, p.non_null_if_true):
                if p.non_null_if_true == cond_true:
                    set_add(state, p.name)
                else:
                    set_remove(state, p.name)
        i += 1


## The identifier being null-tested when the condition is exactly `x != null`
## or `null != x` (the only form the rule reports); empty otherwise.
function null_check_name(ep: ptr[ast.Expr]) -> str:
    unsafe:
        match read(ep):
            ast.Expr.expr_binary_op as b:
                if b.operator == "!=":
                    return null_compared_name(b.left, b.right)
            _:
                pass
    return ""


# =============================================================================
#  Write collection — names whose narrowing a region invalidates
# =============================================================================

function collect_writes_body(body: ptr[ast.Stmt]?, sink: ref[vec.Vec[str]]) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    collect_writes_stmt(blk.statements.data + i, sink)
                    i += 1
            _:
                collect_writes_stmt(bp, sink)


function collect_writes_stmt(sp: ptr[ast.Stmt], sink: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as l:
                set_add(sink, l.name)
                match l.destructure_bindings:
                    Option.some as names:
                        var di: ptr_uint = 0
                        while di < names.value.len:
                            set_add(sink, read(names.value.data + di))
                            di += 1
                    Option.none:
                        pass
                collect_expr_writes(l.value, sink)
                collect_writes_body(l.else_body, sink)
            ast.Stmt.stmt_assignment as a:
                match read(a.target):
                    ast.Expr.expr_identifier as id:
                        set_add(sink, id.name)
                    _:
                        pass
                collect_expr_writes(a.value, sink)
            ast.Stmt.stmt_expression as e:
                collect_expr_writes(e.expression, sink)
            ast.Stmt.stmt_ret as r:
                collect_expr_writes(r.value, sink)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let br = read(iff.branches.data + bi)
                    collect_expr_writes(br.condition, sink)
                    collect_writes_body(br.body, sink)
                    bi += 1
                collect_writes_body(iff.else_body, sink)
            ast.Stmt.stmt_while as wh:
                collect_expr_writes(wh.condition, sink)
                collect_writes_body(wh.body, sink)
            ast.Stmt.stmt_for as fr:
                var fbi: ptr_uint = 0
                while fbi < fr.bindings.len:
                    set_add(sink, read(fr.bindings.data + fbi).name)
                    fbi += 1
                var fii: ptr_uint = 0
                while fii < fr.iterables.len:
                    collect_expr_writes(fr.iterables.data + fii, sink)
                    fii += 1
                collect_writes_body(fr.body, sink)
            ast.Stmt.stmt_match as mt:
                collect_expr_writes(mt.scrutinee, sink)
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    collect_writes_body(read(mt.arms.data + ai).body, sink)
                    ai += 1
            ast.Stmt.stmt_unsafe as un:
                collect_writes_body(un.body, sink)
            ast.Stmt.stmt_defer as d:
                collect_expr_writes(d.expression, sink)
                collect_writes_body(d.body, sink)
            ast.Stmt.stmt_when as wn:
                var wi: ptr_uint = 0
                while wi < wn.branches.len:
                    let br = read(wn.branches.data + wi)
                    var wsi: ptr_uint = 0
                    while wsi < br.body.len:
                        collect_writes_stmt(br.body.data + wsi, sink)
                        wsi += 1
                    wi += 1
                collect_writes_body(wn.else_body, sink)
            ast.Stmt.stmt_parallel_block as pb:
                var pi: ptr_uint = 0
                while pi < pb.bodies.len:
                    collect_writes_stmt(pb.bodies.data + pi, sink)
                    pi += 1
            ast.Stmt.stmt_block as blk:
                var si: ptr_uint = 0
                while si < blk.statements.len:
                    collect_writes_stmt(blk.statements.data + si, sink)
                    si += 1
            _:
                pass


## Mutation through borrows: `ref_of(x)` / `ptr_of(x)` hand out a mutable
## alias, so `x` is treated as written.  Mirrors the Ruby builder's
## `call_argument_mutation_target` (its sema-assisted `out`-param detection
## has no equivalent here; the miss only affects foreign out-params).
function collect_expr_writes(ep: ptr[ast.Expr]?, sink: ref[vec.Vec[str]]) -> void:
    let p = ep else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_call as cl:
                match read(cl.callee):
                    ast.Expr.expr_identifier as callee_id:
                        if (callee_id.name == "ref_of" or callee_id.name == "ptr_of") and cl.args.len == 1:
                            match read(read(cl.args.data + 0).arg_value):
                                ast.Expr.expr_identifier as arg_id:
                                    set_add(sink, arg_id.name)
                                _:
                                    pass
                    _:
                        pass
                collect_expr_writes(cl.callee, sink)
                var ai: ptr_uint = 0
                while ai < cl.args.len:
                    collect_expr_writes(read(cl.args.data + ai).arg_value, sink)
                    ai += 1
            ast.Expr.expr_binary_op as b:
                collect_expr_writes(b.left, sink)
                collect_expr_writes(b.right, sink)
            ast.Expr.expr_unary_op as u:
                collect_expr_writes(u.operand, sink)
            ast.Expr.expr_member_access as ma:
                collect_expr_writes(ma.receiver, sink)
            ast.Expr.expr_index_access as ix:
                collect_expr_writes(ix.receiver, sink)
                collect_expr_writes(ix.index, sink)
            ast.Expr.expr_specialization as sp:
                collect_expr_writes(sp.callee, sink)
            ast.Expr.expr_prefix_cast as c:
                collect_expr_writes(c.expression, sink)
            ast.Expr.expr_await as aw:
                collect_expr_writes(aw.expression, sink)
            ast.Expr.expr_unsafe as us:
                collect_expr_writes(us.expression, sink)
            ast.Expr.expr_detach as det:
                collect_expr_writes(det.expression, sink)
            ast.Expr.expr_if as ife:
                collect_expr_writes(ife.condition, sink)
                collect_expr_writes(ife.then_expr, sink)
                collect_expr_writes(ife.else_expr, sink)
            ast.Expr.expr_named as ne:
                collect_expr_writes(ne.value, sink)
            ast.Expr.expr_range as rg:
                collect_expr_writes(rg.start_expr, sink)
                collect_expr_writes(rg.end_expr, sink)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    collect_expr_writes(el.elements.data + ei, sink)
                    ei += 1
            ast.Expr.expr_format_string as fs:
                var fi: ptr_uint = 0
                while fi < fs.parts.len:
                    match read(fs.parts.data + fi):
                        ast.FormatStringPart.fmt_expr as fe:
                            collect_expr_writes(fe.expression, sink)
                        _:
                            pass
                    fi += 1
            _:
                pass


function remove_all(state: ref[vec.Vec[str]], names: ref[vec.Vec[str]]) -> void:
    var i: ptr_uint = 0
    while i < names.len():
        let np = names.get(i) else:
            break
        unsafe:
            set_remove(state, read(np))
        i += 1


## Apply write-kills from an expression evaluated in linear flow.
function kill_expr_writes(ep: ptr[ast.Expr]?, state: ref[vec.Vec[str]]) -> void:
    var written = vec.Vec[str].create()
    defer written.release()
    collect_expr_writes(ep, ref_of(written))
    remove_all(state, ref_of(written))


# =============================================================================
#  Path termination — a body that always leaves the enclosing block
# =============================================================================

function body_terminates(body: ptr[ast.Stmt]?) -> bool:
    let bp = body else:
        return false
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    if stmt_terminates(blk.statements.data + i):
                        return true
                    i += 1
                return false
            _:
                return stmt_terminates(bp)


function stmt_terminates(sp: ptr[ast.Stmt]) -> bool:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_ret | ast.Stmt.stmt_break | ast.Stmt.stmt_continue:
                return true
            ast.Stmt.stmt_expression as e:
                return is_fatal_call(e.expression)
            ast.Stmt.stmt_if as iff:
                if iff.else_body == null:
                    return false
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    if not body_terminates(read(iff.branches.data + bi).body):
                        return false
                    bi += 1
                return body_terminates(iff.else_body)
            ast.Stmt.stmt_match as mt:
                if mt.arms.len == 0:
                    return false
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    if not body_terminates(read(mt.arms.data + ai).body):
                        return false
                    ai += 1
                return true
            ast.Stmt.stmt_unsafe as un:
                return body_terminates(un.body)
            _:
                return false


function is_fatal_call(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_call as cl:
                match read(cl.callee):
                    ast.Expr.expr_identifier as id:
                        return id.name == "fatal"
                    _:
                        return false
            _:
                return false


# =============================================================================
#  Forward walk
# =============================================================================

function walk_body(body: ptr[ast.Stmt]?, state: ref[vec.Vec[str]], diags: ref[vec.Vec[Diag]]) -> void:
    let bp = body else:
        return
    unsafe:
        match read(bp):
            ast.Stmt.stmt_block as blk:
                var i: ptr_uint = 0
                while i < blk.statements.len:
                    walk_stmt(blk.statements.data + i, state, diags)
                    i += 1
            _:
                walk_stmt(bp, state, diags)


function walk_stmt(sp: ptr[ast.Stmt], state: ref[vec.Vec[str]], diags: ref[vec.Vec[Diag]]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as l:
                kill_expr_writes(l.value, state)
                set_remove(state, l.name)
                match l.destructure_bindings:
                    Option.some as names:
                        var di: ptr_uint = 0
                        while di < names.value.len:
                            set_remove(state, read(names.value.data + di))
                            di += 1
                    Option.none:
                        pass
                if l.else_body != null:
                    var else_state = copy_set(state)
                    walk_body(l.else_body, ref_of(else_state), diags)
                    else_state.release()
            ast.Stmt.stmt_assignment as a:
                kill_expr_writes(a.value, state)
                match read(a.target):
                    ast.Expr.expr_identifier as id:
                        set_remove(state, id.name)
                    _:
                        pass
            ast.Stmt.stmt_expression as e:
                kill_expr_writes(e.expression, state)
            ast.Stmt.stmt_ret as r:
                kill_expr_writes(r.value, state)
            ast.Stmt.stmt_if as iff:
                walk_if(iff.branches, iff.else_body, state, diags)
            ast.Stmt.stmt_while as wh:
                kill_expr_writes(wh.condition, state)
                var killed = vec.Vec[str].create()
                collect_writes_body(wh.body, ref_of(killed))
                remove_all(state, ref_of(killed))
                killed.release()

                var pairs = vec.Vec[NullPair].create()
                collect_null_pairs(wh.condition, true, ref_of(pairs))

                # The condition is re-evaluated before every iteration, so its
                # true-edge refinements hold at the body top even when the body
                # writes the name.
                var body_state = copy_set(state)
                apply_refinements(ref_of(pairs), true, ref_of(body_state))
                walk_body(wh.body, ref_of(body_state), diags)
                body_state.release()

                # Leaving the loop means the condition just evaluated false.
                apply_refinements(ref_of(pairs), false, state)
                pairs.release()
            ast.Stmt.stmt_for as fr:
                var fii: ptr_uint = 0
                while fii < fr.iterables.len:
                    kill_expr_writes(fr.iterables.data + fii, state)
                    fii += 1
                var killed = vec.Vec[str].create()
                collect_writes_body(fr.body, ref_of(killed))
                var fbi: ptr_uint = 0
                while fbi < fr.bindings.len:
                    set_add(ref_of(killed), read(fr.bindings.data + fbi).name)
                    fbi += 1
                remove_all(state, ref_of(killed))
                killed.release()

                var body_state = copy_set(state)
                walk_body(fr.body, ref_of(body_state), diags)
                body_state.release()
            ast.Stmt.stmt_match as mt:
                kill_expr_writes(mt.scrutinee, state)
                var after = vec.Vec[str].create()
                var first = true
                var ai: ptr_uint = 0
                while ai < mt.arms.len:
                    let arm = read(mt.arms.data + ai)
                    var arm_state = copy_set(state)
                    walk_body(arm.body, ref_of(arm_state), diags)
                    if not body_terminates(arm.body):
                        intersect_into(ref_of(after), ref_of(arm_state), ref_of(first))
                    arm_state.release()
                    ai += 1
                if mt.arms.len > 0 and not first:
                    assign_set(state, ref_of(after))
                else if mt.arms.len > 0:
                    # Every arm terminates; the continuation is unreachable.
                    state.clear()
                after.release()
            ast.Stmt.stmt_unsafe as un:
                walk_body(un.body, state, diags)
            ast.Stmt.stmt_defer as d:
                kill_expr_writes(d.expression, state)
                walk_body(d.body, state, diags)
            ast.Stmt.stmt_when as wn:
                var killed = vec.Vec[str].create()
                var wi: ptr_uint = 0
                while wi < wn.branches.len:
                    let br = read(wn.branches.data + wi)
                    var branch_state = copy_set(state)
                    var wsi: ptr_uint = 0
                    while wsi < br.body.len:
                        walk_stmt(br.body.data + wsi, ref_of(branch_state), diags)
                        collect_writes_stmt(br.body.data + wsi, ref_of(killed))
                        wsi += 1
                    branch_state.release()
                    wi += 1
                if wn.else_body != null:
                    var else_state = copy_set(state)
                    walk_body(wn.else_body, ref_of(else_state), diags)
                    else_state.release()
                    collect_writes_body(wn.else_body, ref_of(killed))
                remove_all(state, ref_of(killed))
                killed.release()
            ast.Stmt.stmt_parallel_block as pb:
                var killed = vec.Vec[str].create()
                var pi: ptr_uint = 0
                while pi < pb.bodies.len:
                    var body_state = copy_set(state)
                    walk_stmt(pb.bodies.data + pi, ref_of(body_state), diags)
                    body_state.release()
                    collect_writes_stmt(pb.bodies.data + pi, ref_of(killed))
                    pi += 1
                remove_all(state, ref_of(killed))
                killed.release()
            ast.Stmt.stmt_static_assert as sa:
                kill_expr_writes(sa.condition, state)
            _:
                pass


## Sequential if/else-if/else handling: each branch condition is checked
## against the running state (which accumulates the false-edge refinements of
## every preceding branch), and the continuation state is the intersection of
## all non-terminating paths.
function walk_if(
    branches: span[ast.IfBranch],
    else_body: ptr[ast.Stmt]?,
    state: ref[vec.Vec[str]],
    diags: ref[vec.Vec[Diag]]
) -> void:
    var current = copy_set(state)
    var after = vec.Vec[str].create()
    var first = true

    var bi: ptr_uint = 0
    while bi < branches.len:
        let br = unsafe: read(branches.data + bi)
        kill_expr_writes(br.condition, ref_of(current))

        let checked = null_check_name(br.condition)
        if checked.len != 0 and set_contains(ref_of(current), checked):
            diags.push(Diag(name = checked, line = br.line))

        var pairs = vec.Vec[NullPair].create()
        collect_null_pairs(br.condition, true, ref_of(pairs))

        var branch_state = copy_set(ref_of(current))
        apply_refinements(ref_of(pairs), true, ref_of(branch_state))
        walk_body(br.body, ref_of(branch_state), diags)
        if not body_terminates(br.body):
            intersect_into(ref_of(after), ref_of(branch_state), ref_of(first))
        branch_state.release()

        apply_refinements(ref_of(pairs), false, ref_of(current))
        pairs.release()
        bi += 1

    if else_body != null:
        var else_state = copy_set(ref_of(current))
        walk_body(else_body, ref_of(else_state), diags)
        if not body_terminates(else_body):
            intersect_into(ref_of(after), ref_of(else_state), ref_of(first))
        else_state.release()
    else:
        intersect_into(ref_of(after), ref_of(current), ref_of(first))

    if not first:
        assign_set(state, ref_of(after))
    else:
        # All paths terminated; the continuation is unreachable.
        state.clear()

    current.release()
    after.release()
