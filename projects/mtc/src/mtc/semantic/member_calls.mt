## Member-call checking, extracted from semantic/analyzer.mt.

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
            return analyzer.check_typed_method_call(
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
                    return analyzer.check_typed_method_call(
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
            return analyzer.check_typed_method_call(
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
    return analyzer.check_typed_method_call(ctx, member_recv, method_name, args, arg_types, any_named, line, column)
