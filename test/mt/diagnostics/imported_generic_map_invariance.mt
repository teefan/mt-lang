# expect-error: expects
import std.map as map

function take(m: map.Map[str, int]) -> int:
    return 0

function main() -> int:
    var m = map.Map[int, bool].create()
    defer: m.release()
    return take(m)
