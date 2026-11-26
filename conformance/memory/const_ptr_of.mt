# Spec: README.md §10 Type System

struct Thing:
    value: int

function read_thing(ptr: const_ptr[Thing]) -> int:
    let value = unsafe: read(ptr)
    return value.value

function main() -> int:
    var thing = Thing(value = 5)
    if read_thing(const_ptr_of(thing)) != 5:
        return 1
    return 0
