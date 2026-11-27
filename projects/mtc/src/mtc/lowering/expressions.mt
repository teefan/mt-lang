## Binary, identifier, and specialization expression lowering, extracted from
## lowering/lowering.mt (Wave 4.2).

import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types
import mtc.strings
import mtc.c_naming as naming

import mtc.lowering.async_cps as async_cps
import mtc.lowering.control_flow as control_flow
import mtc.lowering.format as format
import mtc.lowering.member_access as member_mod
import mtc.lowering.tasks as tasks
import mtc.lowering.async as async_mod
import mtc.lowering.comptime as comptime
import mtc.lowering.comptime_types as comptime_types
import mtc.lowering.const_eval as const_eval
import mtc.lowering.inline as inline_mod
import mtc.lowering.layout as layout_mod
import mtc.lowering.monomorphized as monomorphized
import mtc.lowering.parallel as parallel_mod
import mtc.lowering.utils as utils
import mtc.lowering.events as events_mod
import mtc.lowering.lowering as lowering
import mtc.lowering.type_helpers as type_helpers


public function lower_short_circuit_binary(
    ctx: ref[lowering.LoweringContext],
    operator: str,
    left_ep: ptr[ast.Expr],
    right_ep: ptr[ast.Expr],
    ep: ptr[ast.Expr],
) -> ptr[ir.Expr]:
    # The host's async normalizer rewrites every `and`/`or` in an async body —
    # setup or not — into a `__mt_async_tmp_N` var spilled to the frame:
    # `tmp = init; <left setup>; if left: <right setup>; tmp = right; else: tmp = init`.
    # The sync lowering keeps the prepared shape only when an operand produces
    # setup (below).
    if ctx.inside_async:
        let bool_ty = ctx.bool_ty
        # The host normalizer's declaration position: the and/or result temp is
        # declared before its operand setups, but its name is allocated after
        # them.  `async_hoist_awaits` recorded the field slot before recursing
        # into the operands; an unrecorded node starts at the current count.
        var field_index = async_cps.async_local_field_count(ctx)
        let recorded_index = ctx.async_and_or_field_indices.get(unsafe: reinterpret[ptr_uint](ep))
        if recorded_index != null:
            field_index = unsafe: read(ptr[ptr_uint]<-recorded_index)
        let left_stored_ptr = ctx.async_and_or_left_setup.get(unsafe: reinterpret[ptr_uint](ep))
        let right_stored_ptr = ctx.async_and_or_right_setup.get(unsafe: reinterpret[ptr_uint](ep))
        # Lower both operands into child windows: their setup follows the temp
        # declaration, and their cleanups follow the enclosing statement (the
        # host's prepared binary shape).
        let left_saved = lowering.begin_stmt_setup(ctx, ctx.hoist.mode)
        if left_stored_ptr != null:
            var left_stored = unsafe: read(ptr[vec.Vec[ir.Stmt]]<-left_stored_ptr)
            lowering.append_span_stmts(ref_of(ctx.hoist.stmts), left_stored.as_span())
        let left = lower_expr(ctx, left_ep)
        let left_collected = lowering.collect_stmt_setup(ctx, left_saved)
        let right_saved = lowering.begin_stmt_setup(ctx, ctx.hoist.mode)
        if right_stored_ptr != null:
            var right_stored = unsafe: read(ptr[vec.Vec[ir.Stmt]]<-right_stored_ptr)
            lowering.append_span_stmts(ref_of(ctx.hoist.stmts), right_stored.as_span())
        # The right operand sees the left operand's refinement (the host's
        # `binary_right_env`, `resolve.rb:967`).
        var right_refs = type_helpers.lowering_flow_refinements(ctx, left_ep, operator == "and")
        let right_flow_saved = type_helpers.push_flow_refinements(ctx, ref_of(right_refs))
        let right = lower_expr(ctx, right_ep)
        type_helpers.restore_flow_refinements(ctx, right_flow_saved)
        let right_collected = lowering.collect_stmt_setup(ctx, right_saved)
        lowering.append_cleanup_stmts(ref_of(ctx.hoist.cleanups), left_collected.cleanups)
        lowering.append_cleanup_stmts(ref_of(ctx.hoist.cleanups), right_collected.cleanups)
        ctx.counters.async_tmp += 1
        let tmp = strings.join_two("__mt_async_tmp_", lowering.pw1_str(ctx.counters.async_tmp))
        let field_name = strings.join_two("local_", tmp)
        let frame_cname = strings.join_two("__mt_frame->", field_name)
        let field_count_before = async_cps.async_local_field_count(ctx)
        async_cps.async_register_unused_field(ctx, field_name, bool_ty)
        if async_cps.async_local_field_count(ctx) > field_count_before:
            async_cps.async_move_last_local_field_to(ctx, field_index)
        let short_circuit_value = operator != "and"
        # A CPS body spills the normalizer's LocalDecl to a frame field; the
        # no-await async path lowers it as a plain C local (the host's
        # `lower_async_cf_statements` vs `lower_async_non_await_statements`).
        # Both keep the frame field registered.
        var value_name = frame_cname
        if ctx.async_cps_active:
            let init_target = lowering.alloc_expr(ir.Expr.expr_member(
                receiver = lowering.alloc_expr(ir.Expr.expr_name(
                    name = "__mt_frame",
                    ty = ctx.async_frame_ptr_ty,
                    pointer = Option[bool].some(value = false)
                )),
                member = field_name,
                ty = bool_ty
            ))
            ctx.hoist.stmts.push(ir.Stmt.stmt_assignment(
                target = init_target,
                operator = "=",
                value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = short_circuit_value, ty = bool_ty))
            ))
        else:
            value_name = tmp
            ctx.hoist.stmts.push(ir.Stmt.stmt_local(
                name = tmp,
                linkage_name = tmp,
                ty = bool_ty,
                value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = short_circuit_value, ty = bool_ty)),
                line = 0,
                source_path = ""
            ))
        var left_stmts = left_collected.stmts
        lowering.append_span_stmts(ref_of(ctx.hoist.stmts), left_stmts.as_span())
        # `and`: left true -> value = right, left false -> value = false.
        # `or`:  left true -> value = true,  left false -> value = right.
        # The host swaps the two branch bodies for `or`
        # (`normalize_async_expression`'s BinaryOp arm).
        var right_stmts = vec.Vec[ir.Stmt].create()
        var ri: ptr_uint = 0
        while ri < right_collected.stmts.len:
            let stmt = right_collected.stmts.get(ri) else:
                break
            right_stmts.push(unsafe: read(stmt))
            ri += 1
        let right_target = lowering.alloc_expr(ir.Expr.expr_name(
            name = value_name,
            ty = bool_ty,
            pointer = Option[bool].some(value = false)
        ))
        let short_target = lowering.alloc_expr(ir.Expr.expr_name(
            name = value_name,
            ty = bool_ty,
            pointer = Option[bool].some(value = false)
        ))
        let right_assign = ir.Stmt.stmt_assignment(target = right_target, operator = "=", value = right)
        let short_assign = ir.Stmt.stmt_assignment(
            target = short_target,
            operator = "=",
            value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = short_circuit_value, ty = bool_ty))
        )
        var then_body = vec.Vec[ir.Stmt].create()
        var else_body = vec.Vec[ir.Stmt].create()
        if operator == "and":
            lowering.append_span_stmts(ref_of(then_body), right_stmts.as_span())
            then_body.push(right_assign)
            else_body.push(short_assign)
        else:
            then_body.push(short_assign)
            lowering.append_span_stmts(ref_of(else_body), right_stmts.as_span())
            else_body.push(right_assign)
        ctx.hoist.stmts.push(ir.Stmt.stmt_if(
            condition = left,
            then_body = then_body.as_span(),
            else_body = Option[span[ir.Stmt]].some(value = else_body.as_span())
        ))
        return lowering.alloc_expr(ir.Expr.expr_name(
            name = value_name,
            ty = bool_ty,
            pointer = Option[bool].some(value = false)
        ))
    let setup_base = ctx.hoist.stmts.len
    let left = lower_expr(ctx, left_ep)
    let left_has_setup = ctx.hoist.stmts.len > setup_base
    let right_saved = lowering.begin_stmt_setup(ctx, ctx.hoist.mode)
    var right_refs = type_helpers.lowering_flow_refinements(ctx, left_ep, operator == "and")
    let right_flow_saved = type_helpers.push_flow_refinements(ctx, ref_of(right_refs))
    let right = lower_expr(ctx, right_ep)
    type_helpers.restore_flow_refinements(ctx, right_flow_saved)
    let right_collected = lowering.collect_stmt_setup(ctx, right_saved)
    let right_has_setup = right_collected.stmts.len > 0
    lowering.append_cleanup_stmts(ref_of(ctx.hoist.cleanups), right_collected.cleanups)
    if not left_has_setup and not right_has_setup:
        return lowering.alloc_expr(ir.Expr.expr_binary(operator = operator, left = left, right = right, ty = ctx.bool_ty))
    let result_c = lowering.fresh_c_temp_name(ctx, operator)
    let result_ty = ctx.bool_ty
    let result_ref = lowering.alloc_expr(ir.Expr.expr_name(
        name = result_c,
        ty = result_ty,
        pointer = Option[bool].some(value = false)
    ))
    ctx.hoist.stmts.push(ir.Stmt.stmt_local(
        name = result_c,
        linkage_name = result_c,
        ty = result_ty,
        value = left,
        line = 0,
        source_path = "",
    ))
    let cond = if operator == "and":
        result_ref
    else:
        lowering.alloc_expr(ir.Expr.expr_unary(operator = "not", operand = result_ref, ty = result_ty))
    var then_body = vec.Vec[ir.Stmt].create()
    var ri: ptr_uint = 0
    while ri < right_collected.stmts.len:
        let stmt = right_collected.stmts.get(ri) else:
            break
        then_body.push(unsafe: read(stmt))
        ri += 1
    then_body.push(ir.Stmt.stmt_assignment(target = result_ref, operator = "=", value = right))
    ctx.hoist.stmts.push(ir.Stmt.stmt_if(
        condition = cond,
        then_body = then_body.as_span(),
        else_body = Option[span[ir.Stmt]].none
    ))
    return lowering.alloc_expr(ir.Expr.expr_name(name = result_c, ty = result_ty, pointer = Option[bool].some(value = false)))


public function lower_expr(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr]) -> ptr[ir.Expr]:
    if lowering.lowering_failed(ctx):
        return lowering.poison_expr()
    unsafe:
        match read(ep):
            ast.Expr.expr_integer_literal as lit:
                return lowering.alloc_expr(ir.Expr.expr_integer_literal(
                    value = long<-lit.value,
                    ty = type_helpers.expr_type(ctx, ep)
                ))
            ast.Expr.expr_float_literal as lit:
                return lowering.alloc_expr(ir.Expr.expr_float_literal(value = lit.value, ty = type_helpers.expr_type(ctx, ep)))
            ast.Expr.expr_char_literal as lit:
                return lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-lit.value, ty = types.primitive("ubyte")))
            ast.Expr.expr_bool_literal as b:
                return lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = b.value, ty = ctx.bool_ty))
            ast.Expr.expr_if as ie:
                let cond = lower_expr(ctx, ie.condition)
                let hoist_saved = lowering.suspend_stmt_setup(ctx)
                # Each branch sees the condition's truthy/falsy refinements (the
                # host's `then_env`/`else_env`, `expressions.rb:1101`).
                var then_refs = type_helpers.lowering_flow_refinements(ctx, ie.condition, true)
                let then_flow_saved = type_helpers.push_flow_refinements(ctx, ref_of(then_refs))
                var then_e = lower_expr(ctx, ie.then_expr)
                type_helpers.restore_flow_refinements(ctx, then_flow_saved)
                var else_refs = type_helpers.lowering_flow_refinements(ctx, ie.condition, false)
                let else_flow_saved = type_helpers.push_flow_refinements(ctx, ref_of(else_refs))
                var else_e = lower_expr(ctx, ie.else_expr)
                type_helpers.restore_flow_refinements(ctx, else_flow_saved)
                lowering.resume_stmt_setup(ctx, hoist_saved)
                # The conditional's type is the host's branch-common inference
                # (`conditional_common_type`), and each branch is lowered
                # contextually to it (`lower_contextual_expression`), so
                # `if flag: 0 else: <ptr_uint call>` emits `ptr_uint` literals.
                var ty = type_helpers.expr_type(ctx, ep)
                if types.is_error(ty) or types.type_to_string(ty) == "void":
                    ty = lowering.ir_expr_type(then_e)
                then_e = lowering.literal_value_to_context_type(ctx, ie.then_expr, ty, then_e)
                else_e = lowering.literal_value_to_context_type(ctx, ie.else_expr, ty, else_e)
                return lowering.alloc_expr(ir.Expr.expr_conditional(
                    condition = cond,
                    then_expression = then_e,
                    else_expression = else_e,
                    ty = ty
                ))
            ast.Expr.expr_unsafe as u:
                return lower_expr(ctx, u.expression)
            ast.Expr.expr_string_literal as lit:
                let ty = if lit.is_cstring: types.primitive("cstr") else: types.Type.ty_str
                return lowering.alloc_expr(ir.Expr.expr_string_literal(value = lit.value, ty = ty, cstring = lit.is_cstring))
            ast.Expr.expr_identifier as id:
                return lower_identifier_expr(ctx, ep, id.name)
            ast.Expr.expr_binary_op as bin:
                return lower_binary_expr(ctx, ep, bin.operator, bin.left, bin.right)
            ast.Expr.expr_unary_op as un:
                let operand = lower_expr(ctx, un.operand)
                let op_ty = lowering.ir_expr_type(operand)
                if un.operator == "-":
                    let vname = type_helpers.nominal_type_name(op_ty)
                    if type_helpers.is_vec_math_name(vname):
                        return type_helpers.lower_vec_unary_neg(ctx, operand, vname)
                # The host types a unary with its *operand's* lowered type
                # (`infer_expression_type`'s UnaryOp arm; `not` is bool), not the
                # analyzer's recorded expression type.
                let un_ty = if un.operator == "not": ctx.bool_ty else: op_ty
                return lowering.alloc_expr(ir.Expr.expr_unary(operator = un.operator, operand = operand, ty = un_ty))
            ast.Expr.expr_prefix_cast as pc:
                let target_ty = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, pc.target_type))
                let lowered_expr = lower_expr(ctx, pc.expression)
                return lowering.alloc_expr(ir.Expr.expr_cast(target_type = target_ty, expression = lowered_expr, ty = target_ty))
            ast.Expr.expr_call as call:
                return lowering.maybe_materialize_array_call(ctx, ep, lowering.lower_call(ctx, call.callee, call.args, ep))
            ast.Expr.expr_member_access as ma:
                return member_mod.lower_member_access(ctx, ma.receiver, ma.member_name, ep)
            ast.Expr.expr_index_access as ix:
                return lowering.lower_index_access(ctx, ix.receiver, ix.index, ep)
            ast.Expr.expr_expression_list as lst:
                return lowering.lower_tuple_literal_with_names(ctx, lst.elements)
            ast.Expr.expr_proc as pr:
                return lower_proc_expr(ctx, pr.method_params, pr.return_type, pr.body, ep)
            ast.Expr.expr_await as aw:
                let inner = lower_expr(ctx, aw.expression)
                return tasks.unwrap_task_value(inner)
            ast.Expr.expr_format_string as fs:
                # All-static format strings collapse to a plain literal.  A
                # dynamic one builds through the host's make/release protocol:
                # inside a statement's hoisting window the whole build hoists
                # into the statement stream and the result is released after the
                # statement (the host's `prepare_expression_with_cleanups`);
                # a lazily-evaluated region keeps the inline statement-expression
                # form, which cannot carry the post-statement release.
                if format.format_string_all_static(fs.parts):
                    return format.format_string_static_literal(fs.parts)
                if ctx.hoist.mode == lowering.HoistMode.hm_off:
                    var fmt_setup = vec.Vec[ir.Stmt].create()
                    let fmt_result = format.build_format_string_dynamic(ctx, fs.parts, ref_of(fmt_setup))
                    return lowering.alloc_expr(ir.Expr.expr_stmt_expr(
                        setup = fmt_setup.as_span(),
                        result = fmt_result,
                        ty = types.Type.ty_str
                    ))
                let fmt_result = format.build_format_string_dynamic(ctx, fs.parts, ref_of(ctx.hoist.stmts))
                # The result temp owns its buffer and outlives the statement
                # (the host's `register_prepared_temp!(…, cstr_backed: true)`),
                # so a `str as cstr` boundary may pass its `data` directly.
                unsafe:
                    match read(fmt_result):
                        ir.Expr.expr_name as nm:
                            ctx.format_state.cstr_backed.set(nm.name, true)
                        _:
                            pass
                # Register the release here in every window; a return whose type
                # owns the buffer drops it (`filter_return_format_cleanups`), and
                # an assignment/local-target arm drops it through
                # `drop_format_release_cleanups`.
                ctx.hoist.cleanups.push(format.format_str_release_stmt(fmt_result))
                return fmt_result
            ast.Expr.expr_detach as dt:
                return parallel_mod.lower_detach_expr(ctx, dt.expression, ep)
            ast.Expr.expr_specialization as spec:
                return lower_specialization_expr(ctx, ep, spec.callee, spec.arguments)
            ast.Expr.expr_match as me:
                return lowering.lower_expression_match(ctx, me.scrutinee, me.arms, ep)
            ast.Expr.expr_range as rng:
                let start = lower_expr(ctx, rng.start_expr)
                return start
            ast.Expr.expr_null_literal as nl:
                let nl_target = nl.target_type
                if nl_target != null:
                    let target = lowering.resolve_type_ref(ctx, nl_target)
                    return lowering.alloc_expr(ir.Expr.expr_null_literal(ty = types.Type.ty_null(target = types.alloc_type(target))))
                return lowering.alloc_expr(ir.Expr.expr_null_literal(ty = ctx.void_ty))
            ast.Expr.expr_named as nm:
                return lower_expr(ctx, nm.value)
            ast.Expr.expr_sizeof as sz:
                return lowering.alloc_expr(ir.Expr.expr_sizeof(
                    target_type = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, sz.target_type)),
                    ty = types.primitive("ptr_uint")
                ))
            ast.Expr.expr_alignof as al:
                return lowering.alloc_expr(ir.Expr.expr_alignof(
                    target_type = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, al.target_type)),
                    ty = types.primitive("ptr_uint")
                ))
            ast.Expr.expr_offsetof as off:
                var field_name = off.field
                match ctx.inline_for_element:
                    Option.some as ce:
                        match ce.value:
                            comptime_types.ComptimeElement.ce_struct_field as sf:
                                field_name = sf.name
                            _:
                                pass
                    Option.none:
                        pass
                return lowering.alloc_expr(ir.Expr.expr_offsetof(
                    target_type = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, off.target_type)),
                    field = field_name,
                    ty = types.primitive("ptr_uint"),
                ))
            ast.Expr.expr_error:
                return lowering.alloc_expr(ir.Expr.expr_null_literal(ty = ctx.void_ty))
            _:
                fatal(c"lowering: unsupported expression")

function lower_identifier_expr(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr], name: str) -> ptr[ir.Expr]:
    # An inline foreign-mapping parameter bound to the argument's
    # value (the host's `replacements`) wins over the locals.
    let replacement = ctx.mapping_replacements.get(name)
    if replacement != null:
        return unsafe: read(replacement)
    match type_helpers.find_local_binding(ctx, name):
        Option.some as lb:
            return lowering.lower_binding_read(ctx, lb.value)
        Option.none:
            if ctx.function_returns.contains(name) or ctx.analysis.functions.contains(name):
                let fn_c_name = naming.qualified_c_name(ctx.module_name, name)
                var fn_ty = type_helpers.expr_type(ctx, ep)
                match fn_ty:
                    types.Type.ty_function as fnt:
                        let fnt_ft = unsafe: read(fnt.payload)
                        # Only wrap in proc struct when the expected type
                        # is a proc (is_proc == true).  For plain fn
                        # fields, pass the function pointer directly.
                        if fnt_ft.is_proc:
                            return lowering.lower_fn_to_proc(ctx, fn_c_name, fn_ty, "")
                        # The analyzer records a bare function reference
                        # with an empty type name (the contextual
                        # field/signature form); the host's binding type
                        # carries the function's own name (`fn <name>`).
                        if fnt_ft.name.len == 0:
                            fn_ty = types.function_type(
                                name = name,
                                params = fnt_ft.params,
                                return_type = fnt_ft.return_type,
                                variadic = fnt_ft.variadic,
                                is_proc = false,
                                param_names = fnt_ft.param_names
                            )
                    _:
                        pass
                return lowering.alloc_expr(ir.Expr.expr_name(
                    name = fn_c_name,
                    ty = fn_ty,
                    pointer = Option[bool].some(value = false)
                ))
            if ctx.analysis.events.contains(name):
                # The event's global is emitted under its
                # module-qualified linkage name, and its read type is
                # the event itself (`Types::Event`) — the host's
                # binding carries `Types::Event`, not a plain named
                # type.
                var ev_info = events_mod.ensure_event_runtime(ctx, "", name)
                var ev_payload: ptr[types.Type]? = null
                if ev_info.has_payload:
                    ev_payload = types.alloc_type(ev_info.payload_type)
                let ev_ty = types.event_type(
                    name = name,
                    capacity = ev_info.capacity,
                    payload_type = ev_payload,
                    linkage_name = ev_info.event_c_name
                )
                return lowering.alloc_expr(ir.Expr.expr_name(
                    name = naming.qualified_c_name(ctx.module_name, name),
                    ty = ev_ty,
                    pointer = Option[bool].some(value = false)
                ))
            match type_helpers.find_qualified_constant(ctx, name):
                Option.some as qc:
                    # A module-level value's read carries its *declared*
                    # storage type (the host's binding type), not the
                    # contextually-inferred type: stripping the
                    # `Nullable` here would let a guarded global read
                    # masquerade as non-null in the IR (the
                    # `opaque_backing_names` global).
                    var value_ty = type_helpers.expr_type(ctx, ep)
                    let declared_ty_ptr = ctx.analysis.value_types.get(name)
                    if declared_ty_ptr != null:
                        value_ty = unsafe: read(declared_ty_ptr)
                    return lowering.alloc_expr(ir.Expr.expr_name(
                        name = qc.value,
                        ty = value_ty,
                        pointer = Option[bool].some(value = false)
                    ))
                Option.none:
                    pass
            return lowering.alloc_expr(ir.Expr.expr_name(
                name = name,
                ty = type_helpers.expr_type(ctx, ep),
                pointer = Option[bool].some(value = false)
            ))


public function lower_binary_expr(
    ctx: ref[lowering.LoweringContext],
    ep: ptr[ast.Expr],
    operator: str,
    left_ast: ptr[ast.Expr],
    right_ast: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    if (operator == "and" or operator == "or") and ctx.hoist.mode != lowering.HoistMode.hm_off:
        return lower_short_circuit_binary(ctx, operator, left_ast, right_ast, ep)
    var left = lower_expr(ctx, left_ast)
    var right: ptr[ir.Expr]
    if operator == "and" or operator == "or":
        let hoist_saved = lowering.suspend_stmt_setup(ctx)
        var right_refs = type_helpers.lowering_flow_refinements(ctx, left_ast, operator == "and")
        let right_flow_saved = type_helpers.push_flow_refinements(ctx, ref_of(right_refs))
        right = lower_expr(ctx, right_ast)
        type_helpers.restore_flow_refinements(ctx, right_flow_saved)
        lowering.resume_stmt_setup(ctx, hoist_saved)
    else:
        right = lower_expr(ctx, right_ast)
    # A bare `null` compared against a nullable value takes the other
    # operand's type — the host propagates the left operand's type as
    # the right operand's expected type — so `source == null` types
    # the literal `Nullable(ptr[ubyte])` rather than `void`.
    if operator == "==" or operator == "!=":
        right = lowering.null_literal_to_context_type(right_ast, lowering.ir_expr_type(left), right)
        left = lowering.null_literal_to_context_type(left_ast, lowering.ir_expr_type(right), left)
    # Struct equality on a raw-binding struct (`s_drag_body !=
    # b3.b3_nullBodyId`): the host keeps the `IR::Binary` and its C
    # backend synthesizes the `mt_struct_eq_<T>` helper from the
    # type's fields.  Raw modules lower no declarations, so register
    # the type's layout for the backend's helper synthesis.
    if (operator == "==" or operator == "!=") and lowering.register_equality_operands(ctx, left, right):
        return lowering.alloc_expr(ir.Expr.expr_binary(operator = operator, left = left, right = right, ty = ctx.bool_ty))
    # `str + str` concatenates into a thread-local scratch buffer.
    if (
        operator == "+"
        and type_helpers.is_str_typed(lowering.ir_expr_type(left))
        and type_helpers.is_str_typed(lowering.ir_expr_type(right))
    ):
        var concat_args = vec.Vec[ir.Expr].create()
        unsafe:
            concat_args.push(read(left))
            concat_args.push(read(right))
        return lowering.alloc_expr(ir.Expr.expr_call(
            callee = "mt_str_concat",
            arguments = concat_args.as_span(),
            ty = types.Type.ty_str
        ))
    var result_ty = type_helpers.expr_type(ctx, ep)
    # A comparison is always `bool` (the host's `infer_expression_type`
    # BinaryOp arm); the analyzer can miss it inside a constant
    # initializer (`not (glfwInit() != 0)`).
    if (
        operator == "=="
        or operator == "!="
        or operator == "<"
        or operator == "<="
        or operator == ">"
        or operator == ">="
    ):
        result_ty = ctx.bool_ty
    # A simd arithmetic expression falls back to its left operand's
    # type (the host's BinaryOp inference chain has no Simd promotion
    # rule: `3.0 * a` is `float`, `a * 3.0` keeps the simd type); the
    # analyzer records the Simd operand's type instead.
    if types.is_simd_type(result_ty):
        result_ty = lowering.ir_expr_type(left)
    # A recorded vec/mat/quat result whose operands lower as scalars
    # (field arithmetic such as `this.x - other.x`) is scalar in the
    # host's lowering inference: no vector rule matches the operands,
    # so `common_numeric_type` (else the left type) wins.
    if type_helpers.is_vec_math_name(type_helpers.nominal_type_name(result_ty)) and not (
        type_helpers.is_vec_math_name(type_helpers.nominal_type_name(lowering.ir_expr_type(left))) or type_helpers.is_vec_math_name(type_helpers.nominal_type_name(lowering.ir_expr_type(right)))
    ):
        match type_helpers.common_numeric_type(lowering.ir_expr_type(left), lowering.ir_expr_type(right)):
            Option.some as common_ty:
                result_ty = common_ty.value
            Option.none:
                result_ty = lowering.ir_expr_type(left)
    # Bitwise operators on one nominal type (`Flags.a | Flags.b`):
    # const initializers can miss the analyzer's type map, so the
    # host re-infers from the operands; equal operands give that type.
    if types.is_error(result_ty) and (operator == "|" or operator == "&" or operator == "^"):
        let blt = lowering.ir_expr_type(left)
        let brt = lowering.ir_expr_type(right)
        if not types.is_error(blt) and types.type_equals(blt, brt):
            result_ty = blt
    # Vector/matrix/quaternion binary arithmetic: lower to
    # component-wise aggregate literal BEFORE type promotion, so
    # scalar operands are not cast to the vector result type.
    # Only apply when at least one operand is an actual vector type
    # (the analyzer may mis-type float sub-expressions as vec3
    # inside methods on vec types).
    let lt = lowering.ir_expr_type(left)
    let rt = lowering.ir_expr_type(right)
    let rn = type_helpers.nominal_type_name(result_ty)
    if type_helpers.is_vec_math_name(rn) and (
        type_helpers.is_vec_math_name(type_helpers.nominal_type_name(lt)) or type_helpers.is_vec_math_name(type_helpers.nominal_type_name(rt))
    ) and (
        operator == "+" or operator == "-" or operator == "*" or operator == "/"
    ):
        return type_helpers.lower_vec_binary_op(ctx, operator, left, right, result_ty, rn)
    # Pointer arithmetic (`p + i` / `p - i`) yields the pointer
    # operand's concrete type; the analyzer's generically-recorded
    # type may have dropped its arguments inside a monomorphized body.
    # A nullable operand contributes its *unwrapped* pointer: the
    # host's flow-refined operand type makes `blocks + i` on a
    # guard-bound `ptr[T]?` a `ptr[T]` (its `pointer_arithmetic_result`
    # returns the refined left type), and the C arithmetic runs on the
    # pointer either way — carrying the `Nullable` here overrode the
    # analyzer's refined result.
    if operator == "+" or operator == "-":
        let left_ty = lowering.ir_expr_type(left)
        if types.is_raw_pointer(left_ty) and not types.is_raw_pointer(lowering.ir_expr_type(right)):
            result_ty = if types.is_nullable_type(left_ty): types.unwrap_nullable(left_ty) else: left_ty
    # Integer arithmetic where the analyzer's recorded type is not an
    # integer (e.g. `text.len - n`, where `.len` is typed `ptr_uint`
    # by lowering but the analyzer recorded a wrong type): trust the
    # lowered operand types when both are the same integer type.
    if type_helpers.is_arithmetic_operator(operator) and not lowering.is_integer_scrutinee(result_ty):
        let lt = lowering.ir_expr_type(left)
        let rt = lowering.ir_expr_type(right)
        if lowering.is_integer_scrutinee(lt) and types.type_to_string(lt) == types.type_to_string(rt):
            result_ty = lt
        # `<wider-int-expr> + <int literal>` (e.g. `ptr_uint + 2`): the
        # analyzer recorded a non-integer result, and one operand is a
        # plain `int` literal.  Adopt the other operand's wider integer
        # type so the result matches the dominant operand.
        else if lowering.is_integer_scrutinee(lt) and types.type_to_string(rt) == "int":
            result_ty = lt
        else if lowering.is_integer_scrutinee(rt) and types.type_to_string(lt) == "int":
            result_ty = rt
    # Re-type an integer literal against the other operand's integer
    # type (e.g. `b == 0` where `b: ubyte`, `p + 1` where `p: ptr_uint`),
    # mirroring the host's `harmonize_binary_integer_literal_types`.
    # The literal is recognized *syntactically* — not by its inferred
    # type — because the inference itself follows the peer
    # (`std/noise.mt`'s `state * 6364136223846793005` types the
    # constant `ulong`, and a value > 2^31 is `long` on its own).
    let harm_lt = lowering.ir_expr_type(left)
    let harm_rt = lowering.ir_expr_type(right)
    # Pointer arithmetic: the host lowers the integer offset with the
    # pointer as its expected type, which falls back to the literal's
    # default `int` — an explicit `0z` suffix is ignored
    # (`paths + 0z` carries an `int` literal).
    if operator == "+" or operator == "-":
        if (types.is_pointer_type(harm_lt) or types.is_ref_type(harm_lt)) and control_flow.ast_is_integer_literal(right_ast):
            right = lowering.int_literal_to_context_type(right_ast, types.primitive("int"), right)
        else if (types.is_pointer_type(harm_rt) or types.is_ref_type(harm_rt)) and control_flow.ast_is_integer_literal(left_ast):
            left = lowering.int_literal_to_context_type(left_ast, types.primitive("int"), left)
    if types.is_integer_type(harm_rt):
        let hl = lowering.int_literal_to_context_type(left_ast, harm_rt, left)
        if hl != left:
            left = hl
        # The host lowers each binary operand with the peer's type
        # as its expected type (`lower_expression(... expected_type:)`),
        # so an `if` expression operand takes the peer's type on both
        # branches (`(if c: 1 else: 0) != ptr_uint_value`).
        left = lowering.conditional_value_to_context_type(ctx, left_ast, harm_rt, left)
    if types.is_integer_type(harm_lt):
        let hr = lowering.int_literal_to_context_type(right_ast, harm_lt, right)
        if hr != right:
            right = hr
        right = lowering.conditional_value_to_context_type(ctx, right_ast, harm_lt, right)
    # The same expected-type propagation for a float peer: an `if`
    # expression operand takes the peer's type on both branches
    # (`(if c: W else: H) / sqrtf(x)` casts each branch to float).
    if types.is_float_type(harm_rt):
        left = lowering.conditional_value_to_context_type(ctx, left_ast, harm_rt, left)
    if types.is_float_type(harm_lt):
        right = lowering.conditional_value_to_context_type(ctx, right_ast, harm_lt, right)
    # The recorded result type carries the host's propagated expected
    # type: a bare float literal in an arithmetic binary takes it,
    # so `next_double`'s `val / 4294967296.0` promotes both operands
    # to `double` (the analyzer's hint propagation records the
    # contextual type).  An explicit `f`/`d` suffix keeps its own
    # type.
    if type_helpers.is_pure_arithmetic_operator(operator) and types.is_float_type(result_ty):
        if lowering.is_bare_float_literal(left_ast) and not types.type_equals(lowering.ir_expr_type(left), result_ty):
            left = lowering.float_literal_to_context_type(left_ast, result_ty, left)
        if lowering.is_bare_float_literal(right_ast) and not types.type_equals(lowering.ir_expr_type(right), result_ty):
            right = lowering.float_literal_to_context_type(right_ast, result_ty, right)
    # Re-type a *bare* float literal operand against a float peer
    # (`payload.value == 2.718…` with a `double` peer stays a double
    # literal — the host's contextual literal inference).  An explicit
    # `f`/`d` suffix keeps its own type and is cast by the promotion
    # below instead; without this the literal keeps its default
    # `float` type and the cast truncates it.
    let flt = lowering.ir_expr_type(left)
    let frt = lowering.ir_expr_type(right)
    if types.is_float_type(frt) and types.is_float_type(flt):
        if lowering.is_bare_float_literal(left_ast):
            left = lowering.float_literal_to_context_type(left_ast, frt, left)
        if lowering.is_bare_float_literal(right_ast):
            right = lowering.float_literal_to_context_type(right_ast, flt, right)
    # Balance mixed-width integer and int/float operands: cast the
    # narrower operand up to the common type, matching Ruby's
    # usual-arithmetic-conversion casts (redundant casts are elided
    # by the C backend).  For arithmetic operators the common type is
    # also the result type, which the analyzer may have under-widened.
    # Enum/flags operands unwrap to their integer backing first, so
    # enum comparisons cast to the backing type like Ruby.
    let bal_lt = type_helpers.enum_backing_or_self(ctx, lowering.ir_expr_type(left))
    let bal_rt = type_helpers.enum_backing_or_self(ctx, lowering.ir_expr_type(right))
    match type_helpers.promoted_binary_operand_type(operator, bal_lt, bal_rt):
        Option.some as op_ty:
            left = type_helpers.cast_to_type(left, op_ty.value)
            right = type_helpers.cast_to_type(right, op_ty.value)
            if type_helpers.is_pure_arithmetic_operator(operator):
                result_ty = op_ty.value
        Option.none:
            pass
    return lowering.alloc_expr(ir.Expr.expr_binary(operator = operator, left = left, right = right, ty = result_ty))


public function lower_specialization_expr(
    ctx: ref[lowering.LoweringContext],
    ep: ptr[ast.Expr],
    callee: ptr[ast.Expr],
    arguments: span[ast.TypeArgument]
) -> ptr[ir.Expr]:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if id.name == "zero" and arguments.len == 1:
                    let z_ty = lowering.resolve_type_ref(ctx, read(arguments.data + 0).value)
                    return lowering.alloc_expr(ir.Expr.expr_zero_init(ty = z_ty))
                if id.name == "default" and arguments.len == 1:
                    let t_ty = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, read(arguments.data + 0).value))
                    match lowering.resolve_method_info(ctx, t_ty, "default"):
                        Option.some as smi:
                            if smi.value.method_kind == ast.MethodKind.mk_static:
                                var empty_args = span[ast.Argument]()
                                return lowering.lower_static_call_args(ctx, smi.value, empty_args)
                        Option.none:
                            pass
                # A generic function reference used as a value:
                # `always_allow_transition[State, Event, Context]` passed
                # as an `fn(...)` argument.  Monomorphize it explicitly and
                # refer to the specialized C function.
                match lowering.find_generic_function(ctx, id.name):
                    Option.some as vgm:
                        match vgm.value.decl:
                            ast.Decl.decl_function as vfun:
                                if vfun.type_params.len > 0 and vfun.type_params.len == arguments.len:
                                    let vspec_key = lowering.specialization_key(ctx, vgm.value.module_name, id.name, arguments)
                                    if (
                                        not ctx.caches.specializations.contains(vspec_key)
                                        and not ctx.spec_in_progress.contains(vspec_key)
                                    ):
                                        # A function *reference* instantiates the
                                        # binding but the host analyzer does not
                                        # validate the referenced body (that is
                                        # the `infer_call` path's job), so its
                                        # nested calls are lowering-created.
                                        ctx.next_spec_body_validated = Option[bool].some(value = false)
                                        lowering.lower_and_cache_specialization(
                                            ctx,
                                            vgm.value,
                                            arguments,
                                            vspec_key,
                                            ctx.pre_instantiated_context
                                        )
                                        ctx.next_spec_body_validated = Option[bool].none
                                    else:
                                        # A reference is not a call; an actual
                                        # call site elsewhere records the edge.
                                        pass
                                    var fn_ty = type_helpers.expr_type(ctx, ep)
                                    let vcached = ctx.caches.specializations.get(vspec_key)
                                    if vcached != null:
                                        let sf = unsafe: read(vcached)
                                        var ptypes = vec.Vec[types.Type].create()
                                        var pnames = vec.Vec[str].create()
                                        var vpi: ptr_uint = 0
                                        while vpi < sf.params.len:
                                            unsafe:
                                                ptypes.push(read(sf.params.data + vpi).ty)
                                                pnames.push(read(sf.params.data + vpi).name)
                                            vpi += 1
                                        fn_ty = types.function_type(
                                            name = id.name,
                                            params = ptypes.as_span(),
                                            return_type = types.alloc_type(sf.return_type),
                                            variadic = false,
                                            is_proc = false,
                                            param_names = pnames.as_span()
                                        )
                                    return lowering.alloc_expr(ir.Expr.expr_name(
                                        name = vspec_key,
                                        ty = fn_ty,
                                        pointer = Option[bool].some(value = false)
                                    ))
                            _:
                                pass
                    Option.none:
                        pass
            _:
                pass
        return lowering.alloc_expr(ir.Expr.expr_name(
            name = "spec",
            ty = types.Type.ty_error,
            pointer = Option[bool].some(value = false)
        ))


function lower_proc_expr(
    ctx: ref[lowering.LoweringContext],
    method_params: span[ast.Param],
    return_type: ptr[ast.TypeRef]?,
    body_ptr: ptr[ast.Stmt],
    ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    let proc_ty = type_helpers.expr_type(ctx, ep)
    var ret_ty = ctx.void_ty
    if return_type != null:
        ret_ty = lowering.resolve_type_ref(ctx, return_type)
    return lowering.lower_proc_expression_typed(ctx, method_params, ret_ty, body_ptr, proc_ty)

