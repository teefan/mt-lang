## Milk Tea Language Baseline
##
## This file exercises the language surface documented in README.md
## and docs/language-manual.md.  It is structured as a single ordinary
## module that parses, type-checks, and lowers to C without errors.
##
## Each section exercises a group of features.

# ---------------------------------------------------------------------------
# 1  Module imports
# ---------------------------------------------------------------------------

import std.async as aio
import std.linear_algebra

# ---------------------------------------------------------------------------
# 2  Literals
# ---------------------------------------------------------------------------

# --- integer literals (decimal, hex, binary, underscore separators)
const DECIMAL: int = 42
const HEX_LITERAL: uint = 0xff
const BIN_LITERAL: int = 0b1010
const SEPARATED: ulong = 1_000_000

# --- float literals (including exponent notation)
const PI: float = 3.14
const SMALL: double = 1.1920929E-7
const EXPONENT: float = 1.2e-3

# --- boolean literals
const YES: bool = true
const NO: bool = false

# --- string literal  (type is str)
public const GREETING: str = "hello"

# --- cstring literal  (type is cstr)
const C_GREETING: cstr = c"hello from C"

# --- heredoc string
const SHADER: cstr = c<<-GLSL
    #version 330
    void main() {
        gl_Position = vec4(0.0);
    }
GLSL

# --- plain heredoc
const PLAIN_HEREDOC: str = <<-MSG
    This is a plain heredoc.
    Leading whitespace is stripped.
MSG

# --- heredoc format string (exercised in function body)

function heredoc_fmt_demo() -> void:
    let _rendered = f<<-SQL
    SELECT * FROM items
    WHERE count = #{42}
SQL
    return

# --- null and typed null
const VOID_PTR: ptr[char]? = null
const TYPED_NULL: ptr[int]? = null[ptr[int]]

# ---------------------------------------------------------------------------
# 3  Data declarations: type, struct, union, variant, enum, flags, opaque
# ---------------------------------------------------------------------------

# --- type aliases (plain, callable)

type Seconds = float
public type IntCallback = fn(value: int) -> void

# --- plain struct with fields

struct Vec2:
    x: float
    y: float

# --- struct with attribute application  (@[packed], @[align])
@[packed]
struct Header:
    tag: ubyte

@[align(16)]
struct Mat4:
    data: array[float, 16]

# --- nested struct (scoped type inside enclosing struct body; also exercises qualified name access)

struct Rectangle:
    x: float
    y: float

    struct Edge:
        start: float
        end: float

    top_edge: Edge
    left_edge: Edge

# --- union

union Number:
    i: int
    f: float

# --- enum (explicit backing type)

enum State: ubyte
    idle = 0
    running = 1

# --- flags (bitmask, composite alias referencing earlier member)

flags Mask: uint
    a = 1 << 0
    b = 1 << 1
    both = Mask.a | Mask.b

# --- opaque

opaque RawHandle

# --- generic struct
public struct Pair[A, B]:
    first: A
    second: B

# --- custom variant (tagged union)
public variant TokenKind:
    ident(name: str)
    number(value: int)
    eof

# ---------------------------------------------------------------------------
# 4  Interfaces, methods, implements
# ---------------------------------------------------------------------------

interface Damageable:
    editable function take_damage(amount: int) -> void
    function is_alive() -> bool
    static function max_hp() -> int

interface Named:
    function name() -> str

struct NPC implements Damageable, Named:
    hp: int


extending NPC:
    editable function take_damage(amount: int) -> void:
        this.hp = this.hp - amount


    function is_alive() -> bool:
        return this.hp > 0


    function name() -> str:
        return "npc"


    static function default() -> NPC:
        return NPC(hp = 100)


    static function max_hp() -> int:
        return 100

# --- generic function with implements constraint

function damage_one[T implements Damageable](target: ref[T], amount: int) -> void:
    if target.is_alive():
        target.take_damage(amount)

# --- generic function with multiple implements constraints

function describe[T implements Damageable and Named](target: ref[T]) -> str:
    if target.is_alive():
        return target.name()
    return "dead"

# --- generic function without constraint (relies on default[T])

function make_default[T]() -> T:
    return default[T]

# --- generic interface with type parameters and implements constraint

interface Converter[T, U]:
    function convert(x: T) -> U

struct Doubler implements Converter[int, int]:
    value: int

extending Doubler:
    function convert(x: int) -> int:
        return x * 2

function apply_converter[T implements Converter[int, int]](c: ref[T], v: int) -> int:
    return c.convert(v)

# ---------------------------------------------------------------------------
# 5  Custom attributes and compile-time reflection
# ---------------------------------------------------------------------------

attribute[field] rename(name: str)
attribute[callable] traced(tag: str)

struct Labeled:
    @[rename("my_field")]
    value: int


@[traced("identity")]
function identity(x: int) -> int:
    return x

static_assert(
    has_attribute(field_of(Labeled, value), rename),
    "rename attribute missing on field"
)
static_assert(
    has_attribute(callable_of(identity), traced),
    "traced attribute missing on identity"
)

const SIZEOF_LABELED: ptr_uint = size_of(Labeled)
const ALIGNOF_LABELED: ptr_uint = align_of(Labeled)
const OFFSET_VALUE: ptr_uint = offset_of(Labeled, value)

# ---------------------------------------------------------------------------
# 5b  Expanded user-defined attribute targets
# ---------------------------------------------------------------------------
#
# user-defined attributes now target 9 kinds:
#   struct, field, callable, const, event, enum, flags, union, variant

attribute[const, event, enum, flags, union, variant] tagged(tag: str)

@[tagged("my_const")]
const TRACED_CONST: int = 999

@[tagged("top_event")]
event tagged_event[4]

@[tagged("color_enum")]
enum ColorSet: ubyte
    red = 1
    green = 2
    blue = 3

@[tagged("perm_flags")]
flags PermSet: uint
    read = 1 << 0
    write = 1 << 1

@[tagged("val_union")]
union TaggedValue:
    i: int
    f: float

@[tagged("status")]
variant OpStatus:
    ok
    failed(code: int)

# --- built-in deprecated attribute on expanded targets
@[deprecated("use ColorSet instead")]
enum LegacyColor: ubyte
    r = 0
    g = 1
    b = 2

function traced_demo() -> int:
    return TRACED_CONST

# ---------------------------------------------------------------------------
# 6  Top-level const, var, events
# ---------------------------------------------------------------------------

const WIDTH: int = 640
public var global_counter: int = 0

var scratch_buffer: array[ubyte, 256]

# --- event (no payload)
public event ready[4]

# --- event with payload
public event updated[8](Seconds)

# ---------------------------------------------------------------------------
# 7  Functions, externals
# ---------------------------------------------------------------------------

function void_returning() -> void:
    return


function simple_noop():
    pass


function add(a: int, b: int) -> int:
    return a + b

# --- generic function (explicit specialization at call site)

function first_pair[T](pair: Pair[T, int]) -> T:
    return pair.first

# --- generic function with ref parameter

function read_into[T](source: T, target: ref[T]) -> void:
    read(target) = source

# --- external function (simple manual ABI bridge; no call needed)

external function atoi(input: cstr) -> int

# ---------------------------------------------------------------------------
# 8  Statements: local declarations, guards, Result propagation
# ---------------------------------------------------------------------------

function statements_demo() -> int:
    # --- let / var locals with type inference
    let x = 10
    var y = 20
    y += 1

    # --- typed local without initializer (zero-initialized)
    var result: int

    # --- char literal and usage
    let nl: char = char<-10
    let letter: char = char<-65
    let _nl = nl
    let _letter = letter

    # --- if / else if / else
    if x + y > 30:
        result = 1
    else if x > 0:
        result = 2
    else:
        result = 3

    # --- while
    var count: int = 3
    while count > 0:
        count -= 1

    # --- for over range
    for i in 0..4:
        result += 1

    # --- for over array
    var values: array[int, 3]
    values[0] = 10
    values[1] = 20
    values[2] = 30
    for item in values:
        result += item

    # --- for over span
    let sp = span[int](data = ptr_of(values[0]), len = 3)
    for item in sp:
        result += item

    # --- parallel for
    var a: array[int, 3]
    var b: array[int, 3]
    a[0] = 1
    a[1] = 2
    a[2] = 3
    b[0] = 4
    b[1] = 5
    b[2] = 6
    for left, right in a, b:
        result += left + right

    # --- range index assignment
    values[0..2] = (1, 2)

    # --- pass
    if true:
        pass

    # --- break / continue
    var i: int = 0
    while i < 5:
        i += 1
        if i == 2:
            continue
        if i == 4:
            break

    # --- match over enum
    let st = State.running
    match st:
        State.idle:
            result += 0
        State.running:
            result += 1

    # --- match over variant (built-in Option)
    let opt = Option[int].some(value = 42)
    match opt:
        Option[int].some as s:
            result += s.value
        Option[int].none:
            result += 0

    # --- match over custom variant
    let tk = TokenKind.ident(name = "hello")
    match tk:
        TokenKind.ident as iden:
            result += 1
        TokenKind.number as n:
            result += n.value
        TokenKind.eof:
            result += 0

    # --- match over variant with struct pattern (field binding)
    let tk2 = TokenKind.ident(name = "struct-match")
    match tk2:
        TokenKind.ident(name):
            if name == "struct-match":
                result += 1
        TokenKind.number as n:
            result += n.value
        TokenKind.eof:
            result += 0

    # --- match over integer
    match result:
        0:
            result = 0
        1:
            result = 1
        _:
            result = -1

    # --- defer (block form)
    defer:
        global_counter += result

    defer:
        global_counter += 1
        global_counter += 2

    return result

# ---------------------------------------------------------------------------
# 8b   Guards: let ... else: / var ... else: / else as error:
# ---------------------------------------------------------------------------

enum GuardError: ubyte
    missing = 1
    timeout = 2


function guard_demo() -> Result[int, GuardError]:
    # --- let ... else: over nullable
    let known_ptr: ptr[int]? = null[ptr[int]]
    let safe = known_ptr else:
        return Result[int, GuardError].failure(error = GuardError.missing)

    # --- let ... else as error: over Result
    let value = Result[int, GuardError].success(value = 7) else as error:
        return Result[int, GuardError].failure(error = error)

    # --- let ... else: over get() (recoverable array index)
    let guarded_arr: array[int, 3] = array[int, 3](10, 20, 30)
    let third = get(guarded_arr, 2) else:
        return Result[int, GuardError].failure(error = GuardError.missing)
    let _third = unsafe: read(third)

    # --- var ... else: over Option
    let maybe: Option[int]? = Option[int].some(value = 3)
    var bound = maybe else:
        return Result[int, GuardError].failure(error = GuardError.missing)

    # --- let _ = ... else: (discard success)
    let _ = Result[int, GuardError].success(value = 1) else:
        return Result[int, GuardError].failure(error = GuardError.missing)

    # --- postfix Result propagation (expr?)
    let parsed = Result[int, GuardError].success(value = 5)?
    let v = parsed
    return Result[int, GuardError].success(value = v + unsafe: safe[0])

# ---------------------------------------------------------------------------
# 9  Expressions and operators
# ---------------------------------------------------------------------------

function expressions_demo(x: int, y: int) -> int:
    # --- arithmetic
    let a = x + y
    let b = x - y
    let c = x * y
    let d = x / y
    let e = x % y

    # --- bitwise
    let f = a & b
    let g = a | b
    let h = a ^ b
    let i = ~a
    let j = a << 2
    let k = a >> 2

    # --- comparison
    let eq = x == y
    let ne = x != y
    let lt = x < y
    let le = x <= y
    let gt = x > y
    let ge = x >= y

    # --- boolean
    let and_val = eq and lt
    let or_val = eq or lt
    let not_val = not eq

    # --- compound assignment operators
    var acc: int = x
    acc += y
    acc -= y
    acc *= y
    acc /= y
    acc %= y
    acc &= y
    acc |= y
    acc ^= y
    acc <<= 1
    acc >>= 1

    # --- if expression
    let chosen = if x > y: x else: y

    # --- member access and indexing
    let v = Vec2(x = 1.0, y = 2.0)
    let vx_val = int<-(v.x)
    let buf: array[int, 4]
    let elem = buf[0]

    # --- specialization expression
    let pair = Pair[int, float](first = 10, second = 3.0)

    # --- parenthesized expression (wrapped with delimiter)
    let wrapped = (
        x
        + y
        - acc
    )

    # --- operator-led continuation
    let continued = x + y - acc

    let expr_result = wrapped + continued + chosen + vx_val + elem + pair.first
    return expr_result

# ---------------------------------------------------------------------------
# 10  Built-in callable surface
# ---------------------------------------------------------------------------

function builtins_demo() -> int:
    var counter: int = 0

    # --- ref_of: mutable borrow
    let handle = ref_of(counter)
    read(handle) = 42

    # --- const_ptr_of: read-only pointer
    let const_p = const_ptr_of(counter)

    # --- ptr_of: writable raw pointer from safe ref
    let raw_p = ptr_of(handle)

    # --- read through ref and pointer
    let val_ref = read(handle)
    let val_ptr = unsafe: read(raw_p)

    # --- T<-value: explicit cast
    let as_long = long<-counter
    let as_int = int<-as_long

    # --- zero[T]: zero initialization
    let zeroed = zero[int]

    # --- default[T] (via associated function)
    let default_npc = default[NPC]

    # --- fatal (compile-time recognized)
    if counter != 42:
        fatal(c"unexpected counter value")

    # --- array[T, N]() literal construction
    var arr: array[int, 4] = array[int, 4](1, 2, 3, 4)
    let size = size_of(int)
    let align = align_of(int)

    # --- reinterpret requires unsafe
    let bits = unsafe: reinterpret[uint](counter)
    let _bits_val = bits

    # --- span[T] construction
    let sp = span[int](data = ptr_of(arr[0]), len = 4)
    let _sp_copy = sp

    # --- get(coll, index): recoverable array/span indexing (returns ptr[T]?)
    let elem_ptr = get(arr, 1) else:
        fatal(c"get: array index out of bounds")
    unsafe:
        read(elem_ptr) = 99

    let sp_elem = get(sp, 0) else:
        fatal(c"get: span index out of bounds")
    let _sp_val = unsafe: read(sp_elem)

    # --- auto-deref ref
    read(handle) = read(handle) + 1
    var _rd: array[int, 4] = arr

    return val_ref + val_ptr + zeroed + default_npc.hp

# ---------------------------------------------------------------------------
# 11  unsafe blocks
# ---------------------------------------------------------------------------

function unsafe_demo() -> void:
    var counter: int = 42
    let raw_p = ptr_of(counter)

    # --- unsafe expression
    let val = unsafe: read(raw_p)
    let _v = val

    # --- unsafe block
    unsafe:
        raw_p[0] = 99
        let deref = read(raw_p)
        raw_p[0] = deref + 1

    # --- pointer arithmetic in unsafe
    let adjusted = unsafe: raw_p + 1
    let _a = adjusted
    return

# ---------------------------------------------------------------------------
# 12  proc expressions (closures, captures, nesting)
# ---------------------------------------------------------------------------

# --- 12a: proc capturing local int value
function proc_demo() -> int:
    let offset = 3
    let triple = proc(x: int) -> int: x * offset

    let result = triple(5)
    return result

# --- 12b: proc capturing array[T, N] by value
function proc_array_capture_demo() -> int:
    let offsets = array[int, 3](1, 2, 3)
    let cb = proc() -> int:
        return offsets[0] + offsets[1] + offsets[2]
    return cb()

# --- 12c: proc capturing another proc (retain/release lifecycle)
function proc_capture_proc_demo() -> int:
    let inner = proc() -> int:
        return 42
    let outer = proc() -> int:
        return inner() + 1
    return outer()

# --- 12d: function returning a capturing proc from factory
function make_multiplier(factor: int) -> proc(x: int) -> int:
    return proc(x: int) -> int:
        return x * factor

function proc_factory_demo() -> int:
    let doubler = make_multiplier(2)
    return doubler(21)

# --- 12e: proc returning another proc (higher-order closure)
function make_adder(base: int) -> proc(add: int) -> int:
    return proc(add: int) -> int:
        return base + add

function proc_returning_proc_demo() -> int:
    let adder = make_adder(10)
    return adder(5)

# --- 12f: proc stored in struct field, with capture
struct Callback:
    invoke: proc() -> int

function proc_struct_demo() -> int:
    let offset = 7
    let invoke = proc() -> int:
        return offset + 3
    let cb = Callback(invoke = invoke)
    return cb.invoke()

# --- 12g: capture-free proc stored in module variable (static-storage-safe)
#     A proc that references only module-level functions, constants,
#     and types has no captures from enclosing scopes.  Its env pointer
#     is NULL and the value is a static initializer — no heap allocation.

var modvar_proc: proc(x: int) -> int = proc(x: int) -> int: x * 2

function modvar_proc_demo() -> int:
    return modvar_proc(21)

# ---------------------------------------------------------------------------
# 13  events usage (within declaring module)
# ---------------------------------------------------------------------------

function emit_ready() -> void:
    ready.emit()


function on_ready_callback() -> void:
    global_counter += 1


function on_ready_once() -> void:
    global_counter += 1


function schedule_ready_callback() -> void:
    var _h_sub = ready.subscribe(on_ready_callback)
    var _h_once = ready.subscribe_once(on_ready_once)
    # unsubscribe handled in test of emitted patterns

# ---------------------------------------------------------------------------
# 14  format strings
# ---------------------------------------------------------------------------

function format_demo() -> str:
    let count = 42
    let label = "items"
    global_counter = 0

    # --- escape sequences
    let escaped = "line1\nline2\ttabbed\\ quote \" end"
    let _esc = escaped

    # --- adjacent string concatenation
    let adjacent = "hello "
        "from multiple "
        "indented lines"
    let _adj = adjacent

    # --- basic interpolation
    let text = f"count=#{count} label=#{label}"

    # --- nested expression in interpolation
    let calc = f"calc=#{count * 2 + 1:b}"
    let _calc = calc

    # --- format specs: hex, octal, binary
    let hex = f"hex=#{count:x} hex_upper=#{count:X}"
    let oct = f"oct=#{count:o} oct_upper=#{count:O}"
    let bin = f"bin=#{count:b} bin_upper=#{count:B}"

    # --- float precision
    let dist: float = 3.14
    let precise = f"dist=#{dist:.2}"

    # --- plain heredoc in function body
    let heredoc = <<-MSG
        Plain heredoc inside function.
    MSG
    let _heredoc = heredoc

    let _h = hex
    let _o = oct
    let _b = bin
    let _p = precise

    return text

# ---------------------------------------------------------------------------
# 15  Generic struct usage
# ---------------------------------------------------------------------------

function generics_demo() -> int:
    # --- generic struct specialization
    let pair = Pair[int, bool](first = 10, second = true)
    let fisth = pair.first

    # --- generic variant construction (built-in Option)
    let some_opt = Option[float].some(value = 3.14)
    let none_opt = Option[float].none

    # --- generic variant match with different specializations
    match some_opt:
        Option[float].some as s:
            return int<-(s.value)
        Option[float].none:
            return 0

    return fisth

# ---------------------------------------------------------------------------
# 16  Async functions
# ---------------------------------------------------------------------------

async function async_child() -> int:
    return 41


async function async_demo() -> int:
    let v = await async_child()

    # --- await inside if expression
    let w = if v > 40: await async_child() else: 0

    # --- await inside while condition
    var i: int = 0
    while (await async_child()) > 0 and i < 2:
        i += 1

    # --- defer with await in async function
    defer:
        global_counter += i

    return v + w + i

# ---------------------------------------------------------------------------
# 17  Interface method and callable type projections
# ---------------------------------------------------------------------------

function interface_demo(target: ref[NPC]) -> int:
    # --- methods via type projection (editable function)
    target.take_damage(10)

    # --- method via value receiver
    let alive = target.is_alive()

    # --- static function via type projection
    let max_hp = NPC.max_hp()
    let _m = max_hp

    # --- generic constrained function call (single constraint)
    damage_one[NPC](target, 5)

    # --- generic constrained function call (multiple constraints)
    let label = describe[NPC](target)
    let _l = label

    if alive:
        return 1
    return 0

# ---------------------------------------------------------------------------
# 18  static_assert
# ---------------------------------------------------------------------------

static_assert(size_of(int) == 4, "int must be 4 bytes")
static_assert(true, "static_assert true check")

# ---------------------------------------------------------------------------
# 19  str_buffer[N] usage
# ---------------------------------------------------------------------------

function str_buffer_demo() -> bool:
    var buffer: str_buffer[64]

    buffer.assign("hello")
    buffer.append(" world")
    buffer.assign_format(f"count=#{42}")

    let s = buffer.as_str()
    let c = buffer.as_cstr()

    let length = buffer.len()
    let capacity = buffer.capacity()

    buffer.clear()

    return length + capacity > 0

# ---------------------------------------------------------------------------
# 20  Nullability
# ---------------------------------------------------------------------------

function nullability_demo() -> int:
    # --- nullable pointers and null checks
    let ptr: ptr[int]? = null
    let cstr_ptr: cstr? = null

    # --- flow narrowing nullable pointer
    if ptr == null:
        return 0

    # ptr is non-null here after flow narrowing
    if cstr_ptr != null:
        return 0

    return 1

# ---------------------------------------------------------------------------
# 21  Compile-time evaluation
# ---------------------------------------------------------------------------

# --- 21a: block-bodied const with `->`
# The block body is a sequence of statements evaluated at compile time.
# The block's `return` produces the const value.

const NEXT_POW2_ABOVE_1000 -> int:
    var n: int = 1
    while n < 1024:
        n = n * 2
    return n

# --- 21b: FNV-1a hash of a constant byte array, computed at compile time
const FNV_OFFSET: uint = 0x811c9dc5
const FNV_PRIME: uint = 0x01000193

const HELLO: array[ubyte, 5] = (0x68, 0x65, 0x6c, 0x6c, 0x6f)
const FNV_HASH -> uint:
    var h = FNV_OFFSET
    for b in HELLO:
        h = (h ^ b) * FNV_PRIME
    return h

# --- 21c: when for compile-time dispatch

enum TargetBackend: ubyte
    gl = 1
    metal = 2
    vulkan = 3

const TARGET: TargetBackend = TargetBackend.gl


function backend_label() -> str:
    when TARGET:
        TargetBackend.gl:
            return "OpenGL"
        TargetBackend.metal:
            return "Metal"
        TargetBackend.vulkan:
            return "Vulkan"

# --- 21c2: when at module level for conditional declarations

enum Platform: ubyte
    linux = 1
    windows = 2

const CURRENT_PLATFORM: Platform = Platform.linux

when CURRENT_PLATFORM:
    Platform.linux:
        const MODULE_WHEN_TEST: str = "linux-module-when"
        function module_when_func() -> int:
            return 1
    Platform.windows:
        const MODULE_WHEN_TEST: str = "windows-module-when"
        function module_when_func() -> int:
            return 2

# --- 21d: enum used by inline match and members_of below

enum Palette: ubyte
    red = 1
    green = 2
    blue = 3

# --- 21e: inline match for compile-time dispatch (alternative to when)

const FAVORITE_COLOR: Palette = Palette.red


function favorite_label() -> str:
    inline match FAVORITE_COLOR:
        Palette.red:
            return "warm"
        Palette.green:
            return "cool"
        Palette.blue:
            return "cool"

# --- 21f: inline for over a struct's fields (reflection: fields_of)

struct Particle:
    x: float
    y: float
    z: float


function all_fields_floats() -> bool:
    inline for field in fields_of(Particle):
        if field.type != float:
            return false
    return true

# --- 21g: inline while with a compile-time-bounded step

const ROUNDED_UP -> int:
    var n: int = 1
    inline while n < 1024:
        n = n * 2
    return n

# --- 21h: members_of over an enum (reflection: members_of)

function color_count() -> int:
    var count: int = 0
    inline for member in members_of(Palette):
        let _name = member.name
        count += 1
    return count

# --- 21i: type as a return type (picking a primitive by width)

function int_with_bits[N: int]() -> type:
    if N == 8:
        return byte
    else if N == 16:
        return short
    else if N == 32:
        return int
    else if N == 64:
        return long
    static_assert(false, "unsupported bit width")

const Wide: type = int_with_bits[64]
const WidePtr: type = ptr[Wide]

# --- 21j: comptime demo function called from main

function comptime_demo() -> int:
    let pow2 = NEXT_POW2_ABOVE_1000
    let hash = FNV_HASH
    let label = backend_label()
    let all_float = all_fields_floats()
    let rounded = ROUNDED_UP
    let fav = favorite_label()
    let colors = color_count()
    let _label = label
    let _fav = fav
    return pow2 + int<-hash + int<-(all_float) + rounded + colors

# ---------------------------------------------------------------------------
# 22  Native vector types (vec2, vec3, vec4, ivec2, ivec3, ivec4)
# ---------------------------------------------------------------------------

function vector_demo() -> float:
    # --- zero-initialized vectors
    let v2 = zero[vec2]
    let v3 = zero[vec3]
    let v4 = zero[vec4]

    # --- integer vectors
    let iv2 = zero[ivec2]
    let iv3 = zero[ivec3]

    # --- field access
    let v2x = v2.x
    let v2y = v2.y
    let v3z = v3.z
    let v4w = v4.w
    let iv2x = iv2.x

    # --- component-wise arithmetic (same type)
    let vsum = v3 + v3 # vec3 + vec3
    let vdiff = v3 - v3 # vec3 - vec3
    let vmul = v3 * v3 # vec3 * vec3 (component-wise)
    let vneg = -v3 # unary negation

    # --- scalar arithmetic
    let v_scaled = v3 * 2.0 # vec3 * scalar
    let sv_scaled = 3.0 * v3 # scalar * vec3
    let v_divided = v3 / 2.0 # vec3 / scalar

    # --- integer vector arithmetic
    let isum = iv3 + iv3 # ivec3 + ivec3
    let iscaled = iv3 * 3 # ivec3 * scalar
    let ineg = -iv3 # unary negation

    # --- extending block method on native vector type
    let squared = v3.squared_len()

    # --- methods from std.linear_algebra import (dot, length, cross, identity, etc.)
    let dot_val = v3.dot(v3)
    let len_val = v3.length()
    let cross_val = v3.cross(v3)
    let identity_mat = mat4.identity()
    let identity_quat = quat.identity()

    let _v2 = v2
    let _v4 = v4
    let _iv3 = iv3

    let result_a = vsum.x + vdiff.x
    let result_b = vmul.x + vneg.x
    let result_c = v_scaled.x + sv_scaled.x + v_divided.x
    let result_d = float<-(isum.x) + float<-(iscaled.x) + float<-(ineg.x)
    return (
        v2x + v2y + v3z + v4w + float<-(iv2x)
        + result_a + result_b + result_c + result_d
        + squared + dot_val + len_val + cross_val.x
        + identity_mat.col0.x + identity_quat.w
    )


extending vec3:
    function squared_len() -> float:
        return this.x * this.x + this.y * this.y + this.z * this.z

# ---------------------------------------------------------------------------
# 23  Native matrix types (mat3, mat4)
# ---------------------------------------------------------------------------

function matrix_demo() -> float:
    let m4 = zero[mat4]
    let m3 = zero[mat3]

    # --- field access (column vectors)
    let col0 = m4.col0
    let col0x = m4.col0.x

    # --- component-wise arithmetic
    let msum = m4 + m4 # mat4 + mat4
    let mdif = m4 - m4 # mat4 - mat4
    let mscaled = m4 * 2.0 # mat4 * scalar
    let mneg = -m4 # unary negation

    let _m3 = m3
    let _col0 = col0

    return msum.col0.x + mdif.col0.x + mscaled.col0.x + mneg.col0.x + col0x

# ---------------------------------------------------------------------------
# 24  Native quaternion type (quat)
# ---------------------------------------------------------------------------

function quat_demo() -> float:
    let q = zero[quat]

    # --- field access
    let qx = q.x
    let qy = q.y
    let qz = q.z
    let qw = q.w

    # --- component-wise arithmetic
    let qsum = q + q # quat + quat
    let qdiff = q - q # quat - quat
    let qmul = q * q # quat * quat (component-wise)
    let qneg = -q # unary negation

    let _qdiff = qdiff
    let _qmul = qmul

    return qsum.x + qneg.x + qx + qy + qz + qw

# ---------------------------------------------------------------------------
# 25  SoA (Structure-of-Arrays) type constructor
# ---------------------------------------------------------------------------

struct Point:
    x: float
    y: float
    z: float


function soa_demo() -> float:
    var particles: SoA[Point, 4]

    # --- indexed field access (each field is an independent array)
    particles[0].x = 1.0
    particles[0].y = 5.0
    particles[1].x = 2.0
    particles[1].y = 6.0
    particles[2].x = 3.0
    particles[3].x = 4.0

    # --- reading back via SoA index
    let first_x = particles[0].x
    let second_x = particles[1].x
    let first_y = particles[0].y

    return first_x + second_x + first_y

# ---------------------------------------------------------------------------
# 26  Compile-time code generation (emit)
# ---------------------------------------------------------------------------

const function generate_helpers() -> void:
    emit function zero_meaning() -> int:
        return 0

    emit function hex_prefix() -> str:
        return "0x"


function emit_demo() -> int:
    let meaning = zero_meaning()
    let prefix = hex_prefix()
    let _p = prefix
    return meaning

# ---------------------------------------------------------------------------
# 27  Lifetime-annotated refs with non-owning structs
# ---------------------------------------------------------------------------

struct Buffer[@a]:
    data: ref[@a, span[ubyte]]


function buffer_advance(buf: ref[Buffer]) -> void:
    # non-owning struct can be passed by ref as function parameter
    pass


function lifetime_demo() -> void:
    var storage: array[ubyte, 128]
    var sp = span[ubyte](data = ptr_of(storage[0]), len = 128)
    var buf = Buffer(data = ref_of(sp))
    buffer_advance(ref_of(buf))

# ---------------------------------------------------------------------------
# 28  struct.with() partial field update
# ---------------------------------------------------------------------------

function with_demo() -> Vec2:
    let v = Vec2(x = 1.0, y = 2.0)
    return v.with(x = 10.0)

# ---------------------------------------------------------------------------
# 29  Named arguments at call sites
# ---------------------------------------------------------------------------

function configure(host: str, port: int, debug: bool) -> void:
    pass

function named_args_demo() -> int:
    configure("localhost", port = 8080, debug = false)
    configure(host = "other", port = 3000, debug = true)
    return 1

# ---------------------------------------------------------------------------
# 30  dyn[InterfaceName] — runtime interface values
# ---------------------------------------------------------------------------

interface Shape:
    function area() -> float
    function label() -> str

struct Circle implements Shape:
    radius: float

extending Circle:
    function area() -> float:
        return 3.14159 * this.radius * this.radius

    function label() -> str:
        return "circle"

function dyn_demo() -> float:
    var c = Circle(radius = 5.0)
    var s: dyn[Shape] = adapt[Shape](ref_of(c))
    let label = s.label()
    let area = s.area()
    let _l = label
    return area

# ---------------------------------------------------------------------------
# 31  Tuples — positional, named, destructuring
# ---------------------------------------------------------------------------

function tuple_demo() -> int:
    # --- positional tuple construction and field access
    let pair = (42, 7)
    let sum_pos = pair._0 + pair._1

    # --- named tuple construction and field access
    let point = (x = 10, y = 20)
    let sum_named = point.x + point.y

    # --- tuple return type
    let result = get_coords()
    let coords_x = result._0
    let coords_y = result._1

    # --- destructuring
    let (a, b) = result
    let sum_dest = a + b

    # --- destructure with swap-like pattern
    var v1 = 1
    var v2 = 2
    var swapped = (v2, v1)
    let (left, rite) = swapped
    let ord = left + rite

    # --- struct destructuring
    var vec = Vec2(x = 1.0, y = 2.0)
    let Vec2(x, y) = vec
    let sum_struct = int<-(x + y)

    return sum_pos + sum_named + coords_x + coords_y + sum_dest + ord + sum_struct


function get_coords() -> (int, int):
    return (50, 60)

# ---------------------------------------------------------------------------
# 32  Nested structs (scoped types inside enclosing struct bodies)
# ---------------------------------------------------------------------------

function nested_struct_demo() -> float:
    var r: Rectangle

    r.x = 100.0
    r.y = 200.0

    r.top_edge.start = 0.0
    r.top_edge.end = 50.0

    r.left_edge.start = 0.0
    r.left_edge.end = 100.0

    let width = r.top_edge.end - r.top_edge.start
    let area = width * (r.left_edge.end - r.left_edge.start)

    var qualified: Rectangle.Edge
    qualified.start = 1.0
    qualified.end = 2.0

    let _q = qualified

    return r.x + r.y + area

# ---------------------------------------------------------------------------
# 33  Entrypoint
# ---------------------------------------------------------------------------

function main() -> int:
    var total: int = 0

    total += statements_demo()
    total += expressions_demo(3, 2)
    total += builtins_demo()
    total += proc_demo()
    total += proc_array_capture_demo()
    total += proc_capture_proc_demo()
    total += proc_factory_demo()
    total += proc_returning_proc_demo()
    total += proc_struct_demo()
    total += generics_demo()
    total += comptime_demo()
    total += emit_demo()

    total += int<-(vector_demo())
    total += int<-(matrix_demo())
    total += int<-(quat_demo())
    total += int<-(soa_demo())

    unsafe_demo()
    emit_ready()
    schedule_ready_callback()
    format_demo()
    heredoc_fmt_demo()
    str_buffer_demo()
    lifetime_demo()

    var npc = NPC.default()
    interface_demo(ref_of(npc))

    total += int<-(with_demo().x) + int<-(with_demo().y)
    nullability_demo()

    total += named_args_demo()
    total += int<-(dyn_demo())
    total += tuple_demo()

    total += int<-(nested_struct_demo())

    total += traced_demo()
    total += modvar_proc_demo()

    total += aio.wait(async_child())
    total += aio.wait(async_demo())

    var dblr = Doubler(value = 0)
    total += apply_converter[Doubler](ref_of(dblr), 3)

    # --- module-level when compilation (21c2) ---
    total += module_when_func()

    return total
