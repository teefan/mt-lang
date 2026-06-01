# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdBehaviorTreeTest < Minitest::Test
  def test_host_runtime_executes_behavior_tree_nodes
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

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

function main() -> int:
    var tree = bt.Tree[Context].create()
    defer tree.release()

    let root = tree.add_node(bt.Node[Context].selector())
    let chase = tree.add_node(bt.Node[Context].sequence())
    let can_see = tree.add_node(bt.Node[Context].condition(sees_target))
    let approach = tree.add_node(bt.Node[Context].action(approach_target))
    let attack = tree.add_node(bt.Node[Context].action(attack_target))
    let patrol_repeat = tree.add_node(bt.Node[Context].repeater(2))
    let patrol_leaf = tree.add_node(bt.Node[Context].action(patrol))

    if tree.node_count() != 7:
        return 1
    if not tree.set_root(root):
        return 2
    if not tree.add_child(root, chase):
        return 3
    if not tree.add_child(root, patrol_repeat):
        return 4
    if not tree.add_child(chase, can_see):
        return 5
    if not tree.add_child(chase, approach):
        return 6
    if not tree.add_child(chase, attack):
        return 7
    if not tree.add_child(patrol_repeat, patrol_leaf):
        return 8

    var context = Context(
        target_visible = false,
        approach_step = 0,
        attack_count = 0,
        patrol_count = 0,
        failed_checks = 0,
        until_success_attempts = 0,
    )

    if tree.tick(context) != bt.Status.running:
        return 9
    if context.patrol_count != 1:
        return 10

    if tree.tick(context) != bt.Status.success:
        return 11
    if context.patrol_count != 2:
        return 12

    tree.reset()
    context.target_visible = true
    if tree.tick(context) != bt.Status.running:
        return 13
    if context.attack_count != 0:
        return 14

    if tree.tick(context) != bt.Status.success:
        return 15
    if context.attack_count != 1:
        return 16

    tree.reset()

    var inverter_tree = bt.Tree[Context].create()
    defer inverter_tree.release()
    let inverter_root = inverter_tree.add_node(bt.Node[Context].inverter())
    let false_check = inverter_tree.add_node(bt.Node[Context].condition(always_false))
    if not inverter_tree.set_root(inverter_root):
        return 17
    if not inverter_tree.add_child(inverter_root, false_check):
        return 18
    if inverter_tree.tick(context) != bt.Status.success:
        return 19
    if context.failed_checks != 1:
        return 20

    var retry_tree = bt.Tree[Context].create()
    defer retry_tree.release()
    let until_root = retry_tree.add_node(bt.Node[Context].until_success())
    let retry_leaf = retry_tree.add_node(bt.Node[Context].action(succeed_on_third_try))
    if not retry_tree.set_root(until_root):
        return 21
    if not retry_tree.add_child(until_root, retry_leaf):
        return 22
    if retry_tree.tick(context) != bt.Status.running:
        return 23
    if retry_tree.tick(context) != bt.Status.running:
        return 24
    if retry_tree.tick(context) != bt.Status.success:
        return 25
    if context.until_success_attempts != 3:
        return 26

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
    Dir.mktmpdir("milk-tea-std-behavior-tree") do |dir|
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
