import std.mem.arena as arena_mod

public type Arena = arena_mod.Arena
public type Mark = arena_mod.Mark

public function create(capacity: ptr_uint) -> Arena:
    return arena_mod.create(capacity)

public function with_capacity(capacity: ptr_uint) -> Arena:
    return arena_mod.create(capacity)
