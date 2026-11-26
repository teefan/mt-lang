# Spec: README.md §4 Variables And Guards

function read_int(p: ptr[int]?) -> int:
    if p == null:
        return 0
    let value = unsafe: read(p)
    return value

function main() -> int:
    return read_int(null)
