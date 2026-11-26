# Spec: README.md §10 Type System

function sum(values: span[int]) -> int:
    var total = 0
    for value in values:
        total += value
    return total

function main() -> int:
    var values = array[int, 3](1, 2, 3)
    if sum(values) != 6:
        return 1
    return 0
