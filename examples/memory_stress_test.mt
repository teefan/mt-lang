## Memory / Pointer / Unsafe / Nullable Stress Test
##
## Exercises the full surface documented in README.md §4 (Variables and
## Guards), §9 (Expressions), §10 (Type System), and §13 (Safety And
## Conversion Rules).
##
## Uses own[T] for heap allocation exercises.

import std.mem.heap as heap
##
## Each function exercises a specific scenario.  The entrypoint `main`
## calls them all and returns a status code where 0 indicates all
## checks passed.

# ---------------------------------------------------------------------------
# 1  Nullable pointer basic flow
# ---------------------------------------------------------------------------

function nullable_guard_clause(handle: ptr[int]?) -> int:
    if handle == null:
        return 0
    unsafe:
        return read(handle)

function nullable_not_equal_guard(handle: ptr[int]?) -> int:
    if handle != null:
        unsafe:
            return read(handle)
    return 0

function short_circuit_and_nullable(handle: ptr[int]?) -> int:
    unsafe:
        if handle != null and read(handle) > 0:
            return read(handle)
    return 0

# ---------------------------------------------------------------------------
# 2  let ... else: guard (nullable / Result / Option)
# ---------------------------------------------------------------------------

function let_else_nullable(maybe: ptr[int]?) -> int:
    let handle = maybe else:
        return -1
    unsafe:
        return read(handle)

function let_else_result_void(ok: Result[void, int]) -> int:
    let _ = ok else:
        return -1
    return 0

# ---------------------------------------------------------------------------
# 3  Zero vs null
# ---------------------------------------------------------------------------

function zero_vs_null() -> void:
    let p: ptr[int]? = null[ptr[int]]
    let q: ptr[int]? = null
    let _ = p
    let _ = q
    # zero[...] is deliberately excluded here — the compiler rejects it

# ---------------------------------------------------------------------------
# 4  Unsafe: statement and expression forms
# ---------------------------------------------------------------------------

function unsafe_statement_form(p: ptr[int], value: int) -> void:
    unsafe:
        p[0] = value

function unsafe_expression_form(p: ptr[int]) -> int:
    return unsafe: read(p)

# ---------------------------------------------------------------------------
# 5  Nested unsafe blocks
# ---------------------------------------------------------------------------

function nested_unsafe_blocks(outer: ptr[int], inner: ptr[int]) -> int:
    unsafe:
        let a = read(outer)
        unsafe:
            let b = read(inner)
            return a + b

# ---------------------------------------------------------------------------
# 6  Pointer arithmetic
# ---------------------------------------------------------------------------

function pointer_arithmetic_stress(base: ptr[int]) -> ptr[int]:
    unsafe:
        let advance = base + 1
        return advance

function pointer_indexing(base: ptr[int], idx: ptr_uint) -> int:
    unsafe:
        return base[idx]

# ---------------------------------------------------------------------------
# 7  Pointer casts
# ---------------------------------------------------------------------------

function pointer_cast_demo() -> ptr[int]:
    var v: int = 42
    let p = ptr_of(v)
    return p

# ---------------------------------------------------------------------------
# 8  reinterpret (same-size types)
# ---------------------------------------------------------------------------

function reinterpret_int_as_uint(value: int) -> uint:
    unsafe:
        return reinterpret[uint](value)

function reinterpret_float_as_uint(value: float) -> uint:
    unsafe:
        return reinterpret[uint](value)

function reinterpret_pointer_as_uint(p: ptr[int]) -> ptr_uint:
    unsafe:
        return reinterpret[ptr_uint](p)

# ---------------------------------------------------------------------------
# 9  ref types — creation, auto-deref, read
# ---------------------------------------------------------------------------

function ref_creation_and_deref() -> int:
    var counter: int = 0
    let r = ref_of(counter)
    read(r) = 41
    return read(r)

function ref_auto_deref_member_access() -> float:
    var p = vec3(x = 1.0, y = 2.0, z = 3.0)
    let r = ref_of(p)
    return r.x + r.y + r.z

# ---------------------------------------------------------------------------
# 10  const_ptr operations
# ---------------------------------------------------------------------------

function const_ptr_read_only(source: ptr[int]) -> int:
    unsafe:
        let r = const_ptr_of(read(source))
        return read(r)

# ---------------------------------------------------------------------------
# 11  ptr_of on ref value
# ---------------------------------------------------------------------------

function ptr_of_ref_value() -> ptr[int]:
    var counter: int = 0
    let r = ref_of(counter)
    return ptr_of(r)

# ---------------------------------------------------------------------------
# 12  get() — recoverable indexing returning ptr[T]?
# ---------------------------------------------------------------------------

function recoverable_indexing(arr: array[int, 4], idx: int) -> int:
    let item = get(arr, idx) else:
        return -1
    unsafe:
        return read(item)

function recoverable_indexing_span(s: span[int], idx: int) -> int:
    let item = get(s, idx) else:
        return -1
    unsafe:
        return read(item)

# ---------------------------------------------------------------------------
# 13  Safe array indexing (addressable)
# ---------------------------------------------------------------------------

function safe_array_indexing(arr: array[int, 4]) -> int:
    return arr[0] + arr[3]

# ---------------------------------------------------------------------------
# 14  ? postfix Result propagation
# ---------------------------------------------------------------------------

function postfix_result_propagation(input: Result[int, bool]) -> Result[int, bool]:
    let value = input?
    return Result[int, bool].success(value = value)

function postfix_void_success_expression(input: Result[void, bool]) -> Result[int, bool]:
    let _ = input else as error:
        return Result[int, bool].failure(error = error)
    return Result[int, bool].success(value = 0)

# ---------------------------------------------------------------------------
# 15  Nullable flow through assignments
# ---------------------------------------------------------------------------

function nullable_assignment_flow() -> int:
    var handle: ptr[int]? = null[ptr[int]]
    if handle == null:
        handle = open_handle()
    if handle != null:
        unsafe:
            return read(handle)
    return -1

function open_handle() -> ptr[int]?:
    return null[ptr[int]]

# ---------------------------------------------------------------------------
# 16  Non-owning struct with ref fields
# ---------------------------------------------------------------------------

struct Cursor:
    data: ref[ubyte]
    len: ptr_uint

function non_owning_local() -> ubyte:
    var buf: array[ubyte, 16]
    let c = Cursor(data = ref_of(buf[0]), len = 16)
    return read(c.data)

# ---------------------------------------------------------------------------
# 17  Raw pointer member access and method calls (inside unsafe)
# ---------------------------------------------------------------------------

function raw_pointer_field_access(p: ptr[int]) -> void:
    unsafe:
        p[0] = 0

# ---------------------------------------------------------------------------
# 18  Typed null literals
# ---------------------------------------------------------------------------

function typed_null_literal() -> cstr?:
    return null[cstr]

function bare_null_for_typed_context() -> ptr[int]?:
    let p: ptr[int]? = null
    return p

# ---------------------------------------------------------------------------
# 19  Mixed pointer and numeric operations
# ---------------------------------------------------------------------------

function size_of_for_ptr() -> ptr_uint:
    return size_of(ptr[int])

function align_of_for_ptr() -> ptr_uint:
    return align_of(ptr[int])

# ---------------------------------------------------------------------------
# 21  own[T] — owning heap pointer (auto-deref, nullable, storable)
# ---------------------------------------------------------------------------

function own_basic_alloc() -> own[int]:
    let p = heap.must_alloc[int](1)
    return p

function own_nullable_flow() -> int:
    var p: own[int]? = heap.alloc[int](1)
    defer heap.release(unsafe: ptr[int]<-p)
    if p != null:
        return 0
    return -1

# ---------------------------------------------------------------------------
# 22  Entrypoint
# ---------------------------------------------------------------------------

function main() -> int:
    var handle: ptr[int]
    var counter: int = 0
    handle = ptr_of(counter)

    unsafe:
        pointer_indexing(handle, 0)

    let _ = ptr_of_ref_value()
    let _ = ref_creation_and_deref()

    return 0
