## Reachability analysis for the C backend — which constants and functions are
## actually emitted (mirrors c_backend/reachability.rb).  Extracted from
## c_backend/c_backend.mt.

import std.vec as vec
import std.map as map_mod
import std.string as string
import std.str

import mtc.ir as ir
import mtc.c_naming as naming

import mtc.c_backend.c_backend as c_backend


## Constants reachable from the root module, globals, static asserts, and the
## emitted functions (mirrors Ruby's emitted_constants).  Unreferenced imported
## constants are pruned; in particular foreign C macros such as libuv's
## UV__EFTYPE, whose helper macro `UV__ERR` is undefined by the end of uv.h.
public function emitted_constants(program: ir.Program, funcs: span[ir.Function]) -> vec.Vec[ir.Constant]:
    var by_name = map_mod.Map[str, ptr_uint].create()
    var i: ptr_uint = 0
    while i < program.constants.len:
        unsafe:
            by_name.set(read(program.constants.data + i).linkage_name, i)
        i += 1
    var referenced = map_mod.Map[str, bool].create()
    var root_prefix = string.String.create()
    root_prefix.append(naming.module_c_prefix(program.module_name))
    root_prefix.append("_")
    i = 0
    while i < program.constants.len:
        unsafe:
            let c = read(program.constants.data + i)
            if c.linkage_name.starts_with(root_prefix.as_str()):
                add_constant_ref(c.linkage_name, ref_of(by_name), ref_of(referenced), program)
        i += 1
    i = 0
    while i < program.globals.len:
        unsafe:
            collect_constant_refs_expr(read(program.globals.data + i).value, ref_of(by_name), ref_of(referenced), program)
        i += 1
    i = 0
    while i < program.static_asserts.len:
        unsafe:
            let sa = read(program.static_asserts.data + i)
            collect_constant_refs_expr(sa.condition, ref_of(by_name), ref_of(referenced), program)
            collect_constant_refs_expr(sa.message, ref_of(by_name), ref_of(referenced), program)
        i += 1
    i = 0
    while i < funcs.len:
        unsafe:
            collect_constant_refs_stmts(read(funcs.data + i).body, ref_of(by_name), ref_of(referenced), program)
        i += 1
    var result = vec.Vec[ir.Constant].create()
    i = 0
    while i < program.constants.len:
        unsafe:
            let c = read(program.constants.data + i)
            if referenced.contains(c.linkage_name):
                result.push(c)
        i += 1
    return result


## Mark `name` as a referenced constant and recursively scan its value, so
## constant-to-constant references pull in their dependencies.
function add_constant_ref(name: str, by_name: ref[map_mod.Map[str, ptr_uint]], referenced: ref[map_mod.Map[str, bool]], program: ir.Program) -> void:
    if referenced.contains(name):
        return
    let idx_ptr = by_name.get(name) else:
        return
    referenced.set(name, true)
    let idx = unsafe: read(idx_ptr)
    if idx < program.constants.len:
        collect_constant_refs_expr(unsafe: read(program.constants.data + idx).value, by_name, referenced, program)


function collect_constant_refs_stmts(body: span[ir.Stmt], by_name: ref[map_mod.Map[str, ptr_uint]], referenced: ref[map_mod.Map[str, bool]], program: ir.Program) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            collect_constant_refs_stmt(body.data + i, by_name, referenced, program)
        i += 1


function collect_constant_refs_stmt(sp: ptr[ir.Stmt], by_name: ref[map_mod.Map[str, ptr_uint]], referenced: ref[map_mod.Map[str, bool]], program: ir.Program) -> void:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_local as loc:
                collect_constant_refs_expr(loc.value, by_name, referenced, program)
            ir.Stmt.stmt_assignment as asg:
                collect_constant_refs_expr(asg.target, by_name, referenced, program)
                collect_constant_refs_expr(asg.value, by_name, referenced, program)
            ir.Stmt.stmt_expression as ex:
                collect_constant_refs_expr(ex.expression, by_name, referenced, program)
            ir.Stmt.stmt_return as r:
                let rv = r.value
                if rv != null:
                    collect_constant_refs_expr(rv, by_name, referenced, program)
            ir.Stmt.stmt_block as blk:
                collect_constant_refs_stmts(blk.body, by_name, referenced, program)
            ir.Stmt.stmt_if as iff:
                collect_constant_refs_expr(iff.condition, by_name, referenced, program)
                collect_constant_refs_stmts(iff.then_body, by_name, referenced, program)
                collect_constant_refs_stmts(c_backend.else_stmts_or_empty(iff.else_body), by_name, referenced, program)
            ir.Stmt.stmt_while as w:
                collect_constant_refs_expr(w.condition, by_name, referenced, program)
                collect_constant_refs_stmts(w.body, by_name, referenced, program)
            ir.Stmt.stmt_for as f:
                collect_constant_refs_stmt(f.init, by_name, referenced, program)
                collect_constant_refs_expr(f.condition, by_name, referenced, program)
                collect_constant_refs_stmts(f.body, by_name, referenced, program)
                collect_constant_refs_stmt(f.post, by_name, referenced, program)
            ir.Stmt.stmt_switch as sw:
                collect_constant_refs_expr(sw.expression, by_name, referenced, program)
                var ci: ptr_uint = 0
                while ci < sw.cases.len:
                    let sc = read(sw.cases.data + ci)
                    let cv = sc.value
                    if cv != null:
                        collect_constant_refs_expr(cv, by_name, referenced, program)
                    collect_constant_refs_stmts(sc.body, by_name, referenced, program)
                    ci += 1
            ir.Stmt.stmt_static_assert as sa:
                collect_constant_refs_expr(sa.condition, by_name, referenced, program)
                collect_constant_refs_expr(sa.message, by_name, referenced, program)
            _:
                pass


function collect_constant_refs_expr(ep: ptr[ir.Expr], by_name: ref[map_mod.Map[str, ptr_uint]], referenced: ref[map_mod.Map[str, bool]], program: ir.Program) -> void:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as n:
                add_constant_ref(n.name, by_name, referenced, program)
            ir.Expr.expr_member as m:
                collect_constant_refs_expr(m.receiver, by_name, referenced, program)
            ir.Expr.expr_index as ix:
                collect_constant_refs_expr(ix.receiver, by_name, referenced, program)
                collect_constant_refs_expr(ix.index, by_name, referenced, program)
            ir.Expr.expr_checked_index as ix:
                collect_constant_refs_expr(ix.receiver, by_name, referenced, program)
                collect_constant_refs_expr(ix.index, by_name, referenced, program)
            ir.Expr.expr_checked_span_index as ix:
                collect_constant_refs_expr(ix.receiver, by_name, referenced, program)
                collect_constant_refs_expr(ix.index, by_name, referenced, program)
            ir.Expr.expr_nullable_index as ix:
                collect_constant_refs_expr(ix.receiver, by_name, referenced, program)
                collect_constant_refs_expr(ix.index, by_name, referenced, program)
            ir.Expr.expr_nullable_span_index as ix:
                collect_constant_refs_expr(ix.receiver, by_name, referenced, program)
                collect_constant_refs_expr(ix.index, by_name, referenced, program)
            ir.Expr.expr_call as call:
                var ai: ptr_uint = 0
                while ai < call.arguments.len:
                    collect_constant_refs_expr(call.arguments.data + ai, by_name, referenced, program)
                    ai += 1
            ir.Expr.expr_call_indirect as call:
                collect_constant_refs_expr(call.callee, by_name, referenced, program)
                var bi: ptr_uint = 0
                while bi < call.arguments.len:
                    collect_constant_refs_expr(call.arguments.data + bi, by_name, referenced, program)
                    bi += 1
            ir.Expr.expr_unary as un:
                collect_constant_refs_expr(un.operand, by_name, referenced, program)
            ir.Expr.expr_binary as bin:
                collect_constant_refs_expr(bin.left, by_name, referenced, program)
                collect_constant_refs_expr(bin.right, by_name, referenced, program)
            ir.Expr.expr_conditional as cond:
                collect_constant_refs_expr(cond.condition, by_name, referenced, program)
                collect_constant_refs_expr(cond.then_expression, by_name, referenced, program)
                collect_constant_refs_expr(cond.else_expression, by_name, referenced, program)
            ir.Expr.expr_reinterpret as rin:
                collect_constant_refs_expr(rin.expression, by_name, referenced, program)
            ir.Expr.expr_address_of as addr:
                collect_constant_refs_expr(addr.expression, by_name, referenced, program)
            ir.Expr.expr_cast as cast:
                collect_constant_refs_expr(cast.expression, by_name, referenced, program)
            ir.Expr.expr_aggregate_literal as agg:
                var fi: ptr_uint = 0
                while fi < agg.fields.len:
                    collect_constant_refs_expr(read(agg.fields.data + fi).value, by_name, referenced, program)
                    fi += 1
            ir.Expr.expr_variant_literal as vl:
                var vi: ptr_uint = 0
                while vi < vl.fields.len:
                    collect_constant_refs_expr(read(vl.fields.data + vi).value, by_name, referenced, program)
                    vi += 1
            ir.Expr.expr_array_literal as arr:
                var ei: ptr_uint = 0
                while ei < arr.elements.len:
                    collect_constant_refs_expr(arr.elements.data + ei, by_name, referenced, program)
                    ei += 1
            ir.Expr.expr_stmt_expr as se:
                collect_constant_refs_stmts(se.setup, by_name, referenced, program)
                collect_constant_refs_expr(se.result, by_name, referenced, program)
            ir.Expr.expr_assignment as asg:
                collect_constant_refs_expr(asg.target, by_name, referenced, program)
                collect_constant_refs_expr(asg.value, by_name, referenced, program)
            _:
                pass


## Functions reachable from the entry points (or, absent entry points, from the
## root module's own functions), returned in source order.  Prunes unused
## functions so the output matches the Ruby backend.
public function emitted_functions(program: ir.Program) -> vec.Vec[ir.Function]:
    var func_names = map_mod.Map[str, bool].create()
    var index_by_name = map_mod.Map[str, ptr_uint].create()
    var i: ptr_uint = 0
    while i < program.functions.len:
        unsafe:
            let f = read(program.functions.data + i)
            func_names.set(f.linkage_name, true)
            index_by_name.set(f.linkage_name, i)
        i += 1

    var reachable = map_mod.Map[str, bool].create()
    var worklist = vec.Vec[str].create()

    var any_seed = false
    i = 0
    while i < program.functions.len:
        unsafe:
            let f = read(program.functions.data + i)
            if f.entry_point:
                worklist.push(f.linkage_name)
                any_seed = true
        i += 1
    if not any_seed:
        var prefix = string.String.create()
        prefix.append(naming.module_c_prefix(program.module_name))
        prefix.append("_")
        i = 0
        while i < program.functions.len:
            unsafe:
                let f = read(program.functions.data + i)
                if f.linkage_name.starts_with(prefix.as_str()):
                    worklist.push(f.linkage_name)
            i += 1

    # Seed reachability from global vtable constants: they hold function pointers
    # (expr_name references) to wrapper functions that are otherwise unreachable.
    var ci: ptr_uint = 0
    while ci < program.constants.len:
        unsafe:
            let c = read(program.constants.data + ci)
            reach_from_expr(c.value, ref_of(func_names), ref_of(reachable), ref_of(worklist))
        ci += 1

    # Seed reachability from global variable initializers: a top-level `var`
    # initialized with a no-capture `proc` holds function pointers to synthetic
    # invoke/release/retain wrappers that are reachable only through the global.
    var gvi: ptr_uint = 0
    while gvi < program.globals.len:
        unsafe:
            let gv = read(program.globals.data + gvi)
            reach_from_expr(gv.value, ref_of(func_names), ref_of(reachable), ref_of(worklist))
        gvi += 1

    while true:
        let name = worklist.pop() else:
            break
        if reachable.contains(name):
            continue
        reachable.set(name, true)
        let idx_ptr = index_by_name.get(name)
        if idx_ptr != null:
            unsafe:
                let f = read(program.functions.data + read(idx_ptr))
                reach_from_stmts(f.body, ref_of(func_names), ref_of(reachable), ref_of(worklist))

    var result = vec.Vec[ir.Function].create()
    i = 0
    while i < program.functions.len:
        unsafe:
            let f = read(program.functions.data + i)
            if reachable.contains(f.linkage_name):
                result.push(f)
        i += 1
    return result


function reach_from_stmts(body: span[ir.Stmt], func_names: ref[map_mod.Map[str, bool]], reachable: ref[map_mod.Map[str, bool]], worklist: ref[vec.Vec[str]]) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            reach_from_stmt(body.data + i, func_names, reachable, worklist)
        i += 1


function reach_from_stmt(sp: ptr[ir.Stmt], func_names: ref[map_mod.Map[str, bool]], reachable: ref[map_mod.Map[str, bool]], worklist: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_return as r:
                let value = r.value else:
                    return
                reach_from_expr(value, func_names, reachable, worklist)
            ir.Stmt.stmt_local as loc:
                reach_from_expr(loc.value, func_names, reachable, worklist)
            ir.Stmt.stmt_assignment as asg:
                reach_from_expr(asg.target, func_names, reachable, worklist)
                reach_from_expr(asg.value, func_names, reachable, worklist)
            ir.Stmt.stmt_expression as ex:
                reach_from_expr(ex.expression, func_names, reachable, worklist)
            ir.Stmt.stmt_block as blk:
                reach_from_stmts(blk.body, func_names, reachable, worklist)
            ir.Stmt.stmt_if as iff:
                reach_from_expr(iff.condition, func_names, reachable, worklist)
                reach_from_stmts(iff.then_body, func_names, reachable, worklist)
                reach_from_stmts(c_backend.else_stmts_or_empty(iff.else_body), func_names, reachable, worklist)
            ir.Stmt.stmt_while as w:
                reach_from_expr(w.condition, func_names, reachable, worklist)
                reach_from_stmts(w.body, func_names, reachable, worklist)
            ir.Stmt.stmt_for as f:
                reach_from_stmt(f.init, func_names, reachable, worklist)
                reach_from_expr(f.condition, func_names, reachable, worklist)
                reach_from_stmt(f.post, func_names, reachable, worklist)
                reach_from_stmts(f.body, func_names, reachable, worklist)
            ir.Stmt.stmt_switch as sw:
                reach_from_expr(sw.expression, func_names, reachable, worklist)
                var ci: ptr_uint = 0
                while ci < sw.cases.len:
                    let sc = read(sw.cases.data + ci)
                    reach_from_stmts(sc.body, func_names, reachable, worklist)
                    ci += 1
            _:
                pass


function reach_from_expr(ep: ptr[ir.Expr], func_names: ref[map_mod.Map[str, bool]], reachable: ref[map_mod.Map[str, bool]], worklist: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(ep):
            ir.Expr.expr_call as call:
                if func_names.contains(call.callee) and not reachable.contains(call.callee):
                    worklist.push(call.callee)
                var i: ptr_uint = 0
                while i < call.arguments.len:
                    reach_from_expr(call.arguments.data + i, func_names, reachable, worklist)
                    i += 1
            ir.Expr.expr_call_indirect as call:
                var i: ptr_uint = 0
                while i < call.arguments.len:
                    reach_from_expr(call.arguments.data + i, func_names, reachable, worklist)
                    i += 1
            ir.Expr.expr_name as n:
                if func_names.contains(n.name) and not reachable.contains(n.name):
                    worklist.push(n.name)
            ir.Expr.expr_binary as bin:
                reach_from_expr(bin.left, func_names, reachable, worklist)
                reach_from_expr(bin.right, func_names, reachable, worklist)
            ir.Expr.expr_unary as un:
                reach_from_expr(un.operand, func_names, reachable, worklist)
            ir.Expr.expr_conditional as cond:
                reach_from_expr(cond.condition, func_names, reachable, worklist)
                reach_from_expr(cond.then_expression, func_names, reachable, worklist)
                reach_from_expr(cond.else_expression, func_names, reachable, worklist)
            ir.Expr.expr_member as member:
                reach_from_expr(member.receiver, func_names, reachable, worklist)
            ir.Expr.expr_index as index:
                reach_from_expr(index.receiver, func_names, reachable, worklist)
                reach_from_expr(index.index, func_names, reachable, worklist)
            ir.Expr.expr_cast as cast:
                reach_from_expr(cast.expression, func_names, reachable, worklist)
            ir.Expr.expr_address_of as addr:
                reach_from_expr(addr.expression, func_names, reachable, worklist)
            ir.Expr.expr_aggregate_literal as agg:
                var i: ptr_uint = 0
                while i < agg.fields.len:
                    reach_from_expr(read(agg.fields.data + i).value, func_names, reachable, worklist)
                    i += 1
            ir.Expr.expr_variant_literal as vl:
                var i: ptr_uint = 0
                while i < vl.fields.len:
                    reach_from_expr(read(vl.fields.data + i).value, func_names, reachable, worklist)
                    i += 1
            ir.Expr.expr_array_literal as arr:
                var i: ptr_uint = 0
                while i < arr.elements.len:
                    reach_from_expr(arr.elements.data + i, func_names, reachable, worklist)
                    i += 1
            ir.Expr.expr_stmt_expr as se:
                var i: ptr_uint = 0
                while i < se.setup.len:
                    reach_from_stmt(se.setup.data + i, func_names, reachable, worklist)
                    i += 1
                reach_from_expr(se.result, func_names, reachable, worklist)
            ir.Expr.expr_assignment as asg:
                reach_from_expr(asg.target, func_names, reachable, worklist)
                reach_from_expr(asg.value, func_names, reachable, worklist)
            _:
                pass
