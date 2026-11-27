## Type qualification, extracted from lowering/lowering.mt (Wave 4.2).

import std.vec as vec

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types
import mtc.strings
import mtc.c_naming as naming

import mtc.lowering.lowering as lowering
import mtc.lowering.match as match_mod
import mtc.lowering.monomorphized as monomorphized


public function qualify_type(ctx: ref[lowering.LoweringContext], t: types.Type) -> types.Type:
    match t:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if lowering.is_raw_type_param_name(n_np.name):
                return ctx.void_ty
            # A nested struct's named type carries the parent-qualified C
            # linkage (`<module>_Rectangle_Edge`); converting it to
            # `ty_imported` would drop it and re-derive `<module>_Edge`.
            if n_np.linkage_name.is_some():
                return t
            # Built-in registered types (`EventError`, `Subscription`) carry no
            # owning module and must not be module-qualified.
            if n_np.module_name.len == 0:
                let registered_ptr = ctx.analysis.types.get(n_np.name)
                if registered_ptr != null:
                    unsafe:
                        match read(registered_ptr):
                            types.Type.ty_named as rn:
                                let rn_np = unsafe: read(rn.payload)
                                if rn_np.module_name.len == 0:
                                    return t
                            _:
                                pass
            # Already-monomorphized concrete names (e.g. std_map_Node_str_bool)
            # are fully qualified: pass them through so re-qualifying in a
            # different module context does not double-prefix them.
            if monomorphized.generic_instance_contains(ctx, n_np.name) or ctx.caches.generic_structs.contains(n_np.name):
                return t
            # Concrete C names produced by generic_struct_c_name always contain
            # at least one underscore (module_prefix_Name_Arg).  Bare names
            # without underscores (like the type param `T`) should follow the
            # normal qualify path.
            if n_np.name.find_byte('_').is_some():
                return t
            # Prelude variant instances (Option_str, Result_int_Error) and proc
            # typedefs (mt_proc_...) have global C names and must not be
            # module-prefixed.
            if match_mod.is_prelude_variant_name(n_np.name) or n_np.name.starts_with("mt_proc_"):
                return t
            # A bare type name may be a type imported from another module (e.g.
            # `Diag` used in `analyzer` but defined in `definite_assignment`).
            # Qualify it against its OWNER module, not the current one, so it does
            # not become a mis-attributed `<current_module>_Diag`.
            match lowering.imported_type_module(ctx, n_np.name):
                Option.some as owner:
                    return types.imported_type(module_name = owner.value, name = n_np.name, args = span[types.Type]())
                Option.none:
                    pass
            # The name may be declared in a module the current one does not
            # import (e.g. a reflected struct type from the caller's module,
            # reached through `fields_of(T)`): find its defining module
            # program-wide so it is not mis-attributed to the current module.
            match lowering.find_declaring_module(ctx, n_np.name):
                Option.some as owner:
                    return types.imported_type(module_name = owner.value, name = n_np.name, args = span[types.Type]())
                Option.none:
                    pass
            # Resolve type aliases to their target type so the C backend sees
            # the concrete type (e.g. IntCallback → fn(...)) rather than an
            # opaque ty_imported.  Aliases targeting std.c.* types are NOT
            # resolved — the C typedef (e.g. `typedef struct sockaddr_storage
            # std_net_NativeSocketStorage`) handles the mapping, and keeping
            # the alias name avoids raw C type names (e.g. `sockaddr_storage`
            # without `struct` prefix) in function signatures / struct fields.
            if ctx.analysis.type_alias_types.contains(n_np.name):
                let resolved_ptr = ctx.analysis.type_alias_types.get(n_np.name) else:
                    fatal(c"lowering: type alias lookup inconsistency")
                let resolved_val = unsafe: read(resolved_ptr)
                if not lowering.type_is_from_std_c(resolved_val):
                    return qualify_type(ctx, resolved_val)
            # A named type that already carries its owning module is qualified
            # against it, not the current module: lowering std.result's
            # `map_error[F]` with `ty_named("Error", "map_err_probe")` must not
            # produce `std.result.Error`.
            let owner = if n_np.module_name.len > 0: n_np.module_name else: ctx.module_name
            return types.imported_type(module_name = owner, name = n_np.name, args = span[types.Type]())
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            if lowering.is_raw_type_param_name(im_bp.name):
                return ctx.void_ty
            # Resolve type aliases defined in the owning module (e.g.
            # `NativeBuffer` in `std.net` → `uv_buf_t` in `std.c.libuv`).
            if im_bp.args.len == 0 and not match_mod.is_prelude_variant_name(im_bp.name):
                let owner_a_opt = lowering.find_imported_analysis(ctx, im_bp.module_name)
                if owner_a_opt.is_some():
                    let owner_a = owner_a_opt.unwrap()
                    if owner_a.type_alias_types.contains(im_bp.name):
                        let resolved_ptr = owner_a.type_alias_types.get(im_bp.name) else:
                            fatal(c"lowering: imported type alias lookup inconsistency")
                        return qualify_type(ctx, unsafe: read(resolved_ptr))
            var resolved_args = span[types.Type]()
            if im_bp.args.len > 0:
                var args_vec = vec.Vec[types.Type].with_capacity_exact(im_bp.args.len)
                var ai: ptr_uint = 0
                while ai < im_bp.args.len:
                    unsafe:
                        args_vec.push(qualify_type(ctx, read(im_bp.args.data + ai)))
                    ai += 1
                resolved_args = args_vec.as_span()
            # Prelude variants (Option/Result) have global, un-prefixed C names
            # (Option_str, not <module>_Option_str) and are emitted as generic
            # variants, so keep them in generic form rather than monomorphizing a
            # module-qualified struct.
            if match_mod.is_prelude_variant_name(im_bp.name):
                return types.generic_type(name = im_bp.name, args = resolved_args)
            if resolved_args.len > 0:
                var has_unresolved = false
                var ui: ptr_uint = 0
                while ui < resolved_args.len:
                    unsafe:
                        if lowering.type_contains_type_var(read(resolved_args.data + ui)):
                            has_unresolved = true
                    ui += 1
                if has_unresolved:
                    return t
                let concrete_name = naming.qualified_c_name(
                    im_bp.module_name,
                    lowering.generic_struct_c_name(im_bp.name, resolved_args)
                )
                # A generic VARIANT instance has no struct fields to extract, so
                # register its concrete declaration and stop: it is emitted as a
                # variant, not a struct.
                match lowering.find_imported_analysis(ctx, im_bp.module_name):
                    Option.some as owner:
                        if lowering.ensure_generic_variant_decl(ctx, owner.value, im_bp.name, resolved_args, concrete_name):
                            return types.imported_type(
                                module_name = im_bp.module_name,
                                name = im_bp.name,
                                args = resolved_args
                            )
                    Option.none:
                        pass
                lowering.ensure_generic_struct_decl_named(
                    ctx,
                    im_bp.name,
                    span[ast.TypeArgument](),
                    resolved_args,
                    concrete_name
                )
                monomorphized.generic_instance_set(
                    ctx,
                    concrete_name,
                    lowering.GenericReceiver(
                        owner_name = im_bp.name,
                        concrete_args = resolved_args,
                        owner_module = im_bp.module_name
                    )
                )
                return types.imported_type(module_name = im_bp.module_name, name = im_bp.name, args = resolved_args)
            return t
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            var args = vec.Vec[types.Type].with_capacity_exact(g_bp.args.len)
            var gi: ptr_uint = 0
            while gi < g_bp.args.len:
                unsafe:
                    args.push(qualify_type(ctx, read(g_bp.args.data + gi)))
                gi += 1
            # Monomorphize user-defined generic structs used as field types
            # (e.g. Node[str, bool] from std/map), skipping builtins handled
            # directly by the C backend.
            let resolved = lowering.try_monomorphize_generic(ctx, g_bp.name, args.as_span())
            if not types.is_error(resolved):
                return resolved
            return types.generic_type(name = g_bp.name, args = args.as_span())
        types.Type.ty_nullable as nl:
            let qbase = qualify_type(ctx, unsafe: read(nl.base))
            # An opaque type is an incomplete C type used only through pointers,
            # so `Opaque?` is a nullable C pointer.  Wrap the base in `ptr[...]`
            # so it flows through the existing pointer-nullable machinery
            # (rendered as `<backing>*`) instead of an invalid value-optional
            # struct over an incomplete type.
            if lowering.is_opaque_base(ctx, qbase):
                let op_parts = lowering.opaque_module_name_and_name(qbase)
                if op_parts.module_name.len > 0:
                    let op_ty = types.opaque_type(module_name = op_parts.module_name, name = op_parts.name)
                    return types.Type.ty_nullable(base = types.alloc_type(op_ty))
                let ptr_base = types.generic_type(name = "ptr", args = lowering.sp_type(qbase))
                return types.Type.ty_nullable(base = types.alloc_type(ptr_base))
            return types.Type.ty_nullable(base = types.alloc_type(qbase))
        types.Type.ty_function as fnt:
            let fnt_ft = unsafe: read(fnt.payload)
            if fnt_ft.is_proc:
                # A proc value's IR type is the closure's own function type (the
                # host's `Types::Proc`); the `mt_proc_*` C struct is synthesized
                # from it by the backend.  Register the struct declaration and
                # carry the type itself.
                let _registered = lowering.proc_ensure_struct_decl(ctx, naming.proc_type_c_name(t), t)
            return t
        _:
            return t


## When `name` is a generic struct (local or imported) with concrete args,
## monomorphize it and return the concrete `ty_named`.  Returns `ty_error` for
## builtins (ptr/span/ref/...) and unknown names — the caller should fall back
## to `ty_generic`.
