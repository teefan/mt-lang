## stress/main.mt — language stress test entry point

import std.async as aio
import engine.types as types
import engine.interfaces as ifaces
import engine.closures as closures
import engine.systems as systems
import engine.compile as compile
import engine.math as math
import engine.async_tasks as atasks
import engine.guards as guards

# ---------------------------------------------------------------------------
# Section A: Type system stress (all declaration kinds exercised)
# ---------------------------------------------------------------------------

function type_system_stress() -> int:
    # enum usage
    var kind = types.EntityKind.player

    # flags usage
    var mask = types.CollisionMask.player | types.CollisionMask.wall
    var combined = mask & types.CollisionMask.all_solid

    # generic variant
    var maybe_val = types.Maybe[int].some(value = 42)
    var none_val = types.Maybe[int].none

    # Outcome (custom Result)
    var ok_val = types.Outcome[int, types.EngineError].ok(value = 7)
    var err_val = types.Outcome[int, types.EngineError].err(error = types.EngineError.invalid_entity)

    # attribute reflection
    var header_aligned = size_of(types.Header16)
    var _ha = header_aligned

    var score: int = 0

    match maybe_val:
        types.Maybe[int].some as s:
            score += s.value
        types.Maybe[int].none:
            score += 0

    match ok_val:
        types.Outcome[int, types.EngineError].ok as v:
            score += v.value
        types.Outcome[int, types.EngineError].err as e:
            score += int<-(e.error)

    return score + int<-(kind) + int<-(mask) + int<-(combined)

# ---------------------------------------------------------------------------
# Section B: Interface and dyn stress
# ---------------------------------------------------------------------------

function interface_stress() -> int:
    var player = types.Player(
        id = 0,
        transform = types.Transform(x = 0.0, y = 0.0, rotation = 0.0),
        health = types.Health(current = 100, max = 100),
    )
    var enemy = types.Enemy(
        id = 1,
        transform = types.Transform(x = 0.0, y = 0.0, rotation = 0.0),
        health = types.Health(current = 50, max = 50),
        speed = 1.0,
        ai_state = 0,
    )

    # Interface methods via value receivers
    player.move(1.0, 2.0)
    enemy.take_damage(10)
    let enemy_alive = enemy.is_alive()

    # Static methods — none needed
    let max_enemy = types.Enemy(
        id = 2,
        transform = types.Transform(x = 0.0, y = 0.0, rotation = 0.0),
        health = types.Health(current = 50, max = 50),
        speed = 1.0,
        ai_state = 0,
    )

    # Generic constrained function (Updatable only)
    systems.move_system[types.Player](ref_of(player), 0.5)

    # dyn dispatch (fat pointer interface values)
    let player_dyn: dyn[ifaces.Identifiable] = adapt[ifaces.Identifiable](ref_of(player))
    let enemy_dyn: dyn[ifaces.Damageable] = adapt[ifaces.Damageable](ref_of(enemy))
    let desc = ifaces.describe_entity(player_dyn)
    ifaces.kill_if_alive(enemy_dyn)

    var score: int = 0
    if enemy_alive:
        score += 1
    let _desc = desc
    let _max = max_enemy

    return score

# ---------------------------------------------------------------------------
# Section C: Closure stress (proc captures of all kinds)
# ---------------------------------------------------------------------------

function closure_stress() -> int:
    var total: int = 0

    total += closures.scalar_capture_demo()
    total += closures.array_capture_demo()
    total += int<-(closures.multi_capture_demo())
    total += closures.proc_capture_proc_demo()
    total += closures.proc_capture_deep_demo()
    total += closures.mixed_capture_demo()
    total += closures.proc_struct_demo()
    total += closures.proc_array_demo(1)
    total += closures.proc_array_from_factory_demo()
    total += int<-(closures.listener_demo(10))
    total += closures.variant_proc_demo(0)
    total += closures.function_to_proc_coercion_demo()
    total += closures.void_proc_demo(3)
    total += closures.proc_in_match_demo(0)

    # Factory functions
    let scaler = closures.make_scaler(2.5)
    let _s = scaler(10.0)
    let adder = closures.make_curried_adder(5)
    let _a = adder(3)

    return total

# ---------------------------------------------------------------------------
# Section D: Systems / ECS stress
# ---------------------------------------------------------------------------

function systems_stress() -> int:
    var store = systems.EntityStore.default()

    # Spawn entities
    var player = store.spawn_player()
    var enemy = store.spawn_enemy()

    # Movement system
    systems.move_system[types.Player](ref_of(player), 0.016)
    systems.move_system[types.Enemy](ref_of(enemy), 0.016)

    # Damage system
    systems.damage_system[types.Enemy](ref_of(enemy), 25, types.EntityKind.player)

    # Custom iterable protocol
    var iter_total = systems.structural_iterable_demo()

    # Event subscription with closure listeners
    systems.setup_event_listeners(ref_of(store))

    # Pipeline with proc handler
    let handler_proc = proc(input: int) -> types.Outcome[int, types.EngineError]:
        return types.Outcome[int, types.EngineError].ok(value = input * 2)
    var steps: array[systems.PipelineStep[int], 1]
    steps[0] = systems.PipelineStep[int](
        name = "double",
        handler = handler_proc,
    )
    let result = systems.run_pipeline[int](21, steps.as_span())
    var pipe_val: int = 0
    match result:
        types.Outcome[int, types.EngineError].ok as v:
            pipe_val = v.value
        types.Outcome[int, types.EngineError].err:
            pipe_val = 0

    return int<-(player.id) + int<-(enemy.id) + iter_total + pipe_val

# ---------------------------------------------------------------------------
# Section E: Compile-time stress
# ---------------------------------------------------------------------------

function compile_time_stress() -> int:
    var total: int = 0

    total += compile.FIB_10
    total += compile.POW2_ABOVE_500
    total += int<-(compile.MAGIC_HASH)
    total += int<-(compile.all_transform_fields_are_double())
    total += compile.entity_kind_count()

    let platform = compile.platform_name()
    let mode = compile.mode_label()
    let _platform = platform
    let _mode = mode

    # Verify compile-time assertions
    let ok = compile.verify_sizes()
    let _ok = ok

    return total

# ---------------------------------------------------------------------------
# Section F: Math / native types stress
# ---------------------------------------------------------------------------

function math_stress() -> int:
    var total: double = 0.0
    total += double<-(math.vector_math_demo())
    total += double<-(math.matrix_math_demo())
    total += double<-(math.quat_math_demo())
    total += double<-(math.soa_math_demo())
    let _s = math.str_buffer_math_demo()
    let _f = math.format_strings_demo(255, 3.14159)
    let _h = math.heredoc_demo()
    return int<-(total)

# ---------------------------------------------------------------------------
# Section G: Async stress
# ---------------------------------------------------------------------------

function async_stress() -> int:
    var total: int = 0
    total += aio.wait(atasks.task_pipeline())
    total += aio.wait(atasks.task_with_defer())
    total += aio.wait(atasks.task_with_procs())
    return total

# ---------------------------------------------------------------------------
# Section H: Lifetime / unsafe / pointer stress
# ---------------------------------------------------------------------------

function unsafe_stress() -> int:
    var value = 42
    let handle = ref_of(value)
    read(handle) = 99

    let raw_p = ptr_of(handle)
    unsafe:
        raw_p[0] = 100
        let deref = read(raw_p)

    # reinterpret
    let bits = unsafe: reinterpret[uint](value)
    let _bits = bits

    # pointer arithmetic
    let next_p = unsafe: raw_p + 1
    let _next = next_p

    # T<-value cast
    let as_long = long<-value
    let as_double = double<-value

    let _as_long = as_long
    let _as_double = as_double

    return value

# ---------------------------------------------------------------------------
# Section I: Var arg, with, tuple destructuring stress
# ---------------------------------------------------------------------------

function syntax_sugar_stress() -> int:
    # struct.with()
    var v = types.Vec2(x = 1.0, y = 2.0)
    let updated = v.with(x = 10.0)

    # tuple destructuring
    let pair = (42, 7)
    let (a, b) = pair
    let named = (x = 10, y = 20)
    let (nx, ny) = named

    # struct destructuring (access fields directly)
    var t = types.Transform(x = 5.0, y = 10.0, rotation = 0.0)
    let sx = t.x
    let sy = t.y
    let sr = t.rotation

    var total = int<-(updated.x) + int<-(updated.y)
    total += a + b + nx + ny
    total += int<-(sx) + int<-(sy) + int<-(sr)

    return total

# ---------------------------------------------------------------------------
# Section J: Guards and error handling
# ---------------------------------------------------------------------------

function guard_stress() -> int:
    var total: int = 0
    total += guards.guard_nullable_demo()
    total += guards.guard_else_as_error_demo()
    total += guards.guard_discard_demo()
    total += guards.get_recoverable_demo(2)
    var _v = guards.var_else_demo()
    return total

# ---------------------------------------------------------------------------
# Section K: Control flow — break, continue, range-for, parallel-for, defer expr
# ---------------------------------------------------------------------------

function control_flow_stress() -> int:
    var total: int = 0

    # break / continue
    var i: int = 0
    while i < 10:
        i += 1
        if i == 3:
            continue
        if i == 7:
            break
        total += 1

    # range-based for
    for j in 0..5:
        total += j

    # parallel for
    var a: array[int, 3]
    var b: array[int, 3]
    a[0] = 1
    a[1] = 2
    a[2] = 3
    b[0] = 10
    b[1] = 20
    b[2] = 30
    for left, right in a, b:
        total += left + right

    # defer block form
    var tracked: int = 0
    defer:
        tracked += 1
    defer:
        tracked += 2
    tracked += 10

    return total

# ---------------------------------------------------------------------------
# Section L: Built-in surface — fatal, const_ptr_of, zero
# ---------------------------------------------------------------------------

function builtins_missing_stress() -> int:
    # fatal in unreachable branch (exercises compiler recognition)
    if false:
        fatal(c"this should never fire")

    # const_ptr_of
    var v: int = 42
    let cp = const_ptr_of(v)

    # zero[T] as expression
    var zv = zero[int]

    var _cp = cp
    var _zv = zv

    return 0

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

function main() -> int:
    var total: int = 0

    total += type_system_stress()
    total += interface_stress()
    total += closure_stress()
    total += systems_stress()
    total += compile_time_stress()
    total += math_stress()
    total += async_stress()
    total += unsafe_stress()
    total += syntax_sugar_stress()
    total += guard_stress()
    total += control_flow_stress()
    total += builtins_missing_stress()

    return total
