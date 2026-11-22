## If/else chains, range and collection `for` lowering, custom iterators, and
## array-to-span decay.  Extracted from lowering/lowering.mt.

import std.vec as vec
import std.map as map_mod
import std.str

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types

import mtc.lowering.async_cps as async_cps
import mtc.lowering.comptime as comptime
import mtc.lowering.comptime_types as comptime_types
import mtc.lowering.const_eval as const_eval
import mtc.lowering.lowering as lowering
import mtc.lowering.tasks as tasks
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.utils as utils
import mtc.strings

## Lower an `if`/`else if`/`else` chain into nested `IR::IfStmt`s.  A branch
## condition's hoisted setup (a statement-lowered foreign call's argument temps)
## is emitted *before* its `IfStmt` — for an `else if` that is the enclosing
## branch's else body — and the condition's cleanups head *both* branches, the
## host's `lower_if_chain` shape.
##
## Each branch is lowered with the host's flow refinements (`block.rb:656-709`):
## the condition and body see the accumulated falsy refinements of the earlier
## branches, the body adds the condition's truthy refinements, and an else-less
## `if` whose branches all terminate narrows the enclosing block after the
## statement.
public function lower_if_chain(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], branches: span[ast.IfBranch], index: ptr_uint, else_body: ptr[ast.Stmt]?) -> void:
    var prior_false = map_mod.Map[str, types.Type].create()
    lower_if_chain_at(ctx, output, branches, index, else_body, ref_of(prior_false), true)


public function lower_if_chain_at(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], branches: span[ast.IfBranch], index: ptr_uint, else_body: ptr[ast.Stmt]?, prior_false: ref[map_mod.Map[str, types.Type]], top: bool) -> void:
    var branch: ast.IfBranch
    unsafe:
        branch = read(branches.data + index)
    let base_saved = type_helpers.push_flow_refinements(ctx, prior_false)
    let cond_base = output.len()
    # A condition is a *prepared* position: a statement-lowered foreign call
    # materializes into `__mt_foreign_result_N` with its cleanups before the
    # `IfStmt` (the host's `prepare_statement_lowered_foreign_call` +
    # `materialize_prepared_expression`), the shape `hm_return` produces.
    let cond_saved = lowering.begin_stmt_setup(ctx, lowering.HoistMode.hm_return)
    let cond = lowering.lower_expr(ctx, branch.condition)
    let cond_collected = lowering.collect_stmt_setup(ctx, cond_saved)
    lowering.emit_hoist_setup(output, cond_base, cond_collected)

    # The body's visible env: the prior falsy refinements plus this
    # condition's truthy refinements (the host's `merge_refinements`).
    var true_refs = map_mod.Map[str, types.Type].create()
    type_helpers.merge_flow_refinements(ref_of(true_refs), prior_false)
    var cond_true = type_helpers.lowering_flow_refinements(ctx, branch.condition, true)
    type_helpers.merge_flow_refinements(ref_of(true_refs), ref_of(cond_true))
    var then_body = vec.Vec[ir.Stmt].create()
    lowering.append_hoist_cleanups(ref_of(then_body), cond_collected)
    let then_saved = type_helpers.push_flow_refinements(ctx, ref_of(true_refs))
    then_body.append_span(lowering.lower_block(ctx, branch.body))
    type_helpers.restore_flow_refinements(ctx, then_saved)

    # The cumulative falsy refinements for the next branch.
    var next_false = map_mod.Map[str, types.Type].create()
    type_helpers.merge_flow_refinements(ref_of(next_false), prior_false)
    var cond_false = type_helpers.lowering_flow_refinements(ctx, branch.condition, false)
    type_helpers.merge_flow_refinements(ref_of(next_false), ref_of(cond_false))

    # A source-level `if` always carries an else body in the host's IR — an
    # empty one when the source has no else clause.
    var else_inner = vec.Vec[ir.Stmt].create()
    if index + 1 < branches.len:
        lower_if_chain_at(ctx, ref_of(else_inner), branches, index + 1, else_body, ref_of(next_false), false)
    else:
        let else_saved = type_helpers.push_flow_refinements(ctx, ref_of(next_false))
        else_inner.append_span(lowering.lower_block(ctx, else_body))
        type_helpers.restore_flow_refinements(ctx, else_saved)
    var else_stmts = vec.Vec[ir.Stmt].create()
    lowering.append_hoist_cleanups(ref_of(else_stmts), cond_collected)
    else_stmts.append_span(else_inner.as_span())

    # The sync path always carries an else body — an empty list when the source
    # has none (`block.rb:682-701`).  The async non-await path instead emits
    # `nil` for an empty effective else (`async_lowering.rb:667`).
    var else_opt = Option[span[ir.Stmt]].some(value = else_stmts.as_span())
    if ctx.async_nonawait_body and else_stmts.len() == 0:
        else_opt = Option[span[ir.Stmt]].none
    output.push(ir.Stmt.stmt_if(condition = cond, then_body = then_body.as_span(), else_body = else_opt))
    type_helpers.restore_flow_refinements(ctx, base_saved)

    # The host's post-if rule (`block.rb:707`): an else-less `if` whose branches
    # all terminate narrows the enclosing block's env after the statement.
    # `break`/`continue` count as falling through here (the host's termination
    # builder has no loop targets), which is why the guard-break shape does not
    # refine.  The pushed scope is released by the enclosing `lower_block`.
    if top and else_body == null and if_branches_all_terminate(branches):
        var final_false = map_mod.Map[str, types.Type].create()
        var bi: ptr_uint = 0
        while bi < branches.len:
            var cond_false_i = type_helpers.lowering_flow_refinements(ctx, unsafe: read(branches.data + bi).condition, false)
            type_helpers.merge_flow_refinements(ref_of(final_false), ref_of(cond_false_i))
            bi += 1
        let _post_scope = type_helpers.push_flow_refinements(ctx, ref_of(final_false))


function if_branches_all_terminate(branches: span[ast.IfBranch]) -> bool:
    if branches.len == 0:
        return false
    var i: ptr_uint = 0
    while i < branches.len:
        var br: ast.IfBranch
        unsafe:
            br = read(branches.data + i)
        if not type_helpers.ast_block_always_terminates(br.body):
            return false
        i += 1
    return true


## Lower `for i in start..stop:` into a scope block holding an optional hoisted
## stop temporary and a C `for` loop.  Mirrors lowering/loops.rb
## lower_range_for_stmt, including the always-allocated (here unused) continue /
## break label temporaries so the fresh-temp counter advances identically.
public function lower_for_range(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], bindings: span[ast.ForBinding], iterables: span[ast.Expr], body_ptr: ptr[ast.Stmt]?) -> void:
    if bindings.len != 1 or iterables.len != 1:
        tasks.lower_multi_for(ctx, output, bindings, iterables, body_ptr)
        return

    var index_name: str
    unsafe:
        index_name = read(bindings.data + 0).name

    var start: ptr[ast.Expr]
    var stop: ptr[ast.Expr]
    unsafe:
        match read(iterables.data + 0):
            ast.Expr.expr_range as rng:
                start = rng.start_expr
                stop = rng.end_expr
            _:
                lower_collection_for(ctx, output, index_name, iterables.data + 0, body_ptr)
                return

    # The host's `infer_range_loop_type`: an integer-literal bound takes the
    # other bound's type, so `for i in 0..span.len` is a `ptr_uint` loop.
    var loop_type = type_helpers.expr_type(ctx, start)
    var stop_ty = type_helpers.expr_type(ctx, stop)
    if not types.type_equals(loop_type, stop_ty):
        if ast_is_integer_literal(start) and types.is_integer_type(stop_ty):
            loop_type = stop_ty
        else if ast_is_integer_literal(stop) and types.is_integer_type(loop_type):
            stop_ty = loop_type
    if types.is_error(loop_type):
        loop_type = types.primitive("int")

    let index_c = utils.c_local_name(index_name)
    let stop_c = lowering.fresh_c_temp_name(ctx, "for_stop")

    # The host inlines the stop value when it is a compile-time numeric
    # constant expression (`compile_time_numeric_const_expression?`) — a literal,
    # a module constant, an enum member or a fold of those — and hoists the
    # `__mt_for_stop_N` temp only otherwise.
    let inline_stop = is_numeric_const_expr(ctx, stop)

    let saved_break = ctx.loop_break_label
    let saved_continue = ctx.loop_continue_label
    let saved_continue_native = ctx.loop_continue_native
    let saved_break_native = ctx.loop_break_native
    let cl = lowering.fresh_c_temp_name(ctx, "loop_continue")
    let bl = lowering.fresh_c_temp_name(ctx, "loop_break")
    ctx.loop_break_label = bl
    ctx.loop_continue_label = cl
    # A native `continue` reaches the generated loop's post statement and a
    # native `break` exits it (the host's ContinueStmt/BreakStmt); the labels
    # remain for the defer-flush paths and for arms inside a switch.
    ctx.loop_continue_native = true
    ctx.loop_break_native = true

    # In CPS mode, spill the induction variable and (if not inline) the stop value
    # to frame fields so they survive an `await` inside the loop body.
    var index_linkage: str = index_c
    var stop_linkage: str = stop_c
    if ctx.async_cps_active:
        let idx_field = strings.join_two("local_for_", index_name)
        index_linkage = strings.join_two("__mt_frame->", idx_field)
        async_cps.async_register_local_field(ctx, index_name, idx_field, index_linkage, loop_type)
        if not inline_stop:
            let stp_field = strings.join_two("local_", stop_c)
            stop_linkage = strings.join_two("__mt_frame->", stp_field)
            async_cps.async_register_local_field(ctx, stop_c, stp_field, stop_linkage, loop_type)
    else:
        ctx.locals.push(lowering.LocalBinding(name = index_name, c_name = index_c, ty = loop_type, pointer = Option[bool].some(value = false)))

    let saved_loop_depth = ctx.loop_defer_depth
    ctx.loop_defer_depth = ctx.defer_stack.len()
    let body_span = lowering.lower_block(ctx, body_ptr)
    var body = vec.Vec[ir.Stmt].create()
    lowering.append_span_stmts(ref_of(body), body_span)
    if lowering.contains_label_target(body.as_span(), cl):
        body.push(ir.Stmt.stmt_label(name = cl))

    let index_ref = lowering.alloc_expr(ir.Expr.expr_name(name = index_linkage, ty = loop_type, pointer = Option[bool].some(value = false)))
    # The host lowers both bounds with the loop type as the expected type
    # (`lower_expression(..., expected_type: loop_type)`).
    let start_value = lowering.int_literal_to_context_type(start, loop_type, lowering.lower_expr(ctx, start))
    let stop_lowered = lowering.int_literal_to_context_type(stop, loop_type, lowering.lower_expr(ctx, stop))
    var init: ptr[ir.Stmt]
    if ctx.async_cps_active:
        init = lowering.alloc_stmt(ir.Stmt.stmt_assignment(target = index_ref, operator = "=", value = start_value))
    else:
        init = lowering.alloc_stmt(ir.Stmt.stmt_local(
            name = index_name,
            linkage_name = index_c,
            ty = loop_type,
            value = start_value,
            line = 0,
            source_path = "",
        ))
    let stop_value = if inline_stop: stop_lowered else: lowering.alloc_expr(ir.Expr.expr_name(name = stop_linkage, ty = loop_type, pointer = Option[bool].some(value = false)))
    let condition = lowering.alloc_expr(ir.Expr.expr_binary(operator = "<", left = index_ref, right = stop_value, ty = ctx.bool_ty))
    let post_target = lowering.alloc_expr(ir.Expr.expr_name(name = index_linkage, ty = loop_type, pointer = Option[bool].some(value = false)))
    let one = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = loop_type))
    let post = lowering.alloc_stmt(ir.Stmt.stmt_assignment(target = post_target, operator = "+=", value = one))
    let for_stmt = ir.Stmt.stmt_for(init = init, condition = condition, post = post, body = body.as_span())

    var block_stmts = vec.Vec[ir.Stmt].create()
    if not inline_stop:
        if ctx.async_cps_active:
            block_stmts.push(ir.Stmt.stmt_assignment(target = lowering.alloc_expr(ir.Expr.expr_name(name = stop_linkage, ty = loop_type, pointer = Option[bool].some(value = false))), operator = "=", value = stop_lowered))
        else:
            block_stmts.push(ir.Stmt.stmt_local(
                name = stop_c,
                linkage_name = stop_c,
                ty = loop_type,
                value = stop_lowered,
                line = 0,
                source_path = "",
            ))
    block_stmts.push(for_stmt)
    if lowering.contains_label_target(body.as_span(), bl):
        block_stmts.push(ir.Stmt.stmt_label(name = bl))
    output.push(ir.Stmt.stmt_block(body = block_stmts.as_span()))

    ctx.loop_break_label = saved_break
    ctx.loop_continue_label = saved_continue
    ctx.loop_continue_native = saved_continue_native
    ctx.loop_break_native = saved_break_native
    ctx.loop_defer_depth = saved_loop_depth


## True when `ep` is an integer-literal expression (the host's
## `AST::IntegerLiteral` checks in `infer_range_loop_type`).
public function ast_is_integer_literal(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal:
                return true
            _:
                return false


## True when `ep` folds to a numeric compile-time constant (the host's
## `compile_time_numeric_const_expression?`): a literal, a module constant
## (recursively), an enum member's value, or an arithmetic fold of those.
function is_numeric_const_expr(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> bool:
    match const_eval.try_evaluate_const_expr(ctx, ep):
        Option.some as value:
            match value.value:
                comptime_types.ConstValue.cv_int:
                    return true
                _:
                    return false
        Option.none:
            return false


## Lower `for v in xs:` (array) / `for v in s:` (span) into a scope block that
## copies the iterable into a temp and drives a C index loop.  Mirrors
## lowering/loops.rb lower_collection_for_stmt (including the always-allocated
## continue/break label temporaries so the fresh-temp counter matches).
function lower_collection_for(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], binding_name: str, iterable: ptr[ast.Expr], body_ptr: ptr[ast.Stmt]?) -> void:
    let iterable_type = lowering.index_receiver_type(ctx, iterable)
    let element_type = lowering.generic_first_arg(iterable_type)
    let is_arr = lowering.is_array_type(iterable_type)
    # Only arrays and spans are index-driven collections.  Every other iterable
    # (Vec, Queue, map entries, ...) goes through the iterator protocol
    # (`iter()` / `next()` / `current()`).
    if not is_arr and not lowering.is_span_type(iterable_type):
        if not ctx.async_cps_active:
            lower_custom_iter_for(ctx, output, binding_name, iterable, body_ptr)
        return
    let ptr_uint_ty = types.primitive("ptr_uint")

    let items_c = lowering.fresh_c_temp_name(ctx, "for_items")
    let index_c = lowering.fresh_c_temp_name(ctx, "for_index")

    let binding_c = utils.c_local_name(binding_name)
    let saved_break = ctx.loop_break_label
    let saved_continue = ctx.loop_continue_label
    let saved_continue_native = ctx.loop_continue_native
    let saved_break_native = ctx.loop_break_native
    let cl = lowering.fresh_c_temp_name(ctx, "loop_continue")
    let bl = lowering.fresh_c_temp_name(ctx, "loop_break")
    ctx.loop_break_label = bl
    ctx.loop_continue_label = cl
    # A native `continue` reaches the generated loop's post statement and a
    # native `break` exits it (the host's ContinueStmt/BreakStmt); the labels
    # remain for the defer-flush paths and for arms inside a switch.
    ctx.loop_continue_native = true
    ctx.loop_break_native = true

    # In CPS mode, register the index and element binding as frame fields so they
    # survive an `await` inside the loop body.
    var idx_linkage: str = index_c
    var items_linkage: str = items_c
    if ctx.async_cps_active:
        let idx_field = strings.join_two("local_", index_c)
        idx_linkage = strings.join_two("__mt_frame->", idx_field)
        async_cps.async_register_local_field(ctx, index_c, idx_field, idx_linkage, ptr_uint_ty)
        let items_field = strings.join_two("local_", items_c)
        items_linkage = strings.join_two("__mt_frame->", items_field)
        async_cps.async_register_local_field(ctx, items_c, items_field, items_linkage, iterable_type)

    ctx.locals.push(lowering.LocalBinding(name = binding_name, c_name = binding_c, ty = element_type, pointer = Option[bool].some(value = false)))
    let saved_loop_depth = ctx.loop_defer_depth
    ctx.loop_defer_depth = ctx.defer_stack.len()
    let body_span = lowering.lower_block(ctx, body_ptr)

    # item value: array -> items[index]; span -> items.data[index]
    var item_value: ptr[ir.Expr]
    let index_ref_item = lowering.alloc_expr(ir.Expr.expr_name(name = idx_linkage, ty = ptr_uint_ty, pointer = Option[bool].some(value = false)))
    if is_arr:
        let items_ref = lowering.alloc_expr(ir.Expr.expr_name(name = items_linkage, ty = iterable_type, pointer = Option[bool].some(value = false)))
        item_value = lowering.alloc_expr(ir.Expr.expr_index(receiver = items_ref, index = index_ref_item, ty = element_type))
    else:
        let items_ref = lowering.alloc_expr(ir.Expr.expr_name(name = items_linkage, ty = iterable_type, pointer = Option[bool].some(value = false)))
        var ptr_args = vec.Vec[types.Type].create()
        ptr_args.push(element_type)
        let data_ty = types.generic_type(name = "ptr", args = ptr_args.as_span())
        let data_ref = lowering.alloc_expr(ir.Expr.expr_member(receiver = items_ref, member = "data", ty = data_ty))
        item_value = lowering.alloc_expr(ir.Expr.expr_index(receiver = data_ref, index = index_ref_item, ty = element_type))

    # stop value: array -> N; span -> items.len
    var stop_value: ptr[ir.Expr]
    if is_arr:
        stop_value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = array_length_of(iterable_type), ty = ptr_uint_ty))
    else:
        let items_ref_stop = lowering.alloc_expr(ir.Expr.expr_name(name = items_linkage, ty = iterable_type, pointer = Option[bool].some(value = false)))
        stop_value = lowering.alloc_expr(ir.Expr.expr_member(receiver = items_ref_stop, member = "len", ty = ptr_uint_ty))

    var loop_body = vec.Vec[ir.Stmt].create()
    if ctx.async_cps_active:
        let elt_field = strings.join_two("local_for_elt_", binding_name)
        let elt_cname = strings.join_two("__mt_frame->", elt_field)
        async_cps.async_register_local_field(ctx, binding_name, elt_field, elt_cname, element_type)
        loop_body.push(ir.Stmt.stmt_assignment(target = lowering.alloc_expr(ir.Expr.expr_name(name = elt_cname, ty = element_type, pointer = Option[bool].some(value = false))), operator = "=", value = item_value))
    else:
        loop_body.push(ir.Stmt.stmt_local(name = binding_name, linkage_name = binding_c, ty = element_type, value = item_value, line = 0, source_path = ""))
    var bi: ptr_uint = 0
    while bi < body_span.len:
        unsafe:
            loop_body.push(read(body_span.data + bi))
        bi += 1
    if lowering.contains_label_target(loop_body.as_span(), cl):
        loop_body.push(ir.Stmt.stmt_label(name = cl))

    var init: ptr[ir.Stmt]
    if ctx.async_cps_active:
        init = lowering.alloc_stmt(ir.Stmt.stmt_assignment(target = lowering.alloc_expr(ir.Expr.expr_name(name = idx_linkage, ty = ptr_uint_ty, pointer = Option[bool].some(value = false))), operator = "=", value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty))))
    else:
        init = lowering.alloc_stmt(ir.Stmt.stmt_local(name = index_c, linkage_name = index_c, ty = ptr_uint_ty, value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)), line = 0, source_path = ""))
    let index_ref_cond = lowering.alloc_expr(ir.Expr.expr_name(name = idx_linkage, ty = ptr_uint_ty, pointer = Option[bool].some(value = false)))
    let condition = lowering.alloc_expr(ir.Expr.expr_binary(operator = "<", left = index_ref_cond, right = stop_value, ty = ctx.bool_ty))
    let post_target = lowering.alloc_expr(ir.Expr.expr_name(name = idx_linkage, ty = ptr_uint_ty, pointer = Option[bool].some(value = false)))
    let post = lowering.alloc_stmt(ir.Stmt.stmt_assignment(target = post_target, operator = "+=", value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))))
    let for_stmt = ir.Stmt.stmt_for(init = init, condition = condition, post = post, body = loop_body.as_span())

    var block_stmts = vec.Vec[ir.Stmt].create()
    if ctx.async_cps_active:
        block_stmts.push(ir.Stmt.stmt_assignment(target = lowering.alloc_expr(ir.Expr.expr_name(name = items_linkage, ty = iterable_type, pointer = Option[bool].some(value = false))), operator = "=", value = lowering.lower_expr(ctx, iterable)))
    else:
        block_stmts.push(ir.Stmt.stmt_local(name = items_c, linkage_name = items_c, ty = iterable_type, value = lowering.lower_expr(ctx, iterable), line = 0, source_path = ""))
    block_stmts.push(for_stmt)
    if lowering.contains_label_target(loop_body.as_span(), bl):
        block_stmts.push(ir.Stmt.stmt_label(name = bl))
    output.push(ir.Stmt.stmt_block(body = block_stmts.as_span()))

    ctx.loop_break_label = saved_break
    ctx.loop_continue_label = saved_continue
    ctx.loop_continue_native = saved_continue_native
    ctx.loop_break_native = saved_break_native
    ctx.loop_defer_depth = saved_loop_depth


## Lower `for x in custom_iterable` over the iterator protocol.  The `iter()`
## / `next()` / `current()` calls are synthesized as AST and lowered through the
## normal call path so generic receivers (a `Vec[int]` collapses to a concrete
## struct) monomorphize exactly like a source-level method call.  Two shapes
## are supported, mirroring the host's `iterator_loop_info`:
##   * nullable item: `Iter it = xs.iter(); while (true) { T* x = it.next();
##     if (x == null) break; body }`
##   * ready flag: `Iter it = xs.iter(); while (true) { bool ready = it.next();
##     if (!ready) break; T x = it.current(); body }`
function lower_custom_iter_for(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], binding_name: str, iterable: ptr[ast.Expr], body_ptr: ptr[ast.Stmt]?) -> void:
    # The host's `iterator_loop_type` instantiates `iter`/`next`/`current` while
    # analyzing the loop but never validates their bodies, so those
    # specializations' nested calls are lowering-created.
    let iter_callee = async_cps.alloc_ast_expr(ast.Expr.expr_member_access(receiver = iterable, member_name = "iter", line = 0, column = 0))
    ctx.next_spec_body_validated = Option[bool].some(value = false)
    let iter_call = lowering.lower_call(ctx, iter_callee, span[ast.Argument](), iter_callee)
    ctx.next_spec_body_validated = Option[bool].none
    let iter_ty = lowering.ir_expr_type(iter_call)
    if types.is_error(iter_ty) or types.is_void(iter_ty):
        return

    let it_c = lowering.fresh_c_temp_name(ctx, "for_iterator")
    ctx.locals.push(lowering.LocalBinding(name = it_c, c_name = it_c, ty = iter_ty, pointer = Option[bool].some(value = false)))

    let it_id = async_cps.alloc_ast_expr(ast.Expr.expr_identifier(name = it_c, line = 0, column = 0))
    let next_callee = async_cps.alloc_ast_expr(ast.Expr.expr_member_access(receiver = it_id, member_name = "next", line = 0, column = 0))
    ctx.next_spec_body_validated = Option[bool].some(value = false)
    let next_call = lowering.lower_call(ctx, next_callee, span[ast.Argument](), next_callee)
    ctx.next_spec_body_validated = Option[bool].none
    let next_ty = lowering.ir_expr_type(next_call)
    if types.is_error(next_ty) or types.is_void(next_ty):
        return
    let nullable_item = lowering.is_nullable_pointer_like(next_ty)

    var cur_call = next_call
    var cur_ty = next_ty
    if not nullable_item:
        let it_id2 = async_cps.alloc_ast_expr(ast.Expr.expr_identifier(name = it_c, line = 0, column = 0))
        let cur_callee = async_cps.alloc_ast_expr(ast.Expr.expr_member_access(receiver = it_id2, member_name = "current", line = 0, column = 0))
        ctx.next_spec_body_validated = Option[bool].some(value = false)
        cur_call = lowering.lower_call(ctx, cur_callee, span[ast.Argument](), cur_callee)
        ctx.next_spec_body_validated = Option[bool].none
        cur_ty = lowering.ir_expr_type(cur_call)
        if types.is_error(cur_ty) or types.is_void(cur_ty):
            return

    let saved_break = ctx.loop_break_label
    let saved_continue = ctx.loop_continue_label
    let saved_continue_native = ctx.loop_continue_native
    let saved_break_native = ctx.loop_break_native
    let cl = lowering.fresh_c_temp_name(ctx, "loop_continue")
    let bl = lowering.fresh_c_temp_name(ctx, "loop_break")
    ctx.loop_break_label = bl
    ctx.loop_continue_label = cl
    # A native `continue` reaches the generated loop's post statement and a
    # native `break` exits it (the host's ContinueStmt/BreakStmt); the labels
    # remain for the defer-flush paths and for arms inside a switch.
    ctx.loop_continue_native = true
    ctx.loop_break_native = true

    let binding_c = utils.c_local_name(binding_name)
    let binding_ty = if nullable_item: types.unwrap_nullable(next_ty) else: cur_ty
    # The host registers the loop binding with the `next()` storage (nullable)
    # and the unwrapped item as its visible type (`iterator_loop_info`'s
    # `item_storage_type`/`item_type`), so a pointer-like item's reads keep the
    # storage `Nullable` and a non-pointer-like one projects `.value`.
    var binding_projection = lowering.plain_binding_projection()
    if nullable_item:
        binding_projection = lowering.guard_binding_projection("nullable", next_ty)
    ctx.locals.push(lowering.LocalBinding(name = binding_name, c_name = binding_c, ty = binding_ty, pointer = Option[bool].some(value = false), projection = binding_projection))
    let saved_loop_depth = ctx.loop_defer_depth
    ctx.loop_defer_depth = ctx.defer_stack.len()
    let body_span = lowering.lower_block(ctx, body_ptr)

    var break_body = vec.Vec[ir.Stmt].create()
    break_body.push(ir.Stmt.stmt_break())

    var loop_body = vec.Vec[ir.Stmt].create()
    if nullable_item:
        let item_ref = lowering.alloc_expr(ir.Expr.expr_name(name = binding_c, ty = next_ty, pointer = Option[bool].some(value = false)))
        loop_body.push(ir.Stmt.stmt_local(name = binding_name, linkage_name = binding_c, ty = next_ty, value = next_call, line = 0, source_path = ""))
        let null_lit = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = next_ty))
        let is_null = lowering.alloc_expr(ir.Expr.expr_binary(operator = "==", left = item_ref, right = null_lit, ty = ctx.bool_ty))
        loop_body.push(ir.Stmt.stmt_if(condition = is_null, then_body = break_body.as_span(), else_body = Option[span[ir.Stmt]].none))
    else:
        let ready_c = lowering.fresh_c_temp_name(ctx, "for_ready")
        let ready_ref = lowering.alloc_expr(ir.Expr.expr_name(name = ready_c, ty = ctx.bool_ty, pointer = Option[bool].some(value = false)))
        loop_body.push(ir.Stmt.stmt_local(name = ready_c, linkage_name = ready_c, ty = ctx.bool_ty, value = next_call, line = 0, source_path = ""))
        let not_ready = lowering.alloc_expr(ir.Expr.expr_unary(operator = "not", operand = ready_ref, ty = ctx.bool_ty))
        loop_body.push(ir.Stmt.stmt_if(condition = not_ready, then_body = break_body.as_span(), else_body = Option[span[ir.Stmt]].none))
        loop_body.push(ir.Stmt.stmt_local(name = binding_name, linkage_name = binding_c, ty = cur_ty, value = cur_call, line = 0, source_path = ""))

    var bi: ptr_uint = 0
    while bi < body_span.len:
        unsafe:
            loop_body.push(read(body_span.data + bi))
        bi += 1
    if lowering.contains_label_target(loop_body.as_span(), cl):
        loop_body.push(ir.Stmt.stmt_label(name = cl))

    var block_stmts = vec.Vec[ir.Stmt].create()
    block_stmts.push(ir.Stmt.stmt_local(name = it_c, linkage_name = it_c, ty = iter_ty, value = iter_call, line = 0, source_path = ""))
    let true_lit = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = ctx.bool_ty))
    block_stmts.push(ir.Stmt.stmt_while(condition = true_lit, body = loop_body.as_span()))
    if lowering.contains_label_target(loop_body.as_span(), bl):
        block_stmts.push(ir.Stmt.stmt_label(name = bl))
    output.push(ir.Stmt.stmt_block(body = block_stmts.as_span()))

    ctx.loop_break_label = saved_break
    ctx.loop_continue_label = saved_continue
    ctx.loop_continue_native = saved_continue_native
    ctx.loop_break_native = saved_break_native
    ctx.loop_defer_depth = saved_loop_depth


public function array_length_of(t: types.Type) -> long:
    match t:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.args.len == 2:
                unsafe:
                    match read(g_bp.args.data + 1):
                        types.Type.ty_literal_int as lit:
                            return lit.value
                        _:
                            pass
        _:
            pass
    return 0


## Lower `array[T, N].as_span()` to a `span[T]` aggregate literal
## `{ data = &arr[0], len = N }`, mirroring Ruby's `lower_array_to_span_expression`.
public function lower_array_as_span(ctx: ref[lowering.LoweringContext], receiver: ptr[ast.Expr], array_ty: types.Type) -> ptr[ir.Expr]:
    let elem_ty = lowering.generic_first_arg(array_ty)
    let ptr_uint_ty = types.primitive("ptr_uint")
    # Recover the length from the array type; if it lost its literal length
    # (a const/var reference whose recorded type dropped the count), resolve it
    # from the declaration's type annotation.
    var length = array_length_of(array_ty)
    if length == 0:
        length = comptime.const_array_length(ctx, receiver)
    let recv = lowering.lower_expr(ctx, receiver)
    let zero_index = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty))
    # The host's `lower_array_to_span_expression` uses a plain `IR::Index` for
    # the decay's `&array[0]` (an unchecked element pointer, not a runtime
    # subscript).
    let elem0 = lowering.alloc_expr(ir.Expr.expr_index(receiver = recv, index = zero_index, ty = elem_ty))
    let data_ptr = lowering.alloc_expr(ir.Expr.expr_address_of(
        expression = elem0,
        ty = types.generic_type(name = "ptr", args = lowering.sp_type(elem_ty)),
    ))
    let len_expr = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = length, ty = ptr_uint_ty))
    var fields = vec.Vec[ir.AggregateField].create()
    fields.push(ir.AggregateField(name = "data", value = data_ptr))
    fields.push(ir.AggregateField(name = "len", value = len_expr))
    let span_ty = types.generic_type(name = "span", args = lowering.sp_type(elem_ty))
    return lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = span_ty, fields = fields.as_span()))
