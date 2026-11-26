# expect-error: adapt requires exactly one argument
interface I:
    function f() -> int

struct S implements I:
    function f() -> int:
        return 1

function main() -> int:
    var s = S()
    let d = adapt[I]()
    return 0
