## SIMD helpers — load, store, and reduction operations
## for the built-in simd[T, N] type constructor.
##
## Load and store use unsafe ptr casts internally; the user-facing
## surface is safe because only valid pointer dereferencing is involved.
##
## Usage:
##   import std.simd as simd
##   let v = simd.load_aligned_float4(ptr)
##   let s = simd.horizontal_sum_float4(v)

import std.mem.ptr as ptr

## ── simd[float, 4] ──────────────────────────────────────────────────

public function load_aligned_float4(p: ptr[float]) -> simd[float, 4]:
    let q = unsafe: ptr[simd[float, 4]]<-p
    return q.load()

public function load_unaligned_float4(ptr: ptr[float]) -> simd[float, 4]:
    return load_aligned_float4(ptr)

public function store_aligned_float4(p: ptr[float], value: simd[float, 4]) -> void:
    let q = unsafe: ptr[simd[float, 4]]<-p
    q.store(value)

public function store_unaligned_float4(ptr: ptr[float], value: simd[float, 4]) -> void:
    store_aligned_float4(ptr, value)

public function horizontal_sum_float4(v: simd[float, 4]) -> float:
    return v[0] + v[1] + v[2] + v[3]

public function dot_float4(a: simd[float, 4], b: simd[float, 4]) -> float:
    return horizontal_sum_float4(a * b)

## ── simd[int, 4] ────────────────────────────────────────────────────

public function load_aligned_int4(ptr: ptr[int]) -> simd[int, 4]:
    let p = unsafe: ptr[simd[int, 4]]<-ptr
    return p.load()

public function load_unaligned_int4(ptr: ptr[int]) -> simd[int, 4]:
    return load_aligned_int4(ptr)

public function store_aligned_int4(ptr: ptr[int], value: simd[int, 4]) -> void:
    let p = unsafe: ptr[simd[int, 4]]<-ptr
    p.store(value)

public function store_unaligned_int4(ptr: ptr[int], value: simd[int, 4]) -> void:
    store_aligned_int4(ptr, value)

public function horizontal_sum_int4(v: simd[int, 4]) -> int:
    return v[0] + v[1] + v[2] + v[3]

public function dot_int4(a: simd[int, 4], b: simd[int, 4]) -> int:
    return horizontal_sum_int4(a * b)

## ── simd[float, 8] (AVX) ────────────────────────────────────────────

public function load_aligned_float8(ptr: ptr[float]) -> simd[float, 8]:
    let p = unsafe: ptr[simd[float, 8]]<-ptr
    return p.load()

public function load_unaligned_float8(ptr: ptr[float]) -> simd[float, 8]:
    return load_aligned_float8(ptr)

public function horizontal_sum_float8(v: simd[float, 8]) -> float:
    return v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7]

public function dot_float8(a: simd[float, 8], b: simd[float, 8]) -> float:
    return horizontal_sum_float8(a * b)

## ── simd[double, 2] ─────────────────────────────────────────────────

public function load_aligned_double2(ptr: ptr[double]) -> simd[double, 2]:
    let p = unsafe: ptr[simd[double, 2]]<-ptr
    return p.load()

public function load_unaligned_double2(ptr: ptr[double]) -> simd[double, 2]:
    return load_aligned_double2(ptr)

public function horizontal_sum_double2(v: simd[double, 2]) -> double:
    return v[0] + v[1]

public function dot_double2(a: simd[double, 2], b: simd[double, 2]) -> double:
    return horizontal_sum_double2(a * b)
