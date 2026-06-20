# Lexical scope system for the self-hosting compiler.
# Mirrors the Scope/FlowScope model from Ruby lib/milk_tea/core/binding_types.rb.

import std.vec
import std.map
import std.hash
import std.str
import mtc.types

public struct ValueBinding:
    id: ptr_uint
    name: str
    storage_type: types.TypeId
    mutable: bool
    kind: str
    is_param: bool

public struct Scope:
    bindings: map.Map[str, ValueBinding]

extending Scope:
    public static function create() -> Scope:
        return Scope(bindings = map.Map[str, ValueBinding].create())

    public function lookup(name: str) -> Option[ValueBinding]:
        let ptr = this.bindings.get(name) else:
            return Option[ValueBinding].none
        return Option[ValueBinding].some(value = unsafe: read(ptr))

    public editable function insert(binding: ValueBinding) -> void:
        let _prev = this.bindings.set(binding.name, binding)
        pass

# ScopeStack is a Vec[Scope]. The outermost scope is at index 0.
# Lookup walks from innermost to outermost.

public struct ScopeStack:
    scopes: vec.Vec[Scope]

extending ScopeStack:
    public static function create() -> ScopeStack:
        var stack = ScopeStack(scopes = vec.Vec[Scope].create())
        stack.scopes.push(Scope.create())
        return stack

    public editable function push_scope() -> void:
        this.scopes.push(Scope.create())

    public editable function pop_scope() -> void:
        let _discard = this.scopes.pop()
        pass

    public function lookup(name: str) -> Option[ValueBinding]:
        var depth = this.scopes.len
        while depth > 0z:
            depth -= 1
            let scope = this.scopes.at(depth) else:
                continue
            let found = scope.lookup(name)
            match found:
                Option.some:
                    return found
                Option.none:
                    pass
        return Option[ValueBinding].none

    public editable function insert(binding: ValueBinding) -> void:
        let last = this.scopes.len
        if last == 0z:
            return
        let idx = last - 1
        let scope_ptr = this.scopes.get(idx) else:
            return
        unsafe:
            read(scope_ptr).insert(binding)
