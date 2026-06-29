# POC 032 — Custom structural iterables: iterator protocol with iter()/next()/current()
# Tests: for loop over custom types exposing iter() method that returns an iterator
# with next() -> bool plus current() form, and next() -> ptr[T]? form.
import std.vec as vec

struct Counter:
    limit: int

struct CounterIter:
    current_val: int
    limit: int

extending Counter:
    function iter() -> CounterIter:
        return CounterIter(current_val = 0, limit = this.limit)

extending CounterIter:
    editable function next() -> bool:
        this.current_val += 1
        return this.current_val <= this.limit

    function current() -> int:
        return this.current_val

struct RangeIter:
    data: vec.Vec[int]
    index: ptr_uint
    len: ptr_uint

extending RangeIter:
    editable function next() -> ptr[int]?:
        if this.index >= this.len:
            return null
        let entry = this.data.get(this.index) else:
            return null
        this.index += 1
        return entry

function main() -> int:
    var total: int = 0

    # next() -> bool + current() protocol
    var c = Counter(limit = 5)
    for val in c:
        total += val

    # next() -> ptr[T]? protocol on vec.Vec
    var items = vec.Vec[int].create()
    items.push(10)
    items.push(20)
    items.push(30)
    for val in items:
        unsafe:
            total += read(val)

    items.release()
    let _total = total
    return 0
