## Function/method declaration lowering, extracted from
## lowering/lowering.mt (Wave 4.2).

import std.string as string
import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types
import mtc.strings
import mtc.c_naming as naming

import mtc.lowering.async_cps as async_cps
import mtc.lowering.async as async_mod
import mtc.lowering.format as format
import mtc.lowering.match as match_mod
import mtc.lowering.monomorphized as monomorphized
import mtc.lowering.parallel as parallel_mod
import mtc.lowering.lowering as lowering
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
## lowering.build_root_main_entrypoint(:none / :span_str signatures).
