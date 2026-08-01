## HTN planner tests.
## Run via `mtc test test/mt/`.

import std.testing as t
import std.htn as htn


# ── simple move/collect domain ──

struct World:
    at: str
    has_key: bool
    door_open: bool
    has_treasure: bool

struct Context:
    dummy: int


function always(_context: ptr[Context], _world: World) -> bool:
    return true


function at_door(_context: ptr[Context], world: World) -> bool:
    return world.at == "door"


function at_treasure(_context: ptr[Context], world: World) -> bool:
    return world.at == "treasure"


function move_to_door(_context: ptr[Context], _world: World) -> World:
    return World(at = "door", has_key = _world.has_key, door_open = _world.door_open, has_treasure = _world.has_treasure)


function move_to_treasure(_context: ptr[Context], _world: World) -> World:
    return World(at = "treasure", has_key = _world.has_key, door_open = _world.door_open, has_treasure = _world.has_treasure)


function open_door(_context: ptr[Context], _world: World) -> World:
    return World(at = _world.at, has_key = _world.has_key, door_open = true, has_treasure = _world.has_treasure)


function take_treasure(_context: ptr[Context], _world: World) -> World:
    return World(at = _world.at, has_key = _world.has_key, door_open = _world.door_open, has_treasure = true)


function build_collect_domain() -> htn.HtnPlanner[World, Context]:
    var planner = htn.HtnPlanner[World, Context].create()

    planner.add_operator(htn.HtnOperator[World, Context].create("move_to_door", always, move_to_door))
    planner.add_operator(htn.HtnOperator[World, Context].create("move_to_treasure", always, move_to_treasure))
    planner.add_operator(htn.HtnOperator[World, Context].create("open_door", always, open_door))
    planner.add_operator(htn.HtnOperator[World, Context].create("take_treasure", at_treasure, take_treasure))

    var door_method = htn.HtnMethod[World, Context].create("open_door_seq", "reach_door_and_open", at_door)
    door_method.add_subtask("open_door")
    planner.add_method(door_method)

    var collect_method = htn.HtnMethod[World, Context].create("collect_seq", "collect_treasure", always)
    collect_method.add_subtask("move_to_door")
    collect_method.add_subtask("open_door")
    collect_method.add_subtask("move_to_treasure")
    collect_method.add_subtask("take_treasure")
    planner.add_method(collect_method)

    return planner


@[test]
function test_htn_primitive_success() -> t.Check:
    var planner = build_collect_domain()
    defer: planner.release()

    var ctx = Context(dummy = 0)
    var world = World(at = "home", has_key = false, door_open = false, has_treasure = false)
    var r = planner.plan(ptr_of(ctx), world, "move_to_door")
    defer: r.release()

    t.expect(r.status == htn.HtnStatus.success, "primitive task succeeds")?
    t.expect_true(r.has_plan())?

    return t.ok()


@[test]
function test_htn_primitive_fails_precondition() -> t.Check:
    var planner = build_collect_domain()
    defer: planner.release()

    var ctx = Context(dummy = 0)
    var world = World(at = "home", has_key = false, door_open = false, has_treasure = false)
    var r = planner.plan(ptr_of(ctx), world, "take_treasure")
    defer: r.release()

    t.expect(r.status == htn.HtnStatus.failure, "primitive fails precondition")?
    t.expect_false(r.has_plan())?

    return t.ok()


@[test]
function test_htn_compound_decomposition() -> t.Check:
    var planner = build_collect_domain()
    defer: planner.release()

    var ctx = Context(dummy = 0)
    var world = World(at = "home", has_key = false, door_open = false, has_treasure = false)
    var r = planner.plan(ptr_of(ctx), world, "collect_treasure")
    defer: r.release()

    t.expect(r.status == htn.HtnStatus.success, "compound task succeeds")?
    t.expect_true(r.has_plan())?

    match r.plan:
        Option.none:
            t.fail("expected plan")?
        Option.some as payload:
            let plan = payload.value
            t.expect(plan.step_count() > 0, "plan has steps")?
            t.expect(plan.final_world.has_treasure, "final world has treasure")?

    return t.ok()


@[test]
function test_htn_unknown_task() -> t.Check:
    var planner = build_collect_domain()
    defer: planner.release()

    var ctx = Context(dummy = 0)
    var world = World(at = "home", has_key = false, door_open = false, has_treasure = false)
    var r = planner.plan(ptr_of(ctx), world, "nonexistent_task")
    defer: r.release()

    t.expect(r.status == htn.HtnStatus.failure, "unknown task fails")?
    t.expect_false(r.has_plan())?

    return t.ok()


@[test]
function test_htn_max_depth_exceeded() -> t.Check:
    var planner = build_collect_domain()
    defer: planner.release()
    planner.set_max_depth(1)

    var ctx = Context(dummy = 0)
    var world = World(at = "home", has_key = false, door_open = false, has_treasure = false)
    var r = planner.plan(ptr_of(ctx), world, "collect_treasure")
    defer: r.release()

    t.expect(r.status == htn.HtnStatus.max_depth, "depth limit exceeded")?
    t.expect_false(r.has_plan())?

    return t.ok()
