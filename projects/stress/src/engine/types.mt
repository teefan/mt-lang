## engine/types.mt — comprehensive type declarations

import engine.interfaces as ifaces

# ---------------------------------------------------------------------------
# Primitive type aliases
# ---------------------------------------------------------------------------

public type EntityId = ulong
public type Seconds = double
public type Callback = proc(value: int) -> int
public type Predicate = proc(item: EntityId) -> bool

# ---------------------------------------------------------------------------
# Attribute declarations (for struct, field, callable targets)
# ---------------------------------------------------------------------------

attribute[struct] component(tag: str)
attribute[field] hot
attribute[callable] debug_name(name: str)

# ---------------------------------------------------------------------------
# Enum with explicit backing type
# ---------------------------------------------------------------------------

public enum EntityKind: ubyte
    player = 1
    enemy = 2
    item = 3
    projectile = 4

# ---------------------------------------------------------------------------
# Flags with composite aliases
# ---------------------------------------------------------------------------

public flags CollisionMask: uint
    player = 1 << 0
    enemy = 1 << 1
    wall = 1 << 2
    pickup = 1 << 3
    player_enemy = CollisionMask.player | CollisionMask.enemy
    all_solid = CollisionMask.player | CollisionMask.enemy | CollisionMask.wall

# ---------------------------------------------------------------------------
# Generic variant (used as Option/Result substitute in custom code)
# ---------------------------------------------------------------------------

public variant Maybe[T]:
    some(value: T)
    none

public variant Outcome[T, E]:
    ok(value: T)
    err(error: E)

# ---------------------------------------------------------------------------
# Custom error enum for Outcome
# ---------------------------------------------------------------------------

public enum EngineError: ubyte
    out_of_bounds = 1
    invalid_entity = 2
    resource_missing = 3

# ---------------------------------------------------------------------------
# Struct with packed and align attributes
# ---------------------------------------------------------------------------

@[packed]
public struct Header16:
    magic: ushort
    version: ubyte
    field_flags: ubyte

@[align(16)]
public struct AlignedBlock:
    data: array[ubyte, 64]

# ---------------------------------------------------------------------------
# Core data structs
# ---------------------------------------------------------------------------

public struct Transform:
    x: double
    y: double
    rotation: double

public struct Health:
    current: int
    max: int

public struct Damage:
    amount: int
    kind: EntityKind

# ---------------------------------------------------------------------------
# Type implementing interfaces
# ---------------------------------------------------------------------------

@[component("player_entity")]
public struct Player implements ifaces.Updatable, ifaces.Identifiable:
    id: EntityId
    transform: Transform
    health: Health
    name: str_buffer[32]
    active_callbacks: array[Callback, 4]

@[component("enemy_entity")]
public struct Enemy implements ifaces.Updatable, ifaces.Damageable:
    id: EntityId
    transform: Transform
    health: Health
    speed: double
    ai_state: int

# ---------------------------------------------------------------------------
# Extending Player with methods
# ---------------------------------------------------------------------------

extending Player:
    public function id_value() -> ulong:
        return this.id

    public editable function move(dx: double, dy: double) -> void:
        this.transform.x += dx
        this.transform.y += dy

    public function pos_x() -> double:
        return this.transform.x

    public function pos_y() -> double:
        return this.transform.y

    public editable function add_callback(c: Callback) -> void:
        this.active_callbacks[0] = c

    public static function make(id: EntityId) -> Player:
        var p = Player(
            id = id,
            transform = Transform(x = 0.0, y = 0.0, rotation = 0.0),
            health = Health(current = 100, max = 100),
        )
        p.name.assign("unknown")
        return p

# ---------------------------------------------------------------------------
# Extending Enemy with methods
# ---------------------------------------------------------------------------

extending Enemy:
    public function id_value() -> ulong:
        return this.id

    public editable function move(dx: double, dy: double) -> void:
        this.transform.x += dx
        this.transform.y += dy

    public function pos_x() -> double:
        return this.transform.x

    public function pos_y() -> double:
        return this.transform.y

    public editable function take_damage(amount: int) -> void:
        this.health.current -= amount
        if this.health.current < 0:
            this.health.current = 0

    public function is_alive() -> bool:
        return this.health.current > 0

    public function is_dead() -> bool:
        return not this.is_alive()

    public static function make(id: EntityId) -> Enemy:
        return Enemy(
            id = id,
            transform = Transform(x = 0.0, y = 0.0, rotation = 0.0),
            health = Health(current = 50, max = 50),
            speed = 1.0,
            ai_state = 0,
        )

# ---------------------------------------------------------------------------
# Union type for low-level data reinterpreting
# ---------------------------------------------------------------------------

union IdOrPtr:
    id: EntityId
    pointer: ptr[void]

# ---------------------------------------------------------------------------
# Opaque handle type
# ---------------------------------------------------------------------------

opaque RenderHandle

# ---------------------------------------------------------------------------
# Velocity struct for SoA
# ---------------------------------------------------------------------------

struct Velocity:
    dx: double
    dy: double

# ---------------------------------------------------------------------------
# Vec2 struct for with() demo and value semantics
# ---------------------------------------------------------------------------

public struct Vec2:
    x: double
    y: double

# ---------------------------------------------------------------------------
# Deprecated function
# ---------------------------------------------------------------------------

@[deprecated("use Transform instead")]
public function legacy_position(x: double, y: double) -> Transform:
    return Transform(x = x, y = y, rotation = 0.0)
