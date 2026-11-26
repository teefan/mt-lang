# Spec: README.md §4 Variables And Guards

function main() -> int:
    var a: array[int, 3] = (1, 2, 3)
    if a[2] != 3:
        return 1
    return 0
