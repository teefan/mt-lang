## Milk Tea Language Baseline
##
## This file exercises the complete language surface documented in
## README.md and docs/language-manual.md.  It is structured as a single
## ordinary module that parses, type-checks, and lowers to C without errors.
##
## Option[T] and Result[T, E] are auto-imported via prelude —
## no explicit import needed.

# =============================================================================
# 1  Module imports & prelude types
# =============================================================================

import std.async as aio
import std.hash
import std.linear_algebra
import std.mem.endian as endian
import std.mem.heap as heap

# =============================================================================
# 2  Literals
# =============================================================================

const DECIMAL: int       = 42
const HEX_LITERAL: uint  = 0xff
const BIN_LITERAL: int   = 0b1010
const SEPARATED: ulong   = 1_000_000
const Z_LITERAL: ptr_uint = 100z

const PI: float       = 3.14
const SMALL: double   = 1.1920929E-7
const EXPONENT: float = 1.2e-3

const YES: bool = true
const NO: bool  = false

public const GREETING: str = "hello"
const C_GREETING: cstr     = c"hello from C"

const SHADER: cstr = c<<-GLSL
    #version 330
    void main() {
        gl_Position = vec4(0.0);
    }
GLSL

const PLAIN_HEREDOC: str = <<-MSG
    This is a plain heredoc.
    Leading whitespace is stripped.
MSG

function heredoc_fmt_demo() -> void:
    let _rendered = f<<-SQL
    SELECT * FROM items
    WHERE count = #{42}
SQL

const VOID_PTR:    ptr[char]? = null
const TYPED_NULL:  ptr[int]?  = null[ptr[int]]

var char_buf: array[char, 4]

var shorts: short   = 0
var bytes:  byte    = 0
var ptrint: ptr_int = 0

const FIRST_CHAR:   ubyte = 'A'
const NEWLINE:      ubyte = '\n'
const TAB_CHAR:     ubyte = '\t'
const BACKSLASH:    ubyte = '\\'
const SINGLE_QUOTE: ubyte = '\''
const NULL_BYTE:    ubyte = '\0'
const HEX_BYTE:     ubyte = '\x41'

# =============================================================================
# 3  Data declarations
# =============================================================================

type Seconds = float
public type IntCallback = fn(value: int) -> void
type IntGenerator = proc() -> int

struct Vec2:
    x: float
    y: float

@[packed]
struct Header:
    tag: ubyte

@[align(16)]
struct Mat4Layout:
    data: array[float, 16]

@[deprecated("use Vec2 instead")]
struct OldVec:
    x: float
    y: float

struct Rectangle:
    x: float
    y: float
    struct Edge:
        start: float
        end: float
    top_edge:  Edge
    left_edge: Edge

union Number:
    i: int
    f: float

enum State: ubyte
    idle    = 0
    running = 1

flags Mask: uint
    a    = 1 << 0
    b    = 1 << 1
    both = Mask.a | Mask.b

# Backing type defaults to int; values auto-increment from 0
enum Color:
    red
    green
    blue

# Auto-increment continues from the last explicit value
enum Status:
    idle = 10
    running
    stopped

# Explicit type with auto values
enum Kind: ubyte
    a
    b = 5
    c
    d

# Flags with default type and auto-increment
flags Perm:
    read = 1 << 0
    write
    exec

opaque RawHandle

opaque CFile implements Closable

extending CFile:
    function close() -> void:
        pass

public variant MyOption[T]:
    some(value: T)
    none

public struct Pair[A, B]:
    first:  A
    second: B

public variant TokenKind:
    ident(name: str)
    number(value: int)
    eof

# Variant with multi-field arms to exercise _ discard
variant MultiField:
    tagged(tag: int, pos_x: float, pos_y: float, title: str)
    empty

# =============================================================================
# 4  Interfaces, methods, implements
# =============================================================================

interface Damageable:
    editable function take_damage(amount: int) -> void
    function is_alive() -> bool
    static function max_hp() -> int

interface Named:
    function name() -> str

interface Closable:
    function close() -> void

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

function damage_one[T implements Damageable](target: ref[T], amount: int) -> void:
    if target.is_alive():
        target.take_damage(amount)

function describe[T implements Damageable and Named](target: ref[T]) -> str:
    if target.is_alive():
        return target.name()
    return "dead"

function make_default[T]() -> T:
    return default[T]

interface Converter[T, U]:
    function convert(x: T) -> U

struct Doubler implements Converter[int, int]:
    value: int

extending Doubler:
    function convert(x: int) -> int:
        return x * 2

function apply_converter[T implements Converter[int, int]](c: ref[T], v: int) -> int:
    return c.convert(v)

# =============================================================================
# 5  Custom attributes and compile-time reflection
# =============================================================================

attribute[field] rename(name: str)
attribute[callable] traced(tag: str)
attribute[const, event, enum, flags, union, variant] tagged(tag: str)

struct Labeled:
    @[rename("my_field")]
    value: int

@[traced("identity")]
function identity(x: int) -> int:
    return x

@[tagged("my_const")]
const TRACED_CONST: int = 999

@[tagged("top_event")]
event tagged_event[4]

@[tagged("color_enum")]
enum ColorSet: ubyte
    red   = 1
    green = 2
    blue  = 3

@[tagged("perm_flags")]
flags PermSet: uint
    read  = 1 << 0
    write = 1 << 1

@[tagged("val_union")]
union TaggedValue:
    i: int
    f: float

@[tagged("status")]
variant OpStatus:
    ok
    failed(code: int)

static_assert(has_attribute(field_of(Labeled, value), rename), "rename attribute missing")
static_assert(has_attribute(callable_of(identity), traced), "traced attribute missing")

const HAS_RENAME: bool = has_attribute(field_of(Labeled, value), rename)
const RENAME_ARG: str  = attribute_arg[str](
    attribute_of(field_of(Labeled, value), rename),
    name
)

function attributes_demo() -> int:
    var count: int = 0
    inline for attr in attributes_of(field_of(Labeled, value)):
        count += 1
    return count

# --- .value on member_handle ---

function member_value_demo() -> int:
    var total: int = 0
    inline for member in members_of(Palette):
        total += member.value
    return total

const SIZEOF_LABELED: ptr_uint = size_of(Labeled)
const ALIGNOF_LABELED: ptr_uint = align_of(Labeled)
const OFFSET_VALUE: ptr_uint = offset_of(Labeled, value)

function traced_demo() -> int:
    return TRACED_CONST

# =============================================================================
# 6  Top-level const, var, events
# =============================================================================

const WIDTH: int = 640
public var global_counter: int = 0
var scratch_buffer: array[ubyte, 256]

public event ready[4]
public event updated[8](Seconds)

# --- block-bodied const (also demonstrated in §21) ---

const DOUBLE_WIDTH -> int:
    return WIDTH * 2

# =============================================================================
# 7  Functions, externals, const function
# =============================================================================

function void_returning() -> void:
    return

function simple_noop():
    pass

function add(a: int, b: int) -> int:
    return a + b

const function square(x: int) -> int:
    return x * x

const SQUARE_5: int = square(5)

function const_func_demo() -> int:
    return square(7)

function first_pair[T](pair: Pair[T, int]) -> T:
    return pair.first

function read_into[T](source: T, target: ref[T]) -> void:
    read(target) = source

external function atoi(input: cstr) -> int

# out, in, inout param modes via foreign projection
external function c_write_int_ptr(ptr: ptr[int], value: int) -> void

foreign function wrap_write(out result: int, value: int) -> void = c_write_int_ptr
foreign function parse_int_foreign(input: str as cstr) -> int = atoi

function foreign_demo() -> int:
    return parse_int_foreign("42")

function foreign_modes_demo() -> int:
    var buf: int = 0
    wrap_write(buf, 99)
    return buf

# =============================================================================
# 8  Statements: locals, guards, ? propagation, control flow
# =============================================================================

# --- custom iterable with iter() protocol ---

struct SimpleRange:
    start: int
    stop:  int

struct SimpleRangeIter:
    pos:  int
    stop: int

extending SimpleRange:
    function iter() -> SimpleRangeIter:
        return SimpleRangeIter(pos = this.start, stop = this.stop)

extending SimpleRangeIter:
    editable function next() -> bool:
        if this.pos < this.stop:
            this.pos += 1
            return true
        return false
    function current() -> int:
        return this.pos - 1

function custom_iter_demo() -> int:
    var result: int = 0
    let r = SimpleRange(start = 0, stop = 5)
    for i in r:
        result += i
    return result

# detached concurrency helpers
function compute_side() -> void:
    global_counter += 1

function statements_demo() -> int:
    let x = 10
    var y = 20
    y += 1
    var result: int

    let nl: char = char<-10
    let _nl = nl

    if x + y > 30:
        result = 1
    else if x > 0:
        result = 2
    else:
        result = 3

    # --- inline if (single-statement body)
    if result > 0: result = 100 else: result = -1

    var count: int = 3
    while count > 0:
        count -= 1

    for i in 0..4:
        result += 1

    var values: array[int, 3]
    values[0] = 10
    values[1] = 20
    values[2] = 30
    for item in values:
        result += item

    let sp = span[int](data = ptr_of(values[0]), len = 3)
    for item in sp:
        result += item

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

    var positions: array[int, 4] = array[int, 4](0, 1, 2, 3)
    parallel for i in 0..4:
        positions[i] += 1

    var pa: int = 0
    var pb: int = 0
    parallel:
        pa = 42
        pb = 99
    result += pa + pb

    # --- detached concurrency: detach / gather
    let ha = detach compute_side()
    let hb = detach compute_side()
    gather ha, hb

    values[0..2] = (1, 2)

    if true:
        pass

    var i: int = 0
    while i < 5:
        i += 1
        if i == 2:
            continue
        if i == 4:
            break

    # --- match with | for multiple patterns sharing a body
    match result:
        0 | 1 | 2:
            result = 10
        3 | 4:
            result = 20
        _:
            result = 0

    match State.running:
        State.idle:
            result += 0
        State.running:
            result += 1

    # --- Option (prelude type, structurally detected)
    let opt = Option[int].some(value = 42)
    match opt:
        Option.some as s:
            result += s.value
        Option.none:
            result += 0

    # --- Result (prelude type)
    let res = Result[int, int].success(value = 7)
    match res:
        Result.success as s:
            result += s.value
        Result.failure as f:
            result += f.error

    # --- custom variant
    let tk = TokenKind.ident(name = "hello")
    match tk:
        TokenKind.ident as iden:
            result += 1
        TokenKind.number as n:
            result += n.value
        TokenKind.eof:
            result += 0

    # --- struct pattern in match
    let tk2 = TokenKind.ident(name = "struct-match")
    match tk2:
        TokenKind.ident(name):
            if name == "struct-match":
                result += 1
        TokenKind.number as n:
            result += n.value
        TokenKind.eof:
            result += 0

    # --- struct pattern _ discard (skip unneeded fields)
    var mf = MultiField.tagged(tag = 7, pos_x = 1.0, pos_y = 2.0, title = "test")
    match mf:
        MultiField.tagged(_, _, _, title):
            if title == "test":
                result += 1
        MultiField.empty:
            result += 0

    # --- integer match
    match result:
        0:
            result = 0
        1:
            result = 1
        _:
            result = -1

    # --- char-literal match on ubyte
    var ch: ubyte = '('
    match ch:
        '(':
            result += 1
        ')':
            result += 0
        '+':
            result += 0
        _:
            result += 0

    # --- match expression
    let label = match result:
        0: "zero"
        _: "other"
    let _label = label

    # --- match on str (expression form)
    let str_label = match result:
        0: "zero"
        1: "one"
        _: "other"
    let _str_label = str_label

    # --- match on str (statement form)
    var str_result: int = 0
    match str_label:
        "zero":
            str_result = 0
        "one":
            str_result = 1
        "other":
            str_result = 2
        _:
            str_result = -1
    result += str_result

    # --- is keyword: variant arm membership test
    let tk3 = TokenKind.eof
    if tk3 is TokenKind.eof:
        result += 1
    if not (tk3 is TokenKind.number):
        result += 1

    let is_ident = tk3 is TokenKind.ident
    if not is_ident:
        result += 1

    # --- == on variants: no-payload and payload comparison
    let eof1 = TokenKind.eof
    let eof2 = TokenKind.eof
    if eof1 == eof2:
        result += 1
    if eof1 != TokenKind.number(value = 0):
        result += 1

    let id_abc = TokenKind.ident(name = "abc")
    let id_abc2 = TokenKind.ident(name = "abc")
    let id_xyz = TokenKind.ident(name = "xyz")
    if id_abc == id_abc2:
        result += 1
    if id_abc != id_xyz:
        result += 1

    if id_abc != TokenKind.eof:
        result += 1

    # --- struct pattern guards and equality patterns
    var mf2 = MultiField.tagged(tag = 7, pos_x = 1.0, pos_y = 2.0, title = "test")
    match mf2:
        MultiField.tagged(tag > 5, _, _, _):
            result += 1
        MultiField.tagged(tag = 0, _, _, _):
            result += 0
        MultiField.empty:
            result += 0
        _:
            result += 0

    # --- struct pattern with as binding combined
    var mf3 = MultiField.tagged(tag = 3, pos_x = 0.0, pos_y = 0.0, title = "guard")
    match mf3:
        MultiField.tagged(tag > 0, _, _, _) as payload:
            if payload.tag == 3:
                result += 1
        MultiField.empty:
            result += 0
        _:
            result += 0

    # --- defer single-statement inline form
    defer on_ready_callback()

    defer:
        global_counter += result
    defer:
        global_counter += 1
        global_counter += 2

    return result

# =============================================================================
# 8b  Guards: let / var ... else: / else as error:
# =============================================================================

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

    # --- let ... else: over get()
    let guarded_arr: array[int, 3] = array[int, 3](10, 20, 30)
    let third = get(guarded_arr, 2) else:
        return Result[int, GuardError].failure(error = GuardError.missing)
    let _third = unsafe: read(third)

    # --- var ... else: over Option
    var bound = Option[int].some(value = 3) else:
        return Result[int, GuardError].failure(error = GuardError.missing)

    # --- let _ = ... else: (discard success)
    let _ = Result[int, GuardError].success(value = 1) else:
        return Result[int, GuardError].failure(error = GuardError.missing)

    # --- ? propagation on Result
    let parsed = Result[int, GuardError].success(value = 5)?
    let v = parsed
    return Result[int, GuardError].success(value = v + unsafe: safe[0])

# =============================================================================
# 8c  Option/Result extending methods
# =============================================================================

function option_methods_demo() -> int:
    var total: int = 0

    let some_opt = Option[int].some(value = 42)
    if some_opt.is_some():
        total += 1
    if not some_opt.is_none():
        total += 1
    if some_opt.unwrap() == 42:
        total += 1
    total += some_opt.unwrap_or(99)

    let none_opt = Option[int].none
    total += none_opt.unwrap_or(77)
    total += none_opt.unwrap_or_else(proc() -> int: 7)

    return total

function result_methods_demo() -> int:
    var total: int = 0

    let ok_val = Result[int, int].success(value = 7)
    if ok_val.is_success():
        total += 1
    if not ok_val.is_failure():
        total += 1
    if ok_val.unwrap() == 7:
        total += 1

    let err_val = Result[int, int].failure(error = 13)
    total += err_val.unwrap_error()
    total += err_val.unwrap_or(99)

    # --- ok() / err() — conversion to Option
    let opt_ok = ok_val.ok()
    match opt_ok:
        Option.some as s:
            total += s.value
        Option.none:
            total += 0

    let opt_err = err_val.error()
    match opt_err:
        Option.some as s:
            total += s.value
        Option.none:
            total += 0

    # --- map_err — cross-module error wrapping
    let mapped: Result[int, str] = err_val.map_error(proc(error: int) -> str: "bad")
    match mapped:
        Result.failure as f:
            if f.error == "bad":
                total += 1
        Result.success:
            total += 0

    # --- ? propagation with Option
    let propagated = propagate_option(Option[int].some(value = 5))
    match propagated:
        Option.some as s:
            total += s.value
        Option.none:
            total += 0

    return total

function propagate_option(opt: Option[int]) -> Option[int]:
    let value = opt?
    return Option[int].some(value = value * 2)

# =============================================================================
# 9  Expressions and operators
# =============================================================================

function expressions_demo(x: int, y: int) -> int:
    let a = x + y
    let b = x - y
    let c = x * y
    let d = x / y
    let e = x % y

    let f = a & b
    let g = a | b
    let h = a ^ b
    let i = ~a
    let j = a << 2
    let k = a >> 2

    let eq = x == y
    let ne = x != y
    let lt = x < y
    let le = x <= y
    let gt = x > y
    let ge = x >= y

    let and_val = eq and lt
    let or_val  = eq or lt
    let not_val = not eq

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

    let chosen = if x > y: x else: y

    let v = Vec2(x = 1.0, y = 2.0)
    let vx_val = int<-(v.x)
    let buf: array[int, 4]
    let elem = buf[0]

    let pair = Pair[int, float](first = 10, second = 3.0)

    let wrapped = (x + y - acc)
    let continued = x + y - acc

    let expr_result = wrapped + continued + chosen + vx_val + elem + pair.first
    let s_idle    = State.idle
    let s_running = State.running
    let enum_eq  = s_idle == s_idle
    let enum_ne  = s_idle != s_running
    let enum_lt  = s_idle <  s_running
    let enum_le  = s_idle <= s_running
    let enum_gt  = s_running >  s_idle
    let enum_ge  = s_running >= s_idle
    let enum_op  = (
        int<-(s_idle) + int<-(enum_eq) + int<-(enum_ne)
        + int<-(enum_lt) + int<-(enum_le) + int<-(enum_gt) + int<-(enum_ge)
    )

    let mask_a = Mask.a
    let mask_b = Mask.b
    let flags_eq = mask_a == mask_a
    let flags_ne = mask_a != mask_b
    let flags_or  = mask_a | mask_b
    let flags_and = mask_a & mask_b
    let flags_xor = mask_a ^ mask_b
    let flags_not = ~mask_a

    let enum_backing: bool = State.idle == ubyte<-0

    return expr_result + enum_op + int<-(flags_eq) + int<-(flags_ne) + int<-(flags_or) + int<-(flags_and) + int<-(flags_xor) + int<-(flags_not) + int<-(enum_backing)

# =============================================================================
# 10  Built-in callable surface
# =============================================================================

function builtins_demo() -> int:
    var counter: int = 0

    let handle  = ref_of(counter)
    read(handle) = 42

    let const_p = const_ptr_of(counter)
    let _const_p = const_p
    let raw_p   = ptr_of(handle)

    let val_ref = read(handle)
    let val_ptr = unsafe: read(raw_p)

    let as_long = long<-counter
    let as_int  = int<-as_long
    let _as_int = as_int

    let zeroed      = zero[int]
    let default_npc = default[NPC]

    var arr: array[int, 4] = array[int, 4](1, 2, 3, 4)
    var sp = span[int](data = ptr_of(arr[0]), len = 4)

    let elem_ptr = get(arr, 1) else:
        fatal(c"get: array index out of bounds")
    unsafe:
        read(elem_ptr) = 99

    let bits = unsafe: reinterpret[uint](counter)
    let _bits_val = bits

    var int_left: int = 10
    var int_right: int = 20
    let int_hash = hash[int](ptr_of(int_left))
    let int_eq   = equal[int](ptr_of(int_left), ptr_of(int_right))
    let int_ord  = order[int](ptr_of(int_left), ptr_of(int_right))

    return val_ref + val_ptr + zeroed + default_npc.hp + int<-(int_hash) + int<-(int_eq) + int_ord

# =============================================================================
# 11  unsafe blocks
# =============================================================================

function unsafe_demo() -> void:
    var counter: int = 42
    let raw_p = ptr_of(counter)

    let val = unsafe: read(raw_p)
    let _v = val

    unsafe:
        raw_p[0] = 99
        let deref = read(raw_p)
        raw_p[0] = deref + 1

    let adjusted = unsafe: raw_p + 1
    let _a = adjusted

# =============================================================================
# 12  proc and fn types (closures, fn pointers, coercion, containers)
# =============================================================================

function proc_demo() -> int:
    let offset = 3
    let triple = proc(x: int) -> int: x * offset
    return triple(5)

function proc_array_capture_demo() -> int:
    let offsets = array[int, 3](1, 2, 3)
    let cb = proc() -> int:
        return offsets[0] + offsets[1] + offsets[2]
    return cb()

function proc_capture_proc_demo() -> int:
    let inner = proc() -> int: 42
    let outer = proc() -> int:
        return inner() + 1
    return outer()

function make_multiplier(factor: int) -> proc(x: int) -> int:
    return proc(x: int) -> int: x * factor

function proc_factory_demo() -> int:
    return make_multiplier(2)(21)

function make_adder(base: int) -> proc(add: int) -> int:
    return proc(add: int) -> int: base + add

function proc_higher_order_demo() -> int:
    return make_adder(10)(5)

struct Callback:
    invoke: proc() -> int

function proc_struct_demo() -> int:
    let offset = 7
    let invoke = proc() -> int: offset + 3
    return Callback(invoke = invoke).invoke()

var modvar_proc: proc(x: int) -> int = proc(x: int) -> int: x * 2

function modvar_proc_demo() -> int:
    return modvar_proc(21)

# --- fn type: struct field, parameter, return ---

struct FnFilter:
    check: fn(x: int) -> bool

function is_positive_fn(x: int) -> bool:
    return x > 0

function fn_struct_demo() -> int:
    let f = FnFilter(check = is_positive_fn)
    if f.check(5):
        return 1
    return 0

function count_matching(values: span[int], pred: fn(x: int) -> bool) -> int:
    var count: int = 0
    for v in values:
        if pred(v):
            count += 1
    return count

function fn_param_return_demo() -> int:
    let nums = array[int, 3](-5, 10, 15)
    return count_matching(nums.as_span(), is_positive_fn) * 10

# --- fn → proc coercion (function call arguments) ---

function double_it_fn(x: int) -> int:
    return x * 2

function apply_int_op(p: proc(x: int) -> int, x: int) -> int:
    return p(x)

function fn_to_proc_call_demo() -> int:
    return apply_int_op(double_it_fn, 21)

# --- fn wrapped in proc for struct storage ---

function get_seven_fn() -> int:
    return 7

function fn_wrap_in_proc_demo() -> int:
    let c = Callback(invoke = proc() -> int: get_seven_fn())
    return c.invoke()

# --- nullable fn ---

function nullable_fn_demo() -> int:
    let pred: IntCallback? = null
    if pred == null:
        return 99
    return 0

# --- proc in array ---

function proc_array_demo() -> int:
    var ops: array[IntGenerator, 2]
    ops[0] = proc() -> int: 3
    ops[1] = proc() -> int: 7
    let a = ops[0]
    let b = ops[1]
    return a() + b()

# --- proc with ref param ---

function proc_ref_param_demo() -> int:
    var val: int = 10
    let getter = proc(x: ref[int]) -> int:
        return read(x) + 1
    return getter(ref_of(val))

# --- proc in tuple ---

function proc_tuple_demo() -> int:
    let pair = (42, proc() -> int: 5)
    let (val, getter) = pair
    return val + getter()

# --- proc through generic function ---

function call_proc[T](p: proc() -> T) -> T:
    return p()

function proc_generic_demo() -> int:
    let f = proc() -> int: 33
    return call_proc(f)

# =============================================================================
# 13  Events
# =============================================================================

function emit_ready() -> void:
    ready.emit()

function on_ready_callback() -> void:
    global_counter += 1

function on_ready_once() -> void:
    global_counter += 1

function schedule_ready_callback() -> void:
    let h_sub  = ready.subscribe(on_ready_callback) else:
        return
    let h_once = ready.subscribe_once(on_ready_once) else:
        return
    ready.unsubscribe(h_sub)

# --- event payload emission ---

function on_updated(delta: Seconds) -> void:
    global_counter += 1
    let _d = delta

function fire_updated() -> void:
    updated.emit(float<-1.5)

function event_payload_demo() -> int:
    let h = updated.subscribe(on_updated) else:
        return 0
    updated.emit(Seconds<-2.0)
    updated.unsubscribe(h)
    return 1

# =============================================================================
# 14  Format strings
# =============================================================================

function format_demo() -> str:
    let count = 42
    let label = "items"

    let escaped = "line1\nline2\ttabbed\\ quote \" end"
    let _esc = escaped

    let adjacent = "hello "
        "from multiple "
        "indented lines"
    let _adj = adjacent

    let text = f"count=#{count} label=#{label}"

    let calc = f"calc=#{count * 2 + 1:b}"
    let _calc = calc

    let hex = f"hex=#{count:x} upper=#{count:X}"
    let oct = f"oct=#{count:o} upper=#{count:O}"
    let bin = f"bin=#{count:b} upper=#{count:B}"

    let dist: float = 3.14
    let precise = f"dist=#{dist:.2}"

    let heredoc = <<-MSG
        Plain heredoc inside function.
    MSG

    let _h = hex
    let _o = oct
    let _b = bin
    let _p = precise
    let _heredoc = heredoc

    return text

# =============================================================================
# 15  Generics — struct & variant
# =============================================================================

function generics_demo() -> int:
    let pair = Pair[int, bool](first = 10, second = true)

    let some_opt = Option[float].some(value = 3.14)
    let none_opt = Option[float].none
    let _none = none_opt

    match some_opt:
        Option.some as s:
            return int<-(s.value) + pair.first
        Option.none:
            return 0
    return 0

# =============================================================================
# 16  Async
# =============================================================================

async function async_child() -> int:
    return 41

async function async_demo() -> int:
    let v = await async_child()

    let w = if v > 40: await async_child() else: 0

    var i: int = 0
    while (await async_child()) > 0 and i < 2:
        i += 1

    defer:
        global_counter += i

    return v + w + i

# =============================================================================
# 17  Static interface dispatch
# =============================================================================

function interface_demo(target: ref[NPC]) -> int:
    target.take_damage(10)
    let alive = target.is_alive()
    let max_hp = NPC.max_hp()
    let _m = max_hp

    damage_one[NPC](target, 5)
    let label = describe[NPC](target)
    let _l = label

    if alive:
        return 1
    return 0

# =============================================================================
# 18  static_assert
# =============================================================================

static_assert(size_of(int) == 4, "int must be 4 bytes")
static_assert(true, "static_assert true check")

# =============================================================================
# 19  str_buffer[N]
# =============================================================================

function str_buffer_demo() -> bool:
    var buffer: str_buffer[64]
    buffer.assign("hello")
    buffer.append(" world")
    buffer.assign_format(f"count=#{42}")
    let s = buffer.as_str()
    let c = buffer.as_cstr()
    let _s = s
    let _c = c
    let length   = buffer.len()
    let capacity = buffer.capacity()
    buffer.clear()
    return length + capacity > 0

# =============================================================================
# 20  Nullability + flow narrowing
# =============================================================================

function nullability_demo() -> int:
    let ptr: ptr[int]? = null
    if ptr == null:
        return 0
    let cstr_ptr: cstr? = null
    if cstr_ptr != null:
        return 0

    # --- value-type nullable: stored inline as tagged optional
    let maybe_int: int? = 42
    let val = maybe_int else:
        return 0
    if val != 42:
        return 0

    let maybe_bool: bool? = null
    if maybe_bool != null:
        return 0

    return 1

# =============================================================================
# 21  Compile-time evaluation
# =============================================================================

const NEXT_POW2_ABOVE_1000 -> int:
    var n: int = 1
    while n < 1024:
        n = n * 2
    return n

const FNV_OFFSET: uint = 0x811c9dc5
const FNV_PRIME:  uint = 0x01000193
const HELLO: array[ubyte, 5] = (0x68, 0x65, 0x6c, 0x6c, 0x6f)
const FNV_HASH -> uint:
    var h = FNV_OFFSET
    for b in HELLO:
        h = (h ^ b) * FNV_PRIME
    return h

enum TargetBackend: ubyte
    gl     = 1
    metal  = 2
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

enum Platform: ubyte
    linux   = 1
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

struct Particle:
    x: float
    y: float
    z: float

function all_fields_floats() -> bool:
    inline for field in fields_of(Particle):
        if field.type != float:
            return false
    return true

const ROUNDED_UP -> int:
    var n: int = 1
    inline while n < 1024:
        n = n * 2
    return n

enum Palette: ubyte
    red   = 1
    green = 2
    blue  = 3
const FAVORITE_COLOR: Palette = Palette.red

function favorite_label() -> str:
    inline match FAVORITE_COLOR:
        Palette.red:
            return "warm"
        Palette.green:
            return "cool"
        Palette.blue:
            return "cool"

const DEBUG_RENDER: bool = false

function maybe_debug_draw() -> void:
    inline if DEBUG_RENDER:
        global_counter += 1

# --- inline if with type comparison ---

function type_label[T]() -> str:
    inline if T == int:
        return "int32"
    inline if T == float:
        return "float32"
    return "other"

# --- .type in type position (type-constructor arguments) ---

function particle_field_sizes() -> ptr_uint:
    var total: ptr_uint = 0
    inline for field in fields_of(Particle):
        total += size_of(field.type)
    return total

function color_count() -> int:
    var count: int = 0
    inline for member in members_of(Palette):
        count += 1
    return count

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

const WIDE: type     = int_with_bits[64]
const WIDE_PTR: type = ptr[WIDE]

function comptime_demo() -> int:
    let pow2      = NEXT_POW2_ABOVE_1000
    let hash      = FNV_HASH
    let label     = backend_label()
    let all_float = all_fields_floats()
    let rounded   = ROUNDED_UP
    let fav       = favorite_label()
    let colors    = color_count()
    let sizes     = particle_field_sizes()
    let _label    = label
    let _fav      = fav
    let _sizes    = sizes
    return pow2 + int<-hash + int<-(all_float) + rounded + colors

function type_label_demo() -> int:
    if type_label[int]() == "int32":
        return 1
    return 0

# =============================================================================
# 22  Native vector types
# =============================================================================

extending vec3:
    function squared_len() -> float:
        return this.x * this.x + this.y * this.y + this.z * this.z

function vector_demo() -> float:
    let v2 = zero[vec2]
    let v3 = zero[vec3]
    let v4 = zero[vec4]
    let iv2 = zero[ivec2]
    let iv3 = zero[ivec3]

    let vsum = v3 + v3
    let vdiff = v3 - v3
    let vmul = v3 * v3
    let vneg = -v3
    let vscaled = v3 * 2.0
    let sscaled = 3.0 * v3
    let vdiv = v3 / 2.0
    let isum = iv3 + iv3
    let iscaled = iv3 * 3
    let ineg = -iv3

    let squared = v3.squared_len()
    let dot_val = v3.dot(v3)
    let len_val = v3.length()
    let cross_val = v3.cross(v3)

    let v3_partial = v3.with(x = 99.0)
    let _vp = v3_partial

    return (
        v2.x + v3.x + v4.x + float<-(iv2.x)
        + vsum.x + vdiff.x + vmul.x + vneg.x
        + vscaled.x + sscaled.x + vdiv.x
        + float<-(isum.x) + float<-(iscaled.x) + float<-(ineg.x)
        + squared + dot_val + len_val + cross_val.x
    )

# =============================================================================
# 23  Native matrix types
# =============================================================================

function matrix_demo() -> float:
    let m4 = zero[mat4]
    let m3 = zero[mat3]

    let msum    = m4 + m4
    let mdif    = m4 - m4
    let mscaled = m4 * 2.0
    let mneg    = -m4
    let m4_id   = mat4.identity()

    let _m3  = m3
    let _m4i = m4_id

    return msum.col0.x + mdif.col0.x + mscaled.col0.x + mneg.col0.x + m4_id.col0.x

# =============================================================================
# 24  Native quaternion type
# =============================================================================

function quat_demo() -> float:
    let q = zero[quat]

    let qsum  = q + q
    let qdiff = q - q
    let qmul  = q * q
    let qneg  = -q
    let q_id  = quat.identity()

    let _qd  = qdiff
    let _qm  = qmul
    let _qi  = q_id

    return q.x + q.y + q.z + q.w + qsum.x + qneg.x + q_id.x

# =============================================================================
# 25  SoA (Structure-of-Arrays)
# =============================================================================

struct Point:
    x: float
    y: float
    z: float

function soa_demo() -> float:
    var particles: SoA[Point, 4]
    particles[0].x = 1.0
    particles[0].y = 5.0
    particles[1].x = 2.0
    particles[1].y = 6.0
    particles[2].x = 3.0
    particles[3].x = 4.0
    return particles[0].x + particles[1].x + particles[0].y

# =============================================================================
# 26  emit — compile-time code generation
# =============================================================================

const function generate_helpers() -> void:
    emit function zero_meaning() -> int:
        return 0
    emit function hex_prefix() -> str:
        return "0x"

function emit_demo() -> int:
    let meaning = zero_meaning()
    return meaning

# =============================================================================
# 27  Lifetime-annotated refs (non-owning structs)
# =============================================================================

struct Buffer[@a]:
    data: ref[@a, span[ubyte]]

function buffer_advance(buf: ref[Buffer]) -> void:
    pass

function lifetime_demo() -> void:
    var storage: array[ubyte, 128]
    var sp = span[ubyte](data = ptr_of(storage[0]), len = 128)
    var buf = Buffer(data = ref_of(sp))
    buffer_advance(ref_of(buf))

# =============================================================================
# 28  own[T] — owning heap pointer with auto-deref
# =============================================================================

# --- own[T] struct field, nullable, heap alloc, member access

function create_owned() -> own[int]:
    let p = zero[own[int]]
    return p

function use_owned(p: own[int]) -> int:
    return unsafe: read(p) + 1

# --- own[int]? — nullable owning pointer

function nullable_owned_demo() -> int:
    var p: own[int]? = null
    if p == null:
        return 0
    return 1

# =============================================================================
## 29  struct.with() partial field update
# =============================================================================

function with_demo() -> Vec2:
    let v = Vec2(x = 1.0, y = 2.0)
    return v.with(x = 10.0)

# =============================================================================
## 29  Named arguments
# =============================================================================

function configure(host: str, port: int, debug: bool) -> void:
    pass

function named_args_demo() -> int:
    configure("localhost", port = 8080, debug = false)
    configure(host = "other", port = 3000, debug = true)
    return 1

# =============================================================================
# 31  dyn[InterfaceName] — runtime interface values
# =============================================================================

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
    return s.area()

# --- dyn with generic interface ---

interface Mapper[T]:
    function map(x: T) -> T

struct DoublerMap implements Mapper[int]:
    factor: int

extending DoublerMap:
    function map(x: int) -> int:
        return x * this.factor

function dyn_generic_demo() -> int:
    var d = DoublerMap(factor = 2)
    var m: dyn[Mapper[int]] = adapt[Mapper[int]](ref_of(d))
    return m.map(21)

# =============================================================================
# 32  Tuples — positional, named, destructuring
# =============================================================================

function tuple_demo() -> int:
    let pair  = (42, 7)
    let sum_pos = pair._0 + pair._1

    let point = (x = 10, y = 20)
    let sum_named = point.x + point.y

    let result = get_coords()
    let (a, b) = result
    let sum_dest = a + b

    var v1 = 1
    var v2 = 2
    var swapped = (v2, v1)
    let (left, rite) = swapped
    let ord = left + rite

    var vec = Vec2(x = 1.0, y = 2.0)
    let Vec2(x, y) = vec
    let sum_struct = int<-(x + y)

    return sum_pos + sum_named + sum_dest + ord + sum_struct

# --- tuple match (expression and statement forms) ---

function tuple_match_demo() -> int:
    let t = (42, 7)
    let r1 = match t:
        (42, 7): 100
        _: 0

    # statement form
    var result: int = 0
    match t:
        (42, _):
            result = 200
        _:
            result = -1

    # match on char tuples
    let ch = ('a', 'b')
    let r2 = match ch:
        ('a', 'b'): 1
        _: 0

    return r1 + result + r2

# --- _ discard may repeat in destructure patterns ---

function underscore_repeat_demo() -> int:
    let triple = (1, 2, 3)
    let (_, _, third) = triple
    return third

function get_coords() -> (int, int):
    return (50, 60)

# =============================================================================
# 33  Nested structs
# =============================================================================

function nested_struct_demo() -> float:
    var r: Rectangle
    r.x = 100.0
    r.y = 200.0
    r.top_edge.start = 0.0
    r.top_edge.end = 50.0
    r.left_edge.start = 0.0
    r.left_edge.end = 100.0

    var qualified: Rectangle.Edge
    qualified.start = 1.0
    qualified.end = 2.0
    let _q = qualified

    return r.x + r.y + (r.top_edge.end - r.top_edge.start)

# =============================================================================
# 34  atomic[T]
# =============================================================================

function atomic_demo() -> int:
    var counter: atomic[int]
    counter.store(0)
    let prev = counter.add(1)
    let value = counter.load()
    return int<-(prev) + value

# =============================================================================
# 35  Endian & move_bytes helpers
# =============================================================================

function endian_demo() -> uint:
    let original: uint = 0x01020304
    let swapped = endian.swap_uint(original)
    let network = endian.hton_uint(original)
    let host = endian.ntoh_uint(network)
    return swapped + network + host

function move_bytes_demo() -> void:
    var buf: array[ubyte, 16]
    buf[0] = ubyte<-1
    buf[1] = ubyte<-2
    heap.move_bytes(ptr_of(buf[2]), ptr_of(buf[0]), 2)

# =============================================================================
# 36  Entrypoint
# =============================================================================

function main() -> int:
    var total: int = 0

    total += statements_demo()
    total += expressions_demo(3, 2)
    total += builtins_demo()
    total += generics_demo()
    total += option_methods_demo()
    total += result_methods_demo()
    total += comptime_demo()
    total += emit_demo()
    total += const_func_demo()
    total += proc_demo()
    total += proc_array_capture_demo()
    total += proc_capture_proc_demo()
    total += proc_factory_demo()
    total += proc_higher_order_demo()
    total += proc_struct_demo()
    total += modvar_proc_demo()
    total += fn_struct_demo()
    total += fn_param_return_demo()
    total += fn_to_proc_call_demo()
    total += fn_wrap_in_proc_demo()
    total += nullable_fn_demo()
    total += proc_array_demo()
    total += proc_ref_param_demo()
    total += proc_tuple_demo()
    total += proc_generic_demo()

    total += int<-(vector_demo())
    total += int<-(matrix_demo())
    total += int<-(quat_demo())
    total += int<-(soa_demo())

    unsafe_demo()
    emit_ready()
    schedule_ready_callback()
    fire_updated()
    format_demo()
    heredoc_fmt_demo()
    str_buffer_demo()
    lifetime_demo()
    maybe_debug_draw()

    var npc = NPC.default()
    interface_demo(ref_of(npc))

    total += int<-(with_demo().x) + int<-(with_demo().y)
    total += nullability_demo()
    total += named_args_demo()
    total += int<-(dyn_demo())
    total += tuple_demo()
    total += tuple_match_demo()
    total += underscore_repeat_demo()
    total += int<-(nested_struct_demo())
    total += traced_demo()
    total += atomic_demo()
    total += foreign_demo()
    total += attributes_demo()
    total += custom_iter_demo()
    total += int<-(dyn_generic_demo())
    total += type_label_demo()
    total += member_value_demo()

    total += event_payload_demo()
    total += aio.wait(async_child())
    total += aio.wait(async_demo())

    var dblr = Doubler(value = 0)
    total += apply_converter[Doubler](ref_of(dblr), 3)
    total += module_when_func()

    let _total = total
    return 0
