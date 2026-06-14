## engine/systems.mt — ECS-like systems using generics, events, proc values

import engine.types as types
import engine.interfaces as ifaces

# ---------------------------------------------------------------------------
# Events with complex payload types
# ---------------------------------------------------------------------------

public event entity_spawned[16](types.EntityId)
public event entity_killed[16](types.EntityId)
public event damage_applied[8](types.Damage)
public event system_tick[4]

# ---------------------------------------------------------------------------
# Entity store
# ---------------------------------------------------------------------------

public struct EntityStore:
    next_id: types.EntityId
    player_count: int
    enemy_count: int

extending EntityStore:
    public static function default() -> EntityStore:
        return EntityStore(next_id = 0, player_count = 0, enemy_count = 0)

    public editable function spawn_player() -> types.Player:
        let id = this.next_id
        this.next_id += 1
        this.player_count += 1
        var p = types.Player(
            id = id,
            transform = types.Transform(x = 0.0, y = 0.0, rotation = 0.0),
            health = types.Health(current = 100, max = 100),
        )
        entity_spawned.emit(id)
        return p

    public editable function spawn_enemy() -> types.Enemy:
        let id = this.next_id
        this.next_id += 1
        this.enemy_count += 1
        var e = types.Enemy(
            id = id,
            transform = types.Transform(x = 0.0, y = 0.0, rotation = 0.0),
            health = types.Health(current = 50, max = 50),
            speed = 1.0,
            ai_state = 0,
        )
        entity_spawned.emit(id)
        return e

# ---------------------------------------------------------------------------
# Movement system
# ---------------------------------------------------------------------------

public function move_system[T implements ifaces.Updatable](entity: ref[T], dt: double) -> void:
    entity.move(dt * 60.0, dt * 60.0)

# ---------------------------------------------------------------------------
# Damage system
# ---------------------------------------------------------------------------

public function damage_system[T implements ifaces.Damageable](
    entity: ref[T], amount: int, source: types.EntityKind,
) -> void:
    if not entity.is_alive():
        return
    entity.take_damage(amount)
    damage_applied.emit(types.Damage(amount = amount, kind = source))
    if not entity.is_alive():
        entity_killed.emit(entity.id_value())

# ---------------------------------------------------------------------------
# Entity lookup by predicate proc
# ---------------------------------------------------------------------------

public function find_entity[T](
    entities: span[T],
    predicate: proc(e: ref[T]) -> bool,
) -> ptr[T]?:
    var i: int = 0
    while i < int<-(entities.len):
        if predicate(ref_of(entities[i])):
            return ptr_of(entities[i])
        i += 1
    return null

# ---------------------------------------------------------------------------
# Bulk processing with proc pipeline
# ---------------------------------------------------------------------------

public function process_entities[T](
    entities: span[T],
    processor: proc(e: ref[T]) -> void,
) -> void:
    var i: int = 0
    while i < int<-(entities.len):
        processor(ref_of(entities[i]))
        i += 1

# ---------------------------------------------------------------------------
# Custom iterable protocol
# ---------------------------------------------------------------------------

struct Counter:
    limit: int

extending Counter:
    public function iter() -> Counter:
        return Counter(limit = this.limit)

    public editable function next() -> ptr[int]?:
        if this.limit > 0:
            this.limit -= 1
            return ptr_of(this.limit)
        return null

public function structural_iterable_demo() -> int:
    var c = Counter(limit = 5)
    var total: int = 0
    for value in c:
        total += unsafe: read(value)
    return total

# ---------------------------------------------------------------------------
# Event subscription with closure listeners
# ---------------------------------------------------------------------------

public function setup_event_listeners(store: ref[EntityStore]) -> void:
    let _eh = entity_spawned.subscribe(on_spawn)
    let _oh = entity_spawned.subscribe_once(on_spawn_once)
    let _dh = damage_applied.subscribe(on_damage)

public function on_spawn(id: types.EntityId) -> void:
    pass

public function on_spawn_once(id: types.EntityId) -> void:
    pass

public function on_damage(d: types.Damage) -> void:
    pass

public function unsubscribe_listener(sub: ptr[void]) -> void:
    pass

# ---------------------------------------------------------------------------
# Generic struct instantiated with proc type
# ---------------------------------------------------------------------------

public struct PipelineStep[T]:
    name: str
    handler: proc(input: T) -> types.Outcome[T, types.EngineError]

public function run_pipeline[T](
    input: T, steps: span[PipelineStep[T]],
) -> types.Outcome[T, types.EngineError]:
    var current = types.Outcome[T, types.EngineError].ok(value = input)
    var i: int = 0
    while i < int<-(steps.len):
        let step = steps[i]
        match current:
            types.Outcome[T, types.EngineError].ok as v:
                current = step.handler(v.value)
            types.Outcome[T, types.EngineError].err:
                return current
        i += 1
    return current
