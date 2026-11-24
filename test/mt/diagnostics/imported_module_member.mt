# expect-error: unknown member NOPE on module a
import std.str as a

function main() -> int:
    if a.NOPE() == 42:
        return 1
    return 0
