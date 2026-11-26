# expect-error: concrete type must be nominal
interface I:
    function f() -> int

function main() -> int:
    var number = 1
    let value = adapt[I](ref_of(number))
    return 0
