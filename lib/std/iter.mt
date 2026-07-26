## std.iter — composable, lazy iteration adaptors.
##
## Each source/adaptor creates heap-allocated state linked through
## function pointers. The outer release() call frees the entire
## chain. Callbacks use fn types (function pointers, no captures).
##
## Usage:
##   import std.iter
##   let it = iter.from_array(ref_of(arr))
##   let it2 = iter.iter_filter(it, pred)
##   let v = iter.collect_vec(it2)
##
## Note: iter_map allocates per mapped item; prefer collect_vec or
## fold to consume values without leaking.

import std.mem.heap as heap
import std.vec as v

## ── Core Iter type ───────────────────────────────────────────────────

struct Iter[T]:
    state: ptr[void]
    next_fn: fn(state: ptr[void]) -> ptr[T]?
    release_fn: fn(state: ptr[void]) -> void

## ── Source: Vec ─────────────────────────────────────────────────────

public function from_vec[T](vec: ref[v.Vec[T]]) -> Iter[T]:
    return from_span(vec.as_span())

## ── Source: array ────────────────────────────────────────────────────

public function from_array[T, N](arr: ref[array[T, N]]) -> Iter[T]:
    return from_span(arr.as_span())

## ── Source: span ─────────────────────────────────────────────────────

struct SpanIterState[T]:
    sp: span[T]
    index: ptr_uint

public function span_advance[T](state: ptr[void]) -> ptr[T]?:
    let s = unsafe: ptr[SpanIterState[T]]<-state
    let _this = unsafe: read(s)
    if _this.index >= _this.sp.len:
        return null
    let item = unsafe: _this.sp.data + _this.index
    unsafe: read(s).index += 1
    return item

public function span_release[T](state: ptr[void]) -> void:
    let s = unsafe: ptr[SpanIterState[T]]<-state
    heap.release[SpanIterState[T]](s)

public function from_span[T](sp: span[T]) -> Iter[T]:
    let state = heap.must_alloc[SpanIterState[T]](1)
    state.index = 0
    state.sp = sp
    return Iter[T](state = unsafe: ptr[void]<-state, next_fn = span_advance[T], release_fn = span_release[T])

## ── Adaptor: Filter ──────────────────────────────────────────────────

struct FilterState[T]:
    inner: Iter[T]
    pred: fn(value: T) -> bool

public function filter_advance[T](state: ptr[void]) -> ptr[T]?:
    let s = unsafe: ptr[FilterState[T]]<-state
    let _this = unsafe: read(s)
    var item = _this.inner.next_fn(_this.inner.state)
    while item != null:
        if _this.pred(unsafe: read(item)):
            return item
        item = _this.inner.next_fn(_this.inner.state)
    return null

public function filter_release[T](state: ptr[void]) -> void:
    let s = unsafe: ptr[FilterState[T]]<-state
    let _this = unsafe: read(s)
    _this.inner.release_fn(_this.inner.state)
    heap.release[FilterState[T]](s)

public function iter_filter[T](iter: Iter[T], pred: fn(value: T) -> bool) -> Iter[T]:
    let state = heap.must_alloc[FilterState[T]](1)
    state.inner = iter
    state.pred = pred
    return Iter[T](state = unsafe: ptr[void]<-state, next_fn = filter_advance[T], release_fn = filter_release[T])

## ── Adaptor: Map ─────────────────────────────────────────────────────

struct MapState[T, U]:
    inner: Iter[T]
    map_fn: fn(value: T) -> U

public function map_advance[T, U](state: ptr[void]) -> ptr[U]?:
    let s = unsafe: ptr[MapState[T, U]]<-state
    let _this = unsafe: read(s)
    let item = _this.inner.next_fn(_this.inner.state)
    if item == null:
        return null
    let mapped = heap.must_alloc[U](1)
    read(mapped) = _this.map_fn(read(item))
    return mapped

public function map_release[T, U](state: ptr[void]) -> void:
    let s = unsafe: ptr[MapState[T, U]]<-state
    let _this = unsafe: read(s)
    _this.inner.release_fn(_this.inner.state)
    heap.release[MapState[T, U]](s)

public function iter_map[T, U](iter: Iter[T], f: fn(value: T) -> U) -> Iter[U]:
    let state = heap.must_alloc[MapState[T, U]](1)
    state.inner = iter
    state.map_fn = f
    return Iter[U](state = unsafe: ptr[void]<-state, next_fn = map_advance[T, U], release_fn = map_release[T, U])

## ── Adaptor: Take ────────────────────────────────────────────────────

struct TakeState[T]:
    inner: Iter[T]
    remaining: int

public function take_advance[T](state: ptr[void]) -> ptr[T]?:
    let s = unsafe: ptr[TakeState[T]]<-state
    let _this = unsafe: read(s)
    if _this.remaining <= 0:
        return null
    unsafe: read(s).remaining -= 1
    return _this.inner.next_fn(_this.inner.state)

public function take_release[T](state: ptr[void]) -> void:
    let s = unsafe: ptr[TakeState[T]]<-state
    let _this = unsafe: read(s)
    _this.inner.release_fn(_this.inner.state)
    heap.release[TakeState[T]](s)

public function iter_take[T](iter: Iter[T], n: int) -> Iter[T]:
    let state = heap.must_alloc[TakeState[T]](1)
    state.inner = iter
    state.remaining = n
    return Iter[T](state = unsafe: ptr[void]<-state, next_fn = take_advance[T], release_fn = take_release[T])

## ── Adaptor: Skip ────────────────────────────────────────────────────

struct SkipState[T]:
    inner: Iter[T]
    skip_count: int

public function skip_advance[T](state: ptr[void]) -> ptr[T]?:
    let s = unsafe: ptr[SkipState[T]]<-state
    let _this = unsafe: read(s)
    while _this.skip_count > 0:
        let skipped = _this.inner.next_fn(_this.inner.state)
        if skipped == null:
            return null
        unsafe: read(s).skip_count -= 1
    return _this.inner.next_fn(_this.inner.state)

public function skip_release[T](state: ptr[void]) -> void:
    let s = unsafe: ptr[SkipState[T]]<-state
    let _this = unsafe: read(s)
    _this.inner.release_fn(_this.inner.state)
    heap.release[SkipState[T]](s)

public function iter_skip[T](iter: Iter[T], n: int) -> Iter[T]:
    let state = heap.must_alloc[SkipState[T]](1)
    state.inner = iter
    state.skip_count = n
    return Iter[T](state = unsafe: ptr[void]<-state, next_fn = skip_advance[T], release_fn = skip_release[T])

## ── Consumer: Fold ───────────────────────────────────────────────────

public function iter_fold[T, U](iter: Iter[T], init: U, f: fn(accum: U, value: T) -> U) -> U:
    var accum = init
    var item = iter.next_fn(iter.state)
    while item != null:
        accum = f(accum, unsafe: read(item))
        item = iter.next_fn(iter.state)
    iter.release_fn(iter.state)
    return accum

## ── Consumer: Find ───────────────────────────────────────────────────

public function iter_find[T](iter: Iter[T], pred: fn(value: T) -> bool) -> Option[T]:
    var item = iter.next_fn(iter.state)
    while item != null:
        if pred(unsafe: read(item)):
            let val = unsafe: read(item)
            iter.release_fn(iter.state)
            return Option[T].some(value = val)
        item = iter.next_fn(iter.state)
    iter.release_fn(iter.state)
    return Option[T].none

## ── Consumer: Any ────────────────────────────────────────────────────

public function iter_any[T](iter: Iter[T], pred: fn(value: T) -> bool) -> bool:
    var item = iter.next_fn(iter.state)
    while item != null:
        if pred(unsafe: read(item)):
            iter.release_fn(iter.state)
            return true
        item = iter.next_fn(iter.state)
    iter.release_fn(iter.state)
    return false

## ── Consumer: All ────────────────────────────────────────────────────

public function iter_all[T](iter: Iter[T], pred: fn(value: T) -> bool) -> bool:
    var item = iter.next_fn(iter.state)
    while item != null:
        if not pred(unsafe: read(item)):
            iter.release_fn(iter.state)
            return false
        item = iter.next_fn(iter.state)
    iter.release_fn(iter.state)
    return true

## ── Consumer: Count ──────────────────────────────────────────────────

public function iter_count[T](iter: Iter[T]) -> ptr_uint:
    var count: ptr_uint = 0
    var item = iter.next_fn(iter.state)
    while item != null:
        count += 1
        item = iter.next_fn(iter.state)
    iter.release_fn(iter.state)
    return count

## ── Collect: Vec ─────────────────────────────────────────────────────

public function collect_vec[T](iter: Iter[T]) -> v.Vec[T]:
    var result = v.Vec[T].create()
    var item = iter.next_fn(iter.state)
    while item != null:
        result.push(unsafe: read(item))
        item = iter.next_fn(iter.state)
    iter.release_fn(iter.state)
    return result
