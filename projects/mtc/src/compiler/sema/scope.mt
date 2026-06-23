## Scope — lexical scope with parent chain and symbol table.

import compiler.sema.type_registry as reg
import std.map

public type TypeId = reg.TypeId
public type IdentId = ptr_uint


public enum BindingKind: int
    bk_param = 0
    bk_let = 1
    bk_var = 2
    bk_function = 3
    bk_type = 4


public struct Scope:
    parent: ptr[Scope]?
    bindings: map.Map[IdentId, TypeId]


public function create(parent: ptr[Scope]?) -> Scope:
    return Scope(
        parent = parent,
        bindings = map.Map[IdentId, TypeId].with_capacity(16),
    )


public function define(scope: ptr[Scope], name: IdentId, type_id: TypeId) -> void:
    unsafe:
        let _ = scope.bindings.set(name, type_id)


public function lookup(scope: ptr[Scope]?, name: IdentId) -> Option[TypeId]:
    if scope == null:
        return Option[TypeId].none

    unsafe:
        let tid = scope.bindings.get(name)
        if tid != null:
            return Option[TypeId].some(value = read(tid))

        let p = scope.parent
        if p != null:
            return lookup(p, name)
    return Option[TypeId].none
