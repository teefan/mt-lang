## Proc capture-env construction, extracted from lowering/lowering.mt (Wave 4.2).

import std.fmt as fmt
import std.map as map_mod
import std.string as string
import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types
import mtc.strings
import mtc.c_naming as naming

import mtc.lowering.lowering as lowering
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.utils as utils


public function lower_fn_to_proc(
    ctx: ref[lowering.LoweringContext],
    fn_c_name: str,
    fn_ty: types.Type,
    source_path: str
) -> ptr[ir.Expr]:
    let proc_id = lowering.next_proc_counter()
    var prefix = string.String.create()
    prefix.append(naming.module_c_prefix(ctx.module_name))
    prefix.append("__proc_")
    fmt.append_ptr_uint(ref_of(prefix), proc_id)

    var invoke_c = string.String.create()
    invoke_c.append(prefix.as_str())
    invoke_c.append("__invoke")
    var release_c = string.String.create()
    release_c.append(prefix.as_str())
    release_c.append("__release")
    var retain_c = string.String.create()
    retain_c.append(prefix.as_str())
    retain_c.append("__retain")

    let invoke_str = invoke_c.as_str()
    let release_str = release_c.as_str()
    let retain_str = retain_c.as_str()

    match fn_ty:
        types.Type.ty_function as fnt:
            let fnt_ft = unsafe: read(fnt.payload)
            let void_ptr = types.generic_type(name = "ptr", args = lowering.sp_type(ctx.void_ty))
            var inv_params = vec.Vec[ir.Param].create()
            inv_params.push(ir.Param(
                name = "env",
                linkage_name = "__mt_proc_env",
                ty = void_ptr,
                pointer = Option[bool].some(value = false)
            ))
            var call_args = vec.Vec[ir.Expr].create()
            var pi: ptr_uint = 0
            while pi < fnt_ft.params.len:
                var p_ty: types.Type
                unsafe:
                    p_ty = read(fnt_ft.params.data + pi)
                # The host's wrapper invoke takes the proc type's own parameter
                # names (the proc annotation's names), not synthetic ones.
                var pname = lowering.jstr_i("arg_", pi)
                if pi < fnt_ft.param_names.len:
                    let annotated = unsafe: read(fnt_ft.param_names.data + pi)
                    if annotated.len > 0:
                        pname = annotated
                inv_params.push(ir.Param(
                    name = pname,
                    linkage_name = pname,
                    ty = p_ty,
                    pointer = Option[bool].some(value = false)
                ))
                let arg_expr = lowering.alloc_expr(ir.Expr.expr_name(
                    name = pname,
                    ty = p_ty,
                    pointer = Option[bool].some(value = false)
                ))
                unsafe:
                    call_args.push(read(arg_expr))
                pi += 1
            var ret_ty = ctx.void_ty
            unsafe:
                ret_ty = read(fnt_ft.return_type)
            var inv_body = vec.Vec[ir.Stmt].create()
            if lowering.is_void_type(ret_ty):
                let call = lowering.alloc_expr(ir.Expr.expr_call(
                    callee = fn_c_name,
                    arguments = call_args.as_span(),
                    ty = ret_ty
                ))
                inv_body.push(ir.Stmt.stmt_expression(expression = call, line = 0, source_path = source_path))
                inv_body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = source_path))
            else:
                let call = lowering.alloc_expr(ir.Expr.expr_call(
                    callee = fn_c_name,
                    arguments = call_args.as_span(),
                    ty = ret_ty
                ))
                inv_body.push(ir.Stmt.stmt_return(value = call, line = 0, source_path = source_path))

            ctx.pending_synthetic_functions.push(ir.Function(
                source_module = Option[str].none,
                name = invoke_str,
                linkage_name = invoke_str,
                params = inv_params.as_span(),
                return_type = ret_ty,
                body = inv_body.as_span(),
                entry_point = false,
                public_export = false,
                method_receiver_param = false
            ))
            ctx.pending_synthetic_functions.push(lowering.build_proc_noop_fn(release_str))
            ctx.pending_synthetic_functions.push(lowering.build_proc_noop_fn(retain_str))

            # Ensure the proc struct type exists for this signature.
            let proc_name = naming.proc_type_c_name(fn_ty)
            let proc_ty = lowering.proc_ensure_struct_decl(ctx, proc_name, fn_ty)

            let lifecycle_ty = lowering.proc_lifecycle_fn_type()
            var fields = vec.Vec[ir.AggregateField].create()
            fields.push(ir.AggregateField(name = "env", value = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr))))
            fields.push(ir.AggregateField(
                name = "invoke",
                value = lowering.alloc_expr(ir.Expr.expr_name(
                    name = invoke_str,
                    ty = lowering.proc_invoke_field_type(fn_ty),
                    pointer = Option[bool].some(value = false)
                ))
            ))
            fields.push(ir.AggregateField(
                name = "release",
                value = lowering.alloc_expr(ir.Expr.expr_name(
                    name = release_str,
                    ty = lifecycle_ty,
                    pointer = Option[bool].some(value = false)
                ))
            ))
            fields.push(ir.AggregateField(
                name = "retain",
                value = lowering.alloc_expr(ir.Expr.expr_name(
                    name = retain_str,
                    ty = lifecycle_ty,
                    pointer = Option[bool].some(value = false)
                ))
            ))
            return lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = proc_ty, fields = fields.as_span()))
        _:
            fatal(c"lowering: fn_to_proc requires function type")


public function build_env_setup_fn(
    ctx: ref[lowering.LoweringContext],
    c_name: str,
    env_type_name: str,
    captures: span[lowering.ProcCapture]
) -> ir.Function:
    let void_ptr = types.generic_type(name = "ptr", args = lowering.sp_type(ctx.void_ty))
    let env_ty_named = types.named_type(name = env_type_name, module_name = "", linkage_name = Option[str].none)
    let env_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(env_ty_named))
    let uint_ty = types.primitive("ptr_uint")

    var params = vec.Vec[ir.Param].create()
    # Each capture becomes a parameter of the setup function.  The parameter needs
    # a C identifier of its own: `cap.c_name` is the *caller's* reference to the
    # captured value, which inside an async function is a frame member
    # (`__mt_frame->local_offset`) — unusable in a declaration, and meaningless in
    # this separate function, whose body must read its own parameter.
    var param_names = vec.Vec[str].create()
    var ci: ptr_uint = 0
    while ci < captures.len:
        let cap = unsafe: read(captures.data + ci)
        let pname = lowering.fresh_c_temp_name(ctx, "cap")
        param_names.push(pname)
        params.push(ir.Param(
            name = cap.name,
            linkage_name = pname,
            ty = cap.ty,
            pointer = Option[bool].some(value = false)
        ))
        ci += 1

    var body = vec.Vec[ir.Stmt].create()

    # env = (env_type*) mt_async_alloc(sizeof(env_type)) — a checked, zeroed
    # allocation (`block.rb:122-126`).
    let sizeof_call = lowering.alloc_expr(ir.Expr.expr_call(
        callee = "mt_async_alloc",
        arguments = lowering.pack_single(lowering.alloc_expr(ir.Expr.expr_sizeof(target_type = env_ty_named, ty = uint_ty))),
        ty = void_ptr
    ))
    let cast_env = lowering.alloc_expr(ir.Expr.expr_cast(target_type = env_ptr_ty, expression = sizeof_call, ty = env_ptr_ty))
    body.push(ir.Stmt.stmt_local(
        name = "env",
        linkage_name = "env",
        ty = env_ptr_ty,
        value = cast_env,
        line = 0,
        source_path = ""
    ))

    # env->__mt_ref_count = 1
    let env_ref = lowering.alloc_expr(ir.Expr.expr_name(
        name = "env",
        ty = env_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let ref_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = env_ref, member = "__mt_ref_count", ty = uint_ty))
    let one = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = uint_ty))
    body.push(ir.Stmt.stmt_assignment(target = ref_field, operator = "=", value = one))

    # Populate capture fields from parameters.
    var ci2: ptr_uint = 0
    while ci2 < captures.len:
        let cap = unsafe: read(captures.data + ci2)
        let field = lowering.alloc_expr(ir.Expr.expr_member(receiver = env_ref, member = cap.name, ty = cap.ty))
        let pname_ptr = param_names.get(ci2) else:
            break
        let cap_val = lowering.alloc_expr(ir.Expr.expr_name(
            name = unsafe: read(pname_ptr),
            ty = cap.ty,
            pointer = Option[bool].some(value = false)
        ))
        if lowering.is_array_type(cap.ty):
            let addr_of_field = lowering.alloc_expr(ir.Expr.expr_address_of(
                expression = field,
                ty = types.generic_type(name = "ptr", args = lowering.sp_type(cap.ty))
            ))
            # An array argument already decays to a pointer in C; taking its
            # address here would copy pointer bytes into the env array.
            let size_val = lowering.alloc_expr(ir.Expr.expr_sizeof(target_type = cap.ty, ty = uint_ty))
            var memcpy_args = vec.Vec[ir.Expr].create()
            unsafe:
                memcpy_args.push(read(addr_of_field))
                memcpy_args.push(read(cap_val))
                memcpy_args.push(read(size_val))
            body.push(ir.Stmt.stmt_expression(
                expression = lowering.alloc_expr(ir.Expr.expr_call(
                    callee = "memcpy",
                    arguments = memcpy_args.as_span(),
                    ty = ctx.void_ty
                )),
                line = 0,
                source_path = ""
            ))
        else:
            body.push(ir.Stmt.stmt_assignment(target = field, operator = "=", value = cap_val))
        ci2 += 1

    # A proc-storing capture is retained by the env (the host's literal setup
    # retains its proc-valued captures, `block.rb:146-151`).
    var cri2: ptr_uint = 0
    while cri2 < captures.len:
        let cap = unsafe: read(captures.data + cri2)
        if lowering.contains_proc_storage_type(ctx, cap.ty):
            let field = lowering.alloc_expr(ir.Expr.expr_member(receiver = env_ref, member = cap.name, ty = cap.ty))
            lowering.proc_contained_retain_stmts(ctx, field, cap.ty, ref_of(body))
        cri2 += 1

    # return env
    body.push(ir.Stmt.stmt_return(value = env_ref, line = 0, source_path = ""))

    return ir.Function(
        source_module = Option[str].none,
        name = c_name,
        linkage_name = c_name,
        params = params.as_span(),
        return_type = env_ptr_ty,
        body = body.as_span(),
        entry_point = false,
        public_export = false,
        method_receiver_param = false
    )


public function build_capturing_invoke(
    ctx: ref[lowering.LoweringContext],
    method_params: span[ast.Param],
    ret_ty: types.Type,
    body: ptr[ast.Stmt],
    invoke_c_name: str,
    env_type_name: str,
    captures: span[lowering.ProcCapture]
) -> ir.Function:
    let saved_locals = ctx.locals
    let saved_counter = ctx.counters.temp
    let saved_cps_ci = ctx.async_cps_active
    let saved_cps_ci_completion = ctx.async_completion_active
    let saved_ci_inside_async = ctx.inside_async
    # A proc is a synchronous closure: a literal inside an async function must not
    # inherit the caller's CPS state, or its body emits `__mt_frame->result` stores
    # that don't exist here.  Nor may it inherit `inside_async`, which wraps every
    # returned value in a Task literal.
    ctx.async_cps_active = false
    ctx.async_completion_active = false
    ctx.inside_async = false
    ctx.locals = vec.Vec[lowering.LocalBinding].create()
    ctx.counters.temp = 0
    ctx.format_state.dest_name = ""
    ctx.format_state.counter.clear()
    ctx.format_state.counter_visible = false
    ctx.format_state.cstr_backed.clear()

    let void_ptr = types.generic_type(name = "ptr", args = lowering.sp_type(ctx.void_ty))
    let env_ptr_ty = types.generic_type(
        name = "ptr",
        args = lowering.sp_type(types.named_type(name = env_type_name, module_name = "", linkage_name = Option[str].none))
    )

    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(
        name = "env",
        linkage_name = "__mt_proc_env",
        ty = void_ptr,
        pointer = Option[bool].some(value = false)
    ))

    var pi: ptr_uint = 0
    while pi < method_params.len:
        var p: ast.Param
        unsafe:
            p = read(method_params.data + pi)
        let p_ty = lowering.resolve_field_type_ref(ctx, p.param_type)
        let pc = utils.c_local_name(p.name)
        params.push(ir.Param(name = p.name, linkage_name = pc, ty = p_ty, pointer = Option[bool].some(value = false)))
        ctx.locals.push(lowering.LocalBinding(name = p.name, c_name = pc, ty = p_ty, pointer = Option[bool].some(value = false)))
        pi += 1

    # Build body: first cast env to typed pointer, then unpack captures.
    var body_stmts = vec.Vec[ir.Stmt].create()
    let env_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_proc_env",
        ty = void_ptr,
        pointer = Option[bool].some(value = false)
    ))
    let cast_env = lowering.alloc_expr(ir.Expr.expr_cast(target_type = env_ptr_ty, expression = env_expr, ty = env_ptr_ty))
    # The host names the cast local `__mt_proc_env_ptr` (`proc.rb:19`).
    let env_local_name = "__mt_proc_env_ptr"
    body_stmts.push(ir.Stmt.stmt_local(
        name = env_local_name,
        linkage_name = env_local_name,
        ty = env_ptr_ty,
        value = cast_env,
        line = 0,
        source_path = ""
    ))

    # Unpack each capture from env.  The unpacked read is `__mt_capture_<name>`
    # (the host's `proc.rb:27`), leaving the source name for the body's AST.
    var ci: ptr_uint = 0
    while ci < captures.len:
        let cap = unsafe: read(captures.data + ci)
        let env_ref = lowering.alloc_expr(ir.Expr.expr_name(
            name = env_local_name,
            ty = env_ptr_ty,
            pointer = Option[bool].some(value = false)
        ))
        let member = lowering.alloc_expr(ir.Expr.expr_member(receiver = env_ref, member = cap.name, ty = cap.ty))
        let bc = strings.join_two("__mt_capture_", cap.name)
        body_stmts.push(ir.Stmt.stmt_local(
            name = cap.name,
            linkage_name = bc,
            ty = cap.ty,
            value = member,
            line = 0,
            source_path = ""
        ))
        ctx.locals.push(lowering.LocalBinding(
            name = cap.name,
            c_name = bc,
            ty = cap.ty,
            pointer = Option[bool].some(value = false)
        ))
        ci += 1

    # Append the original body.
    let orig_body = lowering.lower_function_body(ctx, body)
    var bi: ptr_uint = 0
    while bi < orig_body.len:
        unsafe:
            body_stmts.push(read(orig_body.data + bi))
        bi += 1

    ctx.locals = saved_locals
    ctx.counters.temp = saved_counter
    ctx.async_cps_active = saved_cps_ci
    ctx.async_completion_active = saved_cps_ci_completion
    ctx.inside_async = saved_ci_inside_async
    return ir.Function(
        source_module = Option[str].none,
        name = invoke_c_name,
        linkage_name = invoke_c_name,
        params = params.as_span(),
        return_type = ret_ty,
        body = body_stmts.as_span(),
        entry_point = false, public_export = false,
        method_receiver_param = false,
    )


public function proc_capture_visit_stmt(
    ctx: ref[lowering.LoweringContext],
    sp: ptr[ast.Stmt]?,
    scopes: ref[vec.Vec[map_mod.Map[str, bool]]],
    seen: ref[map_mod.Map[str, bool]],
    captures: ref[vec.Vec[lowering.ProcCapture]]
) -> void:
    let xp = sp else:
        return
    unsafe:
        match read(xp):
            ast.Stmt.stmt_block as blk:
                proc_capture_visit_stmts(ctx, blk.statements, scopes, seen, captures)
            ast.Stmt.stmt_local as loc:
                proc_capture_visit_expr(ctx, loc.value, scopes, seen, captures)
                match loc.destructure_bindings:
                    Option.some as names:
                        var di: ptr_uint = 0
                        while di < names.value.len:
                            proc_capture_scope_add(scopes, read(names.value.data + di))
                            di += 1
                    Option.none:
                        pass
                proc_capture_scope_add(scopes, loc.name)
            ast.Stmt.stmt_assignment as a:
                proc_capture_visit_expr(ctx, a.target, scopes, seen, captures)
                proc_capture_visit_expr(ctx, a.value, scopes, seen, captures)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let br = read(iff.branches.data + bi)
                    proc_capture_visit_expr(ctx, br.condition, scopes, seen, captures)
                    proc_capture_visit_scope(ctx, br.body, scopes, seen, captures)
                    bi += 1
                proc_capture_visit_scope(ctx, iff.else_body, scopes, seen, captures)
            ast.Stmt.stmt_while as w:
                proc_capture_visit_expr(ctx, w.condition, scopes, seen, captures)
                proc_capture_visit_scope(ctx, w.body, scopes, seen, captures)
            ast.Stmt.stmt_for as f:
                var ii: ptr_uint = 0
                while ii < f.iterables.len:
                    proc_capture_visit_expr(ctx, f.iterables.data + ii, scopes, seen, captures)
                    ii += 1
                scopes.push(map_mod.Map[str, bool].create())
                var bi: ptr_uint = 0
                while bi < f.bindings.len:
                    proc_capture_scope_add(scopes, read(f.bindings.data + bi).name)
                    bi += 1
                proc_capture_visit_stmt(ctx, f.body, scopes, seen, captures)
                let _dropped = scopes.pop()
            ast.Stmt.stmt_match as m:
                proc_capture_visit_expr(ctx, m.scrutinee, scopes, seen, captures)
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    let arm = read(m.arms.data + ai)
                    proc_capture_visit_expr(ctx, arm.pattern, scopes, seen, captures)
                    scopes.push(map_mod.Map[str, bool].create())
                    match arm.binding_name:
                        Option.some as bn:
                            proc_capture_scope_add(scopes, bn.value)
                        Option.none:
                            pass
                    proc_capture_visit_stmt(ctx, arm.body, scopes, seen, captures)
                    let _dropped = scopes.pop()
                    ai += 1
            ast.Stmt.stmt_ret as r:
                proc_capture_visit_expr(ctx, r.value, scopes, seen, captures)
            ast.Stmt.stmt_expression as e:
                proc_capture_visit_expr(ctx, e.expression, scopes, seen, captures)
            ast.Stmt.stmt_defer as d:
                scopes.push(map_mod.Map[str, bool].create())
                proc_capture_visit_expr(ctx, d.expression, scopes, seen, captures)
                proc_capture_visit_stmt(ctx, d.body, scopes, seen, captures)
                let _dropped = scopes.pop()
            ast.Stmt.stmt_unsafe as u:
                proc_capture_visit_scope(ctx, u.body, scopes, seen, captures)
            ast.Stmt.stmt_static_assert as sa:
                proc_capture_visit_expr(ctx, sa.condition, scopes, seen, captures)
                proc_capture_visit_expr(ctx, sa.message, scopes, seen, captures)
            ast.Stmt.stmt_when as w:
                proc_capture_visit_expr(ctx, w.discriminant, scopes, seen, captures)
                var wi: ptr_uint = 0
                while wi < w.branches.len:
                    let br = read(w.branches.data + wi)
                    proc_capture_visit_expr(ctx, br.pattern, scopes, seen, captures)
                    scopes.push(map_mod.Map[str, bool].create())
                    match br.binding_name:
                        Option.some as bn:
                            proc_capture_scope_add(scopes, bn.value)
                        Option.none:
                            pass
                    proc_capture_visit_stmts(ctx, br.body, scopes, seen, captures)
                    let _dropped = scopes.pop()
                    wi += 1
                proc_capture_visit_scope(ctx, w.else_body, scopes, seen, captures)
            ast.Stmt.stmt_gather as g:
                var gi: ptr_uint = 0
                while gi < g.handles.len:
                    proc_capture_visit_expr(ctx, g.handles.data + gi, scopes, seen, captures)
                    gi += 1
            ast.Stmt.stmt_parallel_block as pb:
                var pbi: ptr_uint = 0
                while pbi < pb.bodies.len:
                    proc_capture_visit_scope(ctx, pb.bodies.data + pbi, scopes, seen, captures)
                    pbi += 1
            ast.Stmt.stmt_error_block as eb:
                proc_capture_visit_stmt(ctx, eb.body, scopes, seen, captures)
            ast.Stmt.stmt_emit:
                pass
            ast.Stmt.stmt_break:
                pass
            ast.Stmt.stmt_continue:
                pass
            ast.Stmt.stmt_pass:
                pass
            ast.Stmt.stmt_error:
                pass
            _:
                pass


public function build_capturing_release(
    ctx: ref[lowering.LoweringContext],
    c_name: str,
    env_type_name: str,
    captures: span[lowering.ProcCapture]
) -> ir.Function:
    let void_ptr = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))
    let env_ptr_ty = types.generic_type(
        name = "ptr",
        args = lowering.sp_type(types.named_type(name = env_type_name, module_name = "", linkage_name = Option[str].none))
    )
    let uint_ty = types.primitive("ptr_uint")
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(
        name = "env",
        linkage_name = "__mt_proc_env",
        ty = void_ptr,
        pointer = Option[bool].some(value = false)
    ))
    var body = vec.Vec[ir.Stmt].create()

    let env_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_proc_env",
        ty = void_ptr,
        pointer = Option[bool].some(value = false)
    ))
    let cast_env = lowering.alloc_expr(ir.Expr.expr_cast(target_type = env_ptr_ty, expression = env_expr, ty = env_ptr_ty))
    body.push(ir.Stmt.stmt_local(
        name = "__mt_proc_env_ptr",
        linkage_name = "__mt_proc_env_ptr",
        ty = env_ptr_ty,
        value = cast_env,
        line = 0,
        source_path = ""
    ))
    let env_ref = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_proc_env_ptr",
        ty = env_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let ref_field = lowering.alloc_expr(ir.Expr.expr_member(receiver = env_ref, member = "__mt_ref_count", ty = uint_ty))
    let one = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = uint_ty))
    body.push(ir.Stmt.stmt_assignment(target = ref_field, operator = "-=", value = one))
    let zero = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = uint_ty))
    let cond = lowering.alloc_expr(ir.Expr.expr_binary(
        operator = "==",
        left = ref_field,
        right = zero,
        ty = types.primitive("bool")
    ))
    var then_body = vec.Vec[ir.Stmt].create()
    # Captured proc values own a reference; release them before the env is
    # freed (the host's `build_proc_release_function` capture walk).
    var ci: ptr_uint = 0
    while ci < captures.len:
        var cap: lowering.ProcCapture
        unsafe:
            cap = read(captures.data + ci)
        if lowering.contains_proc_storage_type(ctx, cap.ty):
            let release_env = lowering.alloc_expr(ir.Expr.expr_name(
                name = "__mt_proc_env_ptr",
                ty = env_ptr_ty,
                pointer = Option[bool].some(value = false)
            ))
            let capture_ref = lowering.alloc_expr(ir.Expr.expr_member(receiver = release_env, member = cap.name, ty = cap.ty))
            lowering.proc_contained_release_stmts(ctx, capture_ref, cap.ty, ref_of(then_body))
        ci += 1
    let free_call = lowering.alloc_expr(ir.Expr.expr_call(
        callee = "mt_async_free",
        arguments = lowering.pack_single(lowering.alloc_expr(ir.Expr.expr_name(
            name = "__mt_proc_env",
            ty = void_ptr,
            pointer = Option[bool].some(value = false)
        ))),
        ty = types.primitive("void")
    ))
    then_body.push(ir.Stmt.stmt_expression(expression = free_call, line = 0, source_path = ""))
    body.push(ir.Stmt.stmt_if(
        condition = cond,
        then_body = then_body.as_span(),
        else_body = Option[span[ir.Stmt]].none
    ))
    body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    return ir.Function(
        source_module = Option[str].none,
        name = c_name,
        linkage_name = c_name,
        params = params.as_span(),
        return_type = types.primitive("void"),
        body = body.as_span(),
        entry_point = false,
        public_export = false,
        method_receiver_param = false
    )


public function proc_capture_visit_expr(
    ctx: ref[lowering.LoweringContext],
    ep: ptr[ast.Expr]?,
    scopes: ref[vec.Vec[map_mod.Map[str, bool]]],
    seen: ref[map_mod.Map[str, bool]],
    captures: ref[vec.Vec[lowering.ProcCapture]]
) -> void:
    let xp = ep else:
        return
    unsafe:
        match read(xp):
            ast.Expr.expr_identifier as id:
                if id.name == "this" or proc_capture_name_bound(scopes, id.name) or seen.contains(id.name):
                    return
                match lowering.find_local(ctx, id.name):
                    Option.some as lb:
                        seen.set(id.name, true)
                        captures.push(lowering.ProcCapture(
                            name = id.name,
                            c_name = lb.value.c_name,
                            ty = lb.value.ty,
                            read_expr = lowering.lower_binding_read(ctx, lb.value)
                        ))
                    Option.none:
                        pass
            ast.Expr.expr_member_access as ma:
                proc_capture_visit_expr(ctx, ma.receiver, scopes, seen, captures)
            ast.Expr.expr_call as c:
                proc_capture_visit_expr(ctx, c.callee, scopes, seen, captures)
                var i: ptr_uint = 0
                while i < c.args.len:
                    proc_capture_visit_expr(ctx, read(c.args.data + i).arg_value, scopes, seen, captures)
                    i += 1
            ast.Expr.expr_index_access as ix:
                proc_capture_visit_expr(ctx, ix.receiver, scopes, seen, captures)
                proc_capture_visit_expr(ctx, ix.index, scopes, seen, captures)
            ast.Expr.expr_specialization as s:
                proc_capture_visit_expr(ctx, s.callee, scopes, seen, captures)
            ast.Expr.expr_binary_op as b:
                proc_capture_visit_expr(ctx, b.left, scopes, seen, captures)
                proc_capture_visit_expr(ctx, b.right, scopes, seen, captures)
            ast.Expr.expr_unary_op as u:
                proc_capture_visit_expr(ctx, u.operand, scopes, seen, captures)
            ast.Expr.expr_if as c:
                proc_capture_visit_expr(ctx, c.condition, scopes, seen, captures)
                proc_capture_visit_expr(ctx, c.then_expr, scopes, seen, captures)
                proc_capture_visit_expr(ctx, c.else_expr, scopes, seen, captures)
            ast.Expr.expr_match as m:
                proc_capture_visit_expr(ctx, m.scrutinee, scopes, seen, captures)
                var ai: ptr_uint = 0
                while ai < m.arms.len:
                    let arm = read(m.arms.data + ai)
                    proc_capture_visit_expr(ctx, arm.pattern, scopes, seen, captures)
                    scopes.push(map_mod.Map[str, bool].create())
                    match arm.binding_name:
                        Option.some as bn:
                            proc_capture_scope_add(scopes, bn.value)
                        Option.none:
                            pass
                    proc_capture_visit_expr(ctx, arm.value, scopes, seen, captures)
                    let _dropped = scopes.pop()
                    ai += 1
            ast.Expr.expr_format_string as f:
                var pi: ptr_uint = 0
                while pi < f.parts.len:
                    match read(f.parts.data + pi):
                        ast.FormatStringPart.fmt_expr as part:
                            proc_capture_visit_expr(ctx, part.expression, scopes, seen, captures)
                        ast.FormatStringPart.fmt_text:
                            pass
                    pi += 1
            ast.Expr.expr_range as r:
                proc_capture_visit_expr(ctx, r.start_expr, scopes, seen, captures)
                proc_capture_visit_expr(ctx, r.end_expr, scopes, seen, captures)
            ast.Expr.expr_prefix_cast as pc:
                proc_capture_visit_expr(ctx, pc.expression, scopes, seen, captures)
            ast.Expr.expr_unsafe as u:
                proc_capture_visit_expr(ctx, u.expression, scopes, seen, captures)
            ast.Expr.expr_await as aw:
                proc_capture_visit_expr(ctx, aw.expression, scopes, seen, captures)
            ast.Expr.expr_detach as d:
                proc_capture_visit_expr(ctx, d.expression, scopes, seen, captures)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    proc_capture_visit_expr(ctx, el.elements.data + ei, scopes, seen, captures)
                    ei += 1
            ast.Expr.expr_named as n:
                proc_capture_visit_expr(ctx, n.value, scopes, seen, captures)
            _:
                pass

public function collect_proc_captures(
    ctx: ref[lowering.LoweringContext],
    method_params: span[ast.Param],
    body: ptr[ast.Stmt]?
) -> span[lowering.ProcCapture]:
    var captures = vec.Vec[lowering.ProcCapture].create()
    var seen = map_mod.Map[str, bool].create()
    var scopes = vec.Vec[map_mod.Map[str, bool]].create()
    var param_scope = map_mod.Map[str, bool].create()
    var pi: ptr_uint = 0
    while pi < method_params.len:
        unsafe:
            param_scope.set(read(method_params.data + pi).name, true)
        pi += 1
    scopes.push(param_scope)
    proc_capture_visit_stmt(ctx, body, ref_of(scopes), ref_of(seen), ref_of(captures))
    return captures.as_span()


public function proc_capture_name_bound(scopes: ref[vec.Vec[map_mod.Map[str, bool]]], name: str) -> bool:
    var i = scopes.len()
    while i > 0:
        i -= 1
        let sc = scopes.get(i) else:
            continue
        if unsafe: read(sc).contains(name):
            return true
    return false


public function proc_capture_scope_add(scopes: ref[vec.Vec[map_mod.Map[str, bool]]], name: str) -> void:
    if name == "":
        return
    let sc = scopes.get(scopes.len() - 1) else:
        return
    unsafe: read(sc).set(name, true)


public function proc_capture_visit_scope(
    ctx: ref[lowering.LoweringContext],
    body: ptr[ast.Stmt]?,
    scopes: ref[vec.Vec[map_mod.Map[str, bool]]],
    seen: ref[map_mod.Map[str, bool]],
    captures: ref[vec.Vec[lowering.ProcCapture]]
) -> void:
    if body == null:
        return
    scopes.push(map_mod.Map[str, bool].create())
    proc_capture_visit_stmt(ctx, body, scopes, seen, captures)
    let _dropped = scopes.pop()


public function proc_capture_visit_stmts(
    ctx: ref[lowering.LoweringContext],
    stmts: span[ast.Stmt],
    scopes: ref[vec.Vec[map_mod.Map[str, bool]]],
    seen: ref[map_mod.Map[str, bool]],
    captures: ref[vec.Vec[lowering.ProcCapture]]
) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        unsafe:
            proc_capture_visit_stmt(ctx, stmts.data + i, scopes, seen, captures)
        i += 1
