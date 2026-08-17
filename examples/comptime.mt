## Milk Tea Compile-Time Evaluation Example
##
## Exercises the compile-time (comptime) surface: const functions, const
## methods, block-bodied consts with loops (break/continue), expression
## folding (string concat, chars, matches, indexing, members, casts),
## const-block assignment/destructuring/guards, and the when / inline /
## reflection / emit / type-returning surface.
##
## Every folded constant is asserted in main() so the file is runnable:
## `mtc run examples/comptime.mt` exits 0 when every fold is correct. The
## ExitCode helpers below return nonzero (1, 2, ...) on the first mismatch.

function exit_code(code: int) -> int:
    return code

# =============================================================================
# 1  const functions and block-bodied consts
# =============================================================================

const function square(x: int) -> int:
    return x * x

const SQUARE_FOLDED: int = square(5)          # -> 25

# Block-bodied const: compile-time FNV-1a hash over a byte array.
const FNVA_OFFSET: uint = 0x811c9dc5
const FNVA_PRIME: uint = 0x01000193
const FNV_BYTES: array[ubyte, 5] = (0x68, 0x65, 0x6c, 0x6c, 0x6f)
const FNV_HASH_FOLDED -> uint:
    var h = FNVA_OFFSET
    for b in FNV_BYTES:
        h = (h ^ b) * FNVA_PRIME
    return h

# =============================================================================
# 2  const methods: static, plain value receiver, and this dispatch
# =============================================================================

struct Rect:
    w: int
    h: int

    const function area() -> int:
        return this.w * this.h

    const function double_area() -> int:
        return this.area() * 2

    static const function make(w: int, h: int) -> Rect:
        return Rect(w = w, h = h)

const RECT: Rect = Rect.make(10, 20)
const RECT_AREA_FOLDED: int = RECT.area()             # -> 200
const RECT_DOUBLE_FOLDED: int = RECT.double_area()    # -> 400

const RECT_LOCAL_METHODS -> int:
    var r = Rect.make(3, 4)
    return r.area() + r.double_area()                 # -> 36

# =============================================================================
# 3  compile-time loops with break / continue
# =============================================================================

const NEXT_POW2_FOLDED -> int:
    var n: int = 1
    while true:
        n = n * 2
        if n >= 1024:
            break
    return n                                           # -> 1024

const SUM_SKIP_FOLDED -> int:
    var total: int = 0
    for i in 0..10:
        if i == 3:
            continue
        if i >= 6:
            break
        total += i
    return total                                       # -> 12 (0+1+2+4+5)

# =============================================================================
# 4  expression folding: concat, chars, matches, indexing, members, casts
# =============================================================================

const CONCAT_FOLDED: str = "hello" + " " + "world"     # -> "hello world"

const CHAR_NEWLINE_FOLDED: ubyte = '\n'                # -> 10

const CHAR_MATCH_FOLDED -> int:
    return match 'b':
        'a': 1
        'b': 2
        _: 0                                           # -> 2

const INDEX_ARR: array[int, 3] = (10, 20, 30)
const INDEX_ARR_0_FOLDED: int = INDEX_ARR[0]           # -> 10
const INDEX_SLICE_FOLDED -> int:
    var total: int = 0
    for v in INDEX_ARR[1..3]:
        total += v
    return total                                       # -> 50

const INDEX_STR: str = "abcde"
const INDEX_STR_FIRST_FOLDED: ubyte = INDEX_STR[0]     # -> 97 ('a')
const INDEX_STR_SLICE_FOLDED: str = INDEX_STR[1..3]    # -> "bc"
const INDEX_STR_LEN_FOLDED: int = INDEX_STR.len        # -> 5

const TRUNC_CAST_FOLDED: int = int<-3.7                # -> 3
const WRAP_CAST_FOLDED: byte = byte<-300               # -> 44
const BREAK_CAST_FOLDED: short = short<-70000          # -> 4464
const BOOL_CAST_FOLDED: int = int<-true                # -> 1

# =============================================================================
# 5  const-block assignment, destructuring, and else guards
# =============================================================================

struct Pt:
    x: int
    y: int

const ASSIGN_FIELD_FOLDED -> int:
    var p = Pt(x = 1, y = 2)
    p.y = 5
    return p.y                                         # -> 5

const ASSIGN_INDEX_FOLDED -> int:
    var a = array[int, 3](1, 2, 3)
    a[1] = 9
    a[2] += 1
    return a[1] + a[2]                                 # -> 13

const COW_FOLDED -> int:
    var a = Pt(x = 1, y = 2)
    var b = a
    a.x = 5
    return b.x                                         # -> 1 (value semantics)

const DESTRUCTURE_FOLDED -> int:
    let (a, b) = (10, 20)
    let Pt(cx, cy) = Pt(x = 3, y = 4)
    return a + b + cx + cy                             # -> 37

const GUARD_SOME_FOLDED -> int:
    let x = Option[int].some(value = 42) else:
        return 0
    return x                                           # -> 42

const GUARD_NONE_FOLDED -> int:
    let x = Option[int].none else:
        return 9
    return x                                           # -> 9

const GUARD_RESULT_FOLDED -> int:
    let x = Result[int, str].failure(error = "bad") else as error:
        if error == "bad":
            return 44
        return 0
    return x                                           # -> 44

const GUARD_NULLABLE_FOLDED -> int:
    let maybe: int? = 42
    let x = maybe else:
        return 9
    return x                                           # -> 42

const DISCARD_FOLDED -> int:
    let _ = Result[int, int].success(value = 1) else:
        return 0
    return 55                                          # -> 55

# =============================================================================
# 6  when / inline / reflection / emit / type-returning
# =============================================================================

enum Target: ubyte
    native = 1
    wasm   = 2

const TARGET: Target = Target.native

function backend_label() -> str:
    when TARGET:
        Target.native:
            return "native"
        Target.wasm:
            return "wasm"

const DEBUG_RENDER: bool = false

function maybe_debug_gate() -> int:
    inline if DEBUG_RENDER:
        return 1
    return 0

struct Particle:
    x: float
    y: float
    z: float

function all_fields_float() -> bool:
    inline for field in fields_of(Particle):
        if field.type != float:
            return false
    return true

const function emit_helpers() -> void:
    emit function emitted_value() -> int:
        return 7

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

const WIDE: type = int_with_bits[64]
const WIDE_PTR: type = ptr[WIDE]

# =============================================================================
# 7  runtime assertion of every folded value
# =============================================================================

function runtime_fnva(buf: array[ubyte, 5]) -> uint:
    var h: uint = FNVA_OFFSET
    for b in buf:
        h = (h ^ uint<-b) * FNVA_PRIME
    return h

function runtime_area(w: int, h: int) -> int:
    return w * h

function main() -> int:
    # const functions / block consts
    if SQUARE_FOLDED != square(5): return exit_code(1)
    if FNV_HASH_FOLDED != runtime_fnva(FNV_BYTES): return exit_code(2)
    # const methods
    if RECT_AREA_FOLDED != runtime_area(10, 20): return exit_code(3)
    if RECT_DOUBLE_FOLDED != runtime_area(10, 20) * 2: return exit_code(4)
    if RECT_LOCAL_METHODS != 36: return exit_code(5)
    # loops
    if NEXT_POW2_FOLDED != 1024: return exit_code(6)
    if SUM_SKIP_FOLDED != 12: return exit_code(7)
    # expression folds
    if CONCAT_FOLDED != "hello world": return exit_code(8)
    if int<-CHAR_NEWLINE_FOLDED != 10: return exit_code(9)
    if CHAR_MATCH_FOLDED != 2: return exit_code(10)
    if INDEX_ARR_0_FOLDED != 10: return exit_code(11)
    if INDEX_SLICE_FOLDED != 50: return exit_code(12)
    if int<-INDEX_STR_FIRST_FOLDED != 97: return exit_code(13)
    if INDEX_STR_SLICE_FOLDED != "bc": return exit_code(14)
    if INDEX_STR_LEN_FOLDED != 5: return exit_code(15)
    if TRUNC_CAST_FOLDED != int<-3.7: return exit_code(16)
    if int<-WRAP_CAST_FOLDED != int<-byte<-300: return exit_code(17)
    if int<-BREAK_CAST_FOLDED != int<-short<-70000: return exit_code(18)
    if BOOL_CAST_FOLDED != int<-true: return exit_code(19)
    # const-block assignment / destructure / guards
    if ASSIGN_FIELD_FOLDED != 5: return exit_code(20)
    if ASSIGN_INDEX_FOLDED != 13: return exit_code(21)
    if COW_FOLDED != 1: return exit_code(22)
    if DESTRUCTURE_FOLDED != 37: return exit_code(23)
    if GUARD_SOME_FOLDED != 42: return exit_code(24)
    if GUARD_NONE_FOLDED != 9: return exit_code(25)
    if GUARD_RESULT_FOLDED != 44: return exit_code(26)
    if GUARD_NULLABLE_FOLDED != 42: return exit_code(27)
    if DISCARD_FOLDED != 55: return exit_code(28)
    # when / inline / reflection / emit / type-returning
    if backend_label() != "native": return exit_code(29)
    if maybe_debug_gate() != 0: return exit_code(30)
    if not all_fields_float(): return exit_code(31)
    if emitted_value() != 7: return exit_code(32)
    return exit_code(0)
