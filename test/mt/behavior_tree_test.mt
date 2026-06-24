# In-language tests for std.behavior_tree (migrated from
# test/std/std_behavior_tree_test.rb, run by `mtc test`).

import std.testing as t
import std.behavior_tree as bt

struct Context:
    target_visible: bool
    approach_step: int
    attack_count: int
    patrol_count: int
    failed_checks: int
    until_success_attempts: int


function sees_target(context: ptr[Context]) -> bool:
    unsafe:
        return read(context).target_visible


function approach_target(context: ptr[Context]) -> bt.Status:
    unsafe:
        if read(context).approach_step == 0:
            read(context).approach_step = 1
            return bt.Status.running
        return bt.Status.success


function attack_target(context: ptr[Context]) -> bt.Status:
    unsafe:
        read(context).attack_count += 1
    return bt.Status.success


function patrol(context: ptr[Context]) -> bt.Status:
    unsafe:
        read(context).patrol_count += 1
    return bt.Status.success


function always_false(context: ptr[Context]) -> bool:
    unsafe:
        read(context).failed_checks += 1
    return false


function succeed_on_third_try(context: ptr[Context]) -> bt.Status:
    unsafe:
        read(context).until_success_attempts += 1
        if read(context).until_success_attempts >= 3:
            return bt.Status.success
    return bt.Status.failure


@[test]
function test_behavior_tree_nodes() -> t.Check:
    var tree = bt.Tree[Context].create()
    defer tree.release()

    let root = tree.add_node(bt.Node[Context].selector())
    let chase = tree.add_node(bt.Node[Context].sequence())
    let can_see = tree.add_node(bt.Node[Context].condition(sees_target))
    let approach = tree.add_node(bt.Node[Context].action(approach_target))
    let attack = tree.add_node(bt.Node[Context].action(attack_target))
    let patrol_repeat = tree.add_node(bt.Node[Context].repeater(2))
    let patrol_leaf = tree.add_node(bt.Node[Context].action(patrol))

    t.expect(tree.node_count() == 7, "7 nodes")?
    t.expect_true(tree.set_root(root))?
    t.expect_true(tree.add_child(root, chase))?
    t.expect_true(tree.add_child(root, patrol_repeat))?
    t.expect_true(tree.add_child(chase, can_see))?
    t.expect_true(tree.add_child(chase, approach))?
    t.expect_true(tree.add_child(chase, attack))?
    t.expect_true(tree.add_child(patrol_repeat, patrol_leaf))?

    var context = Context(
        target_visible = false,
        approach_step = 0,
        attack_count = 0,
        patrol_count = 0,
        failed_checks = 0,
        until_success_attempts = 0,
    )

    t.expect(tree.tick(context) == bt.Status.running, "first tick running")?
    t.expect_equal_int(context.patrol_count, 1)?

    t.expect(tree.tick(context) == bt.Status.success, "second tick success")?
    t.expect_equal_int(context.patrol_count, 2)?

    tree.reset()
    context.target_visible = true
    t.expect(tree.tick(context) == bt.Status.running, "chase tick running")?
    t.expect_equal_int(context.attack_count, 0)?

    t.expect(tree.tick(context) == bt.Status.success, "chase tick success")?
    t.expect_equal_int(context.attack_count, 1)?

    tree.reset()

    var inverter_tree = bt.Tree[Context].create()
    defer inverter_tree.release()
    let inverter_root = inverter_tree.add_node(bt.Node[Context].inverter())
    let false_check = inverter_tree.add_node(bt.Node[Context].condition(always_false))
    t.expect_true(inverter_tree.set_root(inverter_root))?
    t.expect_true(inverter_tree.add_child(inverter_root, false_check))?
    t.expect(inverter_tree.tick(context) == bt.Status.success, "inverter success")?
    t.expect_equal_int(context.failed_checks, 1)?

    var retry_tree = bt.Tree[Context].create()
    defer retry_tree.release()
    let until_root = retry_tree.add_node(bt.Node[Context].until_success())
    let retry_leaf = retry_tree.add_node(bt.Node[Context].action(succeed_on_third_try))
    t.expect_true(retry_tree.set_root(until_root))?
    t.expect_true(retry_tree.add_child(until_root, retry_leaf))?
    t.expect(retry_tree.tick(context) == bt.Status.running, "retry tick 1 running")?
    t.expect(retry_tree.tick(context) == bt.Status.running, "retry tick 2 running")?
    t.expect(retry_tree.tick(context) == bt.Status.success, "retry tick 3 success")?
    return t.expect_equal_int(context.until_success_attempts, 3)
