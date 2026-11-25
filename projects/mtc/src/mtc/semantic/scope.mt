## Lexical scope — nested frame-based binding table for type resolution.
## Extracted from the semantic analyzer so that sub-modules performing
## expression inference or flow refinement can import scope management
## without a circular dependency on the full analyzer.
##
## Mirrors `Scope` in the Ruby compiler's semantic analyzer.

import std.map as map_mod
import std.str
import std.vec as vec

import mtc.semantic.types as types

public struct Scope:
    frames: vec.Vec[map_mod.Map[str, types.Type]]
    let_bindings: vec.Vec[map_mod.Map[str, bool]]
    param_bindings: vec.Vec[map_mod.Map[str, bool]]
    storage_types: vec.Vec[map_mod.Map[str, types.Type]]
    ## The semantic binding id of each name's declaration (the host's
    ## ValueBinding ids, `semantic/analyzer.mt`'s binding-id records).  Only
    ## names bound to a real binding (params, locals, `this`) carry one.
    binding_ids: vec.Vec[map_mod.Map[str, ptr_uint]]


public function scope_create() -> Scope:
    return Scope(
        frames = vec.Vec[map_mod.Map[str, types.Type]].create(),
        let_bindings = vec.Vec[map_mod.Map[str, bool]].create(),
        param_bindings = vec.Vec[map_mod.Map[str, bool]].create(),
        storage_types = vec.Vec[map_mod.Map[str, types.Type]].create(),
        binding_ids = vec.Vec[map_mod.Map[str, ptr_uint]].create(),
    )


public function scope_enter(scope: ref[Scope]) -> void:
    scope.frames.push(map_mod.Map[str, types.Type].create())
    scope.let_bindings.push(map_mod.Map[str, bool].create())
    scope.param_bindings.push(map_mod.Map[str, bool].create())
    scope.storage_types.push(map_mod.Map[str, types.Type].create())
    scope.binding_ids.push(map_mod.Map[str, ptr_uint].create())


public function scope_leave(scope: ref[Scope]) -> void:
    match scope.frames.pop():
        Option.some as frame:
            var released = frame.value
            released.release()
        Option.none:
            pass
    match scope.let_bindings.pop():
        Option.some as let_frame:
            var released = let_frame.value
            released.release()
        Option.none:
            pass
    match scope.param_bindings.pop():
        Option.some as param_frame:
            var released_params = param_frame.value
            released_params.release()
        Option.none:
            pass
    match scope.storage_types.pop():
        Option.some as storage_frame:
            var released = storage_frame.value
            released.release()
        Option.none:
            pass
    match scope.binding_ids.pop():
        Option.some as id_frame:
            var released_ids = id_frame.value
            released_ids.release()
        Option.none:
            pass


## Record the binding id of a name declared in the innermost frame.
public function scope_set_binding_id(scope: ref[Scope], name: str, id: ptr_uint) -> void:
    let count = scope.binding_ids.len()
    if count == 0:
        return
    let frame_ptr = scope.binding_ids.get(count - 1) else:
        return
    unsafe:
        let _prev = read(frame_ptr).set(name, id)


## The innermost declared binding id for `name`, or 0 when the name is not a
## real binding (a module-level value, a type, a function) or was never given
## one.
public function scope_get_binding_id(scope: ref[Scope], name: str) -> ptr_uint:
    var index = scope.binding_ids.len()
    while index > 0:
        index -= 1
        let frame_ptr = scope.binding_ids.get(index) else:
            return 0
        unsafe:
            let found = read(frame_ptr).get(name)
            if found != null:
                return read(found)
    return 0


public function scope_set(scope: ref[Scope], name: str, ty: types.Type) -> void:
    let count = scope.frames.len()
    if count == 0:
        return
    let frame_ptr = scope.frames.get(count - 1) else:
        return
    unsafe:
        let _prev = read(frame_ptr).set(name, ty)


public function scope_get(scope: ref[Scope], name: str) -> ptr[types.Type]?:
    var index = scope.frames.len()
    while index > 0:
        index -= 1
        let frame_ptr = scope.frames.get(index) else:
            return null
        unsafe:
            let found = read(frame_ptr).get(name)
            if found != null:
                return found
    return null


public function scope_is_let(scope: ref[Scope], name: str) -> bool:
    var index = scope.let_bindings.len()
    while index > 0:
        index -= 1
        let frame_ptr = scope.let_bindings.get(index) else:
            return false
        if unsafe: read(frame_ptr).contains(name):
            return true
    return false


public function scope_set_let(scope: ref[Scope], name: str) -> void:
    let count = scope.let_bindings.len()
    if count == 0:
        return
    let frame_ptr = scope.let_bindings.get(count - 1) else:
        return
    unsafe:
        let _prev = read(frame_ptr).set(name, true)


## Mark a name as a function/method/proc parameter (the host's
## `ValueBinding#kind == :param`).  Used by the lvalue-receiver ladder to allow
## a span parameter as an assignment receiver.
public function scope_set_param(scope: ref[Scope], name: str) -> void:
    let count = scope.param_bindings.len()
    if count == 0:
        return
    let frame_ptr = scope.param_bindings.get(count - 1) else:
        return
    unsafe:
        let _prev = read(frame_ptr).set(name, true)


public function scope_is_param(scope: ref[Scope], name: str) -> bool:
    var index = scope.param_bindings.len()
    while index > 0:
        index -= 1
        let frame_ptr = scope.param_bindings.get(index) else:
            return false
        if unsafe: read(frame_ptr).contains(name):
            return true
    return false


## The binding's *storage* type — the declared/initializer type, unaffected by
## flow refinement.  The host's `ValueBinding#storage_type`: an assignment
## target is checked against it (`infer_lvalue`), so a refined non-null binding
## still accepts a nullable value.
public function scope_set_storage(scope: ref[Scope], name: str, ty: types.Type) -> void:
    let count = scope.storage_types.len()
    if count == 0:
        return
    let frame_ptr = scope.storage_types.get(count - 1) else:
        return
    unsafe:
        let _prev = read(frame_ptr).set(name, ty)


public function scope_get_storage(scope: ref[Scope], name: str) -> ptr[types.Type]?:
    var index = scope.storage_types.len()
    while index > 0:
        index -= 1
        let frame_ptr = scope.storage_types.get(index) else:
            return null
        unsafe:
            let found = read(frame_ptr).get(name)
            if found != null:
                return found
    return scope_get(scope, name)
