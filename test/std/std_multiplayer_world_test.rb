# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerWorldTest < Minitest::Test
  def test_world_spawn_state_ptr_and_state_copy_roundtrip
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp

struct PlayerState:
    health: int

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let _ = registry.add_state(mp.StateDescriptor(
        name = "PlayerState",
        authority = mp.Authority.server,
        schema_hash = 0x1001,
        sync_field_count = 1,
        sync_mode = mp.TransferMode.unreliable_ordered,
        sync_channel = 0,
        sync_rate_hz = 20,
        sync_target = mp.SyncTarget.observers,
    )) else:
        return registry
    registry.freeze()
    return registry

function main() -> int:
    var registry = build_registry()
    defer registry.release()

    let world_result = mp.World.create(registry, mp.default_config(), mp.WorldRole.server)
    match world_result:
        Result.failure as _:
            return 1
        Result.success as world_payload:
            var world = world_payload.value
            defer world.release()

            let spawn_result = world.spawn(PlayerState(health = 10), Option[mp.ConnectionId].none)
            match spawn_result:
                Result.failure as _:
                    return 2
                Result.success as spawn_payload:
                    let entity = spawn_payload.value

                    let state_ptr = world.state_ptr[PlayerState](entity) else:
                        return 3
                    unsafe:
                        if read(state_ptr).health != 10:
                            return 4
                        read(state_ptr).health = 22

                    let copied = world.state_copy[PlayerState](entity) else:
                        return 5
                    if copied.health != 22:
                        return 6

                    let missing_ptr = world.state_ptr[PlayerState](entity + 1)
                    if missing_ptr != null:
                        return 7

                    let despawned = world.despawn(entity) else:
                        return 8
                    if not despawned:
                        return 9

                    let ptr_after = world.state_ptr[PlayerState](entity)
                    if ptr_after != null:
                        return 10

                    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_world_descriptor_aware_spawn_and_access_for_multi_state_registry
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp

struct PlayerState:
    health: int

struct ProjectileState:
    velocity: long

function player_descriptor() -> mp.StateDescriptor:
    return mp.StateDescriptor(
        name = "PlayerState",
        authority = mp.Authority.server,
        schema_hash = 0x2001,
        sync_field_count = 1,
        sync_mode = mp.TransferMode.unreliable_ordered,
        sync_channel = 0,
        sync_rate_hz = 20,
        sync_target = mp.SyncTarget.observers,
    )

function projectile_descriptor() -> mp.StateDescriptor:
    return mp.StateDescriptor(
        name = "ProjectileState",
        authority = mp.Authority.server,
        schema_hash = 0x2002,
        sync_field_count = 1,
        sync_mode = mp.TransferMode.unreliable_ordered,
        sync_channel = 0,
        sync_rate_hz = 20,
        sync_target = mp.SyncTarget.observers,
    )

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let _ = registry.add_state(player_descriptor()) else:
        return registry
    let _ = registry.add_state(projectile_descriptor()) else:
        return registry
    registry.freeze()
    return registry

function main() -> int:
    var registry = build_registry()
    defer registry.release()

    let world_result = mp.World.create(registry, mp.default_config(), mp.WorldRole.server)
    match world_result:
        Result.failure as _:
            return 1
        Result.success as world_payload:
            var world = world_payload.value
            defer world.release()

            let ambiguous_spawn = world.spawn(PlayerState(health = 10), Option[mp.ConnectionId].none)
            match ambiguous_spawn:
                Result.success as _:
                    return 2
                Result.failure as payload:
                    if payload.error.code != mp.ErrorCode.not_registered:
                        return 3

            let player = player_descriptor()
            let projectile = projectile_descriptor()

            let player_entity = world.spawn_with_descriptor(player, PlayerState(health = 7), Option[mp.ConnectionId].none) else:
                return 4
            let projectile_entity = world.spawn_with_descriptor(projectile, ProjectileState(velocity = 99), Option[mp.ConnectionId].none) else:
                return 5

            let old_accessor = world.state_ptr[PlayerState](player_entity)
            if old_accessor != null:
                return 6

            let player_ptr = world.state_ptr_with_descriptor[PlayerState](player_entity, player) else:
                return 7
            unsafe:
                if read(player_ptr).health != 7:
                    return 8

            let wrong = world.state_ptr_with_descriptor[PlayerState](projectile_entity, player)
            if wrong != null:
                return 9

            let copied = world.state_copy_with_descriptor[ProjectileState](projectile_entity, projectile) else:
                return 10
            if copied.velocity != 99:
                return 11

            return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_world_respects_max_entities_capacity
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp

struct PlayerState:
    health: int

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let _ = registry.add_state(mp.StateDescriptor(
        name = "PlayerState",
        authority = mp.Authority.server,
        schema_hash = 0x3001,
        sync_field_count = 1,
        sync_mode = mp.TransferMode.unreliable_ordered,
        sync_channel = 0,
        sync_rate_hz = 20,
        sync_target = mp.SyncTarget.observers,
    )) else:
        return registry
    registry.freeze()
    return registry

function main() -> int:
    var registry = build_registry()
    defer registry.release()

    let config = mp.Config(snapshot_tick_hz = 20, max_entities = 1, max_rpcs_per_tick = 32)
    let world_result = mp.World.create(registry, config, mp.WorldRole.server)
    match world_result:
        Result.failure as _:
            return 1
        Result.success as world_payload:
            var world = world_payload.value
            defer world.release()

            let first = world.spawn(PlayerState(health = 10), Option[mp.ConnectionId].none) else:
                return 2
            if first == 0:
                return 3

            match world.spawn(PlayerState(health = 11), Option[mp.ConnectionId].none):
                Result.success as _:
                    return 4
                Result.failure as payload:
                    if payload.error.code != mp.ErrorCode.invalid_argument:
                        return 5

            return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-world") do |dir|
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
