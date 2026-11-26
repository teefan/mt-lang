# Spec: README.md §13 Safety And Conversion Rules

function main() -> int:
    var value = 1
    let ptr = ptr_of(value)
    return read(ptr)
