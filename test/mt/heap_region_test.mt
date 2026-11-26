# In-language tests for the heap's growable regions (`heap.begin_region` /
# `Region.release`) and the scoped allocator routing they enable.  Run with:
# mtc test projects/mtc

import std.map as map_mod
import std.mem.heap as heap
import std.string as string
import std.thread as thread
import std.vec as vec


var tls_worker_a_ok: bool = false
var tls_worker_b_ok: bool = false
var shared_region: heap.Region = zero[heap.Region]


function tls_region_worker_a() -> void:
    var region = heap.create_region()
    let previous = heap.begin_region(ptr_of(region))
    let data = heap.must_alloc[long](8)
    tls_worker_a_ok = region.contains(unsafe: ptr[void]<-data)
    heap.end_region(previous)
    region.release_all()


function tls_region_worker_b() -> void:
    var region = heap.create_region()
    let previous = heap.begin_region(ptr_of(region))
    let data = heap.must_alloc[long](8)
    tls_worker_b_ok = region.contains(unsafe: ptr[void]<-data)
    heap.end_region(previous)
    region.release_all()


function cross_thread_region_worker() -> void:
    let previous = heap.begin_region(ptr_of(shared_region))
    heap.end_region(previous)


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
    region.release_all()
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
    region.release_all()
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
    region.release_all()
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
    region.release_all()
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
    region.release_all()
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
    outer.release_all()
    inner.release_all()
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
    region.release_all()
    return


@[test]
function test_region_state_is_thread_local() -> void:
    tls_worker_a_ok = false
    tls_worker_b_ok = false
    var first = thread.spawn(tls_region_worker_a).unwrap()
    var second = thread.spawn(tls_region_worker_b).unwrap()
    let _ = first.join()
    let _ = second.join()
    expect(tls_worker_a_ok, "worker A allocated inside its own region")
    expect(tls_worker_b_ok, "worker B allocated inside its own region")
    return


@[test]
function test_region_cross_region_release_is_a_noop() -> void:
    var first = heap.create_region()
    var second = heap.create_region()
    let previous_first = heap.begin_region(ptr_of(first))
    let data = heap.must_alloc[long](8)
    let previous_second = heap.begin_region(ptr_of(second))
    heap.release(data)
    # `first` is still an active outer region, so the release is a no-op even
    # though `second` is the innermost active region.
    expect(first.contains(unsafe: ptr[void]<-data), "a cross-region release does not free region memory")
    heap.end_region(previous_second)
    heap.end_region(previous_first)
    first.release_all()
    second.release_all()
    return


@[test] @[expect_fatal]
function test_region_rejects_cross_region_resize() -> void:
    var first = heap.create_region()
    var second = heap.create_region()
    let previous_first = heap.begin_region(ptr_of(first))
    let data = heap.must_alloc[long](8)
    let previous_second = heap.begin_region(ptr_of(second))
    let grown = heap.must_resize[long](data, 32)
    heap.release(grown)
    heap.end_region(previous_second)
    heap.end_region(previous_first)
    first.release_all()
    second.release_all()
    return


@[test] @[expect_fatal]
function test_region_rejects_cross_thread_use() -> void:
    shared_region = heap.create_region()
    var worker = thread.spawn(cross_thread_region_worker).unwrap()
    let _ = worker.join()
    shared_region.release_all()
    return


@[test] @[expect_fatal]
function test_region_release_all_rejects_the_active_region() -> void:
    var region = heap.create_region()
    let previous = heap.begin_region(ptr_of(region))
    region.release_all()
    heap.end_region(previous)
    return
