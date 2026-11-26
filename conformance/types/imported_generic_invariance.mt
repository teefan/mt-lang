# Spec: docs/language-manual.md §6.4 Generics

import std.vec as vec

function take(v: vec.Vec[str]) -> int:
    return 0

function main() -> int:
    var v = vec.Vec[int].create()
    defer: v.release()
    return take(v)
