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


public function scope_create() -> Scope:
    return Scope(
        frames = vec.Vec[map_mod.Map[str, types.Type]].create(),
        let_bindings = vec.Vec[map_mod.Map[str, bool]].create(),
    )


public function scope_enter(scope: ref[Scope]) -> void:
    scope.frames.push(map_mod.Map[str, types.Type].create())
    scope.let_bindings.push(map_mod.Map[str, bool].create())


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
