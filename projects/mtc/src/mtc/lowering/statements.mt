## Return-statement lowering, extracted from lowering/lowering.mt (Wave 4.2).
## The body is verbatim apart from module qualification of lowering helpers.

import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types

import mtc.lowering.async as async_mod
import mtc.lowering.async_cps as async_cps
import mtc.lowering.format as format
import mtc.lowering.inline as inline_mod
import mtc.lowering.lowering as lowering
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.match as match_mod
import mtc.lowering.tasks as tasks
import mtc.lowering.utils as utils
import mtc.strings


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

function lower_assignment_stmt(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], sp: ptr[ast.Stmt]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_assignment as asg:
                # Async CPS: an assignment whose value contains an await.  For a
                # plain `x = await Y` (operator `=`), assign the awaited result
                # straight into the target.  For a compound operator (`+=` etc.)
                # or an embedded await, hoist the await(s) into temp frame locals
                # first, then emit the (await-free) assignment normally.
                if ctx.async_cps_active and async_mod.expr_has_await(asg.value):
                    if asg.operator == "=" and async_cps.expr_is_direct_await(asg.value):
                        let asg_target = lowering.lower_assignment_target(ctx, asg.target)
                        async_cps.lower_async_await_into(
                            ctx,
                            output,
                            async_cps.direct_await_inner(asg.value),
                            Option[ptr[ir.Expr]].some(value = asg_target)
                        )
                        return
                    let hoisted = async_cps.async_hoist_awaits(ctx, output, asg.value)
                    output.push(ir.Stmt.stmt_assignment(
                        target = lowering.lower_assignment_target(ctx, asg.target),
                        operator = asg.operator,
                        value = lowering.lower_expr(ctx, hoisted)
                    ))
                    return
                # Lower `arr[start..end] = (e1, e2, ...)` — range index assignment.
                # Expand into individual checked-index assignments, one per RHS element.
                match read(asg.target):
                    ast.Expr.expr_index_access as idx_target:
                        match read(idx_target.index):
                            ast.Expr.expr_range as rng:
                                match read(asg.value):
                                    ast.Expr.expr_expression_list as els:
                                        lowering.lower_range_index_assignment(
                                            ctx,
                                            output,
                                            idx_target.receiver,
                                            rng.start_expr,
                                            els.elements
                                        )
                                        return
                                    _:
                                        pass
                            _:
                                pass
                    _:
                        pass
                # Desugar `read(x) = value` to `*x = value`.
                var target_expr = asg.target
                # `target = expr?` — Result/Option propagation into an existing
                # lvalue (not a `let` binding).  Unwrap on success into the target;
                # on failure return/complete-early like `let _ = expr? / return`.
                if asg.operator == "=":
                    match read(asg.value):
                        ast.Expr.expr_unary_op as un:
                            if un.operator == "?":
                                lowering.lower_propagate_assign(ctx, output, asg.target, un.operand)
                                return
                        _:
                            pass
                match lowering.is_read_call(target_expr):
                    Option.some as inner:
                        let deref_target = lowering.lower_expr(ctx, inner.value)
                        # The deref's type is the handle's value type (the host's
                        # `infer_value_type`, `utils.rb:128`): a pointer-like
                        # nullable unwraps to its base, then the pointee/referent.
                        # Falls back to the recorded `read(...)` type when the
                        # handle is not a pointer.
                        var deref_ty = type_helpers.expr_type(ctx, inner.value)
                        if types.is_nullable_type(deref_ty) and lowering.is_nullable_pointer_like(deref_ty):
                            deref_ty = types.unwrap_nullable(deref_ty)
                        let pointee_ty = types.pointer_element(deref_ty)
                        if types.is_error(pointee_ty):
                            deref_ty = type_helpers.expr_type(ctx, target_expr)
                        else:
                            deref_ty = pointee_ty
                        let target = lowering.alloc_expr(ir.Expr.expr_unary(
                            operator = "*",
                            operand = deref_target,
                            ty = deref_ty
                        ))
                        let hoist_base = output.len()
                        let hoist_saved = lowering.begin_stmt_setup(ctx, lowering.HoistMode.hm_value)
                        ctx.hoist_root_ep = asg.value
                        if lowering.is_array_type(deref_ty) and not ctx.async_completion_active:
                            ctx.array_call_exempt = asg.value
                        var value = lowering.lower_expr(ctx, asg.value)
                        let hoist_collected = lowering.collect_stmt_setup(ctx, hoist_saved)
                        lowering.emit_hoist_setup(output, hoist_base, hoist_collected)
                        value = lowering.contextual_value_to_type(
                            ctx,
                            asg.value,
                            deref_ty,
                            value,
                            types.is_float_type(deref_ty) and not lowering.is_foreign_call_initializer(ctx, asg.value),
                            false
                        )
                        output.push(ir.Stmt.stmt_assignment(target = target, operator = asg.operator, value = value))
                        let read_target_cleanups = if format.format_owning_target_type(ctx, deref_ty, 0):
                            format.drop_format_release_cleanups(hoist_collected)
                        else:
                            hoist_collected
                        lowering.record_or_emit_local_cleanups(ctx, output, read_target_cleanups.cleanups)
                        return
                    Option.none:
                        pass
                let target = lowering.lower_assignment_target(ctx, asg.target)
                let hoist_base = output.len()
                let hoist_saved = lowering.begin_stmt_setup(ctx, lowering.HoistMode.hm_value)
                ctx.hoist_root_ep = asg.value
                if lowering.is_array_type(type_helpers.expr_type(ctx, asg.target)) and not ctx.async_completion_active:
                    ctx.array_call_exempt = asg.value
                var value = lowering.lower_expr(ctx, asg.value)
                let hoist_collected = lowering.collect_stmt_setup(ctx, hoist_saved)
                lowering.emit_hoist_setup(output, hoist_base, hoist_collected)
                # The host passes the lowered target's *storage* type as the
                # expected type (`block.rb:527,555`), not the analyzer's
                # flow-refined type: inside `if x == null`, the refined `null`
                # must not retype a `null` RHS (the declared `ptr[T]?` wins).
                var target_ty = lowering.ir_expr_type(target)
                if types.is_error(target_ty) or types.is_void(target_ty):
                    target_ty = type_helpers.expr_type(ctx, asg.target)
                # A bare literal takes the target's type (the host's
                # `lower_contextual_expression` with the target as the expected
                # type): `i = 1` / `i += 1` on a `ptr_uint` target emits a
                # `ptr_uint` literal, not an `int` one.  Mirrors the local
                # declaration arm's literal set.
                value = lowering.contextual_value_to_type(
                    ctx,
                    asg.value,
                    target_ty,
                    value,
                    types.is_float_type(target_ty) and not lowering.is_foreign_call_initializer(ctx, asg.value),
                    lowering.external_numeric_assignment_target(ctx, asg.target),
                )
                format.update_cstr_metadata_for_assignment_mt(ctx, asg.target, asg.value, value, asg.operator)
                # Native math compound assignment (`a += b`, `a *= 2.0`): the C
                # aggregate structs have no operators, so expand component-wise
                # and emit a plain assignment.
                if type_helpers.is_compound_assignment_operator(asg.operator):
                    var math_name = type_helpers.nominal_type_name(target_ty)
                    if not type_helpers.is_vec_math_name(math_name):
                        math_name = type_helpers.nominal_type_name(lowering.ir_expr_type(target))
                    if type_helpers.is_vec_math_name(math_name):
                        let expanded = type_helpers.lower_vec_binary_op(
                            ctx,
                            type_helpers.compound_base_operator(asg.operator),
                            target,
                            value,
                            target_ty,
                            math_name
                        )
                        output.push(ir.Stmt.stmt_assignment(target = target, operator = "=", value = expanded))
                        let math_cleanups = if format.format_owning_target_type(ctx, target_ty, 0):
                            format.drop_format_release_cleanups(hoist_collected)
                        else:
                            hoist_collected
                        lowering.record_or_emit_local_cleanups(ctx, output, math_cleanups.cleanups)
                        return
                if types.is_nullable_type(target_ty) and not lowering.is_nullable_pointer_like(target_ty):
                    let value_ty = lowering.ir_expr_type(value)
                    if not types.is_nullable_type(value_ty):
                        match read(value):
                            ir.Expr.expr_null_literal:
                                value = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = target_ty))
                            _:
                                value = lowering.nullable_some_literal(target_ty, value)
                # A proc-containing target's assignment owns a reference: retain a
                # non-fresh RHS, release the old value, then store through a temp
                # (the host's `proc_assign` shape, `block.rb:583-590`).
                if asg.operator == "=" and lowering.contains_proc_storage_type(ctx, target_ty):
                    let rhs_temp = lowering.fresh_c_temp_name(ctx, "proc_assign")
                    let rhs_c = utils.c_local_name(rhs_temp)
                    output.push(ir.Stmt.stmt_local(
                        name = rhs_temp,
                        linkage_name = rhs_c,
                        ty = target_ty,
                        value = value,
                        line = 0,
                        source_path = ""
                    ))
                    let rhs_ref = lowering.alloc_expr(ir.Expr.expr_name(
                        name = rhs_c,
                        ty = target_ty,
                        pointer = Option[bool].some(value = false)
                    ))
                    lowering.proc_selective_retain_stmts(ctx, rhs_ref, asg.value, target_ty, output)
                    lowering.proc_nullable_release_stmts(ctx, target, target_ty, output)
                    output.push(ir.Stmt.stmt_assignment(target = target, operator = asg.operator, value = rhs_ref))
                else:
                    output.push(ir.Stmt.stmt_assignment(target = target, operator = asg.operator, value = value))
                let assign_cleanups = if format.format_owning_target_type(ctx, target_ty, 0):
                    format.drop_format_release_cleanups(hoist_collected)
                else:
                    hoist_collected
                lowering.record_or_emit_local_cleanups(ctx, output, assign_cleanups.cleanups)
            _:
                pass


function lower_while_stmt(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], sp: ptr[ast.Stmt]) -> void:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_while as w:
                if w.is_inline:
                    inline_mod.lower_inline_while(ctx, output, w.condition, w.body)
                    return
                # Async CPS: an await in the loop condition must be re-evaluated
                # (and may suspend) each iteration.  The host normalizer also
                # restructures an await-free condition that contains `and`/`or`
                # (its setup is non-empty) and spills the evaluated condition to
                # a `cond_name` frame temp.  Restructure to
                # `while (true) { <cond setup>; cond = <cond>; if (!cond) break; <body> }`.
                if (
                    ctx.async_cps_active
                    and (async_mod.expr_has_await(w.condition) or async_mod.expr_has_short_circuit(w.condition))
                ):
                    var wbody = vec.Vec[ir.Stmt].create()
                    # The host normalizes the condition into the loop body and
                    # lowers that body as a unit: when neither the condition nor
                    # the body awaits, the generated condition temps are plain
                    # locals (their frame fields still register); an await in
                    # either keeps the whole body on the CF path.
                    let loop_needs_cps = async_mod.expr_has_await(w.condition) or async_mod.body_has_await(w.body)
                    let loop_cps = ctx.async_cps_active
                    if not loop_needs_cps:
                        ctx.async_cps_active = false
                    let saved_structured = ctx.async_structured_setup
                    ctx.async_structured_setup = true
                    let cond_hoisted = async_cps.async_hoist_awaits(ctx, ref_of(wbody), w.condition)
                    ctx.async_structured_setup = saved_structured
                    # The host's `normalize_async_expression` evaluates the
                    # condition into a fresh `cond_name` bool local after the
                    # condition setup and declares it inside the loop body
                    # (`normalization.rb:107`), so its field registers after the
                    # setup temps but before the body locals.
                    let cond_base = wbody.len()
                    let cond_saved = lowering.begin_stmt_setup(ctx, lowering.HoistMode.hm_value)
                    let cond_ir = lowering.lower_expr(ctx, cond_hoisted)
                    let cond_collected = lowering.collect_stmt_setup(ctx, cond_saved)
                    lowering.emit_hoist_setup(ref_of(wbody), cond_base, cond_collected)
                    ctx.async_tmp_counter += 1
                    let cond_tmp = strings.join_two("__mt_async_tmp_", lowering.pw1_str(ctx.async_tmp_counter))
                    let cond_field = strings.join_two("local_", cond_tmp)
                    let cond_frame = strings.join_two("__mt_frame->", cond_field)
                    var cond_name: str
                    if ctx.async_cps_active:
                        async_cps.async_register_local_field(ctx, cond_tmp, cond_field, cond_frame, ctx.bool_ty)
                        wbody.push(async_cps.async_frame_field_assignment(ctx, cond_field, ctx.bool_ty, cond_ir))
                        cond_name = cond_frame
                    else:
                        async_cps.async_register_unused_field(ctx, cond_field, ctx.bool_ty)
                        wbody.push(ir.Stmt.stmt_local(
                            name = cond_tmp,
                            linkage_name = cond_tmp,
                            ty = ctx.bool_ty,
                            value = cond_ir,
                            line = 0,
                            source_path = ""
                        ))
                        cond_name = cond_tmp
                    lowering.append_hoist_cleanups(ref_of(wbody), cond_collected)
                    let cond_ref = lowering.alloc_expr(ir.Expr.expr_name(
                        name = cond_name,
                        ty = ctx.bool_ty,
                        pointer = Option[bool].some(value = false)
                    ))
                    # Use goto labels so user-written `break`/`continue` inside the
                    # loop body (including inside match→switch arms) still exit the
                    # correct enclosing loop.
                    let saved_break = ctx.loop_break_label
                    let saved_continue = ctx.loop_continue_label
                    let saved_continue_native = ctx.loop_continue_native
                    let saved_break_native = ctx.loop_break_native
                    let saved_loop_depth = ctx.loop_defer_depth
                    let cl = lowering.fresh_c_temp_name(ctx, "loop_continue")
                    let bl = lowering.fresh_c_temp_name(ctx, "loop_break")
                    ctx.loop_break_label = bl
                    ctx.loop_continue_label = cl
                    ctx.loop_defer_depth = ctx.defer_stack.len()
                    ctx.loop_continue_native = true
                    ctx.loop_break_native = true
                    var brk = vec.Vec[ir.Stmt].create()
                    brk.push(ir.Stmt.stmt_break())
                    wbody.push(ir.Stmt.stmt_if(
                        condition = lowering.alloc_expr(ir.Expr.expr_unary(
                            operator = "not",
                            operand = cond_ref,
                            ty = ctx.bool_ty
                        )),
                        then_body = brk.as_span(),
                        else_body = Option[span[ir.Stmt]].none
                    ))
                    ctx.async_cps_active = loop_cps
                    ctx.async_force_cps_body = loop_needs_cps
                    let inner = lowering.lower_block(ctx, w.body)
                    var ii: ptr_uint = 0
                    while ii < inner.len:
                        wbody.push(unsafe: read(inner.data + ii))
                        ii += 1
                    if lowering.contains_label_target(wbody.as_span(), cl):
                        wbody.push(ir.Stmt.stmt_label(name = cl))
                    var wrap = vec.Vec[ir.Stmt].create()
                    wrap.push(ir.Stmt.stmt_while(
                        condition = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = ctx.bool_ty)),
                        body = wbody.as_span()
                    ))
                    if lowering.contains_label_target(wbody.as_span(), bl):
                        wrap.push(ir.Stmt.stmt_label(name = bl))
                    # The host's CF path (`lower_async_cf_while_stmt`) emits the
                    # while (and any break label) directly, without the sync
                    # path's scoping block.
                    var wi: ptr_uint = 0
                    while wi < wrap.len():
                        let wsp = wrap.get(wi) else:
                            break
                        output.push(unsafe: read(wsp))
                        wi += 1
                    ctx.loop_break_label = saved_break
                    ctx.loop_continue_label = saved_continue
                    ctx.loop_continue_native = saved_continue_native
                    ctx.loop_break_native = saved_break_native
                    ctx.loop_defer_depth = saved_loop_depth
                    return
                let cond = lowering.lower_expr(ctx, w.condition)
                let saved_break = ctx.loop_break_label
                let saved_continue = ctx.loop_continue_label
                let saved_continue_native = ctx.loop_continue_native
                let saved_break_native = ctx.loop_break_native
                let saved_loop_depth = ctx.loop_defer_depth
                let cl = lowering.fresh_c_temp_name(ctx, "loop_continue")
                let bl = lowering.fresh_c_temp_name(ctx, "loop_break")
                ctx.loop_break_label = bl
                ctx.loop_continue_label = cl
                ctx.loop_defer_depth = ctx.defer_stack.len()
                # A plain C `while`'s continue point is the loop's condition, so
                # a native `continue` here reaches exactly the label's position;
                # a native `break` likewise exits exactly this loop (unless a
                # match's `switch` intervenes, which clears the flag around its
                # arms).
                ctx.loop_continue_native = true
                ctx.loop_break_native = true
                # The body sees the condition's truthy refinements (the host's
                # `lower_while_stmt`, `loops.rb:28`).
                var while_refs = type_helpers.lowering_flow_refinements(ctx, w.condition, true)
                let while_flow_saved = type_helpers.push_flow_refinements(ctx, ref_of(while_refs))
                let body_span = lowering.lower_block(ctx, w.body)
                type_helpers.restore_flow_refinements(ctx, while_flow_saved)
                var body = vec.Vec[ir.Stmt].create()
                lowering.append_span_stmts(ref_of(body), body_span)
                if lowering.contains_label_target(body.as_span(), cl):
                    body.push(ir.Stmt.stmt_label(name = cl))
                var wrap = vec.Vec[ir.Stmt].create()
                wrap.push(ir.Stmt.stmt_while(condition = cond, body = body.as_span()))
                if lowering.contains_label_target(body.as_span(), bl):
                    wrap.push(ir.Stmt.stmt_label(name = bl))
                if ctx.async_cps_active:
                    # The host's CF path emits the while directly (no scoping
                    # block); only the sync path wraps it.
                    var wi: ptr_uint = 0
                    while wi < wrap.len():
                        let wsp = wrap.get(wi) else:
                            break
                        output.push(unsafe: read(wsp))
                        wi += 1
                else:
                    output.push(ir.Stmt.stmt_block(body = wrap.as_span()))
                ctx.loop_break_label = saved_break
                ctx.loop_continue_label = saved_continue
                ctx.loop_continue_native = saved_continue_native
                ctx.loop_break_native = saved_break_native
                ctx.loop_defer_depth = saved_loop_depth
            _:
                pass

