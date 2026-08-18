# In-language tests for std.mem.heap (migrated from
# test/std/std_mem_heap_test.rb, run by `mtc test`).

import std.mem.heap as heap

@[align(16)]
struct Mat4:
    data: array[float, 16]


@[test]
function test_heap_allocation_wrappers() -> void:
    let bytes = heap.alloc[ubyte](16)
    let grown = heap.resize(bytes, 32)
    let zeroed = heap.alloc_zeroed[bool](4)
    let raw = heap.alloc_bytes(8)
    let raw_grown = heap.resize_bytes(raw, 16)
    expect(grown != null, "resize returns non-null")
    expect(zeroed != null, "alloc_zeroed returns non-null")
    expect(raw_grown != null, "resize_bytes returns non-null")
    heap.release(grown)
    heap.release(zeroed)
    heap.release_bytes(raw_grown)


@[test]
function test_heap_contract_edges() -> void:
    expect(heap.alloc_bytes(0) == null, "alloc_bytes(0) is null")
    expect(heap.alloc_zeroed_bytes(0, 4) == null, "alloc_zeroed_bytes(0) is null")

    let raw = heap.alloc_bytes(8)
    expect(raw != null, "alloc_bytes(8) non-null")
    let released = heap.resize_bytes(raw, 0)
    expect(released == null, "resize_bytes to 0 frees")

    let aligned = heap.alloc_bytes_aligned(1, 16)
    expect(aligned != null, "aligned alloc non-null")
    heap.release_bytes(aligned)

    let matrix = heap.alloc_aligned[Mat4](1)
    expect(matrix != null, "alloc_aligned non-null")
    heap.release(matrix)

    expect(heap.alloc[Mat4](1) == null, "unaligned alloc of aligned type is null")

    var source = array[ubyte, 3](ubyte<-10, ubyte<-20, ubyte<-30)
    let copied = heap.must_alloc[ubyte](3)
    heap.copy_bytes(copied, ptr_of(source[0]), 3)
    var copy_ok = false
    unsafe:
        copy_ok = read(copied + 0) == ubyte<-10 and read(copied + 1) == ubyte<-20 and read(copied + 2) == ubyte<-30
    heap.release(copied)
    expect(copy_ok)


@[test] @[expect_fatal]
function test_heap_must_alloc_zero_count_aborts() -> void:
    let _ = heap.must_alloc[int](0)


@[test] @[expect_fatal]
function test_heap_must_alloc_aligned_zero_count_aborts() -> void:
    let _ = heap.must_alloc_aligned[int](0)


@[test] @[expect_fatal]
function test_heap_must_alloc_zeroed_zero_count_aborts() -> void:
    let _ = heap.must_alloc_zeroed[int](0)


@[test] @[expect_fatal]
function test_heap_must_resize_zero_count_aborts() -> void:
    let bytes = heap.must_alloc[int](1)
    defer: heap.release(bytes)
    let _ = heap.must_resize(bytes, 0)


@[test] @[expect_fatal]
function test_heap_must_alloc_size_overflow_aborts() -> void:
    let _ = heap.must_alloc[long](heap.ptr_uint_max)
