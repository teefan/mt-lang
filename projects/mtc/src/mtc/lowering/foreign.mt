## Foreign/external call lowering, extracted from lowering/lowering.mt
## (Wave 4.2).

import std.fmt as fmt
import std.map as map_mod
import std.string as string
import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.strings
import mtc.c_naming as naming

import mtc.lowering.async_cps as async_cps
import mtc.lowering.comptime as comptime
import mtc.lowering.comptime_types as comptime_types
import mtc.lowering.const_eval as const_eval
import mtc.lowering.format as format
import mtc.lowering.layout as layout_mod
import mtc.lowering.lowering as lowering
import mtc.lowering.type_resolution as type_res_mod
import mtc.lowering.match as match_mod
import mtc.lowering.monomorphized as monomorphized
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.utils as utils


public function foreign_call_substitution(
    ctx: ref[lowering.LoweringContext],
    info: lowering.ForeignInfo,
    args: span[ast.Argument]
) -> map_mod.Map[str, types.Type]:
    var sub = map_mod.Map[str, types.Type].create()
    var tpi: ptr_uint = 0
    while tpi < info.type_params.len:
        var tp: ast.TypeParam
        unsafe:
            tp = read(info.type_params.data + tpi)
        if not tp.is_lifetime:
            match lowering.infer_foreign_type_param_from_args(ctx, tp.name, info.params, args):
                Option.some as inferred:
                    sub.set(tp.name, inferred.value)
                Option.none:
                    pass
        tpi += 1
    return sub



public function foreign_call_needs_materialized_value(
    ctx: ref[lowering.LoweringContext],
    info: lowering.ForeignInfo,
    args: span[ast.Argument]
) -> bool:
    let mapping = info.mapping else:
        return false
    var i: ptr_uint = 0
    while i < info.params.len and i < args.len:
        var param: ast.ForeignParam
        var arg: ast.Argument
        unsafe:
            param = read(info.params.data + i)
            arg = read(args.data + i)
        var total = lowering.mapping_reference_count(mapping, param.name)
        if param.boundary_type.is_some():
            total += lowering.mapping_reference_count(mapping, strings.join_two(param.name, "_public"))
        if total > 1 and not lowering.duplicable_foreign_ast(arg.arg_value):
            return true
        i += 1
    return false


## The host's `materialize_prepared_expression` with prefix `foreign_expr`: a
## statement-lowered foreign call in an expression position stores its result in
## a `__mt_foreign_expr_N` local before the enclosing statement.  A value that
## already is a temp's Name (the `foreign_result` shape) passes through.

public function lower_foreign_call(
    ctx: ref[lowering.LoweringContext],
    info: lowering.ForeignInfo,
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    # The host lowers a generic wrapper under its call-site specialization
    # (`binding.type_substitutions`), so `T as const_ptr[void]` boundary
    # projections see the concrete type.
    var saved_sub = ctx.type_substitution
    if info.type_params.len > 0:
        ctx.type_substitution = foreign_call_substitution(ctx, info, args)
    defer: ctx.type_substitution = saved_sub
    var result: ptr[ir.Expr]
    if info.simple:
        result = lower_foreign_call_direct(ctx, info, args, call_ep)
    else:
        result = lower_inline_foreign_mapping(ctx, info, args, call_ep)
    # A statement-lowered foreign call used in an expression position
    # materializes its result before the enclosing statement (the host's
    # `prepare_statement_lowered_foreign_call`); the statement roots
    # (initializer, assignment value, return value, discarded expression) keep
    # the call inline.
    if ctx.hoist.mode != lowering.HoistMode.hm_off and ctx.hoist.root_ep != call_ep and foreign_call_needs_materialized_value(
        ctx,
        info,
        args
    ):
        result = lowering.materialize_foreign_expr(ctx, result, info.return_ty)
    return result



public function lower_foreign_call_direct(
    ctx: ref[lowering.LoweringContext],
    info: lowering.ForeignInfo,
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    var ir_args = vec.Vec[ir.Expr].create()
    var setup = vec.Vec[ir.Stmt].create()
    # Names of hoisted `str as cstr` temporaries (malloc'd by
    # mt_foreign_str_to_cstr_temp) that must be freed after the call so a foreign
    # call in a loop (e.g. DrawText(dynamic_str, ...) each frame) does not leak.
    var cstr_temps = vec.Vec[str].create()
    var lowered_args = vec.Vec[ptr[ir.Expr]].create()
    let saved_locals_len = ctx.locals.len()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        var lowered: ptr[ir.Expr]
        if i < info.params.len:
            var param: ast.ForeignParam
            unsafe:
                param = read(info.params.data + i)
            # The host's `prepare_foreign_in_argument`: an `in` operand that is
            # not addressable storage gets a `foreign_in` temp before the
            # boundary projection wraps its address.
            let prepared = lowering.prepare_foreign_in_argument_mt(ctx, info, param, arg, ref_of(setup))
            lowered = lowering.materialize_foreign_address_arg(
                ctx,
                lower_foreign_arg(ctx, info, param, prepared.arg_value),
                ref_of(setup)
            )
        else:
            # A variadic slot has no declared type; the host still converts a
            # `str` value at the raw C boundary (`TextFormat("%s", value)`).
            lowered = lowering.lower_expr(ctx, arg.arg_value)
            if type_helpers.is_str_typed(lowering.ir_expr_type(lowered)):
                lowered = lower_cstr_argument(ctx, arg.arg_value, lowered)
        lowered_args.push(lowered)
        i += 1
    # The host allocates this call's own argument temps only after every
    # argument value has been lowered (`bind_foreign_mapping_arguments` phase
    # 3), so a nested foreign call in a later argument numbers before an earlier
    # argument's cstr temp.
    var ai: ptr_uint = 0
    while ai < lowered_args.len:
        let lp = lowered_args.get(ai) else:
            break
        var lowered = unsafe: read(lp)
        if lowering.is_foreign_cstr_temp_call(lowered):
            let cstr_ty = types.primitive("cstr")
            let tc = lowering.fresh_c_temp_name(ctx, "foreign_arg")
            setup.push(ir.Stmt.stmt_local(
                name = tc,
                linkage_name = tc,
                ty = cstr_ty,
                value = lowered,
                line = 0,
                source_path = ""
            ))
            cstr_temps.push(tc)
            lowered = lowering.alloc_expr(ir.Expr.expr_name(name = tc, ty = cstr_ty, pointer = Option[bool].some(value = false)))
        unsafe:
            ir_args.push(read(lowered))
        ai += 1
    let ret_ty = info.return_ty
    # The host's `bind_foreign_mapping_arguments` binds its argument temps in a
    # duplicated env; the simple path's `foreign_in` temps must not leak either.
    while ctx.locals.len() > saved_locals_len:
        if ctx.locals.pop().is_none():
            break
    # The host types the emitted C call with the *raw declaration's* return
    # type — the owner analysis's view — not the wrapper's: `= c.getenv` with
    # a `ptr[char]` declaration and a `cstr?` wrapper types the call
    # `ptr[char]` (the 3f rule, on the simple path).
    var call_ty = ret_ty
    let mapping = info.mapping
    if mapping != null:
        match simple_mapping_callee(mapping):
            Option.some as callee:
                match lowering.mapping_call_return_type(ctx, info.owner_module, callee.value.receiver, callee.value.name):
                    Option.some as raw_ret:
                        call_ty = raw_ret.value
                    Option.none:
                        pass
            Option.none:
                pass
    let call = lowering.alloc_expr(ir.Expr.expr_call(callee = info.c_name, arguments = ir_args.as_span(), ty = call_ty))
    return wrap_foreign_cstr_frees(ctx, ref_of(setup), call, ret_ty, ref_of(cstr_temps), call_ep)


## The host's consuming-argument rule (`consuming_foreign_release_assignments`):
## after a statement-position foreign call, each bare nullable local passed to a
## `consuming` parameter is nulled and refined to null for later statements.

public function lower_inline_foreign_mapping(
    ctx: ref[lowering.LoweringContext],
    info: lowering.ForeignInfo,
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    let mapping = info.mapping else:
        fatal(c"lowering: inline foreign mapping missing expression")

    var setup = vec.Vec[ir.Stmt].create()
    var cstr_temps = vec.Vec[str].create()
    let saved_locals_len = ctx.locals.len()
    # The mapping's substitutions never leak into an argument's lowering (the
    # host lowers the values in the caller's env); start from an empty map.
    let saved_replacements = ctx.mapping_replacements
    ctx.mapping_replacements = map_mod.Map[str, ptr[ir.Expr]].create()

    # Pass 1: the `as` boundary's public alias.  A value that already is a Name
    # (the buffer/local itself) is bound to that name; anything else gets the
    # host's `foreign_arg_public` temp before any parameter value is evaluated.
    var i: ptr_uint = 0
    while i < info.params.len and i < args.len:
        var param: ast.ForeignParam
        var arg: ast.Argument
        unsafe:
            param = read(info.params.data + i)
            arg = read(args.data + i)
        if param.boundary_type.is_some():
            let pub_alias = strings.join_two(param.name, "_public")
            if lowering.mapping_references_name(mapping, pub_alias):
                let declared_ty = foreign_param_context_type(ctx, info, param)
                let public_ir = lowering.literal_value_to_context_type(
                    ctx,
                    arg.arg_value,
                    declared_ty,
                    lowering.lower_expr(ctx, arg.arg_value)
                )
                let public_lowered = unsafe: read(public_ir)
                match public_lowered:
                    ir.Expr.expr_name as nm:
                        ctx.locals.push(lowering.LocalBinding(
                            name = pub_alias,
                            c_name = nm.name,
                            ty = declared_ty,
                            pointer = Option[bool].some(value = false)
                        ))
                    _:
                        let tcp = lowering.fresh_c_temp_name(ctx, "foreign_arg_public")
                        setup.push(ir.Stmt.stmt_local(
                            name = tcp,
                            linkage_name = tcp,
                            ty = declared_ty,
                            value = public_ir,
                            line = 0,
                            source_path = ""
                        ))
                        ctx.locals.push(lowering.LocalBinding(
                            name = pub_alias,
                            c_name = tcp,
                            ty = declared_ty,
                            pointer = Option[bool].some(value = false)
                        ))
        i += 1

    # Pass 2: lower every referenced parameter's value in declaration order.
    var values = map_mod.Map[str, ptr[ir.Expr]].create()
    i = 0
    while i < info.params.len and i < args.len:
        var param2: ast.ForeignParam
        var arg2: ast.Argument
        unsafe:
            param2 = read(info.params.data + i)
            arg2 = read(args.data + i)
        if lowering.mapping_reference_count(mapping, param2.name) > 0:
            # A referenced public alias supplies the source value (the host's
            # `source_argument` rewrite), so `text_public.capacity()` and the
            # projection share one evaluation.
            var source_arg = arg2
            if param2.boundary_type.is_some():
                let pub_alias2 = strings.join_two(param2.name, "_public")
                if lowering.mapping_reference_count(mapping, pub_alias2) > 0:
                    let alias_id = async_cps.alloc_ast_expr(ast.Expr.expr_identifier(
                        name = pub_alias2,
                        line = 0,
                        column = 0
                    ))
                    source_arg = ast.Argument(arg_name = arg2.arg_name, arg_value = alias_id)
            source_arg = lowering.prepare_foreign_in_argument_mt(ctx, info, param2, source_arg, ref_of(setup))
            var value: ptr[ir.Expr]
            if lowering.is_str_buffer_char_ptr_boundary(param2):
                value = lowering.lower_str_buffer_char_ptr_argument(ctx, param2, source_arg, ref_of(setup))
            else:
                value = lower_foreign_arg(ctx, info, param2, source_arg.arg_value)
                value = lowering.materialize_foreign_address_arg(ctx, value, ref_of(setup))
                # An `array[T, N]` argument for a `span[T]` parameter (e.g.
                # `render_lines(renderer, line_points)`) coerces to the span
                # aggregate `{ data = &arr[0], len = N }` so the mapping's
                # `points.data` / `points.len` resolve, mirroring the analyzer's
                # array→span boundary rule.  The span's element type comes from
                # the argument: the declared name (`FPoint`) is an alias of the
                # binding's module and is not resolvable from the caller.
                let projected_ty = lowering.ir_expr_type(value)
                if param_type_is_span(param2.param_type) and lowering.is_array_type(projected_ty):
                    let span_ty = types.generic_type(name = "span", args = lowering.sp_type(lowering.generic_first_arg(projected_ty)))
                    value = lowering.array_value_to_span(value, projected_ty, span_ty)
            values.set(param2.name, value)
        i += 1

    # The host's `inlineable_single_direct_call_names` exception: when exactly
    # one referenced parameter needs a temporary and it is a single-reference
    # plain call, that call is embedded directly after all.
    var blocked_count: ptr_uint = 0
    var blocked_name = ""
    i = 0
    while i < info.params.len and i < args.len:
        var param3: ast.ForeignParam
        unsafe:
            param3 = read(info.params.data + i)
        let refs3 = lowering.mapping_reference_count(mapping, param3.name)
        if refs3 > 0:
            let value_ptr3 = values.get(param3.name)
            if value_ptr3 != null:
                let value3 = unsafe: read(value_ptr3)
                if refs3 > 1 or not inlineable_foreign_value(value3):
                    blocked_count += 1
                    blocked_name = param3.name
        i += 1
    var inline_direct_name = ""
    if blocked_count == 1:
        let refs_d = lowering.mapping_reference_count(mapping, blocked_name)
        let value_ptr_d = values.get(blocked_name)
        if value_ptr_d != null:
            let value_d = unsafe: read(value_ptr_d)
            if refs_d == 1 and is_plain_foreign_call_value(value_d) and not lowering.is_foreign_cstr_temp_call(value_d):
                inline_direct_name = blocked_name

    # Pass 3: temporary-bind a parameter only where the host does
    # (`foreign_argument_needs_temporary_binding?`); every other referenced
    # parameter's value is substituted into the mapping instead.
    i = 0
    while i < info.params.len and i < args.len:
        var param4: ast.ForeignParam
        unsafe:
            param4 = read(info.params.data + i)
        let refs4 = lowering.mapping_reference_count(mapping, param4.name)
        if refs4 > 0:
            let value_ptr4 = values.get(param4.name)
            if value_ptr4 != null:
                let value4 = unsafe: read(value_ptr4)
                let temp_ty = lowering.ir_expr_type(value4)
                var needs_temp = refs4 > 1 and not lowering.duplicable_foreign_value(value4)
                if not inlineable_foreign_value(value4):
                    needs_temp = true
                if param4.name == inline_direct_name:
                    needs_temp = false
                if needs_temp:
                    let tc = lowering.fresh_c_temp_name(ctx, "foreign_arg")
                    setup.push(ir.Stmt.stmt_local(
                        name = tc,
                        linkage_name = tc,
                        ty = temp_ty,
                        value = value4,
                        line = 0,
                        source_path = ""
                    ))
                    ctx.locals.push(lowering.LocalBinding(
                        name = param4.name,
                        c_name = tc,
                        ty = temp_ty,
                        pointer = Option[bool].some(value = false)
                    ))
                    if lowering.is_foreign_cstr_temp_call(value4):
                        cstr_temps.push(tc)
                else:
                    ctx.mapping_replacements.set(param4.name, value4)
        i += 1

    let result = walk_mapping_expr(ctx, mapping, info.return_ty, info.owner_module)
    ctx.mapping_replacements = saved_replacements

    while ctx.locals.len() > saved_locals_len:
        if ctx.locals.pop().is_none():
            break

    return wrap_foreign_cstr_frees(ctx, ref_of(setup), result, info.return_ty, ref_of(cstr_temps), call_ep)


## The host's `addressable_storage_expression?` over the AST: an identifier,
## a member/element chain rooted at one, or a `read(...)` call.  An `in`
## argument with any other shape needs a `foreign_in` temporary before its
## address can be taken.  The host strips `unsafe:` while preparing the
## argument (`prepare_expression_for_inline_lowering`'s UnsafeExpr arm), so the
## predicate looks through the wrapper.

public function foreign_argument_operand(ep: ptr[ast.Expr]) -> ptr[ast.Expr]:
    unsafe:
        match read(ep):
            ast.Expr.expr_unary_op as un:
                if un.operator == "in" or un.operator == "out" or un.operator == "inout":
                    return un.operand
                return ep
            _:
                return ep


## The host's `prepare_foreign_in_argument`: an `in` argument whose operand is
## not addressable storage is materialized into a `foreign_in` temp before the
## value is lowered, so the boundary's address-of has an lvalue to take.

public function foreign_param_context_type(
    ctx: ref[lowering.LoweringContext],
    info: lowering.ForeignInfo,
    param: ast.ForeignParam
) -> types.Type:
    var saved_module = ctx.module_name
    var saved_analysis = ctx.analysis
    if info.owner_module.len > 0 and not info.owner_module.equal(ctx.module_name):
        match lowering.find_imported_analysis(ctx, info.owner_module):
            Option.some as owner_a:
                ctx.module_name = info.owner_module
                ctx.analysis = owner_a.value
            Option.none:
                pass
    var ctx_pt = param.param_type
    let ctx_ty = lowering.opaqueify_type(ctx, deep_alias_target(ctx, lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, ptr_of(ctx_pt)))))
    ctx.module_name = saved_module
    ctx.analysis = saved_analysis
    return ctx_ty


## The declared return type of a foreign wrapper call, resolved in its
## declaring module — the host's `infer_expression_type` for a call.  A simple
## mapping's lowered call carries the raw declaration's return type instead
## (`ptr[char]` for a `cstr?` wrapper, the 3j rule), so a local declaration
## inferred from the call needs this.  None when the callee is not a wrapper.

public function foreign_wrapper_call_return_type(ctx: ref[lowering.LoweringContext], callee: ptr[ast.Expr]) -> Option[types.Type]:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                let fp = ctx.foreign_map.get(id.name)
                if fp != null:
                    return Option[types.Type].some(value = read(fp).return_ty)
                return Option[types.Type].none
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as id2:
                        let mod_ptr = ctx.analysis.imports.get(id2.name) else:
                            return Option[types.Type].none
                        match imported_foreign_call(ctx, read(mod_ptr), ma.member_name):
                            Option.some as fi:
                                return Option[types.Type].some(value = fi.value.return_ty)
                            Option.none:
                                return Option[types.Type].none
                    _:
                        return Option[types.Type].none
            _:
                return Option[types.Type].none


## The resolved `as` boundary type of a foreign wrapper parameter, in the
## module that declares the wrapper — the host's `parameter.boundary_type`
## (`resolve_type_ref` in the owner).

public function foreign_boundary_type(ctx: ref[lowering.LoweringContext], info: lowering.ForeignInfo, param: ast.ForeignParam) -> types.Type:
    match param.boundary_type:
        Option.some as boundary:
            var saved_module = ctx.module_name
            var saved_analysis = ctx.analysis
            if info.owner_module.len > 0 and not info.owner_module.equal(ctx.module_name):
                match lowering.find_imported_analysis(ctx, info.owner_module):
                    Option.some as owner_a:
                        ctx.module_name = info.owner_module
                        ctx.analysis = owner_a.value
                    Option.none:
                        pass
            var bt_ref = boundary.value
            let bt = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, ptr_of(bt_ref)))
            ctx.module_name = saved_module
            ctx.analysis = saved_analysis
            return bt
        Option.none:
            return types.Type.ty_error


## True when a value of type `actual` may be projected to the foreign boundary
## `expected` by an `IR::Cast` — the pointer/nullable/cstr subset of the host's
## `foreign_identity_projection_cast_compatible?`.

public function foreign_projection_cast_compatible(actual: types.Type, expected: types.Type) -> bool:
    if types.type_equals(actual, expected):
        return true
    match actual:
        types.Type.ty_nullable as na:
            match expected:
                types.Type.ty_nullable as ne:
                    return foreign_projection_cast_compatible(unsafe: read(na.base), unsafe: read(ne.base))
                _:
                    # A nullable *pointer* is the same C pointer value, so it
                    # projects to a non-nullable pointer boundary as a cast
                    # (`update_texture(texture, pixels)` with a guard-bound
                    # `pixels: ptr[Color]?`).
                    let nbase = unsafe: read(na.base)
                    if (types.is_pointer_type(nbase) or types.is_ref_type(nbase)) and (types.is_pointer_type(expected) or types.is_ref_type(expected)):
                        return true
                    return false
        _:
            pass
    match expected:
        types.Type.ty_nullable as ne:
            return foreign_projection_cast_compatible(actual, unsafe: read(ne.base))
        _:
            pass
    let actual_ptr = types.is_pointer_type(actual)
    let expected_ptr = types.is_pointer_type(expected)
    if types.type_equals(actual, types.primitive("cstr")) and expected_ptr:
        return types.is_char_type(types.pointer_element(expected))
    if actual_ptr and types.type_equals(expected, types.primitive("cstr")):
        return types.is_char_type(types.pointer_element(actual))
    if actual_ptr and expected_ptr:
        # A const pointer never projects to a mutable one.
        match actual:
            types.Type.ty_generic as ag:
                let ag_bp = unsafe: read(ag.payload)
                if ag_bp.name == "const_ptr":
                    match expected:
                        types.Type.ty_generic as eg:
                            let eg_bp = unsafe: read(eg.payload)
                            if eg_bp.name == "ptr" or eg_bp.name == "own":
                                return false
                        _:
                            pass
            _:
                pass
        if is_void_pointer_type(actual) or is_void_pointer_type(expected):
            return true
        return foreign_projection_cast_compatible(types.pointer_element(actual), types.pointer_element(expected))
    # A `void*` and an opaque handle share the C representation.
    if is_void_pointer_type(actual):
        match expected:
            types.Type.ty_opaque:
                return true
            _:
                pass
    if is_void_pointer_type(expected):
        match actual:
            types.Type.ty_opaque:
                return true
            _:
                pass
    return false



public function lower_foreign_arg(
    ctx: ref[lowering.LoweringContext],
    info: lowering.ForeignInfo,
    param: ast.ForeignParam,
    arg: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    match param.boundary_type:
        Option.some as boundary:
            if boundary_is_cstr(boundary.value):
                return lower_cstr_argument(ctx, arg, lowering.lower_expr(ctx, arg))
            # For `in value: T as const_ptr[void]` the host takes the
            # argument's address with `const_pointer_to(parameter.type)` and
            # then projects it to the declared boundary type — the host's
            # `lower_foreign_in_argument_value` + `lower_addr_expression`.
            if param.param_mode == ast.ForeignParamMode.fmode_in:
                let lowered_val = lowering.lower_expr(ctx, arg)
                let in_ty = foreign_param_context_type(ctx, info, param)
                if lowering.is_null_ir_expr(lowered_val):
                    return lowering.null_literal_to_context_type(arg, in_ty, lowered_val)
                let in_target = types.generic_type(name = "const_ptr", args = lowering.sp_type(in_ty))
                var address: ptr[ir.Expr]
                match addr_operand_expr(lowered_val):
                    Option.some as op:
                        let op_ty = lowering.ir_expr_type(op.value)
                        if types.type_equals(op_ty, in_target):
                            address = op.value
                        else:
                            address = lowering.alloc_expr(ir.Expr.expr_cast(
                                target_type = in_target,
                                expression = op.value,
                                ty = in_target
                            ))
                    Option.none:
                        address = lowering.alloc_expr(ir.Expr.expr_address_of(expression = lowered_val, ty = in_target))
                return project_foreign_boundary(ctx, address, foreign_boundary_type(ctx, info, param))
            # A plain `as` boundary: a bare literal takes the parameter's
            # declared type, then the value projects to the declared boundary —
            # the host's `lower_foreign_argument_value` fallback +
            # `foreign_identity_projection_expression`.
            let lowered_plain = lowering.lower_expr(ctx, arg)
            let ctx_ty = foreign_param_context_type(ctx, info, param)
            var typed = lowering.literal_value_to_context_type(ctx, arg, ctx_ty, lowered_plain)
            # The host's `lower_contextual_expression` also applies the numeric
            # constant cast at a foreign boundary (`set_render_draw_color(…,
            # ALPHA_OPAQUE)` with a `ubyte` parameter casts the `int` const).
            typed = lowering.contextual_numeric_cast(ctx, arg, typed, ctx_ty, false, false)
            return project_foreign_boundary(ctx, typed, foreign_boundary_type(ctx, info, param))
        Option.none:
            # A float/double parameter threads its expected type into an
            # arithmetic binary argument (the host's `lower_contextual_expression`
            # with the parameter's type): `math.cos((i + 1) / 51.45)` takes a
            # double literal and casts the int sub-expression.
            let arg_ctx_ty = foreign_param_context_type(ctx, info, param)
            var lowered: ptr[ir.Expr]
            if types.is_float_type(arg_ctx_ty) and lowering.is_contextual_binary_expr(arg):
                lowered = lowering.lower_contextual_binary(ctx, arg, arg_ctx_ty)
            else:
                lowered = lowering.lower_expr(ctx, arg)
            # `out`/`inout` pass the address of the argument's storage slot, with
            # the host's `lower_addr_expression` exception: a lowered argument
            # that already *is* a pointer — an editable method's `this` receiver
            # (`IR::Name` with `pointer: true`) or a `*p` dereference — is cast
            # to the boundary's pointer type instead of being addressed again.
            # A pointer-typed slot (`out glyph_recs: ptr[Rectangle]`) with a
            # plain value still takes its address, so the C function receives
            # `Rectangle**`.
            let mode_needs_address = param.param_mode == ast.ForeignParamMode.fmode_out or param.param_mode == ast.ForeignParamMode.fmode_inout
            if mode_needs_address:
                if lowering.is_null_ir_expr(lowered):
                    return lowered
                let arg_ty = lowering.ir_expr_type(lowered)
                # Resolve the declared parameter type in the wrapper's OWNER
                # module (the host's `lowering.ForeignInfo.owner_module`): a wrapper in
                # `std.libuv` declares `out addr: sockaddr_in` where
                # `sockaddr_in` is that module's public alias of
                # `std.c.libuv.sockaddr_in`, a name the caller may not import.
                # `qualify_type`/`deep_alias_target` run inside that context.
                var slot_ty = foreign_param_context_type(ctx, info, param)
                # The host's `foreign_slot_boundary_value_type`: a nullable
                # pointer-like slot's boundary value is its base.
                if types.is_nullable_type(slot_ty) and lowering.is_nullable_pointer_like(slot_ty):
                    slot_ty = types.unwrap_nullable(slot_ty)
                let slot_is_pointer = types.is_raw_pointer(slot_ty) or types.is_ref_type(slot_ty) or types.is_own_type(slot_ty)
                let slot_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(lowering.qualify_type(ctx, slot_ty)))
                match addr_operand_expr(lowered):
                    Option.some as op:
                        return lowering.alloc_expr(ir.Expr.expr_cast(
                            target_type = slot_ptr_ty,
                            expression = op.value,
                            ty = slot_ptr_ty
                        ))
                    Option.none:
                        pass
                if types.is_raw_pointer(arg_ty) and not slot_is_pointer:
                    return lowered
                # The host's `lower_foreign_pointer_argument_value` types the
                # address-of with `pointer_to(slot_type)` — `ptr[T]`, not a
                # `ptr[void]` placeholder.
                return lowering.alloc_expr(ir.Expr.expr_address_of(expression = lowered, ty = slot_ptr_ty))
            # A bare `in` parameter (no `as`) has the host's implicit boundary
            # `const_pointer_to(parameter.type)` (`foreign_parameter_boundary_type`):
            # hand the callee the argument's address, unless it is already a
            # pointer.
            if param.param_mode == ast.ForeignParamMode.fmode_in:
                if lowering.is_null_ir_expr(lowered):
                    # The host types the null with the parameter's declared
                    # type (`c.time(null)` carries `Nullable(ptr[ptr_int])`,
                    # not `void`).
                    return lowering.null_literal_to_context_type(arg, foreign_param_context_type(ctx, info, param), lowered)
                let in_arg_ty = lowering.ir_expr_type(lowered)
                if types.is_raw_pointer(in_arg_ty) or types.is_ref_type(in_arg_ty) or types.is_own_type(in_arg_ty):
                    return lowered
                let in_val_ty = foreign_param_context_type(ctx, info, param)
                return lowering.alloc_expr(ir.Expr.expr_address_of(
                    expression = lowered,
                    ty = types.generic_type(name = "const_ptr", args = lowering.sp_type(in_val_ty))
                ))
            # A plain pointer/ref param passed a non-pointer value borrows it.
            var pt_copy = param.param_type
            let param_ty = lowering.resolve_type_ref(ctx, ptr_of(pt_copy))
            if types.is_raw_pointer(param_ty) or types.is_ref_type(param_ty):
                if not lowering.is_null_ir_expr(lowered):
                    let arg_ty = lowering.ir_expr_type(lowered)
                    if not types.is_raw_pointer(arg_ty) and not types.is_own_type(arg_ty):
                        let borrowed = lowering.alloc_expr(ir.Expr.expr_address_of(
                            expression = lowered,
                            ty = types.primitive("ptr[void]")
                        ))
                        return project_foreign_boundary(ctx, borrowed, foreign_boundary_type(ctx, info, param))
            # Every bare literal takes the parameter's declared type — the
            # host's `lower_contextual_expression` (int/float/string/null all
            # retype, not just `null`), resolved in the param's declaring
            # module (session 44, items 3ag/3ae/3fc).  The lowered value is
            # then projected to the declared boundary — the host's
            # `foreign_identity_projection_expression` (item 8a).
            let ctx_ty = foreign_param_context_type(ctx, info, param)
            var typed = lowering.literal_value_to_context_type(ctx, arg, ctx_ty, lowered)
            typed = lowering.contextual_numeric_cast(ctx, arg, typed, ctx_ty, false, false)
            return project_foreign_boundary(ctx, typed, foreign_boundary_type(ctx, info, param))



public function foreign_mapping_is_simple(mapping: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(mapping):
            ast.Expr.expr_identifier:
                return true
            ast.Expr.expr_member_access as ma:
                # `c.Name` is a simple 1:1 mapping; `c.Call(...).field` is an
                # inline mapping (field access on a call result), so it is simple
                # only when its receiver is a bare module-alias identifier.
                match read(ma.receiver):
                    ast.Expr.expr_identifier:
                        return true
                    _:
                        return false
            _:
                return false


## The resolved type of `member` on a receiver that is an instance of a struct
## defined in ANOTHER module.  The analyzer stores field types with names bare
## relative to their defining module, so qualifying them in the accessing
## module's context mis-attributes them (ir.Program.functions -> a Function type
## prefixed with the caller's module).  Resolve the field's declared type ref in
## the owner module's context instead.  Returns none for same-module receivers
## (handled by the recorded type) and non-struct receivers.
## Member access: enum / flags member constants on a type-name receiver
## (`State.running` -> `en_State_running`), otherwise a struct field access
## (`p.x`).  Method calls are resolved through `lower_method_resolved` and
## `lower_dyn_method_call`; other member forms (atomic, str_buffer, event) are
## dispatched by their type.

public function is_plain_foreign_call_value(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_call:
                return true
            ir.Expr.expr_call_indirect:
                return true
            _:
                return false


## The parameter's declared type, resolved in its *declaring* module and
## deepened/opaqueified: the context type the host's
## `lower_contextual_expression` gives every foreign argument (session 44,
## items 3ag/5b).


public function is_void_pointer_type(t: types.Type) -> bool:
    return types.is_pointer_type(t) and types.is_void(types.pointer_element(t))


## The host's `foreign_identity_projection_expression`: a value at a foreign
## boundary keeps its type when equal to the boundary, is `IR::Cast` when the
## types are projection-compatible, and is otherwise left unchanged (the self's
## type resolution is coarser than the host's in a few nominal corners).


public function project_foreign_boundary(ctx: ref[lowering.LoweringContext], value: ptr[ir.Expr], boundary: types.Type) -> ptr[ir.Expr]:
    let value_ty = lowering.ir_expr_type(value)
    if types.type_equals(value_ty, boundary):
        return value
    if foreign_projection_cast_compatible(value_ty, boundary):
        return lowering.alloc_expr(ir.Expr.expr_cast(target_type = boundary, expression = value, ty = boundary))
    return value


## A `str` argument at a `cstr` boundary (a declared `str as cstr` parameter or
## a variadic slot): a string literal becomes a C string literal; an already
## cstr value passes through; a cstr-backed `str` (a literal-backed local, a
## dynamic format temp, or a syntactically cstr-backed `if`/`unsafe`) passes its
## `data` pointer in an `IR::Cast(cstr)`; anything else takes the malloc-backed
## `mt_foreign_str_to_cstr_temp` copy (hoisted/freed by the caller).


public function lower_cstr_argument(ctx: ref[lowering.LoweringContext], arg: ptr[ast.Expr], lowered_str: ptr[ir.Expr]) -> ptr[ir.Expr]:
    let cstr_ty = types.primitive("cstr")
    unsafe:
        match read(arg):
            ast.Expr.expr_string_literal as lit:
                return lowering.alloc_expr(ir.Expr.expr_string_literal(value = lit.value, ty = cstr_ty, cstring = true))
            _:
                pass
    let arg_ty = lowering.ir_expr_type(lowered_str)
    match arg_ty:
        types.Type.ty_primitive as p:
            if p.name == "cstr":
                return lowered_str
        _:
            pass
    if format.is_cstr_backed_lowered(ctx, lowered_str) or format.ast_expr_cstr_backed(ctx, arg):
        let data_member = lowering.alloc_expr(ir.Expr.expr_member(
            receiver = lowered_str,
            member = "data",
            ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("char")))
        ))
        return lowering.alloc_expr(ir.Expr.expr_cast(target_type = cstr_ty, expression = data_member, ty = cstr_ty))
    return lowering.alloc_expr(ir.Expr.expr_call(
        callee = "mt_foreign_str_to_cstr_temp",
        arguments = lowering.single_expr_span(lowered_str),
        ty = cstr_ty,
    ))


public function boundary_is_cstr(boundary: ast.TypeRef) -> bool:
    if boundary.name.parts.len != 1:
        return false
    unsafe:
        return read(boundary.name.parts.data + 0) == "cstr"


## Follow a module-local type alias chain to its target type.  A foreign
## boundary's pointer element is the host's `parameter.type` — the *resolved*
## declared type — so `WorldDef` (a wrapper alias of `c.b2WorldDef`) must deepen
## to the raw `b2WorldDef`; `qualify_type` deliberately keeps std.c-targeting
## aliases by name for C-signature purposes, which is why this exists
## (session 43, item 3q).


public function deep_alias_target(ctx: ref[lowering.LoweringContext], t: types.Type) -> types.Type:
    var current = t
    var guard: ptr_uint = 0
    while guard < 8:
        guard += 1
        var module_name = ""
        var type_name = ""
        match current:
            types.Type.ty_imported as im:
                let im_bp = unsafe: read(im.payload)
                if im_bp.args.len > 0 or match_mod.is_prelude_variant_name(im_bp.name):
                    return current
                module_name = im_bp.module_name
                type_name = im_bp.name
            types.Type.ty_named as nm:
                let nm_np = unsafe: read(nm.payload)
                if nm_np.module_name.len == 0:
                    return current
                module_name = nm_np.module_name
                type_name = nm_np.name
            _:
                return current
        match type_res_mod.resolve_imported_alias_type(ctx.program_analyses, module_name, type_name):
            Option.some as target:
                let next = target.value
                if types.type_equals(next, current):
                    return current
                current = next
            Option.none:
                # `qualify_type` keeps a std.c-targeting alias by name but pairs
                # it with the *target* module (`ty_imported("std.c.raw.lib",
                # "MyDef")` for `type MyDef = c.Def`).  Look the alias up in the
                # module that actually declares it, and accept the result only
                # when it targets the module already on the type — any other
                # same-named alias elsewhere would be the wrong rewrite.
                match resolve_alias_targeting_module(ctx.program_analyses, module_name, type_name):
                    Option.some as target:
                        let next = target.value
                        if types.type_equals(next, current):
                            return current
                        current = next
                    Option.none:
                        return current
    return current


## The target of an alias named `type_name` declared in *some* module, accepted
## only when it is an imported type of the given `module_name` (the pairing
## `qualify_type` leaves for a std.c-targeting alias).


public function resolve_alias_targeting_module(
    analyses: span[analyzer.Analysis],
    module_name: str,
    type_name: str
) -> Option[types.Type]:
    var ai: ptr_uint = 0
    while ai < analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(analyses.data + ai)
        let alias_target = a.type_alias_types.get(type_name)
        if alias_target != null:
            unsafe:
                let at = read(alias_target)
                var base = at
                if types.is_nullable_type(base):
                    base = types.unwrap_nullable(base)
                match base:
                    types.Type.ty_imported as aim:
                        let aim_bp = unsafe: read(aim.payload)
                        if aim_bp.module_name == module_name:
                            return Option[types.Type].some(value = types.imported_type(
                                module_name = aim_bp.module_name,
                                name = aim_bp.name,
                                args = aim_bp.args
                            ))
                        return Option[types.Type].none
                    _:
                        return Option[types.Type].none
        ai += 1
    return Option[types.Type].none


## The operand an address-taking foreign boundary should cast rather than
## address again — the host's `lower_addr_expression`: an `IR::Name` with
## `pointer: true` (a C pointer variable, e.g. an editable method's `this`
## receiver) is itself the pointer, and `*p` unwraps to `p`.  None for
## everything else (which takes `IR::AddressOf`).


public function addr_operand_expr(ep: ptr[ir.Expr]) -> Option[ptr[ir.Expr]]:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as n:
                if n.pointer.unwrap_or(false):
                    return Option[ptr[ir.Expr]].some(value = ep)
                return Option[ptr[ir.Expr]].none
            ir.Expr.expr_unary as u:
                if u.operator == "*":
                    return Option[ptr[ir.Expr]].some(value = u.operand)
                return Option[ptr[ir.Expr]].none
            _:
                return Option[ptr[ir.Expr]].none


## True when a declared foreign parameter type is spelled `span[T]`, i.e. the
## array→span boundary coercion applies to its argument.


public function param_type_is_span(type_ref: ast.TypeRef) -> bool:
    if type_ref.name.parts.len != 1:
        return false
    unsafe:
        return read(type_ref.name.parts.data + 0) == "span"

# =============================================================================
#  Foreign / external function registry
# =============================================================================

## Pre-scan declarations to map each external function to its C name and each
## foreign function to its mapped C function and boundary parameters, so calls
## can be lowered to direct C calls.


public function collect_foreign_functions(ctx: ref[lowering.LoweringContext], decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_extern_function as ef:
                ctx.extern_map.set(ef.name, extern_c_name(ef.name, ef.mapping))
            _:
                pass
        i += 1

    i = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_foreign_function as ff:
                let ff_simple = foreign_mapping_is_simple(ff.mapping)
                var ff_c_name = ""
                if ff_simple:
                    ff_c_name = resolve_foreign_c_name(ctx, ff.mapping)
                ctx.foreign_map.set(ff.name, lowering.ForeignInfo(
                    c_name = ff_c_name,
                    # The declared return type resolved like any other type ref:
                    # a nominal return (`-> Vector4` through `type Vector4 =
                    # c.Vector4`) must yield the originating raw type, exactly as
                    # `imported_foreign_call` resolves a cross-module callee.
                    return_ty = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, ff.return_type)),
                    params = ff.foreign_params,
                    mapping = ff.mapping,
                    simple = ff_simple,
                    owner_module = ctx.module_name,
                    type_params = ff.type_params,
                ))
            _:
                pass
        i += 1


## Resolve a cross-module foreign function call: find a `foreign function` decl
## named `name` in the target module and build its lowering.ForeignInfo (mapped C name +
## return type + params) resolved in the owner module's context.  Returns none
## when the target has no such foreign function.


public function imported_foreign_call(ctx: ref[lowering.LoweringContext], target_module: str, name: str) -> Option[lowering.ForeignInfo]:
    let owner_a = lowering.find_imported_analysis(ctx, target_module) else:
        return Option[lowering.ForeignInfo].none
    var saved_module = ctx.module_name
    var saved_analysis = ctx.analysis
    ctx.module_name = target_module
    ctx.analysis = owner_a
    var result = Option[lowering.ForeignInfo].none
    var di: ptr_uint = 0
    while di < owner_a.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(owner_a.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_foreign_function as ff:
                if ff.name == name:
                    let ff_simple = foreign_mapping_is_simple(ff.mapping)
                    var ff_c_name = ""
                    if ff_simple:
                        ff_c_name = resolve_foreign_c_name(ctx, ff.mapping)
                    result = Option[lowering.ForeignInfo].some(value = lowering.ForeignInfo(
                        c_name = ff_c_name,
                        return_ty = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, ff.return_type)),
                        params = ff.foreign_params,
                        mapping = ff.mapping,
                        simple = ff_simple,
                        owner_module = target_module,
                        type_params = ff.type_params,
                    ))
            _:
                pass
        di += 1
    ctx.module_name = saved_module
    ctx.analysis = saved_analysis
    return result


## Resolve a cross-module external function call: find an `external function`
## decl named `name` in the target module and return its bare C linkage name
## (or `= target` mapping) plus resolved return type.  External functions carry
## no module prefix, so a cross-module call must use this bare name instead of
## `<module>_<name>`.  Returns none when the target has no such external function.


public function imported_extern_call(ctx: ref[lowering.LoweringContext], target_module: str, name: str) -> Option[lowering.ForeignInfo]:
    let owner_a = lowering.find_imported_analysis(ctx, target_module) else:
        return Option[lowering.ForeignInfo].none
    var saved_module = ctx.module_name
    var saved_analysis = ctx.analysis
    ctx.module_name = target_module
    ctx.analysis = owner_a
    var result = Option[lowering.ForeignInfo].none
    var di: ptr_uint = 0
    while di < owner_a.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(owner_a.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_extern_function as ef:
                if ef.name == name:
                    var ret = ctx.void_ty
                    if ef.return_type != null:
                        ret = lowering.qualify_type(
                            ctx,
                            type_helpers.resolve_return_type(ctx, Option[analyzer.FnSig].none, ef.return_type)
                        )
                    result = Option[lowering.ForeignInfo].some(value = lowering.ForeignInfo(
                        c_name = extern_c_name(ef.name, ef.mapping),
                        return_ty = ret,
                        params = ef.extern_params,
                        mapping = null,
                        simple = true,
                        owner_module = target_module,
                        type_params = ef.type_params,
                    ))
            _:
                pass
        di += 1
    ctx.module_name = saved_module
    ctx.analysis = saved_analysis
    return result


## The C linkage name of an external function declared in `target_module`,
## honoring a `= c"..."` rename mapping (`external function foo = c"__real"`
## resolves to `__real`).  Returns none when `name` is not an external function
## of that module, so callers can fall back to the bare member name.


public function imported_extern_c_name(ctx: ref[lowering.LoweringContext], target_module: str, name: str) -> Option[str]:
    let owner_a = lowering.find_imported_analysis(ctx, target_module) else:
        return Option[str].none
    var di: ptr_uint = 0
    while di < owner_a.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(owner_a.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_extern_function as ef:
                if ef.name == name:
                    return Option[str].some(value = extern_c_name(ef.name, ef.mapping))
            _:
                pass
        di += 1
    return Option[str].none


## Lower a cross-module external function call.  External functions use their
## bare C name; `out`/`inout` parameters are passed by address (`&arg`) so the C
## function can write back through the pointer, mirroring Ruby's
## lower_foreign_pointer_argument_value.


public function lower_extern_call(
    ctx: ref[lowering.LoweringContext],
    info: lowering.ForeignInfo,
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    var ir_args = vec.Vec[ir.Expr].create()
    var i: ptr_uint = 0
    while i < args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(args.data + i)
        var lowered = lowering.lower_expr(ctx, arg.arg_value)
        if i < info.params.len:
            var param: ast.ForeignParam
            unsafe:
                param = read(info.params.data + i)
            # Every bare literal takes the parameter's declared type — the raw
            # external call path shares the foreign rule (`c.time(null)` carries
            # `Nullable(ptr[time_t])`; session 44, item 5b).
            lowered = lowering.literal_value_to_context_type(
                ctx,
                arg.arg_value,
                foreign_param_context_type(ctx, info, param),
                lowered
            )
            if (
                param.param_mode == ast.ForeignParamMode.fmode_out
                or param.param_mode == ast.ForeignParamMode.fmode_inout
            ):
                # The host's `lower_foreign_pointer_argument_value` (the external
                # call path shares it): the address-of's type is
                # `pointer_to(foreign_slot_boundary_value_type(parameter.type))`,
                # so a nullable pointer-like slot contributes its base
                # (`mt_mutex_create(handle)` with `handle: ptr[mt_mutex]?` gets
                # `ptr[ptr[mt_mutex]]`, not `ptr[ptr[mt_mutex]?]`).
                var slot_ty = foreign_param_context_type(ctx, info, param)
                if types.is_nullable_type(slot_ty) and lowering.is_nullable_pointer_like(slot_ty):
                    slot_ty = types.unwrap_nullable(slot_ty)
                let slot_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(lowering.qualify_type(ctx, slot_ty)))
                match addr_operand_expr(lowered):
                    Option.some as op:
                        lowered = lowering.alloc_expr(ir.Expr.expr_cast(
                            target_type = slot_ptr_ty,
                            expression = op.value,
                            ty = slot_ptr_ty
                        ))
                    Option.none:
                        lowered = lowering.alloc_expr(ir.Expr.expr_address_of(expression = lowered, ty = slot_ptr_ty))
        unsafe:
            ir_args.push(read(lowered))
        i += 1
    return lowering.alloc_expr(ir.Expr.expr_call(
        callee = info.c_name,
        arguments = ir_args.as_span(),
        ty = type_helpers.expr_type(ctx, call_ep)
    ))


## Pre-scan function declarations to record each one's resolved return type in
## ctx.function_returns, so call lowering can use the correct type even when the
## analyzer left it unresolved (tuple returns, array returns, etc.).


public function resolve_foreign_c_name(ctx: ref[lowering.LoweringContext], mapping: ptr[ast.Expr]) -> str:
    unsafe:
        match read(mapping):
            ast.Expr.expr_identifier as id:
                let ext = ctx.extern_map.get(id.name)
                if ext != null:
                    return read(ext)
                return id.name
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as recv_id:
                        let mod_ptr = ctx.analysis.imports.get(recv_id.name)
                        if mod_ptr != null:
                            match imported_extern_c_name(ctx, read(mod_ptr), ma.member_name):
                                Option.some as renamed:
                                    return renamed.value
                                Option.none:
                                    pass
                    _:
                        pass
                return ma.member_name
            ast.Expr.expr_prefix_cast as pc:
                return resolve_foreign_c_name(ctx, pc.expression)
            ast.Expr.expr_call as call:
                return resolve_foreign_c_name(ctx, call.callee)
            _:
                return ""


## True when a foreign `= target` mapping is a bare name (`= atoi`,
## `= c.InitWindow`): the call then lowers 1:1 through the mapped C function.
## Call, cast, and construction mappings are inline expressions that must be
## expanded with argument substitution instead.


public function extern_c_name(name: str, mapping: ptr[ast.Expr]?) -> str:
    let m = mapping else:
        return name
    unsafe:
        match read(m):
            ast.Expr.expr_identifier as id:
                return id.name
            ast.Expr.expr_member_access as ma:
                return ma.member_name
            ast.Expr.expr_string_literal as s:
                return s.value
            _:
                return name


## The C name a foreign function maps to: resolve its `= target` identifier
## through the external registry (so `= atoi` yields the external's C name),
## falling back to the target name.  A `= c.Name` member mapping resolves the
## receiver alias to its module and honors the external function's own
## `= c"..."` rename there (so `= c.tracy_emit_zone_begin` yields
## `___tracy_emit_zone_begin`), mirroring Ruby's external_function_c_name.
## Complex inline mapping expressions are handled by
## lower_inline_foreign_mapping instead; this resolver only needs the
## bare-name forms and returns "" for anything else.

public function simple_mapping_callee(mapping: ptr[ast.Expr]) -> Option[lowering.SimpleCallee]:
    unsafe:
        match read(mapping):
            ast.Expr.expr_member_access as ma:
                return Option[lowering.SimpleCallee].some(value = lowering.SimpleCallee(receiver = ma.receiver, name = ma.member_name))
            ast.Expr.expr_prefix_cast as pc:
                return simple_mapping_callee(pc.expression)
            ast.Expr.expr_call as call:
                return simple_mapping_callee(call.callee)
            _:
                return Option[lowering.SimpleCallee].none


public function append_foreign_consuming_releases(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    ep: ptr[ast.Expr]
) -> void:
    var info_opt = Option[lowering.ForeignInfo].none
    var call_args = span[ast.Argument]()
    unsafe:
        match read(ep):
            ast.Expr.expr_call as call:
                call_args = call.args
                match read(call.callee):
                    ast.Expr.expr_identifier as id:
                        let fp = ctx.foreign_map.get(id.name)
                        if fp != null:
                            info_opt = Option[lowering.ForeignInfo].some(value = read(fp))
                    ast.Expr.expr_member_access as ma:
                        match read(ma.receiver):
                            ast.Expr.expr_identifier as rid:
                                let mod_ptr = ctx.analysis.imports.get(rid.name)
                                if mod_ptr != null:
                                    info_opt = lowering.imported_foreign_call(ctx, read(mod_ptr), ma.member_name)
                            _:
                                pass
                    _:
                        pass
            _:
                pass
    let info = info_opt else:
        return
    var refinements = map_mod.Map[str, types.Type].create()
    var i: ptr_uint = 0
    while i < info.params.len and i < call_args.len:
        var param: ast.ForeignParam
        var arg: ast.Argument
        unsafe:
            param = read(info.params.data + i)
            arg = read(call_args.data + i)
        if param.param_mode == ast.ForeignParamMode.fmode_consuming:
            unsafe:
                match read(arg.arg_value):
                    ast.Expr.expr_identifier as aid:
                        match type_helpers.find_local_binding(ctx, aid.name):
                            Option.some as lb:
                                let b = lb.value
                                # The binding's *storage* type: a guard-bound
                                # pointer binding stores the full nullable in its
                                # c_name (projection-carried); option/result
                                # storages cannot satisfy a consuming pointer.
                                var storage_ty = types.primitive("void")
                                match b.projection:
                                    BindingProjection.plain:
                                        storage_ty = b.ty
                                    BindingProjection.nullable_storage as st:
                                        storage_ty = st.storage_ty
                                    _:
                                        pass
                                if types.is_nullable_type(storage_ty):
                                    let base = types.unwrap_nullable(storage_ty)
                                    let param_ty = foreign_param_context_type(ctx, info, param)
                                    if types.type_equals(base, param_ty):
                                        let target = lowering.alloc_expr(ir.Expr.expr_name(
                                            name = b.c_name,
                                            ty = storage_ty,
                                            pointer = b.pointer
                                        ))
                                        output.push(ir.Stmt.stmt_assignment(
                                            target = target,
                                            operator = "=",
                                            value = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = storage_ty)),
                                        ))
                                        refinements.set(aid.name, types.Type.ty_null(target = null))
                            Option.none:
                                pass
                    _:
                        pass
        i += 1
    if refinements.len() > 0:
        let _post = type_helpers.push_flow_refinements(ctx, ref_of(refinements))


public function wrap_foreign_cstr_frees(
    ctx: ref[lowering.LoweringContext],
    setup: ref[vec.Vec[ir.Stmt]],
    result: ptr[ir.Expr],
    ret_ty: types.Type,
    cstr_temps: ref[vec.Vec[str]],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    if ctx.hoist.mode != lowering.HoistMode.hm_off:
        var hs: ptr_uint = 0
        while hs < setup.len:
            let s = setup.get(hs) else:
                fatal(c"lowering: missing foreign setup statement")
            ctx.hoist.stmts.push(unsafe: read(s))
            hs += 1
        # A statement-position (discarded) foreign call is emitted by the
        # lowering itself, without the statement's line/path — the host's
        # `lower_foreign_call_statement(discard_result: true)` shape — whatever
        # its arguments needed; the frees follow it as cleanups.
        if ctx.hoist.mode == lowering.HoistMode.hm_discard and ctx.hoist.root_ep == call_ep:
            var hd: ptr_uint = 0
            while hd < cstr_temps.len():
                ctx.hoist.cleanups.push(lowering.free_cstr_temp_stmt(lowering.cstr_temp_name(cstr_temps, hd)))
                hd += 1
            ctx.hoist.stmts.push(ir.Stmt.stmt_expression(expression = result, line = 0, source_path = ""))
            ctx.hoist.stmt_emitted = true
            return result
        if cstr_temps.len() == 0:
            return result
        # A nested value-position foreign call with temporaries materializes its
        # result before the frees (the host's `prepare_statement_lowered_foreign_call`:
        # `foreign_result` + frees, then the Name).  A statement-root call does
        # not: the assignment/local/return destination stores it directly (the
        # host's `lower_foreign_call_components` path).  A nested call inside a
        # discarded statement (`DrawText(TextFormat(…), …)`) materializes too.
        let nested_value_call = ctx.hoist.mode != lowering.HoistMode.hm_off and call_ep != ctx.hoist.root_ep
        if (ctx.hoist.mode == lowering.HoistMode.hm_return or nested_value_call) and not types.is_void(ret_ty):
            let rt = lowering.fresh_c_temp_name(ctx, "foreign_result")
            ctx.hoist.stmts.push(ir.Stmt.stmt_local(
                name = rt,
                linkage_name = rt,
                ty = ret_ty,
                value = result,
                line = 0,
                source_path = ""
            ))
            var hi: ptr_uint = 0
            while hi < cstr_temps.len():
                ctx.hoist.stmts.push(lowering.free_cstr_temp_stmt(lowering.cstr_temp_name(cstr_temps, hi)))
                hi += 1
            return lowering.alloc_expr(ir.Expr.expr_name(name = rt, ty = ret_ty, pointer = Option[bool].some(value = false)))
        var hj: ptr_uint = 0
        while hj < cstr_temps.len():
            ctx.hoist.cleanups.push(lowering.free_cstr_temp_stmt(lowering.cstr_temp_name(cstr_temps, hj)))
            hj += 1
        return result

    if cstr_temps.len() == 0:
        if setup.len() == 0:
            return result
        return lowering.alloc_expr(ir.Expr.expr_stmt_expr(setup = setup.as_span(), result = result, ty = ret_ty))

    if types.is_void(ret_ty):
        setup.push(ir.Stmt.stmt_expression(expression = result, line = 0, source_path = ""))
        var fi: ptr_uint = 0
        while fi + 1 < cstr_temps.len():
            setup.push(lowering.free_cstr_temp_stmt(lowering.cstr_temp_name(cstr_temps, fi)))
            fi += 1
        let last_result = lowering.free_cstr_temp_call(lowering.cstr_temp_name(cstr_temps, cstr_temps.len() - 1))
        return lowering.alloc_expr(ir.Expr.expr_stmt_expr(setup = setup.as_span(), result = last_result, ty = ret_ty))

    let rt = lowering.fresh_c_temp_name(ctx, "foreign_result")
    setup.push(ir.Stmt.stmt_local(
        name = rt,
        linkage_name = rt,
        ty = ret_ty,
        value = result,
        line = 0,
        source_path = ""
    ))
    var fj: ptr_uint = 0
    while fj < cstr_temps.len():
        setup.push(lowering.free_cstr_temp_stmt(lowering.cstr_temp_name(cstr_temps, fj)))
        fj += 1
    let ret_result = lowering.alloc_expr(ir.Expr.expr_name(name = rt, ty = ret_ty, pointer = Option[bool].some(value = false)))
    return lowering.alloc_expr(ir.Expr.expr_stmt_expr(setup = setup.as_span(), result = ret_result, ty = ret_ty))


public function walk_mapping_expr(
    ctx: ref[lowering.LoweringContext],
    ep: ptr[ast.Expr],
    top_ret_ty: types.Type,
    owner_module: str
) -> ptr[ir.Expr]:
    if not lowering.mapping_contains_external_call(ctx, ep):
        return lowering.lower_expr(ctx, ep)
    unsafe:
        match read(ep):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_member_access as ma:
                        if not lowering.member_receiver_is_local(ctx, ma.receiver):
                            var cargs = vec.Vec[ir.Expr].create()
                            let raw_info = lowering.mapping_call_foreign_info(ctx, owner_module, ma.receiver, ma.member_name)
                            var k: ptr_uint = 0
                            while k < call.args.len:
                                var a: ast.Argument
                                a = read(call.args.data + k)
                                var arg_ir = walk_mapping_expr(ctx, a.arg_value, top_ret_ty, owner_module)
                                # A literal mapping argument (the fixed `null` of
                                # `= c.SDL_RunApp(..., null)`) takes the raw C
                                # parameter's declared type, the host's
                                # `lower_contextual_expression` against the
                                # resolved declaration (item 5b's rule on the
                                # mapping path).
                                match raw_info:
                                    Option.some as ri:
                                        if k < ri.value.params.len:
                                            var raw_param: ast.ForeignParam
                                            raw_param = read(ri.value.params.data + k)
                                            arg_ir = lowering.literal_value_to_context_type(
                                                ctx,
                                                a.arg_value,
                                                foreign_param_context_type(ctx, ri.value, raw_param),
                                                arg_ir
                                            )
                                    Option.none:
                                        pass
                                cargs.push(read(arg_ir))
                                k += 1
                            var call_ty = top_ret_ty
                            match lowering.mapping_call_return_type(ctx, owner_module, ma.receiver, ma.member_name):
                                Option.some as rt:
                                    call_ty = rt.value
                                Option.none:
                                    pass
                            return lowering.alloc_expr(ir.Expr.expr_call(
                                callee = ma.member_name,
                                arguments = cargs.as_span(),
                                ty = call_ty
                            ))
                        return lowering.lower_expr(ctx, ep)
                    ast.Expr.expr_specialization:
                        return lowering.walk_mapping_construction(ctx, call.args, top_ret_ty, owner_module)
                    _:
                        return lowering.lower_expr(ctx, ep)
            ast.Expr.expr_prefix_cast as pc:
                let target = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, pc.target_type))
                let inner = walk_mapping_expr(ctx, pc.expression, top_ret_ty, owner_module)
                return lowering.alloc_expr(ir.Expr.expr_cast(target_type = target, expression = inner, ty = target))
            ast.Expr.expr_member_access as ma:
                # Field access on an external call result (`c.MatrixToFloatV(mat).v`):
                # walk the receiver so the external call is rebuilt, then take the
                # member.  The member's type is the mapping's own return type here
                # (the field IS the projected result).
                let recv = walk_mapping_expr(ctx, ma.receiver, top_ret_ty, owner_module)
                return lowering.alloc_expr(ir.Expr.expr_member(receiver = recv, member = ma.member_name, ty = top_ret_ty))
            ast.Expr.expr_binary_op as bin:
                let l = walk_mapping_expr(ctx, bin.left, top_ret_ty, owner_module)
                let r = walk_mapping_expr(ctx, bin.right, top_ret_ty, owner_module)
                # The rebuilt node keeps the analyzer's recorded type (the host
                # lowers the mapping through `lower_expression`): a comparison
                # (`= c.glfwInit() != 0`) is `bool`, not its left operand's type.
                var bty = type_helpers.expr_type(ctx, ep)
                if types.is_error(bty) or types.type_to_string(bty) == "void":
                    bty = lowering.ir_expr_type(l)
                return lowering.alloc_expr(ir.Expr.expr_binary(operator = bin.operator, left = l, right = r, ty = bty))
            ast.Expr.expr_unary_op as un:
                let operand = walk_mapping_expr(ctx, un.operand, top_ret_ty, owner_module)
                var uty = type_helpers.expr_type(ctx, ep)
                if types.is_error(uty) or types.type_to_string(uty) == "void":
                    uty = lowering.ir_expr_type(operand)
                return lowering.alloc_expr(ir.Expr.expr_unary(operator = un.operator, operand = operand, ty = uty))
            _:
                return lowering.lower_expr(ctx, ep)


public function inlineable_foreign_value(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_name:
                return true
            ir.Expr.expr_integer_literal:
                return true
            ir.Expr.expr_unsigned_integer_literal:
                return true
            ir.Expr.expr_float_literal:
                return true
            ir.Expr.expr_string_literal:
                return true
            ir.Expr.expr_boolean_literal:
                return true
            ir.Expr.expr_null_literal:
                return true
            ir.Expr.expr_zero_init:
                return true
            ir.Expr.expr_sizeof:
                return true
            ir.Expr.expr_alignof:
                return true
            ir.Expr.expr_offsetof:
                return true
            ir.Expr.expr_call as call:
                if lowering.is_foreign_cstr_temp_call(ep):
                    return false
                var k: ptr_uint = 0
                while k < call.arguments.len:
                    if not inlineable_foreign_value(call.arguments.data + k):
                        return false
                    k += 1
                return true
            ir.Expr.expr_call_indirect as call:
                if not inlineable_foreign_value(call.callee):
                    return false
                var k2: ptr_uint = 0
                while k2 < call.arguments.len:
                    if not inlineable_foreign_value(call.arguments.data + k2):
                        return false
                    k2 += 1
                return true
            ir.Expr.expr_member as m:
                return inlineable_foreign_value(m.receiver)
            ir.Expr.expr_index as x:
                return inlineable_foreign_value(x.receiver) and inlineable_foreign_value(x.index)
            ir.Expr.expr_checked_index as x:
                return inlineable_foreign_value(x.receiver) and inlineable_foreign_value(x.index)
            ir.Expr.expr_checked_span_index as x:
                return inlineable_foreign_value(x.receiver) and inlineable_foreign_value(x.index)
            ir.Expr.expr_nullable_index as x:
                return inlineable_foreign_value(x.receiver) and inlineable_foreign_value(x.index)
            ir.Expr.expr_nullable_span_index as x:
                return inlineable_foreign_value(x.receiver) and inlineable_foreign_value(x.index)
            ir.Expr.expr_unary as u:
                return inlineable_foreign_value(u.operand)
            ir.Expr.expr_binary as b:
                return inlineable_foreign_value(b.left) and inlineable_foreign_value(b.right)
            ir.Expr.expr_conditional as c:
                return inlineable_foreign_value(c.condition) and inlineable_foreign_value(c.then_expression) and inlineable_foreign_value(c.else_expression)
            ir.Expr.expr_reinterpret as r:
                let rp = unsafe: read(r.payload)
                return inlineable_foreign_value(rp.expression)
            ir.Expr.expr_cast as c:
                return inlineable_foreign_value(c.expression)
            ir.Expr.expr_address_of as a:
                return inlineable_foreign_value(a.expression)
            ir.Expr.expr_aggregate_literal as g:
                var fi: ptr_uint = 0
                while fi < g.fields.len:
                    let f = unsafe: read(g.fields.data + fi)
                    if not inlineable_foreign_value(f.value):
                        return false
                    fi += 1
                return true
            _:
                return false
