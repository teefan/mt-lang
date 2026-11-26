# expect-error: expects
import std.vec as vec

function take(v: vec.Vec[str]) -> int:
    return 0

function main() -> int:
    var v = vec.Vec[int].create()
    defer: v.release()
    return take(v)
