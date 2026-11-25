## Monomorphized function lowering and the per-module driver — type-parameter
## substitution, generic-instance registry access, specialization ordering, the
## per-module lowering walk (`lower_module`), and opaque declaration collection.
## Extracted from lowering/lowering.mt.

import std.vec as vec
import std.map as map_mod
import std.str
import std.string as string

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.loader.module_loader as loader
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.c_naming as naming

import mtc.lowering.async_cps as async_cps
import mtc.lowering.comptime as comptime
import mtc.lowering.comptime_types as comptime_types
import mtc.lowering.const_eval as const_eval
import mtc.lowering.include_scan as include_scan
import mtc.lowering.lowering as lowering
import mtc.lowering.tasks as tasks
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.utils as utils
import mtc.strings


## Lower a function body with type-parameter substitution applied: every reference
## to a type param (e.g. `T`) in locals, expressions, and the return type is
## replaced by the corresponding concrete type from `sub`.
public function lower_specialized_function(
    ctx: ref[lowering.LoweringContext],
    name: str,
    spec_key: str,
    params: span[ast.Param],
    return_type: ptr[ast.TypeRef]?,
    body: ptr[ast.Stmt]?,
    sub: ref[map_mod.Map[str, types.Type]],
    body_validated: bool
) -> ir.Function:
    # Reset function-level state
    ctx.locals.clear()
    ctx.temp_counter = 0
    ctx.fmt_dest_name = ""
    ctx.fmt_counter.clear()
    ctx.fmt_counter_visible = false
    ctx.cstr_backed_names.clear()
    ctx.function_returns.clear()
    var saved_current_fn = ctx.current_function_linkage
    ctx.current_function_linkage = spec_key
    # Calls inside this body were analyzer-instantiated only when the host
    # validated the specialization's body (a concrete call site); an
    # instance created by other paths (the iterator protocol) is not validated,
    # so its nested concrete calls are lowering-created and creator-gated.
    var saved_pre_instantiated = ctx.pre_instantiated_context
    ctx.pre_instantiated_context = body_validated
    var saved_type_subst = ctx.type_substitution
    ctx.type_substitution = read(sub)
    var ir_params = vec.Vec[ir.Param].create()
    var param_setup = vec.Vec[ir.Stmt].create()
    var pi: ptr_uint = 0
    while pi < params.len:
        var p: ast.Param
        unsafe:
            p = read(params.data + pi)
        # For proc/fn types, resolve via ty_function first so that type params
        # get substituted *before* proc struct conversion (otherwise unresolved
        # params leak into struct names like mt_proc_T).
        var fn_tref = p.param_type
        var p_ty: types.Type
        if fn_tref.is_proc or fn_tref.is_fn:
            let fn_type = lowering.resolve_function_type_ref(ctx, ptr_of(fn_tref))
            let substituted = substitute_type_params(ctx, fn_type, sub)
            p_ty = lowering.qualify_type(ctx, substituted)
        else:
            p_ty = lowering.qualify_type(
                ctx,
                substitute_type_params(ctx, lowering.resolve_field_type_ref(ctx, fn_tref), sub)
            )
        let p_c = utils.c_local_name(p.name)
        let p_ptr = false
        let p_link = lowering.array_param_input_name(p_ty, p_c, ref_of(param_setup))
        ir_params.push(ir.Param(
            name = p.name,
            linkage_name = p_link,
            ty = p_ty,
            pointer = Option[bool].some(value = p_ptr)
        ))
        ctx.locals.push(lowering.LocalBinding(
            name = p.name,
            c_name = p_c,
            ty = p_ty,
            pointer = Option[bool].some(value = p_ptr)
        ))
        pi += 1
    var ret_ty = ctx.void_ty
    if return_type != null:
        let rt_raw = unsafe: read(unsafe: ptr[ast.TypeRef]<-return_type)
        if rt_raw.is_proc or rt_raw.is_fn:
            let fn_type = lowering.resolve_function_type_ref(ctx, unsafe: ptr[ast.TypeRef]<-return_type)
            let substituted = substitute_type_params(ctx, fn_type, sub)
            ret_ty = lowering.qualify_type(ctx, substituted)
        else:
            ret_ty = lowering.qualify_type(
                ctx,
                substitute_type_params(ctx, lowering.resolve_field_type_ref(ctx, rt_raw), sub)
            )
    # Register the specialization's return type before lowering its body so a
    # recursive self-call resolves its type from here instead of the analyzer's
    # unsubstituted generic-body record.
    ctx.function_returns.set(spec_key, ret_ty)
    var saved_sub = ctx.type_substitution
    ctx.type_substitution = read(sub)
    # The substituted return type is the body's contextual type: `return null`
    # in `alloc[T](…) -> own[T]?` types the literal `Nullable(own[int])`, not
    # `void` (the host's `lower_return_stmt` contextual lowering).
    var saved_fn_ret = ctx.current_fn_return_type
    ctx.current_fn_return_type = ret_ty
    let body_ir = lowering.prepend_param_setup(ref_of(param_setup), lowering.lower_function_body(ctx, body))
    ctx.current_fn_return_type = saved_fn_ret
    ctx.type_substitution = saved_sub
    ctx.type_substitution = saved_type_subst
    ctx.current_function_linkage = saved_current_fn
    ctx.pre_instantiated_context = saved_pre_instantiated
    return ir.Function(
        name = name,
        linkage_name = name,
        params = ir_params.as_span(),
        return_type = ret_ty,
        body = body_ir,
        entry_point = false, public_export = false,
        method_receiver_param = false,
    )


## Replace type-parameter references (`ty_var`) in a type with their concrete
## values from the substitution map.  Other type variants pass through unchanged.
public function substitute_type_params(
    ctx: ref[lowering.LoweringContext],
    ty: types.Type,
    sub: ref[map_mod.Map[str, types.Type]]
) -> types.Type:
    match ty:
        types.Type.ty_var as v:
            let concrete = sub.get(v.name)
            if concrete != null:
                return unsafe: read(concrete)
            return ty
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            let concrete = sub.get(im_bp.name)
            if concrete != null:
                return unsafe: read(concrete)
            if im_bp.args.len > 0:
                var args = vec.Vec[types.Type].with_capacity_exact(im_bp.args.len)
                var i: ptr_uint = 0
                while i < im_bp.args.len:
                    unsafe:
                        args.push(substitute_type_params(ctx, read(im_bp.args.data + i), sub))
                    i += 1
                return types.imported_type(module_name = im_bp.module_name, name = im_bp.name, args = args.as_span())
            return ty
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            let concrete = sub.get(n_np.name)
            if concrete != null:
                return unsafe: read(concrete)
            return ty
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            var args = vec.Vec[types.Type].with_capacity_exact(g_bp.args.len)
            var i: ptr_uint = 0
            while i < g_bp.args.len:
                unsafe:
                    args.push(substitute_type_params(ctx, read(g_bp.args.data + i), sub))
                i += 1
            return types.generic_type(name = g_bp.name, args = args.as_span())
        types.Type.ty_nullable as nl:
            return types.Type.ty_nullable(base = types.alloc_type(substitute_type_params(
                ctx,
                unsafe: read(nl.base),
                sub
            )))
        types.Type.ty_function as fnt:
            let fnt_ft = unsafe: read(fnt.payload)
            var fn_params = vec.Vec[types.Type].with_capacity_exact(fnt_ft.params.len)
            var pi: ptr_uint = 0
            while pi < fnt_ft.params.len:
                unsafe:
                    fn_params.push(substitute_type_params(ctx, read(fnt_ft.params.data + pi), sub))
                pi += 1
            return types.function_type(
                name = fnt_ft.name,
                params = fn_params.as_span(),
                return_type = types.alloc_type(substitute_type_params(ctx, unsafe: read(fnt_ft.return_type), sub)),
                variadic = fnt_ft.variadic,
                is_proc = fnt_ft.is_proc,
                param_names = fnt_ft.param_names
            )
        _:
            return ty


## Accessors for the shared program-wide generic-struct instance registry
## (`ctx.generic_struct_instances` is a raw pointer to the one shared map).
public function generic_instance_get(ctx: ref[lowering.LoweringContext], name: str) -> ptr[lowering.GenericReceiver]?:
    return unsafe: read(ctx.generic_struct_instances).get(name)


public function generic_instance_set(
    ctx: ref[lowering.LoweringContext],
    name: str,
    value: lowering.GenericReceiver
) -> void:
    unsafe: read(ctx.generic_struct_instances).set(name, value)


public function generic_instance_contains(ctx: ref[lowering.LoweringContext], name: str) -> bool:
    return unsafe: read(ctx.generic_struct_instances).contains(name)


## Create a fully initialised lowering.LoweringContext for a single module.  Every field is
## set explicitly so all code paths start from a known clean state.
function create_lowering_context(
    analysis: analyzer.Analysis,
    prog_returns: ptr[map_mod.Map[str, types.Type]],
    prog_async: ptr[map_mod.Map[str, bool]],
    pl_field_types: ptr[map_mod.Map[str, types.Type]],
    prog_analyses: span[analyzer.Analysis],
    lod_modules: span[loader.LoadedModule],
    gen_instances: ptr[map_mod.Map[str, lowering.GenericReceiver]],
    spec_infos: ptr[map_mod.Map[str, lowering.SpecInfo]]
) -> lowering.LoweringContext:
    return lowering.LoweringContext(
        module_name = analysis.module_name,
        analysis = analysis,
        is_root_module = false,
        locals = vec.Vec[lowering.LocalBinding].create(),
        flow_scopes = vec.Vec[map_mod.Map[str, types.Type]].create(),
        temp_counter = 0,
        fmt_dest_name = "",
        fmt_counter = map_mod.Map[str, ptr_uint].create(),
        fmt_counter_visible = false,
        cstr_backed_names = map_mod.Map[str, bool].create(),
        foreign_map = map_mod.Map[str, lowering.ForeignInfo].create(),
        extern_map = map_mod.Map[str, str].create(),
        function_returns = map_mod.Map[str, types.Type].create(),
        variants = map_mod.Map[str, lowering.VariantInfo].create(),
        match_label_counter = 0,
        program_returns = prog_returns,
        program_async = prog_async,
        prelude_arm_field_types = pl_field_types,
        pending_specializations = vec.Vec[lowering.PendingSpecialization].create(),
        specialization_cache = map_mod.Map[str, ir.Function].create(),
        generic_struct_decls = map_mod.Map[str, ir.StructDecl].create(),
        generic_struct_instances = gen_instances,
        spec_infos = spec_infos,
        arm_payload_fields = map_mod.Map[str, lowering.VariantArmInfo].create(),
        program_analyses = prog_analyses,
        loaded_modules = lod_modules,
        spec_in_progress = map_mod.Map[str, bool].create(),
        type_substitution = map_mod.Map[str, types.Type].create(),
        current_function_linkage = "",
        pre_instantiated_context = true,
        pending_synthetic_functions = vec.Vec[ir.Function].create(),
        pending_external_structs = vec.Vec[ir.ExternalStructLayout].create(),
        external_struct_keys = map_mod.Map[str, bool].create(),
        pending_dyn_structs = vec.Vec[ir.StructDecl].create(),
        pending_dyn_vtable_structs = vec.Vec[ir.StructDecl].create(),
        pending_dyn_constants = vec.Vec[ir.Constant].create(),
        dyn_generated_vtables = map_mod.Map[str, bool].create(),
        str_buffer_structs = map_mod.Map[str, str].create(),
        event_runtimes = map_mod.Map[str, lowering.EventRuntimeInfo].create(),
        pending_synthetic_enums = vec.Vec[ir.EnumDecl].create(),
        pending_generic_variants = vec.Vec[ir.VariantDecl].create(),
        pending_proc_structs = vec.Vec[ir.StructDecl].create(),
        pending_synthetic_structs = vec.Vec[ir.StructDecl].create(),
        pending_emitted_functions = null,
        pending_emitted_structs = null,
        pending_emitted_constants = null,
        pending_tuple_linkages = map_mod.Map[str, bool].create(),
        subscription_emitted = false,
        event_error_emitted = false,
        inline_for_element = Option[comptime_types.ComptimeElement].none,
        defer_stack = vec.Vec[lowering.DeferGroup].create(),
        hoist_mode = lowering.HoistMode.hm_off,
        hoist_stmts = vec.Vec[ir.Stmt].create(),
        hoist_cleanups = vec.Vec[ir.Stmt].create(),
        hoist_stmt_emitted = false,
        hoist_root_ep = null,
        array_call_exempt = null,
        mapping_replacements = map_mod.Map[str, ptr[ir.Expr]].create(),
        inside_async = false,
        async_completion_active = false,
        async_nonawait_body = false,
        current_fn_return_type = types.primitive("void"),
        async_cps_active = false,
        async_frame_ptr_ty = types.primitive("void"),
        async_resume_c = "",
        async_result_ty = types.primitive("void"),
        async_result_is_void = true,
        async_await_counter = 0,
        async_tmp_counter = 0,
        async_local_fields = vec.Vec[ir.Field].create(),
        async_await_fields = vec.Vec[ir.Field].create(),
        async_local_seen = map_mod.Map[str, bool].create(),
        async_format_str_fields = vec.Vec[str].create(),
        async_match_binding_names = map_mod.Map[ptr_uint, str].create(),
        async_and_or_field_indices = map_mod.Map[ptr_uint, ptr_uint].create(),
        async_structured_setup = false,
        async_force_cps_body = false,
        next_spec_body_validated = Option[bool].none,
        async_and_or_left_setup = map_mod.Map[ptr_uint, vec.Vec[ir.Stmt]].create(),
        async_and_or_right_setup = map_mod.Map[ptr_uint, vec.Vec[ir.Stmt]].create(),
        async_await_fields_ptr = null,
        async_local_fields_ptr = null,
        async_format_str_fields_ptr = null,
        loop_break_label = "",
        loop_continue_label = "",
        loop_continue_native = false,
        loop_break_native = false,
        loop_defer_depth = 0,
        bool_ty = types.primitive("bool"),
        void_ty = types.primitive("void"),
        ptr_void_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void"))),
        opaque_keys = collect_opaque_keys(prog_analyses),
    )


## Build the program-wide set of opaque type C keys by scanning every module's
## declarations (including raw external `std.c.*` files) for `opaque` decls.
## Keyed by `naming.type_c_key(ty_imported(module, name))` so lowering can
## recognise an opaque type after import/alias resolution.
function collect_opaque_keys(prog_analyses: span[analyzer.Analysis]) -> map_mod.Map[str, bool]:
    var keys = map_mod.Map[str, bool].create()
    var mi: ptr_uint = 0
    while mi < prog_analyses.len:
        var analysis: analyzer.Analysis
        unsafe:
            analysis = read(prog_analyses.data + mi)
        var di: ptr_uint = 0
        while di < analysis.source_file.declarations.len:
            var d: ast.Decl
            unsafe:
                d = read(analysis.source_file.declarations.data + di)
            match d:
                ast.Decl.decl_opaque as op:
                    keys.set(
                        naming.type_c_key(types.imported_type(
                            module_name = analysis.module_name,
                            name = op.name,
                            args = span[types.Type]()
                        )),
                        true
                    )
                _:
                    pass
            di += 1
        mi += 1
    return keys


## Pre-scan every module's function declarations and record each one's resolved
## return type keyed by its C linkage name, so cross-module calls can look them
## up regardless of lowering order.
public function collect_program_returns(
    program: loader.Program,
    sink: ref[map_mod.Map[str, types.Type]],
    async_sink: ref[map_mod.Map[str, bool]],
    prelude_arm_field_types: ref[map_mod.Map[str, types.Type]],
    gen_instances: ref[map_mod.Map[str, lowering.GenericReceiver]]
) -> void:
    # Specialization metadata is only meaningful for the module fragments the
    # driver assembles; this pass discards it.
    var discarded_spec_infos = map_mod.Map[str, lowering.SpecInfo].create()
    var mi: ptr_uint = 0
    while mi < program.analyses.len():
        let a_ptr = program.analyses.get(mi) else:
            mi += 1
            continue
        var analysis = unsafe: read(a_ptr)
        var ctx = create_lowering_context(
            analysis,
            ptr_of(read(sink)),
            ptr_of(read(async_sink)),
            ptr_of(read(prelude_arm_field_types)),
            program.analyses.as_span(),
            program.modules.as_span(),
            ptr_of(read(gen_instances)),
            ptr_of(discarded_spec_infos)
        )
        var di: ptr_uint = 0
        while di < analysis.source_file.declarations.len:
            var d: ast.Decl
            unsafe:
                d = read(analysis.source_file.declarations.data + di)
            match d:
                ast.Decl.decl_function as fun:
                    # Record async functions once; cross-module call lowering
                    # reads this instead of rescanning every declaration and
                    # allocating a C name per candidate on every call.
                    if fun.is_async:
                        async_sink.set(naming.qualified_c_name(analysis.module_name, fun.name), true)
                    # A generic function's return type still carries type
                    # parameters; resolving it here (with no substitution
                    # context) would instantiate bogus concrete types.  Its
                    # specializations record their own return types.
                    if fun.type_params.len == 0:
                        let ret = type_helpers.resolve_return_type(
                            ref_of(ctx),
                            type_helpers.find_fn_sig(ref_of(ctx), fun.name),
                            fun.return_type
                        )
                        sink.set(naming.qualified_c_name(analysis.module_name, fun.name), ret)
                ast.Decl.decl_extern_function as ext:
                    # External functions use their bare C name as the linkage name
                    # (no module prefix), so a cross-module call `c.func(...)` can
                    # resolve the result type from that same bare-name key.
                    let ext_ret = if ext.return_type != null: type_helpers.resolve_return_type(
                        ref_of(ctx),
                        Option[analyzer.FnSig].none,
                        ext.return_type
                    ) else: types.primitive("void")
                    sink.set(ext.name, ext_ret)
                ast.Decl.decl_foreign_function as ff:
                    # Foreign functions are called cross-module by their Milk Tea
                    # name (`libc.get_environment_variable(...)`), lowered to a
                    # module-qualified C wrapper, so register the resolved return
                    # type under that same qualified linkage key.  Without this a
                    # cross-module foreign call resolves to void and its result
                    # local is emitted `void`.
                    let ff_ret = lowering.qualify_type(
                        ref_of(ctx),
                        lowering.resolve_type_ref(ref_of(ctx), ff.return_type)
                    )
                    sink.set(naming.qualified_c_name(analysis.module_name, ff.name), ff_ret)
                _:
                    pass
            di += 1
        mi += 1


## The last component of a type reference's name (`Vec[T]` -> "Vec",
## `vec.Vec[T]` -> "Vec").
function type_ref_last_name(tref_ptr: ptr[ast.TypeRef]) -> str:
    let tref = unsafe: read(tref_ptr)
    if tref.name.parts.len == 0:
        return ""
    unsafe:
        return read(tref.name.parts.data + (tref.name.parts.len - 1))


## Render a type the way the host's `Type#to_s` does for the fixpoint's
## `sort_by { instance.type_arguments.map(&:to_s).join(",") }` key.  Nominal
## types (structs, variants, enums) are module-qualified; builtin generics
## (`ptr`, `span`, `array`, `Task`, …) are bare; the prelude variants belong to
## `std.option` / `std.result`.  This is intentionally separate from
## `c_naming.type_to_s_qualified`, whose output feeds C name mangling.
public function spec_arg_type_to_s(t: types.Type) -> str:
    match t:
        types.Type.ty_primitive as p:
            return p.name
        types.Type.ty_str:
            return "str"
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if n_np.module_name.len > 0:
                return strings.join_three(n_np.module_name, ".", n_np.name)
            return n_np.name
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            var buf = string.String.create()
            if im_bp.module_name.len > 0:
                buf.append(im_bp.module_name)
                buf.append(".")
            buf.append(im_bp.name)
            if im_bp.args.len > 0:
                buf.append("[")
                var i: ptr_uint = 0
                while i < im_bp.args.len:
                    if i > 0:
                        buf.append(", ")
                    unsafe:
                        buf.append(spec_arg_type_to_s(read(im_bp.args.data + i)))
                    i += 1
                buf.append("]")
            return buf.as_str()
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            var buf = string.String.create()
            if g_bp.name == "Option":
                buf.append("std.option.")
            else if g_bp.name == "Result":
                buf.append("std.result.")
            buf.append(g_bp.name)
            if g_bp.args.len > 0:
                buf.append("[")
                var i: ptr_uint = 0
                while i < g_bp.args.len:
                    if i > 0:
                        buf.append(", ")
                    unsafe:
                        buf.append(spec_arg_type_to_s(read(g_bp.args.data + i)))
                    i += 1
                buf.append("]")
            return buf.as_str()
        types.Type.ty_nullable as nl:
            var buf = string.String.create()
            unsafe:
                buf.append(spec_arg_type_to_s(read(nl.base)))
            buf.append("?")
            return buf.as_str()
        types.Type.ty_tuple as tup:
            let tup_bp = unsafe: read(tup.payload)
            var buf = string.String.create()
            buf.append("(")
            var i: ptr_uint = 0
            while i < tup_bp.elements.len:
                if i > 0:
                    buf.append(", ")
                unsafe:
                    buf.append(spec_arg_type_to_s(read(tup_bp.elements.data + i)))
                i += 1
            buf.append(")")
            return buf.as_str()
        types.Type.ty_function as fnt:
            let fnt_ft = unsafe: read(fnt.payload)
            if fnt_ft.is_proc:
                var buf = string.String.create()
                buf.append("proc(")
                var i: ptr_uint = 0
                while i < fnt_ft.params.len:
                    if i > 0:
                        buf.append(", ")
                    unsafe:
                        buf.append(spec_arg_type_to_s(read(fnt_ft.params.data + i)))
                    i += 1
                buf.append(") -> ")
                unsafe:
                    buf.append(spec_arg_type_to_s(read(fnt_ft.return_type)))
                return buf.as_str()
            if fnt_ft.name.len > 0:
                return strings.join_two("fn ", fnt_ft.name)
            return "fn "
        types.Type.ty_var as v:
            return v.name
        types.Type.ty_opaque as o:
            let o_bp = unsafe: read(o.payload)
            if o_bp.module_name.len > 0:
                return strings.join_three(o_bp.module_name, ".", o_bp.name)
            return o_bp.name
        _:
            return types.type_to_string(t)


## A single visit in the host's `lower_functions` declaration walk.  A
## non-instance visit emits one function by linkage; an instance visit emits
## every *available* instance of a generic declaration / extending block method.
struct DeclVisit:
    instance: bool
    linkage: str
    owner_module: str
    decl_key: str
    ## `owner_module` + `decl_key`, precomputed for the availability map.
    owner_key: str
    is_main: bool


## Join an owner module and declaration key into one map key.  Module names and
## declaration keys never contain `@@`.
function spec_owner_key(owner_module: str, decl_key: str) -> str:
    var b = string.String.create()
    b.append(owner_module)
    b.append("@@")
    b.append(decl_key)
    return b.as_str()


## Build one module's declaration visit sequence in the host's order
## (`expanded_declarations`, `functions.rb:18-73`): functions in source order,
## an extending block's methods in source order.
function build_decl_visits(
    analysis: analyzer.Analysis,
    analyses: span[analyzer.Analysis],
    expanded_decls: ref[map_mod.Map[str, span[ast.Decl]]]
) -> vec.Vec[DeclVisit]:
    var visits = vec.Vec[DeclVisit].create()
    let module_name = analysis.module_name
    var source_decls = analysis.source_file.declarations
    let expanded_ptr = expanded_decls.get(module_name)
    if expanded_ptr != null:
        source_decls = unsafe: read(expanded_ptr)
    var di: ptr_uint = 0
    while di < source_decls.len:
        var d: ast.Decl
        unsafe:
            d = read(source_decls.data + di)
        match d:
            ast.Decl.decl_function as fun:
                if fun.type_params.len == 0:
                    visits.push(DeclVisit(
                        instance = false,
                        linkage = naming.qualified_c_name(module_name, fun.name),
                        owner_module = "", decl_key = "", owner_key = "",
                        is_main = fun.name == "main",
                    ))
                else:
                    let dk = strings.join_two("fn:", fun.name)
                    visits.push(DeclVisit(
                        instance = true, linkage = "",
                        owner_module = module_name, decl_key = dk,
                        owner_key = spec_owner_key(module_name, dk), is_main = false,
                    ))
            ast.Decl.decl_extending_block as ex:
                let bare = unsafe: type_ref_last_name(ex.type_name)
                # Resolve the receiver the same way `lower_extending_block` does,
                # so the linkage name looked up here is the one it emitted.
                var recv_name = bare
                var receiver_ty = lowering.extending_receiver_type(module_name, bare)
                match lowering.extending_receiver_target(analyses, analysis, ex.type_name):
                    Option.some as resolved:
                        receiver_ty = resolved.value
                        match lowering.named_type_name(resolved.value):
                            Option.some as resolved_name:
                                recv_name = resolved_name.value
                            Option.none:
                                pass
                    Option.none:
                        # A nested struct target (`extending Rectangle.Edge:`)
                        # resolves through the analysis' registered types, the
                        # same way `lower_extending_block` names the method.
                        let target_parts = unsafe: read(ex.type_name).name.parts
                        match lowering.nested_type_in_analysis(analysis, target_parts):
                            Option.some as nested:
                                receiver_ty = nested.value
                            Option.none:
                                pass
                var mi: ptr_uint = 0
                while mi < ex.methods.len:
                    var m: ast.Method
                    unsafe:
                        m = read(ex.methods.data + mi)
                    if m.type_params.len > 0 or unsafe: ex.type_name.arguments.len > 0:
                        var dk = string.String.create()
                        dk.append("method:")
                        dk.append(bare)
                        dk.append(".")
                        dk.append(m.name)
                        visits.push(DeclVisit(
                            instance = true, linkage = "",
                            owner_module = module_name, decl_key = dk.as_str(),
                            owner_key = spec_owner_key(module_name, dk.as_str()), is_main = false,
                        ))
                    else:
                        visits.push(DeclVisit(
                            instance = false,
                            linkage = lowering.method_c_name_for_receiver(
                                receiver_ty,
                                module_name,
                                recv_name,
                                m.name,
                                m.method_kind
                            ),
                            owner_module = "", decl_key = "", owner_key = "", is_main = false,
                        ))
                    mi += 1
            _:
                pass
        di += 1
    return visits


## An instance is available once the function that created it has been lowered.
## Instances created outside any function body (module constants/globals,
## synthetic setup) are available from the start; a creator that the declaration
## walk never emits is treated the same way.
function spec_creator_ready(
    info: lowering.SpecInfo,
    emittable: ref[map_mod.Map[str, bool]],
    emitted: ref[map_mod.Map[str, bool]],
    setup_reached: ref[map_mod.Map[str, bool]]
) -> bool:
    if info.pre_instantiated:
        return true
    if info.creator == "":
        if info.setup_module == "":
            return true
        return setup_reached.contains(info.setup_module)
    if not emittable.contains(info.creator):
        return true
    return emitted.contains(info.creator)


## Append a function to one module's ordered result list.
function push_module_function(per_module: ref[vec.Vec[vec.Vec[ir.Function]]], mi: ptr_uint, f: ir.Function) -> void:
    let fp = per_module.get(mi) else:
        return
    unsafe: read(fp).push(f)


## Order the whole program's functions like the host's `lower_modules`: an
## initial declaration pass over every module, then `lower_functions` fixpoint
## passes until no function is lowered.  Within one visit the available
## instances are sorted by their type-argument key (the host's `sort_by`), and a
## function's instances become available at its own visit — so an instance
## created by an earlier declaration in the same pass can still be emitted later
## in that pass, while one created after its declaration was seen waits for the
## next pass.
public function order_module_functions(
    analyses: span[analyzer.Analysis],
    fragments: span[ir.Program],
    all_by_linkage: ref[map_mod.Map[str, ir.Function]],
    spec_infos: ref[map_mod.Map[str, lowering.SpecInfo]],
    expanded_decls: ref[map_mod.Map[str, span[ast.Decl]]]
) -> vec.Vec[ir.Function]:
    var visits = vec.Vec[vec.Vec[DeclVisit]].create()
    var emittable = map_mod.Map[str, bool].create()
    var specs_by_decl = map_mod.Map[str, vec.Vec[str]].create()
    var mi: ptr_uint = 0
    while mi < analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(analyses.data + mi)
        let module_visits = build_decl_visits(a, analyses, expanded_decls)
        var vi: ptr_uint = 0
        while vi < module_visits.len():
            let vp = module_visits.get(vi) else:
                break
            let v = unsafe: read(vp)
            if not v.instance:
                emittable.set(v.linkage, true)
            vi += 1
        visits.push(module_visits)
        mi += 1

    # The analyzer ran before lowering, so its instantiation/validation of a
    # specialization does not depend on which call site lowering reached first.
    # Recompute the classification from the creation graph.
    validate_spec_creation_graph(spec_infos)

    var spec_keys = spec_infos.keys()
    while true:
        let kp = spec_keys.next() else:
            break
        let key = unsafe: read(kp)
        let info_ptr = spec_infos.get(key)
        if info_ptr == null:
            continue
        let info = unsafe: read(info_ptr)
        let dk = spec_owner_key(info.owner_module, info.decl_key)
        var list = vec.Vec[str].create()
        let existing = specs_by_decl.get(dk)
        if existing != null:
            list = unsafe: read(existing)
        list.push(key)
        specs_by_decl.set(dk, list)
        emittable.set(key, true)

    var per_module = vec.Vec[vec.Vec[ir.Function]].create()
    mi = 0
    while mi < analyses.len:
        per_module.push(vec.Vec[ir.Function].create())
        mi += 1

    var emitted = map_mod.Map[str, bool].create()
    var setup_reached = map_mod.Map[str, bool].create()
    var first_pass = true
    var changed = true
    while changed:
        changed = false
        mi = 0
        while mi < analyses.len:
            let visits_ptr = visits.get(mi) else:
                break
            if first_pass:
                # The host's setup loop has already lowered this module's
                # constants/globals/synthetics when its declaration walk starts,
                # so instances created there are available from this visit on.
                let setup_analysis = unsafe: read(analyses.data + mi)
                setup_reached.set(setup_analysis.module_name, true)
            let module_visits = unsafe: read(visits_ptr)
            var vi: ptr_uint = 0
            while vi < module_visits.len():
                let vp = module_visits.get(vi) else:
                    break
                let v = unsafe: read(vp)
                if v.instance:
                    let list_ptr = specs_by_decl.get(v.owner_key)
                    if list_ptr != null:
                        let list = unsafe: read(list_ptr)
                        var picked = vec.Vec[ir.Function].create()
                        var pkeys = vec.Vec[str].create()
                        var li: ptr_uint = 0
                        while li < list.len():
                            let kp = list.get(li) else:
                                break
                            let key = unsafe: read(kp)
                            if not emitted.contains(key):
                                let info_ptr = spec_infos.get(key)
                                if info_ptr != null:
                                    let info = unsafe: read(info_ptr)
                                    if spec_creator_ready(
                                        info,
                                        ref_of(emittable),
                                        ref_of(emitted),
                                        ref_of(setup_reached)
                                    ):
                                        let fp = all_by_linkage.get(key)
                                        if fp != null:
                                            picked.push(unsafe: read(fp))
                                            pkeys.push(info.args_key)
                            li += 1
                        # Insertion sort by the host's type-argument key.
                        var si: ptr_uint = 1
                        while si < picked.len():
                            var j = si
                            while j > 0:
                                let a_ptr = pkeys.get(j - 1) else:
                                    break
                                let b_ptr = pkeys.get(j) else:
                                    break
                                var a: str
                                var b: str
                                unsafe:
                                    a = read(a_ptr)
                                    b = read(b_ptr)
                                if include_scan.str_less_than(a, b):
                                    break
                                picked.swap(j - 1, j)
                                pkeys.swap(j - 1, j)
                                j -= 1
                            si += 1
                        var pi: ptr_uint = 0
                        while pi < picked.len():
                            let fp = picked.get(pi) else:
                                break
                            var f = unsafe: read(fp)
                            if not emitted.contains(f.linkage_name):
                                emitted.set(f.linkage_name, true)
                                push_module_function(ref_of(per_module), mi, f)
                                changed = true
                            pi += 1
                else:
                    if not emitted.contains(v.linkage):
                        let fp = all_by_linkage.get(v.linkage)
                        if fp != null:
                            emitted.set(v.linkage, true)
                            push_module_function(ref_of(per_module), mi, unsafe: read(fp))
                            changed = true
                            if v.is_main and not emitted.contains("main"):
                                let mp = all_by_linkage.get("main")
                                if mp != null:
                                    emitted.set("main", true)
                                    push_module_function(ref_of(per_module), mi, unsafe: read(mp))
                vi += 1
            mi += 1
        first_pass = false

    # Leftovers: functions from `when`-expanded declarations and any fragment
    # function the declaration walk does not name (kept in creation order).
    mi = 0
    while mi < analyses.len:
        let frag = unsafe: read(fragments.data + mi)
        var fi: ptr_uint = 0
        while fi < frag.functions.len:
            var f: ir.Function
            unsafe:
                f = read(frag.functions.data + fi)
            if not emitted.contains(f.linkage_name):
                emitted.set(f.linkage_name, true)
                push_module_function(ref_of(per_module), mi, f)
            fi += 1
        mi += 1

    var result = vec.Vec[ir.Function].create()
    mi = 0
    while mi < per_module.len():
        let mf_ptr = per_module.get(mi) else:
            break
        let module_functions = unsafe: read(mf_ptr)
        var fi: ptr_uint = 0
        while fi < module_functions.len():
            let fp = module_functions.get(fi) else:
                break
            result.push(unsafe: read(fp))
            fi += 1
        mi += 1
    return result


## Propagate the analyzer-created (`body_validated`) and pre-instantiated
## classifications through the specialization creation graph.
function validate_spec_creation_graph(spec_infos: ref[map_mod.Map[str, lowering.SpecInfo]]) -> void:
    var spec_key_list = vec.Vec[str].create()
    var spec_key_iter = read(spec_infos).keys()
    while true:
        let kp = spec_key_iter.next() else:
            break
        spec_key_list.push(unsafe: read(kp))
    var bv_changed = true
    while bv_changed:
        bv_changed = false
        var ski: ptr_uint = 0
        while ski < spec_key_list.len():
            let kp = spec_key_list.get(ski) else:
                break
            let key = unsafe: read(kp)
            let info_ptr = read(spec_infos).get(key)
            if info_ptr != null:
                var info = unsafe: read(info_ptr)
                if not info.body_validated:
                    var analyzed = false
                    var ri: ptr_uint = 0
                    while ri < info.reachers.len():
                        let rp = info.reachers.get(ri) else:
                            break
                        let reacher = unsafe: read(rp)
                        if reacher.len == 0:
                            analyzed = true
                        else:
                            let cp = read(spec_infos).get(reacher)
                            if cp == null:
                                analyzed = true
                            else if unsafe: read(cp).body_validated:
                                analyzed = true
                        ri += 1
                    if analyzed:
                        info.body_validated = true
                        read(spec_infos).set(key, info)
                        bv_changed = true
            ski += 1
    var pre_changed = true
    while pre_changed:
        pre_changed = false
        var pki: ptr_uint = 0
        while pki < spec_key_list.len():
            let kp = spec_key_list.get(pki) else:
                break
            let key = unsafe: read(kp)
            let info_ptr = read(spec_infos).get(key)
            if info_ptr != null:
                var info = unsafe: read(info_ptr)
                var pre = info.pre_instantiated
                var ri2: ptr_uint = 0
                while ri2 < info.reachers.len():
                    let rp = info.reachers.get(ri2) else:
                        break
                    let reacher = unsafe: read(rp)
                    if reacher.len == 0:
                        pre = true
                    else:
                        let cp = read(spec_infos).get(reacher)
                        if cp == null:
                            pre = true
                        else if unsafe: read(cp).body_validated:
                            pre = true
                    ri2 += 1
                if pre != info.pre_instantiated:
                    info.pre_instantiated = pre
                    read(spec_infos).set(key, info)
                    pre_changed = true
            pki += 1


## Append the declarations of a module-level `when`'s selected branch to `out`.
function append_selected_when_decls(
    ctx: ref[lowering.LoweringContext],
    discriminant: ptr[ast.Expr],
    branches: span[ast.WhenDeclBranch],
    dest: ref[vec.Vec[ast.Decl]]
) -> void:
    match const_eval.try_evaluate_const_expr(ctx, discriminant):
        Option.some as dv:
            var bi: ptr_uint = 0
            var found = false
            while bi < branches.len and not found:
                let br = unsafe: read(branches.data + bi)
                match const_eval.try_evaluate_const_expr(ctx, br.pattern):
                    Option.some as pv:
                        if comptime.const_values_eq(dv.value, pv.value):
                            var ddi: ptr_uint = 0
                            while ddi < br.body.len:
                                unsafe:
                                    dest.push(read(br.body.data + ddi))
                                ddi += 1
                            found = true
                    Option.none:
                        pass
                bi += 1
        Option.none:
            pass


## The host's per-module setup order (`lower_modules`): `lower_constants`, then
## `lower_globals` (vars and events), then the type/opaque declarations, then
## `lower_functions`.  Proc symbols are allocated while lowering, so this pass
## order is observable in the generated names.
function decl_lowering_pass(d: ast.Decl) -> ptr_uint:
    match d:
        ast.Decl.decl_const:
            return 0
        ast.Decl.decl_var:
            return 1
        ast.Decl.decl_event:
            return 1
        ast.Decl.decl_function:
            return 3
        ast.Decl.decl_extending_block:
            return 3
        _:
            return 2


public function lower_module(
    analysis: analyzer.Analysis,
    program_returns: ref[map_mod.Map[str, types.Type]],
    program_async: ref[map_mod.Map[str, bool]],
    prelude_arm_field_types: ref[map_mod.Map[str, types.Type]],
    is_root: bool,
    program_analyses: span[analyzer.Analysis],
    loaded_modules: span[loader.LoadedModule],
    gen_instances: ref[map_mod.Map[str, lowering.GenericReceiver]],
    monomorphized: ref[vec.Vec[ir.StructDecl]],
    monomorphized_variants: ref[vec.Vec[ir.VariantDecl]],
    pending_synthetic_structs: ref[vec.Vec[ir.StructDecl]],
    synthetic_functions: ref[vec.Vec[ir.Function]],
    synthetic_enums: ref[vec.Vec[ir.EnumDecl]],
    emitted_functions: ptr[vec.Vec[ir.Function]],
    emitted_structs: ptr[vec.Vec[ir.StructDecl]],
    emitted_constants: ptr[vec.Vec[ir.Constant]],
    spec_infos: ref[map_mod.Map[str, lowering.SpecInfo]],
    expanded_decls: ref[map_mod.Map[str, span[ast.Decl]]]
) -> ir.Program:
    var ctx = create_lowering_context(
        analysis,
        ptr_of(read(program_returns)),
        ptr_of(read(program_async)),
        ptr_of(read(prelude_arm_field_types)),
        program_analyses,
        loaded_modules,
        ptr_of(read(gen_instances)),
        ptr_of(read(spec_infos))
    )
    ctx.is_root_module = is_root
    ctx.pending_emitted_functions = emitted_functions
    ctx.pending_emitted_structs = emitted_structs
    ctx.pending_emitted_constants = emitted_constants
    lowering.collect_foreign_functions(ref_of(ctx), analysis.source_file.declarations)
    lowering.collect_function_returns(ref_of(ctx), analysis.source_file.declarations)
    lowering.collect_variants(ref_of(ctx), analysis.source_file.declarations)
    lowering.install_prelude_variants(ref_of(ctx))
    var functions = vec.Vec[ir.Function].create()
    var enums = vec.Vec[ir.EnumDecl].create()
    var structs = vec.Vec[ir.StructDecl].create()
    var unions = vec.Vec[ir.UnionDecl].create()
    var variants = vec.Vec[ir.VariantDecl].create()
    var globals = vec.Vec[ir.Global].create()
    var constants = vec.Vec[ir.Constant].create()
    var module_static_asserts = vec.Vec[ir.StaticAssert].create()
    # Module-level `when` blocks expand in place to the declarations of their
    # selected branch, so those declarations keep their source order (the host
    # emits them inline rather than deferring them to the end of the module).
    var decls = vec.Vec[ast.Decl].create()
    var wi: ptr_uint = 0
    while wi < analysis.source_file.declarations.len:
        var wd: ast.Decl
        unsafe:
            wd = read(analysis.source_file.declarations.data + wi)
        match wd:
            ast.Decl.decl_when as w:
                append_selected_when_decls(ctx, w.discriminant, w.branches, ref_of(decls))
            _:
                decls.push(wd)
        wi += 1
    expanded_decls.set(analysis.module_name, decls.as_span())

    # The host's `lower_globals` ensures every module-level event's runtime
    # before any struct declaration lowers, so the synthetic structs' creation
    # order leads with the module events in declaration order, then each
    # struct's own events in struct order.
    var evi: ptr_uint = 0
    while evi < decls.len():
        let ev_decl_ptr = decls.get(evi) else:
            break
        match unsafe: read(ev_decl_ptr):
            ast.Decl.decl_event as ev:
                let _ = lowering.ensure_event_runtime(ref_of(ctx), "", ev.name)
            _:
                pass
        evi += 1

    var phase: ptr_uint = 0
    while phase < 4:
        var i: ptr_uint = 0
        while i < decls.len():
            var d: ast.Decl
            let d_ptr = decls.get(i) else:
                break
            unsafe:
                d = read(d_ptr)
            if decl_lowering_pass(d) != phase:
                i += 1
                continue
            match d:
                ast.Decl.decl_function as fun:
                    lower_module_function_decl(ref_of(ctx), d, is_root, ref_of(functions))
                ast.Decl.decl_enum as en:
                    enums.push(lowering.lower_enum_decl(ref_of(ctx), en.name, en.backing_type, en.enum_members, false))
                ast.Decl.decl_flags as fl:
                    enums.push(lowering.lower_enum_decl(ref_of(ctx), fl.name, fl.backing_type, fl.flags_members, true))
                ast.Decl.decl_static_assert as sa:
                    module_static_asserts.push(lowering.lower_static_assert(ref_of(ctx), sa.condition, sa.message))
                ast.Decl.decl_struct as s:
                    lower_module_struct_decl(ref_of(ctx), d, ref_of(structs))
                ast.Decl.decl_union as u:
                    unions.push(lowering.lower_union_decl(ref_of(ctx), u.name, u.union_fields))
                ast.Decl.decl_variant as vr:
                    if vr.type_params.len == 0:
                        variants.push(lowering.lower_variant_decl(ref_of(ctx), vr.name, vr.variant_arms))
                ast.Decl.decl_extending_block as ex:
                    lowering.lower_extending_block(ctx, ref_of(functions), ex.type_name, ex.methods)
                ast.Decl.decl_var as v:
                    lower_module_var_decl(ref_of(ctx), d, ref_of(globals))
                ast.Decl.decl_const as c:
                    lower_module_const_decl(ref_of(ctx), d, ref_of(constants))
                ast.Decl.decl_event as ev:
                    lower_module_event_decl(ref_of(ctx), d, ref_of(globals))
                ast.Decl.decl_when as w:
                    # Expanded by the pre-pass above; unreachable here.
                    pass
                _:
                    pass
            i += 1
        phase += 1

    # Concrete generic struct instances are not part of the IR's declaration
    # sections (host parity: its C backend collects them from the types in
    # use).  Hand them to the driver, which exposes them to the C backend
    # through `Program.monomorphized_structs`.
    var gs_iter = ctx.generic_struct_decls.values()
    while true:
        let gs_ptr = gs_iter.next() else:
            break
        monomorphized.push(unsafe: read(gs_ptr))
    var ps_iter = ctx.pending_proc_structs.iter()
    while true:
        let ps_ptr = ps_iter.next() else:
            break
        monomorphized.push(unsafe: read(ps_ptr))

    # Synthetic value structs join `Program.structs` after every module's
    # declarations, in creation order (the host's `assemble_modules` appends its
    # single `synthetic_structs` list last), so they bypass the per-module
    # fragment.
    var ss_iter = ctx.pending_synthetic_structs.iter()
    while true:
        let ss_ptr = ss_iter.next() else:
            break
        pending_synthetic_structs.push(unsafe: read(ss_ptr))

    # Append any monomorphized generic functions from the specialization cache.
    var spec_iter = ctx.specialization_cache.values()
    while true:
        let spec_ptr = spec_iter.next() else:
            break
        functions.push(unsafe: read(spec_ptr))

    # Synthetic proc/worker functions go to the program-level creation-ordered
    # tail (the host's `@artifacts.synthetic_functions`, appended after every
    # module's functions by `assemble_modules`), not to this module's list.
    var sf_iter = ctx.pending_synthetic_functions.iter()
    while true:
        let sf_ptr = sf_iter.next() else:
            break
        synthetic_functions.push(unsafe: read(sf_ptr))

    # Synthetic enums (the builtin `EventError`) join the program-level list;
    # `lower()` appends them after every module's enums.
    var se_iter = ctx.pending_synthetic_enums.iter()
    while true:
        let se_ptr = se_iter.next() else:
            break
        synthetic_enums.push(unsafe: read(se_ptr))

    var ds_iter = ctx.pending_dyn_structs.iter()
    while true:
        let ds_ptr = ds_iter.next() else:
            break
        monomorphized.push(unsafe: read(ds_ptr))

    var dyn_constants = vec.Vec[ir.Constant].create()
    var dci: ptr_uint = 0
    while dci < ctx.pending_dyn_constants.len():
        let dc_ptr = ctx.pending_dyn_constants.get(dci) else:
            break
        dyn_constants.push(unsafe: read(dc_ptr))
        dci += 1

    # Append dyn vtable constants to the main constants list so they are
    # emitted into the C output (previously they were collected but never
    # written, causing `mt_vtable_..._Shape undeclared`).
    var di: ptr_uint = 0
    while di < dyn_constants.len():
        let c_ptr = dyn_constants.get(di) else:
            break
        constants.push(unsafe: read(c_ptr))
        di += 1

    # Concrete Option/Result instances are kept outside the IR's `:variants`
    # section (host parity) and handed to the driver for the C backend.
    var gv_iter = ctx.pending_generic_variants.iter()
    while true:
        let gv_ptr = gv_iter.next() else:
            break
        monomorphized_variants.push(unsafe: read(gv_ptr))

    # A fragment is an intermediate: the shared type store keeps growing while
    # later modules lower, so a table captured here would be a stale span.  The
    # assembled program carries the finished table (see `lowering.lower`).
    return ir.Program(
        module_name = analysis.module_name,
        includes = span[ir.Include](),
        constants = constants.as_span(),
        globals = globals.as_span(),
        opaques = span[ir.OpaqueDecl](),
        structs = structs.as_span(),
        unions = unions.as_span(),
        enums = enums.as_span(),
        variants = variants.as_span(),
        static_asserts = module_static_asserts.as_span(),
        functions = functions.as_span(),
        type_aliases = span[ir.TypeAlias](),
        source_path = "",
        external_structs = ctx.pending_external_structs.as_span(),
        arena = null,
    )


## Returns true for functions that can be lowered directly (non-generic and
## not an external/foreign/async declaration — async functions take the CPS
## path in `lower_async_fn`).
function lower_module_function_decl(
    ctx: ref[lowering.LoweringContext],
    d: ast.Decl,
    is_root: bool,
    functions: ref[vec.Vec[ir.Function]]
) -> void:
    match d:
        ast.Decl.decl_function as fun:
            if fun.is_async:
                # All async functions use full CPS lowering (frame struct,
                # resume state machine, vtable, constructor).  A 0-await
                # function is the single-state case.  An async `main`
                # constructor carries the host's `__async_main` linkage
                # (`function_binding_c_name`, utils.rb:1089-1092).
                let link_base = if is_root and fun.name == "main": naming.qualified_c_name(
                    ctx.module_name,
                    "__async_main"
                ) else: naming.qualified_c_name(ctx.module_name, fun.name)
                async_cps.lower_async_fn(
                    ctx,
                    fun.name,
                    link_base,
                    Option[types.Type].none,
                    false,
                    fun.method_params,
                    fun.return_type,
                    fun.body,
                    functions,
                    is_root and fun.name == "main"
                )
                if is_root and fun.name == "main":
                    match async_cps.build_async_main_entrypoint(ctx, fun.name):
                        Option.some as entry:
                            functions.push(entry.value)
                        Option.none:
                            pass
            else if lowerable_function(fun.type_params, fun.body):
                functions.push(lowering.lower_function(
                    ctx,
                    fun.name,
                    fun.method_params,
                    fun.return_type,
                    fun.body,
                    false,
                    fun.visibility
                ))
                if is_root and fun.name == "main":
                    match lowering.build_root_main_entrypoint(ctx, fun.name, fun.method_params):
                        Option.some as entry:
                            functions.push(entry.value)
                        Option.none:
                            pass
        _:
            pass


function lower_module_struct_decl(
    ctx: ref[lowering.LoweringContext],
    d: ast.Decl,
    structs: ref[vec.Vec[ir.StructDecl]]
) -> void:
    match d:
        ast.Decl.decl_struct as s:
            # Skip generic structs — only their concrete specializations
            # (emitted by `ensure_generic_struct_decl`) carry resolved
            # field types.  Structs with only lifetime parameters (`@a`)
            # are not generic in the monomorphization sense and should
            # be emitted directly.
            if not tasks.has_non_lifetime_type_params(s.type_params):
                match lowering.lower_struct_decl(ctx, s.name, s.packed, s.alignment, Option[str].none, s.name):
                    Option.some as sd:
                        structs.push(sd.value)
                    Option.none:
                        pass
                lowering.lower_nested_struct_decls(ctx, s.nested_types, s.name, s.name, structs)
        _:
            pass


function lower_module_var_decl(
    ctx: ref[lowering.LoweringContext],
    d: ast.Decl,
    globals: ref[vec.Vec[ir.Global]]
) -> void:
    match d:
        ast.Decl.decl_var as v:
            var g_ty = types.primitive("void")
            if v.var_type != null:
                var vt: ptr[ast.TypeRef] = unsafe: ptr[ast.TypeRef]<-v.var_type
                # `qualify_type` (not just `resolve_type_ref`) registers the
                # generic instance and produces the monomorphized C name, so a
                # module-level `var m: Map[str, str]` declares
                # `std_map_Map_str_str m` rather than the unspecialized
                # `std_map_Map` (which is never defined).
                g_ty = lowering.qualify_type(ctx, lowering.resolve_type_ref(ctx, vt))
            # A tuple in the global's declared type registers its value
            # struct even when no literal mentions it (the host's
            # `ensure_registered_storage_type_types`).
            var g_seen = map_mod.Map[str, bool].create()
            lowering.ensure_storage_type_tuples(ctx, g_ty, ref_of(g_seen))
            # A top-level `var` initializer must be static-storage-safe (the
            # analyzer enforces this), so it lowers to a C static initializer.
            # A no-capture `proc` initializer, for example, becomes a static
            # aggregate of function pointers — without it the proc's invoke
            # pointer stays null and calling it segfaults.
            var g_val = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = g_ty))
            if v.value != null:
                # A top-level initializer is evaluated in an empty local
                # scope: clear any locals left over from a previously-lowered
                # function so a no-capture `proc` initializer is not treated
                # as capturing stale bindings.
                ctx.locals.clear()
                # A compile-time-known initializer folds to its constant value
                # — a literal, a constant reference (an imported module's
                # constant included) or a `const` function/method call — as the
                # host's `lower_static_storage_initializer` folds
                # `compile_time_const_value` through `lower_compile_time_literal`.
                # Anything else lowers as an ordinary expression.
                var init_env = map_mod.Map[str, ptr[ir.Expr]].create()
                match const_eval.try_const_typed_value_ir(ctx, unsafe: ptr[ast.Expr]<-v.value, ref_of(init_env), g_ty):
                    Option.some as g_cv:
                        g_val = lowering.alloc_expr(const_eval.coerce_const_value(ctx, unsafe: read(g_cv.value), g_ty))
                    Option.none:
                        g_val = lowering.lower_expr(ctx, unsafe: ptr[ast.Expr]<-v.value)
                        # A literal initializer takes the global's declared type, as
                        # the host's contextual literal inference gives it one
                        # (`var shorts: short = 0` is a `short` literal, not `int`).
                        g_val = lowering.int_literal_to_context_type(unsafe: ptr[ast.Expr]<-v.value, g_ty, g_val)
                        g_val = lowering.float_literal_to_context_type(unsafe: ptr[ast.Expr]<-v.value, g_ty, g_val)
                        g_val = lowering.string_literal_to_context_type(unsafe: ptr[ast.Expr]<-v.value, g_ty, g_val)
                        g_val = lowering.null_literal_to_context_type(unsafe: ptr[ast.Expr]<-v.value, g_ty, g_val)
            globals.push(ir.Global(
                name = v.name,
                linkage_name = naming.qualified_c_name(ctx.module_name, v.name),
                ty = g_ty,
                value = g_val
            ))
        _:
            pass


function lower_module_const_decl(
    ctx: ref[lowering.LoweringContext],
    d: ast.Decl,
    constants: ref[vec.Vec[ir.Constant]]
) -> void:
    match d:
        ast.Decl.decl_const as c:
            var c_ty = lowering.resolve_type_ref(ctx, c.const_type)
            # A tuple in the constant's declared type registers its value
            # struct, as the host's `ensure_registered_storage_type_types`
            # does before the value is lowered.
            var c_seen = map_mod.Map[str, bool].create()
            lowering.ensure_storage_type_tuples(ctx, c_ty, ref_of(c_seen))
            let val_ptr = c.value
            # The host's `lower_constants` routes an expression-list or
            # call/specialization constant value through
            # `lower_const_value_literal` rather than the storage-initializer
            # path.
            var const_value_literal_path = false
            if val_ptr != null:
                match unsafe: read(ptr[ast.Expr]<-val_ptr):
                    ast.Expr.expr_expression_list:
                        const_value_literal_path = true
                    ast.Expr.expr_call:
                        const_value_literal_path = true
                    ast.Expr.expr_specialization:
                        const_value_literal_path = true
                    _:
                        pass
            # Type constants (->type) are compile-time only; they don't
            # have a C representation (mirrors Ruby).
            var is_type_meta = false
            match c_ty:
                types.Type.ty_type_meta:
                    is_type_meta = true
                _:
                    pass
            if is_type_meta:
                pass
            else if val_ptr == null:
                var bv = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = c_ty))
                if c.block_body != null:
                    var empty_env = map_mod.Map[str, ptr[ir.Expr]].create()
                    match const_eval.try_const_value_body(ctx, c.block_body, ref_of(empty_env)):
                        Option.some as body_val:
                            bv = lowering.alloc_expr(const_eval.coerce_const_value(
                                ctx,
                                unsafe: read(body_val.value),
                                c_ty
                            ))
                        Option.none:
                            pass
                constants.push(ir.Constant(
                    name = c.name,
                    linkage_name = naming.qualified_c_name(ctx.module_name, c.name),
                    ty = c_ty,
                    value = bv,
                    line = c.line,
                    path = ctx.analysis.source_path
                ))
            else:
                # `const EQ: bool = A == B` over constant aggregates folds
                # at compile time; a C function call is not a constant
                # initializer.
                var folded: Option[bool] = Option[bool].none
                match c_ty:
                    types.Type.ty_primitive as cp:
                        if cp.name == "bool":
                            folded = const_eval.try_const_equality(ctx, unsafe: ptr[ast.Expr]<-val_ptr)
                    _:
                        pass
                match folded:
                    Option.some as fb:
                        constants.push(ir.Constant(
                            name = c.name,
                            linkage_name = naming.qualified_c_name(ctx.module_name, c.name),
                            ty = c_ty,
                            value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = fb.value, ty = c_ty)),
                            line = c.line,
                            path = ctx.analysis.source_path
                        ))
                    Option.none:
                        var const_env = map_mod.Map[str, ptr[ir.Expr]].create()
                        match const_eval.try_const_typed_value_ir(
                            ctx,
                            unsafe: ptr[ast.Expr]<-val_ptr,
                            ref_of(const_env),
                            c_ty
                        ):
                            Option.some as cv2:
                                var c_val = unsafe: read(cv2.value)
                                # The host's `lower_const_value_literal` path
                                # (an expression-list or call constant) emits a
                                # tuple constant as an `IR::ArrayLiteral`.
                                if const_value_literal_path:
                                    match comptime.const_tuple_array_literal(c_val, c_ty):
                                        Option.some as al:
                                            c_val = al.value
                                        Option.none:
                                            pass
                                # A plain expression constant takes the host's
                                # `lower_compile_time_literal` path: the folded
                                # value is typed but *not* width-masked
                                # (`~268435455` stays `-268435456` in a `uint`),
                                # unlike the `lower_const_value_literal` paths.
                                var coerced: ptr[ir.Expr]
                                if const_value_literal_path:
                                    coerced = lowering.alloc_expr(const_eval.coerce_const_value(ctx, c_val, c_ty))
                                else:
                                    # `lower_compile_time_literal` returns nil when a
                                    # leaf value cannot be represented (an integer for
                                    # a `char` field, for instance); the host then
                                    # falls back to rewriting the imported constant
                                    # reference to its declaration initializer and
                                    # lowering that AST with the expected type.
                                    if not comptime.const_value_ir_representable(ctx, c_val, c_ty):
                                        match const_eval.lower_imported_const_initializer(
                                            ctx,
                                            unsafe: ptr[ast.Expr]<-val_ptr,
                                            c_ty
                                        ):
                                            Option.some as iv:
                                                c_val = unsafe: read(iv.value)
                                            Option.none:
                                                pass
                                    coerced = lowering.alloc_expr(const_eval.retype_const_literal(c_val, c_ty))
                                constants.push(ir.Constant(
                                    name = c.name,
                                    linkage_name = naming.qualified_c_name(ctx.module_name, c.name),
                                    ty = c_ty,
                                    value = coerced,
                                    line = c.line,
                                    path = ctx.analysis.source_path
                                ))
                            Option.none:
                                constants.push(ir.Constant(
                                    name = c.name,
                                    linkage_name = naming.qualified_c_name(ctx.module_name, c.name),
                                    ty = c_ty,
                                    value = lowering.lower_expr(ctx, unsafe: ptr[ast.Expr]<-val_ptr),
                                    line = c.line,
                                    path = ctx.analysis.source_path
                                ))
        _:
            pass


function lower_module_event_decl(
    ctx: ref[lowering.LoweringContext],
    d: ast.Decl,
    globals: ref[vec.Vec[ir.Global]]
) -> void:
    match d:
        ast.Decl.decl_event as ev:
            var info = lowering.ensure_event_runtime(ctx, "", ev.name)
            # The global's declared type is the event itself (`Types::Event`),
            # whose C name is the runtime struct; the linkage name is the
            # module-qualified event name.
            var ev_payload: ptr[types.Type]? = null
            if info.has_payload:
                ev_payload = types.alloc_type(info.payload_type)
            let ev_ty = types.event_type(
                name = ev.name,
                capacity = info.capacity,
                payload_type = ev_payload,
                linkage_name = info.event_c_name
            )
            let ev_zero = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = ev_ty))
            globals.push(ir.Global(
                name = ev.name,
                linkage_name = naming.qualified_c_name(ctx.module_name, ev.name),
                ty = ev_ty,
                value = ev_zero
            ))
        _:
            pass


function lowerable_function(type_params: span[ast.TypeParam], body: ptr[ast.Stmt]?) -> bool:
    if type_params.len > 0:
        return false
    if body == null:
        return false
    return true


## Collect every non-raw module's `opaque` declarations (host `lower_opaques`):
## each keeps its *declared* name, and its C type is the resolved backing —
## the explicit `= c"..."` C name when present, else the module-qualified name
## the backend's forward declaration defines (`opaque_c_type_name`).  A backing
## that is a plain C identifier is forward-declarable (`typedef struct X X;`);
## raw (`external`) modules' opaques are the headers' own types and their
## fragments are skipped entirely, exactly as the host skips them.
public function collect_opaque_decls(program: loader.Program) -> span[ir.OpaqueDecl]:
    var opaques = vec.Vec[ir.OpaqueDecl].create()
    var mi: ptr_uint = 0
    while mi < program.analyses.len():
        let a_ptr = program.analyses.get(mi) else:
            mi += 1
            continue
        var analysis = unsafe: read(a_ptr)
        if lowering.is_raw_module(analysis.module_kind):
            mi += 1
            continue
        var di: ptr_uint = 0
        while di < analysis.source_file.declarations.len:
            var d: ast.Decl
            unsafe:
                d = read(analysis.source_file.declarations.data + di)
            match d:
                ast.Decl.decl_opaque as op:
                    var linkage = ""
                    match op.c_name:
                        Option.some as cn:
                            linkage = cn.value
                        Option.none:
                            linkage = naming.qualified_c_name(analysis.module_name, op.name)
                    opaques.push(ir.OpaqueDecl(
                        name = op.name,
                        linkage_name = linkage,
                        forward_declarable = naming.is_c_identifier(linkage),
                        source_module = Option[str].some(value = analysis.module_name),
                    ))
                _:
                    pass
            di += 1
        mi += 1
    # Raw (external) modules' forward-declarable opaques (the host's
    # `lower_imported_external_opaques`, `declarations.rb:194-203`): an
    # unnamed external opaque (`opaque X`, no `= c"..."`) keeps its bare C name;
    # a c-named opaque keeps its declared linkage and is not forward-declared.
    var seen_raw = map_mod.Map[str, bool].create()
    var ri: ptr_uint = 0
    while ri < program.analyses.len():
        let ra_ptr = program.analyses.get(ri) else:
            break
        var ra = unsafe: read(ra_ptr)
        if lowering.is_raw_module(ra.module_kind):
            var rdi: ptr_uint = 0
            while rdi < ra.source_file.declarations.len:
                var rd: ast.Decl
                unsafe:
                    rd = read(ra.source_file.declarations.data + rdi)
                match rd:
                    ast.Decl.decl_opaque as rop:
                        if rop.c_name.is_none():
                            let linkage = rop.name
                            if naming.is_c_identifier(linkage) and not seen_raw.contains(linkage):
                                seen_raw.set(linkage, true)
                                opaques.push(ir.OpaqueDecl(
                                    name = rop.name,
                                    linkage_name = linkage,
                                    forward_declarable = true,
                                    source_module = Option[str].some(value = ra.module_name),
                                ))
                    _:
                        pass
                rdi += 1
        ri += 1
    return opaques.as_span()
