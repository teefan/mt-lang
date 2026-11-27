## Call lowering, extracted from lowering/lowering.mt (Wave 4.2).

import std.map as map_mod
import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types
import mtc.strings
import mtc.c_naming as naming

import mtc.lowering.async_cps as async_cps
import mtc.lowering.comptime as comptime
import mtc.lowering.comptime_types as comptime_types
import mtc.lowering.const_eval as const_eval
import mtc.lowering.control_flow as control_flow
import mtc.lowering.format as format
import mtc.lowering.inline as inline_mod
import mtc.lowering.layout as layout_mod
import mtc.lowering.match as match_mod
import mtc.lowering.monomorphized as monomorphized
import mtc.lowering.parallel as parallel_mod
import mtc.lowering.tasks as tasks
import mtc.lowering.declarations as decl_mod
import mtc.lowering.foreign as foreign_mod
import mtc.lowering.lowering as lowering
import mtc.lowering.member_access as member_mod
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.utils as utils


public function lower_call(
    ctx: ref[lowering.LoweringContext],
    callee: ptr[ast.Expr],
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier:
                return lower_identifier_call(ctx, callee, args, call_ep)
            ast.Expr.expr_specialization:
                return lower_specialization_callee_call(ctx, callee, args, call_ep)
            ast.Expr.expr_member_access:
                return member_mod.lower_member_call(ctx, callee, args, call_ep)
            ast.Expr.expr_index_access as ix:
                # Calling a proc held in an array or span element: `ops[i](args)`.
                # The element type comes from the receiver when the analyzer did
                # not record one for the index expression.
                var elem_ty = type_helpers.expr_type(ctx, callee)
                if not lowering.is_proc_type(elem_ty):
                    elem_ty = lowering.generic_first_arg(lowering.index_receiver_type(ctx, ix.receiver))
                if lowering.is_proc_type(elem_ty):
                    let elem_recv = lowering.lower_expr(ctx, callee)
                    return lowering.lower_proc_field_call(ctx, elem_recv, args, call_ep)
                return lowering.alloc_expr(ir.Expr.expr_zero_init(ty = ctx.void_ty))
            _:
                # Call through a callable *value* expression (e.g. a chain call
                # `f(a)(b)`): the host lowers the callee once and shares the node
                # in the `invoke` callee and the `env` argument.
                let callee_expr = lowering.lower_expr(ctx, callee)
                let callee_ty = lowering.ir_expr_type(callee_expr)
                if lowering.is_proc_type(callee_ty):
                    let void_ptr = ctx.ptr_void_ty
                    let env_member = lowering.alloc_expr(ir.Expr.expr_member(
                        receiver = callee_expr,
                        member = "env",
                        ty = void_ptr
                    ))
                    var invoke_args = vec.Vec[ir.Expr].create()
                    unsafe:
                        invoke_args.push(read(env_member))
                    var ai: ptr_uint = 0
                    while ai < args.len:
                        let arg = unsafe: read(args.data + ai)
                        var lowered = lowering.lower_expr(ctx, arg.arg_value)
                        lowered = lowering.literal_value_to_context_type(
                            ctx,
                            arg.arg_value,
                            lowering.proc_param_type_at(callee_ty, ai),
                            lowered
                        )
                        unsafe:
                            invoke_args.push(read(lowered))
                        ai += 1
                    var call_ty = type_helpers.expr_type(ctx, call_ep)
                    if lowering.is_void_type(call_ty) or types.is_error(call_ty) or lowering.is_proc_type(call_ty):
                        call_ty = lowering.proc_return_type(callee_ty)
                    let invoke_field = lowering.alloc_expr(ir.Expr.expr_member(
                        receiver = callee_expr,
                        member = "invoke",
                        ty = lowering.proc_invoke_field_type(callee_ty)
                    ))
                    return lowering.alloc_expr(ir.Expr.expr_call_indirect(
                        callee = invoke_field,
                        arguments = invoke_args.as_span(),
                        ty = call_ty
                    ))
                if lowering.is_fn_type(callee_ty):
                    return lowering.lower_call_with_callee_expr(
                        ctx,
                        callee_expr,
                        args,
                        call_ep,
                        types.alloc_type(type_helpers.expr_type(ctx, call_ep)),
                        lowering.empty_fn_sig()
                    )
                return lowering.alloc_expr(ir.Expr.expr_zero_init(ty = ctx.void_ty))



public function lower_identifier_call(
    ctx: ref[lowering.LoweringContext],
    callee: ptr[ast.Expr],
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    unsafe:
        match read(callee):
            ast.Expr.expr_identifier as id:
                if id.name == "fatal":
                    # `fatal(cstr)` → mt_fatal(const char*); `fatal(str)` →
                    # mt_fatal_str(mt_str), mirroring Ruby's fatal dispatch.
                    var fatal_callee = "mt_fatal"
                    if args.len > 0:
                        if not lowering.fatal_arg_is_cstr(ctx, unsafe: read(args.data + 0).arg_value):
                            fatal_callee = "mt_fatal_str"
                    return lowering.lower_plain_call(ctx, fatal_callee, args, call_ep, null)
                if id.name == "ptr_of" or id.name == "ref_of" or id.name == "const_ptr_of":
                    if args.len == 1:
                        return lower_addr_builtin_call(ctx, id.name, args, call_ep)
                # `read(p)` as an rvalue → pointer dereference `*p`.  The result
                # type is the pointer's element type (more reliable than the
                # analyzer's generically-recorded type inside monomorphized
                # bodies); fall back to the recorded call type otherwise.
                if id.name == "read":
                    if args.len == 1:
                        let inner = lowering.lower_expr(ctx, read(args.data + 0).arg_value)
                        var base = lowering.ir_expr_type(inner)
                        if types.is_nullable_type(base):
                            base = types.unwrap_nullable(base)
                        var elem_ty = type_helpers.expr_type(ctx, call_ep)
                        if types.is_raw_pointer(base) or types.is_ref_type(base) or types.is_own_type(base):
                            elem_ty = types.pointer_element(base)
                        return lowering.alloc_expr(ir.Expr.expr_unary(
                            operator = "*",
                            operand = inner,
                            ty = lowering.qualify_type(ctx, elem_ty)
                        ))
                # `get(coll, index)` → recoverable array/span indexing returning
                # `ptr[T]?` — null on out-of-bounds instead of aborting.
                # Maps to IR checked_index / checked_span_index, mirroring Ruby.
                if id.name == "get":
                    if args.len >= 2:
                        let recv_val = unsafe: read(args.data + 0).arg_value
                        let idx_val = unsafe: read(args.data + 1).arg_value
                        let recv_ty = lowering.index_receiver_type(ctx, recv_val)
                        let recv_ir = lowering.lower_expr(ctx, recv_val)
                        let idx_ir = lowering.lower_expr(ctx, idx_val)
                        var elem_ty = lowering.generic_first_arg(recv_ty)
                        if types.is_error(elem_ty):
                            elem_ty = type_helpers.expr_type(ctx, call_ep)
                        if types.is_nullable_type(elem_ty):
                            elem_ty = types.unwrap_nullable(elem_ty)
                        if lowering.is_array_type(recv_ty):
                            let ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(lowering.qualify_type(ctx, elem_ty)))
                            let nullable_ptr = types.Type.ty_nullable(base = types.alloc_type(ptr_ty))
                            return lowering.alloc_expr(ir.Expr.expr_nullable_index(
                                receiver = recv_ir,
                                index = idx_ir,
                                receiver_type = recv_ty,
                                ty = nullable_ptr
                            ))
                        if lowering.is_span_type(recv_ty):
                            let ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(lowering.qualify_type(ctx, elem_ty)))
                            let nullable_ptr = types.Type.ty_nullable(base = types.alloc_type(ptr_ty))
                            return lowering.alloc_expr(ir.Expr.expr_nullable_span_index(
                                receiver = recv_ir,
                                index = idx_ir,
                                receiver_type = recv_ty,
                                ty = nullable_ptr
                            ))
                # Native `str(data = ..., len = ...)` construction -> mt_str
                # aggregate literal (not a call to a `str` function).
                if id.name == "str":
                    var str_fields = vec.Vec[ir.AggregateField].create()
                    var sfi: ptr_uint = 0
                    while sfi < args.len:
                        var sarg: ast.Argument
                        unsafe:
                            sarg = read(args.data + sfi)
                        let fname = sarg.arg_name else:
                            lowering.fail_lowering_cstr(ctx, c"lowering: str construction requires named fields")
                            return lowering.poison_expr()
                        str_fields.push(ir.AggregateField(name = fname, value = lowering.lower_expr(ctx, sarg.arg_value)))
                        sfi += 1
                    return lowering.alloc_expr(ir.Expr.expr_aggregate_literal(
                        ty = types.Type.ty_str,
                        fields = str_fields.as_span()
                    ))
                if ctx.analysis.structs.contains(id.name):
                    return lowering.lower_aggregate_literal(ctx, id.name, args)
                if lowering.struct_exists_in_imports(ctx, id.name):
                    return lowering.lower_aggregate_literal(ctx, id.name, args)
                # Native type constructors: vec3(x=..., y=..., z=...),
                # mat4(col0=..., ...), quat(x=..., ...).  These are not in
                # structs but are builtin aggregate types.
                if lowering.is_builtin_type_name(id.name):
                    return lowering.lower_aggregate_literal(ctx, id.name, args)
                let foreign_ptr = ctx.foreign_map.get(id.name)
                if foreign_ptr != null:
                    return foreign_mod.lower_foreign_call(ctx, read(foreign_ptr), args, call_ep)
                let extern_ptr = ctx.extern_map.get(id.name)
                if extern_ptr != null:
                    return lowering.lower_plain_call(ctx, read(extern_ptr), args, call_ep, null)
                return lower_plain_identifier_call(ctx, callee, id.name, args, call_ep)
            _:
                fatal(c"lowering: lower_identifier_call called with a non-identifier")



public function lower_addr_builtin_call(
    ctx: ref[lowering.LoweringContext],
    name: str,
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    unsafe:
        let inner = lowering.lower_expr(ctx, read(args.data + 0).arg_value)
        let inner_ty = lowering.ir_expr_type(inner)
        # The analyzer may record the referent type unqualified
        # (e.g. `ref[Counter]` with `Counter` module-less);
        # qualify it so the element matches the host.
        var result_ty = lowering.qualify_type(ctx, type_helpers.expr_type(ctx, call_ep))
        # When expr_type returns void or error (e.g. the analyzer
        # did not record a type for the builtin), compute the
        # correct result type from the argument's type.  Also
        # recompute when the recorded type is a pointer to a void
        # element (`ptr[void]`) but the argument has a concrete
        # type — the analyzer sometimes records the untyped
        # `ptr[void]` for a builtin whose operand is a member
        # access it did not resolve, which would otherwise mask the
        # real referent type.
        let outer_kind = if name == "ptr_of": "ptr" else: if name == "ref_of": "ref" else: "const_ptr"
        let recorded_elem = types.pointer_element(result_ty)
        let recorded_elem_bad = types.is_void(recorded_elem) or types.is_error(recorded_elem)
        let inner_is_concrete = not (types.is_error(inner_ty) or types.is_void(inner_ty))
        if types.is_error(result_ty) or types.is_void(result_ty) or (recorded_elem_bad and inner_is_concrete):
            result_ty = types.generic_type(name = outer_kind, args = lowering.sp_type(inner_ty))
        # The host's `:ptr_of` on a ref-typed argument wraps the
        # reference value in a cast to the result pointer type
        # (`calls.rb`'s `IR::Cast` branch); it does not retype the
        # Name.  `const_ptr_of`/`ref_of` go through the address
        # path instead.
        if name == "ptr_of" and types.is_ref_type(inner_ty):
            return lowering.alloc_expr(ir.Expr.expr_cast(target_type = result_ty, expression = inner, ty = result_ty))
        # When the argument is already a pointer/ref value (e.g. a
        # `ref[T]` parameter, which is a pointer in C), taking its
        # address again would produce `T**`.  Use the pointer value
        # directly; if it is a `*p` deref, use the underlying `p`.
        # Mirrors Ruby's ref_of/ptr_of/const_ptr_of handling.
        match read(inner):
            ir.Expr.expr_name as nm:
                if nm.pointer.unwrap_or(false) or types.is_ref_type(nm.ty) or types.is_own_type(nm.ty):
                    # The operand is already a pointer *value* whose
                    # MT type is a reference (`ref[T]`), or the
                    # binding itself is pointer-lowered, so the
                    # builtin returns it directly.  A mere
                    # raw-pointer MT type (`var p: ptr[int]`) is a
                    # stored pointer value: `ptr_of(p)` must take
                    # its address (`&p`), like the host's
                    # `lower_addr_expression`.  Rebuild the result
                    # type from the lowered pointer's element type:
                    # a monomorphized `this` is a concrete
                    # collapsed struct, whereas the analyzer
                    # recorded the bare generic-body type
                    # (`ref[StateMachine]`), which would break
                    # type-parameter inference at call sites.
                    var direct_ty = result_ty
                    if types.is_raw_pointer(nm.ty) or types.is_ref_type(nm.ty) or types.is_own_type(nm.ty):
                        let elem = types.pointer_element(nm.ty)
                        var kind = "ref"
                        if name == "ptr_of":
                            kind = "ptr"
                        if name == "const_ptr_of":
                            kind = "const_ptr"
                        direct_ty = types.generic_type(name = kind, args = lowering.sp_type(elem))
                    # The host's `lower_addr_expression` wraps a
                    # pointer-lowered Name in `cast_expression(name,
                    # target_type)`: the Name keeps its own type and a
                    # differing target becomes an `IR::Cast`
                    # (`ref_of(this)` on an editable receiver).
                    if types.type_equals(nm.ty, direct_ty):
                        return inner
                    return lowering.alloc_expr(ir.Expr.expr_cast(target_type = direct_ty, expression = inner, ty = direct_ty))
                # ref[T] is already a pointer in C, so ptr_of/const_ptr_of
                # on a ref variable returns the variable directly as a raw
                # pointer to the referent; ref_of returns it as-is.
                if types.is_ref_type(nm.ty):
                    let ref_elem = types.pointer_element(nm.ty)
                    let elem_sp = lowering.sp_type(ref_elem)
                    var adjusted_ty = result_ty
                    if name == "ptr_of":
                        adjusted_ty = types.generic_type(name = "ptr", args = elem_sp)
                    if name == "const_ptr_of":
                        adjusted_ty = types.generic_type(name = "const_ptr", args = elem_sp)
                    if name == "ref_of":
                        pass
                    return lowering.alloc_expr(ir.Expr.expr_name(
                        name = nm.name,
                        ty = adjusted_ty,
                        pointer = Option[bool].some(value = true)
                    ))
            ir.Expr.expr_unary as un:
                if un.operator == "*":
                    # The host casts the deref's operand to the
                    # target when the types differ and returns it
                    # unchanged otherwise.
                    if types.type_equals(lowering.ir_expr_type(un.operand), result_ty):
                        return un.operand
                    return lowering.alloc_expr(ir.Expr.expr_cast(
                        target_type = result_ty,
                        expression = un.operand,
                        ty = result_ty
                    ))
            _:
                pass
        return lowering.alloc_expr(ir.Expr.expr_address_of(expression = inner, ty = result_ty))



public function lower_plain_identifier_call(
    ctx: ref[lowering.LoweringContext],
    callee: ptr[ast.Expr],
    name: str,
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    unsafe:
        # Proc-typed local: `p(args)` → `p.invoke(p.env, args)`.
        match type_helpers.find_local_binding(ctx, name):
            Option.some as lb:
                if lowering.is_proc_type(lb.value.ty):
                    return lowering.lower_proc_call(ctx, lb.value, args, call_ep)
                if lowering.is_fn_type(lb.value.ty):
                    # The host's callee is an `IR::Name` carrying the
                    # function type (a call through the local's value,
                    # not a bare C-name call); the call's type falls back
                    # to the callee's own signature when the analyzer
                    # recorded none (the `lower_proc_call` rule).
                    var ret_ty = type_helpers.expr_type(ctx, call_ep)
                    match lb.value.ty:
                        types.Type.ty_function as ft:
                            let ft_ft = unsafe: read(ft.payload)
                            if lowering.is_void_type(ret_ty):
                                ret_ty = unsafe: read(ft_ft.return_type)
                        _:
                            pass
                    let ret_type_ptr = types.alloc_type(ret_ty)
                    # A guard-projected binding is read as a member chain,
                    # so it cannot be spelled as a bare callee name.
                    match lb.value.projection:
                        lowering.BindingProjection.plain:
                            let callee_expr = lowering.alloc_expr(ir.Expr.expr_name(
                                name = lb.value.c_name,
                                ty = lb.value.ty,
                                pointer = Option[bool].some(value = false)
                            ))
                            return lowering.lower_call_with_callee_expr(
                                ctx,
                                callee_expr,
                                args,
                                call_ep,
                                ret_type_ptr,
                                lowering.empty_fn_sig()
                            )
                        _:
                            return lowering.lower_call_with_callee_expr(
                                ctx,
                                lowering.lower_binding_read(ctx, lb.value),
                                args,
                                call_ep,
                                ret_type_ptr,
                                lowering.empty_fn_sig()
                            )
            Option.none:
                pass
        match lowering.find_generic_function(ctx, name):
            Option.some as gm:
                match lowering.try_inferred_generic_call(ctx, Option[str].none, name, args, call_ep):
                    Option.some as gen_call:
                        return gen_call.value
                    Option.none:
                        pass
            Option.none:
                pass
        # Module-level proc variable: call through proc struct.
        # expr_type on the callee may not have the correct type if the
        # analyzer only records the call expression type, so also check
        # the identifier against the source file's variable declarations.
        var callee_ty = type_helpers.expr_type(ctx, callee)
        if not lowering.is_proc_type(callee_ty):
            callee_ty = lowering.module_var_type(ctx, name)
        if lowering.is_proc_type(callee_ty):
            let c_name = naming.qualified_c_name(ctx.module_name, name)
            let lb = lowering.LocalBinding(
                name = name,
                c_name = c_name,
                ty = callee_ty,
                pointer = Option[bool].some(value = false)
            )
            return lowering.lower_proc_call(ctx, lb, args, call_ep)
        # Compile-time builtins: evaluate to constant literals rather than
        # emitting runtime function calls.  has_attribute returns a bool;
        # field_of / callable_of / attribute_of return opaque handles
        # (zero-init at the IR level since they are consumed only by
        # other compile-time builtins).
        if name == "has_attribute":
            return lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = ctx.bool_ty))
        if name == "field_of" or name == "callable_of" or name == "attribute_of":
            return lowering.alloc_expr(ir.Expr.expr_zero_init(ty = types.Type.ty_error))
        # A `const function` call in an ordinary expression is a normal
        # runtime call (the host emits `examples_comptime_square`); the
        # compile-time evaluation belongs to const initializers, which
        # route through `try_const_typed_value_ir` above.
        # A module-level variable of plain *function* type
        # (`var f: fn() -> void = noop_scene_draw`) is called through its
        # value: the host's callee is an `IR::Name` carrying the function
        # type, not a bare C name (`examples/box3d/*`'s `s_scene_draw()`).
        # `module_var_type` only answers for module-level variables, so a
        # function declaration still takes the direct-call path below.
        match lowering.module_var_type(ctx, name):
            types.Type.ty_function as fn_var_ty:
                let fn_var_ty_ft = unsafe: read(fn_var_ty.payload)
                let c_name = naming.qualified_c_name(ctx.module_name, name)
                let callee_expr = lowering.alloc_expr(ir.Expr.expr_name(
                    name = c_name,
                    ty = lowering.module_var_type(ctx, name),
                    pointer = Option[bool].some(value = false)
                ))
                return lowering.lower_call_with_callee_expr(
                    ctx,
                    callee_expr,
                    args,
                    call_ep,
                    unsafe: fn_var_ty_ft.return_type,
                    lowering.empty_fn_sig()
                )
            _:
                pass
        var ret_ty = lowering.function_return_type(ctx, name)
        var ret_type_ptr = types.alloc_type(ret_ty)
        var plain_args = args
        match lowering.find_func_in_source(ctx.analysis.source_file, name):
            Option.some as fd:
                match fd.value:
                    ast.Decl.decl_function as fun:
                        plain_args = lowering.expand_default_args(fun.method_params, args)
                    _:
                        pass
            Option.none:
                pass
        var callee_c = naming.qualified_c_name(ctx.module_name, name)
        if ctx.is_root_module and name == "main":
            match type_helpers.find_fn_sig(ctx, name):
                Option.some as main_sig:
                    if main_sig.value.is_async:
                        callee_c = naming.qualified_c_name(ctx.module_name, "__async_main")
                Option.none:
                    pass
        return lowering.lower_plain_call_sig(
            ctx,
            callee_c,
            plain_args,
            call_ep,
            ret_type_ptr,
            type_helpers.find_fn_sig(ctx, name)
        )



public function lower_specialization_callee_call(
    ctx: ref[lowering.LoweringContext],
    callee: ptr[ast.Expr],
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    unsafe:
        match read(callee):
            ast.Expr.expr_specialization as spec:
                # When the specialisation callee is a member access
                # (e.g. `r.unpack[CompactHeader]()`), try method resolution
                # before generic-function monomorphization so that
                # extending-block methods with their own type params are found.
                unsafe:
                    match read(spec.callee):
                        ast.Expr.expr_member_access as spma:
                            let sp_recv_ty = lowering.ir_expr_type(lowering.lower_expr(ctx, spma.receiver))
                            var sp_info_opt = lowering.generic_receiver_info(ctx, sp_recv_ty)
                            if sp_info_opt.is_none():
                                sp_info_opt = lowering.ptr_specialization_receiver_info(ctx, sp_recv_ty)
                            match sp_info_opt:
                                Option.some as sp_info:
                                    match lowering.find_generic_method_in_module(
                                        ctx,
                                        sp_info.value.owner_name,
                                        spma.member_name,
                                        sp_info.value.owner_module
                                    ):
                                        Option.some as sp_gm:
                                            if sp_gm.value.method.type_params.len > 0:
                                                var sp_ext_args = vec.Vec[types.Type].create()
                                                var sp_ai: ptr_uint = 0
                                                while sp_ai < sp_info.value.concrete_args.len:
                                                    unsafe:
                                                        sp_ext_args.push(read(sp_info.value.concrete_args.data + sp_ai))
                                                    sp_ai += 1
                                                var sp_tpi: ptr_uint = 0
                                                while sp_tpi < sp_gm.value.method.type_params.len:
                                                    if sp_tpi < spec.arguments.len:
                                                        sp_ext_args.push(lowering.qualify_type(
                                                            ctx,
                                                            lowering.resolve_type_ref(
                                                                ctx,
                                                                unsafe: read(spec.arguments.data + sp_tpi).value
                                                            )
                                                        ))
                                                    else:
                                                        fatal(c"lowering: not enough specialization args for generic method")
                                                    sp_tpi += 1
                                                let sp_ext_info = lowering.GenericReceiver(
                                                    owner_name = sp_info.value.owner_name,
                                                    concrete_args = sp_ext_args.as_span(),
                                                    owner_module = sp_info.value.owner_module
                                                )
                                                return decl_mod.lower_monomorphized_method(
                                                    ctx,
                                                    sp_ext_info,
                                                    sp_gm.value,
                                                    spma.member_name,
                                                    spma.receiver,
                                                    args
                                                )
                                        Option.none:
                                            pass
                                Option.none:
                                    pass
                        _:
                            pass
                return lower_specialization_call(ctx, spec.callee, spec.arguments, args, call_ep)
            _:
                fatal(c"lowering: lower_specialization_callee_call called with a non-specialization")








## The result type of a cross-module call, resolved from the shared program-wide
## return map (keyed by C linkage name), falling back to the analyzer's recorded
## type for the call expression.

public function lower_specialization_call(
    ctx: ref[lowering.LoweringContext],
    spec_callee: ptr[ast.Expr],
    type_args: span[ast.TypeArgument],
    call_args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    unsafe:
        match read(spec_callee):
            ast.Expr.expr_identifier as id:
                if id.name == "span" and type_args.len == 1:
                    var elem_args = vec.Vec[types.Type].create()
                    elem_args.push(lowering.resolve_type_ref(ctx, read(type_args.data + 0).value))
                    let span_ty = types.generic_type(name = "span", args = elem_args.as_span())
                    var fields = vec.Vec[ir.AggregateField].create()
                    var i: ptr_uint = 0
                    while i < call_args.len:
                        let arg = read(call_args.data + i)
                        let field_name = arg.arg_name else:
                            lowering.fail_lowering_cstr(ctx, c"lowering: span construction requires named fields")
                            return lowering.poison_expr()
                        var field_value = lowering.lower_expr(ctx, arg.arg_value)
                        # `.len` is a ptr_uint field, so an integer literal is
                        # re-typed to ptr_uint (matching the host).
                        if field_name == "len":
                            field_value = lowering.int_literal_to_context_type(
                                arg.arg_value,
                                types.primitive("ptr_uint"),
                                field_value
                            )
                        fields.push(ir.AggregateField(name = field_name, value = field_value))
                        i += 1
                    return lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = span_ty, fields = fields.as_span()))
                if id.name == "adapt" and type_args.len == 1:
                    return lowering.lower_adapt_call(ctx, read(type_args.data + 0).value, call_args)
                if id.name == "array" and type_args.len == 2:
                    return lower_array_literal_call(ctx, type_args, call_args)
                if id.name == "simd" and type_args.len == 2:
                    let simd_element_ty = lowering.resolve_type_ref(ctx, read(type_args.data + 0).value)
                    var simd_args = vec.Vec[types.Type].create()
                    simd_args.push(simd_element_ty)
                    simd_args.push(lowering.resolve_array_length_type(ctx, read(type_args.data + 1).value))
                    let simd_ty = types.generic_type(name = "simd", args = simd_args.as_span())
                    var simd_elements = vec.Vec[ir.Expr].create()
                    var sei: ptr_uint = 0
                    while sei < call_args.len:
                        let arg = read(call_args.data + sei)
                        var element_value = lowering.lower_expr(ctx, arg.arg_value)
                        element_value = lowering.int_literal_to_context_type(arg.arg_value, simd_element_ty, element_value)
                        element_value = lowering.float_literal_to_context_type(arg.arg_value, simd_element_ty, element_value)
                        simd_elements.push(read(element_value))
                        sei += 1
                    return lowering.alloc_expr(ir.Expr.expr_array_literal(ty = simd_ty, elements = simd_elements.as_span()))
                if id.name == "str_buffer" and type_args.len == 1:
                    let n_ty = lowering.resolve_type_ref(ctx, read(type_args.data + 0).value)
                    let sb_ty = types.generic_type(name = "str_buffer", args = lowering.sp_type(n_ty))
                    lowering.ensure_str_buffer_struct(ctx, sb_ty)
                    return lowering.alloc_expr(ir.Expr.expr_zero_init(ty = sb_ty))
                # Builtin generic callables: order[T], equal[T], hash[T] — lower
                # to direct C calls with a fixed suffix derived from the type.
                if id.name == "order" or id.name == "equal" or id.name == "hash":
                    return lower_builtin_hook_call(ctx, id.name, type_args, call_args)
                # Builtin `reinterpret[T](value)` → `IR::ReinterpretExpr` (the
                # host always emits the bit reinterpret; the C backend copies
                # the bits instead of a numeric cast, so `reinterpret[uint](f)`
                # yields the IEEE bits rather than `(uint)f`).
                if id.name == "reinterpret" and type_args.len == 1:
                    let target_ty = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, read(type_args.data + 0).value))
                    let arg = unsafe: read(call_args.data + 0)
                    let lowered = lowering.lower_expr(ctx, arg.arg_value)
                    var source_ty = lowering.ir_expr_type(lowered)
                    # The host infers the argument through its lowering env, so
                    # a guarded local carries its narrowed type (`p` after
                    # `if p == null: return` is `ptr[void]`, not `ptr[void]?`)
                    # and an unrefined one its storage type.
                    match unsafe: read(arg.arg_value):
                        ast.Expr.expr_identifier as aid:
                            match type_helpers.visible_local_type(ctx, aid.name):
                                Option.some as visible:
                                    source_ty = visible.value
                                Option.none:
                                    pass
                        _:
                            pass
                    return lowering.alloc_expr(ir.Expr.expr_reinterpret(payload = utils.alloc_reinterpret_expr(
                        target_type = target_ty,
                        source_type = source_ty,
                        expression = lowered,
                        ty = target_ty
                    )))
                # Builtin `zero[T]` → zero-initialized value of type T.
                if id.name == "zero" and type_args.len == 1:
                    let z_ty = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, read(type_args.data + 0).value))
                    return lowering.alloc_expr(ir.Expr.expr_zero_init(ty = z_ty))
                # Builtin `default[T]` → call T.default(), the zero-argument
                # static method on the type.  The method must exist at check time
                # (the analyzer already verified it).
                if id.name == "default" and type_args.len == 1 and call_args.len == 0:
                    let t_ty = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, read(type_args.data + 0).value))
                    match lowering.resolve_method_info(ctx, t_ty, "default"):
                        Option.some as smi:
                            if smi.value.method_kind == ast.MethodKind.mk_static:
                                var nil_receiver = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = t_ty))
                                return lowering.lower_static_call_args(ctx, smi.value, call_args)
                        Option.none:
                            pass
                if (
                    id.name == "attribute_arg" or id.name == "attribute_of"
                    or id.name == "field_of" or id.name == "callable_of"
                    or id.name == "fields_of" or id.name == "members_of"
                    or id.name == "attributes_of" or id.name == "has_attribute"
                    or id.name == "adapt"
                ) and type_args.len >= 1:
                    # `attribute_arg[T](attribute_of(field_of(Type, field), attr),
                    # name)` folds to the attribute's argument literal.
                    if id.name == "attribute_arg":
                        var attr_env = map_mod.Map[str, ptr[ir.Expr]].create()
                        match const_eval.try_const_attribute_arg_ir(ctx, type_args, call_args, ref_of(attr_env)):
                            Option.some as attr_val:
                                return attr_val.value
                            Option.none:
                                pass
                    let z_ty = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, read(type_args.data + 0).value))
                    return lowering.alloc_expr(ir.Expr.expr_zero_init(ty = z_ty))
                # Generic struct constructor, e.g. `Pair[int, int](first = 42, ...)`.
                # Check current module's structs first, then imported modules'
                # (structs referenced in monomorphized generic bodies may be
                # defined in a separate module).
                if lowering.all_call_args_named(call_args):
                    if ctx.analysis.structs.contains(id.name):
                        return lowering.lower_generic_aggregate_literal(ctx, id.name, type_args, call_args)
                    if lowering.struct_exists_in_imports(ctx, id.name):
                        return lowering.lower_generic_aggregate_literal(ctx, id.name, type_args, call_args)
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as recv_id:
                        if ctx.analysis.imports.contains(recv_id.name) and lowering.all_call_args_named(call_args):
                            return lowering.lower_generic_aggregate_literal(ctx, ma.member_name, type_args, call_args)
                    _:
                        pass
                # Member-access specialization: e.g., `vec.Vec[string.String].create()`.
                # Route through method resolution with the concrete type from type args.
                var recv_ty = lowering.expr_type_for_spec(ctx, spec_callee, type_args)
                match lowering.try_generic_method_call(ctx, recv_ty, ma.member_name, ma.receiver, call_args, call_ep):
                    Option.some as gen_call:
                        return gen_call.value
                    Option.none:
                        pass
                match lowering.resolve_method_info(ctx, recv_ty, ma.member_name):
                    Option.some as mi:
                        return lowering.lower_method_resolved(ctx, mi.value, ma.receiver, call_args, call_ep)
                    Option.none:
                        pass
            _:
                pass
    # Generic function call, e.g. `first[int](p)`.  Lower a monomorphized copy of
    # the generic function body with concrete type arguments and emit a call to it.
    return lowering.lower_monomorphized_call(ctx, spec_callee, type_args, call_args, call_ep)


## Lower `array[T, N](elements...)`, applying the element type contextually and
## folding scalar-shaped compile-time constant elements.

public function lower_array_literal_call(
    ctx: ref[lowering.LoweringContext],
    type_args: span[ast.TypeArgument],
    call_args: span[ast.Argument]
) -> ptr[ir.Expr]:
    unsafe:
        let element_ty = lowering.resolve_type_ref(ctx, read(type_args.data + 0).value)
        var array_args = vec.Vec[types.Type].create()
        array_args.push(element_ty)
        array_args.push(lowering.resolve_array_length_type(ctx, read(type_args.data + 1).value))
        let array_ty = types.generic_type(name = "array", args = array_args.as_span())
        var elements = vec.Vec[ir.Expr].create()
        var elem_fold_env = map_mod.Map[str, ptr[ir.Expr]].create()
        var ai: ptr_uint = 0
        while ai < call_args.len:
            let arg = read(call_args.data + ai)
            # Elements take the element type contextually, as the host's
            # `lower_contextual_expression` gives it to them:
            # `array[ubyte, 4](0, 0, 0, 0)` keeps ubyte elements.
            var element_value = lowering.lower_expr(ctx, arg.arg_value)
            element_value = lowering.int_literal_to_context_type(arg.arg_value, element_ty, element_value)
            element_value = lowering.float_literal_to_context_type(arg.arg_value, element_ty, element_value)
            element_value = lowering.null_literal_to_context_type(arg.arg_value, element_ty, element_value)
            # The host folds a *scalar-shaped* compile-time constant element
            # (`int<-Kind.A` → 0, `-1` → -1, `1 + 2` → 3, an imported constant →
            # its aggregate); an aggregate element (a struct literal and its
            # fields) is lowered normally, and a bare literal keeps the
            # contextual retyping above (`array[ubyte, 4](0, …)`).
            var element_foldable = false
            match read(element_value):
                ir.Expr.expr_name:
                    element_foldable = true
                ir.Expr.expr_cast:
                    element_foldable = true
                ir.Expr.expr_unary:
                    element_foldable = true
                ir.Expr.expr_binary:
                    element_foldable = true
                _:
                    pass
            if element_foldable:
                match const_eval.try_const_value_ir(ctx, arg.arg_value, ref_of(elem_fold_env)):
                    Option.some as folded:
                        element_value = folded.value
                    Option.none:
                        pass
            # A `char` element casts its integer literal (`array[char, 512](0,
            # …)` — the host's `contextual_numeric_cast` char arm), applied after
            # the fold so it is not folded away.
            if type_helpers.prim_name(element_ty) == "char" and lowering.is_integer_like_value_type(
                ctx,
                lowering.ir_expr_type(element_value)
            ):
                element_value = type_helpers.cast_to_type(element_value, element_ty)
            elements.push(read(element_value))
            ai += 1
        return lowering.alloc_expr(ir.Expr.expr_array_literal(ty = array_ty, elements = elements.as_span()))


## Lower the builtin generic hooks `order[T]`, `equal[T]`, `hash[T]`: cast or
## borrow each argument to `const_ptr[T]` and call the canonical hook (or the
## `mt_<name>_func` fallback).

public function lower_builtin_hook_call(
    ctx: ref[lowering.LoweringContext],
    id_name: str,
    type_args: span[ast.TypeArgument],
    call_args: span[ast.Argument]
) -> ptr[ir.Expr]:
    unsafe:
        var hook_ty = ctx.void_ty
        if type_args.len >= 1:
            hook_ty = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, read(type_args.data + 0).value))
        let ptr_target = types.generic_type(name = "const_ptr", args = lowering.sp_type(hook_ty))
        var ir_args = vec.Vec[ir.Expr].create()
        var si: ptr_uint = 0
        while si < call_args.len:
            let arg = read(call_args.data + si)
            let lowered = lowering.lower_expr(ctx, arg.arg_value)
            let arg_ty = lowering.ir_expr_type(lowered)
            # The hooks take `const_ptr[T]` (the host's
            # `lower_hash_operation_argument`): a pointer/ref value is cast to
            # that target, a `*p` operand is cast, and an addressable value is
            # borrowed.
            var hook_arg = lowered
            if types.is_raw_pointer(arg_ty) or types.is_ref_type(arg_ty):
                if not types.type_equals(arg_ty, ptr_target):
                    hook_arg = lowering.alloc_expr(ir.Expr.expr_cast(
                        target_type = ptr_target,
                        expression = lowered,
                        ty = ptr_target
                    ))
            else:
                var addressed = true
                match read(lowered):
                    ir.Expr.expr_unary as un:
                        if un.operator == "*":
                            addressed = false
                            let op_ty = lowering.ir_expr_type(un.operand)
                            if types.type_equals(op_ty, ptr_target):
                                hook_arg = un.operand
                            else:
                                hook_arg = lowering.alloc_expr(ir.Expr.expr_cast(
                                    target_type = ptr_target,
                                    expression = un.operand,
                                    ty = ptr_target
                                ))
                    _:
                        pass
                if addressed:
                    hook_arg = lowering.alloc_expr(ir.Expr.expr_address_of(expression = lowered, ty = ptr_target))
            ir_args.push(read(hook_arg))
            si += 1
        var ret_ty = types.primitive("int")
        if id_name == "equal":
            ret_ty = ctx.bool_ty
        else if id_name == "hash":
            ret_ty = types.primitive("uint")
        # Resolve the canonical hook (`T.hash` / `T.equal` / `T.order`) for the
        # type argument to its concrete C function name.
        if type_args.len >= 1:
            let t_ty = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, read(type_args.data + 0).value))
            match lowering.resolve_canonical_hook(ctx, t_ty, id_name):
                Option.some as hook_name:
                    return lowering.alloc_expr(ir.Expr.expr_call(
                        callee = hook_name.value,
                        arguments = ir_args.as_span(),
                        ty = ret_ty
                    ))
                Option.none:
                    pass
        let fn_name = strings.join_two("mt_", strings.join_two(id_name, "_func"))
        return lowering.alloc_expr(ir.Expr.expr_call(callee = fn_name, arguments = ir_args.as_span(), ty = ret_ty))
