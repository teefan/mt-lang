# Spec: README.md §10 Type System

struct Counter:
    value: int

function increment(c: ref[Counter]) -> void:
    c.value += 1

function main() -> int:
    var c = Counter(value = 0)
    increment(c)
    if c.value != 1:
        return 1
    return 0
