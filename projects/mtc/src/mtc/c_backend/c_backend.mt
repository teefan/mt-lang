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


## Local variant-arm metadata for prelude type collection (mirrors lowering's
## VariantArmInfo / VariantInfo, scoped small for the backend).
struct GVArmInfo:
    name: str
    fields: span[ir.Field]


struct GVInfo:
    arms: span[GVArmInfo]


public function generate_c(program: ir.Program) -> string.String:
    var e = Emitter(
        buffer = string.String.create(),
        str_lit_map = map_mod.Map[str, str].create(),
        used_labels = map_mod.Map[str, bool].create(),
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
    # Bounds-checked accessors call mt_fatal, so their presence pulls in the
    # fatal helper (and, via uses_string_view, the mt_str type + <stdlib.h>).
    let use_fatal = uses_fatal_helper(funcs, program) or checked_index_types.len() > 0 or checked_span_index_types.len() > 0
    let use_string_view = uses_string_view(funcs, has_str_literals) or use_fatal or aggregates_use_str(program) or gen_variants_have_str(ref_of(gen_variants))
    let use_str_equality = uses_str_equality(funcs)

    var i: ptr_uint = 0
    while i < program.includes.len:
        unsafe:
            emit_line(ref_of(e), j2("#include ", read(program.includes.data + i).header))
        i += 1
    if use_fatal:
        emit_line(ref_of(e), "#include <stdlib.h>")
    emit_line(ref_of(e), "")

    if use_string_view:
        emit_string_type(ref_of(e))
        emit_line(ref_of(e), "")

    if use_fatal:
        emit_fatal_helper(ref_of(e))
        emit_line(ref_of(e), "")

    if use_str_equality:
        emit_str_equality_helper(ref_of(e))
        emit_line(ref_of(e), "")

    var span_types = collect_span_types(funcs)
    collect_struct_span_types(program, ref_of(span_types))
    collect_variant_span_types(program, ref_of(span_types))

    if program.structs.len > 0 or program.unions.len > 0 or tuple_types.len() > 0 or program.variants.len > 0 or gen_variants.len() > 0:
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
        emit_line(ref_of(e), "")

        emit_enums_block(ref_of(e), program)

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
        var type_order = topo_sort_types(program.structs, ref_of(gen_variants), program.variants)
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
                else:
                    emit_variant(ref_of(e), read(program.variants.data + node.index))
            emit_line(ref_of(e), "")
            toi += 1
        i = 0
        while i < program.unions.len:
            unsafe:
                emit_union(ref_of(e), read(program.unions.data + i))
            emit_line(ref_of(e), "")
            i += 1
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

    # Emit format string runtime helpers when used.
    if uses_format_string(program):
        emit_format_string_helpers(ref_of(e))

    # Emit event runtime helpers when any event method calls are present.
    if uses_event_runtime(program):
        emit_event_helpers(ref_of(e))

    # Emit parallel runtime helpers when any parallel/detach calls are present.
    if uses_parallel_runtime(program):
        emit_parallel_helpers(ref_of(e))

    # Emit builtin helpers (order/equal/hash) when used.
    if uses_builtin_helpers(program):
        emit_builtin_helpers(ref_of(e))

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
            _:
                pass




# =============================================================================
#  String helpers
# =============================================================================

function j2(a: str, b: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf.as_str()

function j3(a: str, b: str, c: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    return buf.as_str()

function j4(a: str, b: str, c: str, d: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    return buf.as_str()

function j5(a: str, b: str, c: str, d: str, e: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    return buf.as_str()

function j6(a: str, b: str, c: str, d: str, e: str, g: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    buf.append(g)
    return buf.as_str()


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
                ir.Stmt.stmt_block as blk:
                    collect_gv_from_stmts(blk.body, seen, result)
                ir.Stmt.stmt_if as iff:
                    collect_gv_from_stmts(iff.then_body, seen, result)
                    collect_gv_from_stmts(iff.else_body, seen, result)
                ir.Stmt.stmt_while as w:
                    collect_gv_from_stmts(w.body, seen, result)
                ir.Stmt.stmt_for as fr:
                    collect_gv_from_stmts(fr.body, seen, result)
                ir.Stmt.stmt_switch as sw:
                    var ci: ptr_uint = 0
                    while ci < sw.cases.len:
                        collect_gv_from_stmts(read(sw.cases.data + ci).body, seen, result)
                        ci += 1
                _:
                    pass
        i += 1


function collect_gv_from_type(ty: types.Type, seen: ref[map_mod.Map[str, bool]], result: ref[vec.Vec[ir.VariantDecl]]) -> void:
    match ty:
        types.Type.ty_generic as g:
            if g.name.equal("span") or g.name.equal("ptr") or g.name.equal("const_ptr") or g.name.equal("ref") or g.name.equal("array"):
                return
            # Only emit variant decls for prelude types; user-generic structs
            # are handled by the lowering's `ensure_generic_struct_decl`.
            if not g.name.equal("Option") and not g.name.equal("Result"):
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
    if name.equal("Option"):
        var sf = vec.Vec[ir.Field].create()
        sf.push(ir.Field(name = "value", ty = first_arg))
        arms.push(GVArmInfo(name = "some", fields = sf.as_span()))
        arms.push(GVArmInfo(name = "none", fields = span[ir.Field]()))
    else if name.equal("Result"):
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
                if call.callee.equal(name):
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
            return naming.qualified_c_name(im.module_name, im.name)
        types.Type.ty_named as n:
            # Bare named types (prelude, local), mirrored as-is.
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
                return c_type(read(nl.base))
        _:
            fatal(j2("c_backend: unsupported C type: ", types.type_to_string(t)))


## The C type name of a positional tuple (`(int, int)` -> `mt_tuple_int_int`).
function tuple_type_name(t: types.Type) -> str:
    var buf = string.String.create()
    buf.append("mt_tuple")
    match t:
        types.Type.ty_tuple as tup:
            var i: ptr_uint = 0
            while i < tup.elements.len:
                buf.append("_")
                unsafe:
                    buf.append(naming.sanitize_identifier(types.type_to_string(read(tup.elements.data + i))))
                i += 1
        _:
            pass
    return buf.as_str()


## C type for a generic instance: span -> mt_span_ELEM, ptr/const_ptr/ref ->
## pointer.  Arrays are declarators (handled by c_declaration), not plain types.
function generic_c_type(name: str, args: span[types.Type]) -> str:
    if name.equal("span") and args.len == 1:
        return span_type_name(unsafe: read(args.data + 0))
    if name.equal("ptr") and args.len == 1:
        return j2(c_type(unsafe: read(args.data + 0)), "*")
    if name.equal("const_ptr") and args.len == 1:
        return j3("const ", c_type(unsafe: read(args.data + 0)), "*")
    if name.equal("ref") and args.len >= 1:
        return j2(c_type(unsafe: read(args.data + (args.len - 1))), "*")
    # str_buffer[N] → mt_str_buffer_N
    if name.equal("str_buffer") and args.len >= 1:
        return j3("mt_str_buffer_", naming.sanitize_identifier(types.type_to_string(unsafe: read(args.data + 0))), "")
    # Generic variant: `<name>_<type0>_<type1>_...`.  The caller module prefix
    # is added by `qualified_c_name` when the type is `ty_imported`.
    if args.len > 0:
        var buf = string.String.create()
        buf.append(name)
        var i: ptr_uint = 0
        while i < args.len:
            buf.append("_")
            unsafe:
                buf.append(naming.sanitize_identifier(types.type_to_string(read(args.data + i))))
            i += 1
        return buf.as_str()
    fatal(c"c_backend: unsupported generic C type")


function span_type_name(element: types.Type) -> str:
    return j2("mt_span_", naming.sanitize_identifier(types.type_to_string(element)))


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
    return name.equal("T") or name.equal("U") or name.equal("K") or name.equal("V") or name.equal("E")


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
                unsafe:
                    emit_line(e, j4("  ", c_declaration(read(tup.elements.data + i), tuple_field_name(i)), ";", ""))
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
            return g.name.equal("array") and g.args.len == 2
        _:
            return false


function is_span_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name.equal("span") and g.args.len == 1
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
    if name.equal("bool"):
        return "bool"
    if name.equal("byte"):
        return "int8_t"
    if name.equal("ubyte"):
        return "uint8_t"
    if name.equal("char"):
        return "char"
    if name.equal("short"):
        return "int16_t"
    if name.equal("ushort"):
        return "uint16_t"
    if name.equal("int"):
        return "int32_t"
    if name.equal("uint"):
        return "uint32_t"
    if name.equal("long"):
        return "int64_t"
    if name.equal("ulong"):
        return "uint64_t"
    if name.equal("ptr_int"):
        return "intptr_t"
    if name.equal("ptr_uint"):
        return "uintptr_t"
    if name.equal("float"):
        return "float"
    if name.equal("double"):
        return "double"
    if name.equal("void"):
        return "void"
    if name.equal("cstr"):
        return "const char*"
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
        return j6(c_type(array_element_type(t)), " ", name, "[", long_to_str(array_length(t)), "]")
    # Function-pointer types need declarator syntax: `ret_type (*name)(...)`.
    # Pointer/reference types: `T*` instead of `ptr_T`.
    # Generic variants: build `name_type0_type1_...` directly.
    match t:
        types.Type.ty_function:
            return c_fn_ptr_declarator(t, name)
        types.Type.ty_generic as g:
            if g.name.equal("ptr") or g.name.equal("ref") and g.args.len >= 1:
                let base = unsafe: c_type(read(g.args.data + (g.args.len - 1)))
                return j3(base, "*", name)
            if g.name.equal("const_ptr") and g.args.len == 1:
                let base = unsafe: c_type(read(g.args.data + 0))
                return j4("const ", base, "*", name)
            if g.name.equal("str_buffer") and g.args.len >= 1:
                let c_name = j3("mt_str_buffer_", naming.sanitize_identifier(types.type_to_string(unsafe: read(g.args.data + 0))), "")
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
                    if c_type(f.ty).equal(outer_c):
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
                    emit_line(e, j6("  struct ", arm.linkage_name, " ", arm.name, ";", ""))
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
            return by_value_dep_key(unsafe: read(nl.base))
        types.Type.ty_generic as g:
            if g.name.equal("array") and g.args.len >= 1:
                return by_value_dep_key(unsafe: read(g.args.data + 0))
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


function type_node_deps(node: TypeNode, structs: span[ir.StructDecl], gen_variants: ref[vec.Vec[ir.VariantDecl]], program_variants: span[ir.VariantDecl]) -> vec.Vec[str]:
    var deps = vec.Vec[str].create()
    if node.kind == 0:
        unsafe:
            collect_field_deps(read(structs.data + node.index).fields, ref_of(deps))
    else if node.kind == 1:
        let gv_ptr = gen_variants.get(node.index) else:
            return deps
        collect_variant_deps(unsafe: read(gv_ptr), ref_of(deps))
    else:
        unsafe:
            collect_variant_deps(read(program_variants.data + node.index), ref_of(deps))
    return deps


function topo_sort_types(structs: span[ir.StructDecl], gen_variants: ref[vec.Vec[ir.VariantDecl]], program_variants: span[ir.VariantDecl]) -> vec.Vec[TypeNode]:
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

    var visited = map_mod.Map[str, bool].create()
    var result = vec.Vec[TypeNode].create()
    i = 0
    while i < nodes.len():
        topo_visit_type(ref_of(nodes), i, structs, gen_variants, program_variants, ref_of(by_key), ref_of(visited), ref_of(result))
        i += 1
    return result


function topo_visit_type(nodes: ref[vec.Vec[TypeNode]], index: ptr_uint, structs: span[ir.StructDecl], gen_variants: ref[vec.Vec[ir.VariantDecl]], program_variants: span[ir.VariantDecl], by_key: ref[map_mod.Map[str, ptr_uint]], visited: ref[map_mod.Map[str, bool]], result: ref[vec.Vec[TypeNode]]) -> void:
    var node: TypeNode
    let node_ptr = nodes.get(index) else:
        return
    unsafe:
        node = read(node_ptr)
    if visited.contains(node.key):
        return
    visited.set(node.key, true)
    var deps = type_node_deps(node, structs, gen_variants, program_variants)
    var di: ptr_uint = 0
    while di < deps.len():
        let dep_ptr = deps.get(di) else:
            break
        unsafe:
            let dep_idx = by_key.get(read(dep_ptr))
            if dep_idx != null:
                topo_visit_type(nodes, read(dep_idx), structs, gen_variants, program_variants, by_key, visited, result)
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
                return render_binary(e, bin.operator, bin.left, bin.right)
            ir.Expr.expr_call as call:
                return render_call(e, call.callee, call.arguments)
            ir.Expr.expr_call_indirect as call:
                return render_indirect_call(e, call.callee, call.arguments)
            ir.Expr.expr_member as member:
                let operator = if pointer_member_receiver(member.receiver): "->" else: "."
                return j3(wrap_member_receiver(e, member.receiver), operator, member.member)
            ir.Expr.expr_aggregate_literal as agg:
                return render_aggregate_literal(e, agg.ty, agg.fields)
            ir.Expr.expr_variant_literal as vl:
                return j4("(", c_type(vl.ty), ")", render_variant_initializer(e, vl.ty, vl.arm_name, vl.fields, true))
            ir.Expr.expr_zero_init as z:
                return render_zero_expression(z.ty)
            ir.Expr.expr_null_literal:
                return "NULL"
            ir.Expr.expr_cast as cast:
                var cast_buf = string.String.create()
                cast_buf.append("(")
                cast_buf.append(c_type(cast.target_type))
                cast_buf.append(")")
                cast_buf.append(wrap_expression(e, cast.expression))
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
            ir.Expr.expr_array_literal as arr:
                return render_array_literal_initializer(e, arr.elements)
            ir.Expr.expr_conditional as cond:
                return j5(wrap_expression(e, cond.condition), " ? ", render_expression(e, cond.then_expression), " : ", render_expression(e, cond.else_expression))
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
    buf.append(naming.sanitize_identifier(types.type_to_string(array_element_type(receiver_type))))
    buf.append("_")
    buf.append(long_to_str(array_length(receiver_type)))
    return buf.as_str()


function checked_span_index_helper_name(receiver_type: types.Type) -> str:
    return j2("mt_checked_span_index_", naming.sanitize_identifier(types.type_to_string(receiver_type)))


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
            buf.append(g.name)
            var i: ptr_uint = 0
            while i < g.args.len:
                buf.append("_")
                unsafe:
                    buf.append(naming.sanitize_identifier(types.type_to_string(read(g.args.data + i))))
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
            if p.name.equal("bool"):
                return "false"
            if p.name.equal("float") or p.name.equal("double"):
                return "0.0"
            if p.name.equal("void"):
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
    var i: ptr_uint = 0
    while i < fields.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            let f = read(fields.data + i)
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
            return g.name.equal("ptr") and g.args.len == 1
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
    var buf = string.String.create()
    let callee_text = unsafe: render_expression(e, callee)
    buf.append(callee_text)
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
            ir.Expr.expr_boolean_literal:
                return text
            ir.Expr.expr_string_literal:
                return text
            ir.Expr.expr_call:
                return text
            _:
                return j3("(", text, ")")


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
    buf.append(c_type(c.ty))
    buf.append(" ")
    buf.append(c.linkage_name)
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
    buf.append(c_type(g.ty))
    buf.append(" ")
    buf.append(g.linkage_name)
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

function uses_format_string(program: ir.Program) -> bool:
    # Detect by checking for mt_format_str_* calls in any function body.
    var i: ptr_uint = 0
    while i < program.functions.len:
        unsafe:
            let f = read(program.functions.data + i)
            if body_calls(f.body, "mt_format_str_make") or body_calls(f.body, "mt_format_str_finish") or body_calls(f.body, "mt_format_str_append_str") or body_calls(f.body, "mt_format_str_append_int") or body_calls(f.body, "mt_format_str_append_float"):
                return true
        i += 1
    return false


function emit_format_string_helpers(e: ref[Emitter]) -> void:
    # Format string builder struct: data pointer, len, capacity.
    emit_line(e, "typedef struct {")
    emit_line(e, "  char* data;")
    emit_line(e, "  uintptr_t len;")
    emit_line(e, "  uintptr_t cap;")
    emit_line(e, "} mt_fmt_builder;")
    emit_line(e, "")
    emit_line(e, "static mt_fmt_builder mt_format_str_make(void) {")
    emit_line(e, "  mt_fmt_builder b;")
    emit_line(e, "  b.data = (char*)malloc(64);")
    emit_line(e, "  b.len = 0;")
    emit_line(e, "  b.cap = 64;")
    emit_line(e, "  return b;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "#define mt_fmt_grow(b, need) do { \\")
    emit_line(e, "  uintptr_t total = (b).len + (need); \\")
    emit_line(e, "  if (total > (b).cap) { \\")
    emit_line(e, "    uintptr_t nc = (b).cap < 16 ? 64 : (b).cap * 2; \\")
    emit_line(e, "    while (nc < total) nc *= 2; \\")
    emit_line(e, "    (b).data = (char*)realloc((b).data, nc); \\")
    emit_line(e, "    (b).cap = nc; \\")
    emit_line(e, "  } \\")
    emit_line(e, "} while(0)")
    emit_line(e, "")
    emit_line(e, "static mt_str mt_format_str_append_str(mt_fmt_builder b, mt_str s) {")
    emit_line(e, "  mt_fmt_grow(b, s.len);")
    emit_line(e, "  memcpy(b.data + b.len, s.data, s.len);")
    emit_line(e, "  b.len += s.len;")
    emit_line(e, "  mt_str r = { b.data, b.len };")
    emit_line(e, "  return r;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static mt_str mt_format_str_append_int(mt_fmt_builder b, int32_t v) {")
    emit_line(e, "  mt_fmt_grow(b, 24);")
    emit_line(e, "  int n = snprintf(b.data + b.len, b.cap - b.len, \"%d\", v);")
    emit_line(e, "  b.len += (uintptr_t)n;")
    emit_line(e, "  mt_str r = { b.data, b.len };")
    emit_line(e, "  return r;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static mt_str mt_format_str_append_float(mt_fmt_builder b, double v) {")
    emit_line(e, "  mt_fmt_grow(b, 48);")
    emit_line(e, "  int n = snprintf(b.data + b.len, b.cap - b.len, \"%g\", v);")
    emit_line(e, "  b.len += (uintptr_t)n;")
    emit_line(e, "  mt_str r = { b.data, b.len };")
    emit_line(e, "  return r;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static mt_str mt_format_str_finish(mt_fmt_builder b) {")
    emit_line(e, "  mt_str r = { b.data, b.len };")
    emit_line(e, "  return r;")
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
    return false


function emit_event_helpers(e: ref[Emitter]) -> void:
    emit_line(e, "typedef enum { mt_event_error_full = 0 } mt_event_error;")
    emit_line(e, "")
    emit_line(e, "static struct mt_subscription mt_event_subscribe(void* slots, uintptr_t capacity, void* listener) {")
    emit_line(e, "  struct mt_subscription out;")
    emit_line(e, "  for (uintptr_t i = 0; i < capacity; i++) {")
    emit_line(e, "    uintptr_t off = i * (2*sizeof(bool) + sizeof(uintptr_t) + sizeof(void*));")
    emit_line(e, "    bool* active = (bool*)((char*)slots + off);")
    emit_line(e, "    if (!*active) {")
    emit_line(e, "      *active = true;")
    emit_line(e, "      ((bool*)((char*)slots + off))[1] = false;")
    emit_line(e, "      *(uintptr_t*)((char*)slots + off + 2*sizeof(bool)) += 1;")
    emit_line(e, "      *(void**)((char*)slots + off + 2*sizeof(bool) + sizeof(uintptr_t)) = listener;")
    emit_line(e, "      out.slot = i;")
    emit_line(e, "      out.generation = *(uintptr_t*)((char*)slots + off + 2*sizeof(bool));")
    emit_line(e, "      return out;")
    emit_line(e, "    }")
    emit_line(e, "  }")
    emit_line(e, "  out.slot = ~(uintptr_t)0;")
    emit_line(e, "  out.generation = 0;")
    emit_line(e, "  return out;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static struct mt_subscription mt_event_subscribe_once(void* slots, uintptr_t capacity, void* listener) {")
    emit_line(e, "  struct mt_subscription out;")
    emit_line(e, "  for (uintptr_t i = 0; i < capacity; i++) {")
    emit_line(e, "    uintptr_t off = i * (2*sizeof(bool) + sizeof(uintptr_t) + sizeof(void*));")
    emit_line(e, "    bool* active = (bool*)((char*)slots + off);")
    emit_line(e, "    if (!*active) {")
    emit_line(e, "      *active = true;")
    emit_line(e, "      ((bool*)((char*)slots + off))[1] = true;")
    emit_line(e, "      *(uintptr_t*)((char*)slots + off + 2*sizeof(bool)) += 1;")
    emit_line(e, "      *(void**)((char*)slots + off + 2*sizeof(bool) + sizeof(uintptr_t)) = listener;")
    emit_line(e, "      out.slot = i;")
    emit_line(e, "      out.generation = *(uintptr_t*)((char*)slots + off + 2*sizeof(bool));")
    emit_line(e, "      return out;")
    emit_line(e, "    }")
    emit_line(e, "  }")
    emit_line(e, "  out.slot = ~(uintptr_t)0;")
    emit_line(e, "  out.generation = 0;")
    emit_line(e, "  return out;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static bool mt_event_unsubscribe(void* slots, uintptr_t capacity, struct mt_subscription sub) {")
    emit_line(e, "  if (sub.slot >= capacity) return false;")
    emit_line(e, "  uintptr_t off = sub.slot * (2*sizeof(bool) + sizeof(uintptr_t) + sizeof(void*));")
    emit_line(e, "  if (!*((bool*)((char*)slots + off))) return false;")
    emit_line(e, "  if (*(uintptr_t*)((char*)slots + off + 2*sizeof(bool)) != sub.generation) return false;")
    emit_line(e, "  *((bool*)((char*)slots + off)) = false;")
    emit_line(e, "  ((bool*)((char*)slots + off))[1] = false;")
    emit_line(e, "  return true;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void mt_event_emit(void* slots, uintptr_t capacity) {")
    emit_line(e, "  for (uintptr_t i = 0; i < capacity; i++) {")
    emit_line(e, "    uintptr_t off = i * (2*sizeof(bool) + sizeof(uintptr_t) + sizeof(void*));")
    emit_line(e, "    if (*((bool*)((char*)slots + off))) {")
    emit_line(e, "      void* listener = *(void**)((char*)slots + off + 2*sizeof(bool) + sizeof(uintptr_t));")
    emit_line(e, "      if (listener) {")
    emit_line(e, "        ((void (*)())listener)();")
    emit_line(e, "        if (((bool*)((char*)slots + off))[1]) {")
    emit_line(e, "          *((bool*)((char*)slots + off)) = false;")
    emit_line(e, "          ((bool*)((char*)slots + off))[1] = false;")
    emit_line(e, "        }")
    emit_line(e, "      }")
    emit_line(e, "    }")
    emit_line(e, "  }")
    emit_line(e, "}")


# =============================================================================
#  Parallel / detach runtime helpers
# =============================================================================

function uses_parallel_runtime(program: ir.Program) -> bool:
    var i: ptr_uint = 0
    while i < program.functions.len:
        unsafe:
            let f = read(program.functions.data + i)
            if body_calls(f.body, "mt_parallel_for") or body_calls(f.body, "mt_spawn_run") or body_calls(f.body, "mt_detach_run") or body_calls(f.body, "mt_detach_join"):
                return true
        i += 1
    return false


function emit_parallel_helpers(e: ref[Emitter]) -> void:
    emit_line(e, "static void mt_parallel_for(intptr_t start, intptr_t end, intptr_t step, void (*worker)(void*, intptr_t, intptr_t), void* data) {")
    emit_line(e, "  for (intptr_t i = start; i < end; i += step) {")
    emit_line(e, "    worker(data, i, end);")
    emit_line(e, "  }")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void mt_spawn_run(void (*work)(void*), void* data) {")
    emit_line(e, "  work(data);")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void mt_spawn_wait(void) {")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void* mt_detach_run(void (*work)(void*), void* data) {")
    emit_line(e, "  work(data);")
    emit_line(e, "  return NULL;")
    emit_line(e, "}")
    emit_line(e, "")
    emit_line(e, "static void mt_detach_join(void* handle) {")
    emit_line(e, "  (void)handle;")
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
