# In-language tests for the heap's growable regions (`heap.begin_region` /
# `Region.release`) and the scoped allocator routing they enable.  Run with:
# mtc test projects/mtc

import std.map as map_mod
import std.mem.heap as heap
import std.string as string
import std.vec as vec


@[test]
function test_region_routes_allocations_across_blocks() -> void:
    var region = heap.create_region()
    let previous = heap.begin_region(ptr_of(region))
    let first = heap.must_alloc[int](4)
    if not region.contains(unsafe: ptr[void]<-first):
        expect(false, "an int allocation lands in the region")
    # 200 x 4 KiB forces the region to grow several blocks.
    var i: ptr_uint = 0
    while i < 200:
        let block = heap.must_alloc[ubyte](4096)
        unsafe:
            read(block) = ubyte<-i
        if not region.contains(unsafe: ptr[void]<-block):
            expect(false, "a grown block allocation lands in the region")
        i += 1
    heap.end_region(previous)
    region.release()
    let outside = heap.must_alloc[int](4)
    if region.contains(unsafe: ptr[void]<-outside):
        expect(false, "a post-release allocation is not region memory")
    heap.release(outside)
    return


@[test]
function test_region_zeroed_allocations_are_zeroed() -> void:
    var region = heap.create_region()
    let previous = heap.begin_region(ptr_of(region))
    let values = heap.must_alloc_zeroed[long](8)
    var i: ptr_uint = 0
    while i < 8:
        unsafe:
            if read(values + i) != 0:
                expect(false, "a zeroed allocation is zeroed")
        i += 1
    heap.end_region(previous)
    region.release()
    return


@[test]
function test_region_resize_preserves_content() -> void:
    var region = heap.create_region()
    let previous = heap.begin_region(ptr_of(region))
    let data = heap.must_alloc[long](4)
    var i: ptr_uint = 0
    while i < 4:
        unsafe:
            read(data + i) = long<-i * 11
        i += 1
    let grown = heap.must_resize[long](data, 64)
    if not region.contains(unsafe: ptr[void]<-grown):
        expect(false, "a resized allocation stays in the region")
    i = 0
    while i < 4:
        unsafe:
            if read(grown + i) != long<-i * 11:
                expect(false, "resize preserves the old content")
        i += 1
    heap.end_region(previous)
    region.release()
    return


@[test]
function test_region_release_is_a_noop_for_region_memory() -> void:
    var region = heap.create_region()
    let previous = heap.begin_region(ptr_of(region))
    let data = heap.must_alloc[long](4)
    heap.release(data)
    # The release above is a no-op, so the region still owns the payload.
    if not region.contains(unsafe: ptr[void]<-data):
        expect(false, "releasing region memory does not free it")
    heap.end_region(previous)
    region.release()
    return


@[test]
function test_region_contains_only_its_own_allocations() -> void:
    let outside = heap.must_alloc[long](8)
    var region = heap.create_region()
    let previous = heap.begin_region(ptr_of(region))
    if region.contains(unsafe: ptr[void]<-outside):
        expect(false, "a libc allocation is not region memory")
    # Resizing a libc allocation inside a region must stay on the libc heap.
    let grown = heap.must_resize[long](outside, 32)
    if region.contains(unsafe: ptr[void]<-grown):
        expect(false, "a libc allocation resized inside a region stays on the heap")
    heap.end_region(previous)
    heap.release(grown)
    region.release()
    return


@[test]
function test_region_nesting_restores_the_previous() -> void:
    var outer = heap.create_region()
    var inner = heap.create_region()
    let previous = heap.begin_region(ptr_of(outer))
    let inside_outer = heap.must_alloc[long](8)
    if not outer.contains(unsafe: ptr[void]<-inside_outer):
        expect(false, "the outer region is active")
    let before_inner = heap.begin_region(ptr_of(inner))
    let inside_inner = heap.must_alloc[long](8)
    if not inner.contains(unsafe: ptr[void]<-inside_inner):
        expect(false, "the nested region captures the allocation")
    heap.end_region(before_inner)
    let after_inner = heap.must_alloc[long](8)
    if not outer.contains(unsafe: ptr[void]<-after_inner):
        expect(false, "the outer region is active again")
    heap.end_region(previous)
    outer.release()
    inner.release()
    return


@[test]
function test_region_owns_container_buffers() -> void:
    var region = heap.create_region()
    let previous = heap.begin_region(ptr_of(region))
    var values = vec.Vec[long].create()
    var i: ptr_uint = 0
    while i < 100:
        values.push(long<-i)
        i += 1
    let values_span = values.as_span()
    if not region.contains(unsafe: ptr[void]<-values_span.data):
        expect(false, "a Vec buffer grows inside the region")
    values.release()
    var key = string.String.from_str("region")
    key.reserve(64)
    let key_text = key.as_str()
    if not region.contains(unsafe: ptr[void]<-key_text.data):
        expect(false, "a String buffer grows inside the region")
    var table = map_mod.Map[long, long].create()
    table.set(1, 2)
    heap.end_region(previous)
    region.release()
    return
