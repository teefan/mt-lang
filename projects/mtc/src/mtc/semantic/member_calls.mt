## Member-call checking, extracted from semantic/analyzer.mt.

import std.map as map_mod

import mtc.parser.ast as ast
import mtc.semantic.types as types
import mtc.semantic.analyzer as analyzer
import mtc.semantic.scope as sscope


## Check a call whose callee is `receiver.method(...)`.  Enum/variant static
## members (`Color.red(...)`, `lib.Token.ident(...)`) are validated for existence
## only.  Struct static methods (`Counter.make(...)`, `lib.Adder.make(...)`) and
## value-receiver instance methods (`p.method(...)`) are resolved to a signature
## and argument-checked, with the method's return type flowing to the caller.
public function check_member_call(
    ctx: ref[analyzer.Context],
    scope: ref[sscope.Scope],
    receiver: ptr[ast.Expr],
    method_name: str,
    args: span[ast.Argument],
    arg_types: span[types.Type],
    any_named: bool,
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    match imported_static_member(ctx, scope, receiver, method_name, line, column):
        Option.some as imported_static:
            return imported_static.value
        Option.none:
            pass

    match static_type_receiver(ctx, scope, receiver):
        Option.some as tn:
            analyzer.check_static_member(ctx, tn.value, method_name, line, column)
            return types.named_type(name = tn.value, module_name = ctx.module_name, linkage_name = Option[str].none)
        Option.none:
            pass

    match static_struct_receiver_type(ctx, scope, receiver):
        Option.some as static_type:
            return check_typed_method_call(
                ctx,
                static_type.value,
                method_name,
                args,
                arg_types,
                any_named,
                line,
                column
            )
        Option.none:
            pass

    # An instantiated imported receiver resolves the call against the binding
    # with the type arguments substituted (`vec.Vec[int].create()` -> `Vec[int]`);
    # the signature is still argument-checked, as the local-type path does.
    match analyzer.specialization_imported_receiver(ctx, scope, receiver):
        Option.some as instantiated:
            analyzer.check_editable_receiver_immutable(ctx, scope, receiver, instantiated.value, method_name, line, column)
            match analyzer.imported_method_call_type(
                ctx,
                instantiated.value,
                method_name,
                args,
                arg_types,
                any_named,
                line,
                column
            ):
                Option.some as method_type:
                    return method_type.value
                Option.none:
                    pass
        Option.none:
            pass

    # A specialization of a locally-known type is an instance of that type
    # (`Result[int, int].success(value = 7)`); for a variant, enum or flags the
    # member is an arm or member and the call's type is the instance itself.
    # A struct's member is an associated function instead
    # (`BinaryHeap[T].parent_index(child)`), so it resolves like any other
    # method on the instance.
    match analyzer.type_instance_receiver(ctx, scope, receiver):
        Option.some as instance:
            match instance.value:
                types.Type.ty_imported as im:
                    let im_bp = unsafe: read(im.payload)
                    if ctx.static_member_types.contains(im_bp.name):
                        analyzer.check_static_member(ctx, im_bp.name, method_name, line, column)
                        return instance.value
                    return check_typed_method_call(
                        ctx,
                        instance.value,
                        method_name,
                        args,
                        arg_types,
                        any_named,
                        line,
                        column
                    )
                _:
                    pass
        Option.none:
            pass

    # A bare builtin type name as receiver (`mat4.identity()`, `str.len()`):
    # resolve the member against the type's methods, wherever an `extending`
    # block declares them (std.linear_algebra's `extending mat4:`).
    match static_builtin_type_name(ctx, scope, receiver):
        Option.some as builtin_name:
            return check_typed_method_call(
                ctx,
                types.named_type(name = builtin_name.value, module_name = "", linkage_name = Option[str].none),
                method_name,
                args,
                arg_types,
                any_named,
                line,
                column
            )
        Option.none:
            pass

    # Builtin event methods (`ready.subscribe(listener)`, `ready.emit(value)`).
    match analyzer.event_value_receiver(ctx, scope, receiver):
        Option.some as event_name:
            let _ = event_name
            # The lowering resolves the event method from the receiver's
            # recorded type, so it must be inferred here too (this arm returns
            # before the generic path below would).
            let _recv_ty = analyzer.infer_expr(ctx, scope, receiver)
            return analyzer.event_method_call_type(ctx, method_name, event_name.value)
        Option.none:
            pass

    let recv_ty = analyzer.infer_expr(ctx, scope, receiver)
    # The LSP's text-based receiver walk cannot resolve a call/index/cast
    # receiver, so record the expression's inferred type at the member token's
    # position (see `member_receiver_types`).
    if ctx.tooling_facts and not analyzer.receiver_is_text_chain(receiver):
        ctx.member_receiver_types.set(analyzer.binding_key(line, column), recv_ty)
    let recv = analyzer.unwrap_ref(recv_ty)
    # A raw/mutable pointer receiver projects to its pointee only when the
    # pointer type itself declares no method of that name (the host's
    # `project_method_receiver_type`): `ptr[T].load()` resolves on the pointer
    # (`extending ptr[T]` in std.mem.ptr), `own[SleepState].ready` on the pointee.
    var member_recv = recv
    match analyzer.resolve_method_sig(ctx, recv, method_name):
        Option.some:
            pass
        Option.none:
            if not analyzer.generic_receiver_has_method(ctx, recv, method_name):
                member_recv = analyzer.project_pointer_receiver(recv)
    analyzer.check_editable_receiver_immutable(ctx, scope, receiver, member_recv, method_name, line, column)
    match analyzer.imported_method_call_type(ctx, member_recv, method_name, args, arg_types, any_named, line, column):
        Option.some as substituted_method:
            return substituted_method.value
        Option.none:
            pass
    return check_typed_method_call(ctx, member_recv, method_name, args, arg_types, any_named, line, column)

## Resolve and check a method call against a known receiver type (local or
## imported): argument-check the signature and flow its return type, or fall back
## to a member-existence check when no signature is known.
public function check_typed_method_call(
    ctx: ref[analyzer.Context],
    receiver_type: types.Type,
    method_name: str,
    args: span[ast.Argument],
    arg_types: span[types.Type],
    any_named: bool,
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    if types.is_simd_type(receiver_type):
        if method_name == "with":
            analyzer.check_simd_with_call(ctx, receiver_type, args, arg_types, any_named, line, column)
            return receiver_type
        analyzer.report(ctx, line, column, analyzer.unknown_member_message("method", types.type_to_string(receiver_type), method_name))
        return types.Type.ty_error
    # A native vec/mat/quat `with` yields the receiver's own type with one field
    # replaced (the host's `check_struct_with_call`): `v3.with(x = 99.0)` -> vec3.
    if method_name == "with" and analyzer.is_vec_math_name(analyzer.primitive_type_name_static(receiver_type)):
        return receiver_type
    match analyzer.resolve_method_sig(ctx, receiver_type, method_name):
        Option.some as sig:
            analyzer.check_signature_call(ctx, method_name, sig.value, args, arg_types, any_named, line, column)
            var type_name: Option[str] = Option[str].none
            match receiver_type:
                types.Type.ty_named as n:
                    let n_np = unsafe: read(n.payload)
                    type_name = Option[str].some(value = n_np.name)
                _:
                    pass
            match type_name:
                Option.some as tn:
                    let key = analyzer.method_key(tn.value, method_name)
                    let tps_ptr = ctx.method_type_params.get(key)
                    if tps_ptr != null:
                        var subs = map_mod.Map[str, types.Type].create()
                        analyzer.unify_call_args(sig.value.params, arg_types, ref_of(subs))
                        unsafe: analyzer.validate_inferred_type_args(ctx, read(tps_ptr), ref_of(subs), line, column)
                        return analyzer.substitute_type(sig.value.return_type, ref_of(subs))
                Option.none:
                    pass
            # A generic receiver carries its own type arguments, which substitute
            # the type's declared parameters in the method's signature
            # (`Option[int].unwrap()` -> `int`, `Vec[int].first()` -> `ptr[int]`).
            match receiver_type:
                types.Type.ty_generic as g:
                    let g_bp = unsafe: read(g.payload)
                    match analyzer.receiver_type_param_names(ctx, g_bp.name):
                        Option.some as pnames:
                            var subs = map_mod.Map[str, types.Type].create()
                            defer: subs.release()
                            var pi: ptr_uint = 0
                            while pi < pnames.value.len and pi < g_bp.args.len:
                                unsafe:
                                    subs.set(read(pnames.value.data + pi), read(g_bp.args.data + pi))
                                pi += 1
                            return analyzer.substitute_type(sig.value.return_type, ref_of(subs))
                        Option.none:
                            pass
                _:
                    pass
            return sig.value.return_type
        Option.none:
            let member_ty = check_member(ctx, receiver_type, method_name, true, line, column)
            match member_ty:
                types.Type.ty_function as callable:
                    let ft = unsafe: read(callable.payload)
                    let sig = analyzer.function_field_signature(method_name, ft)
                    analyzer.check_signature_call(ctx, method_name, sig, args, arg_types, any_named, line, column)
                    return unsafe: read(ft.return_type)
                _:
                    return member_ty


## A member call's signature: an imported function (`lib.f`, `heap.must_alloc`),
## a static struct method (`Counter.make`) or an instance method on a value.
## `with` is the aggregate-copy / simd builtin (named arguments are field names
## or rejected), so it never canonicalizes.
public function member_parameter_info(
    ctx: ref[analyzer.Context],
    scope: ref[sscope.Scope],
    receiver: ptr[ast.Expr],
    member: str,
    name_out: ref[str],
    sig_out: ref[analyzer.FnSig]
) -> bool:
    if member == "with":
        return false
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as rid:
                if analyzer.scope_get(scope, rid.name) == null and ctx.import_aliases.contains(rid.name):
                    let module_name_ptr = ctx.import_aliases.get(rid.name)
                    if module_name_ptr == null:
                        return false
                    let binding_ptr = analyzer.find_binding(ctx, read(module_name_ptr))
                    if binding_ptr == null:
                        return false
                    let sig_ptr = read(binding_ptr).functions.get(member)
                    if sig_ptr == null:
                        return false
                    read(name_out) = member
                    read(sig_out) = read(sig_ptr)
                    return true
            _:
                pass

    match static_struct_receiver_type(ctx, scope, receiver):
        Option.some as static_type:
            match analyzer.resolve_method_sig(ctx, static_type.value, member):
                Option.some as sig:
                    unsafe:
                        read(name_out) = member
                        read(sig_out) = sig.value
                    return true
                Option.none:
                    pass
        Option.none:
            pass

    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as rid:
                let rtp = analyzer.scope_get(scope, rid.name)
                if rtp == null:
                    return false
                let recv_ty = analyzer.unwrap_ref(read(rtp))
                match analyzer.resolve_method_sig(ctx, recv_ty, member):
                    Option.some as sig:
                        read(name_out) = member
                        read(sig_out) = sig.value
                        return true
                    Option.none:
                        return false
            _:
                pass

    let recv = analyzer.unwrap_ref(analyzer.infer_expr(ctx, scope, receiver))
    match analyzer.resolve_method_sig(ctx, recv, member):
        Option.some as sig:
            unsafe:
                read(name_out) = member
                read(sig_out) = sig.value
            return true
        Option.none:
            return false

public function check_imported_member_depth(
    ctx: ref[analyzer.Context],
    module_name: str,
    type_name: str,
    member: str,
    args: span[types.Type],
    is_method_call: bool,
    line: ptr_uint,
    column: ptr_uint,
    depth: int
) -> types.Type:
    if depth > 10:
        return types.Type.ty_error
    let binding_ptr = analyzer.find_binding(ctx, module_name) else:
        return types.Type.ty_error

    unsafe:
        let binding = read(binding_ptr)
        let fields_ptr = binding.structs.get(type_name)
        if fields_ptr != null:
            let fields = read(fields_ptr)
            var i: ptr_uint = 0
            while i < fields.len:
                let fe = read(fields.data + i)
                if fe.name == member:
                    return analyzer.member_call_result_type(
                        analyzer.substituted_field_type(binding, type_name, args, fe.ty),
                        is_method_call
                    )
                i += 1

        let union_ptr = binding.unions.get(type_name)
        if union_ptr != null:
            let ufields = read(union_ptr)
            var ui: ptr_uint = 0
            while ui < ufields.len:
                let ufe = read(ufields.data + ui)
                if ufe.name == member:
                    return analyzer.member_call_result_type(
                        analyzer.substituted_field_type(binding, type_name, args, ufe.ty),
                        is_method_call
                    )
                ui += 1

        # A private type reached through a public signature (a function whose
        # return type is a module-private struct) still resolves its fields.
        let private_fields_ptr = binding.private_structs.get(type_name)
        if private_fields_ptr != null:
            let fields = read(private_fields_ptr)
            var pi: ptr_uint = 0
            while pi < fields.len:
                let fe = read(fields.data + pi)
                if fe.name == member:
                    return analyzer.member_call_result_type(
                        analyzer.substituted_field_type(binding, type_name, args, fe.ty),
                        is_method_call
                    )
                pi += 1

        let private_union_ptr = binding.private_unions.get(type_name)
        if private_union_ptr != null:
            let ufields = read(private_union_ptr)
            var pui: ptr_uint = 0
            while pui < ufields.len:
                let ufe = read(ufields.data + pui)
                if ufe.name == member:
                    return analyzer.member_call_result_type(
                        analyzer.substituted_field_type(binding, type_name, args, ufe.ty),
                        is_method_call
                    )
                pui += 1

        if member == "with" or analyzer.binding_has_member(binding, type_name, member):
            return types.Type.ty_error

    # A method this module declares on the receiver's type (`extending
    # b3.Vec3:` for a receiver that resolved to the C struct `b3Vec3`) lives in
    # the current module's method keys, not in any imported binding.
    if analyzer.has_method(ctx, type_name, member):
        return types.Type.ty_error

    # Follow a type alias to its source module when the member is not found
    # directly (e.g. `public type uv_run_mode = c.uv_run_mode` re-exports an
    # external enum whose members live in the source external module).
    match analyzer.follow_type_alias(ctx, binding_ptr, type_name):
        Option.some as source_info:
            return check_imported_member_depth(
                ctx,
                source_info.value.module_name,
                source_info.value.type_name,
                member,
                span[types.Type](),
                is_method_call,
                line,
                column,
                depth + 1
            )
        Option.none:
            pass

    # Reverse-alias search: `extending` methods on a re-exported type live in
    # the aliasing module's binding under the local alias name (e.g.
    # `type Image = c.Image` + `extending Image:` in std.raylib registers
    # `Image.draw_pixel` there, while the receiver type resolved to the source
    # module std.c.raylib).  Scan visible bindings for an alias that resolves
    # to this exact imported type and check its member keys.
    if alias_binding_has_member(ctx, module_name, type_name, member):
        return types.Type.ty_error

    if is_method_call:
        analyzer.report(ctx, line, column, analyzer.unknown_member_message("method", type_name, member))
    else:
        analyzer.report(ctx, line, column, analyzer.unknown_member_message("field", type_name, member))
    return types.Type.ty_error


## True when any visible module binding re-exports `module_name.type_name`
## through a type alias and declares `member` on that alias via `extending`.
public function alias_binding_has_member(ctx: ref[analyzer.Context], module_name: str, type_name: str, member: str) -> bool:
    let imported = ctx.imported_modules else:
        return false
    unsafe:
        var binding_entries = read(imported).entries()
        while binding_entries.next():
            let entry = binding_entries.current()
            let candidate = read(entry.value)
            # A module that declares `extending <alias>.<Type>:` on an imported
            # type registers the method under the *resolved* name (`b3Vec3`),
            # which is exactly what this receiver resolved to.
            if analyzer.binding_has_member(candidate, type_name, member):
                return true
            var alias_entries = candidate.type_alias_types.entries()
            while alias_entries.next():
                let alias_entry = alias_entries.current()
                match read(alias_entry.value):
                    types.Type.ty_imported as im:
                        let im_bp = unsafe: read(im.payload)
                        if im_bp.module_name == module_name and im_bp.name == type_name:
                            if analyzer.binding_has_member(candidate, read(alias_entry.key), member):
                                return true
                    _:
                        pass
    return false

## Resolve a member access on a receiver.  For a locally-declared struct
## instance, a member must be a field, an `extending` method, or the builtin
## `with`; anything else is reported ("unknown field" for a read, "unknown
## method" when the member is the callee of a call).  Field reads yield the
## field type; everything else (methods, non-struct receivers) is permissive.
public function check_member(
    ctx: ref[analyzer.Context],
    receiver: types.Type,
    member: str,
    is_method_call: bool,
    line: ptr_uint,
    column: ptr_uint
) -> types.Type:
    match receiver:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return analyzer.check_named_member(ctx, n_np.module_name, n_np.name, member, is_method_call, line, column)
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return analyzer.check_imported_receiver_member(
                ctx,
                im_bp.module_name,
                im_bp.name,
                im_bp.args,
                member,
                is_method_call,
                line,
                column
            )
        types.Type.ty_variant_arm_payload as ap:
            # A bound match arm (`Option.some as p`) is the arm's payload struct
            # — the host's `Types::VariantArmPayload` — so `p.value` reads the
            # field the analyzer substituted for the scrutinee's arguments.
            let payload = unsafe: read(ap.payload)
            var fi: ptr_uint = 0
            while fi < payload.fields.len:
                let field = unsafe: read(payload.fields.data + fi)
                if field.name == member:
                    return field.ty
                fi += 1
            return types.Type.ty_error
        types.Type.ty_var as v:
            return analyzer.check_type_var_member(ctx, v.name, member, is_method_call, line, column)
        types.Type.ty_str:
            # The host's `Types::StringView#fields`: `data: ptr[char]` and
            # `len: ptr_uint`.  Every other member (an `extending str:` method)
            # stays on the permissive path.
            if member.equal("data"):
                return types.generic_type(name = "ptr", args = analyzer.alloc_one_type_arg(types.primitive("char")))
            if member.equal("len"):
                return types.primitive("ptr_uint")
            return types.Type.ty_error
        types.Type.ty_primitive as p:
            return analyzer.check_primitive_member(p.name, member)
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return analyzer.check_generic_member(ctx, g_bp.name, g_bp.args, member, is_method_call, line, column)
        types.Type.ty_tuple as tp:
            let tp_bp = unsafe: read(tp.payload)
            # A positional tuple reads `._0`/`._1`; a named tuple's elements read
            # by name (the host's `Tuple#field`, whose positional names are `_N`).
            var index: int = -1
            match tp_bp.field_names:
                Option.some as names:
                    var ni: ptr_uint = 0
                    while ni < names.value.len and index < 0:
                        if unsafe: read(names.value.data + ni) == member:
                            index = int<-ni
                        ni += 1
                Option.none:
                    index = analyzer.positional_tuple_index(member)
            if index >= 0 and ptr_uint<-index < tp_bp.elements.len:
                return unsafe: read(tp_bp.elements.data + ptr_uint<-index)
            return types.Type.ty_error
        _:
            return types.Type.ty_error

## Resolve `alias.Type.member` where `alias` is an imported module and `Type` is
## one of its exported enums/flags/variants: validate that `member` is a member
## of that type, flagging it otherwise.  None for anything else.
public function imported_static_member(
    ctx: ref[analyzer.Context],
    scope: ref[sscope.Scope],
    receiver: ptr[ast.Expr],
    member: str,
    line: ptr_uint,
    column: ptr_uint
) -> Option[types.Type]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_member_access as inner:
                match read(inner.receiver):
                    ast.Expr.expr_identifier as id:
                        if analyzer.scope_get(scope, id.name) != null:
                            return Option[types.Type].none
                        let module_name_ptr = ctx.import_aliases.get(id.name) else:
                            return Option[types.Type].none
                        let binding_ptr = analyzer.find_binding(ctx, read(module_name_ptr)) else:
                            return Option[types.Type].none
                        if not read(binding_ptr).static_member_types.contains(inner.member_name):
                            return Option[types.Type].none
                        if not analyzer.binding_has_member(read(binding_ptr), inner.member_name, member):
                            analyzer.report(ctx, line, column, analyzer.unknown_member_message("member", inner.member_name, member))
                        return Option[types.Type].some(value = types.imported_type(
                            module_name = read(module_name_ptr),
                            name = inner.member_name,
                            args = span[types.Type]()
                        ))
                    _:
                        return Option[types.Type].none
            _:
                return Option[types.Type].none


## Some(type name) when `receiver` is a bare identifier naming a locally-declared
## enum/flags/variant that is not shadowed by a local value.
public function static_type_receiver(ctx: ref[analyzer.Context], scope: ref[sscope.Scope], receiver: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if analyzer.scope_get(scope, id.name) != null:
                    return Option[str].none
                if ctx.static_member_types.contains(id.name):
                    return Option[str].some(value = id.name)
                return Option[str].none
            _:
                return Option[str].none


## The struct type named by a static-method receiver: a bare local struct name
## (`Counter`) or an imported `alias.Struct`.  None for values, enum/variant type
## names (handled as static members), or unknown names.
public function static_struct_receiver_type(
    ctx: ref[analyzer.Context],
    scope: ref[sscope.Scope],
    receiver: ptr[ast.Expr]
) -> Option[types.Type]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if analyzer.scope_get(scope, id.name) != null:
                    return Option[types.Type].none
                if ctx.structs.contains(id.name):
                    return Option[types.Type].some(value = types.named_type(
                        name = id.name,
                        module_name = "",
                        linkage_name = Option[str].none
                    ))
                return Option[types.Type].none
            ast.Expr.expr_member_access as inner:
                match read(inner.receiver):
                    ast.Expr.expr_identifier as alias_id:
                        if analyzer.scope_get(scope, alias_id.name) != null:
                            return Option[types.Type].none
                        let module_name_ptr = ctx.import_aliases.get(alias_id.name) else:
                            return Option[types.Type].none
                        let binding_ptr = analyzer.find_binding(ctx, read(module_name_ptr)) else:
                            return Option[types.Type].none
                        if read(binding_ptr).structs.contains(inner.member_name):
                            return Option[types.Type].some(value = types.imported_type(
                                module_name = read(module_name_ptr),
                                name = inner.member_name,
                                args = span[types.Type]()
                            ))
                        return Option[types.Type].none
                    _:
                        return Option[types.Type].none
            _:
                return Option[types.Type].none


## A receiver identifier that names a builtin type (`mat4.identity()`), not
## shadowed by a local and not one of the module's own structs or static-member
## types (those take the earlier arms).
public function static_builtin_type_name(ctx: ref[analyzer.Context], scope: ref[sscope.Scope], receiver: ptr[ast.Expr]) -> Option[str]:
    unsafe:
        match read(receiver):
            ast.Expr.expr_identifier as id:
                if analyzer.scope_get(scope, id.name) != null:
                    return Option[str].none
                if ctx.structs.contains(id.name) or ctx.static_member_types.contains(id.name):
                    return Option[str].none
                if ctx.types.contains(id.name) or analyzer.is_primitive_type_name(id.name):
                    return Option[str].some(value = id.name)
                return Option[str].none
            _:
                return Option[str].none


## The inferred receiver type of the member access whose member name starts at
## `line`:`column` (1-based), when the receiver is not a plain name/field chain.
## None for the chains `receiver_path_type` already resolves.
public function member_receiver_type_at(
    analysis: ref[analyzer.Analysis],
    line: ptr_uint,
    column: ptr_uint
) -> Option[types.Type]:
    let ty_ptr = unsafe: read(analysis).member_receiver_types.get(analyzer.binding_key(line, column))
    if ty_ptr == null:
        return Option[types.Type].none
    return Option[types.Type].some(value = unsafe: read(ty_ptr))


## True when `ep` is `alias.member` and `member` is an exported constant of the
## imported module.  The self records imported constants under a qualified name
## but cannot fold one whose initializer references the imported module's own
## imports (`std.sdl3`'s `ALPHA_OPAQUE = c.SDL_ALPHA_OPAQUE`); the host folds it
## before the FFI range check.  The call site skips the range test for this
## narrow shape rather than rejecting a valid foreign call.
public function is_imported_constant_member(ctx: ref[analyzer.Context], ep: ptr[ast.Expr]?) -> bool:
    let expr = ep else:
        return false
    unsafe:
        match read(expr):
            ast.Expr.expr_member_access as ma:
                match read(ma.receiver):
                    ast.Expr.expr_identifier as rid:
                        if not ctx.import_aliases.contains(rid.name):
                            return false
                        let module_name_ptr = ctx.import_aliases.get(rid.name) else:
                            return false
                        let binding_ptr = analyzer.find_binding(ctx, read(module_name_ptr)) else:
                            return false
                        return read(binding_ptr).const_values.contains(ma.member_name)
                    _:
                        return false
            _:
                return false
