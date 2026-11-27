## Function/method declaration lowering, extracted from
## lowering/lowering.mt (Wave 4.2).

import std.map as map_mod
import std.string as string
import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types
import mtc.semantic.analyzer as analyzer
import mtc.strings
import mtc.c_naming as naming

import mtc.lowering.async_cps as async_cps
import mtc.lowering.async as async_mod
import mtc.lowering.format as format
import mtc.lowering.match as match_mod
import mtc.lowering.monomorphized as monomorphized
import mtc.lowering.parallel as parallel_mod
import mtc.lowering.lowering as lowering
import mtc.lowering.driver as driver_mod
import mtc.lowering.tasks as tasks
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.utils as utils


public function lower_extending_block(
    ctx: ref[lowering.LoweringContext],
    functions: ref[vec.Vec[ir.Function]],
    type_ref_ptr: ptr[ast.TypeRef],
    methods: span[ast.Method]
) -> void:
    var type_name: str
    var bare_name: str
    unsafe:
        let type_ref = read(type_ref_ptr)
        bare_name = read(type_ref.name.parts.data + (type_ref.name.parts.len - 1))
        if type_ref.name.parts.len == 1:
            type_name = bare_name
        else:
            var buf = string.String.create()
            var bi: ptr_uint = 0
            while bi < type_ref.name.parts.len:
                if bi > 0:
                    buf.append(".")
                buf.append(read(type_ref.name.parts.data + bi))
                bi += 1
            type_name = buf.as_str()
    # Skip generic extending blocks (e.g. `extending Vec[T]:`) — their methods
    # are monomorphized by `lower_monomorphized_call` when concrete calls occur.
    if unsafe: read(type_ref_ptr).arguments.len > 0:
        return
    # An alias target attaches to the *resolved* type: `extending Color:` in
    # std.raylib (with `type Color = c.Color`) and `extending b3.Vec3:` in
    # examples.box3d.common (with `type Vec3 = c.b3Vec3` in std.box3d) both
    # declare methods on the raw C struct, which is the type a call site derives
    # from the receiver — and the type the host names the linkage after.
    var receiver_ty = lowering.extending_receiver_type(ctx.module_name, bare_name)
    match lowering.extending_receiver_target(ctx.program_analyses, ctx.analysis, type_ref_ptr):
        Option.some as resolved:
            receiver_ty = resolved.value
            match lowering.named_type_name(resolved.value):
                Option.some as resolved_name:
                    bare_name = resolved_name.value
                Option.none:
                    pass
        Option.none:
            # A nested struct target (`extending Rectangle.Edge:`): the
            # registered type carries the parent-qualified linkage name, which
            # both the method's C name and its `this` type use.
            let target_parts = unsafe: read(type_ref_ptr).name.parts
            match lowering.local_nested_type(ctx, target_parts):
                Option.some as nested:
                    receiver_ty = nested.value
                Option.none:
                    pass
    var mi: ptr_uint = 0
    while mi < methods.len:
        var m: ast.Method
        unsafe:
            m = read(methods.data + mi)
        # Generic methods are monomorphized on demand by `lower_monomorphized_call`.
        if m.type_params.len > 0:
            mi += 1
            continue
        let c_name = lowering.method_c_name_for_receiver(receiver_ty, ctx.module_name, bare_name, m.name, m.method_kind)
        # Async methods are lowered through the full CPS path, with the receiver
        # (`this`) as an implicit param — except static async methods, which have
        # no receiver.
        if m.is_async:
            var recv_opt = Option[types.Type].none
            if m.method_kind != ast.MethodKind.mk_static:
                # The parameter keeps the declared receiver type; the editable
                # pointer lives in the frame field and the C declarator (the
                # host's `param_type` vs `field_type` split).
                recv_opt = Option[types.Type].some(value = receiver_ty)
            async_cps.lower_async_fn(
                ctx,
                m.name,
                c_name,
                recv_opt,
                m.method_kind == ast.MethodKind.mk_editable,
                m.method_params,
                m.return_type,
                m.body,
                functions,
                false
            )
            mi += 1
            continue
        functions.push(lower_method(ctx, c_name, receiver_ty, m))
        mi += 1


## Lower a single method to an IR function.  The receiver (`this`) is bound as a
## local parameter (pointer for editable methods, value for plain).

function lower_method(ctx: ref[lowering.LoweringContext], c_name: str, receiver_ty: types.Type, m: ast.Method) -> ir.Function:
    ctx.locals.clear()
    ctx.counters.temp = 0
    ctx.format_state.dest_name = ""
    ctx.format_state.counter.clear()
    ctx.format_state.counter_visible = false
    ctx.format_state.cstr_backed.clear()
    var saved_current_fn = ctx.current_function_linkage
    ctx.current_function_linkage = c_name
    let sig = type_helpers.find_fn_sig(ctx, m.name)

    var ir_params = vec.Vec[ir.Param].create()
    var param_setup = vec.Vec[ir.Stmt].create()
    if m.method_kind != ast.MethodKind.mk_static:
        # A pointer-lowered receiver carries its base type with `pointer = true`;
        # the C `*` is added by the backend.  Editable methods borrow, and so do
        # sync methods whose receiver type contains array storage.  Mirrors the
        # host's `pointer_lowered_sync_method_receiver?`.
        let recv_is_ptr = lowering.receiver_by_pointer(ctx, receiver_ty, m.method_kind, m.is_async)
        ir_params.push(ir.Param(
            name = "this",
            linkage_name = utils.c_local_name("this"),
            ty = receiver_ty,
            pointer = Option[bool].some(value = recv_is_ptr)
        ))
        ctx.locals.push(lowering.LocalBinding(
            name = "this",
            c_name = utils.c_local_name("this"),
            ty = receiver_ty,
            pointer = Option[bool].some(value = recv_is_ptr)
        ))
    var pi: ptr_uint = 0
    while pi < m.method_params.len:
        var p: ast.Param
        unsafe:
            p = read(m.method_params.data + pi)
        let param_ty = type_helpers.resolve_param_type(ctx, sig, pi, p.param_type)
        let c_pname = utils.c_local_name(p.name)
        # Params are never pointer-lowered: `ptr`/`ref`/`own` types already
        # render as C pointers.  Matches the host (always `pointer: false`).
        let is_ptr = false
        let link_name = lowering.array_param_input_name(param_ty, c_pname, ref_of(param_setup))
        ir_params.push(ir.Param(
            name = p.name,
            linkage_name = link_name,
            ty = param_ty,
            pointer = Option[bool].some(value = is_ptr)
        ))
        ctx.locals.push(lowering.LocalBinding(
            name = p.name,
            c_name = c_pname,
            ty = param_ty,
            pointer = Option[bool].some(value = is_ptr)
        ))
        pi += 1

    let ret_ty = type_helpers.resolve_return_type(ctx, sig, m.return_type)
    var saved_fn_ret = ctx.current_fn_return_type
    ctx.current_fn_return_type = ret_ty
    let body_stmts = lowering.prepend_param_setup(ref_of(param_setup), lowering.lower_function_body(ctx, m.body))
    ctx.current_fn_return_type = saved_fn_ret
    ctx.current_function_linkage = saved_current_fn

    return ir.Function(
        source_module = Option[str].none,
        name = m.name,
        linkage_name = c_name,
        params = ir_params.as_span(),
        return_type = ret_ty,
        body = body_stmts,
        entry_point = false, public_export = false,
        method_receiver_param = m.method_kind != ast.MethodKind.mk_static,
    )


## A single-element `span[types.Type]` convenience helper.

public function lower_function(
    ctx: ref[lowering.LoweringContext],
    name: str,
    params: span[ast.Param],
    return_type: ptr[ast.TypeRef]?,
    body: ptr[ast.Stmt]?,
    is_async: bool,
    public_export: bool
) -> ir.Function:
    ctx.locals.clear()
    ctx.counters.temp = 0
    ctx.format_state.dest_name = ""
    ctx.format_state.counter.clear()
    ctx.format_state.counter_visible = false
    ctx.format_state.cstr_backed.clear()
    var saved_current_fn = ctx.current_function_linkage
    ctx.current_function_linkage = naming.qualified_c_name(ctx.module_name, name)
    let sig = type_helpers.find_fn_sig(ctx, name)

    var ir_params = vec.Vec[ir.Param].create()
    var param_setup = vec.Vec[ir.Stmt].create()
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        let param_ty = type_helpers.resolve_param_type(ctx, sig, pi, p.param_type)
        let c_name = utils.c_local_name(p.name)
        let f_ptr = false
        let link_name = lowering.array_param_input_name(param_ty, c_name, ref_of(param_setup))
        ir_params.push(ir.Param(
            name = p.name,
            linkage_name = link_name,
            ty = param_ty,
            pointer = Option[bool].some(value = f_ptr)
        ))
        ctx.locals.push(lowering.LocalBinding(
            name = p.name,
            c_name = c_name,
            ty = param_ty,
            pointer = Option[bool].some(value = f_ptr)
        ))
        pi += 1

    var ret_ty = type_helpers.resolve_return_type(ctx, sig, return_type)
    if is_async:
        ret_ty = tasks.make_task_type(ret_ty)
    ctx.inside_async = is_async
    var saved_fn_ret = ctx.current_fn_return_type
    ctx.current_fn_return_type = ret_ty
    let body_stmts = lowering.prepend_param_setup(ref_of(param_setup), lowering.lower_function_body(ctx, body))
    ctx.current_fn_return_type = saved_fn_ret
    ctx.inside_async = false
    ctx.current_function_linkage = saved_current_fn

    return ir.Function(
        source_module = Option[str].none,
        name = name,
        linkage_name = naming.qualified_c_name(ctx.module_name, name),
        params = ir_params.as_span(),
        return_type = ret_ty,
        body = body_stmts,
        entry_point = false,
        public_export = public_export,
        method_receiver_param = false,
    )


## Synthesize the C entry point `int main(...)` that calls the user's root
## `main`.  Supports a no-parameter `main` (`int main(void)`) and a single
## `span[str]` parameter (`int main(int argc, char** argv)` with the argv →
## `span[str]` bridge), each returning `int` or `void`.  Mirrors Ruby's
## driver_mod.build_root_main_entrypoint(:none / :span_str signatures).

public function lower_specialized_method(
    ctx: ref[lowering.LoweringContext],
    method_c: str,
    info: lowering.GenericReceiver,
    gm: lowering.GenericMethodMatch,
    sub: ref[map_mod.Map[str, types.Type]],
    body_validated: bool
) -> ir.Function:
    let m = gm.method
    ctx.locals.clear()
    ctx.counters.temp = 0
    ctx.format_state.dest_name = ""
    ctx.format_state.counter.clear()
    ctx.format_state.counter_visible = false
    ctx.format_state.cstr_backed.clear()
    var saved_current_fn = ctx.current_function_linkage
    ctx.current_function_linkage = method_c
    # Nested instances are analyzer-created only when the body was validated
    # (see `lower_specialized_function`).
    var saved_pre_instantiated = ctx.pre_instantiated_context
    ctx.pre_instantiated_context = body_validated

    # Build the receiver struct type using only the struct-level type args
    # (the first N concrete args where N = struct_param_names.len).  Method-level
    # type params extend concrete_args but are NOT part of the receiver.
    var struct_args = vec.Vec[types.Type].create()
    var si: ptr_uint = 0
    while si < gm.struct_param_names.len and si < info.concrete_args.len:
        unsafe:
            struct_args.push(read(info.concrete_args.data + si))
        si += 1

    # Builtin generics (ptr/span/array/...) are never module-qualified types:
    # keep the receiver as a plain generic instance so `ptr[int]` renders as
    # `int32_t*` rather than a nonexistent `std_mem_ptr_ptr_int` struct.
    var recv_struct_ty: types.Type
    if lowering.is_builtin_pointer_generic(info.owner_name):
        recv_struct_ty = types.generic_type(name = info.owner_name, args = struct_args.as_span())
    else:
        recv_struct_ty = lowering.qualify_type(
            ctx,
            types.imported_type(
                module_name = if info.owner_module.len > 0: info.owner_module else: lowering.struct_defining_module_for_type(
                    ctx,
                    info.owner_name
                ),
                name = info.owner_name,
                args = struct_args.as_span()
            )
        )

    var ir_params = vec.Vec[ir.Param].create()
    var param_setup = vec.Vec[ir.Stmt].create()
    if m.method_kind != ast.MethodKind.mk_static:
        let recv_is_ptr = lowering.receiver_by_pointer(ctx, recv_struct_ty, m.method_kind, m.is_async)
        ir_params.push(ir.Param(
            name = "this",
            linkage_name = utils.c_local_name("this"),
            ty = recv_struct_ty,
            pointer = Option[bool].some(value = recv_is_ptr)
        ))
        ctx.locals.push(lowering.LocalBinding(
            name = "this",
            c_name = utils.c_local_name("this"),
            ty = recv_struct_ty,
            pointer = Option[bool].some(value = recv_is_ptr)
        ))

    var pi: ptr_uint = 0
    while pi < m.method_params.len:
        var p: ast.Param
        unsafe:
            p = read(m.method_params.data + pi)
        let p_ty = lowering.qualify_type(
            ctx,
            monomorphized.substitute_type_params(ctx, lowering.resolve_field_type_ref(ctx, p.param_type), sub)
        )
        let c_pname = utils.c_local_name(p.name)
        let is_ptr = false
        let link_name = lowering.array_param_input_name(p_ty, c_pname, ref_of(param_setup))
        ir_params.push(ir.Param(
            name = p.name,
            linkage_name = link_name,
            ty = p_ty,
            pointer = Option[bool].some(value = is_ptr)
        ))
        ctx.locals.push(lowering.LocalBinding(
            name = p.name,
            c_name = c_pname,
            ty = p_ty,
            pointer = Option[bool].some(value = is_ptr)
        ))
        pi += 1

    var ret_ty = ctx.void_ty
    let return_ref = m.return_type
    if return_ref != null:
        let resolved_ret = lowering.resolve_field_type_ref(ctx, unsafe: read(return_ref))
        ret_ty = lowering.qualify_type(ctx, monomorphized.substitute_type_params(ctx, resolved_ret, sub))

    # Register the method's return type before lowering its body so a
    # recursive self-call resolves its type from here rather than the
    # analyzer's unsubstituted generic-body record.
    ctx.function_returns.set(method_c, ret_ty)
    var saved_sub = ctx.type_substitution
    ctx.type_substitution = read(sub)
    var saved_fn_ret = ctx.current_fn_return_type
    ctx.current_fn_return_type = ret_ty
    let body_ir = lowering.prepend_param_setup(ref_of(param_setup), lowering.lower_function_body(ctx, m.body))
    ctx.current_fn_return_type = saved_fn_ret
    ctx.type_substitution = saved_sub
    ctx.current_function_linkage = saved_current_fn
    ctx.pre_instantiated_context = saved_pre_instantiated

    return ir.Function(
        source_module = Option[str].none,
        # Host parity: the instance's `name` is the method name; the linkage
        # name carries the receiver and type-argument suffix.
        name = m.name,
        linkage_name = method_c,
        params = ir_params.as_span(),
        return_type = ret_ty,
        body = body_ir,
        entry_point = false, public_export = false,
        method_receiver_param = m.method_kind != ast.MethodKind.mk_static,
    )


## Wrap a function reference in a proc struct with a synthetic invoke function
## that calls the original function, plus no-op release/retain.

public function lower_monomorphized_method(
    ctx: ref[lowering.LoweringContext],
    info: lowering.GenericReceiver,
    gm: lowering.GenericMethodMatch,
    method_name: str,
    receiver: ptr[ast.Expr],
    args: span[ast.Argument]
) -> ptr[ir.Expr]:
    # For the struct prefix in the C name, use the struct's defining module
    # (which may differ from the extending-block module, e.g. `Writer` is
    # defined in `std_binary` but extended by `std_serialize`).  The receiver
    # type's own module (`info.owner_module`) is authoritative when known;
    # otherwise fall back to a by-name scan of the program analyses, which is
    # ambiguous when several modules declare a struct with the same simple name.
    var struct_module = info.owner_module
    if struct_module.len == 0:
        struct_module = gm.owner_module
        var sai: ptr_uint = 0
        while sai < ctx.program_analyses.len:
            var sa: analyzer.Analysis
            unsafe:
                sa = read(ctx.program_analyses.data + sai)
            if lowering.struct_in_source(sa, info.owner_name) or sa.structs.contains(info.owner_name):
                struct_module = sa.module_name
                break
            sai += 1
    let method_c = lowering.monomorphized_method_c_name(struct_module, info, gm, method_name)

    if not ctx.caches.specializations.contains(method_c) and not ctx.spec_in_progress.contains(method_c):
        lowering.ensure_monomorphized_method(ctx, method_c, info, gm, ctx.pre_instantiated_context)
    else:
        lowering.note_validated_spec_reach(ctx, method_c)

    var ret_ty = ctx.void_ty
    let cached = ctx.caches.specializations.get(method_c)
    if cached != null:
        ret_ty = unsafe: read(cached).return_type
    else:
        # A recursive self-call reaches here while the specialization is still
        # being lowered, so only the pre-registered return type is available.
        let fr = ctx.function_returns.get(method_c)
        if fr != null:
            ret_ty = unsafe: read(fr)

    let recv = lowering.lower_expr(ctx, receiver)
    let ordered_args = lowering.expand_default_args(gm.method.method_params, args)
    var ir_args = vec.Vec[ir.Expr].create()
    var param_offset: ptr_uint = 0
    if lowering.is_builtin_pointer_generic(info.owner_name) and gm.method.method_kind != ast.MethodKind.mk_static:
        # The declared receiver is itself the builtin generic (`extending
        # ptr[T]`): pass it through (address-of for editable) rather than
        # auto-dereferencing as a value receiver.
        var ptr_recv = recv
        if gm.method.method_kind == ast.MethodKind.mk_editable and not lowering.ir_expr_is_pointer(recv):
            ptr_recv = lowering.alloc_expr(ir.Expr.expr_address_of(
                expression = recv,
                ty = types.generic_type(name = "ptr", args = lowering.sp_type(lowering.ir_expr_type(recv))),
            ))
        unsafe:
            ir_args.push(read(ptr_recv))
        param_offset = 1
    else:
        match lowering.build_receiver_arg(ctx, recv, gm.method.method_kind, gm.method.is_async):
            Option.some as recv_arg:
                unsafe:
                    ir_args.push(read(recv_arg.value))
                param_offset = 1
            Option.none:
                pass
    var i: ptr_uint = 0
    while i < ordered_args.len:
        var arg: ast.Argument
        unsafe:
            arg = read(ordered_args.data + i)
        var lowered = lowering.lower_expr(ctx, arg.arg_value)
        lowered = lowering.coerce_arg_to_param(cached, param_offset + i, lowered)
        lowered = lowering.coerce_monomorphized_arg_to_proc(ctx, cached, param_offset + i, lowered, arg.arg_value)
        lowered = lowering.coerce_literal_to_mono_param(ctx, cached, param_offset + i, arg.arg_value, lowered)
        unsafe:
            ir_args.push(read(lowered))
        i += 1
    return lowering.alloc_expr(ir.Expr.expr_call(callee = method_c, arguments = ir_args.as_span(), ty = ret_ty))


## Re-type a bare literal argument against the specialized function's parameter
## type — the monomorphized path's `coerce_literal_to_param_type` (the params
## live on the IR function, not an `FnSig`), so `a.m(2, 3)` against
## `ptr_uint` parameters emits `ptr_uint` literals.
