## Return-statement lowering, extracted from lowering/lowering.mt (Wave 4.2).
## The body is verbatim apart from module qualification of lowering helpers.

import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types

import mtc.lowering.async as async_mod
import mtc.lowering.async_cps as async_cps
import mtc.lowering.format as format
import mtc.lowering.lowering as lowering
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.match as match_mod
import mtc.lowering.tasks as tasks
import mtc.lowering.utils as utils


public function lower_return_stmt(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], sp: ptr[ast.Stmt]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_ret as r:
                # An async resume body completes the frame inline (the host's
                # `async_complete_statements`): the return value stores into
                # `frame->result`, then ready + waiter wake + return follow.
                # This way returns inside nested blocks (if/while/for/switch)
                # reach the waiter-wake + void-return epilogue instead of
                # returning directly with a value from a void function.
                if ctx.async_completion_active:
                    let rv = r.value
                    let ret_ty = ctx.current_fn_return_type
                    if rv != null and not types.is_void(ret_ty):
                        # `return await X`: suspend, then store the awaited result.
                        if ctx.async_cps_active and async_cps.expr_is_direct_await(rv):
                            async_cps.lower_async_await_into(
                                ctx,
                                output,
                                async_cps.direct_await_inner(rv),
                                Option[ptr[ir.Expr]].some(value = async_cps.async_result_target(ctx, ret_ty))
                            )
                            lowering.flush_all_defers(ctx, output)
                            async_cps.async_complete_statements(ctx, output, ret_ty, Option[ptr[ir.Expr]].none)
                            return
                        # Hoist any embedded awaits in the return value first.
                        var rvh = rv
                        if ctx.async_cps_active and async_mod.expr_has_await(rv):
                            rvh = async_cps.async_hoist_awaits(ctx, output, rv)
                        let lowered = lowering.lower_expr(ctx, rvh)
                        # The host stores the result before the cleanups only for
                        # a non-literal value when cleanups exist
                        # (`async_lowering.rb:1105`); a literal can be stored by
                        # the completion after the cleanups run.
                        if lowering.has_pending_defers(ctx) and not lowering.cleanup_safe_return_expr(rv):
                            output.push(ir.Stmt.stmt_assignment(
                                target = async_cps.async_result_target(ctx, ret_ty),
                                operator = "=",
                                value = lowered,
                            ))
                            lowering.flush_all_defers(ctx, output)
                            async_cps.async_complete_statements(ctx, output, ret_ty, Option[ptr[ir.Expr]].none)
                        else:
                            lowering.flush_all_defers(ctx, output)
                            async_cps.async_complete_statements(
                                ctx,
                                output,
                                ret_ty,
                                Option[ptr[ir.Expr]].some(value = lowered)
                            )
                        return
                    # A void return (or no value): cleanups precede completion.
                    lowering.flush_all_defers(ctx, output)
                    async_cps.async_complete_statements(ctx, output, ret_ty, Option[ptr[ir.Expr]].none)
                    return
                # `return expr?` — handle ? propagation inline before lowering
                # the return value so the ? is resolved to an if/failure pattern
                # rather than emitted as a raw ? prefix in C.
                let rval = r.value
                if rval != null:
                    unsafe:
                        match read(rval):
                            ast.Expr.expr_unary_op as un:
                                if un.operator == "?":
                                    lowering.flush_all_defers(ctx, output)
                                    lower_propagate_return(ctx, output, un.operand, r.line, ctx.analysis.source_path)
                                    return
                            _:
                                pass
                let value = r.value else:
                    lowering.flush_all_defers(ctx, output)
                    # In async functions (inside_async / async_resume_return_label),
                    # a bare `return;` produces a completed Task[void] aggregate
                    # rather than a void return.
                    if ctx.inside_async:
                        let void_ret_val = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = ctx.void_ty))
                        let wrapped = tasks.make_task_literal(void_ret_val)
                        output.push(ir.Stmt.stmt_return(
                            value = wrapped,
                            line = r.line,
                            source_path = ctx.analysis.source_path
                        ))
                    else:
                        output.push(ir.Stmt.stmt_return(
                            value = null,
                            line = r.line,
                            source_path = ctx.analysis.source_path
                        ))
                    return
                # `return match ...`: a match expression has no direct C form, so
                # hoist it into a synthetic temp local (a switch / if-chain that
                # assigns each arm's value), run any active defers, then return the
                # temp.
                match read(value):
                    ast.Expr.expr_match as me:
                        let ret_ty = lowering.current_return_type(ctx, value)
                        let temp = lowering.fresh_c_temp_name(ctx, "match_expr")
                        let tc = utils.c_local_name(temp)
                        let zero_init = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = ret_ty))
                        output.push(ir.Stmt.stmt_local(
                            name = temp,
                            linkage_name = tc,
                            ty = ret_ty,
                            value = zero_init,
                            line = 0,
                            source_path = ""
                        ))
                        let result_ref = lowering.alloc_expr(ir.Expr.expr_name(
                            name = tc,
                            ty = ret_ty,
                            pointer = Option[bool].some(value = false)
                        ))
                        match_mod.lower_match_expr_to_ref(ctx, output, me.scrutinee, me.arms, result_ref)
                        lowering.flush_all_defers(ctx, output)
                        let ret_ref = lowering.alloc_expr(ir.Expr.expr_name(
                            name = tc,
                            ty = ret_ty,
                            pointer = Option[bool].some(value = false)
                        ))
                        output.push(ir.Stmt.stmt_return(
                            value = ret_ref,
                            line = r.line,
                            source_path = ctx.analysis.source_path
                        ))
                        return
                    _:
                        pass
                # Plain `return expr`: when defers or hoisted cleanups are active
                # they must run after the return value is computed but before
                # control leaves.  If the value is not a trivial literal, hoist
                # it into a temp so the cleanups cannot invalidate it (the host's
                # return-value hoist + cleanup preamble, `block.rb:495-511`).
                let hoisted = lowering.lower_expr_hoisting(ctx, output, value, lowering.is_array_type(ctx.current_fn_return_type))
                let lowered = lowering.coerce_return_literal_to_cstr(ctx, value, hoisted.value)
                # Re-type an integer literal return value against the function's
                # return type (e.g. `return 0` in a `ptr_uint` function), matching
                # the host's contextual numeric literal inference.
                let ret_ty0 = ctx.current_fn_return_type
                let ret_lit = lowering.int_literal_to_context_type(value, ret_ty0, lowered)
                let ret_flt = lowering.float_literal_to_context_type(value, ret_ty0, ret_lit)
                # A bare `null` return takes the function's return type (the
                # analyzer may record only `void` for it).
                let ret_null = lowering.null_literal_to_context_type(value, ret_ty0, ret_flt)
                # A conditional return value takes the return type on both
                # branches (`return if b: 1 else: 0` in a `long` function).
                let ret_cond = lowering.conditional_value_to_context_type(ctx, value, ret_ty0, ret_null)
                # The host's return-site contextual conversion: a folded numeric
                # constant that fits, and int→float for a float/double return.
                let ret_typed = lowering.contextual_numeric_cast(
                    ctx,
                    value,
                    ret_cond,
                    ret_ty0,
                    types.is_float_type(ret_ty0) and not lowering.is_foreign_call_initializer(ctx, value),
                    false
                )
                let wrapped = if ctx.inside_async: tasks.make_task_literal(ret_typed) else: ret_typed
                # A returned str/cstr (or a struct containing one) transfers the
                # dynamic format temp's buffer to the caller, so its release is
                # dropped; every other return type keeps the release.
                let ret_cleanups = lowering.filter_return_format_cleanups(ctx, ctx.current_fn_return_type, hoisted.cleanups)
                # A returned proc-containing value is retained before the defers
                # (whose proc releases would otherwise free it) when it is not a
                # fresh literal — the host's `needs_proc_retain` rule
                # (`block.rb:503-509`).
                let ret_needs_proc_retain = lowering.has_pending_defers(ctx) and lowering.contains_proc_storage_type(
                    ctx,
                    ctx.current_fn_return_type
                ) and not lowering.proc_expr_contains_proc_expr(value)
                if ((ret_cleanups.len > 0 or lowering.has_pending_defers(ctx)) and not lowering.cleanup_safe_return_expr(value)) or ret_needs_proc_retain:
                    # The host's hoist declares the temp with the *function's*
                    # return type (`block.rb:508`), not the value's own type
                    # (`return <own[String]>` from an `own[String]?` function
                    # carries `Nullable(ptr[String])`).
                    var ret_ty = lowering.ir_expr_type(wrapped)
                    if not types.is_void(ctx.current_fn_return_type) and not types.is_error(ctx.current_fn_return_type):
                        ret_ty = ctx.current_fn_return_type
                    let rtemp = lowering.fresh_c_temp_name(ctx, "return_value")
                    let rc = utils.c_local_name(rtemp)
                    output.push(ir.Stmt.stmt_local(
                        name = rtemp,
                        linkage_name = rc,
                        ty = ret_ty,
                        value = wrapped,
                        line = 0,
                        source_path = ""
                    ))
                    let rref = lowering.alloc_expr(ir.Expr.expr_name(
                        name = rc,
                        ty = ret_ty,
                        pointer = Option[bool].some(value = false)
                    ))
                    if ret_needs_proc_retain:
                        lowering.proc_contained_retain_stmts(ctx, rref, ret_ty, output)
                    lowering.append_cleanup_stmts(output, ret_cleanups)
                    lowering.flush_all_defers(ctx, output)
                    output.push(ir.Stmt.stmt_return(
                        value = rref,
                        line = r.line,
                        source_path = ctx.analysis.source_path
                    ))
                    return
                lowering.append_cleanup_stmts(output, ret_cleanups)
                lowering.flush_all_defers(ctx, output)
                output.push(ir.Stmt.stmt_return(value = wrapped, line = r.line, source_path = ctx.analysis.source_path))
            _:
                pass

public function lower_propagate_return(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    operand: ptr[ast.Expr],
    line: ptr_uint,
    source_path: str
) -> void:
    # The host's normalization hoists an embedded await out of a `?` operand
    # into a `__mt_async_tmp_<N>` local before the propagation lowers it
    # (`normalize_async_expression`'s AwaitExpr case).
    var actual = operand
    if ctx.async_cps_active and async_mod.expr_has_await(operand):
        actual = async_cps.async_hoist_awaits(ctx, output, operand)
    # The host prepares the `?` operand with the enclosing statement's window,
    # so an operand temp materializes before the propagation storage local.
    let had_window = ctx.hoist_mode != lowering.HoistMode.hm_off
    let window_saved = lowering.begin_stmt_setup(ctx, lowering.HoistMode.hm_value)
    let value_ir = lowering.lower_expr(ctx, actual)
    let window_collected = lowering.collect_stmt_setup(ctx, window_saved)
    if had_window:
        lowering.append_span_stmts(ref_of(ctx.hoist_stmts), window_collected.stmts.as_span())
        lowering.append_span_stmts(ref_of(ctx.hoist_cleanups), window_collected.cleanups.as_span())
    else:
        lowering.append_span_stmts(output, window_collected.stmts.as_span())
    let storage_ty = lowering.ir_expr_type(value_ir)

    let storage_c = lowering.fresh_c_temp_name(ctx, "propagate")
    output.push(ir.Stmt.stmt_local(
        name = storage_c,
        linkage_name = storage_c,
        ty = storage_ty,
        value = value_ir,
        line = 0,
        source_path = ""
    ))
    if not had_window:
        lowering.append_span_stmts(output, window_collected.cleanups.as_span())
    let storage_ref = lowering.alloc_expr(ir.Expr.expr_name(
        name = storage_c,
        ty = storage_ty,
        pointer = Option[bool].some(value = false)
    ))

    let kind = lowering.guard_storage_kind(ctx, storage_ty)
    if kind != "option" and kind != "result" and kind != "nullable":
        output.push(ir.Stmt.stmt_return(value = storage_ref, line = 0, source_path = source_path))
        return

    if kind == "option" or kind == "result":
        let outer_c = lowering.variant_base_c_name(storage_ty, ctx.module_name)
        let success_arm = if kind == "result": "success" else: "some"
        let arm_c = match_mod.variant_arm_type_name(outer_c, success_arm)
        if not ctx.arm_payload_fields.contains(arm_c):
            var base_name = ""
            if match_mod.is_prelude_variant_name(outer_c):
                if outer_c.starts_with("std_result_"):
                    base_name = "Result"
                else if outer_c.starts_with("std_option_"):
                    base_name = "Option"
            if base_name.len > 0:
                let vi_ptr = ctx.variants.get(base_name)
                if vi_ptr != null:
                    let vi = unsafe: read(vi_ptr)
                    match_mod.register_arm_payload_fields(ctx, arm_c, vi, success_arm, storage_ty)

    var fail_value = storage_ref
    let ret_ty = ctx.current_fn_return_type
    if not types.type_equals(ret_ty, storage_ty):
        var is_task_ret = false
        match ret_ty:
            types.Type.ty_generic as tg:
                let tg_bp = unsafe: read(tg.payload)
                if tg_bp.name == "Task":
                    is_task_ret = true
            types.Type.ty_named as tn:
                let tn_np = unsafe: read(tn.payload)
                if tn_np.name.starts_with("mt_task_"):
                    is_task_ret = true
            _:
                pass
        if kind == "result":
            let (error_member, _) = lowering.guard_failure_projection(ctx, storage_ty, storage_ref)
            if is_task_ret:
                var result_fail_fields = vec.Vec[ir.AggregateField].create()
                result_fail_fields.push(ir.AggregateField(name = "error", value = error_member))
                let result_failure = async_cps.extract_task_element_type(ctx, ret_ty)
                let failure_result = lowering.alloc_expr(ir.Expr.expr_variant_literal(
                    ty = result_failure,
                    arm_name = "failure",
                    fields = result_fail_fields.as_span()
                ))
                var task_fields = vec.Vec[ir.AggregateField].create()
                let void_zero = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ctx.ptr_void_ty))
                task_fields.push(ir.AggregateField(name = "value", value = failure_result))
                task_fields.push(ir.AggregateField(name = "frame", value = void_zero))
                task_fields.push(ir.AggregateField(name = "ready", value = void_zero))
                task_fields.push(ir.AggregateField(name = "set_waiter", value = void_zero))
                task_fields.push(ir.AggregateField(name = "release", value = void_zero))
                task_fields.push(ir.AggregateField(name = "take_result", value = void_zero))
                task_fields.push(ir.AggregateField(name = "cancel", value = void_zero))
                fail_value = lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = ret_ty, fields = task_fields.as_span()))
            else:
                var fail_fields = vec.Vec[ir.AggregateField].create()
                fail_fields.push(ir.AggregateField(name = "error", value = error_member))
                fail_value = lowering.alloc_expr(ir.Expr.expr_variant_literal(
                    ty = ret_ty,
                    arm_name = "failure",
                    fields = fail_fields.as_span()
                ))
        else if kind == "option":
            fail_value = lowering.alloc_expr(ir.Expr.expr_variant_literal(
                ty = ret_ty,
                arm_name = "none",
                fields = span[ir.AggregateField]()
            ))

    # Failure branch: return the appropriate failure value.
    var fail_body = vec.Vec[ir.Stmt].create()
    lowering.flush_all_defers(ctx, ref_of(fail_body))
    fail_body.push(ir.Stmt.stmt_return(value = fail_value, line = 0, source_path = source_path))

    let cond = lowering.guard_failure_condition(ctx, kind, storage_ty, storage_ref)
    output.push(ir.Stmt.stmt_if(
        condition = cond,
        then_body = fail_body.as_span(),
        else_body = Option[span[ir.Stmt]].none
    ))

    # On success, return the unwrapped value.
    let success_ty = lowering.guard_success_type(ctx, kind, storage_ty)
    let success_val = lowering.guard_success_projection(ctx, kind, storage_ty, storage_ref, success_ty)
    output.push(ir.Stmt.stmt_return(value = success_val, line = line, source_path = source_path))

public function lower_plain_local_stmt(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    sp: ptr[ast.Stmt],
    c_name: str
) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as loc:
                var ty: types.Type
                var value_expr: ptr[ir.Expr]
                let init = loc.value
                let hoist_base = output.len()
                let hoist_saved = lowering.begin_stmt_setup(ctx, lowering.HoistMode.hm_value)
                ctx.hoist_root_ep = init
                if init != null:
                    # The local's storage type: the declared annotation, else
                    # the analyzer's inferred initializer type.  An array there
                    # keeps the root call inline (the host's
                    # `materialize_array_calls: !array_type?(storage_type)`).
                    var storage_is_array = false
                    let declared_ref0 = loc.stmt_type
                    if declared_ref0 != null:
                        storage_is_array = lowering.is_array_type(lowering.resolve_type_ref(ctx, unsafe: ptr[ast.TypeRef]<-declared_ref0))
                    if not storage_is_array:
                        storage_is_array = lowering.is_array_type(type_helpers.expr_type(ctx, init))
                    # The async statement preparers materialize array calls
                    # unconditionally (they never pass the sync root exemption).
                    if storage_is_array and not ctx.async_completion_active:
                        ctx.array_call_exempt = init
                if init == null:
                    let declared = loc.stmt_type else:
                        fatal(c"lowering: local without initializer requires a type")
                    ty = lowering.resolve_type_ref(ctx, declared)
                    if lowering.is_user_generic_struct(ctx, ty):
                        let _ = lowering.qualify_type(ctx, ty)
                    value_expr = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = ty))
                else:
                    # `var a: array[T, N] = (e0, e1, ...)` lowers the tuple
                    # literal directly to an array initializer (a tuple value
                    # cannot be memcpy'd into an array).
                    var direct_array: ptr[ir.Expr]? = null
                    let declared_ref = loc.stmt_type
                    if declared_ref != null:
                        let declared_ty = lowering.resolve_type_ref(ctx, unsafe: ptr[ast.TypeRef]<-declared_ref)
                        if lowering.is_array_type(declared_ty):
                            unsafe:
                                match read(init):
                                    ast.Expr.expr_expression_list as el:
                                        var elements = vec.Vec[ir.Expr].create()
                                        var ei: ptr_uint = 0
                                        while ei < el.elements.len:
                                            elements.push(read(lowering.lower_expr(ctx, el.elements.data + ei)))
                                            ei += 1
                                        direct_array = lowering.alloc_expr(ir.Expr.expr_array_literal(
                                            ty = declared_ty,
                                            elements = elements.as_span()
                                        ))
                                    _:
                                        pass
                    var direct_val: ptr[ir.Expr]
                    if direct_array != null:
                        direct_val = unsafe: ptr[ir.Expr]<-direct_array
                    else:
                        direct_val = lowering.lower_expr(ctx, init)
                    value_expr = direct_val
                    if loc.stmt_type != null:
                        ty = lowering.local_decl_type(ctx, loc.stmt_type, init)
                        if lowering.is_user_generic_struct(ctx, ty):
                            let _ = lowering.qualify_type(ctx, ty)
                        if types.is_error(ty):
                            ty = lowering.ir_expr_type(value_expr)
                    else:
                        # The unannotated decl's type comes from *inference* of
                        # the initializer (`block.rb:718-729`: `type =
                        # storage_type = infer_expression_type(value)`), not
                        # from the lowered value: a guard-bound read lowers to
                        # the storage `Nullable(...)` under the host's
                        # pointer-like rule while inferring the visible success
                        # type (`let data_ptr = data` in `String.push_byte`).
                        # Inference mirrors `infer_expression_type` exactly: an
                        # identifier takes its *visible* type from the lowering
                        # env (the host's cache shortcut skips identifiers —
                        # refinement lives in `lookup_value`), and a foreign
                        # wrapper call takes the wrapper's declared return (a
                        # simple mapping's lowered call carries the raw
                        # declaration's return instead — `ptr[char]` for a
                        # `cstr?` wrapper, the 3j rule).  Everything else keeps
                        # the lowered value's type, which carries the
                        # module-qualified nominal.
                        unsafe:
                            match read(ptr[ast.Expr]<-init):
                                ast.Expr.expr_identifier:
                                    ty = lowering.qualify_type(ctx, type_helpers.fallback_type(ctx, ptr[ast.Expr]<-init))
                                ast.Expr.expr_call as call:
                                    match lowering.foreign_wrapper_call_return_type(ctx, call.callee):
                                        Option.some as declared:
                                            ty = declared.value
                                        Option.none:
                                            ty = lowering.qualify_type(ctx, lowering.ir_expr_type(value_expr))
                                ast.Expr.expr_detach:
                                    # The host's inference gives a detach value the
                                    # singleton `Handle`, while its lowered call
                                    # node carries `ptr[void]`.
                                    ty = lowering.qualify_type(ctx, type_helpers.expr_type(ctx, ptr[ast.Expr]<-init))
                                    if types.is_error(ty):
                                        ty = lowering.qualify_type(ctx, lowering.ir_expr_type(value_expr))
                                _:
                                    ty = lowering.qualify_type(ctx, lowering.ir_expr_type(value_expr))
                                    # A numeric-aggregate expression's storage
                                    # type is the aggregate even when the binary
                                    # node lowers with its scalar operand type:
                                    # the host's analyzer records the simd/vec
                                    # result (`simd_op_result`,
                                    # `vector_arithmetic_result`) and its
                                    # unannotated inference reuses that record,
                                    # while the binary lowering passes the
                                    # aggregate as the expected type and computes
                                    # the scalar operand type instead.
                                    let recorded = type_helpers.expr_type(ctx, ptr[ast.Expr]<-init)
                                    if type_helpers.is_numeric_aggregate_type(recorded):
                                        match lowering.ir_expr_type(value_expr):
                                            types.Type.ty_primitive:
                                                ty = lowering.qualify_type(ctx, recorded)
                                            _:
                                                pass
                # A float, integer, bare string or `null` literal in a declared
                # `float`/`double`, integer (`ptr_uint`, `ubyte`, …), `cstr` or
                # nullable position takes that type (the host's contextual
                # literal inference).
                if init != null:
                    value_expr = lowering.contextual_value_to_type(
                        ctx,
                        ptr[ast.Expr]<-init,
                        ty,
                        value_expr,
                        loc.stmt_type != null and types.is_float_type(ty) and not lowering.is_foreign_call_initializer(
                            ctx,
                            ptr[ast.Expr]<-init
                        ),
                        false,
                    )
                # Wrap a non-nullable value into a value-type nullable's opt struct.
                if types.is_nullable_type(ty) and not lowering.is_nullable_pointer_like(ty):
                    let value_ty = lowering.ir_expr_type(value_expr)
                    if not types.is_nullable_type(value_ty):
                        match read(value_expr):
                            ir.Expr.expr_null_literal:
                                value_expr = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = ty))
                            _:
                                value_expr = lowering.nullable_some_literal(ty, value_expr)
                let decl_line = if ctx.async_nonawait_body: 0z else: loc.line
                let decl_path = if ctx.async_nonawait_body: "" else: ctx.analysis.source_path
                output.push(ir.Stmt.stmt_local(
                    name = loc.name,
                    linkage_name = c_name,
                    ty = ty,
                    value = value_expr,
                    line = decl_line,
                    source_path = decl_path,
                ))
                let hoist_collected = lowering.collect_stmt_setup(ctx, hoist_saved)
                lowering.emit_hoist_setup(output, hoist_base, hoist_collected)
                # A `str`/`cstr` local (or one holding such a field) owns a
                # dynamic format string's buffer: its release is dropped
                # (the host's `reject_format_releases_for_assignment`).  The
                # remaining cleanups become block defers (the host's
                # `local_defers.concat(prepared_cleanups)`), not immediate
                # post-statement statements.
                let local_cleanups = if format.format_owning_target_type(ctx, ty, 0):
                    format.drop_format_release_cleanups(hoist_collected)
                else:
                    hoist_collected
                lowering.record_or_emit_local_cleanups(ctx, output, local_cleanups.cleanups)
                ctx.locals.push(lowering.LocalBinding(
                    name = loc.name,
                    c_name = c_name,
                    ty = ty,
                    pointer = Option[bool].some(value = false)
                ))
                if format.cstr_backed_binding(ctx, ty, init, value_expr):
                    ctx.cstr_backed_names.set(c_name, true)
                # A proc-containing local owns a reference: its release runs as a
                # defer at every scope exit (guarded, for a zero-initialized var
                # too), and a non-fresh initializer is retained for the new owner
                # (the host's `local_defers` + selective retain, `block.rb:824-830`).
                if lowering.contains_proc_storage_type(ctx, ty):
                    let proc_local_ref = lowering.alloc_expr(ir.Expr.expr_name(
                        name = c_name,
                        ty = ty,
                        pointer = Option[bool].some(value = false)
                    ))
                    var proc_release_body = vec.Vec[ir.Stmt].create()
                    lowering.proc_nullable_release_stmts(ctx, proc_local_ref, ty, ref_of(proc_release_body))
                    lowering.record_defer(ctx, proc_release_body.as_span())
                    if init != null and not lowering.proc_expr_contains_proc_expr(ptr[ast.Expr]<-init):
                        lowering.proc_contained_retain_stmts(ctx, proc_local_ref, ty, output)
            _:
                pass

