# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerWorldTest < Minitest::Test
  def test_world_spawn_state_ptr_and_state_copy_roundtrip
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp

@[mp.replicated(authority = mp.Authority.server)]
struct PlayerState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    health: int

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let _ = registry.add_state(mp.state_descriptor[PlayerState]()) else:
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

@[mp.replicated(authority = mp.Authority.server)]
struct PlayerState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    health: int

@[mp.replicated(authority = mp.Authority.server)]
struct ProjectileState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    velocity: long

function player_descriptor() -> mp.StateDescriptor:
    return mp.state_descriptor[PlayerState]()

function projectile_descriptor() -> mp.StateDescriptor:
    return mp.state_descriptor[ProjectileState]()

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

@[mp.replicated(authority = mp.Authority.server)]
struct PlayerState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    health: int

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let _ = registry.add_state(mp.state_descriptor[PlayerState]()) else:
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

  def test_world_snapshot_payload_roundtrip_applies_descriptor_matched_entity_state
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp

@[mp.replicated(authority = mp.Authority.server)]
struct PlayerState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    health: int

function player_descriptor() -> mp.StateDescriptor:
    return mp.state_descriptor[PlayerState]()

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let _ = registry.add_state(player_descriptor()) else:
        return registry
    registry.freeze()
    return registry

function main() -> int:
    var registry = build_registry()
    defer registry.release()

    let descriptor = player_descriptor()

    let source_world_result = mp.World.create(registry, mp.default_config(), mp.WorldRole.server)
    match source_world_result:
        Result.failure as _:
            return 1
        Result.success as source_payload:
            var source_world = source_payload.value
            defer source_world.release()

            let sink_world_result = mp.World.create(registry, mp.default_config(), mp.WorldRole.client)
            match sink_world_result:
                Result.failure as _:
                    return 2
                Result.success as sink_payload:
                    var sink_world = sink_payload.value
                    defer sink_world.release()

                    let source_entity = source_world.spawn_with_descriptor(descriptor, PlayerState(health = 77), Option[mp.ConnectionId].none) else:
                        return 3
                    let sink_entity = sink_world.spawn_with_descriptor(descriptor, PlayerState(health = 5), Option[mp.ConnectionId].none) else:
                        return 4

                    if source_entity != sink_entity:
                        return 5

                    var encoded = source_world.encode_snapshot_payload() else:
                        return 6
                    defer encoded.release()

                    let applied = sink_world.apply_snapshot_payload(encoded.as_span()) else:
                        return 10
                    if applied != 1:
                        return 7

                    let state = sink_world.state_copy_with_descriptor[PlayerState](sink_entity, descriptor) else:
                        return 8
                    if state.health != 77:
                        return 9

                    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_world_prepare_snapshot_returns_reusable_header_signature_and_payload
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp

@[mp.replicated(authority = mp.Authority.server)]
struct PlayerState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    health: int

function descriptor() -> mp.StateDescriptor:
    return mp.state_descriptor[PlayerState]()

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let _ = registry.add_state(descriptor()) else:
        return registry
    registry.freeze()
    return registry

function main() -> int:
    var registry = build_registry()
    defer registry.release()

    let source_world_result = mp.World.create(registry, mp.default_config(), mp.WorldRole.server)
    match source_world_result:
        Result.failure as _:
            return 1
        Result.success as source_payload:
            var source_world = source_payload.value
            defer source_world.release()

            let sink_world_result = mp.World.create(registry, mp.default_config(), mp.WorldRole.client)
            match sink_world_result:
                Result.failure as _:
                    return 2
                Result.success as sink_payload:
                    var sink_world = sink_payload.value
                    defer sink_world.release()

                    let source_entity = source_world.spawn_with_descriptor(descriptor(), PlayerState(health = 44), Option[mp.ConnectionId].none) else:
                        return 3
                    let sink_entity = sink_world.spawn_with_descriptor(descriptor(), PlayerState(health = 1), Option[mp.ConnectionId].none) else:
                        return 4
                    if source_entity != sink_entity:
                        return 5

                    var prepared = source_world.prepare_snapshot(50, 12) else:
                        return 6
                    defer prepared.release()

                    if prepared.header.tick != 50:
                        return 7
                    if prepared.header.baseline_tick != 12:
                        return 8
                    if prepared.header.entity_count != 1:
                        return 9
                    if prepared.signature.tick != 50:
                        return 10
                    if prepared.signature.entity_count != 1:
                        return 11
                    if prepared.signature.payload_bytes == 0:
                        return 12
                    if prepared.payload.as_span().len == 0:
                        return 13

                    let applied = sink_world.apply_snapshot_payload(prepared.payload.as_span()) else:
                        return 14
                    if applied != 1:
                        return 15

                    let state = sink_world.state_copy_with_descriptor[PlayerState](sink_entity, descriptor()) else:
                        return 16
                    if state.health != 44:
                        return 17

                    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_world_snapshot_payload_partial_apply_for_mixed_descriptors
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp

@[mp.replicated(authority = mp.Authority.server)]
struct PlayerState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    health: int

@[mp.replicated(authority = mp.Authority.server)]
struct ProjectileState:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    velocity: long

@[mp.replicated(authority = mp.Authority.server)]
struct ProjectileStateClient:
    @[mp.sync(mode = mp.TransferMode.unreliable_ordered, channel = 0, rate_hz = 20, target = mp.SyncTarget.observers)]
    velocity: int

function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let _ = registry.add_state(mp.state_descriptor[PlayerState]()) else:
        return registry
    let _ = registry.add_state(mp.state_descriptor[ProjectileState]()) else:
        return registry
    let _ = registry.add_state(mp.state_descriptor[ProjectileStateClient]()) else:
        return registry
    registry.freeze()
    return registry

function main() -> int:
    var registry = build_registry()
    defer registry.release()

    let player = mp.state_descriptor[PlayerState]()
    let projectile_server = mp.state_descriptor[ProjectileState]()
    let projectile_client = mp.state_descriptor[ProjectileStateClient]()

    let source_world_result = mp.World.create(registry, mp.default_config(), mp.WorldRole.server)
    match source_world_result:
        Result.failure as _:
            return 1
        Result.success as source_payload:
            var source_world = source_payload.value
            defer source_world.release()

            let sink_world_result = mp.World.create(registry, mp.default_config(), mp.WorldRole.client)
            match sink_world_result:
                Result.failure as _:
                    return 2
                Result.success as sink_payload:
                    var sink_world = sink_payload.value
                    defer sink_world.release()

                    let source_player = source_world.spawn_with_descriptor(player, PlayerState(health = 90), Option[mp.ConnectionId].none) else:
                        return 3
                    let sink_player = sink_world.spawn_with_descriptor(player, PlayerState(health = 1), Option[mp.ConnectionId].none) else:
                        return 4

                    let source_projectile = source_world.spawn_with_descriptor(projectile_server, ProjectileState(velocity = 120), Option[mp.ConnectionId].none) else:
                        return 5
                    let sink_projectile = sink_world.spawn_with_descriptor(projectile_client, ProjectileStateClient(velocity = 2), Option[mp.ConnectionId].none) else:
                        return 6

                    if source_player != sink_player:
                        return 7
                    if source_projectile != sink_projectile:
                        return 8

                    var encoded = source_world.encode_snapshot_payload() else:
                        return 9
                    defer encoded.release()

                    let applied = sink_world.apply_snapshot_payload(encoded.as_span()) else:
                        return 10
                    if applied != 1:
                        return 11

                    let player_state = sink_world.state_copy_with_descriptor[PlayerState](sink_player, player) else:
                        return 12
                    if player_state.health != 90:
                        return 13

                    let projectile_state = sink_world.state_copy_with_descriptor[ProjectileStateClient](sink_projectile, projectile_client) else:
                        return 14
                    if projectile_state.velocity != 2:
                        return 15

                    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_world_snapshot_payload_parser_rejects_truncated_and_trailing_entries
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp

function main() -> int:
    var registry = mp.Registry.create()
    registry.freeze()
    defer registry.release()

    let world_result = mp.World.create(registry, mp.default_config(), mp.WorldRole.client)
    match world_result:
        Result.failure as _:
            return 1
        Result.success as world_payload:
            var world = world_payload.value
            defer world.release()

            var too_small = array[ubyte, 3](0, 0, 0)
            match world.apply_snapshot_payload(too_small):
                Result.success as _:
                    return 2
                Result.failure as payload:
                    if payload.error.code != mp.ErrorCode.invalid_argument:
                        return 3

            var truncated_entry = array[ubyte, 23](
                0, 0, 0, 1,
                0, 0, 0, 1,
                0, 0, 0, 0, 0, 0, 0, 1,
                0, 0, 0, 4,
                7, 8, 9,
            )
            match world.apply_snapshot_payload(truncated_entry):
                Result.success as _:
                    return 4
                Result.failure as payload:
                    if payload.error.code != mp.ErrorCode.invalid_argument:
                        return 5

            var trailing_bytes = array[ubyte, 5](0, 0, 0, 0, 9)
            match world.apply_snapshot_payload(trailing_bytes):
                Result.success as _:
                    return 6
                Result.failure as payload:
                    if payload.error.code != mp.ErrorCode.invalid_argument:
                        return 7

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
