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


public function generate_c(program: ir.Program) -> string.String:
    var e = Emitter(
        buffer = string.String.create(),
        str_lit_map = map_mod.Map[str, str].create(),
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
    let use_fatal = uses_fatal_helper(funcs)
    let use_string_view = uses_string_view(funcs, has_str_literals) or use_fatal
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

    if program.structs.len > 0 or program.unions.len > 0:
        var sorted_structs = topo_sort_structs(program.structs)
        let sorted = sorted_structs.as_span()

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
        emit_line(ref_of(e), "")

        emit_enums_block(ref_of(e), program)

        i = 0
        while i < sorted.len:
            unsafe:
                emit_struct(ref_of(e), read(sorted.data + i))
            emit_line(ref_of(e), "")
            i += 1
        i = 0
        while i < program.unions.len:
            unsafe:
                emit_union(ref_of(e), read(program.unions.data + i))
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

    if has_str_literals:
        i = 0
        while i < str_lits.len():
            let value_ptr = str_lits.get(i) else:
                break
            unsafe:
                emit_line(ref_of(e), emit_str_literal_constant(read(value_ptr), i))
            i += 1
        emit_line(ref_of(e), "")

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


function emit_str_literal_constant(value: str, index: ptr_uint) -> str:
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
## and the string-view type must be emitted).
function uses_fatal_helper(functions: span[ir.Function]) -> bool:
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
        types.Type.ty_imported as im:
            return naming.qualified_c_name(im.module_name, im.name)
        _:
            fatal(c"c_backend Phase 2: unsupported C type")


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
    fatal(c"c_backend Phase 2: unsupported primitive type")


## A scalar declaration `TYPE NAME` (Phase 2 has no arrays/pointers/functions).
function c_declaration(t: types.Type, name: str) -> str:
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
            emit_line(e, j6("  ", m.linkage_name, " = ", emit_expression(e, m.value), suffix, ""))
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
    emit_line(e, j2(function_signature(func), " {"))
    emit_stmts(e, func.body, 1)
    emit_line(e, "}")


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
                emit_line(e, j4(indent, "return ", emit_expression(e, value), ";"))
            ir.Stmt.stmt_local as loc:
                emit_line(e, j5(indent, c_declaration(loc.ty, loc.linkage_name), " = ", emit_initializer(e, loc.value), ";"))
            ir.Stmt.stmt_assignment as asg:
                emit_line(e, j6(indent, emit_expression(e, asg.target), " ", asg.operator, " ", j2(emit_expression(e, asg.value), ";")))
            ir.Stmt.stmt_expression as ex:
                emit_line(e, j3(indent, emit_expression(e, ex.expression), ";"))
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
                emit_line(e, j4(indent, "while (", emit_expression(e, w.condition), ") {"))
                emit_stmts(e, w.body, level + 1)
                emit_line(e, j2(indent, "}"))
            ir.Stmt.stmt_for as f:
                var header = string.String.create()
                header.append(indent)
                header.append("for (")
                header.append(emit_for_clause(e, f.init))
                header.append("; ")
                header.append(emit_expression(e, f.condition))
                header.append("; ")
                header.append(emit_for_clause(e, f.post))
                header.append(") {")
                emit_line(e, header.as_str())
                emit_stmts(e, f.body, level + 1)
                emit_line(e, j2(indent, "}"))
            ir.Stmt.stmt_switch as sw:
                emit_switch(e, sw.expression, sw.cases, sw.exhaustive, level)
            _:
                fatal(c"c_backend Phase 2: unsupported statement")


## Emit a `switch`.  Non-default cases are `case VALUE: { body [break;] }`; a `_`
## arm is `default: { body [break;] }`; and an exhaustive switch with no explicit
## default gets `default: __builtin_unreachable();`.  Mirrors the switch path in
## c_backend/statements.rb.
function emit_switch(e: ref[Emitter], expression: ptr[ir.Expr], cases: span[ir.SwitchCase], exhaustive: bool, level: ptr_uint) -> void:
    let indent = indent_c(level)
    let case_indent = indent_c(level + 1)
    emit_line(e, j4(indent, "switch (", emit_expression(e, expression), ") {"))
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
                    fatal(c"c_backend Phase 2: non-default switch case missing value")
                emit_line(e, j4(case_indent, "case ", emit_expression(e, value), ": {"))
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
    emit_line(e, j4(indent, "if (", emit_expression(e, condition), ") {"))
    emit_stmts(e, then_body, level + 1)
    emit_else(e, else_body, level)


function emit_else(e: ref[Emitter], else_body: span[ir.Stmt], level: ptr_uint) -> void:
    let indent = indent_c(level)
    if else_body.len == 1:
        unsafe:
            match read(else_body.data + 0):
                ir.Stmt.stmt_if as nested:
                    emit_line(e, j4(indent, "} else if (", emit_expression(e, nested.condition), ") {"))
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
function emit_for_clause(e: ref[Emitter], sp: ptr[ir.Stmt]) -> str:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_local as loc:
                return j5(c_declaration(loc.ty, loc.linkage_name), " = ", emit_initializer(e, loc.value), "", "")
            ir.Stmt.stmt_assignment as asg:
                return j5(emit_expression(e, asg.target), " ", asg.operator, " ", emit_expression(e, asg.value))
            ir.Stmt.stmt_expression as ex:
                return emit_expression(e, ex.expression)
            _:
                fatal(c"c_backend Phase 2: unsupported for-loop clause")


# =============================================================================
#  Expression emission (mirrors c_backend/expressions.rb)
# =============================================================================

function emit_expression(e: ref[Emitter], ep: ptr[ir.Expr]) -> str:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as n:
                return n.name
            ir.Expr.expr_integer_literal as lit:
                return long_to_str(lit.value)
            ir.Expr.expr_boolean_literal as b:
                return if b.value: "true" else: "false"
            ir.Expr.expr_string_literal as s:
                return emit_string_literal(e, s.value, s.cstring)
            ir.Expr.expr_unary as un:
                if un.operator == "not":
                    return j2("!", wrap_expression(e, un.operand))
                return j2(un.operator, wrap_expression(e, un.operand))
            ir.Expr.expr_binary as bin:
                if is_str_equality(bin.operator, bin.left, bin.right):
                    let call = j5("mt_str_equal(", emit_expression(e, bin.left), ", ", emit_expression(e, bin.right), ")")
                    if bin.operator == "!=":
                        return j2("!", call)
                    return call
                return emit_binary(e, bin.operator, bin.left, bin.right)
            ir.Expr.expr_call as call:
                return emit_call(e, call.callee, call.arguments)
            ir.Expr.expr_member as member:
                let operator = if pointer_member_receiver(member.receiver): "->" else: "."
                return j3(wrap_member_receiver(e, member.receiver), operator, member.member)
            ir.Expr.expr_aggregate_literal as agg:
                return emit_aggregate_literal(e, agg.ty, agg.fields)
            ir.Expr.expr_zero_init as z:
                return emit_zero_expression(z.ty)
            _:
                fatal(c"c_backend Phase 3: unsupported expression")


## The initializer form of a value (aggregate literals use `{ ... }` without a
## compound-literal cast); everything else is an ordinary expression.  Mirrors
## c_backend/expressions.rb emit_initializer.
function emit_initializer(e: ref[Emitter], ep: ptr[ir.Expr]) -> str:
    unsafe:
        match read(ep):
            ir.Expr.expr_aggregate_literal as agg:
                return emit_aggregate_initializer(e, agg.fields)
            ir.Expr.expr_zero_init as z:
                return emit_zero_initializer(z.ty)
            _:
                return emit_expression(e, ep)


## The zero value of a type in initializer position (mirrors
## c_backend/expressions.rb emit_zero_initializer).
function emit_zero_initializer(t: types.Type) -> str:
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
function emit_zero_expression(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive:
            return emit_zero_initializer(t)
        types.Type.ty_str:
            return j4("(", c_type(t), ")", " { 0 }")
        _:
            return j4("(", c_declaration(t, ""), ") ", emit_zero_initializer(t))


function emit_aggregate_initializer(e: ref[Emitter], fields: span[ir.AggregateField]) -> str:
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
            buf.append(emit_initializer(e, f.value))
        i += 1
    buf.append(" }")
    return buf.as_str()


function emit_aggregate_literal(e: ref[Emitter], ty: types.Type, fields: span[ir.AggregateField]) -> str:
    return j4("(", c_type(ty), ")", emit_aggregate_initializer(e, fields))


## `receiver.field` receivers that are postfix (name/member/index/call) need no
## parentheses; anything else is wrapped.  Mirrors wrap_member_receiver.
function wrap_member_receiver(e: ref[Emitter], ep: ptr[ir.Expr]) -> str:
    if is_postfix_expr(ep):
        return emit_expression(e, ep)
    return j3("(", emit_expression(e, ep), ")")


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


function emit_string_literal(e: ref[Emitter], value: str, cstring: bool) -> str:
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


function emit_call(e: ref[Emitter], callee: str, arguments: span[ir.Expr]) -> str:
    var buf = string.String.create()
    buf.append(callee)
    buf.append("(")
    var i: ptr_uint = 0
    while i < arguments.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(emit_expression(e, arguments.data + i))
        i += 1
    buf.append(")")
    return buf.as_str()


function emit_binary(e: ref[Emitter], operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr]) -> str:
    let parent = binary_precedence(operator)
    let left_text = emit_binary_operand(e, left, parent, false)
    let right_text = emit_binary_operand(e, right, parent, true)
    return j5(left_text, " ", c_operator(operator), " ", right_text)


function emit_binary_operand(e: ref[Emitter], ep: ptr[ir.Expr], parent_precedence: int, is_right: bool) -> str:
    let text = emit_expression(e, ep)
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
    let text = emit_expression(e, ep)
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
    fatal(c"c_backend Phase 2: unsupported binary operator")


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
