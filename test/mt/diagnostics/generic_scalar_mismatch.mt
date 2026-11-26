# expect-error: expects
import std.vec as vec

function take(s: str) -> int:
    return 0

function main() -> int:
    var v = vec.Vec[int].create()
    defer: v.release()
    return take(v)
