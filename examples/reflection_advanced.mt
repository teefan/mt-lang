## Milk Tea Advanced Compile-Time & Reflection Baseline
##
## Exercises new compile-time features: inline if, expression-based
## size_of/offset_of/align_of, fields_of, generic struct hashing,
## and serialize pack/unpack. Each section returns a unique exit code.

import std.binary as bin
import std.bytes as bytes
import std.serialize as ser

# ---------------------------------------------------------------------------
# 1  Consts
# ---------------------------------------------------------------------------

const DEBUG_ON: bool = true
const DEBUG_OFF: bool = false
const SELECTOR: int = 2

# ---------------------------------------------------------------------------
# 2  Structs
# ---------------------------------------------------------------------------

struct Vec3:
    x: float
    y: float
    z: float

@[packed]
struct CompactHeader:
    tag: ubyte
    version: ushort
    extra: ubyte

struct Entity:
    pos: Vec3
    health: uint
    speed: float
    alive: byte

struct NestedContainer:
    entity: Entity
    id: uint
    priority: ushort

# ---------------------------------------------------------------------------
# 3  inline if
# ---------------------------------------------------------------------------

function test_inline_if_true() -> int:
    var count: int = 0
    inline if DEBUG_ON:
        count = count + 1
    if count != 1:
        return 100
    return 0


function test_inline_if_false() -> int:
    var count: int = 0
    inline if DEBUG_OFF:
        count = 1
    if count != 0:
        return 101
    return 0


function test_inline_if_chain() -> int:
    var count: int = 0
    inline if SELECTOR == 1:
        count = 1
    inline if SELECTOR == 2:
        count = 2
    if count != 2:
        return 102
    return 0


function test_inline_if_and_or() -> int:
    var count: int = 0
    inline if (SELECTOR == 2) and (SELECTOR != 1):
        count = 1
    inline if (SELECTOR == 1) or (SELECTOR == 2):
        count = count * 10
    if count != 10:
        return 103
    return 0


function test_inline_if_not() -> int:
    var count: int = 0
    inline if not DEBUG_OFF:
        count = 7
    if count != 7:
        return 104
    return 0

# ---------------------------------------------------------------------------
# 4  size_of
# ---------------------------------------------------------------------------

function test_sizeof_literal() -> int:
    let s = size_of(uint)
    if s != ptr_uint<-4:
        return 200
    return 0


function test_sizeof_field_type[T]() -> int:
    var total: ptr_uint = 0
    inline for field in fields_of(T):
        total = total + size_of(field.type)
    return int<-total


function test_sizeof_ptr_void() -> int:
    let s = size_of(ptr[void])
    if s != ptr_uint<-8:
        return 201
    return 0


function test_sizeof_generic[T]() -> int:
    let s = size_of(T)
    return int<-s


function test_sizeof_nullable() -> int:
    let s = size_of(ptr[void]?)
    return 0

# ---------------------------------------------------------------------------
# 5  offset_of
# ---------------------------------------------------------------------------

function test_offsetof_literal() -> int:
    let o = offset_of(Vec3, x)
    if o != ptr_uint<-0:
        return 300
    return 0


function test_offsetof_packed() -> int:
    let o0 = offset_of(CompactHeader, tag)
    let o2 = offset_of(CompactHeader, extra)
    if o0 != ptr_uint<-0:
        return 301
    return 0


function test_offsetof_inline_for[T]() -> int:
    var acc: ptr_uint = 0
    inline for field in fields_of(T):
        acc = acc + offset_of(T, field)
    return int<-acc


function test_offsetof_generic[T]() -> int:
    var count: int = 0
    inline for field in fields_of(T):
        let o = offset_of(T, field)
        count = count + 1
    return count

# ---------------------------------------------------------------------------
# 6  fields_of
# ---------------------------------------------------------------------------

function count_fields[T]() -> int:
    var n: int = 0
    inline for field in fields_of(T):
        n = n + 1
    return n


function first_field_name[T]() -> str:
    inline for field in fields_of(T):
        return field.name
    return ""

# ---------------------------------------------------------------------------
# 7  Generic struct hash/equal/order (same-module inline helpers)
# ---------------------------------------------------------------------------

function hash_vec3(value: const_ptr[Vec3]) -> uint:
    var h: uint = 0x811C9DC5
    var prime: uint = 0x01000193
    inline for field in fields_of(Vec3):
        let offset = offset_of(Vec3, field)
        let field_size = size_of(field.type)
        var data_ptr = unsafe: ptr[ubyte]<-value + offset
        var b: ptr_uint = 0
        while b < field_size:
            h = (h ^ uint<-unsafe: read(data_ptr + b)) * prime
            b += 1
    return h


function equal_vec3(a: const_ptr[Vec3], b: const_ptr[Vec3]) -> bool:
    inline for field in fields_of(Vec3):
        let offset = offset_of(Vec3, field)
        let field_size = size_of(field.type)
        var pa = unsafe: ptr[ubyte]<-a + offset
        var pb = unsafe: ptr[ubyte]<-b + offset
        var i: ptr_uint = 0
        while i < field_size:
            if unsafe: read(pa + i) != read(pb + i):
                return false
            i += 1
    return true


function test_hash_equal() -> int:
    var a = Vec3(x = 1.0, y = 2.0, z = 3.0)
    var b = Vec3(x = 1.0, y = 2.0, z = 3.0)
    var c = Vec3(x = 3.0, y = 4.0, z = 5.0)
    if not equal_vec3(const_ptr_of(a), const_ptr_of(b)):
        return 401
    if equal_vec3(const_ptr_of(a), const_ptr_of(c)):
        return 402
    return 0


function test_order_vec() -> int:
    var a = Vec3(x = 1.0, y = 0.0, z = 0.0)
    var b = Vec3(x = 2.0, y = 0.0, z = 0.0)
    var pa = unsafe: ptr[ubyte]<-ptr_of(a)
    var pb = unsafe: ptr[ubyte]<-ptr_of(b)
    if unsafe: read(pa + 0) >= unsafe: read(pb + 0):
        return 0
    return 403

# ---------------------------------------------------------------------------
# 8  serialize — pack / unpack
# ---------------------------------------------------------------------------

function test_serialize_pod() -> int:
    var original = Vec3(x = 1.0, y = 2.0, z = 3.0)
    var packet = ser.pack[Vec3](ref_of(original))
    defer packet.release()
    let result = ser.unpack[Vec3](packet.as_span())
    match result:
        Result.failure:
            return 501
        Result.success as p:
            return 0


function test_serialize_nested() -> int:
    var original = NestedContainer(
        entity = Entity(pos = Vec3(x = 1.0, y = 2.0, z = 3.0), health = uint<-100, speed = 5.0, alive = byte<-1),
        id = uint<-42,
        priority = ushort<-7
    )
    var packet = ser.pack[NestedContainer](ref_of(original))
    defer packet.release()
    let result = ser.unpack[NestedContainer](packet.as_span())
    match result:
        Result.failure:
            return 502
        Result.success as p:
            return 0


function test_serialize_writer_reader() -> int:
    var original = CompactHeader(tag = ubyte<-0xAA, version = ushort<-1, extra = ubyte<-0x55)
    var w = bin.Writer.with_capacity(128)
    w.pack[CompactHeader](ref_of(original))
    var data = w.finish()
    defer data.release()
    var r = bin.reader(data.as_span())
    let result = r.unpack[CompactHeader]()
    match result:
        Result.failure:
            return 503
        Result.success as p:
            return 0


function test_serialize_too_short() -> int:
    var empty = bytes.Bytes.empty()
    let result = ser.unpack[Vec3](empty.as_span())
    match result:
        Result.failure:
            return 0
        Result.success:
            return 504

# ---------------------------------------------------------------------------
# 9  inline for + inline if combined
# ---------------------------------------------------------------------------

function test_inline_for_if[T]() -> int:
    var acc: ptr_uint = 0
    inline for field in fields_of(T):
        let o = offset_of(T, field)
        let s = size_of(field.type)
        acc = acc + o + s
    return 0


function test_double_inline_for() -> int:
    var n: int = 0
    inline for a in fields_of(Vec3):
        inline for b in fields_of(CompactHeader):
            n = n + 1
    if n != 9:
        return 601
    return 0

# ---------------------------------------------------------------------------
# 10  align_of
# ---------------------------------------------------------------------------

function test_alignof_literal() -> int:
    let a = align_of(uint)
    if a != ptr_uint<-4:
        return 700
    return 0


function test_alignof_field[T]() -> int:
    var first: ptr_uint = 0
    var seen: bool = false
    inline for field in fields_of(T):
        if not seen:
            first = align_of(field.type)
            seen = true
    return 0

# ---------------------------------------------------------------------------
# 11  Edge-case combinations
# ---------------------------------------------------------------------------

interface Measurable:
    function tag() -> str

struct TaggedStruct implements Measurable:
    data: uint


extending TaggedStruct:
    function tag() -> str:
        return "tagged"


function reflect_constrained[T implements Measurable](value: ref[T]) -> int:
    var count: int = 0
    inline for field in fields_of(T):
        let s = size_of(field.type)
        count = count + 1
    return count


function pick_int[N: int]() -> type:
    inline if N <= 1:
        return ubyte
    inline if N <= 2:
        return ushort
    inline if N <= 4:
        return uint
    return ulong


function test_nullable_ptr() -> int:
    var e = Entity(pos = Vec3(x = 0.0, y = 0.0, z = 0.0), health = uint<-0, speed = 0.0, alive = byte<-0)
    var ptr: const_ptr[Entity]? = const_ptr_of(e)
    return 0


function test_zero_and_reflect[T]() -> int:
    var v = unsafe: zero[T]
    var count: int = 0
    inline for field in fields_of(T):
        let o = offset_of(T, field)
        count = count + 1
    return count


function first_field_offset[T]() -> ptr_uint:
    inline for field in fields_of(T):
        return offset_of(T, field)
    return ptr_uint<-0

# ---------------------------------------------------------------------------
# 12  const function — compile-time-evaluable functions
# ---------------------------------------------------------------------------

const function square(x: int) -> int:
    return x * x


const function cube(x: int) -> int:
    let sq = square(x)
    return sq * x

const SQUARE_5: int = square(5)
const CUBE_3: int = cube(3)


function test_const_function() -> int:
    if SQUARE_5 != 25:
        return 701
    if CUBE_3 != 27:
        return 702
    return 0

# ---------------------------------------------------------------------------
# 13  Type-level dispatch — inline if with field.type comparison
# ---------------------------------------------------------------------------

function typed_sizes[T]() -> ptr_uint:
    var total: ptr_uint = 0
    inline for field in fields_of(T):
        inline if field.type == float:
            total = total + ptr_uint<-4
        else if field.type == uint:
            total = total + ptr_uint<-4
        else if field.type == ushort:
            total = total + ptr_uint<-2
        else if field.type == ubyte:
            total = total + ptr_uint<-1
        else if field.type == byte:
            total = total + ptr_uint<-1
    return total


function test_type_dispatch() -> int:
    let cs = typed_sizes[CompactHeader]()
    if cs != ptr_uint<-4:
        return 801
    return 0

# ---------------------------------------------------------------------------
# 14  MAIN
# ---------------------------------------------------------------------------

function main() -> int:
    var code: int = 0

    code = test_inline_if_true()
    if code != 0:
        return code
    code = test_inline_if_false()
    if code != 0:
        return code
    code = test_inline_if_chain()
    if code != 0:
        return code
    code = test_inline_if_and_or()
    if code != 0:
        return code
    code = test_inline_if_not()
    if code != 0:
        return code

    code = test_sizeof_literal()
    if code != 0:
        return code
    code = test_sizeof_ptr_void()
    if code != 0:
        return code
    code = test_sizeof_nullable()
    let _ = test_sizeof_field_type[Vec3]()
    let _ = test_sizeof_generic[uint]()

    code = test_offsetof_literal()
    if code != 0:
        return code
    code = test_offsetof_packed()
    if code != 0:
        return code
    let _ = test_offsetof_inline_for[Vec3]()
    let _ = test_offsetof_generic[Entity]()

    let nf = count_fields[Entity]()
    let nm = first_field_name[Vec3]()

    code = test_hash_equal()
    if code != 0:
        return code
    code = test_order_vec()
    if code != 0:
        return code

    code = test_serialize_pod()
    if code != 0:
        return code
    code = test_serialize_nested()
    if code != 0:
        return code
    code = test_serialize_writer_reader()
    if code != 0:
        return code
    code = test_serialize_too_short()
    if code != 0:
        return code

    let _ = test_inline_for_if[Entity]()
    code = test_double_inline_for()
    if code != 0:
        return code

    let _ = test_alignof_field[CompactHeader]()
    let _ = test_alignof_field[CompactHeader]()

    var ts = TaggedStruct(data = uint<-0)
    let _ = reflect_constrained[TaggedStruct](ref_of(ts))
    let _ = test_nullable_ptr()
    let _ = test_zero_and_reflect[Vec3]()
    let _ = first_field_offset[CompactHeader]()

    code = test_const_function()
    if code != 0:
        return code

    code = test_type_dispatch()
    if code != 0:
        return code

    return 0
