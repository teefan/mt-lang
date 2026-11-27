## Task/parallel C codegen, extracted from c_backend/c_backend.mt.

import std.map as map_mod
import std.vec as vec

import mtc.ir as ir
import mtc.semantic.types as types
import mtc.strings
import mtc.c_backend.c_backend as c_backend


public function uses_parallel_runtime(program: ir.Program) -> bool:
    var i: ptr_uint = 0
    while i < program.functions.len:
        unsafe:
            let f = read(program.functions.data + i)
            if c_backend.body_calls(
                f.body,
                "mt_parallel_for"
            ) or c_backend.body_calls(f.body, "mt_spawn_all") or c_backend.body_calls(f.body, "mt_detach_run") or c_backend.body_calls(
                f.body,
                "mt_detach_join"
            ):
                return true
        i += 1
    return false


public function collect_task_type_set(
    program: ir.Program,
    seen: ref[map_mod.Map[str, bool]],
    task_elements: ref[map_mod.Map[str, types.Type]]
) -> void:
    var i: ptr_uint = 0
    while i < program.functions.len:
        unsafe:
            let f = read(program.functions.data + i)
            collect_task_type(program, seen, task_elements, f.return_type)
            var pi: ptr_uint = 0
            while pi < f.params.len:
                collect_task_type(program, seen, task_elements, read(f.params.data + pi).ty)
                pi += 1
        i += 1
    i = 0
    while i < program.structs.len:
        unsafe:
            let s = read(program.structs.data + i)
            var fi: ptr_uint = 0
            while fi < s.fields.len:
                collect_task_type(program, seen, task_elements, read(s.fields.data + fi).ty)
                fi += 1
        i += 1
    i = 0
    while i < program.type_aliases.len:
        unsafe:
            collect_task_type(program, seen, task_elements, read(program.type_aliases.data + i).target_type)
        i += 1
    i = 0
    while i < program.functions.len:
        unsafe:
            let fun = read(program.functions.data + i)
            task_scan_stmts(program, fun.body, seen, task_elements)
        i += 1


public function emit_task_forward_decls(e: ref[c_backend.Emitter], seen: ref[map_mod.Map[str, bool]]) -> void:
    var keys = seen.keys()
    while true:
        let kp = keys.next() else:
            break
        let c_name = unsafe: read(kp)
        c_backend.emit_line(e, strings.join_five("typedef struct ", c_name, " ", c_name, ";"))
    if seen.len() > 0:
        c_backend.emit_line(e, "")


public function task_scan_stmts(
    program: ir.Program,
    body: span[ir.Stmt],
    seen: ref[map_mod.Map[str, bool]],
    elements: ref[map_mod.Map[str, types.Type]]
) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            task_scan_stmt(program, body.data + i, seen, elements)
        i += 1


public function task_scan_stmt(
    program: ir.Program,
    sp: ptr[ir.Stmt],
    seen: ref[map_mod.Map[str, bool]],
    elements: ref[map_mod.Map[str, types.Type]]
) -> void:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_return as r:
                let value = r.value else:
                    return
                task_scan_expr(program, value, seen, elements)
            ir.Stmt.stmt_local as loc:
                task_scan_expr(program, loc.value, seen, elements)
            ir.Stmt.stmt_assignment as asg:
                task_scan_expr(program, asg.target, seen, elements)
                task_scan_expr(program, asg.value, seen, elements)
            ir.Stmt.stmt_expression as ex:
                task_scan_expr(program, ex.expression, seen, elements)
            ir.Stmt.stmt_block as blk:
                task_scan_stmts(program, blk.body, seen, elements)
            ir.Stmt.stmt_if as iff:
                task_scan_expr(program, iff.condition, seen, elements)
                task_scan_stmts(program, iff.then_body, seen, elements)
                task_scan_stmts(program, c_backend.else_stmts_or_empty(iff.else_body), seen, elements)
            ir.Stmt.stmt_while as w:
                task_scan_expr(program, w.condition, seen, elements)
                task_scan_stmts(program, w.body, seen, elements)
            ir.Stmt.stmt_for as f:
                task_scan_stmt(program, f.init, seen, elements)
                task_scan_expr(program, f.condition, seen, elements)
                task_scan_stmt(program, f.post, seen, elements)
                task_scan_stmts(program, f.body, seen, elements)
            ir.Stmt.stmt_switch as sw:
                task_scan_expr(program, sw.expression, seen, elements)
                var ci: ptr_uint = 0
                while ci < sw.cases.len:
                    task_scan_stmts(program, read(sw.cases.data + ci).body, seen, elements)
                    ci += 1
            _:
                pass


public function task_scan_expr(
    program: ir.Program,
    ep: ptr[ir.Expr],
    seen: ref[map_mod.Map[str, bool]],
    elements: ref[map_mod.Map[str, types.Type]]
) -> void:
    unsafe:
        match read(ep):
            ir.Expr.expr_binary as bin:
                collect_task_type(program, seen, elements, bin.ty)
                task_scan_expr(program, bin.left, seen, elements)
                task_scan_expr(program, bin.right, seen, elements)
            ir.Expr.expr_unary as un:
                collect_task_type(program, seen, elements, un.ty)
                task_scan_expr(program, un.operand, seen, elements)
            ir.Expr.expr_conditional as cond:
                collect_task_type(program, seen, elements, cond.ty)
                task_scan_expr(program, cond.condition, seen, elements)
                task_scan_expr(program, cond.then_expression, seen, elements)
                task_scan_expr(program, cond.else_expression, seen, elements)
            ir.Expr.expr_call as call:
                collect_task_type(program, seen, elements, call.ty)
                var i: ptr_uint = 0
                while i < call.arguments.len:
                    task_scan_expr(program, call.arguments.data + i, seen, elements)
                    i += 1
            ir.Expr.expr_call_indirect as ci:
                collect_task_type(program, seen, elements, ci.ty)
                var i: ptr_uint = 0
                while i < ci.arguments.len:
                    task_scan_expr(program, ci.arguments.data + i, seen, elements)
                    i += 1
            ir.Expr.expr_member as member:
                collect_task_type(program, seen, elements, member.ty)
                task_scan_expr(program, member.receiver, seen, elements)
            ir.Expr.expr_index as ix:
                collect_task_type(program, seen, elements, ix.ty)
                task_scan_expr(program, ix.receiver, seen, elements)
                task_scan_expr(program, ix.index, seen, elements)
            ir.Expr.expr_checked_index as ix:
                collect_task_type(program, seen, elements, ix.ty)
                task_scan_expr(program, ix.receiver, seen, elements)
                task_scan_expr(program, ix.index, seen, elements)
            ir.Expr.expr_checked_span_index as ix:
                collect_task_type(program, seen, elements, ix.ty)
                task_scan_expr(program, ix.receiver, seen, elements)
                task_scan_expr(program, ix.index, seen, elements)
            ir.Expr.expr_address_of as addr:
                collect_task_type(program, seen, elements, addr.ty)
                task_scan_expr(program, addr.expression, seen, elements)
            ir.Expr.expr_cast as cast:
                collect_task_type(program, seen, elements, cast.ty)
                task_scan_expr(program, cast.expression, seen, elements)
            ir.Expr.expr_reinterpret as rin:
                let rp = unsafe: read(rin.payload)
                collect_task_type(program, seen, elements, rp.ty)
                task_scan_expr(program, rp.expression, seen, elements)
            ir.Expr.expr_aggregate_literal as agg:
                collect_task_type(program, seen, elements, agg.ty)
                var i: ptr_uint = 0
                while i < agg.fields.len:
                    task_scan_expr(program, read(agg.fields.data + i).value, seen, elements)
                    i += 1
            ir.Expr.expr_variant_literal as vl:
                collect_task_type(program, seen, elements, vl.ty)
                var i: ptr_uint = 0
                while i < vl.fields.len:
                    task_scan_expr(program, read(vl.fields.data + i).value, seen, elements)
                    i += 1
            ir.Expr.expr_array_literal as arr:
                collect_task_type(program, seen, elements, arr.ty)
                var i: ptr_uint = 0
                while i < arr.elements.len:
                    task_scan_expr(program, arr.elements.data + i, seen, elements)
                    i += 1
            ir.Expr.expr_name as nm:
                collect_task_type(program, seen, elements, nm.ty)
            ir.Expr.expr_sizeof as sz:
                collect_task_type(program, seen, elements, sz.ty)
            ir.Expr.expr_alignof as al:
                collect_task_type(program, seen, elements, al.ty)
            ir.Expr.expr_offsetof as of:
                collect_task_type(program, seen, elements, of.ty)
            ir.Expr.expr_integer_literal as il:
                collect_task_type(program, seen, elements, il.ty)
            ir.Expr.expr_float_literal as fl:
                collect_task_type(program, seen, elements, fl.ty)
            ir.Expr.expr_string_literal as sl:
                collect_task_type(program, seen, elements, sl.ty)
            ir.Expr.expr_boolean_literal as bl:
                collect_task_type(program, seen, elements, bl.ty)
            ir.Expr.expr_null_literal as nl:
                collect_task_type(program, seen, elements, nl.ty)
            ir.Expr.expr_zero_init as zi:
                collect_task_type(program, seen, elements, zi.ty)
            _:
                pass


## Collect a Task type element from a type reference.  When `t` is a
## `Task[T]` or has Task-typed sub-expressions, adds the concrete Task
## struct name to `seen` and records the element type.
public function collect_task_type(
    program: ir.Program,
    seen: ref[map_mod.Map[str, bool]],
    elements: ref[map_mod.Map[str, types.Type]],
    t: types.Type
) -> void:
    match t:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.name == "Task" and g_bp.args.len == 1:
                let elem = unsafe: read(g_bp.args.data + 0)
                var task_args = vec.Vec[types.Type].create()
                task_args.push(elem)
                let c_name = c_backend.generic_c_type("Task", task_args.as_span())
                if not seen.contains(c_name):
                    seen.set(c_name, true)
                    elements.set(c_name, elem)
            # Also scan nested generic args for Task types.
            var ai: ptr_uint = 0
            while ai < g_bp.args.len:
                collect_task_type(program, seen, elements, unsafe: read(g_bp.args.data + ai))
                ai += 1
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if n_np.name.starts_with("mt_task_"):
                if not seen.contains(n_np.name):
                    seen.set(n_np.name, true)
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            if im_bp.name.starts_with("mt_task_"):
                if not seen.contains(im_bp.name):
                    seen.set(im_bp.name, true)
        _:
            pass


public function emit_task_struct_type(e: ref[c_backend.Emitter], c_name: str, elem: types.Type) -> void:
    let is_void = c_backend.is_void_type(elem)
    let type_str = c_backend.c_type(elem)
    c_backend.emit_line(e, strings.join_three("struct ", c_name, " {"))
    if not is_void:
        c_backend.emit_line(e, strings.join_three("  ", type_str, " value;"))
    c_backend.emit_line(e, "  void* frame;")
    c_backend.emit_line(e, "  bool (*ready)(void*);")
    c_backend.emit_line(e, "  void (*set_waiter)(void*, void*, void(*)(void*));")
    c_backend.emit_line(e, "  void (*release)(void*);")

    # `take_result` is present for `Task[void]` too (it returns void); the async
    # runtime's `run_on`/`wait_on` call it unconditionally.
    if is_void:
        c_backend.emit_line(e, "  void (*take_result)(void*);")
    else:
        c_backend.emit_line(e, strings.join_three("  ", type_str, " (*take_result)(void*);"))
    c_backend.emit_line(e, "  void (*cancel)(void*);")
    c_backend.emit_line(e, "};")
    c_backend.emit_line(e, strings.join_three("typedef struct ", c_name, strings.join_two(" ", strings.join_two(c_name, ";"))))
    c_backend.emit_line(e, "")


public function emit_parallel_helpers(e: ref[c_backend.Emitter]) -> void:
    c_backend.emit_line(e, "typedef struct {")
    c_backend.emit_line(e, "  void (*work)(void* data, int64_t start, int64_t end);")
    c_backend.emit_line(e, "  void* data;")
    c_backend.emit_line(e, "  int64_t start;")
    c_backend.emit_line(e, "  int64_t end;")
    c_backend.emit_line(e, "} mt_pfor_chunk;")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static void mt_pfor_runner(void* arg) {")
    c_backend.emit_line(e, "  mt_pfor_chunk* chunk = (mt_pfor_chunk*)arg;")
    c_backend.emit_line(e, "  chunk->work(chunk->data, chunk->start, chunk->end);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(
        e,
        "static void mt_parallel_for(void (*work)(void* data, int64_t start, int64_t end), void* data, int64_t count) {"
    )
    c_backend.emit_line(e, "  if (count <= 0) return;")
    c_backend.emit_line(e, "  if (count > INT64_MAX / 64) mt_fatal(\"parallel for range is too large\");")
    c_backend.emit_line(e, "  uv_cpu_info_t* cpu_info;")
    c_backend.emit_line(e, "  int ncpu = 1;")
    c_backend.emit_line(e, "  if (uv_cpu_info(&cpu_info, &ncpu) == 0) {")
    c_backend.emit_line(e, "    uv_free_cpu_info(cpu_info, ncpu);")
    c_backend.emit_line(e, "  }")
    c_backend.emit_line(e, "  if (ncpu < 1) ncpu = 1;")
    c_backend.emit_line(e, "  if (ncpu > 64) ncpu = 64;")
    c_backend.emit_line(e, "  if (count < (int64_t)ncpu) ncpu = (int)count;")
    c_backend.emit_line(e, "  int64_t chunk_size = count / ncpu + (count % ncpu != 0 ? 1 : 0);")
    c_backend.emit_line(e, "  mt_pfor_chunk chunks[64];")
    c_backend.emit_line(e, "  uv_thread_t threads[64];")
    c_backend.emit_line(e, "  int nworkers = 0;")
    c_backend.emit_line(e, "  for (int t = 1; t < ncpu; t++) {")
    c_backend.emit_line(e, "    int64_t s = t * chunk_size;")
    c_backend.emit_line(e, "    int64_t e = s + chunk_size;")
    c_backend.emit_line(e, "    if (e > count) e = count;")
    c_backend.emit_line(e, "    if (s >= count) break;")
    c_backend.emit_line(e, "    chunks[nworkers].work = work;")
    c_backend.emit_line(e, "    chunks[nworkers].data = data;")
    c_backend.emit_line(e, "    chunks[nworkers].start = s;")
    c_backend.emit_line(e, "    chunks[nworkers].end = e;")
    c_backend.emit_line(
        e,
        "    if (uv_thread_create(&threads[nworkers], mt_pfor_runner, &chunks[nworkers]) == 0) {"
    )
    c_backend.emit_line(e, "      nworkers++;")
    c_backend.emit_line(e, "    } else {")
    c_backend.emit_line(e, "      work(data, s, e);")
    c_backend.emit_line(e, "    }")
    c_backend.emit_line(e, "  }")
    c_backend.emit_line(e, "  int64_t first_end = chunk_size < count ? chunk_size : count;")
    c_backend.emit_line(e, "  work(data, 0, first_end);")
    c_backend.emit_line(e, "  for (int t = 0; t < nworkers; t++) {")
    c_backend.emit_line(e, "    uv_thread_join(&threads[t]);")
    c_backend.emit_line(e, "  }")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "typedef struct {")
    c_backend.emit_line(e, "  void (*work)(void* data);")
    c_backend.emit_line(e, "  void* data;")
    c_backend.emit_line(e, "} mt_spawn_item;")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static void mt_spawn_item_runner(void* arg) {")
    c_backend.emit_line(e, "  mt_spawn_item* item = (mt_spawn_item*)arg;")
    c_backend.emit_line(e, "  item->work(item->data);")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static void mt_spawn_all(mt_spawn_item* items, int count) {")
    c_backend.emit_line(e, "  if (count <= 0) return;")
    c_backend.emit_line(e, "  if (count > 64) mt_fatal(\"parallel block supports at most 64 statements\");")
    c_backend.emit_line(e, "  uv_thread_t threads[64];")
    c_backend.emit_line(e, "  int nworkers = 0;")
    c_backend.emit_line(e, "  for (int t = 1; t < count; t++) {")
    c_backend.emit_line(e, "    if (uv_thread_create(&threads[nworkers], mt_spawn_item_runner, &items[t]) == 0) {")
    c_backend.emit_line(e, "      nworkers++;")
    c_backend.emit_line(e, "    } else {")
    c_backend.emit_line(e, "      items[t].work(items[t].data);")
    c_backend.emit_line(e, "    }")
    c_backend.emit_line(e, "  }")
    c_backend.emit_line(e, "  items[0].work(items[0].data);")
    c_backend.emit_line(e, "  for (int t = 0; t < nworkers; t++) {")
    c_backend.emit_line(e, "    uv_thread_join(&threads[t]);")
    c_backend.emit_line(e, "  }")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "typedef struct {")
    c_backend.emit_line(e, "  uv_thread_t thread;")
    c_backend.emit_line(e, "  int started;")
    c_backend.emit_line(e, "} mt_detach_handle;")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static void* mt_detach_run(void (*work)(void*), void* cap) {")
    c_backend.emit_line(e, "  mt_detach_handle* h = (mt_detach_handle*)malloc(sizeof(mt_detach_handle));")
    c_backend.emit_line(e, "  if (h == NULL) mt_fatal(\"detach allocation failed\");")
    c_backend.emit_line(e, "  if (uv_thread_create(&h->thread, work, cap) == 0) {")
    c_backend.emit_line(e, "    h->started = 1;")
    c_backend.emit_line(e, "  } else {")
    c_backend.emit_line(e, "    h->started = 0;")
    c_backend.emit_line(e, "    work(cap);")
    c_backend.emit_line(e, "  }")
    c_backend.emit_line(e, "  return h;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static void mt_detach_join(void* handle) {")
    c_backend.emit_line(e, "  if (!handle) return;")
    c_backend.emit_line(e, "  mt_detach_handle* h = (mt_detach_handle*)handle;")
    c_backend.emit_line(e, "  if (h->started) uv_thread_join(&h->thread);")
    c_backend.emit_line(e, "  free(h);")
    c_backend.emit_line(e, "}")
