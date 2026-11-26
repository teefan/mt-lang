# Spec: docs/language-manual.md §3.7 Functions

struct Handler:
    run: fn(state: ptr[void]) -> void

function work[T](state: ptr[void]) -> void:
    pass

function main() -> int:
    let h = Handler(run = work[int])
    return 0
