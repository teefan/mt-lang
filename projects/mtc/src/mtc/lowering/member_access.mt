## Member access and identifier-member resolution, extracted from
## lowering/lowering.mt (Wave 4.2).

import std.mem.heap as heap
import std.str
import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types
import mtc.semantic.analyzer as analyzer
import mtc.c_naming as naming
import mtc.strings

import mtc.lowering.async_cps as async_cps
import mtc.lowering.control_flow as control_flow
import mtc.lowering.inline as inline_mod
import mtc.lowering.events as events_mod
import mtc.lowering.lowering as lowering
import mtc.lowering.match as match_mod
import mtc.lowering.monomorphized as monomorphized
import mtc.lowering.type_helpers as type_helpers


public function lower_identifier_member(
    ctx: ref[lowering.LoweringContext],
    receiver: ptr[ast.Expr],
    member: str,
    ep: ptr[ast.Expr]
) -> Option[ptr[ir.Expr]]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                # A no-payload variant arm constructor, e.g. `Token.eof`.
                if ctx.variants.contains(id.name):
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_variant_literal(
                        ty = types.imported_type(
                            module_name = ctx.module_name,
                            name = id.name,
                            args = span[types.Type]()
                        ),
                        arm_name = member,
                        fields = span[ir.AggregateField](),
                    )))
                # Synthetic type names (e.g. `EventError.full`) — map to C
                # constant `<Type>_<member>`.
                if id.name == "EventError" and member == "full":
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_name(
                        name = "EventError_full",
                        ty = types.named_type(name = "EventError", module_name = "", linkage_name = Option[str].none),
                        pointer = Option[bool].some(value = false),
                    )))
                if ctx.analysis.static_member_types.contains(id.name):
                    var member_ty = type_helpers.expr_type(ctx, ep)
                    match member_ty:
                        types.Type.ty_error:
                            # Const initializers can miss the analyzer's type map;
                            # a static member's type is its declaring type.
                            member_ty = types.named_type(
                                name = id.name,
                                module_name = ctx.module_name,
                                linkage_name = Option[str].none
                            )
                        _:
                            pass
                    return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_name(
                        name = naming.qualified_member_c_name(ctx.module_name, id.name, member),
                        ty = member_ty,
                        pointer = Option[bool].some(value = false),
                    )))
                # Resolve `import_alias.member` through the imported module.
                let mod_ptr = ctx.analysis.imports.get(id.name)
                if mod_ptr != null:
                    let target_module = read(mod_ptr)
                    match lowering.find_imported_analysis(ctx, target_module):
                        Option.some as imported:
                            if imported.value.type_names.contains(member):
                                let c_name = lowering.imported_member_c_name(ctx, imported.value, target_module, member)
                                var member_ty = type_helpers.expr_type(ctx, ep)
                                # If the member is a re-exported type alias, use
                                # the originating module's type so c_type() produces
                                # the correct C name.
                                let opt_alias = lowering.resolve_single_imported_type(ctx, target_module, member)
                                match opt_alias:
                                    Option.some as resolved:
                                        member_ty = resolved.value
                                    Option.none:
                                        pass
                                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_name(
                                    name = c_name,
                                    ty = member_ty,
                                    pointer = Option[bool].some(value = false),
                                )))
                            if imported.value.value_types.contains(member):
                                let c_name = lowering.imported_member_c_name(ctx, imported.value, target_module, member)
                                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_name(
                                    name = c_name,
                                    ty = type_helpers.expr_type(ctx, ep),
                                    pointer = Option[bool].some(value = false),
                                )))
                        Option.none:
                            pass
            ast.Expr.expr_specialization as spec:
                # No-payload generic variant arm, e.g. `Option[int].none`.
                if spec.arguments.len > 0:
                    var spec_variant_name: Option[str] = Option[str].none
                    match read(spec.callee):
                        ast.Expr.expr_identifier as spec_id:
                            # The declaration is authoritative: a prelude variant
                            # may never have been registered, and a user-defined
                            # generic one only from the declaring module.
                            if ctx.variants.contains(spec_id.name) or lowering.variant_declaring_module(
                                ctx,
                                spec_id.name
                            ).is_some():
                                spec_variant_name = Option[str].some(value = spec_id.name)
                        ast.Expr.expr_member_access as spec_ma:
                            # Module-qualified: `types.Maybe[int].none`.
                            match read(spec_ma.receiver):
                                ast.Expr.expr_identifier as spec_mod_id:
                                    let spec_mod_ptr = ctx.analysis.imports.get(spec_mod_id.name)
                                    if spec_mod_ptr != null:
                                        match lowering.find_imported_analysis(ctx, unsafe: read(spec_mod_ptr)):
                                            Option.some as spec_imported:
                                                if lowering.variant_in_source(spec_imported.value, spec_ma.member_name):
                                                    spec_variant_name = Option[str].some(value = spec_ma.member_name)
                                            Option.none:
                                                pass
                                _:
                                    pass
                        _:
                            pass
                    match spec_variant_name:
                        Option.some as svn:
                            var concrete_args = vec.Vec[types.Type].create()
                            var ai: ptr_uint = 0
                            while ai < spec.arguments.len:
                                # Qualify args to match the signature's C name
                                # (see lower_generic_variant_literal), so a local
                                # struct arg like RemovedEntry becomes module-qualified.
                                concrete_args.push(lowering.qualify_type(
                                    ctx,
                                    lowering.resolve_type_ref(ctx, read(spec.arguments.data + ai).value)
                                ))
                                ai += 1
                            let variant_ty = lowering.generic_variant_instance_type(ctx, svn.value, concrete_args.as_span())
                            return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_variant_literal(
                                ty = variant_ty,
                                arm_name = member,
                                fields = span[ir.AggregateField](),
                            )))
                        Option.none:
                            pass
            ast.Expr.expr_member_access as inner_ma:
                match read(inner_ma.receiver):
                    ast.Expr.expr_identifier as inner_id:
                        let mod_ptr = ctx.analysis.imports.get(inner_id.name)
                        if mod_ptr != null:
                            let target_module = read(mod_ptr)
                            match lowering.find_imported_analysis(ctx, target_module):
                                Option.some as imported:
                                    if (
                                        imported.value.static_member_types.contains(inner_ma.member_name)
                                        or imported.value.type_names.contains(inner_ma.member_name)
                                    ):
                                        match lowering.find_imported_variant_arm(imported.value, member):
                                            Option.some as var_name:
                                                let var_ty = types.imported_type(
                                                    module_name = target_module,
                                                    name = var_name.value,
                                                    args = span[types.Type]()
                                                )
                                                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_variant_literal(
                                                    ty = var_ty,
                                                    arm_name = member,
                                                    fields = span[ir.AggregateField](),
                                                )))
                                            Option.none:
                                                var use_bare = target_module.starts_with("std.c.")
                                                if (
                                                    not use_bare
                                                    and imported.value.type_alias_types.contains(inner_ma.member_name)
                                                ):
                                                    let aliased_ptr = imported.value.type_alias_types.get(inner_ma.member_name) else:
                                                        fatal(c"lowering: enum type alias inconsistency")
                                                    let aliased = unsafe: read(aliased_ptr)
                                                    if lowering.type_is_from_std_c(aliased):
                                                        use_bare = true
                                                var member_c_name = member
                                                if not use_bare:
                                                    member_c_name = naming.qualified_member_c_name(
                                                        target_module,
                                                        inner_ma.member_name,
                                                        member
                                                    )
                                                return Option[ptr[ir.Expr]].some(value = lowering.alloc_expr(ir.Expr.expr_name(
                                                    name = member_c_name,
                                                    ty = type_helpers.expr_type(ctx, ep),
                                                    pointer = Option[bool].some(value = false),
                                                )))
                                Option.none:
                                    pass
                    _:
                        pass
            _:
                pass
    return Option[ptr[ir.Expr]].none


public function lower_member_access(
    ctx: ref[lowering.LoweringContext],
    receiver: ptr[ast.Expr],
    member: str,
    ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    match inline_mod.inline_for_member_subst(ctx, receiver, member):
        Option.some as subst:
            return subst.value
        Option.none:
            pass
    match lower_identifier_member(ctx, receiver, member, ep):
        Option.some as early:
            return early.value
        Option.none:
            pass
    # SoA index+member swap: `particles[0].x` → `particles.x[0]` (mirrors
    # Ruby's lower_soa_indexed_field_access).  Detect when the member access
    # receiver is an index into an SoA type, and lower the field access first.
    unsafe:
        match read(receiver):
            ast.Expr.expr_index_access as ix:
                let base_ty = lowering.index_receiver_type(ctx, ix.receiver)
                if lowering.is_soa_type(base_ty):
                    let soa_base = lowering.lower_expr(ctx, ix.receiver)
                    let idx = lowering.lower_expr(ctx, ix.index)
                    # The swapped member is the SoA struct's array field; the
                    # index then selects the lane (the host's
                    # `lower_soa_indexed_field_access` types the member with
                    # `soa_type.fields[field]`, i.e. `array[T, N]`).
                    var field_ty = lowering.soa_field_type(ctx, base_ty, member)
                    match lowering.soa_member_array_type(ctx, base_ty, member):
                        Option.some as at:
                            field_ty = at.value
                        Option.none:
                            pass
                    let member_expr = lowering.alloc_expr(ir.Expr.expr_member(
                        receiver = soa_base,
                        member = member,
                        ty = field_ty,
                    ))
                    return lowering.alloc_expr(ir.Expr.expr_index(
                        receiver = member_expr,
                        index = idx,
                        ty = type_helpers.expr_type(ctx, ep),
                    ))
            _:
                pass
    let recv = lowering.lower_expr(ctx, receiver)
    var member_ty = type_helpers.expr_type(ctx, ep)
    let recv_ty = lowering.ir_expr_type(recv)
    # A `ref` receiver auto-dereferences for member access (matching the host's
    # `unwrap_ref`), so `.data`/`.len` on `ref[span[T]]` must be typed against
    # the referent `span[T]`.
    var member_recv_ty = recv_ty
    if types.is_ref_type(member_recv_ty):
        member_recv_ty = types.pointer_element(member_recv_ty)
    # span synthetic fields: `.data` is ptr[element], `.len` is ptr_uint.  The
    # analyzer records these as ty_error (permissive), so type them here.
    if lowering.is_span_type(member_recv_ty) and member == "data":
        member_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.pointer_element(member_recv_ty)))
    else if lowering.is_span_type(member_recv_ty) and member == "len":
        member_ty = types.primitive("ptr_uint")
    # str synthetic fields: `.data` is ptr[char], `.len` is ptr_uint.  Like span,
    # the analyzer does not type these reliably (a `var n = text.len` would
    # otherwise be mis-typed as str).
    else if type_helpers.is_str_typed(member_recv_ty) and member == "data":
        member_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("char")))
    else if type_helpers.is_str_typed(member_recv_ty) and member == "len":
        member_ty = types.primitive("ptr_uint")
    # SoA synthetic fields: `points.x` is the per-lane array
    # `array[<element field type>, N]` (the host's `Types::SoA#field`).
    else if lowering.is_soa_type(member_recv_ty):
        match lowering.soa_member_array_type(ctx, member_recv_ty, member):
            Option.some as sat:
                member_ty = sat.value
            Option.none:
                pass
    # vec/mat/quat field types: the analyzer doesn't record these reliably
    # since these are builtin types, not declared structs.
    else if type_helpers.is_vec_math_name(type_helpers.nominal_type_name(member_recv_ty)):
        let vname = type_helpers.nominal_type_name(member_recv_ty)
        var field_names = vec.Vec[str].create()
        var field_types = vec.Vec[types.Type].create()
        type_helpers.vec_math_fields(vname, ref_of(field_names), ref_of(field_types))
        var fi: ptr_uint = 0
        var found = false
        while fi < field_names.len():
            let fn_ptr = field_names.get(fi) else:
                fatal(c"lower_member_access: missing vec field name")
            if unsafe: read(fn_ptr) == member:
                let ft_ptr = field_types.get(fi) else:
                    fatal(c"lower_member_access: missing vec field type")
                member_ty = unsafe: read(ft_ptr)
                found = true
                break
            fi += 1
        if not found:
            pass
    else:
        # Prefer the receiver's concrete (monomorphized) struct field type: the
        # analyzer records member types generically (e.g. Node[K,V] -> Node with
        # the args dropped), so inside a monomorphized method the recorded type
        # loses its arguments.  The concrete struct declaration carries the
        # resolved field type.
        match lowering.concrete_field_type(ctx, recv_ty, member):
            Option.some as ft:
                member_ty = ft.value
            Option.none:
                match match_mod.arm_payload_field_type(ctx, recv_ty, member):
                    Option.some as aft:
                        member_ty = aft.value
                    Option.none:
                        match lowering.imported_field_type(ctx, recv_ty, member):
                            Option.some as ift:
                                member_ty = ift.value
                            Option.none:
                                if types.is_error(member_ty) or lowering.is_tuple_type(member_ty):
                                    if lowering.is_tuple_type(recv_ty):
                                        match recv_ty:
                                            types.Type.ty_tuple as tup:
                                                let tup_bp = unsafe: read(tup.payload)
                                                match tup_bp.field_names:
                                                    Option.some as fnames:
                                                        var fi: ptr_uint = 0
                                                        while fi < fnames.value.len:
                                                            if unsafe: read(fnames.value.data + fi) == member:
                                                                if fi < tup_bp.elements.len:
                                                                    member_ty = unsafe: read(tup_bp.elements.data + fi)
                                                                break
                                                            fi += 1
                                                    Option.none:
                                                        let index = lowering.parse_tuple_member_index(member)
                                                        member_ty = lowering.tuple_element_type(recv_ty, index)
                                            _:
                                                pass
    # An event field is stored under its hidden C name (`__event_<name>`) and
    # typed as the event, as the host's `event_member_from_owner_type` routes it
    # through the receiver struct's own event map.
    var member_name = member
    var member_type = member_ty
    match events_mod.event_info_for_receiver(ctx, recv_ty, member):
        Option.some as evi:
            member_name = strings.join_two("__event_", member)
            var ev_info = events_mod.ensure_event_runtime(ctx, evi.value.owner_type_name, member)
            var ev_payload: ptr[types.Type]? = null
            if ev_info.has_payload:
                ev_payload = types.alloc_type(ev_info.payload_type)
            member_type = types.event_type(
                name = evi.value.name,
                capacity = ev_info.capacity,
                payload_type = ev_payload,
                linkage_name = ev_info.event_c_name
            )
        Option.none:
            # A member already typed as an event (an imported event, a
            # module-level registration) keeps its bare-name resolution.
            if lowering.is_event_type(ctx, member_ty):
                member_name = strings.join_two("__event_", member)
                let ev_name = events_mod.event_name_from_type(member_ty)
                if ctx.analysis.events.contains(ev_name):
                    var ev_info = events_mod.ensure_event_runtime(ctx, "", ev_name)
                    var ev_payload: ptr[types.Type]? = null
                    if ev_info.has_payload:
                        ev_payload = types.alloc_type(ev_info.payload_type)
                    member_type = types.event_type(
                        name = ev_name,
                        capacity = ev_info.capacity,
                        payload_type = ev_payload,
                        linkage_name = ev_info.event_c_name
                    )
    var result = lowering.alloc_expr(ir.Expr.expr_member(
        receiver = recv,
        member = member_name,
        ty = lowering.qualify_type(ctx, member_type),
    ))
    # Auto-dereference recursive variant fields (e.g. bin.left where left
    # is stored as Expr* in C to avoid infinite struct size).
    # Only applicable when recv_ty is a variant arm payload struct.
    match recv_ty:
        types.Type.ty_named as rn:
            let rn_np = unsafe: read(rn.payload)
            if ctx.arm_payload_fields.contains(rn_np.name):
                if match_mod.is_recursive_variant_field(recv_ty, member_ty):
                    return lowering.alloc_expr(ir.Expr.expr_unary(operator = "*", operand = result, ty = member_ty))
        types.Type.ty_imported as ri:
            let ri_bp = unsafe: read(ri.payload)
            if ctx.arm_payload_fields.contains(naming.qualified_c_name(ri_bp.module_name, ri_bp.name)):
                if match_mod.is_recursive_variant_field(recv_ty, member_ty):
                    return lowering.alloc_expr(ir.Expr.expr_unary(operator = "*", operand = result, ty = member_ty))
        types.Type.ty_variant_arm_payload:
            if match_mod.is_recursive_variant_field(recv_ty, member_ty):
                return lowering.alloc_expr(ir.Expr.expr_unary(operator = "*", operand = result, ty = member_ty))
        _:
            pass
    return result

public function lower_member_call(
    ctx: ref[lowering.LoweringContext],
    callee: ptr[ast.Expr],
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    unsafe:
        match read(callee):
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as recv_id:
                        # A non-generic variant arm constructor, e.g. `Token.number(value = 41)`.
                        if ctx.variants.contains(recv_id.name):
                            return lowering.lower_variant_literal(ctx, recv_id.name, ma.member_name, args)
                        # Static hook / method call on a primitive or `str` type
                        # name, e.g. `str.order(a, b)` → `str_order_static(a, b)`.
                        if lowering.is_primitive_or_str_name(recv_id.name):
                            match lowering.resolve_primitive_method_info(ctx, recv_id.name, ma.member_name):
                                Option.some as prim_mi:
                                    return lowering.lower_static_call_args(ctx, prim_mi.value, args)
                                Option.none:
                                    pass
                        # Static method call on a struct type name, e.g.
                        # `String.create()`.  The receiver is a bare type name (not
                        # a value), so resolve the static method and lower only the
                        # arguments.  Mirrors the Ruby resolver's `resolve_type_expression`
                        # + `static:<method>` associated-function path.
                        if lowering.struct_exists_in_imports(ctx, recv_id.name):
                            let static_recv_ty = types.named_type(
                                name = recv_id.name,
                                module_name = "",
                                linkage_name = Option[str].none
                            )
                            match lowering.resolve_method_info(ctx, static_recv_ty, ma.member_name):
                                Option.some as smi:
                                    if smi.value.method_kind == ast.MethodKind.mk_static:
                                        return lowering.lower_static_call_args(ctx, smi.value, args)
                                Option.none:
                                    pass
                        let mod_ptr = ctx.analysis.imports.get(recv_id.name)
                        if mod_ptr != null:
                            let target_module = read(mod_ptr)
                            # Check if member_name is a struct in the imported module
                            # (struct constructor, e.g. ir.Field(name, ty)).
                            match lowering.find_imported_analysis(ctx, target_module):
                                Option.some as imported:
                                    if imported.value.structs.contains(ma.member_name):
                                        return lowering.lower_aggregate_literal_in_module(
                                            ctx,
                                            ma.member_name,
                                            args,
                                            target_module
                                        )
                                    # member_name may be a type alias pointing to a
                                    # struct in an external module (e.g.
                                    # `type Rectangle = c.Rectangle`).  Follow the
                                    # alias chain to the originating struct module
                                    # and construct an aggregate literal there.
                                    if imported.value.type_alias_types.contains(ma.member_name):
                                        let alias_target = imported.value.type_alias_types.get(ma.member_name)
                                        if alias_target != null:
                                            var at = unsafe: read(alias_target)
                                            # Unwrap nullable so `rl.Color?` resolves
                                            # to the underlying struct type.
                                            var base = at
                                            if types.is_nullable_type(base):
                                                base = types.unwrap_nullable(base)
                                            match base:
                                                types.Type.ty_imported as aim:
                                                    let aim_bp = unsafe: read(aim.payload)
                                                    return lowering.lower_aggregate_literal_in_module(
                                                        ctx,
                                                        aim_bp.name,
                                                        args,
                                                        aim_bp.module_name
                                                    )
                                                types.Type.ty_named as nm:
                                                    let nm_np = unsafe: read(nm.payload)
                                                    return lowering.lower_aggregate_literal_in_module(
                                                        ctx,
                                                        nm_np.name,
                                                        args,
                                                        nm_np.module_name
                                                    )
                                                _:
                                                    pass
                                    # Check if ma.member_name is a variant arm in any
                                    # imported variant (e.g. types.Type.ty_named(linkage_name = Option[str].none, name)).
                                    match lowering.find_imported_variant_arm(imported.value, ma.member_name):
                                        Option.some as var_name:
                                            let var_ty = types.imported_type(
                                                module_name = target_module,
                                                name = var_name.value,
                                                args = span[types.Type]()
                                            )
                                            return lowering.alloc_expr(ir.Expr.expr_variant_literal(
                                                ty = var_ty,
                                                arm_name = ma.member_name,
                                                fields = lowering.collect_variant_literal_fields(
                                                    ctx,
                                                    args,
                                                    var_ty,
                                                    ma.member_name
                                                ),
                                            ))
                                        Option.none:
                                            pass
                                Option.none:
                                    pass
                            # Cross-module foreign function call (`libc.getenv_wrapper(...)`):
                            # a foreign function lowers to a direct call on its
                            # mapped C function (e.g. `getenv`), not a Milk Tea
                            # module-qualified symbol.  Resolve it against the
                            # target module's declarations before the plain path.
                            match lowering.imported_foreign_call(ctx, target_module, ma.member_name):
                                Option.some as ff_info:
                                    return lowering.lower_foreign_call(ctx, ff_info.value, args, call_ep)
                                Option.none:
                                    pass
                            # Cross-module external function call (`libc.malloc(...)`):
                            # an external function uses its bare C name (or `= target`
                            # mapping), not a module-qualified symbol.  Resolve it
                            # against the target module before the plain path so its
                            # linkage name and return type are correct.
                            match lowering.imported_extern_call(ctx, target_module, ma.member_name):
                                Option.some as ext_info:
                                    return lowering.lower_extern_call(ctx, ext_info.value, args, call_ep)
                                Option.none:
                                    pass
                            # Cross-module generic function call with inferred type
                            # args (`heap.release(x)` → `heap.release[T]`): infer T
                            # from the argument types and monomorphize.
                            match lowering.try_inferred_generic_call(
                                ctx,
                                Option[str].some(value = target_module),
                                ma.member_name,
                                args,
                                call_ep
                            ):
                                Option.some as gen_call:
                                    return gen_call.value
                                Option.none:
                                    pass
                            let c_name = naming.qualified_c_name(target_module, ma.member_name)
                            var ret_ty = lowering.cross_module_return_type(ctx, c_name, call_ep)
                            var ret_type_ptr = types.alloc_type(ret_ty)
                            var cross_sig = type_helpers.find_imported_fn_sig(ctx, target_module, ma.member_name)
                            var cross_args = args
                            match lowering.find_imported_analysis(ctx, target_module):
                                Option.some as imported:
                                    match lowering.find_func_in_source(imported.value.source_file, ma.member_name):
                                        Option.some as fd:
                                            match fd.value:
                                                ast.Decl.decl_function as fun:
                                                    cross_args = lowering.expand_default_args(fun.method_params, args)
                                                _:
                                                    pass
                                        Option.none:
                                            pass
                                Option.none:
                                    pass
                            return lowering.lower_plain_call_sig(ctx, c_name, cross_args, call_ep, ret_type_ptr, cross_sig)
                    ast.Expr.expr_specialization as spec:
                        # A generic variant arm constructor, e.g. `Option[int].some(value = 42)`.
                        # A GENERIC variant is deliberately absent from `ctx.variants`
                        # (that registry drives non-generic match resolution), so
                        # fall back to the declarations, local then imported.
                        if spec.arguments.len > 0:
                            match read(spec.callee):
                                ast.Expr.expr_identifier as spec_id:
                                    if ctx.variants.contains(spec_id.name):
                                        return lowering.lower_generic_variant_literal(
                                            ctx,
                                            spec_id.name,
                                            spec.arguments,
                                            ma.member_name,
                                            args
                                        )
                                    match lowering.variant_declaring_module(ctx, spec_id.name):
                                        Option.some:
                                            return lowering.lower_generic_variant_literal(
                                                ctx,
                                                spec_id.name,
                                                spec.arguments,
                                                ma.member_name,
                                                args
                                            )
                                        Option.none:
                                            pass
                                ast.Expr.expr_member_access as spec_ma:
                                    # Module-qualified: `types.Outcome[int, E].ok(value = 7)`.
                                    match read(spec_ma.receiver):
                                        ast.Expr.expr_identifier as spec_mod_id:
                                            let spec_mod_ptr = ctx.analysis.imports.get(spec_mod_id.name)
                                            if spec_mod_ptr != null:
                                                match lowering.find_imported_analysis(ctx, unsafe: read(spec_mod_ptr)):
                                                    Option.some as spec_imported:
                                                        if lowering.variant_in_source(spec_imported.value, spec_ma.member_name):
                                                            return lowering.lower_generic_variant_literal(
                                                                ctx,
                                                                spec_ma.member_name,
                                                                spec.arguments,
                                                                ma.member_name,
                                                                args
                                                            )
                                                    Option.none:
                                                        pass
                                        _:
                                            pass
                                _:
                                    pass
                    ast.Expr.expr_member_access as inner_ma:
                        # Imported variant arm constructor: `alias.Variant.arm(args)`,
                        # e.g. `types.Type.ty_named(linkage_name = Option[str].none, name)`.
                        match read(inner_ma.receiver):
                            ast.Expr.expr_identifier as inner_id:
                                let mod_ptr = ctx.analysis.imports.get(inner_id.name)
                                if mod_ptr != null:
                                    let target_module = read(mod_ptr)
                                    match lowering.find_imported_analysis(ctx, target_module):
                                        Option.some as imported:
                                            match lowering.find_imported_variant_arm(imported.value, ma.member_name):
                                                Option.some as var_name:
                                                    let var_ty = types.imported_type(
                                                        module_name = target_module,
                                                        name = var_name.value,
                                                        args = span[types.Type]()
                                                    )
                                                    return lowering.alloc_expr(ir.Expr.expr_variant_literal(
                                                        ty = var_ty,
                                                        arm_name = ma.member_name,
                                                        fields = lowering.collect_variant_literal_fields(
                                                            ctx,
                                                            args,
                                                            var_ty,
                                                            ma.member_name
                                                        ),
                                                    ))
                                                Option.none:
                                                    pass
                                            # If ma.member_name is a static method of a struct
                                            # in the imported module (e.g.
                                            # `sess.Config.default(payload_size)`), resolve
                                            # it against the imported module so struct name
                                            # collisions across modules (e.g. Config in both
                                            # session and channel) pick the correct module.
                                            let inner_recv_ty = types.imported_type(
                                                module_name = target_module,
                                                name = inner_ma.member_name,
                                                args = span[types.Type]()
                                            )
                                            match lowering.resolve_method_info_imported(
                                                ctx,
                                                inner_recv_ty,
                                                method_name = ma.member_name,
                                                import_module = target_module
                                            ):
                                                Option.some as smi:
                                                    if smi.value.method_kind == ast.MethodKind.mk_static:
                                                        return lowering.lower_static_call_args(ctx, smi.value, args)
                                                Option.none:
                                                    pass
                                        Option.none:
                                            pass
                            _:
                                pass
                    _:
                        pass
                return lower_member_dispatch(ctx, callee, args, call_ep)
            _:
                fatal(c"lowering: lower_member_call called with a non-member callee")


public function lower_member_dispatch(
    ctx: ref[lowering.LoweringContext],
    callee: ptr[ast.Expr],
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    unsafe:
        match read(callee):
            ast.Expr.expr_member_access as ma:
                # Method call: receiver.method(args).  Resolve the method from the
                # receiver's type and lower to a direct C function call.
                let recv_ty = lowering.method_receiver_type(ctx, ma.receiver)
                # Builtin `array[T, N].as_span()` → span aggregate literal
                # `{ data = &arr[0], len = N }`.  Intercept before method
                # resolution so it does not fall to the `<module>_mt_as_span`
                # fallback (mirrors Ruby's :array_as_span lowering).
                if lowering.is_array_type(recv_ty) and ma.member_name == "as_span" and args.len == 0:
                    return control_flow.lower_array_as_span(ctx, ma.receiver, recv_ty)
                # Builtin `simd[E, N].with(lane, value)` — copy the vector with
                # one lane replaced (GCC statement expression).
                if types.is_simd_type(recv_ty) and ma.member_name == "with":
                    return lowering.lower_simd_with_call(ctx, ma.receiver, recv_ty, args)
                # Builtin `.with(x = val, ...)` — aggregate copy with specified
                # fields replaced, mirroring Ruby's :struct_with lowering.
                if ma.member_name == "with":
                    return lowering.lower_with_call(ctx, ma.receiver, recv_ty, args)
                # Event builtin methods: must be checked before resolve_method_info
                # because they ARE registered in method_sigs for sema validation.
                if lowering.is_event_type(ctx, recv_ty):
                    let recv_ir = lowering.lower_expr(ctx, ma.receiver)
                    return events_mod.lower_event_method(ctx, recv_ir, recv_ty, ma.member_name, args, call_ep)
                match lowering.try_generic_method_call(ctx, recv_ty, ma.member_name, ma.receiver, args, call_ep):
                    Option.some as gen_call:
                        return gen_call.value
                    Option.none:
                        pass
                match lowering.resolve_method_info(ctx, recv_ty, ma.member_name):
                    Option.some as mi:
                        return lowering.lower_method_resolved(ctx, mi.value, ma.receiver, args, call_ep)
                    Option.none:
                        pass
                # atomic[T] builtin methods: lower to __atomic_* compiler builtins.
                if lowering.is_atomic_type(recv_ty):
                    let recv_ir = lowering.lower_expr(ctx, ma.receiver)
                    return lowering.lower_atomic_method(ctx, recv_ir, recv_ty, ma.member_name, args, call_ep)
                # str_buffer[N] builtin methods: lower to C helper calls.
                if lowering.is_str_buffer_type(recv_ty):
                    let recv_ir = lowering.lower_expr(ctx, ma.receiver)
                    return lowering.lower_str_buffer_method(ctx, recv_ir, recv_ty, ma.member_name, args, call_ep)
                # dyn[I] dispatch: extract data + vtable, call through function pointer.
                # The type may be ty_named("dyn") or ty_dyn(iface) — try both.
                let ts = types.type_to_string(recv_ty)
                if ts == "dyn" or lowering.is_dyn_type(recv_ty):
                    let recv_ir = lowering.lower_expr(ctx, ma.receiver)
                    return lowering.lower_dyn_method_call(ctx, recv_ir, ma.member_name, args, call_ep)
                return lower_member_field_call(ctx, callee, args, call_ep, recv_ty)
            _:
                fatal(c"lowering: lower_member_dispatch called with a non-member callee")


public function lower_member_field_call(
    ctx: ref[lowering.LoweringContext],
    callee: ptr[ast.Expr],
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr],
    recv_ty: types.Type
) -> ptr[ir.Expr]:
    unsafe:
        match read(callee):
            ast.Expr.expr_member_access as ma:
                # Fallback: treat as a direct C call with the member as callee.
                # But first, check if the member is an fn/proc struct field — if so,
                # lower as a direct field access call instead of a method call.
                var is_fn_proc_field = false
                var found_ft: types.Type = ctx.void_ty
                # A variant arm binding's payload fields are registered in
                # `arm_payload_fields` (keyed by the payload struct's C name), not
                # in a struct table, so `s.cb()` on an arm binding needs them from
                # there.
                match recv_ty:
                    types.Type.ty_variant_arm_payload:
                        match match_mod.arm_payload_field_type(ctx, recv_ty, ma.member_name):
                            Option.some as arm_ft:
                                found_ft = arm_ft.value
                            Option.none:
                                pass
                    _:
                        pass
                match lowering.concrete_field_type(ctx, recv_ty, ma.member_name):
                    Option.some as ft:
                        found_ft = ft.value
                    Option.none:
                        # Not in generic_struct_decls; try analysis.structs for
                        # non-generic (local and imported) structs.  Strip
                        # pointer/ref wrappers first so the base struct name is
                        # recovered (ptr[SleepState] → SleepState).
                        var base = recv_ty
                        if types.is_raw_pointer(base) or types.is_ref_type(base) or types.is_own_type(base):
                            base = types.pointer_element(base)
                        if types.is_nullable_type(base):
                            base = types.unwrap_nullable(base)
                        let struct_name = lowering.named_type_name(base)
                        if struct_name.is_some():
                            let sn = struct_name.unwrap()
                            var raw_fields = ctx.analysis.structs.get(sn)
                            if raw_fields == null:
                                var ai: ptr_uint = 0
                                while ai < ctx.program_analyses.len and raw_fields == null:
                                    var a: analyzer.Analysis
                                    unsafe:
                                        a = read(ctx.program_analyses.data + ai)
                                    raw_fields = a.structs.get(sn)
                                    ai += 1
                            if raw_fields != null:
                                let entries = unsafe: read(raw_fields)
                                var ei: ptr_uint = 0
                                while ei < entries.len:
                                    let entry = unsafe: read(entries.data + ei)
                                    if entry.name == ma.member_name:
                                        found_ft = entry.ty
                                        break
                                    ei += 1
                # Task[T] builtin struct fields (frame, ready, set_waiter,
                # release, take_result, cancel) are function pointers / void
                # pointers that must be accessed via struct field + indirect
                # call, not treated as methods.  `take_result` returns the
                # task's result type T; other vtable fields return void.
                #
                # In the monomorphized context, the Task may already be a
                # concrete struct like `ty_named("mt_task_int")` — detect it
                # by the `mt_task_` prefix or `ty_generic("Task", ...)`.
                var is_task = false
                var task_ret_ty = ctx.void_ty
                match recv_ty:
                    types.Type.ty_generic as tg:
                        let tg_bp = unsafe: read(tg.payload)
                        if tg_bp.name == "Task" and tg_bp.args.len >= 1:
                            is_task = true
                            unsafe:
                                task_ret_ty = read(tg_bp.args.data + 0)
                    types.Type.ty_named as tn:
                        let tn_np = unsafe: read(tn.payload)
                        if tn_np.name.starts_with("mt_task_"):
                            is_task = true
                            let gi_ptr = monomorphized.generic_instance_get(ctx, tn_np.name)
                            if gi_ptr != null:
                                let gi = unsafe: read(gi_ptr)
                                if gi.concrete_args.len >= 1:
                                    unsafe:
                                        task_ret_ty = read(gi.concrete_args.data + 0)
                    types.Type.ty_imported as im:
                        let im_bp = unsafe: read(im.payload)
                        if im_bp.name.starts_with("mt_task_"):
                            is_task = true
                            let gi_ptr = monomorphized.generic_instance_get(ctx, im_bp.name)
                            if gi_ptr != null:
                                let gi = unsafe: read(gi_ptr)
                                if gi.concrete_args.len >= 1:
                                    unsafe:
                                        task_ret_ty = read(gi.concrete_args.data + 0)
                    _:
                        pass
                if is_task and ma.member_name == "frame":
                    found_ft = ctx.ptr_void_ty
                else if is_task and async_cps.is_task_fn_field(ma.member_name):
                    # The host's `Types::Task#fields` (`types.rb:590-632`):
                    # `ready` returns bool, `take_result` returns T, every other
                    # vtable field returns void; `set_waiter` takes
                    # `(frame, waiter_frame, waiter)`.
                    var ret = ctx.void_ty
                    if ma.member_name == "ready":
                        ret = ctx.bool_ty
                    else if ma.member_name == "take_result":
                        ret = task_ret_ty
                    if ma.member_name == "set_waiter":
                        let waiter_ty = types.function_type(
                            name = "",
                            params = lowering.single_ty_span(ctx.ptr_void_ty),
                            return_type = types.alloc_type(ctx.void_ty),
                            variadic = false,
                            is_proc = false,
                            param_names = lowering.sp_str("frame")
                        )
                        var params = vec.Vec[types.Type].create()
                        params.push(ctx.ptr_void_ty)
                        params.push(ctx.ptr_void_ty)
                        params.push(waiter_ty)
                        var pnames = vec.Vec[str].create()
                        pnames.push("frame")
                        pnames.push("waiter_frame")
                        pnames.push("waiter")
                        found_ft = types.function_type(
                            name = "",
                            params = params.as_span(),
                            return_type = types.alloc_type(ctx.void_ty),
                            variadic = false,
                            is_proc = false,
                            param_names = pnames.as_span()
                        )
                    else:
                        found_ft = types.function_type(
                            name = "",
                            params = lowering.single_ty_span(ctx.ptr_void_ty),
                            return_type = types.alloc_type(ret),
                            variadic = false,
                            is_proc = false,
                            param_names = lowering.sp_str("frame")
                        )
                # A proc-typed field may be typed either as a `ty_function` with
                # `is_proc` or as the shared proc struct it resolves to, so test
                # the type rather than the variant: both must call through the
                # closure's `invoke`/`env` rather than a same-named method.
                if lowering.is_proc_type(found_ft):
                    let recv_ir = lowering.lower_expr(ctx, ma.receiver)
                    let field_expr = lowering.alloc_expr(ir.Expr.expr_member(
                        receiver = recv_ir,
                        member = ma.member_name,
                        ty = found_ft
                    ))
                    return lowering.lower_proc_field_call(ctx, field_expr, args, call_ep)
                match found_ft:
                    types.Type.ty_function:
                        let recv_ir = lowering.lower_expr(ctx, ma.receiver)
                        let field_expr = lowering.alloc_expr(ir.Expr.expr_member(
                            receiver = recv_ir,
                            member = ma.member_name,
                            ty = found_ft
                        ))
                        return lowering.lower_fn_field_call(ctx, field_expr, args, call_ep)
                    _:
                        pass
                var recv_type_name = lowering.named_type_name(recv_ty)
                if recv_type_name.is_none():
                    recv_type_name = lowering.try_spec_type_name(ma.receiver)
                let recv_name = recv_type_name else:
                    let fn_c_name = naming.qualified_member_c_name(ctx.module_name, "mt", ma.member_name)
                    var ir_args = vec.Vec[ir.Expr].create()
                    let recv_ir = lowering.lower_expr(ctx, ma.receiver)
                    unsafe:
                        ir_args.push(read(recv_ir))
                    var si: ptr_uint = 0
                    while si < args.len:
                        var arg: ast.Argument
                        unsafe:
                            arg = read(args.data + si)
                        let lowered = lowering.lower_expr(ctx, arg.arg_value)
                        unsafe:
                            ir_args.push(read(lowered))
                        si += 1
                    return lowering.alloc_expr(ir.Expr.expr_call(
                        callee = fn_c_name,
                        arguments = ir_args.as_span(),
                        ty = type_helpers.expr_type(ctx, call_ep)
                    ))
                # Method found — try method resolution with the recovered type name.
                var resolved_ty = types.named_type(name = recv_name, module_name = "", linkage_name = Option[str].none)
                match lowering.resolve_method_info(ctx, resolved_ty, ma.member_name):
                    Option.some as mi:
                        return lowering.lower_method_resolved(ctx, mi.value, ma.receiver, args, call_ep)
                    Option.none:
                        let fn_c_name = naming.qualified_member_c_name(ctx.module_name, recv_name, ma.member_name)
                        let recv_ir = lowering.lower_expr(ctx, ma.receiver)
                        var ir_args = vec.Vec[ir.Expr].create()
                        unsafe:
                            ir_args.push(read(recv_ir))
                        var si: ptr_uint = 0
                        while si < args.len:
                            var arg: ast.Argument
                            unsafe:
                                arg = read(args.data + si)
                            let lowered = lowering.lower_expr(ctx, arg.arg_value)
                            unsafe:
                                ir_args.push(read(lowered))
                            si += 1
                        return lowering.alloc_expr(ir.Expr.expr_call(
                            callee = fn_c_name,
                            arguments = ir_args.as_span(),
                            ty = type_helpers.expr_type(ctx, call_ep)
                        ))
            _:
                fatal(c"lowering: lower_member_field_call called with a non-member callee")

