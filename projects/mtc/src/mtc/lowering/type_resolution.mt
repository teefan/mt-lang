## Type reference resolution, extracted from lowering/lowering.mt (Wave 4.2).

import std.string as string
import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.strings
import mtc.c_naming as naming

import mtc.lowering.inline as inline_mod
import mtc.lowering.comptime as comptime
import mtc.lowering.lowering as lowering
import mtc.lowering.proc as proc_mod
import mtc.lowering.match as match_mod
import mtc.lowering.monomorphized as monomorphized


public function resolve_type_ref(ctx: ref[lowering.LoweringContext], tp: ptr[ast.TypeRef]) -> types.Type:
    unsafe:
        let t = read(tp)
        if t.is_fn or t.is_proc:
            let fun = resolve_function_type_ref(ctx, tp)
            if t.is_proc:
                let _registered = lowering.proc_ensure_struct_decl(ctx, naming.proc_type_c_name(fun), fun)
                return fun
            if t.nullable:
                return types.Type.ty_nullable(base = types.alloc_type(fun))
            return fun
        if t.is_dyn:
            return types.dyn_type(
                iface = naming.dyn_iface_declared_name(unsafe: analyzer.qname_to_str(t.dyn_interface)),
                args = lowering.dyn_type_args(ctx, t.dyn_interface)
            )
        if t.is_tuple:
            var elems = vec.Vec[types.Type].create()
            var i: ptr_uint = 0
            while i < t.arguments.len:
                elems.push(resolve_type_ref(ctx, t.arguments.data + i))
                i += 1
            let result = types.tuple_type(elements = elems.as_span(), field_names = Option[span[str]].none)
            if t.nullable:
                return types.Type.ty_nullable(base = types.alloc_type(result))
            return result
        var resolved = types.Type.ty_error
        if t.arguments.len > 0:
            resolved = resolve_generic_type_ref(ctx, t)
        else if t.name.parts.len >= 2:
            var alias: str
            var type_name: str
            unsafe:
                alias = read(t.name.parts.data + 0)
                type_name = read(t.name.parts.data + 1)
            # Inline for substitution: `field.type` resolves to the field's type.
            if type_name == "type":
                let subst = inline_mod.inline_for_type_subst(ctx, alias)
                if not types.is_error(subst):
                    resolved = subst
                    if t.nullable:
                        return types.Type.ty_nullable(base = types.alloc_type(resolved))
                    return resolved
            let mod_ptr = ctx.analysis.imports.get(alias)
            if mod_ptr != null:
                let target_module = unsafe: read(mod_ptr)
                # If the imported module re-exports the type as an alias
                # (e.g. `type CameraMode = c.CameraMode`), follow the chain
                # so the C name comes from the originating `std.c.*` module.
                if lowering.find_imported_opaque_decl(ctx, target_module, type_name):
                    resolved = types.opaque_type(module_name = target_module, name = type_name)
                else:
                    let opt_alias = resolve_single_imported_type(ctx, target_module, type_name)
                    match opt_alias:
                        Option.some as alias_ty:
                            resolved = proc_mod.proc_alias_struct_type(ctx, alias_ty.value)
                        Option.none:
                            resolved = types.imported_type(
                                module_name = target_module,
                                name = type_name,
                                args = span[types.Type]()
                            )
            else:
                # Not an import alias: may be a nested struct, e.g.
                # `Rectangle.Edge` or `Level1.Level2.Level3`.  Its type carries
                # the parent-qualified linkage (`<module>_Rectangle_Edge`).
                match lowering.local_nested_type(ctx, t.name.parts):
                    Option.some as nested:
                        resolved = nested.value
                    Option.none:
                        pass
        else if t.name.parts.len == 1:
            let name = read(t.name.parts.data + 0)
            # A name bound by the enclosing generic's substitution is a type
            # parameter and must be substituted even when the current module
            # declares a same-named type (e.g. `StateHooks[State, Context]`
            # inside `extending StateMachine[State, Event, Context]`).
            let subst_ptr = ctx.type_substitution.get(name)
            if subst_ptr != null:
                resolved = unsafe: read(subst_ptr)
            else if name == "str":
                resolved = types.Type.ty_str
            else if name == "type":
                resolved = types.Type.ty_type_meta
            else if lowering.is_builtin_type_name(name):
                resolved = types.primitive(name)
            else if ctx.analysis.type_names.contains(name):
                if lowering.find_imported_opaque_decl(ctx, ctx.module_name, name):
                    # A declared `opaque X` (optionally with a C backing name) is
                    # `Types::Opaque`, not a struct.
                    resolved = types.opaque_type(module_name = ctx.module_name, name = name)
                    if t.nullable:
                        return types.Type.ty_nullable(base = types.alloc_type(resolved))
                    return resolved
                # Follow the type alias chain so that type aliases pointing to
                # imported types (e.g. `type Color = c.Color`) resolve to the
                # originating module's C name rather than the re-exporting
                # module's qualified name.
                var alias_target = ctx.analysis.type_alias_types.get(name)
                if alias_target != null:
                    resolved = proc_mod.proc_alias_struct_type(ctx, unsafe: read(alias_target))
                else:
                    match lowering.local_nested_type(ctx, t.name.parts):
                        Option.some as nested:
                            resolved = nested.value
                        Option.none:
                            resolved = types.imported_type(
                                module_name = ctx.module_name,
                                name = name,
                                args = span[types.Type]()
                            )
            else:
                let concrete_ptr = ctx.type_substitution.get(name)
                if concrete_ptr != null:
                    resolved = unsafe: read(concrete_ptr)
                else:
                    resolved = types.named_type(name = name, module_name = "", linkage_name = Option[str].none)
        if t.nullable and not types.is_error(resolved):
            return types.Type.ty_nullable(base = types.alloc_type(resolved))
        return resolved


## The type a type alias denotes.  A `type Callback = proc(int) -> int` alias
## denotes its closure struct (`mt_proc_...`), not a bare function pointer, so a
## proc-typed alias matches direct `proc(...)` syntax wherever it is used — as an
## array element, a field, a parameter, or a local annotation.  Any other alias
## target passes through.


public function resolve_imported_alias_type(
    analyses: span[analyzer.Analysis],
    target_module: str,
    type_name: str
) -> Option[types.Type]:
    var ai: ptr_uint = 0
    while ai < analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(analyses.data + ai)
        if a.module_name == target_module:
            let alias_target = a.type_alias_types.get(type_name) else:
                return Option[types.Type].none
            unsafe:
                var at = read(alias_target)
                var base = at
                if types.is_nullable_type(base):
                    base = types.unwrap_nullable(base)
                match base:
                    types.Type.ty_imported as aim:
                        let aim_bp = unsafe: read(aim.payload)
                        return Option[types.Type].some(value = types.imported_type(
                            module_name = aim_bp.module_name,
                            name = aim_bp.name,
                            args = aim_bp.args
                        ))
                    types.Type.ty_named as nm:
                        let nm_np = unsafe: read(nm.payload)
                        return Option[types.Type].some(value = types.named_type(
                            name = nm_np.name,
                            module_name = nm_np.module_name,
                            linkage_name = Option[str].none
                        ))
                    _:
                        return Option[types.Type].some(value = at)
        ai += 1
    return Option[types.Type].none


## The C name for a member resolved through an import alias.
## When the member is a type alias re-exporting from std.c.* (e.g.
## `type CameraMode = c.CameraMode`), use the bare C name from the
## originating module.  Otherwise use the standard qualified name.


public function resolve_single_imported_type(
    ctx: ref[lowering.LoweringContext],
    target_module: str,
    type_name: str
) -> Option[types.Type]:
    return resolve_imported_alias_type(ctx.program_analyses, target_module, type_name)


## `resolve_single_imported_type` over an explicit analysis list, so callers
## without a `lowering.LoweringContext` (the function-ordering pass) resolve identically.


public function resolve_generic_type_ref(ctx: ref[lowering.LoweringContext], t: ast.TypeRef) -> types.Type:
    if t.name.parts.len == 2:
        var alias: str
        var type_name: str
        unsafe:
            alias = read(t.name.parts.data + 0)
            type_name = read(t.name.parts.data + 1)
        let mod_ptr = ctx.analysis.imports.get(alias)
        if mod_ptr != null:
            let target_module = unsafe: read(mod_ptr)
            # A re-exported type alias resolves to its target's type (e.g.
            # `aio.Runtime` -> `std.async.libuv_runtime.Runtime`), matching the
            # analyzer's alias erasure; a plain imported name stays imported.
            match resolve_single_imported_type(ctx, target_module, type_name):
                Option.some as alias_ty:
                    return alias_ty.value
                Option.none:
                    pass
            var resolved_args = vec.Vec[types.Type].create()
            var ai: ptr_uint = 0
            while ai < t.arguments.len:
                unsafe:
                    resolved_args.push(resolve_type_ref(ctx, t.arguments.data + ai))
                ai += 1
            return types.imported_type(module_name = target_module, name = type_name, args = resolved_args.as_span())
        return types.Type.ty_error
    if t.name.parts.len != 1:
        return types.Type.ty_error
    let name = unsafe: read(t.name.parts.data + 0)
    if name == "array" and t.arguments.len == 2:
        var args = vec.Vec[types.Type].create()
        unsafe:
            args.push(resolve_type_ref(ctx, t.arguments.data + 0))
        args.push(resolve_array_length_type(ctx, unsafe: t.arguments.data + 1))
        return types.generic_type(name = "array", args = args.as_span())
    # simd[T, N]: the lane count resolves like an array length (a literal, a
    # bound type parameter, or a module constant), never as a type name.
    if name == "simd" and t.arguments.len == 2:
        var simd_args = vec.Vec[types.Type].create()
        unsafe:
            simd_args.push(resolve_type_ref(ctx, t.arguments.data + 0))
        simd_args.push(resolve_array_length_type(ctx, unsafe: t.arguments.data + 1))
        return types.generic_type(name = "simd", args = simd_args.as_span())
    # SoA[T, N]: the count is an integer argument like simd's lane count (the
    # host stores a plain Integer in `Types::SoA#count`).
    if name == "SoA" and t.arguments.len == 2:
        var soa_args = vec.Vec[types.Type].create()
        unsafe:
            soa_args.push(resolve_type_ref(ctx, t.arguments.data + 0))
        soa_args.push(resolve_array_length_type(ctx, unsafe: t.arguments.data + 1))
        return types.generic_type(name = "SoA", args = soa_args.as_span())
    # str_buffer[N]: ensure the struct type exists and return the resolved type.
    if name == "str_buffer" and t.arguments.len == 1:
        var sb_args = vec.Vec[types.Type].create()
        # The capacity N is an integer type argument: resolve it (like
        # `array[T, N]`) so it folds a literal, a generic type parameter bound by
        # the current specialization (`str_buffer[N]` with `N = 16`), or a
        # module-level constant to a `ty_literal_int`.  A plain
        # `resolve_array_length` would leave a substituted `N` as 0.
        sb_args.push(resolve_array_length_type(ctx, unsafe: t.arguments.data + 0))
        let sb_ty = types.generic_type(name = "str_buffer", args = sb_args.as_span())
        lowering.ensure_str_buffer_struct(ctx, sb_ty)
        return sb_ty
    # span / ptr / const_ptr / ref and other generics: resolve each type argument.
    var args = vec.Vec[types.Type].with_capacity_exact(t.arguments.len)
    var i: ptr_uint = 0
    while i < t.arguments.len:
        unsafe:
            args.push(resolve_type_ref(ctx, t.arguments.data + i))
        i += 1
    return types.generic_type(name = name, args = args.as_span())


## Resolve an `fn(...) -> T` or `proc(...) -> T` type ref to a `ty_function`
## type.  Both `fn` and `proc` share the same runtime C representation (function
## pointer), so they are lowered to the same `ty_function` variant.


public function resolve_function_type_ref(ctx: ref[lowering.LoweringContext], tp: ptr[ast.TypeRef]) -> types.Type:
    let t = unsafe: read(tp)
    var param_types = vec.Vec[types.Type].with_capacity_exact(t.fn_params.len)
    var param_names = vec.Vec[str].with_capacity_exact(t.fn_params.len)
    var i: ptr_uint = 0
    while i < t.fn_params.len:
        var p: ast.Param
        unsafe:
            p = read(t.fn_params.data + i)
        let pty = resolve_type_ref(ctx, ptr_of(p.param_type))
        param_types.push(pty)
        param_names.push(p.name)
        i += 1
    var ret = ctx.void_ty
    let fr = t.fn_return
    if fr != null:
        unsafe:
            ret = resolve_type_ref(ctx, fr)
    return types.function_type(
        name = "",
        params = param_types.as_span(),
        return_type = types.alloc_type(ret),
        variadic = false,
        is_proc = t.is_proc,
        param_names = param_names.as_span()
    )


## The compile-time length of an array type argument (`array[int, 3]` -> 3),
## parsed from the argument's decimal name.  Non-literal lengths (named
## constants) resolve later.


public function resolve_array_length(tp: ptr[ast.TypeRef]) -> long:
    let t = unsafe: read(tp)
    if t.name.parts.len != 1:
        return 0
    let text = unsafe: read(t.name.parts.data + 0)
    return lowering.parse_decimal(text)


## Resolve an array-length type argument to a `ty_literal_int`.  A numeric
## literal (`4`) parses directly.  A named length parameter (`N` in
## `array[T, N]`) resolves through `ctx.type_substitution` when the enclosing
## generic is being specialized (`N -> ty_literal_int(4)`); a module-level
## integer constant (`array[T, ENV_ITEM_COUNT]`) folds through
## `ctx.analysis.const_values`; otherwise it is left as a `ty_named` so a later
## `substitute_type_params` can fill it in.


public function resolve_array_length_type(ctx: ref[lowering.LoweringContext], tp: ptr[ast.TypeRef]) -> types.Type:
    let t = unsafe: read(tp)
    if t.name.parts.len == 1:
        let text = unsafe: read(t.name.parts.data + 0)
        if text.len > 0 and text.byte_at(0) >= '0' and text.byte_at(0) <= '9':
            return types.literal_int(lowering.parse_decimal(text))
        # A named length parameter: substitute if bound, else keep the name.
        let concrete_ptr = ctx.type_substitution.get(text)
        if concrete_ptr != null:
            return unsafe: read(concrete_ptr)
        # A module-level integer constant used as a length: fold to its value.
        let const_ptr = ctx.analysis.const_values.get(text)
        if const_ptr != null:
            return types.literal_int(comptime.const_eval_int(ctx, unsafe: read(const_ptr)))
        return types.named_type(name = text, module_name = "", linkage_name = Option[str].none)
    # A module-qualified constant (`array[b3.BodyId, human.BONE_COUNT]`): fold it
    # through the alias's module, evaluating the constant's value expression in
    # the module that declares it (the host's
    # `resolve_imported_module_const_value`).
    if t.name.parts.len == 2:
        let alias = unsafe: read(t.name.parts.data + 0)
        let member = unsafe: read(t.name.parts.data + 1)
        let target_ptr = ctx.analysis.imports.get(alias)
        if target_ptr != null:
            match lowering.find_imported_analysis(ctx, unsafe: read(target_ptr)):
                Option.some as owner:
                    var saved_module = ctx.module_name
                    var saved_analysis = ctx.analysis
                    ctx.module_name = owner.value.module_name
                    ctx.analysis = owner.value
                    var folded = Option[long].none
                    let chain = ctx.analysis.const_values.get(member)
                    if chain != null:
                        folded = lowering.try_const_eval_int(ctx, unsafe: read(chain))
                    ctx.module_name = saved_module
                    ctx.analysis = saved_analysis
                    match folded:
                        Option.some as value:
                            return types.literal_int(value.value)
                        Option.none:
                            pass
                Option.none:
                    pass
    return types.literal_int(resolve_array_length(tp))


public function resolve_field_type_ref(ctx: ref[lowering.LoweringContext], tref: ast.TypeRef) -> types.Type:
    var local_tref = tref
    let scalar = lowering.resolve_scalar_type_ref(ptr_of(local_tref))
    if not types.is_error(scalar):
        return scalar
    if tref.is_fn or tref.is_proc:
        let fun = resolve_function_type_ref(ctx, ptr_of(local_tref))
        if tref.is_proc:
            let _registered = lowering.proc_ensure_struct_decl(ctx, naming.proc_type_c_name(fun), fun)
            return fun
        if tref.nullable:
            return types.Type.ty_nullable(base = types.alloc_type(fun))
        return fun
    if tref.is_dyn:
        return types.dyn_type(
            iface = naming.dyn_iface_declared_name(unsafe: analyzer.qname_to_str(tref.dyn_interface)),
            args = lowering.dyn_type_args(ctx, tref.dyn_interface)
        )
    if tref.is_tuple:
        var elems = vec.Vec[types.Type].create()
        var ti: ptr_uint = 0
        while ti < tref.arguments.len:
            elems.push(resolve_field_type_ref(ctx, unsafe: read(tref.arguments.data + ti)))
            ti += 1
        let tuple_ty = types.tuple_type(elements = elems.as_span(), field_names = Option[span[str]].none)
        if tref.nullable:
            return types.Type.ty_nullable(base = types.alloc_type(tuple_ty))
        return tuple_ty
    var resolved = types.Type.ty_error
    if tref.arguments.len > 0:
        resolved = resolve_generic_type_ref(ctx, tref)
    else if tref.name.parts.len >= 2:
        var alias: str
        var type_name: str
        unsafe:
            alias = read(tref.name.parts.data + 0)
            type_name = read(tref.name.parts.data + 1)
        let mod_ptr = ctx.analysis.imports.get(alias)
        if mod_ptr != null:
            let target_module = unsafe: read(mod_ptr)
            # Follow a re-exported type alias (e.g. `aio.Runtime` ->
            # `std.async.libuv_runtime.Runtime`), like `resolve_type_ref`.
            match resolve_single_imported_type(ctx, target_module, type_name):
                Option.some as alias_ty:
                    resolved = proc_mod.proc_alias_struct_type(ctx, alias_ty.value)
                Option.none:
                    resolved = types.imported_type(
                        module_name = target_module,
                        name = type_name,
                        args = span[types.Type]()
                    )
        else:
            # A nested struct's qualified reference (`Rectangle.Edge`): its
            # registered type carries the parent-qualified linkage name.
            match lowering.local_nested_type(ctx, tref.name.parts):
                Option.some as nested:
                    resolved = nested.value
                Option.none:
                    pass
    else if tref.name.parts.len == 1:
        let name = unsafe: read(tref.name.parts.data + 0)
        if lowering.is_builtin_type_name(name):
            resolved = types.primitive(name)
        else if ctx.analysis.type_names.contains(name):
            # A same-module type alias resolves to its target (the host's
            # `resolve_type_ref`), except a `std.c.*` backing alias, which stays
            # nominal so the C typedef handles the mapping.
            let alias_ptr = ctx.analysis.type_alias_types.get(name)
            if alias_ptr != null and not lowering.type_is_from_std_c(unsafe: read(alias_ptr)):
                resolved = unsafe: read(alias_ptr)
            else:
                match lowering.local_nested_type(ctx, tref.name.parts):
                    Option.some as nested:
                        resolved = nested.value
                    Option.none:
                        resolved = types.imported_type(
                            module_name = ctx.module_name,
                            name = name,
                            args = span[types.Type]()
                        )
        else:
            let concrete_ptr = ctx.type_substitution.get(name)
            if concrete_ptr != null:
                resolved = unsafe: read(concrete_ptr)
            else:
                resolved = types.named_type(name = name, module_name = "", linkage_name = Option[str].none)
    if tref.nullable and not types.is_error(resolved):
        return types.Type.ty_nullable(base = types.alloc_type(resolved))
    return resolved


## Look up the resolved type of a module-level variable declared in the source
## file.  Used when `expr_type(ctx, callee)` fails for proc variables.


public function named_type_name(t: types.Type) -> Option[str]:
    match t:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return Option[str].some(value = n_np.name)
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return Option[str].some(value = im_bp.name)
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return Option[str].some(value = g_bp.name)
        _:
            return Option[str].none

# =============================================================================
#  C-name mangling (mirrors lowering/utils.rb)
# =============================================================================

# =============================================================================
#  IR allocation
# =============================================================================


public function type_simple_name(t: types.Type) -> str:
    match t:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.name
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return im_bp.name
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return g_bp.name
        _:
            return ""


## Simple type equality check for primitive/named types.


public function type_declared_in_source(module_analysis: analyzer.Analysis, name: str) -> bool:
    var di: ptr_uint = 0
    while di < module_analysis.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(module_analysis.source_file.declarations.data + di)
        match d:
            ast.Decl.decl_struct as s:
                if s.name == name:
                    return true
            ast.Decl.decl_variant as vr:
                if vr.name == name:
                    return true
            ast.Decl.decl_enum as en:
                if en.name == name:
                    return true
            _:
                pass
        di += 1
    return false


## Check if a struct named `name` exists in a module's source file AST.


public function generic_variant_instance_type(
    ctx: ref[lowering.LoweringContext],
    variant_name: str,
    concrete_args: span[types.Type]
) -> types.Type:
    if match_mod.is_prelude_variant_name(variant_name):
        return types.generic_type(name = variant_name, args = concrete_args)
    match lowering.variant_declaring_module(ctx, variant_name):
        Option.some as owner:
            return types.imported_type(module_name = owner.value, name = variant_name, args = concrete_args)
        Option.none:
            return types.generic_type(name = variant_name, args = concrete_args)


## The module declaring a variant named `name`, searching the current module then
## the imports.  `none` when no loaded module declares it.


public function generic_c_type_raw(name: str, args: span[types.Type]) -> str:
    var buf = string.String.create()
    buf.append(name)
    var i: ptr_uint = 0
    while i < args.len:
        buf.append("_")
        unsafe:
            buf.append(naming.type_c_key(read(args.data + i)))
        i += 1
    return buf.as_str()


## Follow a type alias chain across module boundaries.  When `target_module`
## re-exports `type_name` as an alias (e.g. `std.raylib` has `type CameraMode = c.CameraMode`),
## follow the chain through the alias target to get the underlying type from the
## originating module (e.g. `ty_imported("std.c.raylib", "CameraMode")`).
## Returns none if `type_name` is not a type alias in the target module.
