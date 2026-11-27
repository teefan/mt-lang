## Method and declaration resolution, extracted from lowering/lowering.mt (Wave 4.2).

import std.map as map_mod
import std.string as string
import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.strings
import mtc.c_naming as naming

import mtc.lowering.lowering as lowering
import mtc.lowering.match as match_mod
import mtc.lowering.tasks as tasks
import mtc.lowering.type_resolution as type_res_mod
import mtc.lowering.monomorphized as monomorphized
import mtc.lowering.type_helpers as type_helpers


public function find_decl_c_name_cross(
    analysis: analyzer.Analysis,
    tv: types.Type,
    type_name: str,
    analyses: span[analyzer.Analysis]
) -> Option[str]:
    # First try the current module's declarations.
    match find_decl_c_name(analysis, type_name):
        Option.some as cn:
            return Option[str].some(value = cn.value)
        Option.none:
            pass
    # If the type is an imported type, follow the import chain.
    match tv:
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            # std.c.* raw ABI types — they ARE the C types.
            if im_bp.module_name.starts_with("std.c."):
                return find_decl_c_name_in_module(im_bp.module_name, im_bp.name, analyses)
            # Non-std.c imported types may be type aliases themselves
            # (e.g. `type uv_handle_t = c.uv_handle_t` in `std.libuv`).
            # Follow the chain through the imported module's type aliases.
            var found_a: analyzer.Analysis
            var has_a = false
            var ai: ptr_uint = 0
            while ai < analyses.len:
                var a: analyzer.Analysis
                unsafe:
                    a = read(analyses.data + ai)
                if a.module_name == im_bp.module_name:
                    found_a = a
                    has_a = true
                    break
                ai += 1
            if has_a and found_a.type_alias_types.contains(im_bp.name):
                let resolved_ptr = found_a.type_alias_types.get(im_bp.name) else:
                    fatal(c"lowering: chained type alias lookup inconsistency")
                return find_decl_c_name_cross(analysis, unsafe: read(resolved_ptr), im_bp.name, analyses)
        _:
            pass
    return Option[str].none


## Look up the backing c_name of a type in a specific module's analysis.


public function find_decl_c_name_in_module(module_name: str, type_name: str, analyses: span[analyzer.Analysis]) -> Option[str]:
    var ai: ptr_uint = 0
    while ai < analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(analyses.data + ai)
        if a.module_name == module_name:
            return find_decl_c_name(a, type_name)
        ai += 1
    return Option[str].none


## Look up the backing C type name (`= c"..."`) for a struct, opaque, or union
## declaration by scanning the analysis' source file.  Returns `Option[str].none`
## when no backing name was provided.


public function find_decl_c_name(analysis: analyzer.Analysis, type_name: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(analysis.source_file.declarations.data + i)
        match d:
            ast.Decl.decl_struct as s:
                if s.name == type_name:
                    return s.c_name
            ast.Decl.decl_opaque as op:
                if op.name == type_name:
                    return op.c_name
            ast.Decl.decl_union as u:
                if u.name == type_name:
                    return u.c_name
            _:
                pass
        i += 1
    return Option[str].none


## Lower a checked program to IR.  Every non-external module is lowered in
## dependency-first order (the root module is the last retained analysis) and the
## fragments are concatenated into one program — mirroring Ruby's
## `lower_modules` / `assemble_modules`.


public function find_declaring_module(ctx: ref[lowering.LoweringContext], name: str) -> Option[str]:
    # A locally-declared type takes precedence: the caller qualifies against
    # ctx.module_name.  (Same precedence as `imported_type_module`.)
    if ctx.analysis.type_names.contains(name) or ctx.analysis.structs.contains(name) or type_res_mod.type_declared_in_source(
        ctx.analysis,
        name
    ):
        return Option[str].none
    # Only a unique owner is usable: with the same simple name in several
    # modules (e.g. `Field` in both mtc.parser.ast and mtc.ir) picking one
    # would mis-attribute the type.
    var found: str = ""
    var ambiguous = false
    var i: ptr_uint = 0
    while i < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + i)
        if a.module_name != ctx.module_name and (a.type_names.contains(name) or a.structs.contains(name)):
            if found.len == 0:
                found = a.module_name
            else if found != a.module_name:
                ambiguous = true
        i += 1
    if found.len > 0 and not ambiguous:
        return Option[str].some(value = found)
    return Option[str].none


## The owner module of a bare type `name` when it is defined in an imported
## module (struct, variant, or enum) rather than the current one.  Used by
## `qualify_type` so an imported bare type name qualifies against its defining
## module instead of being mis-attributed to the current module.  Returns none
## when the name is defined locally or not found in any import.


public function resolve_method_return_from_import(
    ctx: ref[lowering.LoweringContext],
    module_name: str,
    sig: analyzer.FnSig,
    receiver_ty: types.Type
) -> types.Type:
    var ret = sig.return_type
    if not sig.has_return_type:
        ret = ctx.void_ty
    match ret:
        types.Type.ty_named as rn:
            let rn_np = unsafe: read(rn.payload)
            match receiver_ty:
                types.Type.ty_imported as rim:
                    let rim_bp = unsafe: read(rim.payload)
                    if rim_bp.args.len > 0:
                        ret = types.imported_type(module_name = module_name, name = rn_np.name, args = rim_bp.args)
                    else:
                        ret = types.imported_type(
                            module_name = module_name,
                            name = rn_np.name,
                            args = span[types.Type]()
                        )
                _:
                    ret = types.imported_type(module_name = module_name, name = rn_np.name, args = span[types.Type]())
        _:
            pass
    return lowering.qualify_type(ctx, ret)


public function generic_struct_field_type(
    ctx: ref[lowering.LoweringContext],
    struct_name: str,
    concrete_args: span[types.Type],
    field_name: str,
    owner_module: str
) -> Option[types.Type]:
    let unqualified = lowering.generic_struct_c_name(struct_name, concrete_args)
    let decl_ptr = ctx.caches.generic_structs.get(unqualified)
    if decl_ptr != null:
        unsafe:
            let decl = read(decl_ptr)
            var fi: ptr_uint = 0
            while fi < decl.fields.len:
                let f = read(decl.fields.data + fi)
                if f.name == field_name:
                    return Option[types.Type].some(value = f.ty)
                fi += 1
    # A concrete generic struct instance is registered under the name of the
    # module that *defines* the struct (`std_net_sync_SyncValue_uint`), not the
    # caller's module.
    let decl_module = if owner_module.len > 0: owner_module else: ctx.module_name
    let q_ptr = ctx.caches.generic_structs.get(naming.qualified_c_name(decl_module, unqualified))
    if q_ptr != null:
        unsafe:
            let decl = read(q_ptr)
            var fi: ptr_uint = 0
            while fi < decl.fields.len:
                let f = read(decl.fields.data + fi)
                if f.name == field_name:
                    return Option[types.Type].some(value = f.ty)
                fi += 1
    return Option[types.Type].none


public function extract_generic_struct_fields(
    ctx: ref[lowering.LoweringContext],
    module_analysis: analyzer.Analysis,
    struct_name: str,
    concrete_args: span[types.Type]
) -> Option[span[ir.Field]]:
    var found = false
    var ir_fields = vec.Vec[ir.Field].create()
    var di: ptr_uint = 0
    while di < module_analysis.source_file.declarations.len and not found:
        var d: ast.Decl
        unsafe:
            d = read(module_analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_struct as s:
                if s.name == struct_name:
                    found = true
                    var sub = map_mod.Map[str, types.Type].create()
                    var spi: ptr_uint = 0
                    while spi < s.type_params.len and spi < concrete_args.len:
                        unsafe:
                            sub.set(read(s.type_params.data + spi).name, read(concrete_args.data + spi))
                        spi += 1
                    var fi: ptr_uint = 0
                    var saved_type_subst = ctx.type_substitution
                    var saved_analysis = ctx.analysis
                    var saved_module = ctx.module_name
                    ctx.type_substitution = sub
                    # Field types resolve in the struct's OWN module: an
                    # imported generic struct's field (`values: Vec[T]`) must
                    # monomorphize against the modules that module imports.
                    ctx.analysis = module_analysis
                    ctx.module_name = module_analysis.module_name
                    while fi < s.struct_fields.len:
                        var f: ast.Field
                        unsafe:
                            f = read(s.struct_fields.data + fi)
                        let raw_ty = lowering.resolve_field_type_ref(ctx, f.field_type)
                        let field_ty = monomorphized.substitute_type_params(ctx, raw_ty, ref_of(sub))
                        ir_fields.push(ir.Field(name = f.name, ty = lowering.qualify_type(ctx, field_ty)))
                        fi += 1
                    ctx.type_substitution = saved_type_subst
                    ctx.analysis = saved_analysis
                    ctx.module_name = saved_module
            _:
                pass
        di += 1
    if not found:
        return Option[span[ir.Field]].none
    return Option[span[ir.Field]].some(value = ir_fields.as_span())


## Ensure a concrete declaration exists for a user-defined generic variant
## instance (`Outcome[int, EngineError]` from `engine.types`).  Mirrors
## `extract_generic_struct_fields`: the arms' field types resolve in the
## DECLARING module with the type parameters substituted, and the instance is
## pushed onto `pending_generic_variants` — the collection that reaches
## `Program.monomorphized_variants`.  Without it a generic variant instance is
## referenced by its mangled C name but never declared.
## Returns true when `variant_name` is a generic variant declared in
## `module_analysis`; `decl_name` is the instance's C name.


public function iface_method_return_type(ctx: ref[lowering.LoweringContext], recv_ty: types.Type, method_name: str) -> types.Type:
    match recv_ty:
        types.Type.ty_dyn as d:
            let d_bp = unsafe: read(d.payload)
            match lowering.find_interface_analysis(ctx, d_bp.iface):
                Option.some as ia:
                    var mi: ptr_uint = 0
                    while mi < ia.value.methods.len:
                        var m: ast.InterfaceMethod
                        unsafe:
                            m = read(ia.value.methods.data + mi)
                        if m.name == method_name:
                            let ret = m.return_type else:
                                return ctx.void_ty
                            let resolved = lowering.resolve_field_type_ref(ctx, unsafe: read(ptr[ast.TypeRef]<-ret))
                            return lowering.substitute_interface_type_params(resolved, d_bp.args, ia.value.type_params)
                        mi += 1
                Option.none:
                    pass
        _:
            pass
    return ctx.void_ty


## The C type name for a dyn[I] vtable struct: "mt_vtable_" + iface_name.


public function resolve_canonical_hook(ctx: ref[lowering.LoweringContext], t_ty: types.Type, hook: str) -> Option[str]:
    let type_name = lowering.hook_type_name(t_ty) else:
        return Option[str].none
    let key = analyzer.method_key(type_name, hook)
    if ctx.analysis.method_sigs.contains(key):
        return Option[str].some(value = lowering.method_c_name_for_receiver(
            t_ty,
            ctx.module_name,
            type_name,
            hook,
            ast.MethodKind.mk_static
        ))
    var ai: ptr_uint = 0
    while ai < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + ai)
        if a.method_sigs.contains(key):
            return Option[str].some(value = lowering.method_c_name_for_receiver(
                t_ty,
                a.module_name,
                type_name,
                hook,
                ast.MethodKind.mk_static
            ))
        ai += 1
    return Option[str].none


## The base type name used to key a canonical hook lookup (`int`, `str`, or a
## nominal type's name).


public function resolve_primitive_method_info(
    ctx: ref[lowering.LoweringContext],
    type_name: str,
    method_name: str
) -> Option[lowering.MethodInfo]:
    let key = analyzer.method_key(type_name, method_name)
    if ctx.analysis.method_sigs.contains(key):
        let sig_ptr = ctx.analysis.method_sigs.get(key) else:
            return Option[lowering.MethodInfo].none
        let sig = unsafe: read(sig_ptr)
        var ret = sig.return_type
        if not sig.has_return_type:
            ret = ctx.void_ty
        return Option[lowering.MethodInfo].some(value = lowering.MethodInfo(
            c_name = lowering.primitive_method_c_name(type_name, method_name, sig.method_kind == ast.MethodKind.mk_static),
            method_kind = sig.method_kind,
            return_type = lowering.qualify_type(ctx, ret),
            params = sig.params,
            ast_params = lowering.find_method_params_in_source(ctx.analysis.source_file, type_name, method_name),
            is_async = sig.is_async,
        ))
    var ai: ptr_uint = 0
    while ai < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + ai)
        if a.module_name == ctx.module_name:
            ai += 1
            continue
        if a.method_sigs.contains(key):
            let sig_ptr = a.method_sigs.get(key) else:
                ai += 1
                continue
            let sig = unsafe: read(sig_ptr)
            var ret = sig.return_type
            if not sig.has_return_type:
                ret = ctx.void_ty
            return Option[lowering.MethodInfo].some(value = lowering.MethodInfo(
                c_name = lowering.primitive_method_c_name(type_name, method_name, sig.method_kind == ast.MethodKind.mk_static),
                method_kind = sig.method_kind,
                return_type = lowering.qualify_type(ctx, ret),
                params = sig.params,
                ast_params = lowering.find_method_params_in_source(a.source_file, type_name, method_name),
                is_async = sig.is_async,
            ))
        ai += 1
    return Option[lowering.MethodInfo].none


public function resolve_method_info(
    ctx: ref[lowering.LoweringContext],
    receiver_ty: types.Type,
    method_name: str
) -> Option[lowering.MethodInfo]:
    # Auto-deref pointer / ref receivers so a method call on `this` inside an
    # editable method (where `this` is `ptr[T]`) resolves against `T`, not the
    # builtin "ptr" name (which would mis-name the call `<module>_ptr_<method>`).
    var effective_ty = receiver_ty
    if types.is_raw_pointer(effective_ty) or types.is_ref_type(effective_ty):
        effective_ty = types.pointer_element(effective_ty)
    # Primitive / `str` receivers: methods live in a single `extending` block
    # (e.g. `extending str:` in std.str) and use the bare `<type>_<method>` C
    # naming scheme, so resolve them before the nominal path.
    match lowering.primitive_receiver_name(effective_ty):
        Option.some as pn:
            return resolve_primitive_method_info(ctx, pn.value, method_name)
        Option.none:
            pass
    let type_name = lowering.named_type_name(effective_ty) else:
        let gen_var = match_mod.generic_variant_name(effective_ty)
        match gen_var:
            Option.some as gv:
                let key = analyzer.method_key(gv.value, method_name)
                if ctx.analysis.method_sigs.contains(key):
                    let sig_ptr = ctx.analysis.method_sigs.get(key) else:
                        return Option[lowering.MethodInfo].none
                    let sig = unsafe: read(sig_ptr)
                    var ret = sig.return_type
                    if not sig.has_return_type:
                        ret = ctx.void_ty
                    return Option[lowering.MethodInfo].some(value = lowering.MethodInfo(
                        c_name = naming.qualified_member_c_name(ctx.module_name, gv.value, method_name),
                        method_kind = sig.method_kind,
                        return_type = ret,
                        params = sig.params,
                        ast_params = lowering.find_method_params_in_source(ctx.analysis.source_file, gv.value, method_name),
                        is_async = sig.is_async
                    ))
            Option.none:
                pass
        return Option[lowering.MethodInfo].none
    # Prelude variant methods (Option.is_some, Result.unwrap) are registered
    # under the base variant name, not the concrete qualified C name
    # (e.g. key "Option_is_some", not "std_map_Option_std_map_RemovedEntry_ptr_uint_bool_is_some").
    var lookup_name = type_name
    match match_mod.prelude_variant_base(type_name):
        Option.some as base:
            lookup_name = base.value
        Option.none:
            pass
    let key = analyzer.method_key(lookup_name, method_name)
    if ctx.analysis.method_sigs.contains(key):
        let sig_ptr = ctx.analysis.method_sigs.get(key) else:
            return Option[lowering.MethodInfo].none
        let sig = unsafe: read(sig_ptr)
        var ret = sig.return_type
        if not sig.has_return_type:
            ret = ctx.void_ty
        return Option[lowering.MethodInfo].some(value = lowering.MethodInfo(
            c_name = lowering.method_c_name_for_receiver(effective_ty, ctx.module_name, type_name, method_name, sig.method_kind),
            method_kind = sig.method_kind,
            return_type = lowering.qualify_type(ctx, ret),
            params = sig.params,
            ast_params = lowering.find_method_params_in_source(ctx.analysis.source_file, lookup_name, method_name),
            is_async = sig.is_async
        ))
    # Search imported modules' method_sigs when the method is not found locally.
    # When the receiver type carries a specific originating module (ty_imported),
    # restrict the search to that module first so that structs with the same name
    # in different modules (e.g. Config in both std.net.session and
    # std.net.channel) resolve methods from the correct module.
    # A raw (`std.c.*`) receiver's methods are declared by wrapper modules
    # (`std.raylib`, `examples.box2d.common`) — a raw module has no `extending`
    # blocks of its own — so restricting the search to it would never match and
    # the call would fall through to a module-less re-resolution.
    var preferred_module = ""
    match effective_ty:
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            if not im_bp.module_name.starts_with("std.c."):
                preferred_module = im_bp.module_name
        _:
            pass
    var ai: ptr_uint = 0
    while ai < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + ai)
        if a.module_name == ctx.module_name:
            ai += 1
            continue
        if preferred_module.len > 0 and a.module_name != preferred_module:
            ai += 1
            continue
        if a.method_sigs.contains(key):
            let sig_ptr = a.method_sigs.get(key) else:
                ai += 1
                continue
            let sig = unsafe: read(sig_ptr)
            let mod_prefix = naming.module_c_prefix(a.module_name)
            var ret = sig.return_type
            if not sig.has_return_type:
                ret = ctx.void_ty
            # If the method returns a locally-named struct (ty_named), which is
            # defined in the imported module, convert it to ty_imported so the C
            # backend produces the module-qualified C name.
            match ret:
                types.Type.ty_named as rn:
                    let rn_np = unsafe: read(rn.payload)
                    if a.structs.contains(rn_np.name):
                        ret = types.imported_type(
                            module_name = a.module_name,
                            name = rn_np.name,
                            args = span[types.Type]()
                        )
                _:
                    pass
            return Option[lowering.MethodInfo].some(value = lowering.MethodInfo(
                c_name = lowering.method_c_name_for_receiver(
                    effective_ty,
                    a.module_name,
                    type_name,
                    method_name,
                    sig.method_kind
                ),
                method_kind = sig.method_kind,
                return_type = resolve_method_return_from_import(ctx, a.module_name, sig, effective_ty),
                params = sig.params,
                ast_params = lowering.find_method_params_in_source(a.source_file, lookup_name, method_name),
                is_async = sig.is_async,
            ))
        ai += 1
    return Option[lowering.MethodInfo].none


## Like resolve_method_info, but searches ONLY the named imported module
## (for module-qualified receiver types like `sess.Config.default(...)`).


public function resolve_method_info_imported(
    ctx: ref[lowering.LoweringContext],
    receiver_ty: types.Type,
    method_name: str,
    import_module: str
) -> Option[lowering.MethodInfo]:
    var effective_ty = receiver_ty
    if types.is_raw_pointer(effective_ty) or types.is_ref_type(effective_ty):
        effective_ty = types.pointer_element(effective_ty)
    let type_name = lowering.named_type_name(effective_ty) else:
        return Option[lowering.MethodInfo].none
    var lookup_name = type_name
    match match_mod.prelude_variant_base(type_name):
        Option.some as base:
            lookup_name = base.value
        Option.none:
            pass
    let key = analyzer.method_key(lookup_name, method_name)
    var ai: ptr_uint = 0
    while ai < ctx.program_analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(ctx.program_analyses.data + ai)
        if a.module_name == import_module:
            if a.method_sigs.contains(key):
                let sig_ptr = a.method_sigs.get(key) else:
                    return Option[lowering.MethodInfo].none
                let sig = unsafe: read(sig_ptr)
                var ret = sig.return_type
                if not sig.has_return_type:
                    ret = ctx.void_ty
                match ret:
                    types.Type.ty_named as rn:
                        let rn_np = unsafe: read(rn.payload)
                        if a.structs.contains(rn_np.name):
                            ret = types.imported_type(
                                module_name = a.module_name,
                                name = rn_np.name,
                                args = span[types.Type]()
                            )
                    _:
                        pass
                return Option[lowering.MethodInfo].some(value = lowering.MethodInfo(
                    c_name = lowering.method_c_name_for_receiver(
                        effective_ty,
                        a.module_name,
                        type_name,
                        method_name,
                        sig.method_kind
                    ),
                    method_kind = sig.method_kind,
                    return_type = resolve_method_return_from_import(ctx, a.module_name, sig, effective_ty),
                    params = sig.params,
                    ast_params = lowering.find_method_params_in_source(a.source_file, lookup_name, method_name),
                    is_async = sig.is_async,
                ))
            return Option[lowering.MethodInfo].none
        ai += 1
    return Option[lowering.MethodInfo].none


## Lower a static method / hook call `Type.method(args)` where the receiver is a
## bare type name and there is no receiver value to pass: lower only the
## arguments and emit a direct call to the static C function.


public function collect_function_returns(ctx: ref[lowering.LoweringContext], decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        var d: ast.Decl
        unsafe:
            d = read(decls.data + i)
        match d:
            ast.Decl.decl_function as fun:
                # A generic function's return type still carries type
                # parameters; resolving it without a substitution context would
                # instantiate bogus concrete types.  Specializations record
                # their own return types.
                if fun.type_params.len == 0:
                    var ret = type_helpers.resolve_return_type(
                        ctx,
                        type_helpers.find_fn_sig(ctx, fun.name),
                        fun.return_type
                    )
                    if fun.is_async:
                        ret = tasks.make_task_type(ret)
                    ctx.function_returns.set(fun.name, ret)
                    ctx.function_returns.set(naming.qualified_c_name(ctx.module_name, fun.name), ret)
            _:
                pass
        i += 1


## True when a lowered type represents a proc struct (has invoke/release/retain
## fields), as opposed to a bare fn pointer or a regular struct.
