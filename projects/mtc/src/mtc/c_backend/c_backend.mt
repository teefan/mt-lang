## C backend — transforms an `ir.Program` into C source text.  This is the
## decoupled back-end: it reads only `ir`, never the analyzer or lowering
## internals.
##
## Mirrors the Ruby CBackend (lib/milk_tea/core/c_backend.rb `generate_c` and the
## type_system / type_declaration / statements / expressions / feature_detection
## modules).
##
## Scope (through Phase 2b): includes (+ conditional `mt_str` string-view type and
## `mt_str_equal` helper), enum/flags declarations, function forward declarations,
## deduplicated `mt_str` string-literal constants, and function bodies over
## scalars, `str`/`cstr`, control flow, and enum `match`→`switch`.

import std.string as string
import std.str
import std.fmt as fmt
import std.map as map_mod
import std.vec as vec
import std.mem.heap as heap

import mtc.ir as ir
import mtc.semantic.types as types
import mtc.c_naming as naming
import mtc.lowering.utils as utils


## A backend-stage error.  Placeholder for Phase 1+.
public struct CBackendError:
    message: str
    line: ptr_uint
    column: ptr_uint
    path: str


## The C emitter: an output buffer plus the program-global string-literal map
## (`str` content -> `mt_str_lit_N`) threaded through expression emission.
struct Emitter:
    buffer: string.String
    str_lit_map: map_mod.Map[str, str]
    # Labels targeted by a `goto` in the current function; a `stmt_label` whose
    # name is absent is unused and skipped (mirrors Ruby's used_labels set).
    used_labels: map_mod.Map[str, bool]
    # Variant C struct names whose equality helpers must be emitted.
    variant_eq_set: map_mod.Map[str, bool]
    # Nullable value type C trivially emitted as mt_opt_* typedefs.
    opt_type_set: map_mod.Map[str, types.Type]
    # std.c.* backing C names for type aliases, keyed by the internal name
    # (e.g. "sockaddr_storage" → "struct sockaddr_storage").
    std_c_backing: map_mod.Map[str, str]


## Local variant-arm metadata for prelude type collection (mirrors lowering's
## VariantArmInfo / VariantInfo, scoped small for the backend).
struct GVArmInfo:
    name: str
    fields: span[ir.Field]


struct GVInfo:
    arms: span[GVArmInfo]


## Opt types that need synthetic StructDecl entries for topological ordering.
## `decl` is the StructDecl; `field_store` keeps the field spans alive.
public struct OptStructEntry:
    decl: ir.StructDecl
    field_store: vec.Vec[ir.Field]


public function generate_c(program: ir.Program) -> string.String:
    var e = Emitter(
        buffer = string.String.create(),
        str_lit_map = map_mod.Map[str, str].create(),
        used_labels = map_mod.Map[str, bool].create(),
        variant_eq_set = map_mod.Map[str, bool].create(),
        opt_type_set = map_mod.Map[str, types.Type].create(),
        std_c_backing = map_mod.Map[str, str].create(),
    )

    # Reachability pruning: emit only functions reachable from the entry points,
    # in source order (mirrors c_backend/reachability.rb emitted_functions).
    var emitted = emitted_functions(program)
    let funcs = emitted.as_span()

    var str_lits = collect_str_literals(funcs)
    var li: ptr_uint = 0
    while li < str_lits.len():
        let value_ptr = str_lits.get(li) else:
            break
        unsafe:
            e.str_lit_map.set(read(value_ptr), str_literal_name(li))
        li += 1

    let has_str_literals = str_lits.len() > 0
    var checked_index_types = collect_checked_index_types(funcs)
    var checked_span_index_types = collect_checked_span_index_types(funcs)
    var tuple_types = collect_tuple_types(funcs)
    var gen_variants = collect_generic_variants(program)
    var opt_structs = collect_opt_struct_decls(program)
    # Bounds-checked accessors call mt_fatal, so their presence pulls in the
    # fatal helper (and, via uses_string_view, the mt_str type + <stdlib.h>).
    let use_fatal = uses_fatal_helper(funcs, program) or checked_index_types.len() > 0 or checked_span_index_types.len() > 0
    let use_fatal_str = uses_fatal_str_helper(funcs)
    let use_entry_argv = uses_entry_argv(program)
    let use_string_view = uses_string_view(funcs, has_str_literals) or use_fatal or use_fatal_str or aggregates_use_str(program) or gen_variants_have_str(ref_of(gen_variants)) or use_entry_argv
    let use_str_equality = uses_str_equality(funcs)

    # Feature-test macros required by the fs/tls support headers and the
    # parallel/detach runtime (mirrors Ruby's _GNU_SOURCE / _POSIX_C_SOURCE
    # preamble block).
    if includes_need_feature_macros(program) or uses_parallel_runtime(program):
        emit_line(ref_of(e), "#ifndef _GNU_SOURCE")
        emit_line(ref_of(e), "#define _GNU_SOURCE")
        emit_line(ref_of(e), "#endif")
        emit_line(ref_of(e), "#ifndef _POSIX_C_SOURCE")
        emit_line(ref_of(e), "#define _POSIX_C_SOURCE 200809L")
        emit_line(ref_of(e), "#endif")
        emit_line(ref_of(e), "")

    # Emit the include set deduplicated (mirrors Ruby's `headers.uniq`).
    # `<stddef.h>` (offsetof) follows `<string.h>` to match Ruby's ordering.
    let use_offsetof = functions_use_offsetof(funcs) or constants_use_offsetof(program.constants)
    var seen_headers = map_mod.Map[str, bool].create()
    var i: ptr_uint = 0
    while i < program.includes.len:
        unsafe:
            let header = read(program.includes.data + i).header
            if not seen_headers.contains(header):
                seen_headers.set(header, true)
                emit_line(ref_of(e), j2("#include ", header))
                if use_offsetof and header == "<string.h>" and not seen_headers.contains("<stddef.h>"):
                    seen_headers.set("<stddef.h>", true)
                    emit_line(ref_of(e), "#include <stddef.h>")
        i += 1
    if use_offsetof and not seen_headers.contains("<stddef.h>"):
        seen_headers.set("<stddef.h>", true)
        emit_line(ref_of(e), "#include <stddef.h>")
    if (use_fatal or use_fatal_str or use_entry_argv) and not seen_headers.contains("<stdlib.h>"):
        seen_headers.set("<stdlib.h>", true)
        emit_line(ref_of(e), "#include <stdlib.h>")
    if use_entry_argv and not seen_headers.contains("<string.h>"):
        seen_headers.set("<string.h>", true)
        emit_line(ref_of(e), "#include <string.h>")
    if uses_parallel_runtime(program) and not seen_headers.contains("\"uv.h\""):
        seen_headers.set("\"uv.h\"", true)
        emit_line(ref_of(e), "#include \"uv.h\"")
    emit_line(ref_of(e), "")

    if use_string_view:
        emit_string_type(ref_of(e))
        emit_line(ref_of(e), "")
        emit_builtin_type_defs(ref_of(e), program)

    if use_fatal:
        emit_fatal_helper(ref_of(e))
        emit_line(ref_of(e), "")

    if use_fatal:
        emit_fatal_str_helper(ref_of(e))
        emit_line(ref_of(e), "")
    else if use_fatal_str:
        emit_fatal_str_helper(ref_of(e))
        emit_line(ref_of(e), "")

    if use_str_equality:
        emit_str_equality_helper(ref_of(e))
        emit_line(ref_of(e), "")

    var span_types = collect_span_types(funcs)
    collect_struct_span_types(program, ref_of(span_types))
    collect_variant_span_types(program, ref_of(span_types))

    # Emit runtime helpers before forward declarations (mirrors Ruby order).

    # Emit format string runtime helpers when used.
    if uses_format_helpers(program):
        emit_format_string_helpers(ref_of(e))

    # Emit event runtime helpers when any event method calls are present.
    # Event runtime handled by per-event synthetic functions in the lowering.

    # Emit parallel runtime helpers when any parallel/detach calls are present.
    if uses_parallel_runtime(program):
        emit_parallel_helpers(ref_of(e))

    # Emit builtin helpers (order/equal/hash) when used.
    if uses_builtin_helpers(program):
        emit_builtin_helpers(ref_of(e))

    if uses_event_runtime(program):
        emit_event_helpers(ref_of(e))

    if uses_foreign_cstr_helper(funcs):
        emit_foreign_cstr_helper(ref_of(e))
        emit_line(ref_of(e), "")

    if program.structs.len > 0 or program.unions.len > 0 or tuple_types.len() > 0 or program.variants.len > 0 or gen_variants.len() > 0 or opt_structs.len() > 0:
        var sorted_structs = topo_sort_structs(program.structs)
        let sorted = sorted_structs.as_span()

        # Emit span type forward declarations first (so struct types can reference them).
        var si: ptr_uint = 0
        while si < span_types.len():
            let ty_ptr = span_types.get(si) else:
                break
            unsafe:
                emit_line(ref_of(e), j3("typedef struct ", span_type_name(array_element_type(read(ty_ptr))), ";"))
            si += 1
        if span_types.len() > 0:
            emit_line(ref_of(e), "")

        i = 0
        while i < sorted.len:
            unsafe:
                let s = read(sorted.data + i)
                emit_line(ref_of(e), j3("typedef struct ", s.linkage_name, j2(" ", j2(s.linkage_name, ";"))))
            i += 1
        i = 0
        while i < program.unions.len:
            unsafe:
                let u = read(program.unions.data + i)
                emit_line(ref_of(e), j3("typedef union ", u.linkage_name, j2(" ", j2(u.linkage_name, ";"))))
            i += 1
        i = 0
        while i < tuple_types.len():
            let ty_ptr = tuple_types.get(i) else:
                break
            unsafe:
                emit_tuple_type_forward(ref_of(e), read(ty_ptr))
            i += 1
        i = 0
        while i < program.variants.len:
            unsafe:
                emit_variant_forward(ref_of(e), read(program.variants.data + i))
            i += 1
        i = 0
        while i < gen_variants.len():
            let v_ptr = gen_variants.get(i) else:
                break
            unsafe:
                emit_variant_forward(ref_of(e), read(v_ptr))
            i += 1
        i = 0
        while i < opt_structs.len():
            let os_ptr = opt_structs.get(i) else:
                break
            unsafe:
                let os = read(os_ptr)
                emit_line(ref_of(e), j3("typedef struct ", os.decl.linkage_name, j2(" ", j2(os.decl.linkage_name, ";"))))
            i += 1
        emit_line(ref_of(e), "")

        emit_enums_block(ref_of(e), program)

        # Task forward declarations must come before type aliases because
        # aliases like `typedef mt_task_X ChanMessageTask` reference them.
        emit_task_forward_decls(ref_of(e), program)

        emit_type_aliases(ref_of(e), program)

        # Emit span type full definitions after forward declarations
        # so they can reference struct types.
        si = 0
        while si < span_types.len():
            let ty_ptr = span_types.get(si) else:
                break
            unsafe:
                emit_span_type(ref_of(e), read(ty_ptr))
            emit_line(ref_of(e), "")
            si += 1

        # Emit struct and variant full definitions in a single dependency order,
        # since structs and variants can embed each other by value.
        var type_order = topo_sort_types(program.structs, ref_of(gen_variants), program.variants, ref_of(opt_structs))
        var toi: ptr_uint = 0
        while toi < type_order.len():
            let node_ptr = type_order.get(toi) else:
                break
            unsafe:
                let node = read(node_ptr)
                if node.kind == 0:
                    emit_struct(ref_of(e), read(program.structs.data + node.index))
                else if node.kind == 1:
                    let gv_ptr = gen_variants.get(node.index) else:
                        toi += 1
                        continue
                    emit_variant(ref_of(e), read(gv_ptr))
                else if node.kind == 2:
                    emit_variant(ref_of(e), read(program.variants.data + node.index))
                else:
                    let os_ptr = opt_structs.get(node.index) else:
                        toi += 1
                        continue
                    emit_struct(ref_of(e), read(os_ptr).decl)
            emit_line(ref_of(e), "")
            toi += 1

        # Emit Task struct definitions after struct/variant definitions so that
        # Task structs that embed by-value variants (e.g. Task[Result[void, E]])
        # have the variant type already defined.
        emit_task_structs(ref_of(e), program)
        i = 0
        while i < program.unions.len:
            unsafe:
                emit_union(ref_of(e), read(program.unions.data + i))
            emit_line(ref_of(e), "")
            i += 1

        # Emit SoA struct definitions after regular structs (they reference
        # element struct fields by C name).
        emit_soa_types(ref_of(e), funcs, program)

        i = 0
        while i < tuple_types.len():
            let ty_ptr = tuple_types.get(i) else:
                break
            unsafe:
                emit_tuple_type_def(ref_of(e), read(ty_ptr))
            emit_line(ref_of(e), "")
            i += 1

    else:
        emit_enums_block(ref_of(e), program)

    if funcs.len > 0:
        i = 0
        while i < funcs.len:
            unsafe:
                emit_line(ref_of(e), j2(function_signature(read(funcs.data + i)), ";"))
            i += 1
        emit_line(ref_of(e), "")

    i = 0
    while i < checked_index_types.len():
        let ty_ptr = checked_index_types.get(i) else:
            break
        unsafe:
            emit_checked_index_helper(ref_of(e), read(ty_ptr))
        emit_line(ref_of(e), "")
        i += 1

    i = 0
    while i < checked_span_index_types.len():
        let ty_ptr = checked_span_index_types.get(i) else:
            break
        unsafe:
            emit_checked_span_index_helper(ref_of(e), read(ty_ptr))
        emit_line(ref_of(e), "")
        i += 1

    if has_str_literals:
        i = 0
        while i < str_lits.len():
            let value_ptr = str_lits.get(i) else:
                break
            unsafe:
                emit_line(ref_of(e), render_str_literal_constant(read(value_ptr), i))
            i += 1
        emit_line(ref_of(e), "")

    if program.constants.len > 0:
        var ci: ptr_uint = 0
        while ci < program.constants.len:
            unsafe:
                let c = read(program.constants.data + ci)
                emit_line(ref_of(e), render_constant(ref_of(e), c))
            ci += 1
        emit_line(ref_of(e), "")

    if program.globals.len > 0:
        var gi: ptr_uint = 0
        while gi < program.globals.len:
            unsafe:
                let g = read(program.globals.data + gi)
                emit_line(ref_of(e), render_global(ref_of(e), g))
            gi += 1
        emit_line(ref_of(e), "")

    # Emit str_buffer runtime helpers if any str_buffer struct is present.
    if has_str_buffer_structs(program):
        emit_str_buffer_helpers(ref_of(e))

    # Pre-scan functions for variant equality to know which helpers to emit.
    scan_variant_equality(ref_of(e), funcs, program)
    if e.variant_eq_set.len() > 0:
        emit_variant_equality_helpers(ref_of(e), program)

    # Emit the argv → span[str] entry bridge helpers when the entry point uses them.
    if use_entry_argv:
        emit_entry_argv_helpers(ref_of(e))

    i = 0
    while i < funcs.len:
        unsafe:
            emit_function(ref_of(e), read(funcs.data + i))
        if i < funcs.len - 1:
            emit_line(ref_of(e), "")
        i += 1

    return e.buffer


# =============================================================================
#  Reachability (mirrors c_backend/reachability.rb emitted_functions)
# =============================================================================

## Functions reachable from the entry points (or, absent entry points, from the
## root module's own functions), returned in source order.  Prunes unused
## functions so the output matches the Ruby backend.
function emitted_functions(program: ir.Program) -> vec.Vec[ir.Function]:
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
                reach_from_stmts(iff.else_body, func_names, reachable, worklist)
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
            _:
                pass




# =============================================================================
#  String helpers
# =============================================================================

function j2(a: str, b: str) -> str:
    return utils.j2(a, b)


function j3(a: str, b: str, c: str) -> str:
    return utils.j3(a, b, c)


function j4(a: str, b: str, c: str, d: str) -> str:
    return utils.j4(a, b, c, d)


function j5(a: str, b: str, c: str, d: str, e: str) -> str:
    return utils.j5(a, b, c, d, e)


function j6(a: str, b: str, c: str, d: str, e: str, f: str) -> str:
    return utils.j6(a, b, c, d, e, f)


function emit_line(e: ref[Emitter], text: str) -> void:
    e.buffer.append(text)
    e.buffer.append("\n")


function indent_c(level: ptr_uint) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < level:
        buf.append("  ")
        i += 1
    return buf.as_str()


function long_to_str(value: long) -> str:
    var buf = string.String.create()
    fmt.append_long(ref_of(buf), value)
    return buf.as_str()


function double_to_str(value: double) -> str:
    var buf = string.String.create()
    fmt.append_double(ref_of(buf), value)
    return buf.as_str()


function ptr_uint_to_str(value: ptr_uint) -> str:
    var buf = string.String.create()
    fmt.append_ptr_uint(ref_of(buf), value)
    return buf.as_str()


# =============================================================================
#  String runtime (mirrors c_backend/type_declaration.rb + runtime_helpers.rb)
# =============================================================================

function emit_string_type(e: ref[Emitter]) -> void:
    emit_line(e, "typedef struct mt_str {")
    emit_line(e, "  char* data;")
    emit_line(e, "  uintptr_t len;")
    emit_line(e, "} mt_str;")


function emit_str_equality_helper(e: ref[Emitter]) -> void:
    emit_line(e, "static bool mt_str_equal(mt_str left, mt_str right) {")
    emit_line(e, "  if (left.len != right.len) return false;")
    emit_line(e, "  for (uintptr_t index = 0; index < left.len; index++) {")
    emit_line(e, "    if (left.data[index] != right.data[index]) return false;")
    emit_line(e, "  }")
    emit_line(e, "  return true;")
    emit_line(e, "}")


function emit_fatal_helper(e: ref[Emitter]) -> void:
    emit_line(e, "static _Noreturn void mt_fatal(const char* message) {")
    emit_line(e, "  fputs(message, stderr);")
    emit_line(e, "  fputc('\\n', stderr);")
    emit_line(e, "  abort();")
    emit_line(e, "}")


## The `str`-argument fatal helper: writes the byte view then aborts.  Mirrors
## Ruby's `mt_fatal_str` runtime helper; used for `fatal(str)` calls.
function emit_fatal_str_helper(e: ref[Emitter]) -> void:
    emit_line(e, "static _Noreturn void mt_fatal_str(mt_str message) {")
    emit_line(e, "  fwrite(message.data, 1, message.len, stderr);")
    emit_line(e, "  fputc('\\n', stderr);")
    emit_line(e, "  abort();")
    emit_line(e, "}")


function str_literal_name(index: ptr_uint) -> str:
    return j2("mt_str_lit_", ptr_uint_to_str(index))


function render_str_literal_constant(value: str, index: ptr_uint) -> str:
    return j6(
        "static const mt_str ",
        str_literal_name(index),
        " = { .data = ",
        c_string_literal(value),
        j3(", .len = ", ptr_uint_to_str(value.len), " };"),
        "",
    )


## A C double-quoted string literal for `value`, escaping the C-significant
## bytes.  UTF-8 text bytes (>= 0x80) pass through unescaped, matching Ruby's
## String#inspect for ordinary text.
function c_string_literal(value: str) -> str:
    var buf = string.String.create()
    buf.append("\"")
    var i: ptr_uint = 0
    while i < value.len:
        let b = value.byte_at(i)
        if b == 34:
            buf.append("\\\"")
        else if b == 92:
            buf.append("\\\\")
        else if b == 10:
            buf.append("\\n")
        else if b == 13:
            buf.append("\\r")
        else if b == 9:
            buf.append("\\t")
        else if b == 0:
            buf.append("\\0")
        else:
            buf.push_byte(b)
        i += 1
    buf.append("\"")
    return buf.as_str()


# =============================================================================
#  Feature detection (mirrors c_backend/feature_detection.rb)
# =============================================================================

## True when any struct, union, or variant declaration has a `str`-typed field,
## so the `mt_str` view type must be emitted even if no function signature or
## literal references `str` directly.
function aggregates_use_str(program: ir.Program) -> bool:
    var i: ptr_uint = 0
    while i < program.structs.len:
        unsafe:
            if fields_have_str(read(program.structs.data + i).fields):
                return true
        i += 1
    i = 0
    while i < program.unions.len:
        unsafe:
            if fields_have_str(read(program.unions.data + i).fields):
                return true
        i += 1
    i = 0
    while i < program.variants.len:
        unsafe:
            let vd = read(program.variants.data + i)
            var ai: ptr_uint = 0
            while ai < vd.arms.len:
                if fields_have_str(read(vd.arms.data + ai).fields):
                    return true
                ai += 1
        i += 1
    return false


## True when any generated (synthetic) generic variant has a `str`-typed arm
## field.  These variants are emitted by `collect_generic_variants` and are not
## present in the program's static variant declarations.
function gen_variants_have_str(variants: ref[vec.Vec[ir.VariantDecl]]) -> bool:
    var i: ptr_uint = 0
    while i < variants.len():
        let v_ptr = variants.get(i) else:
            break
        unsafe:
            let vd = read(v_ptr)
            var ai: ptr_uint = 0
            while ai < vd.arms.len:
                if fields_have_str(read(vd.arms.data + ai).fields):
                    return true
                ai += 1
        i += 1
    return false


function fields_have_str(fields: span[ir.Field]) -> bool:
    var i: ptr_uint = 0
    while i < fields.len:
        unsafe:
            if is_str_type(read(fields.data + i).ty):
                return true
        i += 1
    return false


# =============================================================================
#  Generic variant collection (mirrors c_backend/type_collectors.rb)
# =============================================================================

## Collect every unique concrete generic variant type referenced in the lowered
## program so the backend can emit their payload structs, kind enums, data unions,
## and outer tagged structs.  Prelude types (Option/Result) are synthetic and not
## present as AST decls, so this is the only way they reach the backend.
function collect_generic_variants(program: ir.Program) -> vec.Vec[ir.VariantDecl]:
    var seen = map_mod.Map[str, bool].create()
    var result = vec.Vec[ir.VariantDecl].create()
    # Seed seen with variants already in program.variants (from lowering).
    var si: ptr_uint = 0
    while si < program.variants.len:
        unsafe:
            seen.set(read(program.variants.data + si).linkage_name, true)
        si += 1
    var i: ptr_uint = 0
    while i < program.functions.len:
        unsafe:
            collect_gv_from_func(read(program.functions.data + i), ref_of(seen), ref_of(result))
        i += 1
    return result


function collect_gv_from_func(func: ir.Function, seen: ref[map_mod.Map[str, bool]], result: ref[vec.Vec[ir.VariantDecl]]) -> void:
    collect_gv_from_type(func.return_type, seen, result)
    var pi: ptr_uint = 0
    while pi < func.params.len:
        unsafe:
            collect_gv_from_type(read(func.params.data + pi).ty, seen, result)
        pi += 1
    collect_gv_from_stmts(func.body, seen, result)


function collect_gv_from_stmts(body: span[ir.Stmt], seen: ref[map_mod.Map[str, bool]], result: ref[vec.Vec[ir.VariantDecl]]) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            match read(body.data + i):
                ir.Stmt.stmt_local as loc:
                    collect_gv_from_type(loc.ty, seen, result)
                    collect_gv_from_expr(loc.value, seen, result)
                ir.Stmt.stmt_assignment as asg:
                    collect_gv_from_expr(asg.target, seen, result)
                    collect_gv_from_expr(asg.value, seen, result)
                ir.Stmt.stmt_return as ret:
                    let rv = ret.value
                    if rv != null:
                        collect_gv_from_expr(ptr[ir.Expr]<-rv, seen, result)
                ir.Stmt.stmt_expression as ex:
                    collect_gv_from_expr(ex.expression, seen, result)
                ir.Stmt.stmt_block as blk:
                    collect_gv_from_stmts(blk.body, seen, result)
                ir.Stmt.stmt_if as iff:
                    collect_gv_from_expr(iff.condition, seen, result)
                    collect_gv_from_stmts(iff.then_body, seen, result)
                    collect_gv_from_stmts(iff.else_body, seen, result)
                ir.Stmt.stmt_while as w:
                    collect_gv_from_expr(w.condition, seen, result)
                    collect_gv_from_stmts(w.body, seen, result)
                ir.Stmt.stmt_for as fr:
                    collect_gv_from_expr(fr.condition, seen, result)
                    collect_gv_from_stmts(fr.body, seen, result)
                ir.Stmt.stmt_switch as sw:
                    collect_gv_from_expr(sw.expression, seen, result)
                    var ci: ptr_uint = 0
                    while ci < sw.cases.len:
                        collect_gv_from_stmts(read(sw.cases.data + ci).body, seen, result)
                        ci += 1
                _:
                    pass
        i += 1


## Collect generic-variant instances referenced by an expression: the
## expression's own result type plus every sub-expression.  Without this,
## Option/Result instances that appear only in values (returns, call arguments,
## variant/aggregate literal fields) are never declared.
function collect_gv_from_expr(ep: ptr[ir.Expr], seen: ref[map_mod.Map[str, bool]], result: ref[vec.Vec[ir.VariantDecl]]) -> void:
    collect_gv_from_type(expr_result_type(ep), seen, result)
    unsafe:
        match read(ep):
            ir.Expr.expr_call as c:
                var i: ptr_uint = 0
                while i < c.arguments.len:
                    collect_gv_from_expr(c.arguments.data + i, seen, result)
                    i += 1
            ir.Expr.expr_call_indirect as c:
                collect_gv_from_expr(c.callee, seen, result)
                var i: ptr_uint = 0
                while i < c.arguments.len:
                    collect_gv_from_expr(c.arguments.data + i, seen, result)
                    i += 1
            ir.Expr.expr_binary as b:
                collect_gv_from_expr(b.left, seen, result)
                collect_gv_from_expr(b.right, seen, result)
            ir.Expr.expr_unary as u:
                collect_gv_from_expr(u.operand, seen, result)
            ir.Expr.expr_conditional as cd:
                collect_gv_from_expr(cd.condition, seen, result)
                collect_gv_from_expr(cd.then_expression, seen, result)
                collect_gv_from_expr(cd.else_expression, seen, result)
            ir.Expr.expr_member as m:
                collect_gv_from_expr(m.receiver, seen, result)
            ir.Expr.expr_index as ix:
                collect_gv_from_expr(ix.receiver, seen, result)
                collect_gv_from_expr(ix.index, seen, result)
            ir.Expr.expr_cast as cx:
                collect_gv_from_type(cx.target_type, seen, result)
                collect_gv_from_expr(cx.expression, seen, result)
            ir.Expr.expr_address_of as ad:
                collect_gv_from_expr(ad.expression, seen, result)
            ir.Expr.expr_aggregate_literal as agg:
                var i: ptr_uint = 0
                while i < agg.fields.len:
                    collect_gv_from_expr(read(agg.fields.data + i).value, seen, result)
                    i += 1
            ir.Expr.expr_variant_literal as vl:
                var i: ptr_uint = 0
                while i < vl.fields.len:
                    collect_gv_from_expr(read(vl.fields.data + i).value, seen, result)
                    i += 1
            ir.Expr.expr_array_literal as arr:
                var i: ptr_uint = 0
                while i < arr.elements.len:
                    collect_gv_from_expr(arr.elements.data + i, seen, result)
                    i += 1
            _:
                pass


function collect_gv_from_type(ty: types.Type, seen: ref[map_mod.Map[str, bool]], result: ref[vec.Vec[ir.VariantDecl]]) -> void:
    match ty:
        types.Type.ty_generic as g:
            # Recurse into type arguments first so nested generic variants
            # (Option[Result[...]], span[Option[X]], Option[RemovedEntry[K,V]])
            # are collected regardless of the outer constructor.
            var gi: ptr_uint = 0
            while gi < g.args.len:
                unsafe:
                    collect_gv_from_type(read(g.args.data + gi), seen, result)
                gi += 1
            # Only emit variant decls for prelude types; user-generic structs
            # are handled by the lowering's `ensure_generic_struct_decl`.
            if not g.name == "Option" and not g.name == "Result":
                return
            # Skip when type args contain raw type parameters (inside generic bodies).
            if generic_has_type_param(g.args):
                return
            let c_name = generic_c_type(g.name, g.args)
            if seen.contains(c_name):
                return
            seen.set(c_name, true)
            var arms = vec.Vec[ir.VariantArm].create()
            let info = prelude_variant_arm_info(g.name, g.args)
            var ai: ptr_uint = 0
            while ai < info.arms.len:
                var arm = unsafe: read(info.arms.data + ai)
                var fields = vec.Vec[ir.Field].create()
                var fi: ptr_uint = 0
                while fi < arm.fields.len:
                    let f = unsafe: read(arm.fields.data + fi)
                    fields.push(f)
                    fi += 1
                arms.push(ir.VariantArm(name = arm.name, linkage_name = j3(c_name, "_", arm.name), fields = fields.as_span()))
                ai += 1
            result.push(ir.VariantDecl(
                name = c_name,
                linkage_name = c_name,
                arms = arms.as_span(),
                source_module = Option[str].none,
            ))
        types.Type.ty_nullable as nl:
            collect_gv_from_type(unsafe: read(nl.base), seen, result)
        _:
            pass


## True when any type arg contains a raw type parameter (T/K/V/E/U).
function generic_has_type_param(args: span[types.Type]) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        unsafe:
            match read(args.data + i):
                types.Type.ty_var:
                    return true
                types.Type.ty_named as n:
                    if is_raw_type_param_name(n.name):
                        return true
                types.Type.ty_generic as g:
                    if generic_has_type_param(g.args):
                        return true
                types.Type.ty_nullable as nl:
                    if generic_has_type_param(sp_elem(unsafe: read(nl.base))):
                        return true
                _:
                    pass
        i += 1
    return false

function sp_elem(t: types.Type) -> span[types.Type]:
    var buf = vec.Vec[types.Type].create()
    buf.push(t)
    return buf.as_span()

## Return the arm info for a prelude variant (Option / Result).  Mirrors the
## lowering's `install_prelude_variants`.
function prelude_variant_arm_info(name: str, args: span[types.Type]) -> GVInfo:
    let default_ty = types.Type.ty_primitive(name = "int")
    let first_arg = if args.len > 0: unsafe: read(args.data + 0) else: default_ty
    let second_arg = if args.len > 1: unsafe: read(args.data + 1) else: default_ty
    var arms = vec.Vec[GVArmInfo].create()
    if name == "Option":
        var sf = vec.Vec[ir.Field].create()
        sf.push(ir.Field(name = "value", ty = first_arg))
        arms.push(GVArmInfo(name = "some", fields = sf.as_span()))
        arms.push(GVArmInfo(name = "none", fields = span[ir.Field]()))
    else if name == "Result":
        var sf = vec.Vec[ir.Field].create()
        sf.push(ir.Field(name = "value", ty = first_arg))
        var ef = vec.Vec[ir.Field].create()
        ef.push(ir.Field(name = "error", ty = second_arg))
        arms.push(GVArmInfo(name = "success", fields = sf.as_span()))
        arms.push(GVArmInfo(name = "failure", fields = ef.as_span()))
    return GVInfo(arms = arms.as_span())


function uses_string_view(functions: span[ir.Function], has_str_literals: bool) -> bool:
    if has_str_literals:
        return true
    if uses_str_equality(functions):
        return true
    var i: ptr_uint = 0
    while i < functions.len:
        unsafe:
            let f = read(functions.data + i)
            if is_str_type(f.return_type):
                return true
            var j: ptr_uint = 0
            while j < f.params.len:
                if is_str_type(read(f.params.data + j).ty):
                    return true
                j += 1
        i += 1
    return false


function uses_str_equality(functions: span[ir.Function]) -> bool:
    var i: ptr_uint = 0
    while i < functions.len:
        unsafe:
            if body_has_str_equality(read(functions.data + i).body):
                return true
        i += 1
    return false


## True when any emitted function calls `mt_fatal` (so the helper, `<stdlib.h>`,
## and the string-view type must be emitted).  Also true when str_buffer
## runtime helpers are needed (they reference mt_fatal).
function uses_fatal_helper(functions: span[ir.Function], program: ir.Program) -> bool:
    if has_str_buffer_structs(program):
        return true
    var i: ptr_uint = 0
    while i < functions.len:
        unsafe:
            if body_calls(read(functions.data + i).body, "mt_fatal"):
                return true
        i += 1
    return false


## True when any emitted function calls `mt_fatal_str` (the `str`-argument fatal
## helper), so the helper, `<stdlib.h>`, and the string-view type are emitted.
function uses_fatal_str_helper(functions: span[ir.Function]) -> bool:
    var i: ptr_uint = 0
    while i < functions.len:
        unsafe:
            if body_calls(read(functions.data + i).body, "mt_fatal_str"):
                return true
        i += 1
    return false


function body_calls(body: span[ir.Stmt], name: str) -> bool:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            if stmt_calls(body.data + i, name):
                return true
        i += 1
    return false


function stmt_calls(sp: ptr[ir.Stmt], name: str) -> bool:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_return as r:
                let value = r.value else:
                    return false
                return expr_calls(value, name)
            ir.Stmt.stmt_local as loc:
                return expr_calls(loc.value, name)
            ir.Stmt.stmt_assignment as asg:
                return expr_calls(asg.target, name) or expr_calls(asg.value, name)
            ir.Stmt.stmt_expression as ex:
                return expr_calls(ex.expression, name)
            ir.Stmt.stmt_block as blk:
                return body_calls(blk.body, name)
            ir.Stmt.stmt_if as iff:
                return expr_calls(iff.condition, name) or body_calls(iff.then_body, name) or body_calls(iff.else_body, name)
            ir.Stmt.stmt_while as w:
                return expr_calls(w.condition, name) or body_calls(w.body, name)
            ir.Stmt.stmt_for as f:
                return stmt_calls(f.init, name) or expr_calls(f.condition, name) or stmt_calls(f.post, name) or body_calls(f.body, name)
            ir.Stmt.stmt_switch as sw:
                if expr_calls(sw.expression, name):
                    return true
                var ci: ptr_uint = 0
                while ci < sw.cases.len:
                    let sc = read(sw.cases.data + ci)
                    if body_calls(sc.body, name):
                        return true
                    ci += 1
                return false
            _:
                return false


function expr_calls(ep: ptr[ir.Expr], name: str) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_call as call:
                if call.callee == name:
                    return true
                var i: ptr_uint = 0
                while i < call.arguments.len:
                    if expr_calls(call.arguments.data + i, name):
                        return true
                    i += 1
                return false
            ir.Expr.expr_call_indirect as call:
                var j: ptr_uint = 0
                while j < call.arguments.len:
                    if expr_calls(call.arguments.data + j, name):
                        return true
                    j += 1
                return false
            ir.Expr.expr_binary as bin:
                return expr_calls(bin.left, name) or expr_calls(bin.right, name)
            ir.Expr.expr_unary as un:
                return expr_calls(un.operand, name)
            ir.Expr.expr_conditional as cond:
                return expr_calls(cond.condition, name) or expr_calls(cond.then_expression, name) or expr_calls(cond.else_expression, name)
            ir.Expr.expr_member as member:
                return expr_calls(member.receiver, name)
            ir.Expr.expr_index as index:
                return expr_calls(index.receiver, name) or expr_calls(index.index, name)
            ir.Expr.expr_cast as cast:
                return expr_calls(cast.expression, name)
            ir.Expr.expr_address_of as addr:
                return expr_calls(addr.expression, name)
            ir.Expr.expr_aggregate_literal as agg:
                var i: ptr_uint = 0
                while i < agg.fields.len:
                    if expr_calls(read(agg.fields.data + i).value, name):
                        return true
                    i += 1
                return false
            _:
                return false


# =============================================================================
#  String-literal collection (mirrors c_backend collect_str_literals)
# =============================================================================

## Every unique non-cstr string-literal value in the program, sorted by byte
## length then byte value (matching Ruby's `sort_by { [bytesize, k] }`), so the
## assigned `mt_str_lit_N` indices are deterministic.
function collect_str_literals(functions: span[ir.Function]) -> vec.Vec[str]:
    var seen = map_mod.Map[str, bool].create()
    var collected = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < functions.len:
        unsafe:
            collect_from_stmts(read(functions.data + i).body, ref_of(seen), ref_of(collected))
        i += 1
    var it = collected.iter()
    it.sort_by(str_literal_order)
    return collected


function str_literal_order(a: ptr[str], b: ptr[str]) -> int:
    unsafe:
        let la = read(a).len
        let lb = read(b).len
        if la < lb:
            return -1
        if la > lb:
            return 1
        return read(a).compare(read(b))


function collect_from_stmts(body: span[ir.Stmt], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[str]]) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            collect_from_stmt(body.data + i, seen, collected)
        i += 1


function collect_from_stmt(sp: ptr[ir.Stmt], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_return as r:
                let value = r.value else:
                    return
                collect_from_expr(value, seen, collected)
            ir.Stmt.stmt_local as loc:
                collect_from_expr(loc.value, seen, collected)
            ir.Stmt.stmt_assignment as asg:
                collect_from_expr(asg.target, seen, collected)
                collect_from_expr(asg.value, seen, collected)
            ir.Stmt.stmt_expression as ex:
                collect_from_expr(ex.expression, seen, collected)
            ir.Stmt.stmt_block as blk:
                collect_from_stmts(blk.body, seen, collected)
            ir.Stmt.stmt_if as iff:
                collect_from_expr(iff.condition, seen, collected)
                collect_from_stmts(iff.then_body, seen, collected)
                collect_from_stmts(iff.else_body, seen, collected)
            ir.Stmt.stmt_while as w:
                collect_from_expr(w.condition, seen, collected)
                collect_from_stmts(w.body, seen, collected)
            ir.Stmt.stmt_for as f:
                collect_from_stmt(f.init, seen, collected)
                collect_from_expr(f.condition, seen, collected)
                collect_from_stmt(f.post, seen, collected)
                collect_from_stmts(f.body, seen, collected)
            ir.Stmt.stmt_switch as sw:
                collect_from_expr(sw.expression, seen, collected)
                var ci: ptr_uint = 0
                while ci < sw.cases.len:
                    let sc = read(sw.cases.data + ci)
                    collect_from_stmts(sc.body, seen, collected)
                    ci += 1
            _:
                pass


function collect_from_expr(ep: ptr[ir.Expr], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[str]]) -> void:
    unsafe:
        match read(ep):
            ir.Expr.expr_string_literal as lit:
                if not lit.cstring:
                    if not seen.contains(lit.value):
                        seen.set(lit.value, true)
                        collected.push(lit.value)
            ir.Expr.expr_binary as bin:
                collect_from_expr(bin.left, seen, collected)
                collect_from_expr(bin.right, seen, collected)
            ir.Expr.expr_unary as un:
                collect_from_expr(un.operand, seen, collected)
            ir.Expr.expr_call as call:
                var i: ptr_uint = 0
                while i < call.arguments.len:
                    collect_from_expr(call.arguments.data + i, seen, collected)
                    i += 1
            ir.Expr.expr_call_indirect as call:
                var i: ptr_uint = 0
                while i < call.arguments.len:
                    collect_from_expr(call.arguments.data + i, seen, collected)
                    i += 1
            ir.Expr.expr_conditional as cond:
                collect_from_expr(cond.condition, seen, collected)
                collect_from_expr(cond.then_expression, seen, collected)
                collect_from_expr(cond.else_expression, seen, collected)
            ir.Expr.expr_cast as cast:
                collect_from_expr(cast.expression, seen, collected)
            ir.Expr.expr_address_of as addr:
                collect_from_expr(addr.expression, seen, collected)
            ir.Expr.expr_member as member:
                collect_from_expr(member.receiver, seen, collected)
            ir.Expr.expr_index as index:
                collect_from_expr(index.receiver, seen, collected)
                collect_from_expr(index.index, seen, collected)
            _:
                pass


function body_has_str_equality(body: span[ir.Stmt]) -> bool:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            if stmt_has_str_equality(body.data + i):
                return true
        i += 1
    return false


function stmt_has_str_equality(sp: ptr[ir.Stmt]) -> bool:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_return as r:
                let value = r.value else:
                    return false
                return expr_has_str_equality(value)
            ir.Stmt.stmt_local as loc:
                return expr_has_str_equality(loc.value)
            ir.Stmt.stmt_assignment as asg:
                return expr_has_str_equality(asg.target) or expr_has_str_equality(asg.value)
            ir.Stmt.stmt_expression as ex:
                return expr_has_str_equality(ex.expression)
            ir.Stmt.stmt_block as blk:
                return body_has_str_equality(blk.body)
            ir.Stmt.stmt_if as iff:
                return expr_has_str_equality(iff.condition) or body_has_str_equality(iff.then_body) or body_has_str_equality(iff.else_body)
            ir.Stmt.stmt_while as w:
                return expr_has_str_equality(w.condition) or body_has_str_equality(w.body)
            ir.Stmt.stmt_for as f:
                return expr_has_str_equality(f.condition) or body_has_str_equality(f.body)
            ir.Stmt.stmt_switch as sw:
                if expr_has_str_equality(sw.expression):
                    return true
                var ci: ptr_uint = 0
                while ci < sw.cases.len:
                    let sc = read(sw.cases.data + ci)
                    if body_has_str_equality(sc.body):
                        return true
                    ci += 1
                return false
            _:
                return false


function expr_has_str_equality(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_binary as bin:
                if is_str_equality(bin.operator, bin.left, bin.right):
                    return true
                return expr_has_str_equality(bin.left) or expr_has_str_equality(bin.right)
            ir.Expr.expr_unary as un:
                return expr_has_str_equality(un.operand)
            ir.Expr.expr_call as call:
                var i: ptr_uint = 0
                while i < call.arguments.len:
                    if expr_has_str_equality(call.arguments.data + i):
                        return true
                    i += 1
                return false
            ir.Expr.expr_call_indirect as call:
                var i: ptr_uint = 0
                while i < call.arguments.len:
                    if expr_has_str_equality(call.arguments.data + i):
                        return true
                    i += 1
                return false
            ir.Expr.expr_conditional as cond:
                return expr_has_str_equality(cond.condition) or expr_has_str_equality(cond.then_expression) or expr_has_str_equality(cond.else_expression)
            _:
                return false


# =============================================================================
#  Type mapping (mirrors c_backend/type_system.rb)
# =============================================================================

function c_type(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return primitive_c_type(p.name)
        types.Type.ty_str:
            return "mt_str"
        types.Type.ty_dyn as d:
            return j3("mt_dyn_", d.iface, "")
        types.Type.ty_function:
            # Function types are declarators: `ret_type (*)(param_types)`.
            return c_fn_ptr_declarator(t, "")
        types.Type.ty_imported as im:
            # Types from `std.c.*` raw-ABI modules use their bare C name (the
            # `struct X = c"X"` alias / raw external name), never a module prefix,
            # so they match the C header declarations (mirrors Ruby's
            # `named_type_c_name` std.c. special case).
            if im.module_name.starts_with("std.c."):
                return im.name
            return naming.qualified_c_name(im.module_name, im.name)
        types.Type.ty_named as n:
            if n.module_name.len > 0:
                return naming.qualified_c_name(n.module_name, n.name)
            return n.name
        types.Type.ty_var as v:
            # Unresolved type parameter — should have been substituted during
            # monomorphization.  Emit the raw name; if it reaches C it will
            # produce a compiler error rather than a Milk Tea crash.
            return v.name
        types.Type.ty_generic as g:
            return generic_c_type(g.name, g.args)
        types.Type.ty_tuple:
            return tuple_type_name(t)
        types.Type.ty_type_meta:
            return "void"
        types.Type.ty_error:
            return "void"
        types.Type.ty_nullable as nl:
            unsafe:
                let base = read(nl.base)
                if is_pointer_like_for_nullable(base):
                    return c_type(base)
                return j2("mt_opt_", naming.type_c_key(base))
        _:
            fatal(j2("c_backend: unsupported C type: ", types.type_to_string(t)))


## The C type name of a tuple (`(int, int)` -> `mt_tuple_int_int`,
## named `(x: int, y: int)` -> `mt_tuple_int_int_x_y`).
function tuple_type_name(t: types.Type) -> str:
    var buf = string.String.create()
    buf.append("mt_tuple")
    match t:
        types.Type.ty_tuple as tup:
            var i: ptr_uint = 0
            while i < tup.elements.len:
                buf.append("_")
                unsafe:
                    buf.append(naming.type_c_key(read(tup.elements.data + i)))
                i += 1
            match tup.field_names:
                Option.some as names:
                    var ni: ptr_uint = 0
                    while ni < names.value.len:
                        buf.append("_")
                        unsafe:
                            buf.append(read(names.value.data + ni))
                        ni += 1
                Option.none:
                    pass
        _:
            pass
    return buf.as_str()


## C type for a generic instance: span -> mt_span_ELEM, ptr/const_ptr/ref ->
## pointer.  Arrays are declarators (handled by c_declaration), not plain types.
function generic_c_type(name: str, args: span[types.Type]) -> str:
    if name == "span" and args.len == 1:
        return span_type_name(unsafe: read(args.data + 0))
    if name == "ptr" and args.len == 1:
        let inner = unsafe: read(args.data + 0)
        match inner:
            types.Type.ty_function:
                return c_type(inner)
            _:
                pass
        return j2(c_type(inner), "*")
    if name == "const_ptr" and args.len == 1:
        let inner = unsafe: read(args.data + 0)
        match inner:
            types.Type.ty_function:
                return c_type(inner)
            _:
                pass
        return j3("const ", c_type(inner), "*")
    if name == "own" and args.len == 1:
        let inner = unsafe: read(args.data + 0)
        match inner:
            types.Type.ty_function:
                return c_type(inner)
            _:
                pass
        return j2(c_type(inner), "*")
    if name == "ref" and args.len >= 1:
        let inner = unsafe: read(args.data + (args.len - 1))
        match inner:
            types.Type.ty_function:
                return c_type(inner)
            _:
                pass
        return j2(c_type(inner), "*")
    # str_buffer[N] → mt_str_buffer_N
    if name == "str_buffer" and args.len >= 1:
        return j3("mt_str_buffer_", naming.type_c_key(unsafe: read(args.data + 0)), "")
    # atomic[T] → _Atomic <c_type(T)>
    if name == "atomic" and args.len == 1:
        return j3("_Atomic ", c_type(unsafe: read(args.data + 0)), "")
    # Task[T] → mt_task_<T>
    if name == "Task" and args.len == 1:
        return j3("mt_task_", naming.type_c_key(unsafe: read(args.data + 0)), "")
    # SoA[T, N] → mt_soa_<T>_N
    if name == "SoA" and args.len >= 2:
        let elem_name = c_type(unsafe: read(args.data + 0))
        let count_str = naming.type_c_key(unsafe: read(args.data + 1))
        return j4("mt_soa_", elem_name, "_", count_str)
    # array[T, N] in type position (e.g. sizeof) → <elem>[<N>]
    if name == "array" and args.len >= 2:
        return j3(c_type(unsafe: read(args.data + 0)), "[", j2(naming.type_c_key(unsafe: read(args.data + 1)), "]"))
    # Generic variant: `<name>_<type0>_<type1>_...`.  The caller module prefix
    # is added by `qualified_c_name` when the type is `ty_imported`.
    # Prelude types (Option, Result) carry the prefix in their raw name from the
    # lowering (line 2008-2013), but `ty_generic` strips it.  Add it back here.
    if args.len > 0:
        var buf = string.String.create()
        if name == "Option":
            buf.append("std_option_")
        else if name == "Result":
            buf.append("std_result_")
        buf.append(name)
        var i: ptr_uint = 0
        while i < args.len:
            buf.append("_")
            unsafe:
                buf.append(naming.type_c_key(read(args.data + i)))
            i += 1
        return buf.as_str()
    fatal(c"c_backend: unsupported generic C type")


function span_type_name(element: types.Type) -> str:
    return j2("mt_span_", naming.type_c_key(element))


# =============================================================================
#  Span type collection + emission
# =============================================================================

## Distinct span types used across the emitted functions (params, returns, and
## local declarations), deduplicated by span type name.
function collect_variant_span_types(program: ir.Program, collected: ref[vec.Vec[types.Type]]) -> void:
    var seen = map_mod.Map[str, bool].create()
    var ci: ptr_uint = 0
    while ci < collected.len():
        let ty_ptr = collected.get(ci) else:
            break
        unsafe:
            seen.set(span_type_name(array_element_type(read(ty_ptr))), true)
        ci += 1
    var i: ptr_uint = 0
    while i < program.variants.len:
        unsafe:
            let vd = read(program.variants.data + i)
            var ai: ptr_uint = 0
            while ai < vd.arms.len:
                let arm = read(vd.arms.data + ai)
                var fi: ptr_uint = 0
                while fi < arm.fields.len:
                    maybe_add_span(read(arm.fields.data + fi).ty, ref_of(seen), collected)
                    fi += 1
                ai += 1
        i += 1


function collect_struct_span_types(program: ir.Program, collected: ref[vec.Vec[types.Type]]) -> void:
    var seen = map_mod.Map[str, bool].create()
    # Seed seen with already-collected types.
    var ci: ptr_uint = 0
    while ci < collected.len():
        let ty_ptr = collected.get(ci) else:
            break
        unsafe:
            seen.set(span_type_name(array_element_type(read(ty_ptr))), true)
        ci += 1
    var i: ptr_uint = 0
    while i < program.structs.len:
        unsafe:
            let s = read(program.structs.data + i)
            var fi: ptr_uint = 0
            while fi < s.fields.len:
                maybe_add_span(read(s.fields.data + fi).ty, ref_of(seen), collected)
                fi += 1
        i += 1


function collect_span_types(functions: span[ir.Function]) -> vec.Vec[types.Type]:
    var seen = map_mod.Map[str, bool].create()
    var collected = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < functions.len:
        unsafe:
            let f = read(functions.data + i)
            maybe_add_span(f.return_type, ref_of(seen), ref_of(collected))
            var j: ptr_uint = 0
            while j < f.params.len:
                maybe_add_span(read(f.params.data + j).ty, ref_of(seen), ref_of(collected))
                j += 1
            span_from_stmts(f.body, ref_of(seen), ref_of(collected))
        i += 1
    return collected


function maybe_add_span(t: types.Type, seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[types.Type]]) -> void:
    if not is_span_type(t):
        return
    let elem = array_element_type(t)
    if types.is_error(elem):
        return
    match elem:
        types.Type.ty_var:
            return
        types.Type.ty_named as n:
            if is_raw_type_param_name(n.name):
                return
        _:
            pass
    let name = span_type_name(elem)
    if not seen.contains(name):
        seen.set(name, true)
        collected.push(t)

## True when `name` is a single-letter type parameter used in generic bodies.
function is_raw_type_param_name(name: str) -> bool:
    return name == "T" or name == "U" or name == "K" or name == "V" or name == "E"


function span_from_stmts(body: span[ir.Stmt], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[types.Type]]) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            span_from_stmt(body.data + i, seen, collected)
        i += 1


function span_from_stmt(sp: ptr[ir.Stmt], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[types.Type]]) -> void:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_local as loc:
                maybe_add_span(loc.ty, seen, collected)
            ir.Stmt.stmt_block as blk:
                span_from_stmts(blk.body, seen, collected)
            ir.Stmt.stmt_if as iff:
                span_from_stmts(iff.then_body, seen, collected)
                span_from_stmts(iff.else_body, seen, collected)
            ir.Stmt.stmt_while as w:
                span_from_stmts(w.body, seen, collected)
            ir.Stmt.stmt_for as f:
                span_from_stmt(f.init, seen, collected)
                span_from_stmts(f.body, seen, collected)
            ir.Stmt.stmt_switch as sw:
                var ci: ptr_uint = 0
                while ci < sw.cases.len:
                    span_from_stmts(read(sw.cases.data + ci).body, seen, collected)
                    ci += 1
            _:
                pass


function emit_span_type(e: ref[Emitter], t: types.Type) -> void:
    let element = array_element_type(t)
    let name = span_type_name(element)
    emit_line(e, j3("typedef struct ", name, " {"))
    emit_line(e, j3("  ", c_type(element), " *data;"))
    emit_line(e, "  uintptr_t len;")
    emit_line(e, j3("} ", name, ";"))


# =============================================================================
#  Tuple type collection + emission
# =============================================================================

function is_tuple_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_tuple:
            return true
        _:
            return false


## Distinct tuple types across the emitted functions (params, returns, locals).
function collect_tuple_types(functions: span[ir.Function]) -> vec.Vec[types.Type]:
    var seen = map_mod.Map[str, bool].create()
    var collected = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < functions.len:
        unsafe:
            let f = read(functions.data + i)
            maybe_add_tuple(f.return_type, ref_of(seen), ref_of(collected))
            var j: ptr_uint = 0
            while j < f.params.len:
                maybe_add_tuple(read(f.params.data + j).ty, ref_of(seen), ref_of(collected))
                j += 1
            tuple_from_stmts(f.body, ref_of(seen), ref_of(collected))
        i += 1
    return collected


function maybe_add_tuple(t: types.Type, seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[types.Type]]) -> void:
    if not is_tuple_type(t):
        return
    let name = tuple_type_name(t)
    if not seen.contains(name):
        seen.set(name, true)
        collected.push(t)


function tuple_from_stmts(body: span[ir.Stmt], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[types.Type]]) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            tuple_from_stmt(body.data + i, seen, collected)
        i += 1


function tuple_from_stmt(sp: ptr[ir.Stmt], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[types.Type]]) -> void:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_local as loc:
                maybe_add_tuple(loc.ty, seen, collected)
            ir.Stmt.stmt_block as blk:
                tuple_from_stmts(blk.body, seen, collected)
            ir.Stmt.stmt_if as iff:
                tuple_from_stmts(iff.then_body, seen, collected)
                tuple_from_stmts(iff.else_body, seen, collected)
            ir.Stmt.stmt_while as w:
                tuple_from_stmts(w.body, seen, collected)
            ir.Stmt.stmt_for as f:
                tuple_from_stmt(f.init, seen, collected)
                tuple_from_stmts(f.body, seen, collected)
            ir.Stmt.stmt_switch as sw:
                var ci: ptr_uint = 0
                while ci < sw.cases.len:
                    tuple_from_stmts(read(sw.cases.data + ci).body, seen, collected)
                    ci += 1
            _:
                pass


function emit_tuple_type_forward(e: ref[Emitter], t: types.Type) -> void:
    let name = tuple_type_name(t)
    emit_line(e, j3("typedef struct ", name, j2(" ", j2(name, ";"))))


function emit_tuple_type_def(e: ref[Emitter], t: types.Type) -> void:
    let name = tuple_type_name(t)
    emit_line(e, j3("struct ", name, " {"))
    match t:
        types.Type.ty_tuple as tup:
            var i: ptr_uint = 0
            while i < tup.elements.len:
                var fname = tuple_field_name(i)
                match tup.field_names:
                    Option.some as names:
                        if i < names.value.len:
                            unsafe:
                                fname = read(names.value.data + i)
                    Option.none:
                        pass
                unsafe:
                    emit_line(e, j4("  ", c_declaration(read(tup.elements.data + i), fname), ";", ""))
                i += 1
        _:
            pass
    emit_line(e, "};")


function tuple_field_name(index: ptr_uint) -> str:
    return j2("_", ptr_uint_to_str(index))


## True when an array local has a brace-initializable value (array literal or
## zero-init); other array values (e.g. copying another array) need `memcpy`.
function array_direct_initializer(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_array_literal:
                return true
            ir.Expr.expr_zero_init:
                return true
            _:
                return false


function is_array_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name == "array" and g.args.len == 2
        _:
            return false


function is_span_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name == "span" and g.args.len == 1
        _:
            return false


function array_element_type(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_generic as g:
            unsafe:
                return read(g.args.data + 0)
        _:
            return types.Type.ty_error


function array_length(t: types.Type) -> long:
    match t:
        types.Type.ty_generic as g:
            unsafe:
                match read(g.args.data + 1):
                    types.Type.ty_literal_int as lit:
                        return lit.value
                    _:
                        return 0
        _:
            return 0


function is_str_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_str:
            return true
        _:
            return false


## The C name of a module-qualified named type is `naming.qualified_c_name`.





function primitive_c_type(name: str) -> str:
    if name == "bool":
        return "bool"
    if name == "byte":
        return "int8_t"
    if name == "ubyte":
        return "uint8_t"
    if name == "char":
        return "char"
    if name == "short":
        return "int16_t"
    if name == "ushort":
        return "uint16_t"
    if name == "int":
        return "int32_t"
    if name == "uint":
        return "uint32_t"
    if name == "long":
        return "int64_t"
    if name == "ulong":
        return "uint64_t"
    if name == "ptr_int":
        return "intptr_t"
    if name == "ptr_uint":
        return "uintptr_t"
    if name == "float":
        return "float"
    if name == "double":
        return "double"
    if name == "void":
        return "void"
    if name == "cstr":
        return "const char*"
    if name == "vec2" or name == "ivec2":
        return j2("mt_", name)
    if name == "vec3" or name == "ivec3":
        return j2("mt_", name)
    if name == "vec4" or name == "ivec4":
        return j2("mt_", name)
    if name == "mat3" or name == "mat4":
        return j2("mt_", name)
    if name == "quat":
        return j2("mt_", name)
    fatal(c"c_backend: unsupported primitive type")


## Render a function-pointer declarator: `ret_type (*noname)(int32_t, int32_t)` or
## `ret_type (*name)(int32_t, int32_t)`.  When `name` is empty, produces the
## "type only" form used by `c_type`; otherwise produces the full declaration.
function c_fn_ptr_declarator(t: types.Type, name: str) -> str:
    match t:
        types.Type.ty_function as fnt:
            var buf = string.String.create()
            unsafe:
                buf.append(c_type(read(fnt.return_type)))
            if name.len == 0:
                buf.append(" (*)(")
            else:
                buf.append(" (*")
                buf.append(name)
                buf.append(")(")
            var i: ptr_uint = 0
            while i < fnt.params.len:
                if i > 0:
                    buf.append(", ")
                unsafe:
                    buf.append(c_type(read(fnt.params.data + i)))
                i += 1
            if fnt.variadic:
                if fnt.params.len > 0:
                    buf.append(", ")
                buf.append("...")
            if fnt.params.len == 0 and not fnt.variadic:
                buf.append("void")
            buf.append(")")
            return buf.as_str()
        _:
            fatal(c"c_backend: c_fn_ptr_declarator called on non-function type")


## A C declaration `TYPE NAME`.  Array types place the length after the name
## (`int32_t xs[3]`); everything else in Phase 3 is a plain `TYPE NAME`.
function c_declaration(t: types.Type, name: str) -> str:
    if is_array_type(t):
        let inner_name = if name.len > 0 and name.byte_at(0) == '*': j3("(", name, ")") else: name
        return j6(c_type(array_element_type(t)), " ", inner_name, "[", long_to_str(array_length(t)), "]")
    # Function-pointer types need declarator syntax: `ret_type (*name)(...)`.
    # Pointer/reference types: `T*` instead of `ptr_T`.
    # Generic variants: build `name_type0_type1_...` directly.
    match t:
        types.Type.ty_function:
            return c_fn_ptr_declarator(t, name)
        types.Type.ty_generic as g:
            if (g.name == "ptr" or g.name == "own" or g.name == "ref") and g.args.len >= 1:
                let inner = unsafe: read(g.args.data + (g.args.len - 1))
                if is_array_type(inner):
                    return c_declaration(inner, j2("*", name))
                let base = unsafe: c_type(inner)
                return j3(base, " *", name)
            if g.name == "const_ptr" and g.args.len == 1:
                let inner = unsafe: read(g.args.data + 0)
                if is_array_type(inner):
                    return c_declaration(inner, j2("*", name))
                let base = unsafe: c_type(inner)
                return j4("const ", base, "*", name)
            if g.name == "str_buffer" and g.args.len >= 1:
                let c_name = j3("mt_str_buffer_", naming.type_c_key(unsafe: read(g.args.data + 0)), "")
                return j3(c_name, " ", name)
            return j3(generic_c_type(g.name, g.args), " ", name)
        _:
            pass
    return j3(c_type(t), " ", name)


# =============================================================================
#  Enum emission (mirrors c_backend/type_declaration.rb emit_enum)
# =============================================================================

function emit_enums_block(e: ref[Emitter], program: ir.Program) -> void:
    var i: ptr_uint = 0
    while i < program.enums.len:
        unsafe:
            emit_enum(e, read(program.enums.data + i))
        emit_line(e, "")
        i += 1


function emit_enum(e: ref[Emitter], enum_decl: ir.EnumDecl) -> void:
    emit_line(e, j4("typedef ", c_type(enum_decl.backing_type), " ", j2(enum_decl.linkage_name, ";")))
    if enum_decl.members.len == 0:
        return
    emit_line(e, "enum {")
    var i: ptr_uint = 0
    while i < enum_decl.members.len:
        unsafe:
            let m = read(enum_decl.members.data + i)
            let suffix = if i == enum_decl.members.len - 1: "" else: ","
            emit_line(e, j6("  ", m.linkage_name, " = ", render_expression(e, m.value), suffix, ""))
        i += 1
    emit_line(e, "};")


# =============================================================================
#  Struct emission (mirrors c_backend/type_declaration.rb emit_struct)
# =============================================================================

function emit_struct(e: ref[Emitter], s: ir.StructDecl) -> void:
    emit_line(e, j3("struct ", s.linkage_name, " {"))
    var i: ptr_uint = 0
    while i < s.fields.len:
        unsafe:
            let f = read(s.fields.data + i)
            # Skip void-typed fields — C does not allow fields of type void
            # (e.g. `void result;` in WorkState[void] from async runtime).
            if not is_void_type(f.ty):
                emit_line(e, j4("  ", c_declaration(f.ty, f.name), ";", ""))
        i += 1
    emit_line(e, "};")


function emit_union(e: ref[Emitter], u: ir.UnionDecl) -> void:
    emit_line(e, j3("union ", u.linkage_name, " {"))
    var i: ptr_uint = 0
    while i < u.fields.len:
        unsafe:
            let f = read(u.fields.data + i)
            emit_line(e, j4("  ", c_declaration(f.ty, f.name), ";", ""))
        i += 1
    emit_line(e, "};")


## Emit SoA (Structure-of-Arrays) struct definitions for every SoA type used in
## the program.  Each SoA struct has an array member per field of the element
## struct, e.g. `mt_soa_Point_4 { float x[4]; float y[4]; float z[4]; }`.
function emit_soa_types(e: ref[Emitter], funcs: span[ir.Function], program: ir.Program) -> void:
    var seen = map_mod.Map[str, bool].create()
    # Collect SoA types from function signatures, local types, and struct fields.
    var fi: ptr_uint = 0
    while fi < funcs.len:
        unsafe:
            collect_soa_from_function(e, read(funcs.data + fi), ref_of(seen), program)
        fi += 1
    # Also check struct fields and variants for SoA types.
    var svi: ptr_uint = 0
    while svi < program.structs.len:
        unsafe:
            let s = read(program.structs.data + svi)
            var sfi: ptr_uint = 0
            while sfi < s.fields.len:
                collect_soa_from_type(e, read(s.fields.data + sfi).ty, ref_of(seen), program)
                sfi += 1
        svi += 1


## Emit a single SoA struct definition.
function emit_one_soa(e: ref[Emitter], elem_struct_name: str, count_str: str, structs: span[ir.StructDecl]) -> void:
    let soa_name = j4("mt_soa_", elem_struct_name, "_", count_str)
    emit_line(e, j3("typedef struct ", soa_name, " {"))
    var svi: ptr_uint = 0
    while svi < structs.len:
        unsafe:
            let s = read(structs.data + svi)
            if s.linkage_name == elem_struct_name:
                var sfi: ptr_uint = 0
                while sfi < s.fields.len:
                    let f = read(s.fields.data + sfi)
                    var decl_buf = string.String.create()
                    decl_buf.append("  ")
                    decl_buf.append(c_type(f.ty))
                    decl_buf.append(" ")
                    decl_buf.append(f.name)
                    decl_buf.append("[")
                    decl_buf.append(count_str)
                    decl_buf.append("];")
                    emit_line(e, decl_buf.as_str())
                    sfi += 1
        svi += 1
    emit_line(e, j3("} ", soa_name, ";"))
    emit_line(e, "")


## Register an SoA type if it hasn't been emitted yet, keyed by its C name.
function register_soa(e: ref[Emitter], elem_c_name: str, count_str: str, seen: ref[map_mod.Map[str, bool]]) -> bool:
    let key = j3(elem_c_name, "_", count_str)
    if seen.contains(key):
        return false
    seen.set(key, true)
    return true


## Walk a function's IR and register every SoA type found.
function collect_soa_from_function(e: ref[Emitter], func: ir.Function, seen: ref[map_mod.Map[str, bool]], program: ir.Program) -> void:
    collect_soa_from_type(e, func.return_type, seen, program)
    var pi: ptr_uint = 0
    while pi < func.params.len:
        unsafe:
            collect_soa_from_type(e, read(func.params.data + pi).ty, seen, program)
        pi += 1
    collect_soa_from_stmts(e, func.body, seen, program)


## Walk statements looking for SoA types (local decls, assignments, returns).
function collect_soa_from_stmts(e: ref[Emitter], body: span[ir.Stmt], seen: ref[map_mod.Map[str, bool]], program: ir.Program) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            match read(body.data + i):
                ir.Stmt.stmt_local as loc:
                    collect_soa_from_type(e, loc.ty, seen, program)
                ir.Stmt.stmt_assignment as a:
                    collect_soa_from_type(e, expr_result_type(a.target), seen, program)
                ir.Stmt.stmt_return as r:
                    let v = r.value else:
                        i += 1
                        continue
                    collect_soa_from_type(e, expr_result_type(v), seen, program)
                ir.Stmt.stmt_if as ifs:
                    collect_soa_from_stmts(e, ifs.then_body, seen, program)
                    if ifs.else_body.len > 0:
                        collect_soa_from_stmts(e, ifs.else_body, seen, program)
                ir.Stmt.stmt_while as w:
                    collect_soa_from_stmts(e, w.body, seen, program)
                ir.Stmt.stmt_for as fs:
                    collect_soa_from_stmts(e, fs.body, seen, program)
                _:
                    pass
        i += 1


## Register an SoA type from a types.Type if it is `ty_generic(name="SoA", ...)`.
function collect_soa_from_type(e: ref[Emitter], ty: types.Type, seen: ref[map_mod.Map[str, bool]], program: ir.Program) -> void:
    match ty:
        types.Type.ty_generic as g:
            if g.name == "SoA" and g.args.len >= 2:
                let elem_ty = unsafe: read(g.args.data + 0)
                let count_ty = unsafe: read(g.args.data + 1)
                let elem_c_name = soa_element_c_name(elem_ty)
                let count_str = naming.type_c_key(count_ty)
                if elem_c_name.len > 0 and register_soa(e, elem_c_name, count_str, seen):
                    emit_one_soa(e, elem_c_name, count_str, program.structs)
            # Recurse into child types
            if g.args.len > 0:
                var ai: ptr_uint = 0
                while ai < g.args.len:
                    collect_soa_from_type(e, unsafe: read(g.args.data + ai), seen, program)
                    ai += 1
        types.Type.ty_named:
            pass
        _:
            pass


## The C struct name for the element type of an SoA.  For a named struct like
## `Point`, the element type resolves to its qualified C name.
function soa_element_c_name(ty: types.Type) -> str:
    match ty:
        types.Type.ty_named as n:
            if n.module_name.len > 0:
                return naming.qualified_c_name(n.module_name, n.name)
            return n.name
        types.Type.ty_imported as im:
            return naming.qualified_c_name(im.module_name, im.name)
        _:
            return c_type(ty)


## True when any arm of a variant carries payload fields (so a `__data` union and
## a `.data` member are needed).
function variant_has_payload(vd: ir.VariantDecl) -> bool:
    var i: ptr_uint = 0
    while i < vd.arms.len:
        unsafe:
            if read(vd.arms.data + i).fields.len > 0:
                return true
        i += 1
    return false


## Forward typedefs for a variant: the outer tagged struct plus one per payload
## arm (no-payload arms have no payload struct).  Mirrors emit_forward_declarations.
function emit_variant_forward(e: ref[Emitter], vd: ir.VariantDecl) -> void:
    emit_line(e, j3("typedef struct ", vd.linkage_name, j2(" ", j2(vd.linkage_name, ";"))))
    var i: ptr_uint = 0
    while i < vd.arms.len:
        unsafe:
            let arm = read(vd.arms.data + i)
            if arm.fields.len > 0:
                emit_line(e, j3("typedef struct ", arm.linkage_name, j2(" ", j2(arm.linkage_name, ";"))))
        i += 1


## Emit a variant type: per-arm payload structs, the `_kind` discriminant enum,
## the `__data` union, and the outer tagged struct.  Mirrors Ruby's emit_variant.
## Append a trailing underscore to C keywords used as field/member names so
## the generated code compiles (e.g. `sizeof` → `sizeof_`, `switch` → `switch_`).
function c_safe_field_name(name: str) -> str:
    if (
        name == "sizeof" or name == "switch" or name == "union" or name == "struct" or name == "enum"
        or name == "register" or name == "volatile" or name == "const" or name == "restrict"
        or name == "auto" or name == "extern" or name == "static" or name == "typedef"
        or name == "int" or name == "float" or name == "double" or name == "char"
        or name == "short" or name == "long" or name == "void" or name == "bool"
        or name == "default" or name == "case" or name == "break" or name == "continue"
        or name == "return" or name == "if" or name == "else" or name == "while"
        or name == "for" or name == "do" or name == "goto"
    ):
        return j2(name, "_")
    return name


function emit_variant(e: ref[Emitter], vd: ir.VariantDecl) -> void:
    let outer_c = vd.linkage_name

    # Per-arm payload structs
    var i: ptr_uint = 0
    while i < vd.arms.len:
        unsafe:
            let arm = read(vd.arms.data + i)
            if arm.fields.len > 0:
                emit_line(e, j3("struct ", arm.linkage_name, " {"))
                var fi: ptr_uint = 0
                while fi < arm.fields.len:
                    let f = read(arm.fields.data + fi)
                    if not is_void_type(f.ty):
                        if c_type(f.ty) == outer_c:
                            emit_line(e, j4("  ", c_declaration(f.ty, j2("*", f.name)), ";", ""))
                        else:
                            emit_line(e, j4("  ", c_declaration(f.ty, f.name), ";", ""))
                    fi += 1
                emit_line(e, "};")
                emit_line(e, j3("typedef struct ", arm.linkage_name, j2(" ", j2(arm.linkage_name, ";"))))
        i += 1

    # Kind enum
    emit_line(e, j3("typedef int32_t ", outer_c, "_kind;"))
    if vd.arms.len > 0:
        emit_line(e, "enum {")
        i = 0
        while i < vd.arms.len:
            unsafe:
                let arm = read(vd.arms.data + i)
                let suffix = if i == vd.arms.len - 1: "" else: ","
                emit_line(e, j6("  ", outer_c, "_kind_", arm.name, j3(" = ", ptr_uint_to_str(i), suffix), ""))
            i += 1
        emit_line(e, "};")

    # Data union (only if at least one arm has payload)
    if variant_has_payload(vd):
        emit_line(e, j3("union ", outer_c, "__data {"))
        i = 0
        while i < vd.arms.len:
            unsafe:
                let arm = read(vd.arms.data + i)
                if arm.fields.len > 0:
                    emit_line(e, j6("  struct ", arm.linkage_name, " ", c_safe_field_name(arm.name), ";", ""))
            i += 1
        emit_line(e, "};")

    # Outer tagged struct
    emit_line(e, j3("struct ", outer_c, " {"))
    emit_line(e, j3("  ", outer_c, "_kind kind;"))
    if variant_has_payload(vd):
        emit_line(e, j3("  union ", outer_c, "__data data;"))
    emit_line(e, "};")


## Order struct definitions so a struct that embeds another (by value) is emitted
## after its dependency.  Depth-first post-order over struct-typed fields.
function topo_sort_structs(structs: span[ir.StructDecl]) -> vec.Vec[ir.StructDecl]:
    var by_linkage = map_mod.Map[str, ptr_uint].create()
    var i: ptr_uint = 0
    while i < structs.len:
        unsafe:
            by_linkage.set(read(structs.data + i).linkage_name, i)
        i += 1
    var visited = map_mod.Map[str, bool].create()
    var result = vec.Vec[ir.StructDecl].create()
    i = 0
    while i < structs.len:
        topo_visit_struct(structs, i, ref_of(by_linkage), ref_of(visited), ref_of(result))
        i += 1
    return result


function topo_visit_struct(structs: span[ir.StructDecl], index: ptr_uint, by_linkage: ref[map_mod.Map[str, ptr_uint]], visited: ref[map_mod.Map[str, bool]], result: ref[vec.Vec[ir.StructDecl]]) -> void:
    var s: ir.StructDecl
    unsafe:
        s = read(structs.data + index)
    if visited.contains(s.linkage_name):
        return
    visited.set(s.linkage_name, true)
    var i: ptr_uint = 0
    while i < s.fields.len:
        unsafe:
            let f = read(s.fields.data + i)
            match struct_field_linkage(f.ty):
                Option.some as dep:
                    let dep_idx = by_linkage.get(dep.value)
                    if dep_idx != null:
                        topo_visit_struct(structs, read(dep_idx), by_linkage, visited, result)
                Option.none:
                    pass
        i += 1
    result.push(s)


function struct_field_linkage(ty: types.Type) -> Option[str]:
    match ty:
        types.Type.ty_imported as im:
            return Option[str].some(value = naming.qualified_c_name(im.module_name, im.name))
        _:
            return Option[str].none


# =============================================================================
#  Combined struct + variant topological ordering
#
#  A struct may embed a variant by value (e.g. `ir.Field { ty: Type }`) and a
#  variant arm may embed a struct by value (e.g. `Option[String]`), so their C
#  full definitions must be emitted in a single dependency order rather than
#  structs-then-variants or vice versa.  Pointer / ref / span fields need only a
#  forward declaration and so are not dependencies; array and value-nullable
#  fields embed their element by value and are.
# =============================================================================

## One aggregate type to emit: `kind` 0 = struct, 1 = generic variant,
## 2 = program variant; `index` selects it within its source collection.
struct TypeNode:
    key: str
    kind: ubyte
    index: ptr_uint


## The C name of the aggregate type a field embeds by value, or none for
## pointer-like fields (which need only a forward declaration).
function by_value_dep_key(ty: types.Type) -> Option[str]:
    match ty:
        types.Type.ty_named as n:
            return Option[str].some(value = n.name)
        types.Type.ty_imported as im:
            if im.args.len == 0:
                return Option[str].some(value = naming.qualified_c_name(im.module_name, im.name))
            return Option[str].none
        types.Type.ty_nullable as nl:
            unsafe:
                let base = read(nl.base)
                if is_pointer_like_for_nullable(base):
                    return Option[str].none
                return Option[str].some(value = j2("mt_opt_", naming.type_c_key(base)))
        types.Type.ty_generic as g:
            if g.name == "array" and g.args.len >= 1:
                return by_value_dep_key(unsafe: read(g.args.data + 0))
            # Pointer-like generics need only a forward declaration, not a
            # by-value dependency.
            if (
                g.name == "ptr" or g.name == "const_ptr" or g.name == "own" or g.name == "ref"
                or g.name == "span" or g.name == "str_buffer" or g.name == "atomic"
                or g.name == "Task" or g.name == "SoA"
            ):
                return Option[str].none
            # A generic variant instance embedded by value (e.g.
            # `Option[span[str]]` → `Option_span_str`): it depends on the concrete
            # instance's full definition being ordered first.  Uses the same name
            # `generic_c_type` emits so the topo edge matches the emitted type.
            if g.args.len > 0:
                return Option[str].some(value = generic_c_type(g.name, g.args))
            return Option[str].none
        _:
            return Option[str].none


function collect_field_deps(fields: span[ir.Field], deps: ref[vec.Vec[str]]) -> void:
    var i: ptr_uint = 0
    while i < fields.len:
        unsafe:
            match by_value_dep_key(read(fields.data + i).ty):
                Option.some as dep:
                    deps.push(dep.value)
                Option.none:
                    pass
        i += 1


function collect_variant_deps(vd: ir.VariantDecl, deps: ref[vec.Vec[str]]) -> void:
    var i: ptr_uint = 0
    while i < vd.arms.len:
        unsafe:
            collect_field_deps(read(vd.arms.data + i).fields, deps)
        i += 1


function type_node_deps(node: TypeNode, structs: span[ir.StructDecl], gen_variants: ref[vec.Vec[ir.VariantDecl]], program_variants: span[ir.VariantDecl], opt_structs: ref[vec.Vec[OptStructEntry]]) -> vec.Vec[str]:
    var deps = vec.Vec[str].create()
    if node.kind == 0:
        unsafe:
            collect_field_deps(read(structs.data + node.index).fields, ref_of(deps))
    else if node.kind == 1:
        let gv_ptr = gen_variants.get(node.index) else:
            return deps
        collect_variant_deps(unsafe: read(gv_ptr), ref_of(deps))
    else if node.kind == 2:
        unsafe:
            collect_variant_deps(read(program_variants.data + node.index), ref_of(deps))
    else if node.kind == 3:
        let opt_ptr = opt_structs.get(node.index) else:
            return deps
        unsafe:
            collect_field_deps(read(opt_ptr).decl.fields, ref_of(deps))
    return deps


function topo_sort_types(structs: span[ir.StructDecl], gen_variants: ref[vec.Vec[ir.VariantDecl]], program_variants: span[ir.VariantDecl], opt_structs: ref[vec.Vec[OptStructEntry]]) -> vec.Vec[TypeNode]:
    var nodes = vec.Vec[TypeNode].create()
    var by_key = map_mod.Map[str, ptr_uint].create()
    var i: ptr_uint = 0
    while i < structs.len:
        let key = unsafe: read(structs.data + i).linkage_name
        by_key.set(key, nodes.len())
        nodes.push(TypeNode(key = key, kind = 0, index = i))
        i += 1
    i = 0
    while i < gen_variants.len():
        let gv_ptr = gen_variants.get(i) else:
            break
        let key = unsafe: read(gv_ptr).linkage_name
        by_key.set(key, nodes.len())
        nodes.push(TypeNode(key = key, kind = 1, index = i))
        i += 1
    i = 0
    while i < program_variants.len:
        let key = unsafe: read(program_variants.data + i).linkage_name
        by_key.set(key, nodes.len())
        nodes.push(TypeNode(key = key, kind = 2, index = i))
        i += 1
    i = 0
    while i < opt_structs.len():
        let os_ptr = opt_structs.get(i) else:
            break
        let key = unsafe: read(os_ptr).decl.linkage_name
        by_key.set(key, nodes.len())
        nodes.push(TypeNode(key = key, kind = 3, index = i))
        i += 1

    var visited = map_mod.Map[str, bool].create()
    var result = vec.Vec[TypeNode].create()
    i = 0
    while i < nodes.len():
        topo_visit_type(ref_of(nodes), i, structs, gen_variants, program_variants, opt_structs, ref_of(by_key), ref_of(visited), ref_of(result))
        i += 1
    return result


function topo_visit_type(nodes: ref[vec.Vec[TypeNode]], index: ptr_uint, structs: span[ir.StructDecl], gen_variants: ref[vec.Vec[ir.VariantDecl]], program_variants: span[ir.VariantDecl], opt_structs: ref[vec.Vec[OptStructEntry]], by_key: ref[map_mod.Map[str, ptr_uint]], visited: ref[map_mod.Map[str, bool]], result: ref[vec.Vec[TypeNode]]) -> void:
    var node: TypeNode
    let node_ptr = nodes.get(index) else:
        return
    unsafe:
        node = read(node_ptr)
    if visited.contains(node.key):
        return
    visited.set(node.key, true)
    var deps = type_node_deps(node, structs, gen_variants, program_variants, opt_structs)
    var di: ptr_uint = 0
    while di < deps.len():
        let dep_ptr = deps.get(di) else:
            break
        unsafe:
            let dep_idx = by_key.get(read(dep_ptr))
            if dep_idx != null:
                topo_visit_type(nodes, read(dep_idx), structs, gen_variants, program_variants, opt_structs, by_key, visited, result)
        di += 1
    result.push(node)

function function_signature(func: ir.Function) -> str:
    let prefix = if func.entry_point: "" else: "static "
    var buf = string.String.create()
    buf.append(prefix)
    buf.append(c_type(func.return_type))
    buf.append(" ")
    buf.append(func.linkage_name)
    buf.append("(")
    buf.append(function_params(func))
    buf.append(")")
    return buf.as_str()


function function_params(func: ir.Function) -> str:
    if func.params.len == 0:
        return "void"
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < func.params.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            let p = read(func.params.data + i)
            buf.append(c_declaration(p.ty, p.linkage_name))
        i += 1
    return buf.as_str()


function emit_function(e: ref[Emitter], func: ir.Function) -> void:
    e.used_labels.clear()
    collect_used_labels(func.body, ref_of(e.used_labels))
    emit_line(e, j2(function_signature(func), " {"))
    emit_stmts(e, func.body, 1)
    emit_line(e, "}")


## Collect every label targeted by a `goto` anywhere in a statement body, so an
## emitted `stmt_label` that no `goto` references can be skipped.  Mirrors Ruby's
## collect_used_labels.
function collect_used_labels(body: span[ir.Stmt], labels: ref[map_mod.Map[str, bool]]) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            match read(body.data + i):
                ir.Stmt.stmt_goto as g:
                    labels.set(g.label, true)
                ir.Stmt.stmt_block as blk:
                    collect_used_labels(blk.body, labels)
                ir.Stmt.stmt_if as iff:
                    collect_used_labels(iff.then_body, labels)
                    collect_used_labels(iff.else_body, labels)
                ir.Stmt.stmt_while as w:
                    collect_used_labels(w.body, labels)
                ir.Stmt.stmt_for as fr:
                    collect_used_labels(fr.body, labels)
                ir.Stmt.stmt_switch as sw:
                    var ci: ptr_uint = 0
                    while ci < sw.cases.len:
                        collect_used_labels(read(sw.cases.data + ci).body, labels)
                        ci += 1
                _:
                    pass
        i += 1


# =============================================================================
#  Statement emission (mirrors c_backend/statements.rb)
# =============================================================================

function emit_stmts(e: ref[Emitter], body: span[ir.Stmt], level: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            emit_statement(e, body.data + i, level)
        i += 1


function emit_statement(e: ref[Emitter], sp: ptr[ir.Stmt], level: ptr_uint) -> void:
    let indent = indent_c(level)
    unsafe:
        match read(sp):
            ir.Stmt.stmt_return as r:
                let value = r.value else:
                    emit_line(e, j2(indent, "return;"))
                    return
                emit_line(e, j4(indent, "return ", render_expression(e, value), ";"))
            ir.Stmt.stmt_local as loc:
                if is_array_type(loc.ty) and not array_direct_initializer(loc.value):
                    emit_line(e, j3(indent, c_declaration(loc.ty, loc.linkage_name), ";"))
                    emit_line(e, j6(indent, "memcpy(", loc.linkage_name, ", ", render_expression(e, loc.value), j3(", sizeof(", loc.linkage_name, "));")))
                else:
                    emit_line(e, j5(indent, c_declaration(loc.ty, loc.linkage_name), " = ", render_initializer(e, loc.value), ";"))
            ir.Stmt.stmt_assignment as asg:
                emit_line(e, j6(indent, render_expression(e, asg.target), " ", asg.operator, " ", j2(render_expression(e, asg.value), ";")))
            ir.Stmt.stmt_expression as ex:
                emit_line(e, j3(indent, render_expression(e, ex.expression), ";"))
            ir.Stmt.stmt_block as blk:
                if block_requires_scope(blk.body):
                    emit_line(e, j2(indent, "{"))
                    emit_stmts(e, blk.body, level + 1)
                    emit_line(e, j2(indent, "}"))
                else:
                    emit_stmts(e, blk.body, level)
            ir.Stmt.stmt_if as iff:
                emit_if(e, iff.condition, iff.then_body, iff.else_body, level)
            ir.Stmt.stmt_while as w:
                emit_line(e, j4(indent, "while (", render_expression(e, w.condition), ") {"))
                emit_stmts(e, w.body, level + 1)
                emit_line(e, j2(indent, "}"))
            ir.Stmt.stmt_for as f:
                var header = string.String.create()
                header.append(indent)
                header.append("for (")
                header.append(render_for_clause(e, f.init))
                header.append("; ")
                header.append(render_expression(e, f.condition))
                header.append("; ")
                header.append(render_for_clause(e, f.post))
                header.append(") {")
                emit_line(e, header.as_str())
                emit_stmts(e, f.body, level + 1)
                emit_line(e, j2(indent, "}"))
            ir.Stmt.stmt_switch as sw:
                emit_switch(e, sw.expression, sw.cases, sw.exhaustive, level)
            ir.Stmt.stmt_goto as g:
                emit_line(e, j4(indent, "goto ", g.label, ";"))
            ir.Stmt.stmt_label as lbl:
                if e.used_labels.contains(lbl.name):
                    emit_line(e, j3(indent, lbl.name, ":;"))
            ir.Stmt.stmt_break:
                emit_line(e, j2(indent, "break;"))
            ir.Stmt.stmt_continue:
                emit_line(e, j2(indent, "continue;"))
            _:
                fatal(c"c_backend: unsupported statement")


## Emit a `switch`.  Non-default cases are `case VALUE: { body [break;] }`; a `_`
## arm is `default: { body [break;] }`; and an exhaustive switch with no explicit
## default gets `default: __builtin_unreachable();`.  Mirrors the switch path in
## c_backend/statements.rb.
function emit_switch(e: ref[Emitter], expression: ptr[ir.Expr], cases: span[ir.SwitchCase], exhaustive: bool, level: ptr_uint) -> void:
    let indent = indent_c(level)
    let case_indent = indent_c(level + 1)
    emit_line(e, j4(indent, "switch (", render_expression(e, expression), ") {"))
    var has_default = false
    var i: ptr_uint = 0
    while i < cases.len:
        unsafe:
            let sc = read(cases.data + i)
            if sc.is_default:
                has_default = true
                emit_line(e, j2(case_indent, "default: {"))
            else:
                let value = sc.value else:
                    fatal(c"c_backend: non-default switch case missing value")
                emit_line(e, j4(case_indent, "case ", render_expression(e, value), ": {"))
            emit_stmts(e, sc.body, level + 2)
            if not body_terminates(sc.body):
                emit_line(e, j2(indent_c(level + 2), "break;"))
            emit_line(e, j2(case_indent, "}"))
        i += 1
    if exhaustive and not has_default:
        emit_line(e, j2(case_indent, "default: __builtin_unreachable();"))
    emit_line(e, j2(indent, "}"))


## True when a statement sequence always transfers control (mirrors
## control_flow_emission.rb body_terminates? / statement_terminates?).
function body_terminates(body: span[ir.Stmt]) -> bool:
    if body.len == 0:
        return false
    unsafe:
        return statement_terminates(body.data + (body.len - 1))


function statement_terminates(sp: ptr[ir.Stmt]) -> bool:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_return:
                return true
            ir.Stmt.stmt_break:
                return true
            ir.Stmt.stmt_continue:
                return true
            ir.Stmt.stmt_goto:
                return true
            ir.Stmt.stmt_block as blk:
                return body_terminates(blk.body)
            ir.Stmt.stmt_if as iff:
                if iff.else_body.len == 0:
                    return false
                return body_terminates(iff.then_body) and body_terminates(iff.else_body)
            _:
                return false


## True when a block introduces a local declaration and therefore needs its own
## C scope (`{ ... }`) — mirrors c_backend/statements.rb block_requires_scope?.
function block_requires_scope(body: span[ir.Stmt]) -> bool:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            match read(body.data + i):
                ir.Stmt.stmt_local:
                    return true
                _:
                    pass
        i += 1
    return false


## Emit an `if` and its else chain, re-flattening a single-`if` else body back
## into `else if` (mirrors control_flow_emission.rb emit_if_statement).
function emit_if(e: ref[Emitter], condition: ptr[ir.Expr], then_body: span[ir.Stmt], else_body: span[ir.Stmt], level: ptr_uint) -> void:
    let indent = indent_c(level)
    emit_line(e, j4(indent, "if (", render_expression(e, condition), ") {"))
    emit_stmts(e, then_body, level + 1)
    emit_else(e, else_body, level)


function emit_else(e: ref[Emitter], else_body: span[ir.Stmt], level: ptr_uint) -> void:
    let indent = indent_c(level)
    if else_body.len == 1:
        unsafe:
            match read(else_body.data + 0):
                ir.Stmt.stmt_if as nested:
                    emit_line(e, j4(indent, "} else if (", render_expression(e, nested.condition), ") {"))
                    emit_stmts(e, nested.then_body, level + 1)
                    emit_else(e, nested.else_body, level)
                    return
                _:
                    pass
    if else_body.len > 0:
        emit_line(e, j2(indent, "} else {"))
        emit_stmts(e, else_body, level + 1)
        emit_line(e, j2(indent, "}"))
    else:
        emit_line(e, j2(indent, "}"))


## Render a `for` init/post clause (no indent, no trailing `;`) — mirrors
## c_backend/statements.rb emit_for_clause_statement.
function render_for_clause(e: ref[Emitter], sp: ptr[ir.Stmt]) -> str:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_local as loc:
                return j5(c_declaration(loc.ty, loc.linkage_name), " = ", render_initializer(e, loc.value), "", "")
            ir.Stmt.stmt_assignment as asg:
                return j5(render_expression(e, asg.target), " ", asg.operator, " ", render_expression(e, asg.value))
            ir.Stmt.stmt_expression as ex:
                return render_expression(e, ex.expression)
            _:
                fatal(c"c_backend: unsupported for-loop clause")


# =============================================================================
#  Expression emission (mirrors c_backend/expressions.rb)
# =============================================================================

function render_expression(e: ref[Emitter], ep: ptr[ir.Expr]) -> str:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as n:
                return n.name
            ir.Expr.expr_integer_literal as lit:
                return long_to_str(lit.value)
            ir.Expr.expr_float_literal as lit:
                return double_to_str(lit.value)
            ir.Expr.expr_boolean_literal as b:
                return if b.value: "true" else: "false"
            ir.Expr.expr_string_literal as s:
                return render_string_literal(e, s.value, s.cstring)
            ir.Expr.expr_unary as un:
                if un.operator == "not":
                    return j2("!", wrap_expression(e, un.operand))
                return j2(un.operator, wrap_expression(e, un.operand))
            ir.Expr.expr_binary as bin:
                if is_str_equality(bin.operator, bin.left, bin.right):
                    let call = j5("mt_str_equal(", render_expression(e, bin.left), ", ", render_expression(e, bin.right), ")")
                    if bin.operator == "!=":
                        return j2("!", call)
                    return call
                if is_variant_equality(bin.operator, bin.left, bin.right, e):
                    return render_variant_equality(e, bin.operator, bin.left, bin.right)
                if is_nullable_null_comparison(bin.operator, bin.left, bin.right):
                    return render_nullable_null_comparison(e, bin.operator, bin.left, bin.right)
                return render_binary(e, bin.operator, bin.left, bin.right)
            ir.Expr.expr_call as call:
                return render_call(e, call.callee, call.arguments)
            ir.Expr.expr_call_indirect as call:
                return render_indirect_call(e, call.callee, call.arguments)
            ir.Expr.expr_member as member:
                # Enum/flags member access on a type name (lowered as
                # `expr_name(Module.Type, ty=ty_type_meta)` with subsequent
                # `.MemberValue` access).  In C, enum values are bare constants
                # (e.g. `UV_TIMER`); emit just the member name.
                unsafe:
                    match read(member.receiver):
                        ir.Expr.expr_name as n:
                            match n.ty:
                                types.Type.ty_type_meta:
                                    return member.member
                                _:
                                    pass
                        _:
                            pass
                let operator = if pointer_member_receiver(member.receiver): "->" else: "."
                return j3(wrap_member_receiver(e, member.receiver), operator, member.member)
            ir.Expr.expr_aggregate_literal as agg:
                return render_aggregate_literal(e, agg.ty, agg.fields)
            ir.Expr.expr_variant_literal as vl:
                return j4("(", c_type(vl.ty), ")", render_variant_initializer(e, vl.ty, vl.arm_name, vl.fields, true))
            ir.Expr.expr_zero_init as z:
                return render_zero_expression(z.ty)
            ir.Expr.expr_null_literal as nl:
                if is_value_nullable(nl.ty):
                    return j3("(", c_type(nl.ty), "){0}")
                return "NULL"
            ir.Expr.expr_cast as cast:
                # A cast whose target C type equals its operand's C type is a
                # no-op: emit the bare operand (mirrors Ruby's no_op_cast?).
                if no_op_cast(cast.expression, cast.target_type):
                    return render_expression(e, cast.expression)
                var cast_buf = string.String.create()
                cast_buf.append("(")
                cast_buf.append(c_type(cast.target_type))
                cast_buf.append(") ")
                cast_buf.append(emit_cast_operand(e, cast.expression))
                return cast_buf.as_str()
            ir.Expr.expr_checked_index as ci:
                return j5("(*", checked_array_index_helper_name(ci.receiver_type), "(", render_address_of_operand(e, ci.receiver), j3(", ", render_expression(e, ci.index), "))"))
            ir.Expr.expr_checked_span_index as cs:
                return j5("(*", checked_span_index_helper_name(cs.receiver_type), "(", render_expression(e, cs.receiver), j3(", ", render_expression(e, cs.index), "))"))
            ir.Expr.expr_index as ix:
                return j4(wrap_member_receiver(e, ix.receiver), "[", render_expression(e, ix.index), "]")
            ir.Expr.expr_address_of as addr:
                return render_address_of(e, addr.expression)
            ir.Expr.expr_sizeof as sz:
                var buf = string.String.create()
                buf.append("sizeof(")
                buf.append(c_type(sz.target_type))
                buf.append(")")
                return buf.as_str()
            ir.Expr.expr_alignof as al:
                var buf = string.String.create()
                buf.append("_Alignof(")
                buf.append(c_type(al.target_type))
                buf.append(")")
                return buf.as_str()
            ir.Expr.expr_offsetof as off:
                return j5("offsetof(", c_type(off.target_type), ", ", off.field, ")")
            ir.Expr.expr_array_literal as arr:
                return render_array_literal_initializer(e, arr.elements)
            ir.Expr.expr_conditional as cond:
                return j5(emit_conditional_condition(e, cond.condition), " ? ", render_expression(e, cond.then_expression), " : ", render_expression(e, cond.else_expression))
            _:
                fatal(c"c_backend: unsupported expression")


## The address of an operand for a `&`-style position.  A checked array index is
## the pointer the helper already returns (no extra `*`/`&`); other operands are
## `&expr`.
function render_address_of(e: ref[Emitter], ep: ptr[ir.Expr]) -> str:
    unsafe:
        match read(ep):
            ir.Expr.expr_checked_index as ci:
                return j4(checked_array_index_helper_name(ci.receiver_type), "(", render_address_of_operand(e, ci.receiver), j3(", ", render_expression(e, ci.index), ")"))
            _:
                return render_address_of_operand(e, ep)


function render_address_of_operand(e: ref[Emitter], ep: ptr[ir.Expr]) -> str:
    return j2("&", wrap_member_receiver(e, ep))


function checked_array_index_helper_name(receiver_type: types.Type) -> str:
    var buf = string.String.create()
    buf.append("mt_checked_index_array_")
    buf.append(naming.type_c_key(array_element_type(receiver_type)))
    buf.append("_")
    buf.append(long_to_str(array_length(receiver_type)))
    return buf.as_str()


function checked_span_index_helper_name(receiver_type: types.Type) -> str:
    return j2("mt_checked_span_index_", naming.type_c_key(receiver_type))


# =============================================================================
#  Checked-index helper generation
# =============================================================================

## Distinct array-index receiver types used across the emitted functions
## (deduplicated by helper name), one per generated bounds-checked accessor.
function collect_checked_index_types(functions: span[ir.Function]) -> vec.Vec[types.Type]:
    var seen = map_mod.Map[str, bool].create()
    var collected = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < functions.len:
        unsafe:
            checked_from_stmts(read(functions.data + i).body, ref_of(seen), ref_of(collected))
        i += 1
    return collected


function checked_from_stmts(body: span[ir.Stmt], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[types.Type]]) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            checked_from_stmt(body.data + i, seen, collected)
        i += 1


function checked_from_stmt(sp: ptr[ir.Stmt], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[types.Type]]) -> void:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_return as r:
                let value = r.value else:
                    return
                checked_from_expr(value, seen, collected)
            ir.Stmt.stmt_local as loc:
                checked_from_expr(loc.value, seen, collected)
            ir.Stmt.stmt_assignment as asg:
                checked_from_expr(asg.target, seen, collected)
                checked_from_expr(asg.value, seen, collected)
            ir.Stmt.stmt_expression as ex:
                checked_from_expr(ex.expression, seen, collected)
            ir.Stmt.stmt_block as blk:
                checked_from_stmts(blk.body, seen, collected)
            ir.Stmt.stmt_if as iff:
                checked_from_expr(iff.condition, seen, collected)
                checked_from_stmts(iff.then_body, seen, collected)
                checked_from_stmts(iff.else_body, seen, collected)
            ir.Stmt.stmt_while as w:
                checked_from_expr(w.condition, seen, collected)
                checked_from_stmts(w.body, seen, collected)
            ir.Stmt.stmt_for as f:
                checked_from_stmt(f.init, seen, collected)
                checked_from_expr(f.condition, seen, collected)
                checked_from_stmt(f.post, seen, collected)
                checked_from_stmts(f.body, seen, collected)
            ir.Stmt.stmt_switch as sw:
                checked_from_expr(sw.expression, seen, collected)
                var ci: ptr_uint = 0
                while ci < sw.cases.len:
                    checked_from_stmts(read(sw.cases.data + ci).body, seen, collected)
                    ci += 1
            _:
                pass


function checked_from_expr(ep: ptr[ir.Expr], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[types.Type]]) -> void:
    unsafe:
        match read(ep):
            ir.Expr.expr_checked_index as ci:
                let name = checked_array_index_helper_name(ci.receiver_type)
                if not seen.contains(name):
                    seen.set(name, true)
                    collected.push(ci.receiver_type)
                checked_from_expr(ci.receiver, seen, collected)
                checked_from_expr(ci.index, seen, collected)
            ir.Expr.expr_index as ix:
                checked_from_expr(ix.receiver, seen, collected)
                checked_from_expr(ix.index, seen, collected)
            ir.Expr.expr_binary as bin:
                checked_from_expr(bin.left, seen, collected)
                checked_from_expr(bin.right, seen, collected)
            ir.Expr.expr_unary as un:
                checked_from_expr(un.operand, seen, collected)
            ir.Expr.expr_conditional as cond:
                checked_from_expr(cond.condition, seen, collected)
                checked_from_expr(cond.then_expression, seen, collected)
                checked_from_expr(cond.else_expression, seen, collected)
            ir.Expr.expr_call as call:
                var i: ptr_uint = 0
                while i < call.arguments.len:
                    checked_from_expr(call.arguments.data + i, seen, collected)
                    i += 1
            ir.Expr.expr_call_indirect as call:
                var i: ptr_uint = 0
                while i < call.arguments.len:
                    checked_from_expr(call.arguments.data + i, seen, collected)
                    i += 1
            ir.Expr.expr_member as member:
                checked_from_expr(member.receiver, seen, collected)
            ir.Expr.expr_address_of as addr:
                checked_from_expr(addr.expression, seen, collected)
            ir.Expr.expr_cast as cast:
                checked_from_expr(cast.expression, seen, collected)
            ir.Expr.expr_reinterpret as rin:
                checked_from_expr(rin.expression, seen, collected)
            ir.Expr.expr_nullable_index as ni:
                checked_from_expr(ni.receiver, seen, collected)
                checked_from_expr(ni.index, seen, collected)
            ir.Expr.expr_nullable_span_index as ns:
                checked_from_expr(ns.receiver, seen, collected)
                checked_from_expr(ns.index, seen, collected)
            ir.Expr.expr_array_literal as arr:
                var ai: ptr_uint = 0
                while ai < arr.elements.len:
                    checked_from_expr(arr.elements.data + ai, seen, collected)
                    ai += 1
            ir.Expr.expr_variant_literal as vl:
                var vi: ptr_uint = 0
                while vi < vl.fields.len:
                    checked_from_expr(read(vl.fields.data + vi).value, seen, collected)
                    vi += 1
            ir.Expr.expr_aggregate_literal as agg:
                var i: ptr_uint = 0
                while i < agg.fields.len:
                    checked_from_expr(read(agg.fields.data + i).value, seen, collected)
                    i += 1
            _:
                pass


function emit_checked_index_helper(e: ref[Emitter], receiver_type: types.Type) -> void:
    let elem_c = c_type(array_element_type(receiver_type))
    let n = long_to_str(array_length(receiver_type))
    let name = checked_array_index_helper_name(receiver_type)
    var sig = string.String.create()
    sig.append("static inline ")
    sig.append(elem_c)
    sig.append(" *")
    sig.append(name)
    sig.append("(")
    sig.append(elem_c)
    sig.append(" (*array)[")
    sig.append(n)
    sig.append("], uintptr_t index) {")
    emit_line(e, sig.as_str())
    emit_line(e, j4("  if (index >= ", n, ") mt_fatal(\"array index out of bounds\");", ""))
    emit_line(e, "  return &(*array)[index];")
    emit_line(e, "}")


## Distinct span-index receiver types across the emitted functions.
function collect_checked_span_index_types(functions: span[ir.Function]) -> vec.Vec[types.Type]:
    var seen = map_mod.Map[str, bool].create()
    var collected = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < functions.len:
        unsafe:
            span_index_from_stmts(read(functions.data + i).body, ref_of(seen), ref_of(collected))
        i += 1
    return collected


function span_index_from_stmts(body: span[ir.Stmt], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[types.Type]]) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            span_index_from_stmt(body.data + i, seen, collected)
        i += 1


function span_index_from_stmt(sp: ptr[ir.Stmt], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[types.Type]]) -> void:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_return as r:
                let value = r.value else:
                    return
                span_index_from_expr(value, seen, collected)
            ir.Stmt.stmt_local as loc:
                span_index_from_expr(loc.value, seen, collected)
            ir.Stmt.stmt_assignment as asg:
                span_index_from_expr(asg.target, seen, collected)
                span_index_from_expr(asg.value, seen, collected)
            ir.Stmt.stmt_expression as ex:
                span_index_from_expr(ex.expression, seen, collected)
            ir.Stmt.stmt_block as blk:
                span_index_from_stmts(blk.body, seen, collected)
            ir.Stmt.stmt_if as iff:
                span_index_from_expr(iff.condition, seen, collected)
                span_index_from_stmts(iff.then_body, seen, collected)
                span_index_from_stmts(iff.else_body, seen, collected)
            ir.Stmt.stmt_while as w:
                span_index_from_expr(w.condition, seen, collected)
                span_index_from_stmts(w.body, seen, collected)
            ir.Stmt.stmt_for as f:
                span_index_from_stmt(f.init, seen, collected)
                span_index_from_expr(f.condition, seen, collected)
                span_index_from_stmt(f.post, seen, collected)
                span_index_from_stmts(f.body, seen, collected)
            ir.Stmt.stmt_switch as sw:
                span_index_from_expr(sw.expression, seen, collected)
                var ci: ptr_uint = 0
                while ci < sw.cases.len:
                    span_index_from_stmts(read(sw.cases.data + ci).body, seen, collected)
                    ci += 1
            _:
                pass


function span_index_from_expr(ep: ptr[ir.Expr], seen: ref[map_mod.Map[str, bool]], collected: ref[vec.Vec[types.Type]]) -> void:
    unsafe:
        match read(ep):
            ir.Expr.expr_checked_span_index as cs:
                let name = checked_span_index_helper_name(cs.receiver_type)
                if not seen.contains(name):
                    seen.set(name, true)
                    collected.push(cs.receiver_type)
                span_index_from_expr(cs.receiver, seen, collected)
                span_index_from_expr(cs.index, seen, collected)
            ir.Expr.expr_checked_index as ci:
                span_index_from_expr(ci.receiver, seen, collected)
                span_index_from_expr(ci.index, seen, collected)
            ir.Expr.expr_index as ix:
                span_index_from_expr(ix.receiver, seen, collected)
                span_index_from_expr(ix.index, seen, collected)
            ir.Expr.expr_binary as bin:
                span_index_from_expr(bin.left, seen, collected)
                span_index_from_expr(bin.right, seen, collected)
            ir.Expr.expr_unary as un:
                span_index_from_expr(un.operand, seen, collected)
            ir.Expr.expr_conditional as cond:
                span_index_from_expr(cond.condition, seen, collected)
                span_index_from_expr(cond.then_expression, seen, collected)
                span_index_from_expr(cond.else_expression, seen, collected)
            ir.Expr.expr_call as call:
                var i: ptr_uint = 0
                while i < call.arguments.len:
                    span_index_from_expr(call.arguments.data + i, seen, collected)
                    i += 1
            ir.Expr.expr_call_indirect as call:
                var i: ptr_uint = 0
                while i < call.arguments.len:
                    span_index_from_expr(call.arguments.data + i, seen, collected)
                    i += 1
            ir.Expr.expr_member as member:
                span_index_from_expr(member.receiver, seen, collected)
            ir.Expr.expr_address_of as addr:
                span_index_from_expr(addr.expression, seen, collected)
            ir.Expr.expr_cast as cast:
                span_index_from_expr(cast.expression, seen, collected)
            ir.Expr.expr_reinterpret as rin:
                span_index_from_expr(rin.expression, seen, collected)
            ir.Expr.expr_nullable_index as ni:
                span_index_from_expr(ni.receiver, seen, collected)
                span_index_from_expr(ni.index, seen, collected)
            ir.Expr.expr_nullable_span_index as ns:
                span_index_from_expr(ns.receiver, seen, collected)
                span_index_from_expr(ns.index, seen, collected)
            ir.Expr.expr_array_literal as arr:
                var ai: ptr_uint = 0
                while ai < arr.elements.len:
                    span_index_from_expr(arr.elements.data + ai, seen, collected)
                    ai += 1
            ir.Expr.expr_variant_literal as vl:
                var vi: ptr_uint = 0
                while vi < vl.fields.len:
                    span_index_from_expr(read(vl.fields.data + vi).value, seen, collected)
                    vi += 1
            ir.Expr.expr_aggregate_literal as agg:
                var i: ptr_uint = 0
                while i < agg.fields.len:
                    span_index_from_expr(read(agg.fields.data + i).value, seen, collected)
                    i += 1
            _:
                pass


function emit_checked_span_index_helper(e: ref[Emitter], receiver_type: types.Type) -> void:
    let elem_c = c_type(array_element_type(receiver_type))
    let span_c = c_type(receiver_type)
    let name = checked_span_index_helper_name(receiver_type)
    var sig = string.String.create()
    sig.append("static inline ")
    sig.append(elem_c)
    sig.append(" *")
    sig.append(name)
    sig.append("(")
    sig.append(span_c)
    sig.append(" span, uintptr_t index) {")
    emit_line(e, sig.as_str())
    emit_line(e, "  if (index >= span.len) mt_fatal(\"span index out of bounds\");")
    emit_line(e, "  return &span.data[index];")
    emit_line(e, "}")


## The initializer form of a value (aggregate literals use `{ ... }` without a
## compound-literal cast); everything else is an ordinary expression.  Mirrors
## c_backend/expressions.rb render_initializer.
function render_initializer(e: ref[Emitter], ep: ptr[ir.Expr]) -> str:
    unsafe:
        match read(ep):
            ir.Expr.expr_aggregate_literal as agg:
                return render_aggregate_initializer(e, agg.fields)
            ir.Expr.expr_array_literal as arr:
                return render_array_literal_initializer(e, arr.elements)
            ir.Expr.expr_variant_literal as vl:
                return render_variant_initializer(e, vl.ty, vl.arm_name, vl.fields, false)
            ir.Expr.expr_zero_init as z:
                return render_zero_initializer(z.ty)
            _:
                return render_expression(e, ep)


## Render a variant literal in initializer position:
##   `{ .kind = <outer_c>_kind_<arm>, .data.<arm> = { .f = v, ... } }` (payload)
##   `{ .kind = <outer_c>_kind_<arm> }`                                (no payload)
## In expression context the payload aggregate is a compound literal
## `(struct <arm_c>){ ... }`, matching how a variant literal is used as a value.
function render_variant_initializer(e: ref[Emitter], ty: types.Type, arm_name: str, fields: span[ir.AggregateField], as_expression: bool) -> str:
    # Resolve the outer C type name directly: `ty_generic` builds `<name>_<type0>_...`,
    # `ty_imported` uses `qualified_c_name`, everything else delegates to `c_type`.
    var outer_c: str
    match ty:
        types.Type.ty_generic as g:
            var buf = string.String.create()
            if g.name == "Option":
                buf.append("std_option_")
            else if g.name == "Result":
                buf.append("std_result_")
            buf.append(g.name)
            var i: ptr_uint = 0
            while i < g.args.len:
                buf.append("_")
                unsafe:
                    buf.append(naming.type_c_key(read(g.args.data + i)))
                i += 1
            outer_c = buf.as_str()
        types.Type.ty_imported as im:
            outer_c = naming.qualified_c_name(im.module_name, im.name)
        _:
            outer_c = c_type(ty)

    var buf = string.String.create()
    buf.append("{ .kind = ")
    buf.append(outer_c)
    buf.append("_kind_")
    buf.append(arm_name)
    if fields.len > 0:
        buf.append(", .data.")
        buf.append(arm_name)
        buf.append(" = ")
        if as_expression:
            buf.append("(struct ")
            buf.append(outer_c)
            buf.append("_")
            buf.append(arm_name)
            buf.append(")")
        buf.append(render_aggregate_initializer(e, fields))
    buf.append(" }")
    return buf.as_str()


## The zero value of a type in initializer position (mirrors
## c_backend/expressions.rb render_zero_initializer).
function render_zero_initializer(t: types.Type) -> str:
    match t:
        types.Type.ty_str:
            return "{ 0 }"
        types.Type.ty_primitive as p:
            if p.name == "bool":
                return "false"
            if p.name == "float" or p.name == "double":
                return "0.0"
            if p.name == "void":
                return "{ 0 }"
            if is_vec_math_name(p.name):
                return "{ 0 }"
            return "0"
        _:
            return "{ 0 }"


## The zero value of a type in expression position.
function render_zero_expression(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive:
            return render_zero_initializer(t)
        types.Type.ty_str:
            return j4("(", c_type(t), ")", " { 0 }")
        _:
            return j4("(", c_declaration(t, ""), ") ", render_zero_initializer(t))


function render_aggregate_initializer(e: ref[Emitter], fields: span[ir.AggregateField]) -> str:
    var buf = string.String.create()
    buf.append("{ ")
    # Detect positional fields (auto-generated names like _0, _1, ...) and render
    # without the `.name = ` prefix so they work as array/tuple initializers.
    let is_positional = fields.len > 0 and unsafe: read(fields.data + 0).name.starts_with("_")
    var i: ptr_uint = 0
    while i < fields.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            let f = read(fields.data + i)
            if not is_positional:
                buf.append(".")
                buf.append(f.name)
                buf.append(" = ")
            buf.append(render_initializer(e, f.value))
        i += 1
    buf.append(" }")
    return buf.as_str()


function render_aggregate_literal(e: ref[Emitter], ty: types.Type, fields: span[ir.AggregateField]) -> str:
    return j4("(", c_type(ty), ")", render_aggregate_initializer(e, fields))


## Render an array literal in initializer position: `{ e0, e1, ... }`.  An empty
## array literal degenerates to `{ 0 }`.  Mirrors the aggregate initializer form.
function render_array_literal_initializer(e: ref[Emitter], elements: span[ir.Expr]) -> str:
    if elements.len == 0:
        return "{ 0 }"
    var buf = string.String.create()
    buf.append("{ ")
    var i: ptr_uint = 0
    while i < elements.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(render_initializer(e, elements.data + i))
        i += 1
    buf.append(" }")
    return buf.as_str()


## `receiver.field` receivers that are postfix (name/member/index/call) need no
## parentheses; anything else is wrapped.  Mirrors wrap_member_receiver.
function wrap_member_receiver(e: ref[Emitter], ep: ptr[ir.Expr]) -> str:
    if is_postfix_expr(ep):
        return render_expression(e, ep)
    return j3("(", render_expression(e, ep), ")")


function is_postfix_expr(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_name:
                return true
            ir.Expr.expr_member:
                return true
            ir.Expr.expr_index:
                return true
            ir.Expr.expr_call:
                return true
            _:
                return false


function pointer_member_receiver(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as n:
                if n.pointer:
                    return true
                return is_ptr_type(n.ty)
            _:
                return is_ptr_type(expr_result_type(ep))


function is_ptr_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return (g.name == "ptr" or g.name == "own" or g.name == "ref") and g.args.len == 1
        _:
            return false


function render_string_literal(e: ref[Emitter], value: str, cstring: bool) -> str:
    if cstring:
        return c_string_literal(value)
    let name_ptr = e.str_lit_map.get(value)
    if name_ptr != null:
        unsafe:
            return read(name_ptr)
    return j5("(mt_str){ .data = ", c_string_literal(value), ", .len = ", ptr_uint_to_str(value.len), " }")


function is_str_equality(operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr]) -> bool:
    if not (operator == "==" or operator == "!="):
        return false
    return is_str_type(expr_result_type(left)) and is_str_type(expr_result_type(right))


## True when the binary expression is `==` / `!=` comparing two variant values.
## The type must be pre-registered in `e.variant_eq_set` by `scan_variant_equality`.
function is_variant_equality(operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr], e: ref[Emitter]) -> bool:
    if not (operator == "==" or operator == "!="):
        return false
    let lt = expr_result_type(left)
    let rt = expr_result_type(right)
    if not types.type_to_string(lt) == types.type_to_string(rt):
        return false
    return e.variant_eq_set.contains(variant_c_name_for_type(lt))


## Return the C struct name for a type if it corresponds to a variant, or the
## empty string otherwise.  Uses the same `c_type` path as variant struct
## emission.
function variant_c_name_for_type(ty: types.Type) -> str:
    let name = c_type(ty)
    # `c_type` for a variant type (ty_named / ty_imported) returns the qualified
    # C struct name, e.g. `language_baseline_TokenKind`.  For primitive/str/etc.
    # it returns something else — keep those out.
    if name == "void" or name == "mt_str" or is_primitive_name_from_str(name):
        return ""
    return name


## Render a variant equality expression as a call to the generated helper
## (`mt_variant_eq_<variant_c_name>(left, right)`).  The leading `!` for `!=`
## is inserted by the caller.
function render_variant_equality(e: ref[Emitter], operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr]) -> str:
    let variant_name = variant_c_name_for_type(expr_result_type(left))
    let fn_name = variant_equality_helper_name(variant_name)
    let call = j5(j2(fn_name, "("), render_expression(e, left), ", ", render_expression(e, right), ")")
    if operator == "!=":
        return j2("!", call)
    return call


## True when the binary expression is a nullable-value `== null` or `!= null`.
function is_nullable_null_comparison(operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr]) -> bool:
    if not (operator == "==" or operator == "!="):
        return false
    unsafe:
        let lt = expr_result_type(left)
        let rt = expr_result_type(right)
        return (
            is_value_nullable(lt) and is_null_literal_expr(right)
            or is_value_nullable(rt) and is_null_literal_expr(left)
        )


function is_null_literal_expr(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_null_literal:
                return true
            _:
                return false


## Render a nullable-value `== null` or `!= null` comparison as a `.has_value` check.
function render_nullable_null_comparison(e: ref[Emitter], operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr]) -> str:
    unsafe:
        let operand = if is_null_literal_expr(left): right else: left
        let access = j3(render_expression(e, operand), ".has_value", "")
        if operator == "==":
            return j2("!", access)
        return access


## Static helper generation for variant equality (mirrors Ruby's
## `variant_equality_helper_name`).
function variant_equality_helper_name(variant_c_name: str) -> str:
    return j3("mt_variant_eq_", variant_c_name, "")


## Walk every reachable function's IR body and register every variant type
## that participates in an `==` / `!=` comparison.  This populates
## `e.variant_eq_set` before function emission so helper generation can run
## first.
function scan_variant_equality(e: ref[Emitter], funcs: span[ir.Function], program: ir.Program) -> void:
    var var_lookup = map_mod.Map[str, ir.VariantDecl].create()
    # Build lookup: variant linkage_name → VariantDecl
    var svi: ptr_uint = 0
    while svi < program.variants.len:
        unsafe:
            let vd = read(program.variants.data + svi)
            var_lookup.set(vd.linkage_name, vd)
        svi += 1
    # Register each variant type found in equality comparisons.
    var fi: ptr_uint = 0
    while fi < funcs.len:
        unsafe:
            scan_stmts_for_variant_eq(e, read(funcs.data + fi).body, ref_of(var_lookup))
        fi += 1


function scan_stmts_for_variant_eq(e: ref[Emitter], body: span[ir.Stmt], var_lookup: ref[map_mod.Map[str, ir.VariantDecl]]) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            let stmt_ptr = body.data + i
            match read(stmt_ptr):
                ir.Stmt.stmt_local as loc:
                    scan_expr_for_variant_eq(e, loc.value, var_lookup)
                ir.Stmt.stmt_expression as es:
                    scan_expr_for_variant_eq(e, es.expression, var_lookup)
                ir.Stmt.stmt_assignment as a:
                    scan_expr_for_variant_eq(e, a.target, var_lookup)
                    scan_expr_for_variant_eq(e, a.value, var_lookup)
                ir.Stmt.stmt_return as r:
                    let v = r.value else:
                        i += 1
                        continue
                    scan_expr_for_variant_eq(e, v, var_lookup)
                ir.Stmt.stmt_if as ifs:
                    scan_expr_for_variant_eq(e, ifs.condition, var_lookup)
                    scan_stmts_for_variant_eq(e, ifs.then_body, var_lookup)
                    let eb = ifs.else_body
                    if eb.len > 0:
                        scan_stmts_for_variant_eq(e, eb, var_lookup)
                ir.Stmt.stmt_switch as sw:
                    scan_expr_for_variant_eq(e, sw.expression, var_lookup)
                    var ci: ptr_uint = 0
                    while ci < sw.cases.len:
                        scan_stmts_for_variant_eq(e, unsafe: read(sw.cases.data + ci).body, var_lookup)
                        ci += 1
                ir.Stmt.stmt_while as w:
                    scan_expr_for_variant_eq(e, w.condition, var_lookup)
                    scan_stmts_for_variant_eq(e, w.body, var_lookup)
                ir.Stmt.stmt_for as fs:
                    scan_expr_for_variant_eq(e, fs.condition, var_lookup)
                    scan_stmts_for_variant_eq(e, fs.body, var_lookup)
                ir.Stmt.stmt_label:
                    pass
                _:
                    pass
        i += 1


function scan_expr_for_variant_eq(e: ref[Emitter], ep: ptr[ir.Expr], var_lookup: ref[map_mod.Map[str, ir.VariantDecl]]) -> void:
    unsafe:
        match read(ep):
            ir.Expr.expr_binary as bin:
                if bin.operator == "==" or bin.operator == "!=":
                    let lt = expr_result_type(bin.left)
                    let name = variant_c_name_for_type(lt)
                    if name.len > 0 and var_lookup.contains(name):
                        e.variant_eq_set.set(name, true)
                scan_expr_for_variant_eq(e, bin.left, var_lookup)
                scan_expr_for_variant_eq(e, bin.right, var_lookup)
            ir.Expr.expr_unary as un:
                scan_expr_for_variant_eq(e, un.operand, var_lookup)
            ir.Expr.expr_call as call:
                var ci: ptr_uint = 0
                while ci < call.arguments.len:
                    unsafe:
                        scan_expr_for_variant_eq(e, call.arguments.data + ci, var_lookup)
                    ci += 1
            ir.Expr.expr_call_indirect as ci:
                scan_expr_for_variant_eq(e, ci.callee, var_lookup)
                var ai: ptr_uint = 0
                while ai < ci.arguments.len:
                    unsafe:
                        scan_expr_for_variant_eq(e, ci.arguments.data + ai, var_lookup)
                    ai += 1
            ir.Expr.expr_member as m:
                scan_expr_for_variant_eq(e, m.receiver, var_lookup)
            ir.Expr.expr_cast as c:
                scan_expr_for_variant_eq(e, c.expression, var_lookup)
            ir.Expr.expr_conditional as cond:
                scan_expr_for_variant_eq(e, cond.condition, var_lookup)
                scan_expr_for_variant_eq(e, cond.then_expression, var_lookup)
                scan_expr_for_variant_eq(e, cond.else_expression, var_lookup)
            ir.Expr.expr_index as ix:
                scan_expr_for_variant_eq(e, ix.receiver, var_lookup)
                scan_expr_for_variant_eq(e, ix.index, var_lookup)
            ir.Expr.expr_address_of as a:
                scan_expr_for_variant_eq(e, a.expression, var_lookup)
            ir.Expr.expr_checked_index as ci:
                scan_expr_for_variant_eq(e, ci.receiver, var_lookup)
                scan_expr_for_variant_eq(e, ci.index, var_lookup)
            ir.Expr.expr_checked_span_index as cs:
                scan_expr_for_variant_eq(e, cs.receiver, var_lookup)
                scan_expr_for_variant_eq(e, cs.index, var_lookup)
            ir.Expr.expr_aggregate_literal as agg:
                var fi: ptr_uint = 0
                while fi < agg.fields.len:
                    scan_expr_for_variant_eq(e, unsafe: read(agg.fields.data + fi).value, var_lookup)
                    fi += 1
            ir.Expr.expr_array_literal as arr:
                var ei: ptr_uint = 0
                while ei < arr.elements.len:
                    unsafe:
                        scan_expr_for_variant_eq(e, arr.elements.data + ei, var_lookup)
                    ei += 1
            _:
                pass


## Emit static `mt_variant_eq_<name>` helper functions for every variant type
## registered during the pre-scan.  Each helper compares discriminants first,
## then switches on the arm to compare payload fields.
function emit_variant_equality_helpers(e: ref[Emitter], program: ir.Program) -> void:
    var var_lookup = map_mod.Map[str, ir.VariantDecl].create()
    var svi: ptr_uint = 0
    while svi < program.variants.len:
        unsafe:
            let vd = read(program.variants.data + svi)
            var_lookup.set(vd.linkage_name, vd)
        svi += 1
    var keys = e.variant_eq_set.keys()
    while true:
        let kp = keys.next() else:
            break
        let variant_name = unsafe: read(kp)
        let vd_ptr = var_lookup.get(variant_name) else:
            continue
        let vd = unsafe: read(vd_ptr)
        emit_variant_eq_helper(e, vd)
        emit_line(e, "")


## Emit one `mt_variant_eq_<name>` function for a single variant declaration.
function emit_variant_eq_helper(e: ref[Emitter], vd: ir.VariantDecl) -> void:
    let outer_c = vd.linkage_name
    let fn_name = variant_equality_helper_name(outer_c)
    let struct_ty = j3("struct ", outer_c, "")

    e.buffer.append(j5("static bool ", fn_name, "(", struct_ty, " left, "))
    e.buffer.append(struct_ty)
    e.buffer.append(" right) {")
    e.buffer.push_byte(10)

    # Compare discriminants first.
    e.buffer.append("  if (left.kind != right.kind) return false;")
    e.buffer.push_byte(10)

    # Switch on left.kind.
    e.buffer.append("  switch (left.kind) {")
    e.buffer.push_byte(10)

    var ai: ptr_uint = 0
    while ai < vd.arms.len:
        var arm: ir.VariantArm
        unsafe:
            arm = read(vd.arms.data + ai)
        let kind_name = j4(outer_c, "_kind_", arm.name, "")
        e.buffer.append(j3("    case ", kind_name, ":"))
        e.buffer.push_byte(10)

        if arm.fields.len > 0:
            e.buffer.append("      {")
            e.buffer.push_byte(10)
            var fi: ptr_uint = 0
            while fi < arm.fields.len:
                var field: ir.Field
                unsafe:
                    field = read(arm.fields.data + fi)
                let left_expr = j5("left.data.", arm.name, ".", field.name, "")
                let right_expr = j5("right.data.", arm.name, ".", field.name, "")
                emit_variant_field_compare(e, left_expr, right_expr, field.ty)
                fi += 1
            e.buffer.append("      }")
            e.buffer.push_byte(10)

        e.buffer.append("      break;")
        e.buffer.push_byte(10)
        ai += 1

    e.buffer.append("  }")
    e.buffer.push_byte(10)
    e.buffer.append("  return true;")
    e.buffer.push_byte(10)
    e.buffer.append("}")
    e.buffer.push_byte(10)


## Emit a comparison check for one variant payload field.  Recursively handles
## nested variant types by calling their own equality helpers.
function emit_variant_field_compare(e: ref[Emitter], left_expr: str, right_expr: str, field_ty: types.Type) -> void:
    # Compute a temporary variable name for the condition
    if is_str_type(field_ty):
        e.buffer.append(j5("      if (!mt_str_equal(", left_expr, ", ", right_expr, ")) return false;"))
    else:
        match field_ty:
            types.Type.ty_primitive:
                e.buffer.append(j5("      if (", left_expr, " != ", right_expr, ") return false;"))
            types.Type.ty_named:
                let cname = c_type(field_ty)
                if e.variant_eq_set.contains(cname):
                    let helper = variant_equality_helper_name(cname)
                    e.buffer.append(j3("      if (!", helper, "("))
                    e.buffer.append(left_expr)
                    e.buffer.append(", ")
                    e.buffer.append(right_expr)
                    e.buffer.append(")) return false;")
                else:
                    e.buffer.append(j5("      if (", left_expr, " != ", right_expr, ") return false;"))
            _:
                e.buffer.append(j5("      if (", left_expr, " != ", right_expr, ") return false;"))
        e.buffer.push_byte(10)


## True when `name` is a known primitive type name (mirrors types.mt
## `is_primitive_name` usage).  Used to filter out non-variant types.
function is_primitive_name_from_str(name: str) -> bool:
    return (
        name == "bool" or name == "byte" or name == "short" or name == "int"
        or name == "long" or name == "ubyte" or name == "ushort" or name == "uint"
        or name == "ulong" or name == "ptr_int" or name == "ptr_uint" or name == "float"
        or name == "double" or name == "void" or name == "str" or name == "cstr"
        or name == "char"
    )


## True when the type is pointer-like for nullable purposes: ptr, const_ptr, cstr,
## function types, procs, and opaque types.  Value nullable types become mt_opt_*
## structs; pointer-like nullable types stay as-is (null is the null pointer).
function is_pointer_like_for_nullable(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name == "ptr" or g.name == "const_ptr" or g.name == "own" or g.name == "ref"
        types.Type.ty_primitive as p:
            return p.name == "cstr"
        types.Type.ty_function:
            return true
        _:
            return false


## True when the type is a value-type nullable (non-pointer-like inner type).
function is_value_nullable(t: types.Type) -> bool:
    match t:
        types.Type.ty_nullable as nl:
            unsafe:
                return not is_pointer_like_for_nullable(read(nl.base))
        _:
            return false


function render_call(e: ref[Emitter], callee: str, arguments: span[ir.Expr]) -> str:
    var buf = string.String.create()
    buf.append(callee)
    buf.append("(")
    var i: ptr_uint = 0
    while i < arguments.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(render_expression(e, arguments.data + i))
        i += 1
    buf.append(")")
    return buf.as_str()


## Render a call through a function-pointer expression: `(*callee)(args)`.
function render_indirect_call(e: ref[Emitter], callee: ptr[ir.Expr], arguments: span[ir.Expr]) -> str:
    let callee_text = unsafe: render_expression(e, callee)
    let needs_wrap = not unsafe: is_postfix_expr(callee)
    var buf = string.String.create()
    if needs_wrap:
        buf.append("(")
    buf.append(callee_text)
    if needs_wrap:
        buf.append(")")
    buf.append("(")
    var i: ptr_uint = 0
    while i < arguments.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(render_expression(e, arguments.data + i))
        i += 1
    buf.append(")")
    return buf.as_str()


function render_binary(e: ref[Emitter], operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr]) -> str:
    let parent = binary_precedence(operator)
    let left_text = render_binary_operand(e, left, parent, false)
    let right_text = render_binary_operand(e, right, parent, true)
    return j5(left_text, " ", c_operator(operator), " ", right_text)


function render_binary_operand(e: ref[Emitter], ep: ptr[ir.Expr], parent_precedence: int, is_right: bool) -> str:
    let text = render_expression(e, ep)
    unsafe:
        match read(ep):
            ir.Expr.expr_conditional:
                return j3("(", text, ")")
            ir.Expr.expr_binary as child:
                let child_precedence = binary_precedence(child.operator)
                if child_precedence < parent_precedence or (is_right and child_precedence == parent_precedence):
                    return j3("(", text, ")")
                return text
            _:
                return text


function wrap_expression(e: ref[Emitter], ep: ptr[ir.Expr]) -> str:
    let text = render_expression(e, ep)
    unsafe:
        match read(ep):
            ir.Expr.expr_name:
                return text
            ir.Expr.expr_integer_literal:
                return text
            ir.Expr.expr_float_literal:
                return text
            ir.Expr.expr_boolean_literal:
                return text
            ir.Expr.expr_string_literal:
                return text
            ir.Expr.expr_null_literal:
                return text
            ir.Expr.expr_zero_init:
                return text
            ir.Expr.expr_member:
                return text
            ir.Expr.expr_index:
                return text
            ir.Expr.expr_call:
                return text
            ir.Expr.expr_aggregate_literal:
                return text
            ir.Expr.expr_array_literal:
                return text
            ir.Expr.expr_reinterpret:
                return text
            ir.Expr.expr_sizeof:
                return text
            ir.Expr.expr_alignof:
                return text
            ir.Expr.expr_offsetof:
                return text
            _:
                return j3("(", text, ")")


## The condition operand of a `? :` conditional: parenthesized only when the
## condition is itself a conditional (mirrors Ruby's emit_conditional_condition).
## All other kinds render bare because `?:` binds looser than every operator.
function emit_conditional_condition(e: ref[Emitter], ep: ptr[ir.Expr]) -> str:
    let text = render_expression(e, ep)
    unsafe:
        match read(ep):
            ir.Expr.expr_conditional:
                return j3("(", text, ")")
            _:
                return text


## True when a cast from the operand's type to `target_ty` is a no-op
## (the C type name is the same).  Null-literal operands are never elided
## (mirrors Ruby's no_op_cast?).
function no_op_cast(ep: ptr[ir.Expr], target_ty: types.Type) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_null_literal:
                return false
            _:
                pass
    let source_ty = expr_result_type(ep)
    if types.is_error(source_ty):
        return false
    return c_type(target_ty) == c_type(source_ty)


## Render the operand of a cast, wrapping it in parentheses only when its
## top-level expression kind would be ambiguous without them in C (e.g.
## binary expressions, ternaries).  Otherwise emit it bare.  Mirrors the
## operands Ruby's emit_cast_operand passes through without parentheses.
function emit_cast_operand(e: ref[Emitter], ep: ptr[ir.Expr]) -> str:
    let text = render_expression(e, ep)
    unsafe:
        match read(ep):
            ir.Expr.expr_binary:
                return j3("(", text, ")")
            ir.Expr.expr_call_indirect:
                return j3("(", text, ")")
            ir.Expr.expr_conditional:
                return j3("(", text, ")")
            ir.Expr.expr_variant_literal:
                return j3("(", text, ")")
            _:
                return text


function c_operator(operator: str) -> str:
    if operator == "and":
        return "&&"
    if operator == "or":
        return "||"
    return operator


function binary_precedence(operator: str) -> int:
    if operator == "or":
        return 1
    if operator == "and":
        return 2
    if operator == "|":
        return 3
    if operator == "^":
        return 4
    if operator == "&":
        return 5
    if operator == "==" or operator == "!=":
        return 6
    if operator == "<" or operator == "<=" or operator == ">" or operator == ">=":
        return 7
    if operator == "<<" or operator == ">>":
        return 8
    if operator == "+" or operator == "-":
        return 9
    if operator == "*" or operator == "/" or operator == "%":
        return 10
    fatal(c"c_backend: unsupported binary operator")


# =============================================================================
#  IR expression result type (for str-equality detection)
# =============================================================================

function expr_result_type(ep: ptr[ir.Expr]) -> types.Type:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as x:
                return x.ty
            ir.Expr.expr_member as x:
                return x.ty
            ir.Expr.expr_index as x:
                return x.ty
            ir.Expr.expr_checked_index as x:
                return x.ty
            ir.Expr.expr_checked_span_index as x:
                return x.ty
            ir.Expr.expr_nullable_index as x:
                return x.ty
            ir.Expr.expr_nullable_span_index as x:
                return x.ty
            ir.Expr.expr_call as x:
                return x.ty
            ir.Expr.expr_call_indirect as x:
                return x.ty
            ir.Expr.expr_unary as x:
                return x.ty
            ir.Expr.expr_binary as x:
                return x.ty
            ir.Expr.expr_conditional as x:
                return x.ty
            ir.Expr.expr_reinterpret as x:
                return x.ty
            ir.Expr.expr_sizeof as x:
                return x.ty
            ir.Expr.expr_alignof as x:
                return x.ty
            ir.Expr.expr_offsetof as x:
                return x.ty
            ir.Expr.expr_integer_literal as x:
                return x.ty
            ir.Expr.expr_float_literal as x:
                return x.ty
            ir.Expr.expr_string_literal as x:
                return x.ty
            ir.Expr.expr_boolean_literal as x:
                return x.ty
            ir.Expr.expr_null_literal as x:
                return x.ty
            ir.Expr.expr_zero_init as x:
                return x.ty
            ir.Expr.expr_address_of as x:
                return x.ty
            ir.Expr.expr_cast as x:
                return x.ty
            ir.Expr.expr_aggregate_literal as x:
                return x.ty
            ir.Expr.expr_variant_literal as x:
                return x.ty
            ir.Expr.expr_array_literal as x:
                return x.ty


# =============================================================================
#  Constant emission
# =============================================================================

## Emit a global constant (vtable, etc.) as a static const variable.
function render_constant(e: ref[Emitter], c: ir.Constant) -> str:
    var buf = string.String.create()
    buf.append("static const ")
    # Use c_declaration so array types get C-native `TYPE NAME[N]` syntax
    # (mirrors Ruby, which does not emit a struct typedef for arrays).
    buf.append(c_declaration(c.ty, c.linkage_name))
    buf.append(" = ")
    unsafe:
        buf.append(render_initializer_exp(e, c.value))
    buf.append(";")
    return buf.as_str()


## Render an expression in initializer position (no cast wrapper).
function render_initializer_exp(e: ref[Emitter], ep: ptr[ir.Expr]) -> str:
    unsafe:
        match read(ep):
            ir.Expr.expr_aggregate_literal as agg:
                return render_aggregate_initializer(e, agg.fields)
            _:
                return render_expression(e, ep)


## Emit a module-level global variable (event, var, etc.).
function render_global(e: ref[Emitter], g: ir.Global) -> str:
    var buf = string.String.create()
    buf.append("static ")
    # Use c_declaration so array types get C-native `TYPE NAME[N]` syntax
    # rather than the backend-internal `array_elem_N` struct type name (which
    # has no typedef emitted).
    buf.append(c_declaration(g.ty, g.linkage_name))
    buf.append(";")
    return buf.as_str()


# =============================================================================
#  str_buffer runtime helpers
# =============================================================================

function has_str_buffer_structs(program: ir.Program) -> bool:
    var i: ptr_uint = 0
    while i < program.structs.len:
        unsafe:
            if read(program.structs.data + i).linkage_name.starts_with("mt_str_buffer_"):
                return true
        i += 1
    return false


function emit_str_buffer_helpers(e: ref[Emitter]) -> void:
    emit_line(e, "static uintptr_t mt_str_buffer_len(char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {")
    emit_line(e, "  if (*dirty) {")
    emit_line(e, "    uintptr_t current = 0;")
    emit_line(e, "    while (current < cap + 1 && data[current] != '\\0') {")
    emit_line(e, "      current++;")
    emit_line(e, "    }")
    emit_line(e, "    if (current > cap) mt_fatal(\"str_buffer text requires a trailing NUL within capacity\");")
    emit_line(e, "    *len = current;")
    emit_line(e, "    *dirty = false;")
    emit_line(e, "  }")
    emit_line(e, "  return *len;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_str_buffer_capacity(uintptr_t cap) {")
    emit_line(e, "  return cap;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void mt_str_buffer_clear(uintptr_t* len, bool* dirty) {")
    emit_line(e, "  *len = 0;")
    emit_line(e, "  *dirty = false;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void mt_str_buffer_assign(mt_str value, char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {")
    emit_line(e, "  if (value.len > cap) mt_fatal(\"str_buffer.assign exceeds capacity\");")
    emit_line(e, "  memcpy(data, value.data, value.len);")
    emit_line(e, "  data[value.len] = '\\0';")
    emit_line(e, "  *len = value.len;")
    emit_line(e, "  *dirty = false;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void mt_str_buffer_append(mt_str suffix, char* data, uintptr_t cap, uintptr_t* len, bool* dirty) {")
    emit_line(e, "  uintptr_t current = mt_str_buffer_len(data, cap, len, dirty);")
    emit_line(e, "  uintptr_t total = current + suffix.len;")
    emit_line(e, "  if (total > cap) mt_fatal(\"str_buffer.append exceeds capacity\");")
    emit_line(e, "  memcpy(data + current, suffix.data, suffix.len);")
    emit_line(e, "  data[total] = '\\0';")
    emit_line(e, "  *len = total;")
    emit_line(e, "  *dirty = false;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static mt_str mt_str_buffer_as_str(char* data, uintptr_t* len, bool* dirty) {")
    emit_line(e, "  if (*dirty) mt_fatal(\"str_buffer.as_str requires valid UTF-8, call len() first\");")
    emit_line(e, "  mt_str result;")
    emit_line(e, "  result.data = data;")
    emit_line(e, "  result.len = *len;")
    emit_line(e, "  return result;")
    emit_line(e, "}")


# =============================================================================
#  Format string runtime helpers
# =============================================================================


function uses_format_helpers(program: ir.Program) -> bool:
    # Detect by checking for mt_format_append_bytes call in any function body.
    var i: ptr_uint = 0
    while i < program.functions.len:
        unsafe:
            let f = read(program.functions.data + i)
            if body_calls(f.body, "mt_format_append_bytes") or body_calls(f.body, "mt_format_str_make"):
                return true
        i += 1
    return false


function emit_format_string_helpers(e: ref[Emitter]) -> void:
    emit_line(e, "static mt_str mt_format_str_make(uintptr_t len) {")
    emit_line(e, "  char* data = (char*)malloc((size_t)(len + 1));")
    emit_line(e, "  if (data == NULL) mt_fatal(\"format string allocation failed\");")
    emit_line(e, "  data[len] = '\\0';")
    emit_line(e, "  return (mt_str){ .data = data, .len = len };")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void mt_format_str_release(mt_str value) {")
    emit_line(e, "  free(value.data);")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void mt_format_check_capacity(mt_str target, uintptr_t offset, uintptr_t len) {")
    emit_line(e, "  if (offset > target.len || len > target.len - offset) mt_fatal(\"format string append exceeds capacity\");")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_format_append_bytes(mt_str target, uintptr_t offset, const char* data, uintptr_t len) {")
    emit_line(e, "  mt_format_check_capacity(target, offset, len);")
    emit_line(e, "  if (len > 0) memcpy(target.data + offset, data, (size_t)len);")
    emit_line(e, "  offset += len;")
    emit_line(e, "  target.data[offset] = '\\0';")
    emit_line(e, "  return offset;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_format_ptr_uint_len(uintptr_t value) {")
    emit_line(e, "  uintptr_t len = 1;")
    emit_line(e, "  while (value >= 10) {")
    emit_line(e, "    value /= 10;")
    emit_line(e, "    len += 1;")
    emit_line(e, "  }")
    emit_line(e, "  return len;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_format_ulong_hex_len(uint64_t value) {")
    emit_line(e, "  int written = snprintf(NULL, 0, \"%llx\", (unsigned long long)value);")
    emit_line(e, "  if (written < 0) mt_fatal(\"format string could not measure unsigned hex\");")
    emit_line(e, "  return (uintptr_t)written;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_format_long_hex_len(int64_t value) {")
    emit_line(e, "  if (value < 0) return 1 + mt_format_ulong_hex_len(((uint64_t)(-(value + 1))) + 1);")
    emit_line(e, "  return mt_format_ulong_hex_len((uint64_t)value);")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_format_ulong_oct_len(uint64_t value) {")
    emit_line(e, "  int written = snprintf(NULL, 0, \"%llo\", (unsigned long long)value);")
    emit_line(e, "  if (written < 0) mt_fatal(\"format string could not measure unsigned octal\");")
    emit_line(e, "  return (uintptr_t)written;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_format_long_oct_len(int64_t value) {")
    emit_line(e, "  if (value < 0) return 1 + mt_format_ulong_oct_len(((uint64_t)(-(value + 1))) + 1);")
    emit_line(e, "  return mt_format_ulong_oct_len((uint64_t)value);")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_format_ulong_bin_len(uint64_t value) {")
    emit_line(e, "  uintptr_t len = 1;")
    emit_line(e, "  while (value >= 2) {")
    emit_line(e, "    value >>= 1;")
    emit_line(e, "    len += 1;")
    emit_line(e, "  }")
    emit_line(e, "  return len;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_format_long_bin_len(int64_t value) {")
    emit_line(e, "  if (value < 0) return 1 + mt_format_ulong_bin_len(((uint64_t)(-(value + 1))) + 1);")
    emit_line(e, "  return mt_format_ulong_bin_len((uint64_t)value);")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_format_int_len(int32_t value) {")
    emit_line(e, "  if (value < 0) return 1 + mt_format_ptr_uint_len((uintptr_t)(-((int64_t)value)));")
    emit_line(e, "  return mt_format_ptr_uint_len((uintptr_t)value);")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_format_append_str(mt_str target, uintptr_t offset, mt_str value) {")
    emit_line(e, "  return mt_format_append_bytes(target, offset, value.data, value.len);")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_format_append_ptr_uint(mt_str target, uintptr_t offset, uintptr_t value) {")
    emit_line(e, "  uintptr_t len = mt_format_ptr_uint_len(value);")
    emit_line(e, "  uintptr_t index = offset + len;")
    emit_line(e, "  mt_format_check_capacity(target, offset, len);")
    emit_line(e, "  target.data[index] = '\\0';")
    emit_line(e, "  do {")
    emit_line(e, "    index -= 1;")
    emit_line(e, "    target.data[index] = (char)('0' + (value % 10));")
    emit_line(e, "    value /= 10;")
    emit_line(e, "  } while (index > offset);")
    emit_line(e, "  return offset + len;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static uintptr_t mt_format_append_int(mt_str target, uintptr_t offset, int32_t value) {")
    emit_line(e, "  if (value < 0) {")
    emit_line(e, "    offset = mt_format_append_bytes(target, offset, \"-\", 1);")
    emit_line(e, "    return mt_format_append_ptr_uint(target, offset, (uintptr_t)(-((int64_t)value)));")
    emit_line(e, "  }")
    emit_line(e, "  return mt_format_append_ptr_uint(target, offset, (uintptr_t)value);")
    emit_line(e, "}")


# =============================================================================
#  Event runtime helpers
# =============================================================================



function uses_event_runtime(program: ir.Program) -> bool:

    var i: ptr_uint = 0

    while i < program.functions.len:

        unsafe:

            let f = read(program.functions.data + i)

            if body_calls(f.body, "mt_event_subscribe") or body_calls(f.body, "mt_event_subscribe_once") or body_calls(f.body, "mt_event_unsubscribe") or body_calls(f.body, "mt_event_emit"):
                return true

        i += 1

    # Also detect per-event synthetic functions whose linkage names contain
    # `mt_event_` (e.g. `mt_event_examples_event_stress_test_...__subscribe`).
    i = 0
    while i < program.functions.len:
        unsafe:
            if read(program.functions.data + i).linkage_name.starts_with("mt_event_"):
                return true
        i += 1

    return false





function emit_event_helpers(e: ref[Emitter]) -> void:

    emit_line(e, "typedef int32_t EventError;")
    emit_line(e, "enum { EventError_full = 0 };")
    emit_line(e, "")


#  Parallel / detach runtime helpers

# =============================================================================



function uses_parallel_runtime(program: ir.Program) -> bool:

    var i: ptr_uint = 0

    while i < program.functions.len:

        unsafe:

            let f = read(program.functions.data + i)

            if body_calls(f.body, "mt_parallel_for") or body_calls(f.body, "mt_spawn_all") or body_calls(f.body, "mt_detach_run") or body_calls(f.body, "mt_detach_join"):

                return true

        i += 1
    return false



function emit_task_forward_decls(e: ref[Emitter], program: ir.Program) -> void:
    var seen = map_mod.Map[str, bool].create()
    var task_elements = map_mod.Map[str, types.Type].create()
    var i: ptr_uint = 0
    # Collect Task types from all IR sources (same as emit_task_structs).
    while i < program.functions.len:
        unsafe:
            let f = read(program.functions.data + i)
            collect_task_type(program, ref_of(seen), ref_of(task_elements), f.return_type)
            var pi: ptr_uint = 0
            while pi < f.params.len:
                collect_task_type(program, ref_of(seen), ref_of(task_elements), read(f.params.data + pi).ty)
                pi += 1
        i += 1
    i = 0
    while i < program.structs.len:
        unsafe:
            let s = read(program.structs.data + i)
            var fi: ptr_uint = 0
            while fi < s.fields.len:
                collect_task_type(program, ref_of(seen), ref_of(task_elements), read(s.fields.data + fi).ty)
                fi += 1
        i += 1
    i = 0
    while i < program.type_aliases.len:
        unsafe:
            collect_task_type(program, ref_of(seen), ref_of(task_elements), read(program.type_aliases.data + i).target_type)
        i += 1
    var keys = seen.keys()
    while true:
        let kp = keys.next() else:
            break
        let c_name = unsafe: read(kp)
        emit_line(e, j5("typedef struct ", c_name, " ", c_name, ";"))
    if seen.len() > 0:
        emit_line(e, "")



function emit_task_structs(e: ref[Emitter], program: ir.Program) -> void:
    var seen = map_mod.Map[str, bool].create()
    var task_elements = map_mod.Map[str, types.Type].create()

    # Collect Task types from function return types and parameter types.
    var i: ptr_uint = 0
    while i < program.functions.len:
        unsafe:
            let f = read(program.functions.data + i)
            collect_task_type(program, ref_of(seen), ref_of(task_elements), f.return_type)
            var pi: ptr_uint = 0
            while pi < f.params.len:
                collect_task_type(program, ref_of(seen), ref_of(task_elements), read(f.params.data + pi).ty)
                pi += 1
        i += 1

    # Collect Task types from struct field types (async frame structs have
    # `await_N` fields typed as Task[T]).
    i = 0
    while i < program.structs.len:
        unsafe:
            let s = read(program.structs.data + i)
            var fi: ptr_uint = 0
            while fi < s.fields.len:
                collect_task_type(program, ref_of(seen), ref_of(task_elements), read(s.fields.data + fi).ty)
                fi += 1
        i += 1

    # Collect Task types from type aliases (e.g. `type ChanMessageTask = Task[Option[Message]]`).
    i = 0
    while i < program.type_aliases.len:
        unsafe:
            collect_task_type(program, ref_of(seen), ref_of(task_elements), read(program.type_aliases.data + i).target_type)
        i += 1

    # Emit collected Task struct types.
    var keys = seen.keys()
    while true:
        let kp = keys.next() else:
            break
        let c_name = unsafe: read(kp)
        var elem = types.primitive("void")
        let te_ptr = task_elements.get(c_name)
        if te_ptr != null:
            elem = unsafe: read(te_ptr)
        emit_task_struct_type(e, c_name, elem)
    if seen.len() > 0:
        emit_line(e, "")


## Collect a Task type element from a type reference.  When `t` is a
## `Task[T]` or has Task-typed sub-expressions, adds the concrete Task
## struct name to `seen` and records the element type.
function collect_task_type(program: ir.Program, seen: ref[map_mod.Map[str, bool]], elements: ref[map_mod.Map[str, types.Type]], t: types.Type) -> void:
    match t:
        types.Type.ty_generic as g:
            if g.name == "Task" and g.args.len == 1:
                let elem = unsafe: read(g.args.data + 0)
                var task_args = vec.Vec[types.Type].create()
                task_args.push(elem)
                let c_name = generic_c_type("Task", task_args.as_span())
                if not seen.contains(c_name):
                    seen.set(c_name, true)
                    elements.set(c_name, elem)
            # Also scan nested generic args for Task types.
            var ai: ptr_uint = 0
            while ai < g.args.len:
                collect_task_type(program, seen, elements, unsafe: read(g.args.data + ai))
                ai += 1
        types.Type.ty_named as n:
            if n.name.starts_with("mt_task_"):
                if not seen.contains(n.name):
                    seen.set(n.name, true)
        types.Type.ty_imported as im:
            if im.name.starts_with("mt_task_"):
                if not seen.contains(im.name):
                    seen.set(im.name, true)
        _:
            pass



function task_type_element(t: types.Type) -> Option[types.Type]:
    match t:

        types.Type.ty_generic as g:

            if g.name == "Task" and g.args.len == 1:

                return Option[types.Type].some(value = unsafe: read(g.args.data + 0))

            return Option[types.Type].none

        _:

            return Option[types.Type].none





function emit_task_struct_type(e: ref[Emitter], c_name: str, elem: types.Type) -> void:

    let is_void = is_void_type(elem)

    let type_str = c_type(elem)

    emit_line(e, j3("struct ", c_name, " {"))

    if not is_void:

        emit_line(e, j3("  ", type_str, " value;"))

    emit_line(e, "  void* frame;")

    emit_line(e, "  bool (*ready)(void*);")

    emit_line(e, "  void (*set_waiter)(void*, void*, void(*)(void*));")

    emit_line(e, "  void (*release)(void*);")

    if not is_void:

        emit_line(e, j3("  ", type_str, " (*take_result)(void*);"))

    emit_line(e, "  void (*cancel)(void*);")

    emit_line(e, "};")

    emit_line(e, j3("typedef struct ", c_name, j2(" ", j2(c_name, ";"))))

    emit_line(e, "")





function is_vec_math_name(name: str) -> bool:

    return (

        name == "vec2" or name == "vec3" or name == "vec4"

        or name == "ivec2" or name == "ivec3" or name == "ivec4"

        or name == "mat3" or name == "mat4" or name == "quat"

    )





function is_void_type(t: types.Type) -> bool:

    match t:

        types.Type.ty_primitive as p:

            return p.name == "void"

        _:

            return false





function emit_builtin_type_defs(e: ref[Emitter], program: ir.Program) -> void:

    var needed = map_mod.Map[str, bool].create()

    var fi: ptr_uint = 0

    while fi < program.functions.len:

        var f: ir.Function

        unsafe:

            f = read(program.functions.data + fi)

        collect_builtin_types(ref_of(needed), f.return_type)

        var pi: ptr_uint = 0

        while pi < f.params.len:

            unsafe:

                collect_builtin_types(ref_of(needed), read(f.params.data + pi).ty)

            pi += 1

        fi += 1

    # Also scan struct fields and type aliases

    var si: ptr_uint = 0

    while si < program.structs.len:

        var s: ir.StructDecl

        unsafe:

            s = read(program.structs.data + si)

        var sfi: ptr_uint = 0

        while sfi < s.fields.len:

            unsafe:

                collect_builtin_types(ref_of(needed), read(s.fields.data + sfi).ty)

            sfi += 1

        si += 1

    var ti: ptr_uint = 0

    while ti < program.type_aliases.len:

        var ta: ir.TypeAlias

        unsafe:

            ta = read(program.type_aliases.data + ti)

        collect_builtin_types(ref_of(needed), ta.target_type)

        ti += 1

    if needed.contains("vec2"):

        emit_line(e, "typedef struct mt_vec2 { float x; float y; } mt_vec2;")

        emit_line(e, "typedef struct mt_ivec2 { int32_t x; int32_t y; } mt_ivec2;")

    if needed.contains("vec3") or needed.contains("mat3"):

        emit_line(e, "typedef struct mt_vec3 { float x; float y; float z; } mt_vec3;")

        emit_line(e, "typedef struct mt_ivec3 { int32_t x; int32_t y; int32_t z; } mt_ivec3;")

    if needed.contains("vec4") or needed.contains("mat4"):

        emit_line(e, "typedef struct mt_vec4 { float x; float y; float z; float w; } mt_vec4;")

        emit_line(e, "typedef struct mt_ivec4 { int32_t x; int32_t y; int32_t z; int32_t w; } mt_ivec4;")

    if needed.contains("mat3"):

        emit_line(e, "typedef struct mt_mat3 { mt_vec3 col0; mt_vec3 col1; mt_vec3 col2; } mt_mat3;")

    if needed.contains("mat4"):

        emit_line(e, "typedef struct mt_mat4 { mt_vec4 col0; mt_vec4 col1; mt_vec4 col2; mt_vec4 col3; } mt_mat4;")

    if needed.contains("quat"):

        emit_line(e, "typedef struct mt_quat { float x; float y; float z; float w; } mt_quat;")

    if needed.contains("vec2") or needed.contains("vec3") or needed.contains("vec4"):

        emit_line(e, "")

    emit_line(e, "")





## Collect and emit nullable opt struct definitions for value-type nullables.

function collect_opt_type(needed: ref[map_mod.Map[str, types.Type]], t: types.Type) -> void:

    match t:

        types.Type.ty_nullable as nl:

            unsafe:

                let base = read(nl.base)

                if not is_pointer_like_for_nullable(base):

                    let c_key = j2("mt_opt_", naming.type_c_key(base))

                    if not needed.contains(c_key):

                        needed.set(c_key, types.Type.ty_nullable(base = types.alloc_type(base)))

        types.Type.ty_generic as g:

            var gi: ptr_uint = 0

            while gi < g.args.len:

                unsafe:

                    collect_opt_type(needed, read(g.args.data + gi))

                gi += 1

        types.Type.ty_imported as im:

            var ai: ptr_uint = 0

            while ai < im.args.len:

                unsafe:

                    collect_opt_type(needed, read(im.args.data + ai))

                ai += 1

        types.Type.ty_function as f:

            var fi: ptr_uint = 0

            while fi < f.params.len:

                unsafe:

                    collect_opt_type(needed, read(f.params.data + fi))

                fi += 1

            unsafe:

                collect_opt_type(needed, read(f.return_type))

        types.Type.ty_tuple as tu:

            var ei: ptr_uint = 0

            while ei < tu.elements.len:

                unsafe:

                    collect_opt_type(needed, read(tu.elements.data + ei))

                ei += 1

        _:

            pass





function collect_opt_struct_decls(program: ir.Program) -> vec.Vec[OptStructEntry]:

    var needed = map_mod.Map[str, types.Type].create()

    var fi: ptr_uint = 0

    while fi < program.functions.len:

        var f: ir.Function

        unsafe:

            f = read(program.functions.data + fi)

            collect_opt_type(ref_of(needed), f.return_type)

        var pi: ptr_uint = 0

        while pi < f.params.len:

            unsafe:

                collect_opt_type(ref_of(needed), read(f.params.data + pi).ty)

            pi += 1

        collect_opt_from_stmts(ref_of(needed), f.body)

        fi += 1

    var si: ptr_uint = 0

    while si < program.structs.len:

        var s: ir.StructDecl

        unsafe:

            s = read(program.structs.data + si)

        var sfi: ptr_uint = 0

        while sfi < s.fields.len:

            unsafe:

                collect_opt_type(ref_of(needed), read(s.fields.data + sfi).ty)

            sfi += 1

        si += 1

    var ti: ptr_uint = 0

    while ti < program.type_aliases.len:

        var ta: ir.TypeAlias

        unsafe:

            ta = read(program.type_aliases.data + ti)

        collect_opt_type(ref_of(needed), ta.target_type)

        ti += 1

    var ci: ptr_uint = 0

    while ci < program.constants.len:

        unsafe:

            collect_opt_type(ref_of(needed), read(program.constants.data + ci).ty)

        ci += 1

    var gi: ptr_uint = 0

    while gi < program.globals.len:

        unsafe:

            collect_opt_type(ref_of(needed), read(program.globals.data + gi).ty)

        gi += 1

    var result = vec.Vec[OptStructEntry].create()

    if needed.len() > 0:

        var key_list = vec.Vec[str].create()

        defer key_list.release()

        var kiter = needed.keys()

        while true:

            let key_ptr = kiter.next() else:

                break

            unsafe:

                key_list.push(read(key_ptr))

        var viter = key_list.iter()

        while true:

            let key_ptr = viter.next() else:

                break

            unsafe:

                let key_value = read(key_ptr)

                let opt_type = needed.at(key_value).unwrap()

                match opt_type:

                    types.Type.ty_nullable as nl:

                        unsafe:

                            let base_type = read(nl.base)

                            var fields = vec.Vec[ir.Field].create()

                            fields.push(ir.Field(name = "has_value", ty = types.primitive("bool")))

                            fields.push(ir.Field(name = "value", ty = base_type))

                            let decl = ir.StructDecl(

                                name = key_value,

                                linkage_name = key_value,

                                fields = fields.as_span(),

                                packed = false,

                                alignment = 0,

                                source_module = Option[str].none,

                            )

                            result.push(OptStructEntry(decl = decl, field_store = fields))

                    _:

                        pass

    return result





## Walk statements to collect nullable value types from local variable declarations.

function collect_opt_from_stmts(needed: ref[map_mod.Map[str, types.Type]], body: span[ir.Stmt]) -> void:

    var i: ptr_uint = 0

    while i < body.len:

        unsafe:

            match read(body.data + i):

                ir.Stmt.stmt_local as loc:

                    collect_opt_type(needed, loc.ty)

                    collect_opt_from_expr(needed, loc.value)

                ir.Stmt.stmt_assignment as asg:

                    collect_opt_from_expr(needed, asg.value)

                ir.Stmt.stmt_expression as ex:

                    collect_opt_from_expr(needed, ex.expression)

                ir.Stmt.stmt_return as ret:

                    # ret.value is ptr[ir.Expr]? — skip for now to avoid prelude match issues

                    pass

                ir.Stmt.stmt_block as blk:

                    collect_opt_from_stmts(needed, blk.body)

                ir.Stmt.stmt_if as iff:

                    collect_opt_from_expr(needed, iff.condition)

                    collect_opt_from_stmts(needed, iff.then_body)

                    collect_opt_from_stmts(needed, iff.else_body)

                ir.Stmt.stmt_while as w:

                    collect_opt_from_expr(needed, w.condition)

                    collect_opt_from_stmts(needed, w.body)

                ir.Stmt.stmt_for as f:

                    match read(f.init):

                        ir.Stmt.stmt_local as iloc:

                            collect_opt_type(needed, iloc.ty)

                            collect_opt_from_expr(needed, iloc.value)

                        ir.Stmt.stmt_expression as iex:

                            collect_opt_from_expr(needed, iex.expression)

                        _:

                            pass

                    collect_opt_from_expr(needed, f.condition)

                    match read(f.post):

                        ir.Stmt.stmt_expression as pex:

                            collect_opt_from_expr(needed, pex.expression)

                        _:

                            pass

                    collect_opt_from_stmts(needed, f.body)

                ir.Stmt.stmt_switch as sw:

                    collect_opt_from_expr(needed, sw.expression)

                    var ci: ptr_uint = 0

                    while ci < sw.cases.len:

                        unsafe:

                            collect_opt_from_stmts(needed, read(sw.cases.data + ci).body)

                        ci += 1

                _:

                    pass

        i += 1





## Walk expression sub-tree to collect nullable value types.

function collect_opt_from_expr(needed: ref[map_mod.Map[str, types.Type]], ep: ptr[ir.Expr]) -> void:

    collect_opt_type(needed, expr_result_type(ep))





## Scan all expressions in function bodies for nullable value types.

function collect_builtin_types(needed: ref[map_mod.Map[str, bool]], t: types.Type) -> void:

    match t:

        types.Type.ty_primitive as p:

            if p.name == "vec2" or p.name == "ivec2" or p.name == "vec3" or p.name == "ivec3" or p.name == "vec4" or p.name == "ivec4" or p.name == "mat3" or p.name == "mat4" or p.name == "quat":

                needed.set(p.name, true)

        types.Type.ty_nullable as n:

            unsafe:

                collect_builtin_types(needed, read(n.base))

        types.Type.ty_generic as g:

            var gi: ptr_uint = 0

            while gi < g.args.len:

                unsafe:

                    collect_builtin_types(needed, read(g.args.data + gi))

                gi += 1

        types.Type.ty_imported as im:

            var ai: ptr_uint = 0

            while ai < im.args.len:

                unsafe:

                    collect_builtin_types(needed, read(im.args.data + ai))

                ai += 1

        types.Type.ty_function as f:

            var fi: ptr_uint = 0

            while fi < f.params.len:

                unsafe:

                    collect_builtin_types(needed, read(f.params.data + fi))

                fi += 1

            unsafe:

                collect_builtin_types(needed, read(f.return_type))

        types.Type.ty_tuple as tu:

            var ei: ptr_uint = 0

            while ei < tu.elements.len:

                unsafe:

                    collect_builtin_types(needed, read(tu.elements.data + ei))

                ei += 1

        _:

            pass





function emit_type_aliases(e: ref[Emitter], program: ir.Program) -> void:
    var ai: ptr_uint = 0
    while ai < program.type_aliases.len:
        var ta: ir.TypeAlias
        unsafe:
            ta = read(program.type_aliases.data + ai)
        var skip = false
        match ta.target_type:
            types.Type.ty_function:
                let mod_c_prefix = naming.module_c_prefix(program.module_name)
                if not ta.qualified_name.starts_with(mod_c_prefix):
                    skip = true
            _:
                pass
        if not skip:
            match ta.backing_c_name:
                Option.some as cname:
                    emit_line(e, j5("typedef ", cname.value, " ", ta.qualified_name, ";"))
                Option.none:
                    let c_type_str = c_declaration(ta.target_type, ta.qualified_name)
                    emit_line(e, j3("typedef ", c_type_str, ";"))
        ai += 1
    if program.type_aliases.len > 0:
        emit_line(e, "")



function collect_std_c_backing(program: ir.Program) -> map_mod.Map[str, str]:
    var m = map_mod.Map[str, str].create()
    var ai: ptr_uint = 0
    while ai < program.type_aliases.len:
        var ta: ir.TypeAlias
        unsafe:
            ta = read(program.type_aliases.data + ai)
        match ta.backing_c_name:
            Option.some as cname:
                match ta.target_type:
                    types.Type.ty_imported as im:
                        if im.name != cname.value:
                            m.set(im.name, cname.value)
                    _:
                        pass
            Option.none:
                pass
        ai += 1
    return m





## True when the include set contains the fs/tls support headers, which pull in

## POSIX APIs guarded by the _GNU_SOURCE / _POSIX_C_SOURCE feature-test macros.

function includes_need_feature_macros(program: ir.Program) -> bool:

    var i: ptr_uint = 0

    while i < program.includes.len:

        unsafe:

            let h = read(program.includes.data + i).header

            if h == "\"fs_support.h\"" or h == "\"tls_support.h\"":

                return true

        i += 1

    return false





## True when any lowered function references offset_of, which requires

## <stddef.h> (mirrors Ruby's program_uses_offsetof?).

function functions_use_offsetof(functions: span[ir.Function]) -> bool:

    var i: ptr_uint = 0

    while i < functions.len:

        if stmts_use_offsetof(unsafe: read(functions.data + i).body):

            return true

        i += 1

    return false





## Check if any IR constant uses offsetof — constants are not in function

## bodies so we must scan them separately.

function constants_use_offsetof(constants: span[ir.Constant]) -> bool:

    var i: ptr_uint = 0

    while i < constants.len:

        unsafe:

            if expr_uses_offsetof(read(constants.data + i).value):

                return true

        i += 1

    return false





function stmts_use_offsetof(body: span[ir.Stmt]) -> bool:

    var i: ptr_uint = 0

    while i < body.len:

        unsafe:

            if stmt_uses_offsetof(body.data + i):

                return true

        i += 1

    return false





function stmt_uses_offsetof(sp: ptr[ir.Stmt]) -> bool:

    unsafe:

        match read(sp):

            ir.Stmt.stmt_return as r:

                let value = r.value else:

                    return false

                return expr_uses_offsetof(value)

            ir.Stmt.stmt_local as loc:

                return expr_uses_offsetof(loc.value)

            ir.Stmt.stmt_assignment as asg:

                return expr_uses_offsetof(asg.target) or expr_uses_offsetof(asg.value)

            ir.Stmt.stmt_expression as ex:

                return expr_uses_offsetof(ex.expression)

            ir.Stmt.stmt_block as blk:

                return stmts_use_offsetof(blk.body)

            ir.Stmt.stmt_if as iff:

                return expr_uses_offsetof(iff.condition) or stmts_use_offsetof(iff.then_body) or stmts_use_offsetof(iff.else_body)

            ir.Stmt.stmt_while as w:

                return expr_uses_offsetof(w.condition) or stmts_use_offsetof(w.body)

            ir.Stmt.stmt_for as f:

                return stmt_uses_offsetof(f.init) or expr_uses_offsetof(f.condition) or stmt_uses_offsetof(f.post) or stmts_use_offsetof(f.body)

            ir.Stmt.stmt_switch as sw:

                if expr_uses_offsetof(sw.expression):

                    return true

                var ci: ptr_uint = 0

                while ci < sw.cases.len:

                    if stmts_use_offsetof(read(sw.cases.data + ci).body):

                        return true

                    ci += 1

                return false

            ir.Stmt.stmt_static_assert as sa:

                return expr_uses_offsetof(sa.condition) or expr_uses_offsetof(sa.message)

            _:

                return false





function expr_uses_offsetof(ep: ptr[ir.Expr]) -> bool:

    unsafe:

        match read(ep):

            ir.Expr.expr_offsetof:

                return true

            ir.Expr.expr_member as m:

                return expr_uses_offsetof(m.receiver)

            ir.Expr.expr_index as ix:

                return expr_uses_offsetof(ix.receiver) or expr_uses_offsetof(ix.index)

            ir.Expr.expr_checked_index as ci:

                return expr_uses_offsetof(ci.receiver) or expr_uses_offsetof(ci.index)

            ir.Expr.expr_checked_span_index as cs:

                return expr_uses_offsetof(cs.receiver) or expr_uses_offsetof(cs.index)

            ir.Expr.expr_nullable_index as ni:

                return expr_uses_offsetof(ni.receiver) or expr_uses_offsetof(ni.index)

            ir.Expr.expr_nullable_span_index as ns:

                return expr_uses_offsetof(ns.receiver) or expr_uses_offsetof(ns.index)

            ir.Expr.expr_call as call:

                var i: ptr_uint = 0

                while i < call.arguments.len:

                    if expr_uses_offsetof(call.arguments.data + i):

                        return true

                    i += 1

                return false

            ir.Expr.expr_call_indirect as call:

                if expr_uses_offsetof(call.callee):

                    return true

                var i: ptr_uint = 0

                while i < call.arguments.len:

                    if expr_uses_offsetof(call.arguments.data + i):

                        return true

                    i += 1

                return false

            ir.Expr.expr_unary as un:

                return expr_uses_offsetof(un.operand)

            ir.Expr.expr_binary as bin:

                return expr_uses_offsetof(bin.left) or expr_uses_offsetof(bin.right)

            ir.Expr.expr_conditional as cond:

                return expr_uses_offsetof(cond.condition) or expr_uses_offsetof(cond.then_expression) or expr_uses_offsetof(cond.else_expression)

            ir.Expr.expr_reinterpret as rin:

                return expr_uses_offsetof(rin.expression)

            ir.Expr.expr_cast as cast:

                return expr_uses_offsetof(cast.expression)

            ir.Expr.expr_address_of as addr:

                return expr_uses_offsetof(addr.expression)

            ir.Expr.expr_aggregate_literal as agg:

                var i: ptr_uint = 0

                while i < agg.fields.len:

                    if expr_uses_offsetof(read(agg.fields.data + i).value):

                        return true

                    i += 1

                return false

            ir.Expr.expr_variant_literal as vl:

                var i: ptr_uint = 0

                while i < vl.fields.len:

                    if expr_uses_offsetof(read(vl.fields.data + i).value):

                        return true

                    i += 1

                return false

            ir.Expr.expr_array_literal as arr:

                var i: ptr_uint = 0

                while i < arr.elements.len:

                    if expr_uses_offsetof(arr.elements.data + i):

                        return true

                    i += 1

                return false

            _:

                return false





function emit_parallel_helpers(e: ref[Emitter]) -> void:

    emit_line(e, "typedef struct {")
    emit_line(e, "  void (*work)(void* data, int64_t start, int64_t end);")
    emit_line(e, "  void* data;")
    emit_line(e, "  int64_t start;")
    emit_line(e, "  int64_t end;")
    emit_line(e, "} mt_pfor_chunk;")
    emit_line(e, "")
    emit_line(e, "static void mt_pfor_runner(void* arg) {")
    emit_line(e, "  mt_pfor_chunk* chunk = (mt_pfor_chunk*)arg;")
    emit_line(e, "  chunk->work(chunk->data, chunk->start, chunk->end);")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void mt_parallel_for(void (*work)(void* data, int64_t start, int64_t end), void* data, int64_t count) {")
    emit_line(e, "  if (count <= 0) return;")
    emit_line(e, "  uv_cpu_info_t* cpu_info;")
    emit_line(e, "  int ncpu = 1;")
    emit_line(e, "  if (uv_cpu_info(&cpu_info, &ncpu) == 0) {")
    emit_line(e, "    uv_free_cpu_info(cpu_info, ncpu);")
    emit_line(e, "  }")
    emit_line(e, "  if (ncpu < 1) ncpu = 1;")
    emit_line(e, "  if (ncpu > 64) ncpu = 64;")
    emit_line(e, "  if (count < (int64_t)ncpu) ncpu = (int)count;")
    emit_line(e, "  int64_t chunk_size = (count + ncpu - 1) / ncpu;")
    emit_line(e, "  mt_pfor_chunk chunks[64];")
    emit_line(e, "  uv_thread_t threads[64];")
    emit_line(e, "  int nworkers = 0;")
    emit_line(e, "  for (int t = 1; t < ncpu; t++) {")
    emit_line(e, "    int64_t s = t * chunk_size;")
    emit_line(e, "    int64_t e = s + chunk_size;")
    emit_line(e, "    if (e > count) e = count;")
    emit_line(e, "    if (s >= count) break;")
    emit_line(e, "    chunks[nworkers].work = work;")
    emit_line(e, "    chunks[nworkers].data = data;")
    emit_line(e, "    chunks[nworkers].start = s;")
    emit_line(e, "    chunks[nworkers].end = e;")
    emit_line(e, "    uv_thread_create(&threads[nworkers], mt_pfor_runner, &chunks[nworkers]);")
    emit_line(e, "    nworkers++;")
    emit_line(e, "  }")
    emit_line(e, "  int64_t first_end = chunk_size < count ? chunk_size : count;")
    emit_line(e, "  work(data, 0, first_end);")
    emit_line(e, "  for (int t = 0; t < nworkers; t++) {")
    emit_line(e, "    uv_thread_join(&threads[t]);")
    emit_line(e, "  }")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "typedef struct {")
    emit_line(e, "  void (*work)(void* data);")
    emit_line(e, "  void* data;")
    emit_line(e, "} mt_spawn_item;")
    emit_line(e, "")
    emit_line(e, "static void mt_spawn_item_runner(void* arg) {")
    emit_line(e, "  mt_spawn_item* item = (mt_spawn_item*)arg;")
    emit_line(e, "  item->work(item->data);")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void mt_spawn_all(mt_spawn_item* items, int count) {")
    emit_line(e, "  if (count <= 0) return;")
    emit_line(e, "  uv_thread_t threads[64];")
    emit_line(e, "  int nworkers = 0;")
    emit_line(e, "  for (int t = 1; t < count && nworkers < 63; t++) {")
    emit_line(e, "    uv_thread_create(&threads[nworkers], mt_spawn_item_runner, &items[t]);")
    emit_line(e, "    nworkers++;")
    emit_line(e, "  }")
    emit_line(e, "  items[0].work(items[0].data);")
    emit_line(e, "  for (int t = 0; t < nworkers; t++) {")
    emit_line(e, "    uv_thread_join(&threads[t]);")
    emit_line(e, "  }")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "typedef struct {")
    emit_line(e, "  uv_thread_t thread;")
    emit_line(e, "} mt_detach_handle;")
    emit_line(e, "")
    emit_line(e, "static void* mt_detach_run(void (*work)(void*), void* cap) {")
    emit_line(e, "  mt_detach_handle* h = (mt_detach_handle*)malloc(sizeof(mt_detach_handle));")
    emit_line(e, "  uv_thread_create(&h->thread, work, cap);")
    emit_line(e, "  return h;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void mt_detach_join(void* handle) {")
    emit_line(e, "  if (!handle) return;")
    emit_line(e, "  mt_detach_handle* h = (mt_detach_handle*)handle;")
    emit_line(e, "  uv_thread_join(&h->thread);")
    emit_line(e, "  free(h);")
    emit_line(e, "}")





function uses_builtin_helpers(program: ir.Program) -> bool:

    var i: ptr_uint = 0

    while i < program.functions.len:

        unsafe:

            let f = read(program.functions.data + i)

            if body_calls(f.body, "mt_order_func") or body_calls(f.body, "mt_equal_func") or body_calls(f.body, "mt_hash_func"):

                return true

        i += 1

    return false





function emit_builtin_helpers(e: ref[Emitter]) -> void:

    emit_line(e, "static int32_t mt_order_func(void const* a, void const* b) {")

    emit_line(e, "  intptr_t diff = (char const*)a - (char const*)b;")

    emit_line(e, "  return diff < 0 ? -1 : diff > 0 ? 1 : 0;")

    emit_line(e, "}")

    emit_line(e, "")

    emit_line(e, "static bool mt_equal_func(void const* a, void const* b) {")

    emit_line(e, "  return a == b;")

    emit_line(e, "}")

    emit_line(e, "")

    emit_line(e, "static uint32_t mt_hash_func(void const* value) {")

    emit_line(e, "  return (uint32_t)(uintptr_t)value;")

    emit_line(e, "}")





## True when the entry point uses the argv → span[str] bridge.

function uses_entry_argv(program: ir.Program) -> bool:

    var i: ptr_uint = 0

    while i < program.functions.len:

        unsafe:

            let f = read(program.functions.data + i)

            if body_calls(f.body, "mt_entry_argv_to_span_str") or body_calls(f.body, "mt_free_entry_argv_strs"):

                return true

        i += 1

    return false





## Emit the argv → span[str] entry bridge runtime helpers.  Mirrors Ruby's

## mt_entry_argv_to_span_str / mt_free_entry_argv_strs (runtime_helpers.rb).

function emit_entry_argv_helpers(e: ref[Emitter]) -> void:

    emit_line(e, "static mt_span_str mt_entry_argv_to_span_str(int32_t argc, char** argv, mt_str** items_out) {")

    emit_line(e, "  uintptr_t len = argc > 1 ? (uintptr_t)(argc - 1) : 0;")

    emit_line(e, "  mt_str* items = NULL;")

    emit_line(e, "  uintptr_t index = 0;")

    emit_line(e, "  if (len > 0) {")

    emit_line(e, "    items = (mt_str*)malloc(len * sizeof(mt_str));")

    emit_line(e, "    if (items == NULL) abort();")

    emit_line(e, "  }")

    emit_line(e, "  while (index < len) {")

    emit_line(e, "    char* value = argv[index + 1];")

    emit_line(e, "    items[index] = (mt_str){ .data = value, .len = (uintptr_t)strlen(value) };")

    emit_line(e, "    index++;")

    emit_line(e, "  }")

    emit_line(e, "  *items_out = items;")

    emit_line(e, "  return (mt_span_str){ .data = items, .len = len };")

    emit_line(e, "}")

    emit_line(e, "")

    emit_line(e, "static void mt_free_entry_argv_strs(mt_str* items) {")

    emit_line(e, "  free(items);")

    emit_line(e, "}")


## True when any emitted function calls the foreign str-to-cstr temp helper.
function uses_foreign_cstr_helper(functions: span[ir.Function]) -> bool:
    var i: ptr_uint = 0
    while i < functions.len:
        unsafe:
            if body_calls(read(functions.data + i).body, "mt_foreign_str_to_cstr_temp"):
                return true
        i += 1
    return false


## Emit the `mt_foreign_str_to_cstr_temp` runtime helper: malloc's a
## null-terminated copy of a str value for passing to C foreign functions.
## Mirrors Ruby's c_backend/runtime_helpers.rb `mt_foreign_str_to_cstr_temp`.
function emit_foreign_cstr_helper(e: ref[Emitter]) -> void:
    emit_line(e, "static const char* mt_foreign_str_to_cstr_temp(mt_str value) {")
    emit_line(e, "  char* data = (char*)malloc(value.len + 1);")
    emit_line(e, "  uintptr_t index = 0;")
    emit_line(e, "  if (data == NULL) mt_fatal(\"foreign str temporary allocation failed\");")
    emit_line(e, "  while (index < value.len) {")
    emit_line(e, "    data[index] = value.data[index];")
    emit_line(e, "    index++;")
    emit_line(e, "  }")
    emit_line(e, "  data[value.len] = '\\0';")
    emit_line(e, "  return data;")
    emit_line(e, "}")
