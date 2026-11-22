## Async CPS lowering — frame fields, await suspension/resume, async
## completion, and the synthesized async-main entrypoint.  Extracted from
## lowering/lowering.mt.  The program-scoped match-binding counter and its
## prepass stay in lowering.mt: cross-module mutable vars are not supported.

import std.vec as vec
import std.map as map_mod
import std.str
import std.string as string
import std.mem.heap as heap_mod

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.c_naming as naming

import mtc.lowering.async as async_mod
import mtc.lowering.format as format
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.lowering as lowering
import mtc.lowering.monomorphized as monomorphized
import mtc.lowering.tasks as tasks
import mtc.strings


## True when the arm carries a payload (the host's `scrutinee_type.has_payload?`,
## `fields && !fields.empty?`): the gate for the async match-binding counter
## advance and the (unused) field registration.
public function arm_has_payload(info: lowering.VariantInfo, arm_name: str) -> bool:
    match lowering.variant_arm_info(info, arm_name):
        Option.some as ai:
            return ai.value.field_names.len > 0
        Option.none:
            return false


## The host's param `pointer` value (`analysis.rb:20`):
## `receiver_type && receiver_editable && name == "this"` — nil for a plain
## function's params, `true` for an editable receiver (`this`) and `false` for a
## method's other params.  Used by the async ctor's params and its param-copy
## value Names (`frame_builder.rb:291,296`).
function async_param_pointer(receiver_ty_opt: Option[types.Type], receiver_editable: bool, pname: str) -> Option[bool]:
    match receiver_ty_opt:
        Option.some:
            return Option[bool].some(value = receiver_editable and pname == "this")
        Option.none:
            return Option[bool].none


## The frame-field type of an async parameter.  An editable method's `this`
## keeps its declared type as the *parameter* type and stores a pointer in the
## frame (`field_type = pointer ? pointer_to(param_type) : param_type`, the
## host's `analysis.rb:19-29`), so the constructor param renders `T *this`
## while the frame field is `T*`.
function async_param_field_type(receiver_ty_opt: Option[types.Type], receiver_editable: bool, pname: str, pty: types.Type) -> types.Type:
    match async_param_pointer(receiver_ty_opt, receiver_editable, pname):
        Option.some as ptr_flag:
            if ptr_flag.value:
                return types.Type.ty_generic(name = "ptr", args = lowering.single_ty_span(pty))
        Option.none:
            pass
    return pty


## The host's `async_info[:wake_type]` / the Task struct's `wake_fn`:
## `fn(frame: ptr[void]) -> void` (`types.rb:596-600`).
function async_wake_fn_type(ctx: ref[lowering.LoweringContext]) -> types.Type:
    return types.function_type(name = "", params = lowering.single_ty_span(ctx.ptr_void_ty), return_type = types.alloc_type(ctx.void_ty), variadic = false, is_proc = false, param_names = lowering.sp_str("frame"))


## The type of a `Types::Task` field (`types.rb:601-632`): `frame`, `ready`,
## `set_waiter`, `release`, `take_result` or `cancel`.  Anything else falls back
## to the frame pointer (the unknown field's C shape).
function task_field_type(ctx: ref[lowering.LoweringContext], result_ty: types.Type, field: str) -> types.Type:
    let void_ptr = ctx.ptr_void_ty
    if field == "ready":
        return types.function_type(name = "", params = lowering.single_ty_span(void_ptr), return_type = types.alloc_type(ctx.bool_ty), variadic = false, is_proc = false, param_names = lowering.sp_str("frame"))
    if field == "take_result":
        return types.function_type(name = "", params = lowering.single_ty_span(void_ptr), return_type = types.alloc_type(result_ty), variadic = false, is_proc = false, param_names = lowering.sp_str("frame"))
    if field == "set_waiter":
        var ptypes = vec.Vec[types.Type].create()
        ptypes.push(void_ptr)
        ptypes.push(void_ptr)
        ptypes.push(async_wake_fn_type(ctx))
        var pnames = vec.Vec[str].create()
        pnames.push("frame")
        pnames.push("waiter_frame")
        pnames.push("waiter")
        return types.function_type(name = "", params = ptypes.as_span(), return_type = types.alloc_type(ctx.void_ty), variadic = false, is_proc = false, param_names = pnames.as_span())
    if field == "release" or field == "cancel":
        return types.function_type(name = "", params = lowering.single_ty_span(void_ptr), return_type = types.alloc_type(ctx.void_ty), variadic = false, is_proc = false, param_names = lowering.sp_str("frame"))
    return void_ptr


## The `frame->result` store target (the host's
## `async_frame_field_expression(frame_expr, "result", …)`).
public function async_result_target(ctx: ref[lowering.LoweringContext], res_ty: types.Type) -> ptr[ir.Expr]:
    let frame_exp = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = ctx.async_frame_ptr_ty, pointer = Option[bool].some(value = false)))
    return lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "result", ty = res_ty))


## The host's `async_complete_statements` (`async_lowering.rb:1271`): store the
## result (when one is given), mark the frame ready, wake a registered waiter and
## return.  Emitted inline at every `return` and `?`-failure inside an async
## resume body (the self's replacement for the old completion label).
public function async_complete_statements(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], res_ty: types.Type, result_value: Option[ptr[ir.Expr]]) -> void:
    let bool_ty = ctx.bool_ty
    let void_ptr = ctx.ptr_void_ty
    let frame_exp = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = ctx.async_frame_ptr_ty, pointer = Option[bool].some(value = false)))
    match result_value:
        Option.some as rv:
            if not tasks.is_void_type_lowered(res_ty):
                output.push(ir.Stmt.stmt_assignment(
                    target = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "result", ty = res_ty)),
                    operator = "=",
                    value = rv.value,
                ))
        Option.none:
            pass
    output.push(ir.Stmt.stmt_assignment(
        target = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "ready", ty = bool_ty)),
        operator = "=",
        value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty)),
    ))
    let waiter_frame_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "waiter_frame", ty = void_ptr))
    var wake_body = vec.Vec[ir.Stmt].create()
    wake_body.push(ir.Stmt.stmt_local(name = "waiter_frame", linkage_name = "__mt_waiter_frame", ty = void_ptr, value = waiter_frame_field, line = 0, source_path = ""))
    wake_body.push(ir.Stmt.stmt_assignment(target = waiter_frame_field, operator = "=", value = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr))))
    wake_body.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call_indirect(
        callee = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "waiter", ty = async_wake_fn_type(ctx))),
        arguments = lowering.single_expr_span(lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_waiter_frame", ty = void_ptr, pointer = Option[bool].some(value = false)))),
        ty = ctx.void_ty,
    )), line = 0, source_path = ""))
    wake_body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    let has_waiter = lowering.alloc_expr(ir.Expr.expr_binary(
        operator = "!=",
        left = waiter_frame_field,
        right = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr)),
        ty = bool_ty,
    ))
    output.push(ir.Stmt.stmt_if(condition = has_waiter, then_body = wake_body.as_span(), else_body = Option[span[ir.Stmt]].none))
    output.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))


## True when a lowered statement sequence always transfers control — the IR-level
## mirror of the host's `cfg_block_always_terminates?` (used to decide whether an
## async resume needs a trailing completion for a void result; structured like
## `c_backend.body_terminates`).
function async_block_terminates(stmts: span[ir.Stmt]) -> bool:
    if stmts.len == 0:
        return false
    unsafe:
        return async_stmt_terminates(stmts.data + (stmts.len - 1))


function async_stmt_terminates(sp: ptr[ir.Stmt]) -> bool:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_return:
                return true
            ir.Stmt.stmt_break:
                return true
            ir.Stmt.stmt_continue:
                return true
            ir.Stmt.stmt_goto:
                return true
            ir.Stmt.stmt_block as blk:
                return async_block_terminates(blk.body)
            ir.Stmt.stmt_if as iff:
                match iff.else_body:
                    Option.some as eb:
                        return async_block_terminates(iff.then_body) and async_block_terminates(eb.value)
                    Option.none:
                        return false
            _:
                return false


## Lower an async function: generate frame struct, resume fn, constructor fn,
## and vtable helpers.  Push into the output structs/functions collections.
## Supports both no-await (single-state) and full CPS (state-machine) paths.
public function lower_async_fn(ctx: ref[lowering.LoweringContext], name: str, link_base: str, receiver_ty_opt: Option[types.Type], receiver_editable: bool, params: span[ast.Param], return_type: ptr[ast.TypeRef]?, body: ptr[ast.Stmt]?, functions: ref[vec.Vec[ir.Function]], synthetic_ctor: bool) -> void:
    # Function-level state starts fresh (the host's per-function env): the
    # fresh-temp counter, format destination and cstr metadata.
    ctx.locals.clear()
    ctx.temp_counter = 0
    ctx.fmt_dest_name = ""
    ctx.fmt_counter.clear()
    ctx.fmt_counter_visible = false
    ctx.cstr_backed_names.clear()
    var saved_current_fn = ctx.current_function_linkage
    ctx.current_function_linkage = link_base
    # Reset async CPS state so a no-await function (or the next function) never
    # inherits a previous has-await function's frame state.
    ctx.async_cps_active = false
    ctx.async_completion_active = false
    ctx.async_await_counter = 0
    ctx.async_tmp_counter = 0
    ctx.async_local_fields = vec.Vec[ir.Field].create()
    ctx.async_await_fields = vec.Vec[ir.Field].create()
    ctx.async_local_seen = map_mod.Map[str, bool].create()
    ctx.async_format_str_fields = vec.Vec[str].create()
    let sig = type_helpers.find_fn_sig(ctx, name)
    let res_ty = type_helpers.resolve_return_type(ctx, sig, return_type)
    let bool_ty = ctx.bool_ty
    let int_ty = types.primitive("int")
    let void_t = ctx.void_ty
    let is_void_ret = tasks.is_void_type_lowered(res_ty)
    # `link_base` is the constructor's C linkage (e.g. `<mod>_main`, or a method's
    # `<mod>_Type_method`); the frame/resume names derive from it with the
    # host's double underscore (`#{constructor_linkage_name}__frame`,
    # `...__resume`; `functions.rb:199-200`).
    let frame_c = strings.join_two(link_base, "__frame")
    let resume_c = strings.join_two(link_base, "__resume")
    let task_ty = tasks.make_task_type(res_ty)
    let has_await = async_mod.body_has_await(body)
    # The host analyzes the normalized body before lowering it
    # (`analyze_async_function` → `lower_async_function_decl`); its match-binding
    # registrations are what name the frame's `local_match_binding_<N>` fields.
    lowering.async_prepass_match_bindings(ctx, body)
    # The host appends the frame struct to `@artifacts.synthetic_structs` before
    # the body's lowering (`functions.rb:210`), so a body-created struct (a proc
    # env) follows it.  The frame's fields are only known after the body, so
    # remember the insertion point and insert the frame there.
    let frame_index = ctx.pending_synthetic_structs.len()
    let ptr_ty = ptr_uint_type()
    let frame_ty = types.named_type(name = frame_c, module_name = "", linkage_name = Option[str].none)
    let frame_ptr_ty = types.Type.ty_generic(name = "ptr", args = lowering.single_ty_span(frame_ty))

    # Common vtable param: void* __mt_frame_raw
    var waiter_fn_ty = types.function_type(name = "", params = lowering.single_ty_span(ctx.ptr_void_ty), return_type = types.alloc_type(ctx.void_ty), variadic = false, is_proc = false, param_names = lowering.sp_str("frame"))
    var vparams = vec.Vec[ir.Param].create()
    vparams.push(ir.Param(name = "frame", linkage_name = "__mt_frame_raw", ty = ctx.ptr_void_ty, pointer = Option[bool].some(value = false)))
    let vparam_s = vparams.as_span()
    let raw_expr = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame_raw", ty = ctx.ptr_void_ty, pointer = Option[bool].some(value = false)))

    # Param frame-field info.  Fields are named `param_<name>` so they cannot
    # clash with control fields (`state`/`result`/…).  For an async method the
    # receiver is prepended as an implicit `this` param.
    var ctor_param_names = vec.Vec[str].create()
    var ctor_param_tys = vec.Vec[types.Type].create()
    # The frame's field types differ from the constructor's parameter types for
    # an editable receiver (pointer in the frame, value in the signature).
    var ctor_field_tys = vec.Vec[types.Type].create()
    match receiver_ty_opt:
        Option.some as rty:
            ctor_param_names.push("this")
            ctor_param_tys.push(rty.value)
            ctor_field_tys.push(async_param_field_type(receiver_ty_opt, receiver_editable, "this", rty.value))
        Option.none:
            pass
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        let p_ty = type_helpers.resolve_param_type(ctx, sig, pi, p.param_type)
        ctor_param_names.push(p.name)
        ctor_param_tys.push(p_ty)
        ctor_field_tys.push(async_param_field_type(receiver_ty_opt, receiver_editable, p.name, p_ty))
        pi += 1

    # --- resume function body ---
    let resume_body = build_async_resume_body(
        ctx, body, frame_ptr_ty, raw_expr, ctor_param_names, ctor_param_tys, receiver_ty_opt, receiver_editable,
        res_ty, is_void_ret, has_await, resume_c
    )
    let frame_exp = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = frame_ptr_ty, pointer = Option[bool].some(value = false)))
    # The host's `lower_async_function_decl` appends the resume and the vtable
    # helpers to the program-wide `@artifacts.synthetic_functions` tail (after
    # every module's functions), while the constructor stays in the declaring
    # module's list (`functions.rb:199-215`).
    ctx.pending_synthetic_functions.push(ir.Function(name = strings.join_two(name, "__resume"), linkage_name = resume_c, params = vparam_s, return_type = void_t, body = resume_body.as_span(), entry_point = false, public_export = false, method_receiver_param = false))

    # -- frame struct (base + state + result + params + spilled locals + awaits) --
    var ff = vec.Vec[ir.Field].create()
    ff.push(ir.Field(name = "ready",        ty = bool_ty))
    ff.push(ir.Field(name = "cancelled",    ty = bool_ty))
    ff.push(ir.Field(name = "waiter_frame", ty = ctx.ptr_void_ty))
    ff.push(ir.Field(name = "waiter",       ty = waiter_fn_ty))
    if has_await:
        ff.push(ir.Field(name = "state",    ty = int_ty))
    if not is_void_ret:
        ff.push(ir.Field(name = "result",   ty = res_ty))
    var pif: ptr_uint = 0
    while pif < ctor_param_names.len:
        var pfname: str
        var pfty: types.Type
        unsafe:
            pfname = read(ptr[str]<-ctor_param_names.data + pif)
            pfty = read(ptr[types.Type]<-ctor_field_tys.data + pif)
        ff.push(ir.Field(name = strings.join_two("param_", pfname), ty = pfty))
        pif += 1
    var lfi: ptr_uint = 0
    while lfi < ctx.async_local_fields.len():
        let lfp = ctx.async_local_fields.get(lfi) else:
            break
        ff.push(unsafe: read(lfp))
        lfi += 1
    var afi: ptr_uint = 0
    while afi < ctx.async_await_fields.len():
        let afp = ctx.async_await_fields.get(afi) else:
            break
        let af = unsafe: read(afp)
        var already_present = false
        var ffi: ptr_uint = 0
        while ffi < ff.len():
            let existing = ff.get(ffi) else:
                break
            if unsafe: read(existing).name == af.name:
                already_present = true
            ffi += 1
        if not already_present:
            ff.push(af)
        afi += 1
    let _inserted = ctx.pending_synthetic_structs.insert(frame_index, ir.StructDecl(name = frame_c, linkage_name = frame_c, fields = ff.as_span(), packed = false, alignment = 0, source_module = Option[str].none))

    # Shared bool exprs for vtable/constructor
    emit_async_vtable(ctx, link_base, frame_ptr_ty, frame_exp, raw_expr, vparam_s, res_ty, has_await, ctor_param_names, ctor_field_tys, receiver_ty_opt, receiver_editable)

    emit_async_constructor(ctx, name, link_base, frame_ptr_ty, res_ty, ctor_param_names, ctor_param_tys, ctor_field_tys, receiver_ty_opt, receiver_editable, synthetic_ctor, functions)
    ctx.current_function_linkage = saved_current_fn


## Build the resume function's body: frame cast, parameter bindings, and either
## the full CPS state machine or the no-await single-state path.
function build_async_resume_body(
    ctx: ref[lowering.LoweringContext],
    body: ptr[ast.Stmt]?,
    frame_ptr_ty: types.Type,
    raw_expr: ptr[ir.Expr],
    ctor_param_names: vec.Vec[str],
    ctor_param_tys: vec.Vec[types.Type],
    receiver_ty_opt: Option[types.Type],
    receiver_editable: bool,
    res_ty: types.Type,
    is_void_ret: bool,
    has_await: bool,
    resume_c: str,
) -> vec.Vec[ir.Stmt]:
    let int_ty = types.primitive("int")
    ctx.locals.clear()
    var resume_body = vec.Vec[ir.Stmt].create()
    resume_body.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = lowering.alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = raw_expr, ty = frame_ptr_ty)), line = 0, source_path = ""))
    # The pointer lives in the type, not the `Name` (the host's `frame_expr`).
    let frame_exp = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = frame_ptr_ty, pointer = Option[bool].some(value = false)))
    # Register each param as a frame-field binding so references resolve to
    # `__mt_frame->param_<name>` (surviving suspend/resume); no C-local copy.
    var pib: ptr_uint = 0
    while pib < ctor_param_names.len:
        var pname: str
        var pty: types.Type
        unsafe:
            pname = read(ptr[str]<-ctor_param_names.data + pib)
            pty = read(ptr[types.Type]<-ctor_param_tys.data + pib)
        # The binding keeps the declared parameter type; an editable receiver is
        # a pointer-flagged base-typed name (the host's env: `type:
        # param_binding.type, pointer:`), whose frame storage is `ptr[T]`.
        let binding_ptr = async_param_pointer(receiver_ty_opt, receiver_editable, pname)
        ctx.locals.push(lowering.LocalBinding(name = pname, c_name = strings.join_two("__mt_frame->param_", pname), ty = pty, pointer = binding_ptr))
        pib += 1

    if has_await:
        # Full CPS: spill locals to frame fields, split awaits into a goto state
        # machine.  `lower_function_body` reuses the normal statement lowering;
        # `ctx.async_cps_active` redirects local decls and await-valued statements
        # (see `lower_async_local` / `lower_async_await_into`), and
        # `ctx.async_completion_active` rewrites returns/`?`-failures into the
        # host's inline frame completion.
        ctx.async_cps_active = true
        ctx.async_frame_ptr_ty = frame_ptr_ty
        ctx.async_resume_c = resume_c
        ctx.async_result_ty = res_ty
        ctx.async_result_is_void = is_void_ret
        var saved_completion = ctx.async_completion_active
        ctx.async_completion_active = true
        # Fresh field vecs for this function.
        ctx.async_await_counter = 0
        ctx.async_local_fields = vec.Vec[ir.Field].create()
        ctx.async_await_fields = vec.Vec[ir.Field].create()
        ctx.async_local_seen = map_mod.Map[str, bool].create()
        ctx.async_format_str_fields = vec.Vec[str].create()
        # Create LOCAL vec vars and point to THEM (NOT to ctx fields).  The ctx
        # fields are reassigned by nested lower_async_fn calls; a LOCAL variable
        # is immune to that, so pushes through the pointer always land here.
        var my_await_fields = ctx.async_await_fields
        var my_local_fields = ctx.async_local_fields
        var my_format_str_fields = ctx.async_format_str_fields
        let saved_await_ptr = ctx.async_await_fields_ptr
        let saved_local_ptr = ctx.async_local_fields_ptr
        let saved_format_str_ptr = ctx.async_format_str_fields_ptr
        ctx.async_await_fields_ptr = ptr_of(my_await_fields)
        ctx.async_local_fields_ptr = ptr_of(my_local_fields)
        ctx.async_format_str_fields_ptr = ptr_of(my_format_str_fields)
        var saved_rt = ctx.current_fn_return_type
        ctx.current_fn_return_type = res_ty
        var saved_inside = ctx.inside_async
        ctx.inside_async = true

        var body_stmts = lowering.lower_function_body(ctx, body)
        let await_count = ctx.async_await_counter
        # Copy the accumulated fields back to ctx so the frame builder picks them
        # up (ctx fields may have been reassigned by nested lower_async_fn calls).
        ctx.async_local_fields = my_local_fields
        ctx.async_await_fields = my_await_fields
        ctx.async_format_str_fields = my_format_str_fields
        ctx.async_await_fields_ptr = saved_await_ptr
        ctx.async_local_fields_ptr = saved_local_ptr
        ctx.async_format_str_fields_ptr = saved_format_str_ptr

        ctx.async_cps_active = false
        ctx.async_completion_active = saved_completion
        ctx.current_fn_return_type = saved_rt
        ctx.inside_async = saved_inside

        # Dispatch: `switch (state) { case i: goto state_i; } return;`
        var dcases = vec.Vec[ir.SwitchCase].create()
        var ds: ptr_uint = 0
        while ds <= await_count:
            var gbody = vec.Vec[ir.Stmt].create()
            gbody.push(ir.Stmt.stmt_goto(label = async_state_label(resume_c, int<-ds)))
            dcases.push(ir.SwitchCase(is_default = false, value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-ds, ty = int_ty)), body = gbody.as_span()))
            ds += 1
        resume_body.push(ir.Stmt.stmt_switch(expression = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "state", ty = int_ty)), cases = dcases.as_span(), exhaustive = false))
        resume_body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
        resume_body.push(ir.Stmt.stmt_label(name = async_state_label(resume_c, 0)))
        var bci: ptr_uint = 0
        while bci < body_stmts.len:
            resume_body.push(unsafe: read(body_stmts.data + bci))
            bci += 1
        # A void result whose body can fall through completes the frame at the
        # end (the host's `cfg_block_always_terminates?` guard); every return
        # already completed it inline.
        if is_void_ret and not async_block_terminates(body_stmts):
            async_complete_statements(ctx, ref_of(resume_body), res_ty, Option[ptr[ir.Expr]].none)
    else:
        # No awaits: single-state body.  Returns complete the frame inline (the
        # host's `lower_async_non_await_statements` + `async_complete_statements`).
        # The host's async analysis still records every local declaration's
        # `local_<name>` frame field (the body lowers plain locals, so the field
        # is dead, but the frame carries it).
        var noawait_locals = ctx.async_local_fields
        let saved_nf_ptr = ctx.async_local_fields_ptr
        ctx.async_local_fields_ptr = ptr_of(noawait_locals)
        async_register_normalized_body_fields(ctx, body)
        ctx.async_local_fields = noawait_locals
        ctx.async_local_fields_ptr = saved_nf_ptr
        ctx.async_frame_ptr_ty = frame_ptr_ty
        ctx.async_result_ty = res_ty
        ctx.async_result_is_void = is_void_ret
        ctx.async_completion_active = true
        var saved_rt = ctx.current_fn_return_type
        ctx.current_fn_return_type = res_ty
        var saved_inside = ctx.inside_async
        ctx.inside_async = true
        var body_ir = lowering.lower_function_body(ctx, body)
        ctx.async_completion_active = false
        var bi: ptr_uint = 0
        while bi < body_ir.len:
            resume_body.push(unsafe: read(body_ir.data + bi))
            bi += 1
        if is_void_ret and not async_block_terminates(body_ir):
            async_complete_statements(ctx, ref_of(resume_body), res_ty, Option[ptr[ir.Expr]].none)
        ctx.current_fn_return_type = saved_rt
        ctx.inside_async = saved_inside
    return resume_body


function emit_async_vtable(ctx: ref[lowering.LoweringContext], link_base: str, frame_ptr_ty: types.Type, frame_exp: ptr[ir.Expr], raw_expr: ptr[ir.Expr], vparam_s: span[ir.Param], res_ty: types.Type, has_await: bool, ctor_param_names: vec.Vec[str], ctor_field_tys: vec.Vec[types.Type], receiver_ty_opt: Option[types.Type], receiver_editable: bool) -> void:
    let bool_ty = ctx.bool_ty
    let void_t = ctx.void_ty
    let is_void_ret = tasks.is_void_type_lowered(res_ty)
    let bool_true = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))


    # -- vtable linkage names --
    let ready_lk  = strings.join_two(link_base, "__ready")
    let waiter_lk = strings.join_two(link_base, "__set_waiter")
    let release_lk = strings.join_two(link_base, "__release")
    let take_lk   = strings.join_two(link_base, "__take_result")
    let cancel_lk = strings.join_two(link_base, "__cancel")

    # -- vtable: ready (fresh vec) --
    var vrdy = vec.Vec[ir.Stmt].create()
    vrdy.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = lowering.alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = raw_expr, ty = frame_ptr_ty)), line = 0, source_path = ""))
    vrdy.push(ir.Stmt.stmt_return(value = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "ready", ty = bool_ty)), line = 0, source_path = ""))
    ctx.pending_synthetic_functions.push(ir.Function(name = strings.join_two(ready_lk, "_fn"), linkage_name = ready_lk, params = vparam_s, return_type = bool_ty, body = vrdy.as_span(), entry_point = false, public_export = false, method_receiver_param = false))

    # -- vtable: set_waiter (fresh vec) --
    let wake_fn_ty = async_wake_fn_type(ctx)
    var vsw = vec.Vec[ir.Stmt].create()
    vsw.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = lowering.alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = raw_expr, ty = frame_ptr_ty)), line = 0, source_path = ""))
    # If already ready, call the waiter immediately (synchronous completion).
    var sw_rdy = vec.Vec[ir.Stmt].create()
    let sw_waiter_fn = lowering.alloc_expr(ir.Expr.expr_name(name = "waiter", ty = wake_fn_ty, pointer = Option[bool].some(value = false)))
    let sw_waiter_frame = lowering.alloc_expr(ir.Expr.expr_name(name = "waiter_frame", ty = ctx.ptr_void_ty, pointer = Option[bool].some(value = false)))
    sw_rdy.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call_indirect(callee = sw_waiter_fn, arguments = lowering.single_expr_span(sw_waiter_frame), ty = void_t)), line = 0, source_path = ""))
    sw_rdy.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    let sw_ready_cond = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "ready", ty = bool_ty))
    vsw.push(ir.Stmt.stmt_if(condition = sw_ready_cond, then_body = sw_rdy.as_span(), else_body = Option[span[ir.Stmt]].none))
    vsw.push(ir.Stmt.stmt_assignment(target = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "waiter_frame", ty = ctx.ptr_void_ty)), operator = "=", value = sw_waiter_frame))
    vsw.push(ir.Stmt.stmt_assignment(target = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "waiter", ty = wake_fn_ty)), operator = "=", value = sw_waiter_fn))
    vsw.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    var sw_params = vec.Vec[ir.Param].create()
    sw_params.push(ir.Param(name = "frame", linkage_name = "__mt_frame_raw", ty = ctx.ptr_void_ty, pointer = Option[bool].some(value = false)))
    sw_params.push(ir.Param(name = "waiter_frame", linkage_name = "waiter_frame", ty = ctx.ptr_void_ty, pointer = Option[bool].some(value = false)))
    sw_params.push(ir.Param(name = "waiter", linkage_name = "waiter", ty = wake_fn_ty, pointer = Option[bool].some(value = false)))
    ctx.pending_synthetic_functions.push(ir.Function(name = strings.join_two(waiter_lk, "_fn"), linkage_name = waiter_lk, params = sw_params.as_span(), return_type = void_t, body = vsw.as_span(), entry_point = false, public_export = false, method_receiver_param = false))

    # -- vtable: release (fresh vec) --
    var vrel = vec.Vec[ir.Stmt].create()
    vrel.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = lowering.alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = raw_expr, ty = frame_ptr_ty)), line = 0, source_path = ""))
    # If not yet ready, release the pending await tasks and return without
    # freeing (the host's `build_async_release_function`).
    var rel_if_body = vec.Vec[ir.Stmt].create()
    if has_await:
        var afi: ptr_uint = 0
        while afi < ctx.async_await_fields.len():
            let afp = ctx.async_await_fields.get(afi) else:
                break
            let af = unsafe: read(afp)
            let af_task = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = af.name, ty = af.ty))
            let af_frame = lowering.alloc_expr(ir.Expr.expr_member(receiver = af_task, member = "frame", ty = task_field_type(ctx, res_ty, "frame")))
            var af_release_body = vec.Vec[ir.Stmt].create()
            let af_release_fn = lowering.alloc_expr(ir.Expr.expr_member(receiver = af_task, member = "release", ty = task_field_type(ctx, res_ty, "release")))
            af_release_body.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call_indirect(callee = af_release_fn, arguments = lowering.single_expr_span(af_frame), ty = void_t)), line = 0, source_path = ""))
            rel_if_body.push(ir.Stmt.stmt_if(condition = af_frame, then_body = af_release_body.as_span(), else_body = Option[span[ir.Stmt]].none))
            afi += 1
    rel_if_body.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_async_free", arguments = lowering.single_expr_span(raw_expr), ty = void_t)), line = 0, source_path = ""))
    rel_if_body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    let not_ready = lowering.alloc_expr(ir.Expr.expr_unary(operator = "not", operand = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "ready", ty = bool_ty)), ty = bool_ty))
    vrel.push(ir.Stmt.stmt_if(condition = not_ready, then_body = rel_if_body.as_span(), else_body = Option[span[ir.Stmt]].none))
    # Proc-storing frame fields release their references before the frame is
    # freed (the host's `frame_builder.rb:455-470`: non-pointer params first,
    # then the spilled locals).
    var rpi: ptr_uint = 0
    while rpi < ctor_param_names.len:
        var rpname: str
        var rpty: types.Type
        unsafe:
            rpname = read(ptr[str]<-ctor_param_names.data + rpi)
            rpty = read(ptr[types.Type]<-ctor_field_tys.data + rpi)
        var rp_is_ptr = false
        match async_param_pointer(receiver_ty_opt, receiver_editable, rpname):
            Option.some as ap:
                rp_is_ptr = ap.value
            Option.none:
                pass
        if not rp_is_ptr and lowering.contains_proc_storage_type(ctx, rpty):
            let rp_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = strings.join_two("param_", rpname), ty = rpty))
            lowering.proc_nullable_release_stmts(ctx, rp_field, rpty, ref_of(vrel))
        rpi += 1
    var rli: ptr_uint = 0
    while rli < ctx.async_local_fields.len():
        let rlfp = ctx.async_local_fields.get(rli) else:
            break
        let rlf = unsafe: read(rlfp)
        if lowering.contains_proc_storage_type(ctx, rlf.ty):
            let rl_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = rlf.name, ty = rlf.ty))
            lowering.proc_nullable_release_stmts(ctx, rl_field, rlf.ty, ref_of(vrel))
        rli += 1
    # A dynamic format string stored in the frame is freed when the task is
    # released (`frame_builder.rb:472-481`).
    var rfsi: ptr_uint = 0
    while rfsi < ctx.async_format_str_fields.len():
        let rfsp = ctx.async_format_str_fields.get(rfsi) else:
            break
        let rf_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = unsafe: read(rfsp), ty = types.Type.ty_str))
        vrel.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_format_str_release", arguments = lowering.single_expr_span(rf_field), ty = void_t)), line = 0, source_path = ""))
        rfsi += 1
    # Pointer-lowered params are heap copies; free them before the frame
    # (`frame_builder.rb:483-490`).
    var rppi: ptr_uint = 0
    while rppi < ctor_param_names.len:
        var rpp_name: str
        var rpp_ty: types.Type
        unsafe:
            rpp_name = read(ptr[str]<-ctor_param_names.data + rppi)
            rpp_ty = read(ptr[types.Type]<-ctor_field_tys.data + rppi)
        var rpp_is_ptr = false
        match async_param_pointer(receiver_ty_opt, receiver_editable, rpp_name):
            Option.some as app:
                rpp_is_ptr = app.value
            Option.none:
                pass
        if rpp_is_ptr:
            let rpp_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = strings.join_two("param_", rpp_name), ty = rpp_ty))
            vrel.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_async_free", arguments = lowering.single_expr_span(rpp_field), ty = void_t)), line = 0, source_path = ""))
        rppi += 1
    vrel.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_async_free", arguments = lowering.single_expr_span(raw_expr), ty = void_t)), line = 0, source_path = ""))
    vrel.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    ctx.pending_synthetic_functions.push(ir.Function(name = strings.join_two(release_lk, "_fn"), linkage_name = release_lk, params = vparam_s, return_type = void_t, body = vrel.as_span(), entry_point = false, public_export = false, method_receiver_param = false))

    # -- vtable: take_result (fresh vec) --
    # The host emits this vtable entry for every async function; a void result's
    # body is a bare return (`frame_builder.rb build_async_take_result_function`),
    # and the constructor aggregate carries the field either way.
    var vtr = vec.Vec[ir.Stmt].create()
    if is_void_ret:
        vtr.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    else:
        vtr.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = lowering.alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = raw_expr, ty = frame_ptr_ty)), line = 0, source_path = ""))
        vtr.push(ir.Stmt.stmt_return(value = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "result", ty = res_ty)), line = 0, source_path = ""))
    ctx.pending_synthetic_functions.push(ir.Function(name = strings.join_two(take_lk, "_fn"), linkage_name = take_lk, params = vparam_s, return_type = res_ty, body = vtr.as_span(), entry_point = false, public_export = false, method_receiver_param = false))

    emit_async_cancel_fn(ctx, link_base, frame_ptr_ty, frame_exp, raw_expr, vparam_s, res_ty, has_await, ctor_param_names, ctor_field_tys, receiver_ty_opt, receiver_editable)


function emit_async_cancel_fn(ctx: ref[lowering.LoweringContext], link_base: str, frame_ptr_ty: types.Type, frame_exp: ptr[ir.Expr], raw_expr: ptr[ir.Expr], vparam_s: span[ir.Param], res_ty: types.Type, has_await: bool, ctor_param_names: vec.Vec[str], ctor_field_tys: vec.Vec[types.Type], receiver_ty_opt: Option[types.Type], receiver_editable: bool) -> void:
    let bool_ty = ctx.bool_ty
    let void_t = ctx.void_ty
    let bool_true = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))
    let wake_fn_ty = async_wake_fn_type(ctx)
    let cancel_lk = strings.join_two(link_base, "__cancel")
    # -- vtable: cancel (fresh vec) --
    var vcn = vec.Vec[ir.Stmt].create()
    vcn.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = lowering.alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = raw_expr, ty = frame_ptr_ty)), line = 0, source_path = ""))
    # An already-ready frame returns without cancelling anything.
    var cn_ready_body = vec.Vec[ir.Stmt].create()
    cn_ready_body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    vcn.push(ir.Stmt.stmt_if(condition = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "ready", ty = bool_ty)), then_body = cn_ready_body.as_span(), else_body = Option[span[ir.Stmt]].none))
    vcn.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_assignment(target = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "cancelled", ty = bool_ty)), operator = "=", value = bool_true)), line = 0, source_path = ""))
    if has_await:
        var cfi: ptr_uint = 0
        while cfi < ctx.async_await_fields.len():
            let cfp = ctx.async_await_fields.get(cfi) else:
                break
            let cf = unsafe: read(cfp)
            let cf_task = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = cf.name, ty = cf.ty))
            let cf_frame = lowering.alloc_expr(ir.Expr.expr_member(receiver = cf_task, member = "frame", ty = task_field_type(ctx, res_ty, "frame")))
            var cf_then = vec.Vec[ir.Stmt].create()
            var cf_cancel_body = vec.Vec[ir.Stmt].create()
            let cf_cancel_fn = lowering.alloc_expr(ir.Expr.expr_member(receiver = cf_task, member = "cancel", ty = task_field_type(ctx, res_ty, "cancel")))
            cf_cancel_body.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call_indirect(callee = cf_cancel_fn, arguments = lowering.single_expr_span(cf_frame), ty = void_t)), line = 0, source_path = ""))
            let cf_has_cancel = lowering.alloc_expr(ir.Expr.expr_member(receiver = cf_task, member = "cancel", ty = task_field_type(ctx, res_ty, "cancel")))
            cf_then.push(ir.Stmt.stmt_if(condition = cf_has_cancel, then_body = cf_cancel_body.as_span(), else_body = Option[span[ir.Stmt]].none))
            let cf_release_fn = lowering.alloc_expr(ir.Expr.expr_member(receiver = cf_task, member = "release", ty = task_field_type(ctx, res_ty, "release")))
            cf_then.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call_indirect(callee = cf_release_fn, arguments = lowering.single_expr_span(cf_frame), ty = void_t)), line = 0, source_path = ""))
            vcn.push(ir.Stmt.stmt_if(condition = cf_frame, then_body = cf_then.as_span(), else_body = Option[span[ir.Stmt]].none))
            cfi += 1
    # Proc-storing frame fields release their references on cancel too (the
    # host's `frame_builder.rb:551-564`, before the ready store).
    var cpi: ptr_uint = 0
    while cpi < ctor_param_names.len:
        var cpname: str
        var cpty: types.Type
        unsafe:
            cpname = read(ptr[str]<-ctor_param_names.data + cpi)
            cpty = read(ptr[types.Type]<-ctor_field_tys.data + cpi)
        var cp_is_ptr = false
        match async_param_pointer(receiver_ty_opt, receiver_editable, cpname):
            Option.some as ap:
                cp_is_ptr = ap.value
            Option.none:
                pass
        if not cp_is_ptr and lowering.contains_proc_storage_type(ctx, cpty):
            let cp_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = strings.join_two("param_", cpname), ty = cpty))
            lowering.proc_nullable_release_stmts(ctx, cp_field, cpty, ref_of(vcn))
        cpi += 1
    var cli: ptr_uint = 0
    while cli < ctx.async_local_fields.len():
        let clfp = ctx.async_local_fields.get(cli) else:
            break
        let clf = unsafe: read(clfp)
        if lowering.contains_proc_storage_type(ctx, clf.ty):
            let cl_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = clf.name, ty = clf.ty))
            lowering.proc_nullable_release_stmts(ctx, cl_field, clf.ty, ref_of(vcn))
        cli += 1
    # A dynamic format string stored in the frame is freed on cancel too
    # (`frame_builder.rb:566-575`).
    var cfsi: ptr_uint = 0
    while cfsi < ctx.async_format_str_fields.len():
        let cfsp = ctx.async_format_str_fields.get(cfsi) else:
            break
        let cf_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = unsafe: read(cfsp), ty = types.Type.ty_str))
        vcn.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_format_str_release", arguments = lowering.single_expr_span(cf_field), ty = void_t)), line = 0, source_path = ""))
        cfsi += 1
    # Pointer-lowered params are heap copies; cancel frees them before marking
    # the frame ready (`frame_builder.rb:577-591`).
    var cppi: ptr_uint = 0
    while cppi < ctor_param_names.len:
        var cpp_name: str
        var cpp_ty: types.Type
        unsafe:
            cpp_name = read(ptr[str]<-ctor_param_names.data + cppi)
            cpp_ty = read(ptr[types.Type]<-ctor_field_tys.data + cppi)
        var cpp_is_ptr = false
        match async_param_pointer(receiver_ty_opt, receiver_editable, cpp_name):
            Option.some as ap:
                cpp_is_ptr = ap.value
            Option.none:
                pass
        if cpp_is_ptr:
            let cpp_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = strings.join_two("param_", cpp_name), ty = cpp_ty))
            vcn.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_async_free", arguments = lowering.single_expr_span(cpp_field), ty = void_t)), line = 0, source_path = ""))
        cppi += 1
    vcn.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_assignment(target = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "ready", ty = bool_ty)), operator = "=", value = bool_true)), line = 0, source_path = ""))
    let cn_waiter_frame = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "waiter_frame", ty = ctx.ptr_void_ty))
    var cn_wake_body = vec.Vec[ir.Stmt].create()
    cn_wake_body.push(ir.Stmt.stmt_local(name = "waiter_frame", linkage_name = "__mt_waiter_frame", ty = ctx.ptr_void_ty, value = cn_waiter_frame, line = 0, source_path = ""))
    cn_wake_body.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_assignment(target = cn_waiter_frame, operator = "=", value = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = ctx.ptr_void_ty)))), line = 0, source_path = ""))
    cn_wake_body.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call_indirect(
        callee = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame->waiter", ty = wake_fn_ty, pointer = Option[bool].some(value = false))),
        arguments = lowering.single_expr_span(lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_waiter_frame", ty = ctx.ptr_void_ty, pointer = Option[bool].some(value = false)))),
        ty = void_t,
    )), line = 0, source_path = ""))
    vcn.push(ir.Stmt.stmt_if(condition = cn_waiter_frame, then_body = cn_wake_body.as_span(), else_body = Option[span[ir.Stmt]].none))
    vcn.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    ctx.pending_synthetic_functions.push(ir.Function(name = strings.join_two(cancel_lk, "_fn"), linkage_name = cancel_lk, params = vparam_s, return_type = void_t, body = vcn.as_span(), entry_point = false, public_export = false, method_receiver_param = false))


function emit_async_constructor(ctx: ref[lowering.LoweringContext], name: str, link_base: str, frame_ptr_ty: types.Type, res_ty: types.Type, ctor_param_names: vec.Vec[str], ctor_param_tys: vec.Vec[types.Type], ctor_field_tys: vec.Vec[types.Type], receiver_ty_opt: Option[types.Type], receiver_editable: bool, synthetic_ctor: bool, functions: ref[vec.Vec[ir.Function]]) -> void:
    let frame_c = strings.join_two(link_base, "__frame")
    let frame_ty = types.named_type(name = frame_c, module_name = "", linkage_name = Option[str].none)
    let resume_c = strings.join_two(link_base, "__resume")
    let task_ty = tasks.make_task_type(res_ty)
    let ptr_ty = ptr_uint_type()
    let void_t = ctx.void_ty
    let ready_lk = strings.join_two(link_base, "__ready")
    let waiter_lk = strings.join_two(link_base, "__set_waiter")
    let release_lk = strings.join_two(link_base, "__release")
    let take_lk = strings.join_two(link_base, "__take_result")
    let cancel_lk = strings.join_two(link_base, "__cancel")
    # -- constructor function --
    let size_expr = lowering.alloc_expr(ir.Expr.expr_sizeof(target_type = frame_ty, ty = ptr_ty))
    # The frame comes from the host's refcounted `mt_async_alloc`
    # (`frame_builder.rb:270-283`): one `sizeof` argument, the call typed
    # `ptr[void]`, zeroed by the allocator's calloc.
    let alloc_call = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_async_alloc", arguments = lowering.pack_single(size_expr), ty = ctx.ptr_void_ty))
    var ctor_body = vec.Vec[ir.Stmt].create()
    ctor_body.push(ir.Stmt.stmt_local(name = "__mt_frame", linkage_name = "__mt_frame", ty = frame_ptr_ty, value = lowering.alloc_expr(ir.Expr.expr_cast(target_type = frame_ptr_ty, expression = alloc_call, ty = frame_ptr_ty)), line = 0, source_path = ""))
    # The frame `Name` is not marked as a pointer — the pointer lives in the
    # type (the host's `frame_expr`, `frame_builder.rb:267`) — and the resume
    # call / aggregate carry its `ptr[void]` cast (`raw_frame_expr`).
    let cframe = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = frame_ptr_ty, pointer = Option[bool].some(value = false)))
    let raw_cframe = lowering.alloc_expr(ir.Expr.expr_cast(target_type = ctx.ptr_void_ty, expression = cframe, ty = ctx.ptr_void_ty))
    # `ready`/`cancelled`/`state` start zeroed by `mt_async_alloc`'s calloc — the
    # host's ctor stores none of them.
    # Copy constructor params to frame fields.
    var pi3: ptr_uint = 0
    while pi3 < ctor_param_names.len:
        var pname: str
        var pty: types.Type
        var fty: types.Type
        unsafe:
            let rawdata = ctor_param_names.data
            if rawdata == null:
                fatal(c"lowering: async ctor param names missing storage")
            pname = read(ptr[str]<-rawdata + pi3)
            let rawt = ctor_param_tys.data
            if rawt == null:
                fatal(c"lowering: async ctor param types missing storage")
            pty = read(ptr[types.Type]<-rawt + pi3)
            let rawf = ctor_field_tys.data
            if rawf == null:
                fatal(c"lowering: async ctor field types missing storage")
            fty = read(ptr[types.Type]<-rawf + pi3)
        # The store target is typed with the frame field; the value Name carries
        # the declared parameter type with the pointer flag (the host's
        # `param_type` vs `field_type` split).
        let field_expr = lowering.alloc_expr(ir.Expr.expr_member(receiver = cframe, member = strings.join_two("param_", pname), ty = fty))
        let arg_pointer = async_param_pointer(receiver_ty_opt, receiver_editable, pname)
        let arg_expr = lowering.alloc_expr(ir.Expr.expr_name(name = pname, ty = pty, pointer = arg_pointer))
        ctor_body.push(ir.Stmt.stmt_assignment(target = field_expr, operator = "=", value = arg_expr))
        # The frame outlives the call stack, so a proc-storing (non-pointer) param
        # is retained for it (the host's `frame_builder.rb:298-302`).
        var is_pointer_param = false
        match arg_pointer:
            Option.some as ap:
                is_pointer_param = ap.value
            Option.none:
                pass
        if not is_pointer_param and lowering.contains_proc_storage_type(ctx, pty):
            lowering.proc_contained_retain_stmts(ctx, field_expr, pty, ref_of(ctor_body))
        pi3 += 1
    ctor_body.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call(callee = resume_c, arguments = lowering.single_expr_span(raw_cframe), ty = void_t)), line = 0, source_path = ""))
    # The host's task-struct field types (`async_info[:task_type].field(...)`)
    # for the aggregate entries below — the vtable signatures with their
    # parameter names (`frame_builder.rb:313-317`).
    let ready_field_ty = task_field_type(ctx, res_ty, "ready")
    let release_field_ty = task_field_type(ctx, res_ty, "release")
    let cancel_field_ty = task_field_type(ctx, res_ty, "cancel")
    let take_field_ty = task_field_type(ctx, res_ty, "take_result")
    let set_waiter_field_ty = task_field_type(ctx, res_ty, "set_waiter")
    var tf = vec.Vec[ir.AggregateField].create()
    # The host's ctor aggregate carries no `value` field (`frame_builder.rb:
    # 308-318`): the result reaches the task through `take_result` at await time.
    tf.push(ir.AggregateField(name = "frame",       value = raw_cframe))
    tf.push(ir.AggregateField(name = "ready",       value = lowering.alloc_expr(ir.Expr.expr_name(name = ready_lk,  ty = ready_field_ty, pointer = Option[bool].some(value = false)))))
    tf.push(ir.AggregateField(name = "set_waiter",  value = lowering.alloc_expr(ir.Expr.expr_name(name = waiter_lk, ty = set_waiter_field_ty, pointer = Option[bool].some(value = false)))))
    tf.push(ir.AggregateField(name = "release",     value = lowering.alloc_expr(ir.Expr.expr_name(name = release_lk, ty = release_field_ty, pointer = Option[bool].some(value = false)))))
    tf.push(ir.AggregateField(name = "take_result", value = lowering.alloc_expr(ir.Expr.expr_name(name = take_lk, ty = take_field_ty, pointer = Option[bool].some(value = false)))))
    tf.push(ir.AggregateField(name = "cancel",      value = lowering.alloc_expr(ir.Expr.expr_name(name = cancel_lk, ty = cancel_field_ty, pointer = Option[bool].some(value = false)))))
    ctor_body.push(ir.Stmt.stmt_return(value = lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = task_ty, fields = tf.as_span())), line = 0, source_path = ""))
    # Build constructor params from the original async function params, with the
    # host's `pointer` value (`async_param_pointer`; the types already render as
    # C pointers for `ptr`/`ref`/`own`).
    var ctor_params = vec.Vec[ir.Param].create()
    var pi4: ptr_uint = 0
    while pi4 < ctor_param_names.len:
        var pname: str
        var pty: types.Type
        unsafe:
            let rawdata = ctor_param_names.data
            if rawdata == null:
                fatal(c"lowering: async ctor params missing storage")
            pname = read(ptr[str]<-rawdata + pi4)
            let rawt = ctor_param_tys.data
            if rawt == null:
                fatal(c"lowering: async ctor params missing storage")
            pty = read(ptr[types.Type]<-rawt + pi4)
        ctor_params.push(ir.Param(name = pname, linkage_name = pname, ty = pty, pointer = async_param_pointer(receiver_ty_opt, receiver_editable, pname)))
        pi4 += 1
    # The host returns the constructor into the declaring module's list, except
    # for the root `async main`, whose constructor joins the synthetic tail
    # (`functions.rb:224-240`).
    # The async constructor is a method when the function has a receiver (the
    # host's `method_receiver_param: !binding.type.receiver_type.nil?`,
    # `frame_builder.rb:329`).
    let ctor_fn = ir.Function(name = name, linkage_name = link_base, params = ctor_params.as_span(), return_type = task_ty, body = ctor_body.as_span(), entry_point = false, public_export = false, method_receiver_param = receiver_ty_opt.is_some())
    if synthetic_ctor:
        ctx.pending_synthetic_functions.push(ctor_fn)
    else:
        functions.push(ctor_fn)


## The C label for async resume state `n` (goto target in the dispatch switch).
function async_state_label(resume_c: str, n: int) -> str:
    return strings.join_three(resume_c, "_state_", int_to_str(n))


## True when an AST expression is directly an `await` (not wrapped).
public function expr_is_direct_await(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_await:
                return true
            _:
                return false


## The inner (awaited) expression of a direct `await`.
public function direct_await_inner(ep: ptr[ast.Expr]) -> ptr[ast.Expr]:
    unsafe:
        match read(ep):
            ast.Expr.expr_await as aw:
                return aw.expression
            _:
                return ep


## Register a spilled async local: add its frame field once and bind its name to
## `__mt_frame->local_<name>` so all references and writes go through the frame.
public function async_register_local_field(ctx: ref[lowering.LoweringContext], loc_name: str, field_name: str, frame_cname: str, ty: types.Type) -> void:
    async_register_unused_field(ctx, field_name, ty)
    ctx.locals.push(lowering.LocalBinding(name = loc_name, c_name = frame_cname, ty = ty, pointer = Option[bool].some(value = false)))


## Register a frame field the host's async analysis recorded but its lowering
## never references (the `local_match_binding_<N>` shape): the field joins
## `async_local_fields` after the arm body's locals, with no local binding.
public function async_register_unused_field(ctx: ref[lowering.LoweringContext], field_name: str, ty: types.Type) -> void:
    if ctx.async_local_seen.contains(field_name):
        return
    ctx.async_local_seen.set(field_name, true)
    let lfp = ctx.async_local_fields_ptr
    if lfp != null:
        unsafe: read(lfp).push(ir.Field(name = field_name, ty = ty))
    else:
        ctx.async_local_fields.push(ir.Field(name = field_name, ty = ty))


## Lower a `let`/`var` inside an async CPS body: spill to a frame field and, when
## the initializer is a direct `await`, split into suspend/resume.
## Allocate a fresh AST expression node on the heap (for the await-hoisting
## rewrite, which splices synthesized identifier nodes into the source AST).
public function alloc_ast_expr(e: ast.Expr) -> ptr[ast.Expr]:
    var p = heap_mod.must_alloc[ast.Expr](1)
    unsafe:
        read(p) = e
    return p


public function alloc_ast_stmt(s: ast.Stmt) -> ptr[ast.Stmt]:
    var p = heap_mod.must_alloc[ast.Stmt](1)
    unsafe:
        read(p) = s
    return p


## Hoist embedded `await`s out of an expression: emit each await as a direct
## suspend/resume boundary into a fresh temp frame local, and return a rewritten
## AST expression with each await replaced by an identifier referencing that
## temp.  After this, the returned expression contains no awaits, so it can be
## lowered by the normal expression machinery.  A top-level `?` is preserved (its
## operand is hoisted) so the caller can route it to `lower_propagate_let`.
public function async_hoist_awaits(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], ep: ptr[ast.Expr]) -> ptr[ast.Expr]:
    unsafe:
        match read(ep):
            ast.Expr.expr_await as aw:
                let inner = async_hoist_awaits(ctx, output, aw.expression)
                let task_ir = lowering.lower_expr(ctx, inner)
                let task_ty = normalize_awaited_task_type(lowering.ir_expr_type(task_ir))
                let result_ty = extract_task_element_type(ctx, task_ty)
                ctx.async_tmp_counter += 1
                let tmp = strings.join_two("__mt_async_tmp_", lowering.pw1_str(ctx.async_tmp_counter))
                let field_name = strings.join_two("local_", tmp)
                let frame_cname = strings.join_two("__mt_frame->", field_name)
                async_register_local_field(ctx, tmp, field_name, frame_cname, result_ty)
                # The store target is the host's `IR::Member(frame, field)`
                # (`async_frame_field_expression`), not the `__mt_frame->…` text
                # Name (which stays for reads).
                let target = lowering.alloc_expr(ir.Expr.expr_member(receiver = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = ctx.async_frame_ptr_ty, pointer = Option[bool].some(value = false))), member = field_name, ty = result_ty))
                async_emit_await(ctx, output, task_ir, task_ty, result_ty, Option[ptr[ir.Expr]].some(value = target), inner)
                return alloc_ast_expr(ast.Expr.expr_identifier(name = tmp, line = 0, column = 0))
            ast.Expr.expr_binary_op as b:
                # The host normalizer declares an and/or result temp before the
                # operand setups but numbers it after them, so capture the field
                # slot before recursing into the operands and key it by the
                # rewritten node the lowering will see.
                let is_short_circuit = b.operator == "and" or b.operator == "or"
                if is_short_circuit and ctx.async_structured_setup:
                    # Two-phase normalizer shape: keep each operand's await setup
                    # separate so the lowering can emit
                    # `[temp decl] ++ left_setup ++ IfStmt(...)` in that order.
                    let and_or_field_index = async_local_field_count(ctx)
                    var left_setup = vec.Vec[ir.Stmt].create()
                    var right_setup = vec.Vec[ir.Stmt].create()
                    let l = async_hoist_awaits(ctx, ref_of(left_setup), b.left)
                    let r = async_hoist_awaits(ctx, ref_of(right_setup), b.right)
                    let rewritten = alloc_ast_expr(ast.Expr.expr_binary_op(operator = b.operator, left = l, right = r))
                    let key = reinterpret[ptr_uint](rewritten)
                    ctx.async_and_or_field_indices.set(key, and_or_field_index)
                    ctx.async_and_or_left_setup.set(key, left_setup)
                    ctx.async_and_or_right_setup.set(key, right_setup)
                    return rewritten
                var and_or_field_index: ptr_uint = 0
                if is_short_circuit:
                    and_or_field_index = async_local_field_count(ctx)
                let l = async_hoist_awaits(ctx, output, b.left)
                let r = async_hoist_awaits(ctx, output, b.right)
                let rewritten = alloc_ast_expr(ast.Expr.expr_binary_op(operator = b.operator, left = l, right = r))
                if is_short_circuit:
                    ctx.async_and_or_field_indices.set(reinterpret[ptr_uint](rewritten), and_or_field_index)
                return rewritten
            ast.Expr.expr_unary_op as u:
                let operand = async_hoist_awaits(ctx, output, u.operand)
                return alloc_ast_expr(ast.Expr.expr_unary_op(operator = u.operator, operand = operand))
            ast.Expr.expr_call as c:
                let callee = async_hoist_awaits(ctx, output, c.callee)
                var new_args = vec.Vec[ast.Argument].create()
                var i: ptr_uint = 0
                while i < c.args.len:
                    let arg = read(c.args.data + i)
                    new_args.push(ast.Argument(arg_name = arg.arg_name, arg_value = async_hoist_awaits(ctx, output, arg.arg_value)))
                    i += 1
                return alloc_ast_expr(ast.Expr.expr_call(callee = callee, args = new_args.as_span()))
            ast.Expr.expr_member_access as ma:
                return alloc_ast_expr(ast.Expr.expr_member_access(receiver = async_hoist_awaits(ctx, output, ma.receiver), member_name = ma.member_name, line = ma.line, column = ma.column))
            ast.Expr.expr_index_access as ix:
                return alloc_ast_expr(ast.Expr.expr_index_access(receiver = async_hoist_awaits(ctx, output, ix.receiver), index = async_hoist_awaits(ctx, output, ix.index)))
            ast.Expr.expr_prefix_cast as pc:
                return alloc_ast_expr(ast.Expr.expr_prefix_cast(target_type = pc.target_type, expression = async_hoist_awaits(ctx, output, pc.expression), line = pc.line, column = pc.column))
            ast.Expr.expr_unsafe as us:
                return alloc_ast_expr(ast.Expr.expr_unsafe(expression = async_hoist_awaits(ctx, output, us.expression), line = us.line, column = us.column))
            ast.Expr.expr_if as ie:
                # The host's `normalize_async_expression` IfExpr arm: the
                # condition setup precedes the result temp, and the branch
                # setup lives inside the generated `if` that assigns the temp
                # (`async/normalization.rb:274`).
                if not async_mod.expr_has_await(ep):
                    return ep
                let cond_h = async_hoist_awaits(ctx, output, ie.condition)
                # The branches take the lower temp numbers (`tmp_1`, `tmp_2`)
                # while the result temp registers first in the frame (the
                # host's normalized LocalDecl precedes the generated `if`).
                let field_index = async_local_field_count(ctx)
                var then_setup = vec.Vec[ir.Stmt].create()
                let then_h = async_hoist_awaits(ctx, ref_of(then_setup), ie.then_expr)
                var else_setup = vec.Vec[ir.Stmt].create()
                let else_h = async_hoist_awaits(ctx, ref_of(else_setup), ie.else_expr)
                ctx.async_tmp_counter += 1
                let tmp = strings.join_two("__mt_async_tmp_", lowering.pw1_str(ctx.async_tmp_counter))
                let field_name = strings.join_two("local_", tmp)
                let frame_cname = strings.join_two("__mt_frame->", field_name)
                var result_ty = type_helpers.expr_type(ctx, ep)
                if types.is_error(result_ty):
                    result_ty = type_helpers.expr_type(ctx, ie.then_expr)
                async_register_local_field(ctx, tmp, field_name, frame_cname, result_ty)
                async_move_last_local_field_to(ctx, field_index)
                output.push(async_frame_field_assignment(ctx, field_name, result_ty, lowering.alloc_expr(ir.Expr.expr_zero_init(ty = result_ty))))
                let cond_ir = lowering.lower_expr(ctx, cond_h)
                # The host's normalized branch bodies assign an Identifier bound
                # to the frame local (`__mt_frame->local_X`, an `IR::Name`); only
                # await stores use the `IR::Member` frame-field form.
                let then_target = lowering.alloc_expr(ir.Expr.expr_name(name = frame_cname, ty = result_ty, pointer = Option[bool].some(value = false)))
                let else_target = lowering.alloc_expr(ir.Expr.expr_name(name = frame_cname, ty = result_ty, pointer = Option[bool].some(value = false)))
                then_setup.push(ir.Stmt.stmt_assignment(target = then_target, operator = "=", value = lowering.lower_expr(ctx, then_h)))
                else_setup.push(ir.Stmt.stmt_assignment(target = else_target, operator = "=", value = lowering.lower_expr(ctx, else_h)))
                output.push(ir.Stmt.stmt_if(condition = cond_ir, then_body = then_setup.as_span(), else_body = Option[span[ir.Stmt]].some(value = else_setup.as_span())))
                return alloc_ast_expr(ast.Expr.expr_identifier(name = tmp, line = 0, column = 0))
            _:
                return ep


## The frame's current local-field count (the vec the registration helpers use).
public function async_local_field_count(ctx: ref[lowering.LoweringContext]) -> ptr_uint:
    let lfp = ctx.async_local_fields_ptr
    if lfp != null:
        return unsafe: read(lfp).len()
    return ctx.async_local_fields.len()


## Move the most recently appended frame field to `index` — the host's
## normalized statement order registers an if-expression's result temp before
## the branch temps that were numbered first.
public function async_move_last_local_field_to(ctx: ref[lowering.LoweringContext], index: ptr_uint) -> void:
    let lfp = ctx.async_local_fields_ptr
    var fields: ptr[vec.Vec[ir.Field]]
    if lfp != null:
        fields = unsafe: ptr[vec.Vec[ir.Field]]<-lfp
    else:
        fields = ptr_of(ctx.async_local_fields)
    let count = unsafe: read(fields).len()
    if count <= index + 1:
        return
    let last = count - 1
    let moved = unsafe: read(fields).remove(last)
    match moved:
        Option.some as f:
            let _ok = unsafe: read(fields).insert(index, f.value)
        Option.none:
            pass


## `__mt_frame-><field> = value` — the host's `async_frame_field_expression`
## assignment target.
public function async_frame_field_assignment(ctx: ref[lowering.LoweringContext], field_name: str, field_ty: types.Type, value: ptr[ir.Expr]) -> ir.Stmt:
    let frame = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = ctx.async_frame_ptr_ty, pointer = Option[bool].some(value = false)))
    let target = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame, member = field_name, ty = field_ty))
    return ir.Stmt.stmt_assignment(target = target, operator = "=", value = value)


## One frame field collected by the no-await prepass, in normalized order.
struct AsyncFieldEntry:
    name: str
    ty: types.Type


## Register the frame fields a no-await async body contributes, in the host
## analysis' normalized order: an explicit local's field follows its
## initializer's normalizer temps, and an `and`/`or` temp (the only temp the
## plain lowering creates in an await-free body) precedes the locals of the
## branch bodies it encloses.  The lowering later creates the same temps in the
## same counter order, so its registrations dedup against these and the frame
## order matches the host's analysis walk.
public function async_register_normalized_body_fields(ctx: ref[lowering.LoweringContext], body: ptr[ast.Stmt]?) -> void:
    let b = body else:
        return
    var entries = vec.Vec[AsyncFieldEntry].create()
    # Predicted temp names start at the lowering's current counter but never
    # advance it: the lowering allocates them itself.
    var counter = ctx.async_tmp_counter
    async_collect_stmt_fields(ctx, unsafe: read(b), ref_of(entries), ref_of(counter))
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        let entry = unsafe: read(entry_ptr)
        async_register_unused_field(ctx, entry.name, entry.ty)
        i += 1
    entries.release()


## Collect a statement's normalized frame fields (see
## `async_register_normalized_body_fields`).  Assignment targets are skipped:
## the plain lowering lowers them before its statement window opens, so a
## target `and`/`or` stays inline there.
function async_collect_stmt_fields(ctx: ref[lowering.LoweringContext], stmt: ast.Stmt, sink: ref[vec.Vec[AsyncFieldEntry]], counter: ref[ptr_uint]) -> void:
    match stmt:
        ast.Stmt.stmt_block as blk:
            var i: ptr_uint = 0
            while i < blk.statements.len:
                async_collect_stmt_fields(ctx, unsafe: read(blk.statements.data + i), sink, counter)
                i += 1
        ast.Stmt.stmt_local as l:
            let val = l.value
            if val != null:
                async_collect_expr_fields(ctx, unsafe: ptr[ast.Expr]<-val, sink, counter)
            var is_destructure = false
            match l.destructure_bindings:
                Option.some:
                    is_destructure = true
                Option.none:
                    pass
            if l.name != "_" and not is_destructure:
                var storage_ty = ctx.void_ty
                if l.else_body != null:
                    if val != null:
                        storage_ty = async_local_value_type(ctx, unsafe: ptr[ast.Expr]<-val)
                else if l.stmt_type != null:
                    if val != null:
                        storage_ty = lowering.local_decl_type(ctx, l.stmt_type, unsafe: ptr[ast.Expr]<-val)
                    else:
                        storage_ty = lowering.resolve_type_ref(ctx, unsafe: ptr[ast.TypeRef]<-l.stmt_type)
                else if val != null:
                    storage_ty = async_local_value_type(ctx, unsafe: ptr[ast.Expr]<-val)
                sink.push(AsyncFieldEntry(name = strings.join_two("local_", l.name), ty = storage_ty))
            async_collect_body_fields(ctx, l.else_body, sink, counter)
        ast.Stmt.stmt_if as sif:
            var bi: ptr_uint = 0
            while bi < sif.branches.len:
                var branch: ast.IfBranch
                unsafe:
                    branch = read(sif.branches.data + bi)
                async_collect_expr_fields(ctx, branch.condition, sink, counter)
                async_collect_body_fields(ctx, branch.body, sink, counter)
                bi += 1
            async_collect_body_fields(ctx, sif.else_body, sink, counter)
        ast.Stmt.stmt_while as w:
            async_collect_expr_fields(ctx, w.condition, sink, counter)
            async_collect_body_fields(ctx, w.body, sink, counter)
        ast.Stmt.stmt_for as f:
            var fi: ptr_uint = 0
            while fi < f.iterables.len:
                async_collect_expr_fields(ctx, unsafe: f.iterables.data + fi, sink, counter)
                fi += 1
            async_collect_body_fields(ctx, f.body, sink, counter)
        ast.Stmt.stmt_match as m:
            async_collect_expr_fields(ctx, m.scrutinee, sink, counter)
            var ai: ptr_uint = 0
            while ai < m.arms.len:
                async_collect_body_fields(ctx, unsafe: read(m.arms.data + ai).body, sink, counter)
                ai += 1
        ast.Stmt.stmt_expression as ex:
            async_collect_expr_fields(ctx, ex.expression, sink, counter)
        ast.Stmt.stmt_assignment as asg:
            async_collect_expr_fields(ctx, asg.value, sink, counter)
        ast.Stmt.stmt_ret as r:
            let rv = r.value
            if rv != null:
                async_collect_expr_fields(ctx, unsafe: ptr[ast.Expr]<-rv, sink, counter)
        ast.Stmt.stmt_defer as d:
            let de = d.expression
            if de != null:
                async_collect_expr_fields(ctx, unsafe: ptr[ast.Expr]<-de, sink, counter)
            async_collect_body_fields(ctx, d.body, sink, counter)
        ast.Stmt.stmt_unsafe as u:
            async_collect_body_fields(ctx, u.body, sink, counter)
        ast.Stmt.stmt_when as wn:
            async_collect_body_fields(ctx, wn.else_body, sink, counter)
        _:
            pass


function async_collect_body_fields(ctx: ref[lowering.LoweringContext], body: ptr[ast.Stmt]?, sink: ref[vec.Vec[AsyncFieldEntry]], counter: ref[ptr_uint]) -> void:
    let b = body else:
        return
    async_collect_stmt_fields(ctx, unsafe: read(b), sink, counter)


## Collect the temps the plain lowering creates for `ep` in an await-free async
## body, in normalized emission order.  Only `and`/`or` temps exist there: the
## normalizer allocates its temp name after both operand setups but emits the
## temp declaration first, so the entry is emitted before its children's.
## Proc bodies are synchronous and contribute nothing.
function async_collect_expr_fields(ctx: ref[lowering.LoweringContext], ep: ptr[ast.Expr], sink: ref[vec.Vec[AsyncFieldEntry]], counter: ref[ptr_uint]) -> void:
    unsafe:
        match read(ep):
            ast.Expr.expr_call as c:
                async_collect_expr_fields(ctx, c.callee, sink, counter)
                var i: ptr_uint = 0
                while i < c.args.len:
                    async_collect_expr_fields(ctx, read(c.args.data + i).arg_value, sink, counter)
                    i += 1
            ast.Expr.expr_specialization as s:
                # Type arguments are type refs, not expressions — no temps.
                async_collect_expr_fields(ctx, s.callee, sink, counter)
            ast.Expr.expr_prefix_cast as pc:
                async_collect_expr_fields(ctx, pc.expression, sink, counter)
            ast.Expr.expr_unary_op as u:
                async_collect_expr_fields(ctx, u.operand, sink, counter)
            ast.Expr.expr_binary_op as b:
                if b.operator == "and" or b.operator == "or":
                    var children = vec.Vec[AsyncFieldEntry].create()
                    async_collect_expr_fields(ctx, b.left, ref_of(children), counter)
                    async_collect_expr_fields(ctx, b.right, ref_of(children), counter)
                    read(counter) = read(counter) + 1
                    let tmp = strings.join_two("__mt_async_tmp_", lowering.pw1_str(read(counter)))
                    sink.push(AsyncFieldEntry(name = strings.join_two("local_", tmp), ty = ctx.bool_ty))
                    var ci: ptr_uint = 0
                    while ci < children.len():
                        let child_ptr = children.get(ci) else:
                            break
                        sink.push(unsafe: read(child_ptr))
                        ci += 1
                    children.release()
                else:
                    async_collect_expr_fields(ctx, b.left, sink, counter)
                    async_collect_expr_fields(ctx, b.right, sink, counter)
            ast.Expr.expr_if as ie:
                async_collect_expr_fields(ctx, ie.condition, sink, counter)
                async_collect_expr_fields(ctx, ie.then_expr, sink, counter)
                async_collect_expr_fields(ctx, ie.else_expr, sink, counter)
            ast.Expr.expr_match as me:
                async_collect_expr_fields(ctx, me.scrutinee, sink, counter)
                var mi: ptr_uint = 0
                while mi < me.arms.len:
                    let arm = read(me.arms.data + mi)
                    let pat = arm.pattern
                    if pat != null:
                        async_collect_expr_fields(ctx, pat, sink, counter)
                    async_collect_expr_fields(ctx, arm.value, sink, counter)
                    mi += 1
            ast.Expr.expr_format_string as fs:
                var pi: ptr_uint = 0
                while pi < fs.parts.len:
                    match read(fs.parts.data + pi):
                        ast.FormatStringPart.fmt_expr as fe:
                            async_collect_expr_fields(ctx, fe.expression, sink, counter)
                        _:
                            pass
                    pi += 1
            ast.Expr.expr_unsafe as u:
                async_collect_expr_fields(ctx, u.expression, sink, counter)
            ast.Expr.expr_await as aw:
                # Not reachable for an await-free body; skip the temp.
                async_collect_expr_fields(ctx, aw.expression, sink, counter)
            _:
                pass


## The storage type of a no-await async local's initializer.  A call through a
## function-typed member (`task.ready(task.frame)`) records the *member's* type
## on the call node (`fn(ptr[void]) -> bool`); the call's value type is that
## function's return type, as the lowering's own call path computes it.  A
## function-returning method call keeps its recorded type.
function async_local_value_type(ctx: ref[lowering.LoweringContext], val: ptr[ast.Expr]) -> types.Type:
    unsafe:
        match read(val):
            ast.Expr.expr_call as cl:
                match read(cl.callee):
                    ast.Expr.expr_member_access:
                        match type_helpers.expr_type(ctx, val):
                            types.Type.ty_function as fnt:
                                let fnt_ft = unsafe: read(fnt.payload)
                                return unsafe: read(fnt_ft.return_type)
                            _:
                                pass
                    _:
                        pass
            _:
                pass
    return type_helpers.expr_type(ctx, val)


## The host's prepared array-call temp for a value lowered with hoisting off:
## the async statement preparers pass `materialize_array_calls: true` even when
## the destination's own type is an array (the sync statement roots exempt
## their root call instead).  `maybe_materialize_array_call` handles the windowed
## paths; this is the forced form for an already-lowered expression.
function materialize_array_call_value(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], value: ptr[ir.Expr]) -> ptr[ir.Expr]:
    let ty = lowering.ir_expr_type(value)
    if not lowering.is_array_type(ty):
        return value
    match unsafe: read(value):
        ir.Expr.expr_call:
            pass
        ir.Expr.expr_call_indirect:
            pass
        _:
            return value
    let name = lowering.fresh_c_temp_name(ctx, "array_call")
    output.push(ir.Stmt.stmt_local(name = name, linkage_name = name, ty = ty, value = value, line = 0, source_path = ""))
    return lowering.alloc_expr(ir.Expr.expr_name(name = name, ty = ty, pointer = Option[bool].some(value = false)))


## Record a frame field whose value is a dynamic format string: the prepared
## temp release is dropped and the frame's release/cancel functions free the
## field instead (the host's `async_info[:format_str_fields]`).  First-encounter
## order, deduplicated by field name.
function async_record_format_str_field(ctx: ref[lowering.LoweringContext], field_name: str) -> void:
    let ffp = ctx.async_format_str_fields_ptr
    if ffp != null:
        let fields = unsafe: read(ffp)
        var i: ptr_uint = 0
        while i < fields.len:
            let existing = fields.get(i) else:
                break
            if unsafe: read(existing) == field_name:
                return
            i += 1
        unsafe: read(ffp).push(field_name)
        return
    var j: ptr_uint = 0
    while j < ctx.async_format_str_fields.len:
        let existing = ctx.async_format_str_fields.get(j) else:
            break
        if unsafe: read(existing) == field_name:
            return
        j += 1
    ctx.async_format_str_fields.push(field_name)


public function lower_async_local(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], loc_name: str, loc_value: ptr[ast.Expr]?, loc_stmt_type: ptr[ast.TypeRef]?, line: ptr_uint) -> void:
    # `let _ = ...`: the host's analysis registers `local_discard_<line>` for the
    # discard and its lowering stores the (awaited) value there — a dead field,
    # but part of the frame (`async_local_decl_field_name`,
    # `lower_async_await_statement`).  No local binding is introduced.
    if loc_name == "_":
        let dv = loc_value else:
            return
        let field_name = strings.join_two("local_discard_", lowering.pw1_str(line))
        if expr_is_direct_await(dv):
            let task_ir = lowering.lower_expr(ctx, direct_await_inner(dv))
            let task_ty = normalize_awaited_task_type(lowering.ir_expr_type(task_ir))
            let result_ty = extract_task_element_type(ctx, task_ty)
            async_register_unused_field(ctx, field_name, result_ty)
            let target = lowering.alloc_expr(ir.Expr.expr_member(receiver = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = ctx.async_frame_ptr_ty, pointer = Option[bool].some(value = false))), member = field_name, ty = result_ty))
            async_emit_await(ctx, output, task_ir, task_ty, result_ty, Option[ptr[ir.Expr]].some(value = target), direct_await_inner(dv))
        else:
            let value_ir = lowering.lower_expr(ctx, dv)
            let value_ty = lowering.ir_expr_type(value_ir)
            async_register_unused_field(ctx, field_name, value_ty)
            output.push(ir.Stmt.stmt_assignment(target = lowering.alloc_expr(ir.Expr.expr_member(receiver = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = ctx.async_frame_ptr_ty, pointer = Option[bool].some(value = false))), member = field_name, ty = value_ty)), operator = "=", value = value_ir))
        return

    let field_name = strings.join_two("local_", loc_name)
    let frame_cname = strings.join_two("__mt_frame->", field_name)

    let v = loc_value else:
        # No initializer: reserve the frame field with the declared type.
        var ty0 = ctx.void_ty
        if loc_stmt_type != null:
            ty0 = lowering.resolve_type_ref(ctx, unsafe: ptr[ast.TypeRef]<-loc_stmt_type)
        async_register_local_field(ctx, loc_name, field_name, frame_cname, ty0)
        return

    if expr_is_direct_await(v):
        # The host's normalization hoists every await embedded in the awaited
        # expression into a `__mt_async_tmp_<N>` local *before* the analysis
        # registers this local's field (`normalize_async_statement`'s AwaitExpr
        # arm), so the hoist temps precede the local in the frame.
        var inner = direct_await_inner(v)
        if async_mod.expr_has_await(inner):
            inner = async_hoist_awaits(ctx, output, inner)
        let task_ir = lowering.lower_expr(ctx, inner)
        let task_ty = normalize_awaited_task_type(lowering.ir_expr_type(task_ir))
        let result_ty = extract_task_element_type(ctx, task_ty)
        async_register_local_field(ctx, loc_name, field_name, frame_cname, result_ty)
        let target = lowering.alloc_expr(ir.Expr.expr_member(receiver = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = ctx.async_frame_ptr_ty, pointer = Option[bool].some(value = false))), member = field_name, ty = result_ty))
        async_emit_await(ctx, output, task_ir, task_ty, result_ty, Option[ptr[ir.Expr]].some(value = target), inner)
        return

    # Hoist any embedded awaits (inside `?`, arithmetic, calls, etc.) into temp
    # frame locals so the remaining expression is await-free.
    var hv = v
    if async_mod.expr_has_await(v):
        hv = async_hoist_awaits(ctx, output, v)

    # `let x = <expr>?` — Result/Option propagation.  Route to the CPS-aware
    # propagate helper (which spills `x` and returns via the frame on failure).
    unsafe:
        match read(hv):
            ast.Expr.expr_unary_op as u:
                if u.operator == "?":
                    lowering.lower_propagate_let(ctx, output, loc_name, u.operand, line, false, "")
                    return
            _:
                pass

    # Plain spilled local: `frame->local_<name> = <value>`.  The host prepares
    # every CF local initializer (a dynamic format string, a proc literal, a
    # foreign call, an array call) into the statement stream, so an
    # array-returning call first lands in a `__mt_array_call_<N>` local even
    # when the local's own type is that array.
    let hoist_base = output.len()
    let hoist_saved = lowering.begin_stmt_setup(ctx, lowering.HoistMode.hm_value)
    ctx.hoist_root_ep = hv
    var val_ir = lowering.lower_expr(ctx, hv)
    let hoist_collected = lowering.collect_stmt_setup(ctx, hoist_saved)
    lowering.emit_hoist_setup(output, hoist_base, hoist_collected)
    var ty = lowering.ir_expr_type(val_ir)
    if loc_stmt_type != null:
        let annotated = lowering.local_decl_type(ctx, loc_stmt_type, hv)
        if not types.is_error(annotated):
            ty = annotated
    # A literal initializer takes the declared type (the host's CF path lowers
    # the value with `expected_type: storage_type`), so `var offset: ptr_uint = 0`
    # stores a ptr_uint literal.
    val_ir = lowering.contextual_value_to_type(
        ctx,
        hv,
        ty,
        val_ir,
        loc_stmt_type != null and types.is_float_type(ty) and not lowering.is_foreign_call_initializer(ctx, hv),
        false,
    )
    # Wrap a non-nullable value into a value-type nullable's opt struct (mirrors
    # the normal stmt_local path), so `let m: int? = 5` stores `{has_value,value}`.
    if types.is_nullable_type(ty) and not lowering.is_nullable_pointer_like(ty):
        let value_ty = lowering.ir_expr_type(val_ir)
        if not types.is_nullable_type(value_ty):
            unsafe:
                match read(val_ir):
                    ir.Expr.expr_null_literal:
                        val_ir = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = ty))
                    _:
                        val_ir = lowering.nullable_some_literal(ty, val_ir)
    async_register_local_field(ctx, loc_name, field_name, frame_cname, ty)
    let target = lowering.alloc_expr(ir.Expr.expr_member(receiver = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = ctx.async_frame_ptr_ty, pointer = Option[bool].some(value = false))), member = field_name, ty = ty))
    output.push(ir.Stmt.stmt_assignment(target = target, operator = "=", value = val_ir))
    # A dynamic format string's result is owned by the frame field: drop the
    # prepared temp release and register the field for the frame's
    # release/cancel cleanup (the host's `format_str_fields`).
    var local_cleanups = hoist_collected
    var has_format_release = false
    var fci: ptr_uint = 0
    while fci < hoist_collected.cleanups.len:
        let fcp = hoist_collected.cleanups.get(fci) else:
            break
        if format.is_format_release_stmt(unsafe: read(fcp)):
            has_format_release = true
        fci += 1
    if has_format_release:
        async_record_format_str_field(ctx, field_name)
        local_cleanups = format.drop_format_release_cleanups(hoist_collected)
    lowering.record_or_emit_local_cleanups(ctx, output, local_cleanups.cleanups)


## Lower an `await` at statement position: lower the task expr, then emit the
## suspend/resume boundary, assigning the result to `target` (or discarding).
public function lower_async_await_into(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], task_ep: ptr[ast.Expr], target: Option[ptr[ir.Expr]]) -> void:
    let task_ir = lowering.lower_expr(ctx, task_ep)
    let task_ty = normalize_awaited_task_type(lowering.ir_expr_type(task_ir))
    let result_ty = extract_task_element_type(ctx, task_ty)
    async_emit_await(ctx, output, task_ir, task_ty, result_ty, target, task_ep)


## The type of an awaited expression, normalized to a `Task[T]`.  A callee whose
## return type was recovered without the async wrap (a stored lowered return type
## rather than the analyzer's binding) yields the bare `Result`/`Option`; an
## `await` always operates on a `Task`, so wrap any non-Task awaited type here.
## `Task[T]` types pass through unchanged.
public function normalize_awaited_task_type(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_generic as g:
            if g.name == "Task":
                return t
        _:
            pass
    return tasks.make_task_type(t)


## The frame field an awaited task identifier already spills to — the host's
## `reusable_async_await_task_field_name`: `await waited` on a spilled local or a
## parameter reuses that binding's field and skips the `await_<N>` allocation
## (and its store; the value is already there).
function async_reusable_await_field(ctx: ref[lowering.LoweringContext], task_ep: ptr[ast.Expr]?) -> str:
    let ep = task_ep else:
        return ""
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                var i = ctx.locals.len()
                while i > 0:
                    i -= 1
                    let lb_ptr = ctx.locals.get(i) else:
                        break
                    let lb = read(lb_ptr)
                    if lb.name == id.name:
                        let prefix = "__mt_frame->"
                        if lb.c_name.starts_with(prefix):
                            return lb.c_name.slice(prefix.len, lb.c_name.len - prefix.len)
                        return ""
                return ""
            _:
                return ""


## Core await lowering: store the task in `frame->await_N`, guard on `ready`,
## suspend (register waiter + return) if not ready, then resume at `state_<N+1>`,
## take the result into `target`, and release the child task.
public function async_emit_await(ctx: ref[lowering.LoweringContext], output: ref[vec.Vec[ir.Stmt]], task_ir: ptr[ir.Expr], task_ty: types.Type, result_ty: types.Type, target: Option[ptr[ir.Expr]], task_ep: ptr[ast.Expr]?) -> void:
    let ptr_void = async_mod.ptr_void_type()
    let bool_ty = ctx.bool_ty
    let int_ty = types.primitive("int")
    let void_ty = ctx.void_ty
    let idx = ctx.async_await_counter
    ctx.async_await_counter = idx + 1
    let reusable = async_reusable_await_field(ctx, task_ep)
    var await_field: str
    if reusable.len > 0:
        await_field = reusable
    else:
        await_field = strings.join_two("await_", int_to_str(int<-idx))
    # The host records every await field, including one that reuses a local's
    # storage (`reuse_existing_storage`): the release/cancel builders iterate
    # them all, while the frame type dedups an entry whose field already exists.
    # Push through the pointer when set (immune to ctx reassignment by nested
    # lower_async_fn calls), otherwise push to the ctx vec directly.
    let afp = ctx.async_await_fields_ptr
    if afp != null:
        unsafe: read(afp).push(ir.Field(name = await_field, ty = task_ty))
    else:
        ctx.async_await_fields.push(ir.Field(name = await_field, ty = task_ty))
    let next_state = int<-idx + 1

    let frame_exp = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame", ty = ctx.async_frame_ptr_ty, pointer = Option[bool].some(value = false)))
    let await_ref = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = await_field, ty = task_ty))

    # frame->await_N = <task> (skipped when the task already lives in the reused
    # local's field — the host's `unless await_info[:reuse_existing_storage]`).
    if reusable.len == 0:
        output.push(ir.Stmt.stmt_assignment(target = await_ref, operator = "=", value = task_ir))

    # if (!frame->await_N.ready(frame->await_N.frame)) { state=N+1; set_waiter; return; }
    # Task member accesses carry the Task struct's field types (the host's
    # `async_task_call`); the wake argument is the wake function type.
    let task_frame_ty = task_field_type(ctx, result_ty, "frame")
    let ready_fn = lowering.alloc_expr(ir.Expr.expr_member(receiver = await_ref, member = "ready", ty = task_field_type(ctx, result_ty, "ready")))
    let ready_call = lowering.alloc_expr(ir.Expr.expr_call_indirect(callee = ready_fn, arguments = lowering.single_expr_span(lowering.alloc_expr(ir.Expr.expr_member(receiver = await_ref, member = "frame", ty = task_frame_ty))), ty = bool_ty))
    let not_ready = lowering.alloc_expr(ir.Expr.expr_unary(operator = "not", operand = ready_call, ty = bool_ty))
    var suspend = vec.Vec[ir.Stmt].create()
    suspend.push(ir.Stmt.stmt_assignment(target = lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_exp, member = "state", ty = int_ty)), operator = "=", value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-next_state, ty = int_ty))))
    var sw_args = vec.Vec[ir.Expr].create()
    unsafe:
        sw_args.push(read(lowering.alloc_expr(ir.Expr.expr_member(receiver = await_ref, member = "frame", ty = task_frame_ty))))
        sw_args.push(read(lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_frame_raw", ty = ptr_void, pointer = Option[bool].some(value = false)))))
        sw_args.push(read(lowering.alloc_expr(ir.Expr.expr_name(name = ctx.async_resume_c, ty = async_wake_fn_type(ctx), pointer = Option[bool].some(value = false)))))
    let set_waiter_fn = lowering.alloc_expr(ir.Expr.expr_member(receiver = await_ref, member = "set_waiter", ty = task_field_type(ctx, result_ty, "set_waiter")))
    suspend.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call_indirect(callee = set_waiter_fn, arguments = sw_args.as_span(), ty = void_ty)), line = 0, source_path = ""))
    suspend.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    output.push(ir.Stmt.stmt_if(condition = not_ready, then_body = suspend.as_span(), else_body = Option[span[ir.Stmt]].none))

    # resume point
    output.push(ir.Stmt.stmt_label(name = async_state_label(ctx.async_resume_c, next_state)))

    let take_fn = lowering.alloc_expr(ir.Expr.expr_member(receiver = await_ref, member = "take_result", ty = task_field_type(ctx, result_ty, "take_result")))
    let take_call = lowering.alloc_expr(ir.Expr.expr_call_indirect(callee = take_fn, arguments = lowering.single_expr_span(lowering.alloc_expr(ir.Expr.expr_member(receiver = await_ref, member = "frame", ty = task_frame_ty))), ty = result_ty))
    match target:
        Option.some as t:
            output.push(ir.Stmt.stmt_assignment(target = t.value, operator = "=", value = take_call))
        Option.none:
            # The host takes the result of every await, including a void task
            # (`async_lowering.rb:1213`).
            output.push(ir.Stmt.stmt_expression(expression = take_call, line = 0, source_path = ""))

    let release_fn = lowering.alloc_expr(ir.Expr.expr_member(receiver = await_ref, member = "release", ty = task_field_type(ctx, result_ty, "release")))
    output.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call_indirect(callee = release_fn, arguments = lowering.single_expr_span(lowering.alloc_expr(ir.Expr.expr_member(receiver = await_ref, member = "frame", ty = task_frame_ty))), ty = void_ty)), line = 0, source_path = ""))


## Async `main` entrypoint — synthesizes the C `main()` function.
## The async main is already CPS-lowered as a constructor returning Task[T] with
## linkage `<module>_main`.  Here we build a root proc from the constructor,
## drive it via `std.async.wait[int]` / `run` for void, and release the proc.
public function build_async_main_entrypoint(ctx: ref[lowering.LoweringContext], name: str) -> Option[ir.Function]:
    let sig = type_helpers.find_fn_sig(ctx, name)
    let task_ret = type_helpers.fn_sig_return_type(sig)
    let inner_ty = extract_task_element_type(ctx, task_ret)
    let is_void_ret = tasks.is_void_type_lowered(inner_ty)
    # Supported result types: int (wait[int]) and void (run).
    if not (is_void_ret or type_helpers.is_int_type(inner_ty)):
        return Option[ir.Function].none

    let int_ty = types.primitive("int")
    let void_ty = ctx.void_ty
    let void_ptr = types.Type.ty_generic(name = "ptr", args = lowering.sp_type(void_ty))
    let str_ty = types.Type.ty_str
    let char_ty = types.primitive("char")
    let cstr_ty = types.primitive("cstr")
    let ptr_char_ty = types.Type.ty_generic(name = "ptr", args = lowering.sp_type(char_ty))
    let raw_argv_ty = types.Type.ty_generic(name = "ptr", args = lowering.sp_type(ptr_char_ty))
    var params = span[analyzer.ParamEntry]()
    match sig:
        Option.some as s:
            params = s.value.params
        Option.none:
            pass

    # The host's `root_main_entrypoint_signature` + `build_root_main_entrypoint_bridge`:
    # none, one `span[str]`, `(int, ptr[cstr])`, or `(int, ptr[ptr[char]])`.
    var c_params = vec.Vec[ir.Param].create()
    var setup = vec.Vec[ir.Stmt].create()
    var call_args = vec.Vec[ptr[ir.Expr]].create()
    var cleanup = vec.Vec[ir.Stmt].create()
    if params.len > 0:
        c_params.push(ir.Param(name = "argc", linkage_name = "argc", ty = int_ty, pointer = Option[bool].some(value = false)))
        c_params.push(ir.Param(name = "argv", linkage_name = "argv", ty = raw_argv_ty, pointer = Option[bool].some(value = false)))
        let argc_expr = lowering.alloc_expr(ir.Expr.expr_name(name = "argc", ty = int_ty, pointer = Option[bool].some(value = false)))
        let argv_expr = lowering.alloc_expr(ir.Expr.expr_name(name = "argv", ty = raw_argv_ty, pointer = Option[bool].some(value = false)))
        if params.len == 1:
            let p0 = unsafe: read(params.data + 0).ty
            if not (lowering.is_span_type(p0) and types.type_equals(lowering.generic_first_arg(p0), str_ty)):
                return Option[ir.Function].none
            let items_ty = types.Type.ty_generic(name = "ptr", args = lowering.sp_type(str_ty))
            let items_ref = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_args_items", ty = items_ty, pointer = Option[bool].some(value = false)))
            setup.push(ir.Stmt.stmt_local(name = "__mt_args_items", linkage_name = "__mt_args_items", ty = items_ty, value = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = items_ty)), line = 0, source_path = ""))
            var bridge_args = vec.Vec[ir.Expr].create()
            unsafe:
                bridge_args.push(read(argc_expr))
                bridge_args.push(read(argv_expr))
                bridge_args.push(read(lowering.alloc_expr(ir.Expr.expr_address_of(expression = items_ref, ty = types.Type.ty_generic(name = "ptr", args = lowering.sp_type(items_ty))))))
            let args_ty = p0
            let args_ref = lowering.alloc_expr(ir.Expr.expr_name(name = "__mt_args", ty = args_ty, pointer = Option[bool].some(value = false)))
            setup.push(ir.Stmt.stmt_local(name = "__mt_args", linkage_name = "__mt_args", ty = args_ty, value = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_entry_argv_to_span_str", arguments = bridge_args.as_span(), ty = args_ty)), line = 0, source_path = ""))
            call_args.push(args_ref)
            cleanup.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_free_entry_argv_strs", arguments = lowering.single_expr_span(items_ref), ty = void_ty)), line = 0, source_path = ""))
        else if params.len == 2:
            let p1 = unsafe: read(params.data + 1).ty
            call_args.push(argc_expr)
            if types.is_raw_pointer(p1) and types.type_equals(types.pointer_element(p1), cstr_ty):
                let cstr_ptr_ty = types.Type.ty_generic(name = "ptr", args = lowering.sp_type(cstr_ty))
                call_args.push(lowering.alloc_expr(ir.Expr.expr_cast(target_type = cstr_ptr_ty, expression = argv_expr, ty = cstr_ptr_ty)))
            else if types.is_raw_pointer(p1) and types.type_equals(types.pointer_element(p1), ptr_char_ty):
                call_args.push(argv_expr)
            else:
                return Option[ir.Function].none
        else:
            return Option[ir.Function].none

    var body = vec.Vec[ir.Stmt].create()
    var si: ptr_uint = 0
    while si < setup.len():
        let sp = setup.get(si) else:
            break
        body.push(unsafe: read(sp))
        si += 1
    var arg_names = vec.Vec[str].create()
    var ai: ptr_uint = 0
    while ai < params.len:
        let an = strings.join_two("__mt_async_main_arg_", int_to_str(int<-ai + 1))
        let pty = unsafe: read(params.data + ai).ty
        let cval = call_args.get(ai) else:
            return Option[ir.Function].none
        body.push(ir.Stmt.stmt_local(name = an, linkage_name = an, ty = pty, value = unsafe: read(cval), line = 0, source_path = ""))
        ctx.locals.push(lowering.LocalBinding(name = an, c_name = an, ty = pty, pointer = Option[bool].some(value = false)))
        arg_names.push(an)
        ai += 1

    # The root proc calls the constructor through a synthesized AST body, so the
    # argument locals are captured into the host's `__proc_N__env`.
    var ast_args = vec.Vec[ast.Argument].create()
    ai = 0
    while ai < arg_names.len():
        let an_ptr = arg_names.get(ai) else:
            break
        ast_args.push(ast.Argument(arg_name = Option[str].none, arg_value = alloc_ast_expr(ast.Expr.expr_identifier(name = unsafe: read(an_ptr), line = 0, column = 0))))
        ai += 1
    let call_ast = alloc_ast_expr(ast.Expr.expr_call(callee = alloc_ast_expr(ast.Expr.expr_identifier(name = name, line = 0, column = 0)), args = ast_args.as_span()))
    let ret_ast = alloc_ast_stmt(ast.Stmt.stmt_ret(value = call_ast, line = 0, column = 0, length = 0))
    let proc_fn_ty = types.function_type(name = "", params = span[types.Type](), return_type = types.alloc_type(task_ret), variadic = false, is_proc = true, param_names = span[str]())
    # The env setup is a prepared expression: hoist it into the C main body
    # (no `__proc_N__setup_env` fallback).
    let proc_base = body.len()
    let proc_saved = lowering.begin_stmt_setup(ctx, lowering.HoistMode.hm_value)
    # The host lowers the root proc in a fresh env: the env temp is
    # `__mt___mt_async_main_root_env_1` (the counter starts at zero).
    let saved_proc_counter = ctx.temp_counter
    ctx.temp_counter = 0
    let proc_expr = lowering.lower_proc_expression_typed_named(ctx, span[ast.Param](), task_ret, ret_ast, proc_fn_ty, "__mt_async_main_root")
    ctx.temp_counter = saved_proc_counter
    let proc_collected = lowering.collect_stmt_setup(ctx, proc_saved)
    lowering.emit_hoist_setup(ref_of(body), proc_base, proc_collected)
    let proc_named_ty = lowering.ir_expr_type(proc_expr)

    let root_name = "__mt_async_main_root"
    body.push(ir.Stmt.stmt_local(name = root_name, linkage_name = root_name, ty = proc_named_ty, value = proc_expr, line = 0, source_path = ""))
    let root_ref = lowering.alloc_expr(ir.Expr.expr_name(name = root_name, ty = proc_named_ty, pointer = Option[bool].some(value = false)))

    let result_name = "__mt_result"
    if is_void_ret:
        # `std.async.run(root)` — non-generic, so no specialization is needed.
        let run_cname = naming.qualified_c_name("std.async", "run")
        let run_call = lowering.alloc_expr(ir.Expr.expr_call(callee = run_cname, arguments = lowering.single_expr_span(root_ref), ty = void_ty))
        body.push(ir.Stmt.stmt_expression(expression = run_call, line = 0, source_path = ""))
    else:
        # `std.async.wait[inner](root)` — specialize the generic on demand and
        # capture the int result.
        let wait_cname = ensure_async_wait_specialization(ctx, inner_ty) else:
            return Option[ir.Function].none
        let wait_call = lowering.alloc_expr(ir.Expr.expr_call(callee = wait_cname, arguments = lowering.single_expr_span(root_ref), ty = inner_ty))
        body.push(ir.Stmt.stmt_local(name = result_name, linkage_name = result_name, ty = inner_ty, value = wait_call, line = 0, source_path = ""))

    # Release the root proc: `root.release(root.env)`.
    let lifecycle_ty = lowering.proc_lifecycle_fn_type()
    let release_member = lowering.alloc_expr(ir.Expr.expr_member(receiver = root_ref, member = "release", ty = lifecycle_ty))
    let env_member = lowering.alloc_expr(ir.Expr.expr_member(receiver = root_ref, member = "env", ty = void_ptr))
    body.push(ir.Stmt.stmt_expression(expression = lowering.alloc_expr(ir.Expr.expr_call_indirect(callee = release_member, arguments = lowering.single_expr_span(env_member), ty = void_ty)), line = 0, source_path = ""))
    var ci: ptr_uint = 0
    while ci < cleanup.len():
        let cp = cleanup.get(ci) else:
            break
        body.push(unsafe: read(cp))
        ci += 1

    if is_void_ret:
        body.push(ir.Stmt.stmt_return(value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = int_ty)), line = 0, source_path = ""))
    else:
        body.push(ir.Stmt.stmt_return(value = lowering.alloc_expr(ir.Expr.expr_name(name = result_name, ty = int_ty, pointer = Option[bool].some(value = false))), line = 0, source_path = ""))

    return Option[ir.Function].some(value = ir.Function(
        name = name, linkage_name = "main", params = c_params.as_span(),
        return_type = int_ty, body = body.as_span(), entry_point = true, public_export = false, method_receiver_param = false,
    ))


## Ensure `std.async.wait[inner_ty]` is specialized and return its C linkage name.
## Mirrors Ruby's `async_main_runtime_callee_name("wait", type_arguments: [...])`,
## which instantiates the binding declared in `std.async` — the public delegating
## entry, not the deepest backend implementation.  Lowering that instance's body
## then instantiates the rest of the chain (`std.async.runtime.wait`, then
## `std.async.libuv_runtime.wait`/`wait_on`), exactly as the host's walk does.
function ensure_async_wait_specialization(ctx: ref[lowering.LoweringContext], inner_ty: types.Type) -> Option[str]:
    let gm = lowering.find_generic_function_in_module(ctx, "std.async", "wait") else:
        return Option[str].none
    if not gm.module_name.starts_with("std.async"):
        return Option[str].none

    # Build the substitution `T -> inner_ty` from wait's own type parameter name.
    var sub = map_mod.Map[str, types.Type].create()
    match gm.decl:
        ast.Decl.decl_function as fun:
            if fun.type_params.len == 0:
                return Option[str].none
            let tp_name = unsafe: read(fun.type_params.data + 0).name
            sub.set(tp_name, inner_ty)
        _:
            return Option[str].none

    # Spec key mirrors `try_inferred_generic_call`: `<owner_prefix>_wait__<key>`.
    var key = string.String.create()
    key.append(naming.module_c_prefix(gm.module_name))
    key.append("_wait__")
    key.append(lowering.spec_type_key(ctx, inner_ty))
    let spec_key = key.as_str()

    if not ctx.specialization_cache.contains(spec_key) and not ctx.spec_in_progress.contains(spec_key):
        # The async main's `wait` call is synthesized during lowering, not seen
        # by the analyzer, so its instance (and everything its body creates) is
        # creator-gated rather than pre-instantiated.
        lowering.lower_and_cache_specialization_with_sub(ctx, gm, ref_of(sub), spec_key, false)
    return Option[str].some(value = spec_key)


## Convert int to string.
function int_to_str(v: int) -> str:
    var buf = string.String.create()
    var n = v
    var is_neg = false
    if n < 0:
        n = 0 - n
        is_neg = true
    if n == 0:
        buf.push_byte(48)  # '0'
    while n > 0:
        let digit_int = n % 10
        buf.push_byte(ubyte<-(48 + digit_int))
        n = n / 10
    # The loop pushes the least-significant digit first; render most-significant
    # first so multi-digit values are not reversed.
    var rendered = string.String.with_capacity(buf.len() + 1)
    if is_neg:
        rendered.push_byte(45)  # '-'
    let digits = buf.as_str()
    var i = digits.len
    while i > 0:
        i -= 1
        rendered.push_byte(digits.byte_at(i))
    return rendered.as_str()


## ptr_uint primitive type (repeated for convenience in async section).
function ptr_uint_type() -> types.Type:
    return types.Type.ty_primitive(name = "ptr_uint")


## ptr[void] type — used for frame pointer in async CPS.
function ptr_void_type() -> types.Type:
    return types.Type.ty_generic(name = "ptr", args = lowering.single_ty_span(types.primitive("void")))


## True when `name` is one of the function-pointer fields on the Task[T] struct
## (ready, set_waiter, release, take_result, cancel) that must be accessed via
## struct field access + indirect call rather than treated as methods.
public function is_task_fn_field(name: str) -> bool:
    return name == "ready" or name == "set_waiter" or name == "release" or name == "take_result" or name == "cancel"


## Extract the element type from a Task type (`ty_generic("Task", [T])`
## or `ty_named("mt_task_...")`).  Returns `ty_primitive("void")` on failure.
public function extract_task_element_type(ctx: ref[lowering.LoweringContext], t: types.Type) -> types.Type:
    match t:
        types.Type.ty_generic as tg:
            if tg.name == "Task" and tg.args.len >= 1:
                return unsafe: read(tg.args.data + 0)
        types.Type.ty_named as tn:
            let tn_np = unsafe: read(tn.payload)
            if tn_np.name.starts_with("mt_task_"):
                let gi_ptr = monomorphized.generic_instance_get(ctx, tn_np.name)
                if gi_ptr != null:
                    let gi = unsafe: read(gi_ptr)
                    if gi.concrete_args.len >= 1:
                        return unsafe: read(gi.concrete_args.data + 0)
                        pass
        _:
            pass
    return ctx.void_ty
