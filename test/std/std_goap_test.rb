# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdGoapTest < Minitest::Test
  def test_host_runtime_builds_low_cost_goap_plan
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.goap as goap

enum Goal: ubyte
    craft_item = 0

struct World:
    at_resource: bool
    at_workbench: bool
    has_resource: bool
    item_crafted: bool

struct Context:
    expensive_shortcut_used: bool

function is_goal(context: ptr[Context], world: World, goal: Goal) -> bool:
    return world.item_crafted

function heuristic(context: ptr[Context], world: World, goal: Goal) -> float:
    var score = 0.0
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

function gather(context: ptr[Context], world: World) -> World:
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
    unsafe:
        read(context).expensive_shortcut_used = true
    return next

function expensive_cost(context: ptr[Context], world: World) -> float:
    return 20.0

function main() -> int:
    var planner = goap.Planner[World, Goal, Context].create(is_goal, heuristic)
    defer planner.release()

    planner.add_action(goap.Action[World, Context].create("move_to_resource", can_move_to_resource, move_to_resource, move_cost))
    planner.add_action(goap.Action[World, Context].create("gather", can_gather, gather, gather_cost))
    planner.add_action(goap.Action[World, Context].create("move_to_workbench", can_move_to_workbench, move_to_workbench, move_cost))
    planner.add_action(goap.Action[World, Context].create("craft", can_craft, craft, craft_cost))
    planner.add_action(goap.Action[World, Context].create("buy_shortcut", can_buy, buy_shortcut, expensive_cost))

    if planner.action_count() != 5:
        return 1

    var context = Context(expensive_shortcut_used = false)
    let initial_world = World(
        at_resource = false,
        at_workbench = false,
        has_resource = false,
        item_crafted = false,
    )

    var result = planner.plan(context, initial_world, Goal.craft_item)
    defer result.release()

    if result.status != goap.PlanningStatus.found:
        return 2
    if not result.has_plan():
        return 3
    if result.iterations == 0:
        return 4

    match result.plan:
        Option.none:
            return 5
        Option.some as payload:
            let plan = payload.value
            if plan.step_count() != 4:
                return 6
            if plan.total_cost != 6.0:
                return 7
            if not plan.final_world.item_crafted:
                return 8
            let step0 = plan.step(0) else:
                return 9
            let step1 = plan.step(1) else:
                return 10
            let step2 = plan.step(2) else:
                return 11
            let step3 = plan.step(3) else:
                return 12
            unsafe:
                if not read(step0).action_name.equal("move_to_resource"):
                    return 13
                if not read(step1).action_name.equal("gather"):
                    return 14
                if not read(step2).action_name.equal("move_to_workbench"):
                    return 15
                if not read(step3).action_name.equal("craft"):
                    return 16

    if context.expensive_shortcut_used:
        return 17

    var limited_planner = goap.Planner[World, Goal, Context].create(is_goal, heuristic)
    defer limited_planner.release()
    limited_planner.set_max_iterations(1)
    limited_planner.add_action(goap.Action[World, Context].create("move_to_resource", can_move_to_resource, move_to_resource, move_cost))
    limited_planner.add_action(goap.Action[World, Context].create("gather", can_gather, gather, gather_cost))
    limited_planner.add_action(goap.Action[World, Context].create("move_to_workbench", can_move_to_workbench, move_to_workbench, move_cost))
    limited_planner.add_action(goap.Action[World, Context].create("craft", can_craft, craft, craft_cost))

    var limited_result = limited_planner.plan(context, initial_world, Goal.craft_item)
    defer limited_result.release()
    if limited_result.status != goap.PlanningStatus.iteration_limit:
        return 18
    if limited_result.has_plan():
        return 19

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-goap") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, source)
      return MilkTea::Run.run(source_path, cc: compiler)
    end
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
