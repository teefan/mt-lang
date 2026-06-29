# POC 031 — Generic methods on extending blocks
# Tests: extending a generic struct adds methods with access to type parameters.
# Generic methods declared inside an extending block.
struct Box[T]:
    value: T

extending Box[T]:
    function get() -> T:
        return this.value

    editable function set(v: T) -> void:
        this.value = v

    static function init(v: T) -> Box[T]:
        return Box[T](value = v)

    function map[U](f: proc(input: T) -> U) -> Box[U]:
        return Box[U](value = f(this.value))

function twice(x: int) -> int:
    return x * 2

function main() -> int:
    var b = Box[int].init(10)
    let v1 = b.get()

    var sb = Box[str].init("hello")
    let v2 = sb.get()

    b.set(20)
    let mapped = b.map[int](proc(input: int) -> int: twice(input))
    let mv = mapped.get()

    let _v1 = v1
    let _v2 = v2
    let _mv = mv
    return 0
