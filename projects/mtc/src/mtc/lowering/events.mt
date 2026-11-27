## Event runtime lowering, extracted from lowering/lowering.mt (Wave 4.2).

import std.vec as vec
import std.map as map_mod
import std.str
import std.string as string

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.strings
import mtc.c_naming as naming

import mtc.lowering.control_flow as control_flow
import mtc.lowering.format as format
import mtc.lowering.lowering as lowering
import mtc.lowering.match as match_mod
import mtc.lowering.tasks as tasks
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.utils as utils


function event_value_type(info: ref[lowering.EventRuntimeInfo]) -> types.Type:
    var ev_payload: ptr[types.Type]? = null
    if info.has_payload:
        ev_payload = types.alloc_type(info.payload_type)
    return types.event_type(
        name = info.name,
        capacity = info.capacity,
        payload_type = ev_payload,
        linkage_name = info.event_c_name
    )


## The typed stateless listener: the host's `event_listener_function_type`,
## `fn <event>__listener(payload?) -> void`.


function event_listener_type(info: ref[lowering.EventRuntimeInfo]) -> types.Type:
    var params = vec.Vec[types.Type].create()
    var names = vec.Vec[str].create()
    if info.has_payload:
        params.push(info.payload_type)
        names.push("payload")
    return types.function_type(
        name = strings.join_two(info.name, "__listener"),
        params = params.as_span(),
        return_type = types.alloc_type(types.primitive("void")),
        variadic = false,
        is_proc = false,
        param_names = names.as_span()
    )


## The typed stateful listener: the host's `event_stateful_listener_function_type`,
## `fn <event>__stateful_listener(ptr[void], payload?) -> void`.


function event_stateful_listener_type(info: ref[lowering.EventRuntimeInfo]) -> types.Type:
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))
    var params = vec.Vec[types.Type].create()
    var names = vec.Vec[str].create()
    params.push(void_ptr_ty)
    names.push("state")
    if info.has_payload:
        params.push(info.payload_type)
        names.push("payload")
    return types.function_type(
        name = strings.join_two(info.name, "__stateful_listener"),
        params = params.as_span(),
        return_type = types.alloc_type(types.primitive("void")),
        variadic = false,
        is_proc = false,
        param_names = names.as_span()
    )

# =============================================================================
#  str_buffer[N] builtin struct
# =============================================================================

## Ensure a str_buffer[N] struct declaration is registered.  The struct has fields
## { data: array[char, N+1]; len: ptr_uint; dirty: bool }.  N is a literal integer
## encoded as ty_literal_int.  Only emits once per N.


public function event_name_from_type(t: types.Type) -> str:
    match t:
        types.Type.ty_event as e:
            let e_bp = unsafe: read(e.payload)
            return e_bp.name
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if n_np.name.starts_with("mt_event_"):
                return event_name_from_c_linkage(n_np.name)
            return n_np.name
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            if im_bp.name.starts_with("mt_event_"):
                return event_name_from_c_linkage(im_bp.name)
            return im_bp.name
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return g_bp.name
        _:
            fatal(c"event type is not ty_named")


## Remove the trailing _<digits> capacity suffix from an event struct C name.


public function event_info_for_owner(ctx: ref[lowering.LoweringContext], owner: str, name: str) -> Option[analyzer.EventInfo]:
    let key = analyzer.event_registry_key(owner, name)
    let keyed = ctx.analysis.events.get(key)
    if keyed != null:
        return Option[analyzer.EventInfo].some(value = unsafe: read(keyed))
    return Option[analyzer.EventInfo].none


## The sanitized owner path of an expression's receiver type — the host's
## `event_member_from_owner_type` unwrap ladder: `Window` for a top-level
## struct, `Container_Inner` for a nested one (its type links as
## `<module>_Container_Inner`), and the unwrapped element for `ptr`/`const_ptr`/
## `ref`/`own`/nullable wrappers.


function event_owner_for_receiver(ctx: ref[lowering.LoweringContext], t: types.Type) -> str:
    var base = t
    while true:
        match base:
            types.Type.ty_nullable as nl:
                base = unsafe: read(nl.base)
            types.Type.ty_generic as g:
                let g_bp = unsafe: read(g.payload)
                if (g_bp.name == "ptr" or g_bp.name == "const_ptr" or g_bp.name == "ref" or g_bp.name == "own") and g_bp.args.len == 1:
                    base = unsafe: read(g_bp.args.data + 0)
                else:
                    return ""
            _:
                break
    match base:
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            match n_np.linkage_name:
                Option.some as lk:
                    let prefix = strings.join_two(naming.sanitize_event_part(ctx.module_name), "_")
                    let linkage = lk.value
                    if linkage.len > prefix.len and linkage.starts_with(prefix):
                        return linkage.slice(prefix.len, linkage.len - prefix.len)
                    return n_np.name
                Option.none:
                    return n_np.name
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return im_bp.name
        _:
            return ""


## The event a member access names on a receiver of type `recv_ty`, if any.


public function event_info_for_receiver(
    ctx: ref[lowering.LoweringContext],
    recv_ty: types.Type,
    member: str
) -> Option[analyzer.EventInfo]:
    return event_info_for_owner(ctx, event_owner_for_receiver(ctx, recv_ty), member)


## The runtime of an event-typed receiver (`window.closed.emit()`): a
## `ty_event` carries the runtime linkage the member access already resolved, so
## look the runtime up by it; a bare module-level event name resolves directly.


function event_runtime_for_type(ctx: ref[lowering.LoweringContext], t: types.Type) -> lowering.EventRuntimeInfo:
    match t:
        types.Type.ty_event as e:
            let e_bp = unsafe: read(e.payload)
            var iter = ctx.caches.event_runtimes.entries()
            while true:
                if not iter.next():
                    break
                unsafe:
                    let info = read(iter.current().value)
                    if info.event_c_name == e_bp.linkage_name:
                        return info
        _:
            pass
    let ev_name = event_name_from_type(t)
    return ensure_event_runtime(ctx, "", ev_name)




function event_name_from_c_linkage(name: str) -> str:
    var rest = name.slice(8, name.len - 8)
    let base = lowering.strip_event_cap_suffix(rest)
    return base


## Create the EventError enum (backing: int) — the host's
## `ensure_event_error_enum` pushes the builtin enum into
## `@artifacts.synthetic_enums` once.  Returns the named type.


function ensure_event_error_enum(ctx: ref[lowering.LoweringContext]) -> types.Type:
    if not ctx.event_error_emitted:
        let int_ty = types.primitive("int")
        var members = vec.Vec[ir.EnumMember].create()
        members.push(ir.EnumMember(
            name = "full",
            linkage_name = "EventError_full",
            value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = int_ty)),
        ))
        ctx.pending_synthetic_enums.push(ir.EnumDecl(
            name = "EventError",
            linkage_name = "EventError",
            backing_type = int_ty,
            members = members.as_span(),
            is_flags = false,
        ))
        ctx.event_error_emitted = true
    return types.named_type(name = "EventError", module_name = "", linkage_name = Option[str].none)


## Ensure event runtime structs are declared (slot type, event type, subscript type).
## Called lazily on first event method call.


public function ensure_event_runtime(ctx: ref[lowering.LoweringContext], owner: str, event_name: str) -> lowering.EventRuntimeInfo:
    let runtime_key = analyzer.event_registry_key(owner, event_name)
    let existing_ptr = ctx.caches.event_runtimes.get(runtime_key)
    if existing_ptr != null:
        return unsafe: read(existing_ptr)
    var ev_ptr = ctx.analysis.events.get(runtime_key)
    if ev_ptr == null and owner.len > 0:
        ev_ptr = ctx.analysis.events.get(event_name)
    let found_ev = ev_ptr else:
        fatal(c"ensure_event_runtime: event not found")
    var ev = unsafe: read(found_ev)
    let ptr_uint_ty = types.primitive("ptr_uint")
    let bool_ty = ctx.bool_ty
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(ctx.void_ty))
    var has_payload = false
    var payload_ty = ctx.void_ty
    if ev.payload_type != null:
        has_payload = true
        let pt = ev.payload_type else:
            fatal(c"ensure_event_runtime: payload type is null")
        payload_ty = lowering.resolve_type_ref(ctx, pt)
    var payload_name: Option[str] = Option[str].none
    if has_payload:
        payload_name = Option[str].some(value = naming.type_to_s_qualified(payload_ty))
    let linkage = naming.event_linkage_name(
        ctx.module_name,
        ev.owner_type_name,
        event_name,
        payload_name,
        long<-(ev.capacity)
    )
    let slot_cn = strings.join_two(linkage, "__slot")
    let snapshot_cn = strings.join_two(linkage, "__snapshot")
    let event_cn = linkage
    # Subscription struct: { slot, generation } — the shared handle.  The host's
    # `ensure_subscription_runtime` runs before the first per-event struct, and
    # its IR name is the builtin type's `Subscription` (linkage
    # `mt_subscription`).
    if not ctx.subscription_emitted:
        ctx.pending_synthetic_structs.push(ir.StructDecl(
            name = "Subscription", linkage_name = "mt_subscription",
            fields = lowering.sp_field2(
                ir.Field(name = "slot", ty = ptr_uint_ty),
                ir.Field(name = "generation", ty = ptr_uint_ty),
            ),
            packed = false, alignment = 0, source_module = Option[str].none,
        ))
        ctx.subscription_emitted = true
    # Slot struct: { active, once, generation, state, listener, wait_frame }
    ctx.pending_synthetic_structs.push(ir.StructDecl(
        name = slot_cn, linkage_name = slot_cn,
        fields = lowering.sp_field6(
            ir.Field(name = "active", ty = bool_ty),
            ir.Field(name = "once", ty = bool_ty),
            ir.Field(name = "generation", ty = ptr_uint_ty),
            ir.Field(name = "state", ty = void_ptr_ty),
            ir.Field(name = "listener", ty = void_ptr_ty),
            ir.Field(name = "wait_frame", ty = void_ptr_ty),
        ),
        packed = false, alignment = 0, source_module = Option[str].none,
    ))
    # Snapshot struct: { slot, generation, once, wait_slot, stateful, state, listener }
    ctx.pending_synthetic_structs.push(ir.StructDecl(
        name = snapshot_cn, linkage_name = snapshot_cn,
        fields = lowering.sp_field7(
            ir.Field(name = "slot", ty = ptr_uint_ty),
            ir.Field(name = "generation", ty = ptr_uint_ty),
            ir.Field(name = "once", ty = bool_ty),
            ir.Field(name = "wait_slot", ty = bool_ty),
            ir.Field(name = "stateful", ty = bool_ty),
            ir.Field(name = "state", ty = void_ptr_ty),
            ir.Field(name = "listener", ty = void_ptr_ty),
        ),
        packed = false, alignment = 0, source_module = Option[str].none,
    ))
    let event_error_ty = ensure_event_error_enum(ctx)
    var wait_result_args = vec.Vec[types.Type].create()
    if has_payload:
        wait_result_args.push(payload_ty)
    else:
        wait_result_args.push(ctx.void_ty)
    wait_result_args.push(event_error_ty)
    let wait_result_ty = lowering.ensure_generic_variant(ctx, "Result", wait_result_args.as_span())
    let wake_fn_ty = types.function_type(
        name = "",
        params = lowering.single_ty_span(void_ptr_ty),
        return_type = types.alloc_type(ctx.void_ty),
        variadic = false,
        is_proc = false,
        param_names = lowering.sp_str("frame")
    )
    let wait_frame_cn = strings.join_two(linkage, "__wait_frame")
    ctx.pending_synthetic_structs.push(ir.StructDecl(
        name = wait_frame_cn, linkage_name = wait_frame_cn,
        fields = lowering.sp_field6(
            ir.Field(name = "ready", ty = bool_ty),
            ir.Field(name = "waiter_frame", ty = void_ptr_ty),
            ir.Field(name = "waiter", ty = wake_fn_ty),
            ir.Field(name = "event", ty = void_ptr_ty),
            ir.Field(
                name = "subscription",
                ty = types.named_type(
                    name = "Subscription",
                    module_name = "",
                    linkage_name = Option[str].some(value = "mt_subscription")
                )
            ),
            ir.Field(name = "result", ty = wait_result_ty),
        ),
        packed = false, alignment = 0, source_module = Option[str].none,
    ))
    # Event struct: { slots: array[Slot, capacity] }.  Its IR name is the bare
    # event name (the host's `Types::Event#name`) while the linkage carries the
    # module/owner/name/payload/capacity identity.
    let capacity_val: long = long<-(ev.capacity)
    let slot_ty = types.named_type(name = slot_cn, module_name = "", linkage_name = Option[str].none)
    let slot_arr_ty = types.generic_type(name = "array", args = lowering.sp_type2(slot_ty, types.literal_int(capacity_val)))
    ctx.pending_synthetic_structs.push(ir.StructDecl(
        name = event_name, linkage_name = event_cn,
        fields = lowering.sp_field1(ir.Field(name = "slots", ty = slot_arr_ty)),
        packed = false, alignment = 0, source_module = Option[str].none,
    ))
    var info = lowering.EventRuntimeInfo(
        name = event_name, linkage_name = linkage, capacity = ptr_uint<-(ev.capacity),
        has_payload = has_payload, payload_type = payload_ty,
        owner = ev.owner_type_name,
        slot_c_name = slot_cn, event_c_name = event_cn,
        subscribe_c_name = strings.join_two(linkage, "__subscribe"),
        subscribe_once_c_name = strings.join_two(linkage, "__subscribe_once"),
        subscribe_stateful_c_name = strings.join_two(linkage, "__subscribe_stateful"),
        subscribe_once_stateful_c_name = strings.join_two(linkage, "__subscribe_once_stateful"),
        unsubscribe_c_name = strings.join_two(linkage, "__unsubscribe"),
        emit_c_name = strings.join_two(linkage, "__emit"),
        wait_c_name = strings.join_two(linkage, "__wait"),
        wait_frame_c_name = wait_frame_cn,
        wait_ready_c_name = strings.join_two(linkage, "__wait__ready"),
        wait_set_waiter_c_name = strings.join_two(linkage, "__wait__set_waiter"),
        wait_release_c_name = strings.join_two(linkage, "__wait__release"),
        wait_take_result_c_name = strings.join_two(linkage, "__wait__take_result"),
        wait_result_ty = wait_result_ty,
    )
    ctx.caches.event_runtimes.set(runtime_key, info)
    ctx.pending_synthetic_functions.push(build_event_subscribe_fn(ctx, ref_of(info), slot_cn, event_cn, false))
    ctx.pending_synthetic_functions.push(build_event_subscribe_fn(ctx, ref_of(info), slot_cn, event_cn, true))
    ctx.pending_synthetic_functions.push(build_event_subscribe_stateful_fn(ctx, ref_of(info), slot_cn, event_cn, false))
    ctx.pending_synthetic_functions.push(build_event_subscribe_stateful_fn(ctx, ref_of(info), slot_cn, event_cn, true))
    ctx.pending_synthetic_functions.push(build_event_unsubscribe_fn(ref_of(info), slot_cn, event_cn))
    ctx.pending_synthetic_functions.push(build_event_emit_fn(ref_of(info), slot_cn, event_cn))
    ctx.pending_synthetic_functions.push(build_event_wait_ready_fn(ref_of(info), slot_cn, event_cn))
    ctx.pending_synthetic_functions.push(build_event_wait_set_waiter_fn(ref_of(info), slot_cn, event_cn))
    ctx.pending_synthetic_functions.push(build_event_wait_release_fn(ref_of(info), slot_cn, event_cn))
    ctx.pending_synthetic_functions.push(build_event_wait_take_result_fn(ctx, ref_of(info), slot_cn, event_cn))
    ctx.pending_synthetic_functions.push(build_event_wait_fn(ctx, ref_of(info), slot_cn, event_cn))
    return info


## Generates calls to per-event typed functions (mt_event_NAME__emit etc.).


public function lower_event_method(
    ctx: ref[lowering.LoweringContext],
    recv: ptr[ir.Expr],
    recv_ty: types.Type,
    method_name: str,
    args: span[ast.Argument],
    call_ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    var info = event_runtime_for_type(ctx, recv_ty)
    let void_ty = ctx.void_ty
    let bool_ty = ctx.bool_ty
    # The receiver pointer's element type is the event itself (`ptr[Types::Event]`
    # in the host's `lower_event_storage_pointer`), which the C backend renders
    # through the event's linkage name.
    var recv_event_ty = recv_ty
    match recv_event_ty:
        types.Type.ty_event:
            pass
        _:
            var ev_payload: ptr[types.Type]? = null
            if info.has_payload:
                ev_payload = types.alloc_type(info.payload_type)
            recv_event_ty = types.event_type(
                name = info.name,
                capacity = info.capacity,
                payload_type = ev_payload,
                linkage_name = info.event_c_name
            )
    let event_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(recv_event_ty))
    let recv_addr = lowering.alloc_expr(ir.Expr.expr_address_of(expression = recv, ty = event_ptr_ty))
    if method_name == "emit":
        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(recv_addr))
        if info.has_payload:
            let payload_val = lowering.lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
            unsafe:
                call_args.push(read(payload_val))
        return lowering.alloc_expr(ir.Expr.expr_call(callee = info.emit_c_name, arguments = call_args.as_span(), ty = void_ty))
    if method_name == "subscribe" or method_name == "subscribe_once":
        let is_stateful = args.len >= 2
        var callee: str
        if is_stateful:
            callee = if method_name == "subscribe": info.subscribe_stateful_c_name else: info.subscribe_once_stateful_c_name
        else:
            callee = if method_name == "subscribe": info.subscribe_c_name else: info.subscribe_once_c_name
        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(recv_addr))
        if is_stateful:
            let state_val = lowering.lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
            unsafe:
                call_args.push(read(state_val))
            let listener_val = lowering.lower_expr(ctx, unsafe: read(args.data + 1).arg_value)
            unsafe:
                call_args.push(read(listener_val))
        else:
            # The plain listener is the typed `fn <event>__listener(...) -> void`;
            # the host's contextual lowering passes the function value directly
            # (only the stateful form, whose slot stores a `void*`, casts).
            let listener_val = lowering.lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
            unsafe:
                call_args.push(read(listener_val))
        let sub_plain_ty = types.named_type(
            name = "Subscription",
            module_name = "",
            linkage_name = Option[str].some(value = "mt_subscription")
        )
        let event_error_ty = ensure_event_error_enum(ctx)
        var result_args = vec.Vec[types.Type].create()
        result_args.push(sub_plain_ty)
        result_args.push(event_error_ty)
        let sub_ty = lowering.ensure_generic_variant(ctx, "Result", result_args.as_span())
        return lowering.alloc_expr(ir.Expr.expr_call(callee = callee, arguments = call_args.as_span(), ty = sub_ty))
    if method_name == "unsubscribe":
        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(recv_addr))
        let sub_val = lowering.lower_expr(ctx, unsafe: read(args.data + 0).arg_value)
        unsafe:
            call_args.push(read(sub_val))
        return lowering.alloc_expr(ir.Expr.expr_call(
            callee = info.unsubscribe_c_name,
            arguments = call_args.as_span(),
            ty = bool_ty
        ))
    if method_name == "wait":
        var call_args = vec.Vec[ir.Expr].create()
        unsafe:
            call_args.push(read(recv_addr))
        let event_error_ty = ensure_event_error_enum(ctx)
        var wait_result_args = vec.Vec[types.Type].create()
        if info.has_payload:
            wait_result_args.push(info.payload_type)
        else:
            wait_result_args.push(ctx.void_ty)
        wait_result_args.push(event_error_ty)
        let wait_result_ty = lowering.ensure_generic_variant(ctx, "Result", wait_result_args.as_span())
        let task_ty = tasks.make_task_type(wait_result_ty)
        return lowering.alloc_expr(ir.Expr.expr_call(callee = info.wait_c_name, arguments = call_args.as_span(), ty = task_ty))
    lowering.fail_lowering_cstr(ctx, c"lowering: unknown event method")
    return lowering.poison_expr()


## The host's `event_slot_pointer_expr`: `&event->slots[index]`.


function event_slot_pointer_expr(
    info: ref[lowering.EventRuntimeInfo],
    event_expr: ptr[ir.Expr],
    slot_index_expr: ptr[ir.Expr]
) -> ptr[ir.Expr]:
    let slot_ty = types.named_type(name = info.slot_c_name, module_name = "", linkage_name = Option[str].none)
    let slots_ty = types.generic_type(
        name = "array",
        args = lowering.sp_type2(slot_ty, types.literal_int(long<-(info.capacity)))
    )
    let slots_member = lowering.alloc_expr(ir.Expr.expr_member(receiver = event_expr, member = "slots", ty = slots_ty))
    let slot_index = lowering.alloc_expr(ir.Expr.expr_index(receiver = slots_member, index = slot_index_expr, ty = slot_ty))
    return lowering.alloc_expr(ir.Expr.expr_address_of(
        expression = slot_index,
        ty = types.generic_type(name = "ptr", args = lowering.sp_type(slot_ty))
    ))


## The host's `event_slot_local_decl`: `__mt_slot = &event->slots[index]`.


function event_slot_local_decl(
    info: ref[lowering.EventRuntimeInfo],
    event_expr: ptr[ir.Expr],
    slot_index_expr: ptr[ir.Expr],
    local_name: str
) -> ir.Stmt:
    let slot_ty = types.named_type(name = info.slot_c_name, module_name = "", linkage_name = Option[str].none)
    return ir.Stmt.stmt_local(
        name = local_name,
        linkage_name = local_name,
        ty = types.generic_type(name = "ptr", args = lowering.sp_type(slot_ty)),
        value = event_slot_pointer_expr(info, event_expr, slot_index_expr),
        line = 0,
        source_path = "",
    )




function event_slot_field_expr(slot_pointer_expr: ptr[ir.Expr], field_name: str, field_ty: types.Type) -> ptr[ir.Expr]:
    return lowering.alloc_expr(ir.Expr.expr_member(receiver = slot_pointer_expr, member = field_name, ty = field_ty))




public function event_slot_active_expr(slot_pointer_expr: ptr[ir.Expr]) -> ptr[ir.Expr]:
    return event_slot_field_expr(slot_pointer_expr, "active", types.primitive("bool"))




function event_slot_wait_frame_expr(slot_pointer_expr: ptr[ir.Expr]) -> ptr[ir.Expr]:
    return event_slot_field_expr(
        slot_pointer_expr,
        "wait_frame",
        types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))
    )




function event_next_generation_expr(slot_pointer_expr: ptr[ir.Expr]) -> ptr[ir.Expr]:
    let generation = event_slot_field_expr(slot_pointer_expr, "generation", types.primitive("ptr_uint"))
    return lowering.alloc_expr(ir.Expr.expr_binary(
        operator = "+",
        left = generation,
        right = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = types.primitive("ptr_uint"))),
        ty = types.primitive("ptr_uint")
    ))




function event_slot_assign(target: ptr[ir.Expr], value: ptr[ir.Expr]) -> ir.Stmt:
    return ir.Stmt.stmt_assignment(target = target, operator = "=", value = value)


## The host's `event_slot_activate_statements`: the shared slot-activation
## prefix.  `listener_expr` is nil for `wait` (which never stores a listener).


function event_slot_activate_statements(
    info: ref[lowering.EventRuntimeInfo],
    slot_pointer_expr: ptr[ir.Expr],
    generation_expr: ptr[ir.Expr],
    once: bool,
    wait_frame_expr: ptr[ir.Expr],
    listener_expr: ptr[ir.Expr]?
) -> span[ir.Stmt]:
    let bool_ty = types.primitive("bool")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))
    var statements = vec.Vec[ir.Stmt].create()
    statements.push(event_slot_assign(
        event_slot_active_expr(slot_pointer_expr),
        lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))
    ))
    statements.push(event_slot_assign(
        event_slot_field_expr(slot_pointer_expr, "once", bool_ty),
        lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = once, ty = bool_ty))
    ))
    statements.push(event_slot_assign(
        event_slot_field_expr(slot_pointer_expr, "generation", ptr_uint_ty),
        generation_expr
    ))
    statements.push(event_slot_assign(
        event_slot_field_expr(slot_pointer_expr, "state", void_ptr_ty),
        lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty))
    ))
    if listener_expr != null:
        let le = unsafe: ptr[ir.Expr]<-listener_expr
        statements.push(event_slot_assign(
            event_slot_field_expr(slot_pointer_expr, "listener", event_listener_type(info)),
            le
        ))
    statements.push(event_slot_assign(event_slot_wait_frame_expr(slot_pointer_expr), wait_frame_expr))
    return statements.as_span()


## The host's `event_slot_activate_stateful_statements`: same prefix, but the
## slot's `state` field receives the caller's state pointer.


function event_slot_activate_stateful_statements(
    info: ref[lowering.EventRuntimeInfo],
    slot_pointer_expr: ptr[ir.Expr],
    generation_expr: ptr[ir.Expr],
    once: bool,
    state_expr: ptr[ir.Expr],
    wait_frame_expr: ptr[ir.Expr],
    listener_expr: ptr[ir.Expr]
) -> span[ir.Stmt]:
    let bool_ty = types.primitive("bool")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))
    var statements = vec.Vec[ir.Stmt].create()
    statements.push(event_slot_assign(
        event_slot_active_expr(slot_pointer_expr),
        lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))
    ))
    statements.push(event_slot_assign(
        event_slot_field_expr(slot_pointer_expr, "once", bool_ty),
        lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = once, ty = bool_ty))
    ))
    statements.push(event_slot_assign(
        event_slot_field_expr(slot_pointer_expr, "generation", ptr_uint_ty),
        generation_expr
    ))
    statements.push(event_slot_assign(event_slot_field_expr(slot_pointer_expr, "state", void_ptr_ty), state_expr))
    statements.push(event_slot_assign(
        event_slot_field_expr(slot_pointer_expr, "listener", event_listener_type(info)),
        listener_expr
    ))
    statements.push(event_slot_assign(event_slot_wait_frame_expr(slot_pointer_expr), wait_frame_expr))
    return statements.as_span()


## The host's `event_slot_clear_statements`.


function event_slot_clear_statements(slot_pointer_expr: ptr[ir.Expr]) -> span[ir.Stmt]:
    let bool_ty = types.primitive("bool")
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))
    var statements = vec.Vec[ir.Stmt].create()
    statements.push(event_slot_assign(
        event_slot_active_expr(slot_pointer_expr),
        lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = false, ty = bool_ty))
    ))
    statements.push(event_slot_assign(
        event_slot_field_expr(slot_pointer_expr, "once", bool_ty),
        lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = false, ty = bool_ty))
    ))
    statements.push(event_slot_assign(
        event_slot_wait_frame_expr(slot_pointer_expr),
        lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty))
    ))
    return statements.as_span()


## The host's `snapshot_field_expression`: `snapshots[index].field`.


function event_snapshot_field_expr(
    info: ref[lowering.EventRuntimeInfo],
    snapshots_expr: ptr[ir.Expr],
    index_expr: ptr[ir.Expr],
    field_name: str,
    field_ty: types.Type
) -> ptr[ir.Expr]:
    let snapshot_ty = types.named_type(
        name = strings.join_two(info.linkage_name, "__snapshot"),
        module_name = "",
        linkage_name = Option[str].none
    )
    let snapshot_index = lowering.alloc_expr(ir.Expr.expr_index(receiver = snapshots_expr, index = index_expr, ty = snapshot_ty))
    return lowering.alloc_expr(ir.Expr.expr_member(receiver = snapshot_index, member = field_name, ty = field_ty))




function event_subscription_field_expr(
    subscription_expr: ptr[ir.Expr],
    field_name: str,
    field_ty: types.Type
) -> ptr[ir.Expr]:
    return lowering.alloc_expr(ir.Expr.expr_member(receiver = subscription_expr, member = field_name, ty = field_ty))




function event_wait_frame_field_expr(frame_expr: ptr[ir.Expr], field_name: str, field_ty: types.Type) -> ptr[ir.Expr]:
    return lowering.alloc_expr(ir.Expr.expr_member(receiver = frame_expr, member = field_name, ty = field_ty))




function event_subscription_literal(slot_expr: ptr[ir.Expr], generation_expr: ptr[ir.Expr]) -> ptr[ir.Expr]:
    let sub_ty = types.named_type(
        name = "Subscription",
        module_name = "",
        linkage_name = Option[str].some(value = "mt_subscription")
    )
    var fields = vec.Vec[ir.AggregateField].create()
    fields.push(ir.AggregateField(name = "slot", value = slot_expr))
    fields.push(ir.AggregateField(name = "generation", value = generation_expr))
    return lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = sub_ty, fields = fields.as_span()))




function event_subscription_success_literal(
    result_type: types.Type,
    slot_expr: ptr[ir.Expr],
    generation_expr: ptr[ir.Expr]
) -> ptr[ir.Expr]:
    var fields = vec.Vec[ir.AggregateField].create()
    fields.push(ir.AggregateField(name = "value", value = event_subscription_literal(slot_expr, generation_expr)))
    return lowering.alloc_expr(ir.Expr.expr_variant_literal(ty = result_type, arm_name = "success", fields = fields.as_span()))


## The host's `void_value_expr`: `(void) 0`.


function event_wait_success_literal(result_type: types.Type, payload_expr: ptr[ir.Expr]?) -> ptr[ir.Expr]:
    var value = lowering.void_value_expr()
    if payload_expr != null:
        value = unsafe: ptr[ir.Expr]<-payload_expr
    var fields = vec.Vec[ir.AggregateField].create()
    fields.push(ir.AggregateField(name = "value", value = value))
    return lowering.alloc_expr(ir.Expr.expr_variant_literal(ty = result_type, arm_name = "success", fields = fields.as_span()))




function event_failure_literal(event_error_ty: types.Type, result_type: types.Type) -> ptr[ir.Expr]:
    let error_name = lowering.alloc_expr(ir.Expr.expr_name(
        name = "EventError_full",
        ty = event_error_ty,
        pointer = Option[bool].some(value = false)
    ))
    var fields = vec.Vec[ir.AggregateField].create()
    fields.push(ir.AggregateField(name = "error", value = error_name))
    return lowering.alloc_expr(ir.Expr.expr_variant_literal(ty = result_type, arm_name = "failure", fields = fields.as_span()))




function event_unsubscribe_call(
    info: ref[lowering.EventRuntimeInfo],
    event_expr: ptr[ir.Expr],
    subscription_expr: ptr[ir.Expr]
) -> ptr[ir.Expr]:
    return lowering.alloc_expr(ir.Expr.expr_call(
        callee = info.unsubscribe_c_name,
        arguments = lowering.sp_expr2(event_expr, subscription_expr),
        ty = types.primitive("void"),
    ))




function event_listener_call_expr(
    info: ref[lowering.EventRuntimeInfo],
    snapshots_expr: ptr[ir.Expr],
    dispatch_index_expr: ptr[ir.Expr],
    payload_expr: ptr[ir.Expr]?
) -> ptr[ir.Expr]:
    let listener_ty = event_listener_type(info)
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))
    let listener = lowering.alloc_expr(ir.Expr.expr_cast(
        target_type = listener_ty,
        expression = event_snapshot_field_expr(info, snapshots_expr, dispatch_index_expr, "listener", void_ptr_ty),
        ty = listener_ty,
    ))
    var arguments = vec.Vec[ir.Expr].create()
    if payload_expr != null:
        unsafe:
            arguments.push(read(unsafe: ptr[ir.Expr]<-payload_expr))
    return lowering.alloc_expr(ir.Expr.expr_call_indirect(
        callee = listener,
        arguments = arguments.as_span(),
        ty = types.primitive("void")
    ))




function event_stateful_listener_call_expr(
    info: ref[lowering.EventRuntimeInfo],
    snapshots_expr: ptr[ir.Expr],
    dispatch_index_expr: ptr[ir.Expr],
    payload_expr: ptr[ir.Expr]?
) -> ptr[ir.Expr]:
    let listener_ty = event_stateful_listener_type(info)
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))
    let listener = lowering.alloc_expr(ir.Expr.expr_cast(
        target_type = listener_ty,
        expression = event_snapshot_field_expr(info, snapshots_expr, dispatch_index_expr, "listener", void_ptr_ty),
        ty = listener_ty,
    ))
    var arguments = vec.Vec[ir.Expr].create()
    unsafe:
        arguments.push(read(event_snapshot_field_expr(info, snapshots_expr, dispatch_index_expr, "state", void_ptr_ty)))
    if payload_expr != null:
        unsafe:
            arguments.push(read(unsafe: ptr[ir.Expr]<-payload_expr))
    return lowering.alloc_expr(ir.Expr.expr_call_indirect(
        callee = listener,
        arguments = arguments.as_span(),
        ty = types.primitive("void")
    ))




function event_task_wake_fn_type() -> types.Type:
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))
    return types.function_type(
        name = "",
        params = lowering.single_ty_span(void_ptr_ty),
        return_type = types.alloc_type(types.primitive("void")),
        variadic = false,
        is_proc = false,
        param_names = lowering.sp_str("frame")
    )


## The host's `Types::Task#field` type for the given field name.


function event_task_field_type(info: ref[lowering.EventRuntimeInfo], field_name: str) -> types.Type:
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))
    if field_name == "frame":
        return void_ptr_ty
    if field_name == "ready":
        return types.function_type(
            name = "",
            params = lowering.single_ty_span(void_ptr_ty),
            return_type = types.alloc_type(types.primitive("bool")),
            variadic = false,
            is_proc = false,
            param_names = lowering.sp_str("frame")
        )
    if field_name == "set_waiter":
        var params = vec.Vec[types.Type].create()
        var names = vec.Vec[str].create()
        params.push(void_ptr_ty)
        names.push("frame")
        params.push(void_ptr_ty)
        names.push("waiter_frame")
        params.push(event_task_wake_fn_type())
        names.push("waiter")
        return types.function_type(
            name = "",
            params = params.as_span(),
            return_type = types.alloc_type(types.primitive("void")),
            variadic = false,
            is_proc = false,
            param_names = names.as_span()
        )
    if field_name == "release" or field_name == "cancel":
        return types.function_type(
            name = "",
            params = lowering.single_ty_span(void_ptr_ty),
            return_type = types.alloc_type(types.primitive("void")),
            variadic = false,
            is_proc = false,
            param_names = lowering.sp_str("frame")
        )
    if field_name == "take_result":
        return types.function_type(
            name = "",
            params = lowering.single_ty_span(void_ptr_ty),
            return_type = types.alloc_type(info.wait_result_ty),
            variadic = false,
            is_proc = false,
            param_names = lowering.sp_str("frame")
        )
    fatal(c"event_task_field_type: unknown Task field")




function event_task_literal_from_raw_frame(info: ref[lowering.EventRuntimeInfo], raw_frame_expr: ptr[ir.Expr]) -> ptr[ir.Expr]:
    let task_ty = tasks.make_task_type(info.wait_result_ty)
    var fields = vec.Vec[ir.AggregateField].create()
    fields.push(ir.AggregateField(name = "frame", value = raw_frame_expr))
    fields.push(ir.AggregateField(
        name = "ready",
        value = lowering.alloc_expr(ir.Expr.expr_name(
            name = info.wait_ready_c_name,
            ty = event_task_field_type(info, "ready"),
            pointer = Option[bool].some(value = false)
        ))
    ))
    fields.push(ir.AggregateField(
        name = "set_waiter",
        value = lowering.alloc_expr(ir.Expr.expr_name(
            name = info.wait_set_waiter_c_name,
            ty = event_task_field_type(info, "set_waiter"),
            pointer = Option[bool].some(value = false)
        ))
    ))
    fields.push(ir.AggregateField(
        name = "release",
        value = lowering.alloc_expr(ir.Expr.expr_name(
            name = info.wait_release_c_name,
            ty = event_task_field_type(info, "release"),
            pointer = Option[bool].some(value = false)
        ))
    ))
    fields.push(ir.AggregateField(
        name = "take_result",
        value = lowering.alloc_expr(ir.Expr.expr_name(
            name = info.wait_take_result_c_name,
            ty = event_task_field_type(info, "take_result"),
            pointer = Option[bool].some(value = false)
        ))
    ))
    return lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = task_ty, fields = fields.as_span()))




function event_task_literal(info: ref[lowering.EventRuntimeInfo], frame_expr: ptr[ir.Expr]) -> ptr[ir.Expr]:
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))
    let raw_frame_expr = lowering.alloc_expr(ir.Expr.expr_cast(
        target_type = void_ptr_ty,
        expression = frame_expr,
        ty = void_ptr_ty
    ))
    return event_task_literal_from_raw_frame(info, raw_frame_expr)




function event_immediate_failure_task_literal(info: ref[lowering.EventRuntimeInfo]) -> ptr[ir.Expr]:
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))
    return event_task_literal_from_raw_frame(info, lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty)))


## Build a per-event subscribe (or subscribe_once) synthetic function.


public function build_event_subscribe_fn(
    ctx: ref[lowering.LoweringContext],
    info: ref[lowering.EventRuntimeInfo],
    slot_cn: str,
    event_cn: str,
    once: bool
) -> ir.Function:
    let void_ty = ctx.void_ty
    let bool_ty = ctx.bool_ty
    let ptr_uint_ty = types.primitive("ptr_uint")
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(void_ty))
    let sub_plain_ty = types.named_type(
        name = "Subscription",
        module_name = "",
        linkage_name = Option[str].some(value = "mt_subscription")
    )
    let event_error_ty = ensure_event_error_enum(ctx)
    var result_args = vec.Vec[types.Type].create()
    result_args.push(sub_plain_ty)
    result_args.push(event_error_ty)
    let sub_result_ty = lowering.ensure_generic_variant(ctx, "Result", result_args.as_span())
    let slot_ty = types.named_type(name = info.slot_c_name, module_name = "", linkage_name = Option[str].none)
    let slot_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(slot_ty))
    let event_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(event_value_type(info)))
    let listener_ty = event_listener_type(info)
    let callee = if once: info.subscribe_once_c_name else: info.subscribe_c_name
    let event_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "event",
        ty = event_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let listener_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "listener",
        ty = listener_ty,
        pointer = Option[bool].some(value = false)
    ))
    let slot_index_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_slot_index",
        ty = ptr_uint_ty,
        pointer = Option[bool].some(value = false)
    ))
    let generation_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_generation",
        ty = ptr_uint_ty,
        pointer = Option[bool].some(value = false)
    ))
    let slot_pointer_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_slot",
        ty = slot_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let cap_lit = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))
    let cond = lowering.alloc_expr(ir.Expr.expr_binary(operator = "<", left = slot_index_expr, right = cap_lit, ty = bool_ty))
    let post = lowering.alloc_stmt(ir.Stmt.stmt_assignment(
        target = slot_index_expr,
        operator = "+=",
        value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))
    ))
    let init = lowering.alloc_stmt(ir.Stmt.stmt_local(
        name = "__mt_slot_index",
        linkage_name = "__mt_slot_index",
        ty = ptr_uint_ty,
        value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)),
        line = 0,
        source_path = ""
    ))
    var loop_body = vec.Vec[ir.Stmt].create()
    loop_body.push(event_slot_local_decl(info, event_expr, slot_index_expr, "__mt_slot"))
    loop_body.push(lowering.active_event_slot_continue_guard(slot_pointer_expr))
    loop_body.push(ir.Stmt.stmt_local(
        name = "__mt_generation",
        linkage_name = "__mt_generation",
        ty = ptr_uint_ty,
        value = event_next_generation_expr(slot_pointer_expr),
        line = 0,
        source_path = ""
    ))
    let listener_cast = lowering.alloc_expr(ir.Expr.expr_cast(
        target_type = void_ptr_ty,
        expression = listener_expr,
        ty = void_ptr_ty
    ))
    let activate = event_slot_activate_statements(
        info,
        slot_pointer_expr,
        generation_expr,
        once,
        lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty)),
        listener_cast
    )
    var ai: ptr_uint = 0
    while ai < activate.len:
        unsafe:
            loop_body.push(read(activate.data + ai))
        ai += 1
    loop_body.push(ir.Stmt.stmt_return(
        value = event_subscription_success_literal(sub_result_ty, slot_index_expr, generation_expr),
        line = 0,
        source_path = ""
    ))
    var body = vec.Vec[ir.Stmt].create()
    body.push(ir.Stmt.stmt_for(init = init, condition = cond, post = post, body = loop_body.as_span()))
    body.push(ir.Stmt.stmt_return(
        value = event_failure_literal(event_error_ty, sub_result_ty),
        line = 0,
        source_path = ""
    ))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(
        name = "event",
        linkage_name = "event",
        ty = event_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    params.push(ir.Param(
        name = "listener",
        linkage_name = "listener",
        ty = listener_ty,
        pointer = Option[bool].some(value = false)
    ))
    return ir.Function(
        source_module = Option[str].none,
        name = strings.join_two(callee, "_fn"),
        linkage_name = callee,
        params = params.as_span(),
        return_type = sub_result_ty,
        body = body.as_span(),
        entry_point = false,
        public_export = false,
        method_receiver_param = false
    )


## Build a per-event stateful subscribe (or subscribe_once) synthetic function.
## Same as build_event_subscribe_fn but also accepts a `state: ptr[void]`
## parameter and writes it into the slot's `state` field.


public function build_event_subscribe_stateful_fn(
    ctx: ref[lowering.LoweringContext],
    info: ref[lowering.EventRuntimeInfo],
    slot_cn: str,
    event_cn: str,
    once: bool
) -> ir.Function:
    let void_ty = ctx.void_ty
    let bool_ty = ctx.bool_ty
    let ptr_uint_ty = types.primitive("ptr_uint")
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(void_ty))
    let sub_plain_ty = types.named_type(
        name = "Subscription",
        module_name = "",
        linkage_name = Option[str].some(value = "mt_subscription")
    )
    let event_error_ty = ensure_event_error_enum(ctx)
    var result_args = vec.Vec[types.Type].create()
    result_args.push(sub_plain_ty)
    result_args.push(event_error_ty)
    let sub_result_ty = lowering.ensure_generic_variant(ctx, "Result", result_args.as_span())
    let slot_ty = types.named_type(name = info.slot_c_name, module_name = "", linkage_name = Option[str].none)
    let slot_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(slot_ty))
    let event_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(event_value_type(info)))
    var callee: str
    if once:
        callee = info.subscribe_once_stateful_c_name
    else:
        callee = info.subscribe_stateful_c_name
    let event_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "event",
        ty = event_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let state_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "state",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let listener_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "listener",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let slot_index_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_slot_index",
        ty = ptr_uint_ty,
        pointer = Option[bool].some(value = false)
    ))
    let generation_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_generation",
        ty = ptr_uint_ty,
        pointer = Option[bool].some(value = false)
    ))
    let slot_pointer_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_slot",
        ty = slot_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let cap_lit = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))
    let cond = lowering.alloc_expr(ir.Expr.expr_binary(operator = "<", left = slot_index_expr, right = cap_lit, ty = bool_ty))
    let post = lowering.alloc_stmt(ir.Stmt.stmt_assignment(
        target = slot_index_expr,
        operator = "+=",
        value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))
    ))
    let init = lowering.alloc_stmt(ir.Stmt.stmt_local(
        name = "__mt_slot_index",
        linkage_name = "__mt_slot_index",
        ty = ptr_uint_ty,
        value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)),
        line = 0,
        source_path = ""
    ))
    var loop_body = vec.Vec[ir.Stmt].create()
    loop_body.push(event_slot_local_decl(info, event_expr, slot_index_expr, "__mt_slot"))
    loop_body.push(lowering.active_event_slot_continue_guard(slot_pointer_expr))
    loop_body.push(ir.Stmt.stmt_local(
        name = "__mt_generation",
        linkage_name = "__mt_generation",
        ty = ptr_uint_ty,
        value = event_next_generation_expr(slot_pointer_expr),
        line = 0,
        source_path = ""
    ))
    let activate = event_slot_activate_stateful_statements(
        info,
        slot_pointer_expr,
        generation_expr,
        once,
        state_expr,
        lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty)),
        listener_expr
    )
    var ai: ptr_uint = 0
    while ai < activate.len:
        unsafe:
            loop_body.push(read(activate.data + ai))
        ai += 1
    loop_body.push(ir.Stmt.stmt_return(
        value = event_subscription_success_literal(sub_result_ty, slot_index_expr, generation_expr),
        line = 0,
        source_path = ""
    ))
    var body = vec.Vec[ir.Stmt].create()
    body.push(ir.Stmt.stmt_for(init = init, condition = cond, post = post, body = loop_body.as_span()))
    body.push(ir.Stmt.stmt_return(
        value = event_failure_literal(event_error_ty, sub_result_ty),
        line = 0,
        source_path = ""
    ))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(
        name = "event",
        linkage_name = "event",
        ty = event_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    params.push(ir.Param(
        name = "state",
        linkage_name = "state",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    params.push(ir.Param(
        name = "listener",
        linkage_name = "listener",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    return ir.Function(
        source_module = Option[str].none,
        name = strings.join_two(callee, "_fn"),
        linkage_name = callee,
        params = params.as_span(),
        return_type = sub_result_ty,
        body = body.as_span(),
        entry_point = false,
        public_export = false,
        method_receiver_param = false
    )


## Build a per-event unsubscribe synthetic function.


function build_event_unsubscribe_fn(info: ref[lowering.EventRuntimeInfo], slot_cn: str, event_cn: str) -> ir.Function:
    let bool_ty = types.primitive("bool")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let slot_ty = types.named_type(name = info.slot_c_name, module_name = "", linkage_name = Option[str].none)
    let slot_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(slot_ty))
    let event_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(event_value_type(info)))
    let sub_ty = types.named_type(
        name = "Subscription",
        module_name = "",
        linkage_name = Option[str].some(value = "mt_subscription")
    )
    let event_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "event",
        ty = event_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let subscription_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "subscription",
        ty = sub_ty,
        pointer = Option[bool].some(value = false)
    ))
    let slot_index_expr = event_subscription_field_expr(subscription_expr, "slot", ptr_uint_ty)
    let slot_pointer_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_slot",
        ty = slot_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let false_value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = false, ty = bool_ty))
    let true_value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))
    let cap_lit = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))
    var body = vec.Vec[ir.Stmt].create()
    body.push(ir.Stmt.stmt_if(
        condition = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = ">=",
            left = slot_index_expr,
            right = cap_lit,
            ty = bool_ty
        )),
        then_body = lowering.span_from_one(ir.Stmt.stmt_return(value = false_value, line = 0, source_path = "")),
        else_body = Option[span[ir.Stmt]].none,
    ))
    body.push(event_slot_local_decl(info, event_expr, slot_index_expr, "__mt_slot"))
    body.push(ir.Stmt.stmt_if(
        condition = lowering.alloc_expr(ir.Expr.expr_unary(
            operator = "not",
            operand = event_slot_active_expr(slot_pointer_expr),
            ty = bool_ty
        )),
        then_body = lowering.span_from_one(ir.Stmt.stmt_return(value = false_value, line = 0, source_path = "")),
        else_body = Option[span[ir.Stmt]].none,
    ))
    body.push(ir.Stmt.stmt_if(
        condition = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "!=",
            left = event_slot_field_expr(slot_pointer_expr, "generation", ptr_uint_ty),
            right = event_subscription_field_expr(subscription_expr, "generation", ptr_uint_ty),
            ty = bool_ty,
        )),
        then_body = lowering.span_from_one(ir.Stmt.stmt_return(value = false_value, line = 0, source_path = "")),
        else_body = Option[span[ir.Stmt]].none,
    ))
    let clear = event_slot_clear_statements(slot_pointer_expr)
    var ci: ptr_uint = 0
    while ci < clear.len:
        unsafe:
            body.push(read(clear.data + ci))
        ci += 1
    body.push(ir.Stmt.stmt_return(value = true_value, line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(
        name = "event",
        linkage_name = "event",
        ty = event_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    params.push(ir.Param(
        name = "subscription",
        linkage_name = "subscription",
        ty = sub_ty,
        pointer = Option[bool].some(value = false)
    ))
    return ir.Function(
        source_module = Option[str].none,
        name = strings.join_two(info.unsubscribe_c_name, "_fn"),
        linkage_name = info.unsubscribe_c_name,
        params = params.as_span(),
        return_type = bool_ty,
        body = body.as_span(),
        entry_point = false,
        public_export = false,
        method_receiver_param = false
    )


## Build a per-event emit synthetic function.


function build_event_emit_fn(info: ref[lowering.EventRuntimeInfo], slot_cn: str, event_cn: str) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let ptr_uint_ty = types.primitive("ptr_uint")
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(void_ty))
    let slot_ty = types.named_type(name = info.slot_c_name, module_name = "", linkage_name = Option[str].none)
    let slot_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(slot_ty))
    let snapshot_ty = types.named_type(
        name = strings.join_two(info.linkage_name, "__snapshot"),
        module_name = "",
        linkage_name = Option[str].none
    )
    let snapshots_ty = types.generic_type(
        name = "array",
        args = lowering.sp_type2(snapshot_ty, types.literal_int(long<-(info.capacity)))
    )
    let wait_frame_ty = types.named_type(
        name = info.wait_frame_c_name,
        module_name = "",
        linkage_name = Option[str].none
    )
    let wait_frame_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(wait_frame_ty))
    let event_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(event_value_type(info)))
    let event_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "event",
        ty = event_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let snapshots_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_snapshots",
        ty = snapshots_ty,
        pointer = Option[bool].some(value = false)
    ))
    let snapshot_count_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_snapshot_count",
        ty = ptr_uint_ty,
        pointer = Option[bool].some(value = false)
    ))
    let slot_index_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_slot_index",
        ty = ptr_uint_ty,
        pointer = Option[bool].some(value = false)
    ))
    let dispatch_index_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_dispatch_index",
        ty = ptr_uint_ty,
        pointer = Option[bool].some(value = false)
    ))
    let slot_pointer_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_slot",
        ty = slot_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let frame_pointer_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_wait_frame",
        ty = wait_frame_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    var payload_expr: ptr[ir.Expr]? = null
    if info.has_payload:
        payload_expr = lowering.alloc_expr(ir.Expr.expr_name(
            name = "payload",
            ty = info.payload_type,
            pointer = Option[bool].some(value = false)
        ))

    let cap_lit = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))
    var collect_body = vec.Vec[ir.Stmt].create()
    collect_body.push(event_slot_local_decl(info, event_expr, slot_index_expr, "__mt_slot"))
    collect_body.push(lowering.inactive_event_slot_continue_guard(slot_pointer_expr))
    collect_body.push(event_slot_assign(
        event_snapshot_field_expr(info, snapshots_expr, snapshot_count_expr, "slot", ptr_uint_ty),
        slot_index_expr
    ))
    collect_body.push(event_slot_assign(
        event_snapshot_field_expr(info, snapshots_expr, snapshot_count_expr, "generation", ptr_uint_ty),
        event_slot_field_expr(slot_pointer_expr, "generation", ptr_uint_ty)
    ))
    collect_body.push(event_slot_assign(
        event_snapshot_field_expr(info, snapshots_expr, snapshot_count_expr, "once", bool_ty),
        event_slot_field_expr(slot_pointer_expr, "once", bool_ty)
    ))
    collect_body.push(event_slot_assign(
        event_snapshot_field_expr(info, snapshots_expr, snapshot_count_expr, "wait_slot", bool_ty),
        lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "!=",
            left = event_slot_wait_frame_expr(slot_pointer_expr),
            right = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty)),
            ty = bool_ty,
        )),
    ))
    collect_body.push(event_slot_assign(
        event_snapshot_field_expr(info, snapshots_expr, snapshot_count_expr, "stateful", bool_ty),
        lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "!=",
            left = event_slot_field_expr(slot_pointer_expr, "state", void_ptr_ty),
            right = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty)),
            ty = bool_ty,
        )),
    ))
    collect_body.push(event_slot_assign(
        event_snapshot_field_expr(info, snapshots_expr, snapshot_count_expr, "state", void_ptr_ty),
        event_slot_field_expr(slot_pointer_expr, "state", void_ptr_ty)
    ))
    collect_body.push(event_slot_assign(
        event_snapshot_field_expr(info, snapshots_expr, snapshot_count_expr, "listener", void_ptr_ty),
        event_slot_field_expr(slot_pointer_expr, "listener", void_ptr_ty)
    ))
    collect_body.push(ir.Stmt.stmt_assignment(
        target = snapshot_count_expr,
        operator = "+=",
        value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))
    ))

    let snapshot_subscription_expr = event_subscription_literal(
        event_snapshot_field_expr(info, snapshots_expr, dispatch_index_expr, "slot", ptr_uint_ty),
        event_snapshot_field_expr(info, snapshots_expr, dispatch_index_expr, "generation", ptr_uint_ty),
    )
    let wait_slot_condition = lowering.alloc_expr(ir.Expr.expr_binary(
        operator = "and",
        left = event_slot_active_expr(slot_pointer_expr),
        right = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "and",
            left = lowering.alloc_expr(ir.Expr.expr_binary(
                operator = "==",
                left = event_slot_field_expr(slot_pointer_expr, "generation", ptr_uint_ty),
                right = event_snapshot_field_expr(info, snapshots_expr, dispatch_index_expr, "generation", ptr_uint_ty),
                ty = bool_ty,
            )),
            right = lowering.alloc_expr(ir.Expr.expr_binary(
                operator = "!=",
                left = event_slot_wait_frame_expr(slot_pointer_expr),
                right = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty)),
                ty = bool_ty,
            )),
            ty = bool_ty,
        )),
        ty = bool_ty,
    ))
    let waiter_frame_expr = event_wait_frame_field_expr(frame_pointer_expr, "waiter_frame", void_ptr_ty)
    var wait_then_body = vec.Vec[ir.Stmt].create()
    wait_then_body.push(ir.Stmt.stmt_local(
        name = "__mt_wait_frame",
        linkage_name = "__mt_wait_frame",
        ty = wait_frame_ptr_ty,
        value = lowering.alloc_expr(ir.Expr.expr_cast(
            target_type = wait_frame_ptr_ty,
            expression = event_slot_wait_frame_expr(slot_pointer_expr),
            ty = wait_frame_ptr_ty
        )),
        line = 0,
        source_path = "",
    ))
    wait_then_body.push(ir.Stmt.stmt_expression(
        expression = event_unsubscribe_call(info, event_expr, snapshot_subscription_expr),
        line = 0,
        source_path = ""
    ))
    wait_then_body.push(event_slot_assign(
        event_wait_frame_field_expr(frame_pointer_expr, "result", info.wait_result_ty),
        event_wait_success_literal(info.wait_result_ty, payload_expr)
    ))
    wait_then_body.push(event_slot_assign(
        event_wait_frame_field_expr(frame_pointer_expr, "ready", bool_ty),
        lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty))
    ))
    var wake_body = vec.Vec[ir.Stmt].create()
    wake_body.push(ir.Stmt.stmt_local(
        name = "__mt_waiter_frame",
        linkage_name = "__mt_waiter_frame",
        ty = void_ptr_ty,
        value = waiter_frame_expr,
        line = 0,
        source_path = ""
    ))
    wake_body.push(event_slot_assign(waiter_frame_expr, lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty))))
    wake_body.push(ir.Stmt.stmt_expression(
        expression = lowering.alloc_expr(ir.Expr.expr_call_indirect(
            callee = event_wait_frame_field_expr(frame_pointer_expr, "waiter", event_task_wake_fn_type()),
            arguments = lowering.single_expr_span(lowering.alloc_expr(ir.Expr.expr_name(
                name = "__mt_waiter_frame",
                ty = void_ptr_ty,
                pointer = Option[bool].some(value = false)
            ))),
            ty = void_ty,
        )),
        line = 0,
        source_path = "",
    ))
    wait_then_body.push(ir.Stmt.stmt_if(
        condition = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "!=",
            left = waiter_frame_expr,
            right = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty)),
            ty = bool_ty,
        )),
        then_body = wake_body.as_span(),
        else_body = Option[span[ir.Stmt]].none,
    ))
    var dispatch_body = vec.Vec[ir.Stmt].create()
    var already_handled_body = vec.Vec[ir.Stmt].create()
    already_handled_body.push(ir.Stmt.stmt_if(
        condition = event_snapshot_field_expr(info, snapshots_expr, dispatch_index_expr, "once", bool_ty),
        then_body = lowering.span_from_one(ir.Stmt.stmt_expression(
            expression = event_unsubscribe_call(info, event_expr, snapshot_subscription_expr),
            line = 0,
            source_path = ""
        )),
        else_body = Option[span[ir.Stmt]].none,
    ))
    already_handled_body.push(ir.Stmt.stmt_if(
        condition = event_snapshot_field_expr(info, snapshots_expr, dispatch_index_expr, "stateful", bool_ty),
        then_body = lowering.span_from_one(ir.Stmt.stmt_expression(
            expression = event_stateful_listener_call_expr(info, snapshots_expr, dispatch_index_expr, payload_expr),
            line = 0,
            source_path = ""
        )),
        else_body = Option[span[ir.Stmt]].some(value = lowering.span_from_one(ir.Stmt.stmt_expression(
            expression = event_listener_call_expr(info, snapshots_expr, dispatch_index_expr, payload_expr),
            line = 0,
            source_path = ""
        ))),
    ))
    var wait_slot_body = vec.Vec[ir.Stmt].create()
    wait_slot_body.push(event_slot_local_decl(
        info,
        event_expr,
        event_snapshot_field_expr(info, snapshots_expr, dispatch_index_expr, "slot", ptr_uint_ty),
        "__mt_slot",
    ))
    wait_slot_body.push(ir.Stmt.stmt_if(
        condition = wait_slot_condition,
        then_body = wait_then_body.as_span(),
        else_body = Option[span[ir.Stmt]].none
    ))
    dispatch_body.push(ir.Stmt.stmt_if(
        condition = event_snapshot_field_expr(info, snapshots_expr, dispatch_index_expr, "wait_slot", bool_ty),
        then_body = wait_slot_body.as_span(),
        else_body = Option[span[ir.Stmt]].some(value = already_handled_body.as_span()),
    ))
    var body = vec.Vec[ir.Stmt].create()
    body.push(ir.Stmt.stmt_local(
        name = "__mt_snapshots",
        linkage_name = "__mt_snapshots",
        ty = snapshots_ty,
        value = lowering.alloc_expr(ir.Expr.expr_zero_init(ty = snapshots_ty)),
        line = 0,
        source_path = ""
    ))
    body.push(ir.Stmt.stmt_local(
        name = "__mt_snapshot_count",
        linkage_name = "__mt_snapshot_count",
        ty = ptr_uint_ty,
        value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)),
        line = 0,
        source_path = ""
    ))
    body.push(ir.Stmt.stmt_for(
        init = lowering.alloc_stmt(ir.Stmt.stmt_local(
            name = "__mt_slot_index",
            linkage_name = "__mt_slot_index",
            ty = ptr_uint_ty,
            value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)),
            line = 0,
            source_path = ""
        )),
        condition = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "<",
            left = slot_index_expr,
            right = cap_lit,
            ty = bool_ty
        )),
        post = lowering.alloc_stmt(ir.Stmt.stmt_assignment(
            target = slot_index_expr,
            operator = "+=",
            value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))
        )),
        body = collect_body.as_span(),
    ))
    body.push(ir.Stmt.stmt_for(
        init = lowering.alloc_stmt(ir.Stmt.stmt_local(
            name = "__mt_dispatch_index",
            linkage_name = "__mt_dispatch_index",
            ty = ptr_uint_ty,
            value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)),
            line = 0,
            source_path = ""
        )),
        condition = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "<",
            left = dispatch_index_expr,
            right = snapshot_count_expr,
            ty = bool_ty
        )),
        post = lowering.alloc_stmt(ir.Stmt.stmt_assignment(
            target = dispatch_index_expr,
            operator = "+=",
            value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))
        )),
        body = dispatch_body.as_span(),
    ))
    body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(
        name = "event",
        linkage_name = "event",
        ty = event_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    if info.has_payload:
        params.push(ir.Param(
            name = "payload",
            linkage_name = "payload",
            ty = info.payload_type,
            pointer = Option[bool].some(value = false)
        ))
    return ir.Function(
        source_module = Option[str].none,
        name = strings.join_two(info.emit_c_name, "_fn"),
        linkage_name = info.emit_c_name,
        params = params.as_span(),
        return_type = void_ty,
        body = body.as_span(),
        entry_point = false,
        public_export = false,
        method_receiver_param = false
    )


## Build a per-event wait ready vtable function.
## Checks if the wait frame is ready.


function build_event_wait_ready_fn(info: ref[lowering.EventRuntimeInfo], slot_cn: str, event_cn: str) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(void_ty))
    let wf_ptr_ty = types.generic_type(
        name = "ptr",
        args = lowering.sp_type(types.named_type(
            name = info.wait_frame_c_name,
            module_name = "",
            linkage_name = Option[str].none
        ))
    )
    let raw_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "frame",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let frame_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_wait_frame",
        ty = wf_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    var body = vec.Vec[ir.Stmt].create()
    body.push(ir.Stmt.stmt_if(
        condition = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "==",
            left = raw_expr,
            right = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty)),
            ty = bool_ty
        )),
        then_body = lowering.span_from_one(ir.Stmt.stmt_return(
            value = lowering.alloc_expr(ir.Expr.expr_boolean_literal(value = true, ty = bool_ty)),
            line = 0,
            source_path = ""
        )),
        else_body = Option[span[ir.Stmt]].none,
    ))
    body.push(ir.Stmt.stmt_local(
        name = "__mt_wait_frame",
        linkage_name = "__mt_wait_frame",
        ty = wf_ptr_ty,
        value = lowering.alloc_expr(ir.Expr.expr_cast(target_type = wf_ptr_ty, expression = raw_expr, ty = wf_ptr_ty)),
        line = 0,
        source_path = ""
    ))
    body.push(ir.Stmt.stmt_return(
        value = event_wait_frame_field_expr(frame_expr, "ready", bool_ty),
        line = 0,
        source_path = ""
    ))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(
        name = "frame",
        linkage_name = "frame",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    return ir.Function(
        source_module = Option[str].none,
        name = strings.join_two(info.wait_ready_c_name, "_fn"),
        linkage_name = info.wait_ready_c_name,
        params = params.as_span(),
        return_type = bool_ty,
        body = body.as_span(),
        entry_point = false,
        public_export = false,
        method_receiver_param = false
    )


## Build a per-event wait set_waiter vtable function.
## Stores the waiter in the wait frame, or calls it immediately if already ready.


function build_event_wait_set_waiter_fn(info: ref[lowering.EventRuntimeInfo], slot_cn: str, event_cn: str) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(void_ty))
    let wf_ptr_ty = types.generic_type(
        name = "ptr",
        args = lowering.sp_type(types.named_type(
            name = info.wait_frame_c_name,
            module_name = "",
            linkage_name = Option[str].none
        ))
    )
    let wake_ty = event_task_wake_fn_type()
    let raw_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "frame",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let frame_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_wait_frame",
        ty = wf_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let waiter_frame_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "waiter_frame",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let waiter_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "waiter",
        ty = wake_ty,
        pointer = Option[bool].some(value = false)
    ))
    let call_waiter = ir.Stmt.stmt_expression(
        expression = lowering.alloc_expr(ir.Expr.expr_call_indirect(
            callee = waiter_expr,
            arguments = lowering.single_expr_span(waiter_frame_expr),
            ty = void_ty
        )),
        line = 0,
        source_path = ""
    )
    var body = vec.Vec[ir.Stmt].create()
    var null_then = vec.Vec[ir.Stmt].create()
    null_then.push(call_waiter)
    null_then.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    body.push(ir.Stmt.stmt_if(
        condition = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "==",
            left = raw_expr,
            right = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty)),
            ty = bool_ty
        )),
        then_body = null_then.as_span(),
        else_body = Option[span[ir.Stmt]].none,
    ))
    body.push(ir.Stmt.stmt_local(
        name = "__mt_wait_frame",
        linkage_name = "__mt_wait_frame",
        ty = wf_ptr_ty,
        value = lowering.alloc_expr(ir.Expr.expr_cast(target_type = wf_ptr_ty, expression = raw_expr, ty = wf_ptr_ty)),
        line = 0,
        source_path = ""
    ))
    var ready_then = vec.Vec[ir.Stmt].create()
    ready_then.push(call_waiter)
    ready_then.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    body.push(ir.Stmt.stmt_if(
        condition = event_wait_frame_field_expr(frame_expr, "ready", bool_ty),
        then_body = ready_then.as_span(),
        else_body = Option[span[ir.Stmt]].none,
    ))
    body.push(event_slot_assign(
        event_wait_frame_field_expr(frame_expr, "waiter_frame", void_ptr_ty),
        waiter_frame_expr
    ))
    body.push(event_slot_assign(event_wait_frame_field_expr(frame_expr, "waiter", wake_ty), waiter_expr))
    body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(
        name = "frame",
        linkage_name = "frame",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    params.push(ir.Param(
        name = "waiter_frame",
        linkage_name = "waiter_frame",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    params.push(ir.Param(
        name = "waiter",
        linkage_name = "waiter",
        ty = wake_ty,
        pointer = Option[bool].some(value = false)
    ))
    return ir.Function(
        source_module = Option[str].none,
        name = strings.join_two(info.wait_set_waiter_c_name, "_fn"),
        linkage_name = info.wait_set_waiter_c_name,
        params = params.as_span(),
        return_type = void_ty,
        body = body.as_span(),
        entry_point = false,
        public_export = false,
        method_receiver_param = false
    )


## Build a per-event wait release vtable function.
## Frees the wait frame if not already ready.


function build_event_wait_release_fn(info: ref[lowering.EventRuntimeInfo], slot_cn: str, event_cn: str) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(void_ty))
    let wf_ptr_ty = types.generic_type(
        name = "ptr",
        args = lowering.sp_type(types.named_type(
            name = info.wait_frame_c_name,
            module_name = "",
            linkage_name = Option[str].none
        ))
    )
    let event_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(event_value_type(info)))
    let sub_ty = types.named_type(
        name = "Subscription",
        module_name = "",
        linkage_name = Option[str].some(value = "mt_subscription")
    )
    let raw_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "frame",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let frame_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_wait_frame",
        ty = wf_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    var body = vec.Vec[ir.Stmt].create()
    body.push(ir.Stmt.stmt_if(
        condition = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "==",
            left = raw_expr,
            right = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty)),
            ty = bool_ty
        )),
        then_body = lowering.span_from_one(ir.Stmt.stmt_return(value = null, line = 0, source_path = "")),
        else_body = Option[span[ir.Stmt]].none,
    ))
    body.push(ir.Stmt.stmt_local(
        name = "__mt_wait_frame",
        linkage_name = "__mt_wait_frame",
        ty = wf_ptr_ty,
        value = lowering.alloc_expr(ir.Expr.expr_cast(target_type = wf_ptr_ty, expression = raw_expr, ty = wf_ptr_ty)),
        line = 0,
        source_path = ""
    ))
    let event_cast = lowering.alloc_expr(ir.Expr.expr_cast(
        target_type = event_ptr_ty,
        expression = event_wait_frame_field_expr(frame_expr, "event", void_ptr_ty),
        ty = event_ptr_ty,
    ))
    body.push(ir.Stmt.stmt_if(
        condition = lowering.alloc_expr(ir.Expr.expr_unary(
            operator = "not",
            operand = event_wait_frame_field_expr(frame_expr, "ready", bool_ty),
            ty = bool_ty
        )),
        then_body = lowering.span_from_one(ir.Stmt.stmt_expression(
            expression = event_unsubscribe_call(
                info,
                event_cast,
                event_wait_frame_field_expr(frame_expr, "subscription", sub_ty)
            ),
            line = 0,
            source_path = "",
        )),
        else_body = Option[span[ir.Stmt]].none,
    ))
    body.push(ir.Stmt.stmt_expression(
        expression = lowering.alloc_expr(ir.Expr.expr_call(
            callee = "mt_async_free",
            arguments = lowering.single_expr_span(raw_expr),
            ty = void_ty
        )),
        line = 0,
        source_path = ""
    ))
    body.push(ir.Stmt.stmt_return(value = null, line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(
        name = "frame",
        linkage_name = "frame",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    return ir.Function(
        source_module = Option[str].none,
        name = strings.join_two(info.wait_release_c_name, "_fn"),
        linkage_name = info.wait_release_c_name,
        params = params.as_span(),
        return_type = void_ty,
        body = body.as_span(),
        entry_point = false,
        public_export = false,
        method_receiver_param = false
    )


## Build a per-event wait take_result vtable function.


public function build_event_wait_take_result_fn(
    ctx: ref[lowering.LoweringContext],
    info: ref[lowering.EventRuntimeInfo],
    slot_cn: str,
    event_cn: str
) -> ir.Function:
    let void_ty = types.primitive("void")
    let bool_ty = types.primitive("bool")
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(void_ty))
    let wf_ptr_ty = types.generic_type(
        name = "ptr",
        args = lowering.sp_type(types.named_type(
            name = info.wait_frame_c_name,
            module_name = "",
            linkage_name = Option[str].none
        ))
    )
    let event_error_ty = ensure_event_error_enum(ctx)
    let raw_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "frame",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let frame_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_wait_frame",
        ty = wf_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    var body = vec.Vec[ir.Stmt].create()
    body.push(ir.Stmt.stmt_if(
        condition = lowering.alloc_expr(ir.Expr.expr_binary(
            operator = "==",
            left = raw_expr,
            right = lowering.alloc_expr(ir.Expr.expr_null_literal(ty = void_ptr_ty)),
            ty = bool_ty
        )),
        then_body = lowering.span_from_one(ir.Stmt.stmt_return(
            value = event_failure_literal(event_error_ty, info.wait_result_ty),
            line = 0,
            source_path = ""
        )),
        else_body = Option[span[ir.Stmt]].none,
    ))
    body.push(ir.Stmt.stmt_local(
        name = "__mt_wait_frame",
        linkage_name = "__mt_wait_frame",
        ty = wf_ptr_ty,
        value = lowering.alloc_expr(ir.Expr.expr_cast(target_type = wf_ptr_ty, expression = raw_expr, ty = wf_ptr_ty)),
        line = 0,
        source_path = ""
    ))
    body.push(ir.Stmt.stmt_return(
        value = event_wait_frame_field_expr(frame_expr, "result", info.wait_result_ty),
        line = 0,
        source_path = ""
    ))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(
        name = "frame",
        linkage_name = "frame",
        ty = void_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    return ir.Function(
        source_module = Option[str].none,
        name = strings.join_two(info.wait_take_result_c_name, "_fn"),
        linkage_name = info.wait_take_result_c_name,
        params = params.as_span(),
        return_type = info.wait_result_ty,
        body = body.as_span(),
        entry_point = false,
        public_export = false,
        method_receiver_param = false
    )


## Build the per-event wait function.
## Loops through inactive slots, activates one as subscribe_once with a wait_frame,
## and returns a Task[Result[void_or_payload, EventError]].


public function build_event_wait_fn(
    ctx: ref[lowering.LoweringContext],
    info: ref[lowering.EventRuntimeInfo],
    slot_cn: str,
    event_cn: str
) -> ir.Function:
    let void_ty = ctx.void_ty
    let bool_ty = ctx.bool_ty
    let ptr_uint_ty = types.primitive("ptr_uint")
    let void_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(void_ty))
    let wait_frame_ty = types.named_type(
        name = info.wait_frame_c_name,
        module_name = "",
        linkage_name = Option[str].none
    )
    let wf_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(wait_frame_ty))
    let slot_ty = types.named_type(name = info.slot_c_name, module_name = "", linkage_name = Option[str].none)
    let slot_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(slot_ty))
    let event_ptr_ty = types.generic_type(name = "ptr", args = lowering.sp_type(event_value_type(info)))
    let sub_ty = types.named_type(
        name = "Subscription",
        module_name = "",
        linkage_name = Option[str].some(value = "mt_subscription")
    )
    let task_ty = tasks.make_task_type(info.wait_result_ty)
    let event_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "event",
        ty = event_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let frame_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_wait_frame",
        ty = wf_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let raw_frame_expr = lowering.alloc_expr(ir.Expr.expr_cast(
        target_type = void_ptr_ty,
        expression = frame_expr,
        ty = void_ptr_ty
    ))
    let slot_index_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_slot_index",
        ty = ptr_uint_ty,
        pointer = Option[bool].some(value = false)
    ))
    let generation_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_generation",
        ty = ptr_uint_ty,
        pointer = Option[bool].some(value = false)
    ))
    let slot_pointer_expr = lowering.alloc_expr(ir.Expr.expr_name(
        name = "__mt_slot",
        ty = slot_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    let cap_lit = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = long<-(info.capacity), ty = ptr_uint_ty))
    let cond = lowering.alloc_expr(ir.Expr.expr_binary(operator = "<", left = slot_index_expr, right = cap_lit, ty = bool_ty))
    let post = lowering.alloc_stmt(ir.Stmt.stmt_assignment(
        target = slot_index_expr,
        operator = "+=",
        value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = ptr_uint_ty))
    ))
    let init = lowering.alloc_stmt(ir.Stmt.stmt_local(
        name = "__mt_slot_index",
        linkage_name = "__mt_slot_index",
        ty = ptr_uint_ty,
        value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = ptr_uint_ty)),
        line = 0,
        source_path = ""
    ))
    var loop_body = vec.Vec[ir.Stmt].create()
    loop_body.push(event_slot_local_decl(info, event_expr, slot_index_expr, "__mt_slot"))
    loop_body.push(lowering.active_event_slot_continue_guard(slot_pointer_expr))
    loop_body.push(ir.Stmt.stmt_local(
        name = "__mt_generation",
        linkage_name = "__mt_generation",
        ty = ptr_uint_ty,
        value = event_next_generation_expr(slot_pointer_expr),
        line = 0,
        source_path = ""
    ))
    let wf_size_expr = lowering.alloc_expr(ir.Expr.expr_sizeof(target_type = wait_frame_ty, ty = ptr_uint_ty))
    let alloc_call = lowering.alloc_expr(ir.Expr.expr_call(
        callee = "mt_async_alloc",
        arguments = lowering.single_expr_span(wf_size_expr),
        ty = void_ptr_ty
    ))
    loop_body.push(ir.Stmt.stmt_local(
        name = "__mt_wait_frame",
        linkage_name = "__mt_wait_frame",
        ty = wf_ptr_ty,
        value = lowering.alloc_expr(ir.Expr.expr_cast(target_type = wf_ptr_ty, expression = alloc_call, ty = wf_ptr_ty)),
        line = 0,
        source_path = ""
    ))
    let frame_deref = lowering.alloc_expr(ir.Expr.expr_unary(operator = "*", operand = frame_expr, ty = wait_frame_ty))
    loop_body.push(event_slot_assign(frame_deref, lowering.alloc_expr(ir.Expr.expr_zero_init(ty = wait_frame_ty))))
    let event_cast = lowering.alloc_expr(ir.Expr.expr_cast(target_type = void_ptr_ty, expression = event_expr, ty = void_ptr_ty))
    loop_body.push(event_slot_assign(event_wait_frame_field_expr(frame_expr, "event", void_ptr_ty), event_cast))
    let activate = event_slot_activate_statements(info, slot_pointer_expr, generation_expr, true, raw_frame_expr, null)
    var ai: ptr_uint = 0
    while ai < activate.len:
        unsafe:
            loop_body.push(read(activate.data + ai))
        ai += 1
    loop_body.push(event_slot_assign(
        event_wait_frame_field_expr(frame_expr, "subscription", sub_ty),
        event_subscription_literal(slot_index_expr, generation_expr)
    ))
    loop_body.push(ir.Stmt.stmt_return(value = event_task_literal(info, frame_expr), line = 0, source_path = ""))
    var body = vec.Vec[ir.Stmt].create()
    body.push(ir.Stmt.stmt_for(init = init, condition = cond, post = post, body = loop_body.as_span()))
    body.push(ir.Stmt.stmt_return(value = event_immediate_failure_task_literal(info), line = 0, source_path = ""))
    var params = vec.Vec[ir.Param].create()
    params.push(ir.Param(
        name = "event",
        linkage_name = "event",
        ty = event_ptr_ty,
        pointer = Option[bool].some(value = false)
    ))
    return ir.Function(
        source_module = Option[str].none,
        name = strings.join_two(info.wait_c_name, "_fn"),
        linkage_name = info.wait_c_name,
        params = params.as_span(),
        return_type = task_ty,
        body = body.as_span(),
        entry_point = false,
        public_export = false,
        method_receiver_param = false
    )


## Build a span from a single IR statement.

