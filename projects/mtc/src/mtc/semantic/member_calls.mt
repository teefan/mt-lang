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
    match analyzer.imported_static_member(ctx, scope, receiver, method_name, line, column):
        Option.some as imported_static:
            return imported_static.value
        Option.none:
            pass

    match analyzer.static_type_receiver(ctx, scope, receiver):
        Option.some as tn:
            analyzer.check_static_member(ctx, tn.value, method_name, line, column)
            return types.named_type(name = tn.value, module_name = ctx.module_name, linkage_name = Option[str].none)
        Option.none:
            pass

    match analyzer.static_struct_receiver_type(ctx, scope, receiver):
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
    match analyzer.static_builtin_type_name(ctx, scope, receiver):
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
            let member_ty = analyzer.check_member(ctx, receiver_type, method_name, true, line, column)
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

    match analyzer.static_struct_receiver_type(ctx, scope, receiver):
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
