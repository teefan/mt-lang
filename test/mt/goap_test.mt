# In-language tests for std.goap (migrated from
# test/std/std_goap_test.rb, run by `mtc test`).

import std.testing as t
import std.goap as goap
import std.str as str_mod

enum Goal: ubyte
    craft_item = 0

struct World:
    at_resource: bool
    at_workbench: bool
    has_resource: bool
    item_crafted: bool

struct Context:
    unused: int


function is_goal(context: ptr[Context], world: World, goal: Goal) -> bool:
    return world.item_crafted


function worlds_equal(left: World, right: World) -> bool:
    if left.at_resource != right.at_resource:
        return false
    if left.at_workbench != right.at_workbench:
        return false
    if left.has_resource != right.has_resource:
        return false
    if left.item_crafted != right.item_crafted:
        return false
    return true


function heuristic(context: ptr[Context], world: World, goal: Goal) -> float:
    var score: float = 0.0
    if not world.has_resource:
        score += 1.0
    if not world.at_workbench:
        score += 1.0
    if not world.item_crafted:
        score += 1.0
    return score


function can_move_to_resource(context: ptr[Context], world: World) -> bool:
    return not world.at_resource


function move_to_resource(context: ptr[Context], world: World) -> World:
    var next = world
    next.at_resource = true
    next.at_workbench = false
    return next


function move_cost(context: ptr[Context], world: World) -> float:
    return 1.0


function can_gather(context: ptr[Context], world: World) -> bool:
    return world.at_resource and not world.has_resource


function gather_resources(context: ptr[Context], world: World) -> World:
    var next = world
    next.has_resource = true
    return next


function gather_cost(context: ptr[Context], world: World) -> float:
    return 2.0


function can_move_to_workbench(context: ptr[Context], world: World) -> bool:
    return not world.at_workbench


function move_to_workbench(context: ptr[Context], world: World) -> World:
    var next = world
    next.at_workbench = true
    next.at_resource = false
    return next


function can_craft(context: ptr[Context], world: World) -> bool:
    return world.at_workbench and world.has_resource and not world.item_crafted


function craft(context: ptr[Context], world: World) -> World:
    var next = world
    next.item_crafted = true
    return next


function craft_cost(context: ptr[Context], world: World) -> float:
    return 2.0


function can_buy(context: ptr[Context], world: World) -> bool:
    return not world.item_crafted


function buy_shortcut(context: ptr[Context], world: World) -> World:
    var next = world
    next.item_crafted = true
    return next


function expensive_cost(context: ptr[Context], world: World) -> float:
    return 20.0


@[test]
function test_low_cost_goap_plan() -> t.Check:
    var planner = goap.Planner[World, Goal, Context].create(is_goal, heuristic, worlds_equal)
    defer planner.release()

    planner.add_action(goap.Action[World, Context].create("move_to_resource", can_move_to_resource, move_to_resource, move_cost))
    planner.add_action(goap.Action[World, Context].create("gather_resources", can_gather, gather_resources, gather_cost))
    planner.add_action(goap.Action[World, Context].create("move_to_workbench", can_move_to_workbench, move_to_workbench, move_cost))
    planner.add_action(goap.Action[World, Context].create("craft", can_craft, craft, craft_cost))
    planner.add_action(goap.Action[World, Context].create("buy_shortcut", can_buy, buy_shortcut, expensive_cost))

    t.expect(planner.action_count() == 5, "5 actions")?

    var context = Context(unused = 0)
    let initial_world = World(
        at_resource = false,
        at_workbench = false,
        has_resource = false,
        item_crafted = false,
    )

    var result = planner.plan(context, initial_world, Goal.craft_item)
    defer result.release()

    t.expect(result.status == goap.PlanningStatus.found, "plan found")?
    t.expect_true(result.has_plan())?
    t.expect(result.iterations != 0, "iterations > 0")?

    match result.plan:
        Option.none:
            return t.fail("plan is none")
        Option.some as payload:
            let plan = payload.value
            t.expect(plan.step_count() == 4, "4 steps")?
            t.expect(plan.total_cost == 6.0, "total cost 6.0")?
            t.expect_true(plan.final_world.item_crafted)?
            let step0 = plan.step(0) else:
                return t.fail("missing step 0")
            let step1 = plan.step(1) else:
                return t.fail("missing step 1")
            let step2 = plan.step(2) else:
                return t.fail("missing step 2")
            let step3 = plan.step(3) else:
                return t.fail("missing step 3")
            var names_ok = false
            unsafe:
                names_ok = read(step0).action_name.equal(str_mod.cstr_as_str(c"move_to_resource")) and read(step1).action_name.equal(str_mod.cstr_as_str(c"gather_resources")) and read(step2).action_name.equal(str_mod.cstr_as_str(c"move_to_workbench")) and read(step3).action_name.equal(str_mod.cstr_as_str(c"craft"))
            t.expect_true(names_ok)?

    var limited_planner = goap.Planner[World, Goal, Context].create(is_goal, heuristic, worlds_equal)
    defer limited_planner.release()
    limited_planner.set_max_iterations(1)
    limited_planner.add_action(goap.Action[World, Context].create("move_to_resource", can_move_to_resource, move_to_resource, move_cost))
    limited_planner.add_action(goap.Action[World, Context].create("gather_resources", can_gather, gather_resources, gather_cost))
    limited_planner.add_action(goap.Action[World, Context].create("move_to_workbench", can_move_to_workbench, move_to_workbench, move_cost))
    limited_planner.add_action(goap.Action[World, Context].create("craft", can_craft, craft, craft_cost))

    var limited_result = limited_planner.plan(context, initial_world, Goal.craft_item)
    defer limited_result.release()
    t.expect(limited_result.status == goap.PlanningStatus.iteration_limit, "iteration limit reached")?
    return t.expect_false(limited_result.has_plan())
