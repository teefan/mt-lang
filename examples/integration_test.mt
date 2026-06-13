## Comprehensive integration test for generic interfaces, extending blocks,
## lifetime-annotated refs, and struct pattern matching.
##
## This module exercises cross-cutting combinations of recently-built features
## to verify they compose correctly in real-world-like patterns.

# module demo.integration

# ============================================================================
# 1  Generic Interfaces — declaration, implementation, constraint-based generics
# ============================================================================

interface Mapper[T]:
    function map(x: T) -> T

interface Reducer[T, U]:
    function reduce(a: T, b: T) -> U
    function initial() -> U

interface Describable:
    function describe() -> str
    static function tag() -> str

# --- implementor with single generic interface
struct Doubler implements Mapper[int]:
    factor: int

extending Doubler:
    function map(x: int) -> int:
        return x * this.factor

    static function identity() -> Doubler:
        return Doubler(factor = 1)

# --- implementor with multiple interfaces (generic + non-generic)
struct Summarizer implements Reducer[int, str], Describable:
    label: str

extending Summarizer:
    function reduce(a: int, b: int) -> str:
        return this.label

    function initial() -> str:
        return this.label

    function describe() -> str:
        return this.label

    static function tag() -> str:
        return "summarizer"

# --- constrained generic function with generic interface
function apply_mapper[T implements Mapper[int]](m: ref[T], v: int) -> int:
    return m.map(v)

# --- constrained generic with multiple type params
function merge_results[T implements Reducer[int, str]](r: ref[T], x: int, y: int) -> str:
    return r.reduce(x, y)

# --- constrained generic with generic + non-generic interfaces
function describe_if[T implements Describable](value: ref[T]) -> str:
    return value.describe()

# ============================================================================
# 2  Extending blocks — editable, static, generic method interactions
# ============================================================================

struct Counter:
    value: int
    label: str

extending Counter:
    editable function increment() -> void:
        this.value += 1

    editable function add(amount: int) -> void:
        this.value += amount

    function read() -> int:
        return this.value

    function labeled_read() -> str:
        return this.label

    static function create(label: str) -> Counter:
        return Counter(value = 0, label = label)

    # generic method
    editable function set_to[T](source: T) -> void:
        this.value = int<-(source)

# --- generic method usage
function counter_demo() -> int:
    var c = Counter.create("demo")
    c.increment()
    c.increment()
    c.add(5)
    return c.read()

# ============================================================================
# 3  Lifetime-annotated refs — non-owning structs, composition, params
# ============================================================================

struct SliceView[@a]:
    data: ref[@a, span[ubyte]]
    offset: ptr_uint
    length: ptr_uint

struct AnnotatedSlice[@a]:
    data: ref[@a, span[ubyte]]
    note: str

# --- function taking ref to non-owning struct
function slice_first_byte(view: ref[SliceView]) -> ubyte:
    unsafe:
        return view.data.data[view.offset]

# --- function with non-owning struct as ref param
function advance_slice(view: ref[SliceView], by: ptr_uint) -> void:
    view.offset += by
    view.length -= by

# --- composition: outer struct propagating lifetime through type argument
struct FramedSlice[@a]:
    inner: SliceView[@a]
    frame_start: ubyte
    frame_end: ubyte

# --- lifetime struct construction and usage
function lifetime_compose_demo() -> bool:
    var storage: array[ubyte, 64]
    var sp = span[ubyte](data = ptr_of(storage[0]), len = 64)
    var view = SliceView(data = ref_of(sp), offset = 0, length = 32)
    var b = slice_first_byte(ref_of(view))
    return b == 0

# ============================================================================
# 4  Struct Pattern Matching — guards, bindings, equality, mixed as-bindings
# ============================================================================

enum EntityKind: ubyte
    player = 1
    enemy = 2
    item = 3

variant Entity:
    player(hp: int, armor: int, active: bool)
    enemy(hp: int, kind: int, boss: bool)
    item(id: int, quantity: int)
    nothing

# --- struct pattern with guards and bindings
function handle_entity(entity: Entity) -> int:
    match entity:
        Entity.player(hp > 50, armor, active):
            if active and armor > 10:
                return 1
            return 0
        Entity.player(active):
            if active:
                return 2
            return 0
        Entity.enemy(boss = true):
            return 100
        Entity.enemy as e:
            if e.hp <= 0:
                return 0
            return 10
        Entity.item(id, quantity):
            return quantity
        Entity.nothing:
            return 0
        _:
            return -1

# --- struct pattern with multiple bindings and guards (exercised but not called from main)

# --- struct pattern with equality guards
function count_bosses(entities: array[Entity, 4]) -> int:
    var count: int = 0
    for entity in entities:
        match entity:
            Entity.enemy(boss = true):
                count += 1
            _:
                pass
    return count

# --- struct pattern with nested as-bindings + struct pattern in same match
variant Event:
    click(x: int, y: int)
    key(code: int, pressed: bool)
    idle(ms: int)

# handle_event exercised in main via side effects only (format strings can't escape as str)
function handle_event(ev: Event) -> int:
    match ev:
        Event.click(x, y):
            return x + y
        Event.key(code = 27):
            return -1
        Event.key as k:
            return k.code
        Event.idle(ms):
            return int<-(ms)
        _:
            return 0

# --- integer match with wildcard
function classify_entity(id: int) -> int:
    match id:
        1:
            return 100
        2:
            return 200
        3:
            return 300
        _:
            return -1

# ============================================================================
# 5  Cross-cutting — All features combined
# ============================================================================

# combine generic interface with extending
interface Identifiable:
    function id() -> str
    static function kind() -> str

struct Indexed[T] implements Identifiable:
    value: T
    index: ptr_uint

extending Indexed[T]:
    function id() -> str:
        return "indexed"

    static function kind() -> str:
        return "indexed"

# --- lifetime struct implementing a generic interface constraint
function identity_of[T implements Identifiable](item: ref[T]) -> str:
    return item.id()

# ============================================================================
# 6  dyn[InterfaceName] — runtime interface values
# ============================================================================

interface Measurable:
    function measure() -> float

struct MeasurableCounter implements Measurable:
    value: int

extending MeasurableCounter:
    function measure() -> float:
        return float<-(this.value)

function dyn_adapt_demo() -> float:
    var c = MeasurableCounter(value = 42)
    var handler: dyn[Measurable] = adapt[Measurable](ref_of(c))
    return handler.measure()

# ============================================================================
# 7  Entrypoint
# ============================================================================

function main() -> int:
    var total: int = 0

    # generic interface
    var dbl = Doubler.identity()
    total += apply_mapper[Doubler](ref_of(dbl), 7)

    var sumr = Summarizer(label = "test")
    let reduced = merge_results[Summarizer](ref_of(sumr), 3, 4)
    let described = describe_if[Summarizer](ref_of(sumr))
    let _r = reduced
    let _d = described

    # extending
    total += counter_demo()

    # lifetime
    let lc = lifetime_compose_demo()
    if lc:
        total += 1

    # struct pattern matching
    let player_entity = Entity.player(hp = 100, armor = 20, active = true)
    total += handle_entity(player_entity)

    # mixed as-binding + struct patterns in match
    let click_event = Event.click(x = 10, y = 20)
    total += handle_event(click_event)

    let key_event = Event.key(code = 27, pressed = true)
    total += handle_event(key_event)

    let idle_event = Event.idle(ms = 500)
    total += handle_event(idle_event)

    total += classify_entity(2)

    # cross-cutting
    var idx = Indexed[int](value = 42, index = 1)
    let id_str = identity_of[Indexed[int]](ref_of(idx))
    let _id_str = id_str

    total += int<-(dyn_adapt_demo())

    return total

