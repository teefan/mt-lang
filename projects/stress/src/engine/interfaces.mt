## engine/interfaces.mt — interfaces, generic constraints, dyn

# ---------------------------------------------------------------------------
# Core interfaces (self-contained — no imports from engine.types)
# ---------------------------------------------------------------------------

public interface Updatable:
    editable function move(dx: double, dy: double) -> void
    function pos_x() -> double
    function pos_y() -> double

public interface Damageable:
    editable function take_damage(amount: int) -> void
    function is_alive() -> bool

public interface Identifiable:
    function id_value() -> ulong

# ---------------------------------------------------------------------------
# Generic interface with type parameter
# ---------------------------------------------------------------------------

public interface Component[T]:
    function data() -> T
    editable function set_data(value: T) -> void
    static function kind() -> str

# ---------------------------------------------------------------------------
# dyn usage: runtime-polymorphic interface dispatch
# ---------------------------------------------------------------------------

public function describe_entity(e: dyn[Identifiable]) -> str:
    return "entity_desc"

public function kill_if_alive(e: dyn[Damageable]) -> void:
    if e.is_alive():
        e.take_damage(999)

# ---------------------------------------------------------------------------
# Generic functions with interface constraints
# ---------------------------------------------------------------------------

public function move_both[T implements Updatable and Damageable](
    target: ref[T], dx: double, dy: double,
) -> void:
    if target.is_alive():
        target.move(dx, dy)

public function heal_to_max[T implements Damageable](target: ref[T], max_hp: int) -> void:
    target.take_damage(-max_hp)

# ---------------------------------------------------------------------------
# Generic function relying on associated default[T]
# ---------------------------------------------------------------------------

public function make_entity[T](id: ulong) -> T:
    var e = default[T]
    return e
