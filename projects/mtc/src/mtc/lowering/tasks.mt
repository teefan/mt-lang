## Task and parallel-for lowering — `Task[T]` types and constructors, task
## value unwrapping, and parallel-for statement lowering.  Extracted from
## lowering/lowering.mt.

import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types

import mtc.lowering.control_flow as control_flow
import mtc.lowering.lowering as lowering
import mtc.lowering.utils as utils
import mtc.strings


public function make_task_type(inner: types.Type) -> types.Type:
    var args = vec.Vec[types.Type].create()
    args.push(inner)
    return types.generic_type(name = "Task", args = args.as_span())


public function make_task_literal(inner: ptr[ir.Expr]) -> ptr[ir.Expr]:
    let inner_ty = lowering.ir_expr_type(inner)
    let task_ty = make_task_type(inner_ty)
    var fields = vec.Vec[ir.AggregateField].create()
    let is_void = is_void_type_lowered(inner_ty)
    let void_ptr = types.primitive("ptr_uint")
    if not is_void:
        fields.push(ir.AggregateField(name = "value", value = inner))
    fields.push(ir.AggregateField(name = "frame", value = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = void_ptr))))
    fields.push(ir.AggregateField(name = "ready", value = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = void_ptr))))
    fields.push(ir.AggregateField(
        name = "set_waiter",
        value = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = void_ptr))
    ))
    fields.push(ir.AggregateField(name = "release", value = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = void_ptr))))
    fields.push(ir.AggregateField(
        name = "take_result",
        value = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = void_ptr))
    ))
    fields.push(ir.AggregateField(name = "cancel", value = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = void_ptr))))
    return lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = task_ty, fields = fields.as_span()))


public function is_void_type_lowered(t: types.Type) -> bool:
    match t:
        types.Type.ty_primitive as p:
            return p.name == "void"
        _:
            return false


public function unwrap_task_value(task_expr: ptr[ir.Expr]) -> ptr[ir.Expr]:
    var inner_ty = types.primitive("void")
    let task_ty = lowering.ir_expr_type(task_expr)
    match task_ty:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.name == "Task" and g_bp.args.len == 1:
                inner_ty = unsafe: read(g_bp.args.data + 0)
        _:
            pass
    return lowering.alloc_expr(ir.Expr.expr_member(receiver = task_expr, member = "value", ty = inner_ty))


public function lower_task_constructor(
    ctx: ref[lowering.LoweringContext],
    type_args: span[ast.TypeArgument],
    call_args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    var task_inner = ctx.void_ty
    if type_args.len >= 1:
        task_inner = lowering.resolve_type_ref(ctx, unsafe: read(type_args.data + 0).value)
    let task_ty = make_task_type(task_inner)
    var fields = vec.Vec[ir.AggregateField].create()
    var i: ptr_uint = 0
    while i < call_args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(call_args.data + i)
        var val = lowering.lower_expr(ctx, arg.arg_value)
        var fname = if arg.arg_name.is_some(): arg.arg_name.unwrap() else: strings.join_two("_", lowering.pw1_str(i))
        fields.push(ir.AggregateField(name = fname, value = val))
        i += 1
    return lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = task_ty, fields = fields.as_span()))


public function lower_multi_for(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    bindings: span[ast.ForBinding],
    iterables: span[ast.Expr],
    body_ptr: ptr[ast.Stmt]?
) -> void:
    let len = bindings.len
    if len == 0 or iterables.len == 0:
        return
    let ptr_uint_ty = types.primitive("ptr_uint")
    # The host's `lower_parallel_collection_for_stmt`: prepare/lower each
    # iterable first, then allocate its `__mt_for_items_N` temp and the shared
    # `__mt_for_index_N` (the fresh-temp counter order).
    var items_names = vec.Vec[str].create()
    var iterable_types = vec.Vec[types.Type].create()
    var elem_types = vec.Vec[types.Type].create()
    var lowered_iterables = vec.Vec[ptr[ir.Expr]].create()
    var bi: ptr_uint = 0
    while bi < len:
        let ib = unsafe: iterables.data + bi
        let iterable_type = lowering.index_receiver_type(ctx, ib)
        let element_type = lowering.generic_first_arg(iterable_type)
        let lowered = lowering.lower_expr(ctx, ib)
        let items_c = lowering.fresh_c_temp_name(ctx, "for_items")
        items_names.push(items_c)
        iterable_types.push(iterable_type)
        elem_types.push(element_type)
        lowered_iterables.push(lowered)
        bi += 1
    let index_c = lowering.fresh_c_temp_name(ctx, "for_index")

    let saved_break = ctx.loop_break_label
    let saved_continue = ctx.loop_continue_label
    let saved_continue_native = ctx.loop_continue_native
    let saved_break_native = ctx.loop_break_native
    let cl = lowering.fresh_c_temp_name(ctx, "loop_continue")
    let bl = lowering.fresh_c_temp_name(ctx, "loop_break")
    ctx.loop_break_label = bl
    ctx.loop_continue_label = cl
    ctx.loop_continue_native = true
    ctx.loop_break_native = true

    let saved_loop_depth = ctx.loop_defer_depth
    ctx.loop_defer_depth = ctx.defer_stack.len()
    let body_span = lowering.lower_block(ctx, body_ptr)
    let index_ref = lowering.alloc_expr(ir.Expr.expr_name(
        name = index_c,
        ty = ptr_uint_ty,
        pointer = Option[bool].some(value = false)
    ))

    var loop_body = vec.Vec[ir.Stmt].create()
    bi = 0
    while bi < len:
        var bname: str
        unsafe:
            bname = read(bindings.data + bi).name
        let binding_c = utils.c_local_name(bname)
        let elem_ptr = elem_types.get(bi) else:
            fatal(c"lower_multi_for: missing elem type")
        let elem_ty = unsafe: read(elem_ptr)
        let items_name_ptr = items_names.get(bi) else:
            fatal(c"lower_multi_for: missing items name")
        let items_name = unsafe: read(items_name_ptr)
        let iterable_ty_ptr = iterable_types.get(bi) else:
            fatal(c"lower_multi_for: missing iterable type")
        let iterable_ty = unsafe: read(iterable_ty_ptr)
        let items_ref = lowering.alloc_expr(ir.Expr.expr_name(
            name = items_name,
            ty = iterable_ty,
            pointer = Option[bool].some(value = false)
        ))
        var item_val: ptr[ir.Expr]
        if lowering.is_array_type(iterable_ty):
            item_val = lowering.alloc_expr(ir.Expr.expr_index(receiver = items_ref, index = index_ref, ty = elem_ty))
        else:
            var ptr_args = vec.Vec[types.Type].create()
            ptr_args.push(elem_ty)
            let data_ty = types.generic_type(name = "ptr", args = ptr_args.as_span())
            let data_ref = lowering.alloc_expr(ir.Expr.expr_member(receiver = items_ref, member = "data", ty = data_ty))
            item_val = lowering.alloc_expr(ir.Expr.expr_index(receiver = data_ref, index = index_ref, ty = elem_ty))
        loop_body.push(ir.Stmt.stmt_local(
            name = bname,
            linkage_name = binding_c,
            ty = elem_ty,
            value = item_val,
            line = 0,
            source_path = ""
        ))
        bi += 1
    var si: ptr_uint = 0
    while si < body_span.len:
        unsafe:
            loop_body.push(read(body_span.data + si))
        si += 1
    if lowering.contains_label_target(loop_body.as_span(), cl):
        loop_body.push(ir.Stmt.stmt_label(name = cl))

    # The first iterable's length is the loop bound; every other iterable must
    # match it (the host's `length_checks`).
    let first_name_ptr = items_names.get(0) else:
        fatal(c"lower_multi_for: missing first items name")
    let first_ty_ptr = iterable_types.get(0) else:
        fatal(c"lower_multi_for: missing first iterable type")
    let stop_value = multi_for_stop(unsafe: read(first_name_ptr), unsafe: read(first_ty_ptr))
    var length_checks = vec.Vec[ir.Stmt].create()
    bi = 1
    while bi < len:
        let name_ptr = items_names.get(bi) else:
            break
        let ty_ptr = iterable_types.get(bi) else:
            break
        let other_stop = multi_for_stop(unsafe: read(name_ptr), unsafe: read(ty_ptr))
        let cond = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "!=",
            left = other_stop,
            right = stop_value,
            ty = ctx.bool_ty
        ))
        let msg = lowering.alloc_expr(ir.Expr.expr_string_literal(
            value = "parallel for iterables must have matching lengths",
            ty = types.Type.ty_str,
            cstring = false
        ))
        let fatal_call = lowering.alloc_expr(ir.Expr.expr_call(
            callee = "mt_fatal_str",
            arguments = lowering.single_expr_span(msg),
            ty = ctx.void_ty
        ))
        var then_body = vec.Vec[ir.Stmt].create()
        then_body.push(ir.Stmt.stmt_expression(expression = fatal_call, line = 0, source_path = ""))
        length_checks.push(ir.Stmt.stmt_if(
            condition = cond,
            then_body = then_body.as_span(),
            else_body = Option[span[ir.Stmt]].none
        ))
        bi += 1

    let init = lowering.alloc_stmt(ir.Stmt.stmt_local(
        name = index_c,
        linkage_name = index_c,
        ty = ptr_uint_ty,
        value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)),
        line = 0,
        source_path = ""
    ))
    let condition = lowering.alloc_expr(ir.Expr.expr_binary(
        operator = "<",
        left = index_ref,
        right = stop_value,
        ty = ctx.bool_ty
    ))
    let post_target = lowering.alloc_expr(ir.Expr.expr_name(
        name = index_c,
        ty = ptr_uint_ty,
        pointer = Option[bool].some(value = false)
    ))
    let post = lowering.alloc_stmt(ir.Stmt.stmt_assignment(
        target = post_target,
        operator = "+=",
        value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))
    ))
    let for_stmt = ir.Stmt.stmt_for(init = init, condition = condition, post = post, body = loop_body.as_span())

    var block_stmts = vec.Vec[ir.Stmt].create()
    bi = 0
    while bi < len:
        let name_ptr = items_names.get(bi) else:
            break
        let ty_ptr = iterable_types.get(bi) else:
            break
        let val_ptr = lowered_iterables.get(bi) else:
            break
        block_stmts.push(ir.Stmt.stmt_local(
            name = unsafe: read(name_ptr),
            linkage_name = unsafe: read(name_ptr),
            ty = unsafe: read(ty_ptr),
            value = unsafe: read(val_ptr),
            line = 0,
            source_path = ""
        ))
        bi += 1
    var li: ptr_uint = 0
    while li < length_checks.len():
        let lc_ptr = length_checks.get(li) else:
            break
        block_stmts.push(unsafe: read(lc_ptr))
        li += 1
    block_stmts.push(for_stmt)
    if lowering.contains_label_target(loop_body.as_span(), bl):
        block_stmts.push(ir.Stmt.stmt_label(name = bl))
    output.push(ir.Stmt.stmt_block(body = block_stmts.as_span()))

    ctx.loop_break_label = saved_break
    ctx.loop_continue_label = saved_continue
    ctx.loop_continue_native = saved_continue_native
    ctx.loop_break_native = saved_break_native
    ctx.loop_defer_depth = saved_loop_depth


## The stop value of a parallel-for entry: an array's length literal or a
## span's `items.len` member.
function multi_for_stop(items_name: str, iterable_type: types.Type) -> ptr[ir.Expr]:
    let ptr_uint_ty = types.primitive("ptr_uint")
    if lowering.is_array_type(iterable_type):
        return lowering.alloc_expr(ir.Expr.expr_integer_literal(
            value = control_flow.array_length_of(iterable_type),
            ty = ptr_uint_ty
        ))
    let items_ref = lowering.alloc_expr(ir.Expr.expr_name(
        name = items_name,
        ty = iterable_type,
        pointer = Option[bool].some(value = false)
    ))
    return lowering.alloc_expr(ir.Expr.expr_member(receiver = items_ref, member = "len", ty = ptr_uint_ty))


## True when a span of type parameters contains at least one non-lifetime
## parameter (i.e. the struct/deferred type requires monomorphization).
## Lifetime-only parameters (`@a`) are erased at the C level and the struct
## can be emitted directly without specialization.
public function has_non_lifetime_type_params(params: span[ast.TypeParam]) -> bool:
    var i: ptr_uint = 0
    while i < params.len:
        unsafe:
            if not read(params.data + i).is_lifetime:
                return true
        i += 1
    return false
