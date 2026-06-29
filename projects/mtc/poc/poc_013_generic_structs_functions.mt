# POC 013 — Generic structs and functions: generic struct Pair[A,B],
# generic function, generic type constraint, generic value param.

struct Pair[A, B]:
    first: A
    second: B

interface Addable:
    function add(other: int) -> int

function first[T](pair: Pair[T, T]) -> T:
    return pair.first

struct FixedBuffer[N: int]:
    data: array[ubyte, N]

function main() -> int:
    let p = Pair[int, int](first = 10, second = 20)
    let f = first(p)
    let _f = f

    let p2 = Pair[float, str](first = 3.14f, second = "pi")
    let _p2 = p2

    var buf: FixedBuffer[16]
    buf.data[0] = 0ub
    let _buf = buf

    return 0
