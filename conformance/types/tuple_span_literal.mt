# Spec: README.md §4 Variables And Guards

function main() -> int:
    var b: array[float, 3]
    b[0..2] = (1.0, 2.0)
    if b[1] != 2.0:
        return 1
    return 0
