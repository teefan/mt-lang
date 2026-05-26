# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdThreadSyncTest < Minitest::Test
  def test_thread_spawn_and_join_runs_worker
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.thread as thread

var worker_value: int = 0

function worker() -> void:
    worker_value = 42

function main() -> int:
    let spawn_result = thread.spawn(worker)
    match spawn_result:
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            var handle = payload.value
            defer handle.release()
            let join_result = handle.join()
            match join_result:
                Result.failure as join_payload:
                    var error = join_payload.error
                    defer error.release()
                    return 2
                Result.success as join_payload:
                    if not join_payload.value:
                        return 3
    return worker_value

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_semaphore_coordinates_worker_and_main_thread
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.sync as sync
import std.thread as thread

struct WorkerState:
    gate: ptr[sync.Semaphore]
    ready: ptr[bool]

function worker(state_raw: ptr[void]) -> void:
    let state = unsafe: ptr[WorkerState]<-state_raw
    unsafe:
        let gate = read(state).gate
        gate.wait()
        let ready = read(state).ready
        read(ready) = true

function main() -> int:
    var gate = zero[sync.Semaphore]
    var worker_ready = false

    let semaphore_result = sync.create_semaphore(0)
    match semaphore_result:
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            gate = payload.value

    defer gate.release()

    var worker_state = WorkerState(gate = unsafe: ptr_of(gate), ready = unsafe: ptr_of(worker_ready))

    let spawn_result = thread.spawn_raw(worker, unsafe: ptr[void]<-ptr_of(worker_state))
    match spawn_result:
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 2
        Result.success as payload:
            var handle = payload.value
            defer handle.release()
            gate.post()
            let join_result = handle.join()
            match join_result:
                Result.failure as join_payload:
                    var error = join_payload.error
                    defer error.release()
                    return 3
                Result.success as join_payload:
                    if not join_payload.value:
                        return 4

    if not worker_ready:
        return 5

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_mailbox_receives_message_from_worker_thread
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.async as aio
import std.async.mailbox as mailbox
import std.thread as thread

struct WorkerState:
    mailbox: ptr[mailbox.Mailbox[int]]

function worker(state_raw: ptr[void]) -> void:
    let state = unsafe: ptr[WorkerState]<-state_raw
    unsafe:
        let shared_mailbox = read(state).mailbox
        let first_send_result = shared_mailbox.send(40)
        match first_send_result:
            Result.failure as payload:
                var error = payload.error
                defer error.release()
                return
            Result.success as payload:
                if not payload.value:
                    return

        let send_result = shared_mailbox.send(2)
        match send_result:
            Result.failure as payload:
                var error = payload.error
                defer error.release()
                return
            Result.success as payload:
                if not payload.value:
                    return

function run_with_runtime(runtime: aio.Runtime) -> int:
    var shared_mailbox = zero[mailbox.Mailbox[int]]

    let mailbox_result = mailbox.create_on[int](runtime)
    match mailbox_result:
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            shared_mailbox = payload.value

    defer shared_mailbox.release()

    var worker_state = WorkerState(mailbox = unsafe: ptr_of(shared_mailbox))

    let spawn_result = thread.spawn_raw(worker, unsafe: ptr[void]<-ptr_of(worker_state))
    match spawn_result:
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 2
        Result.success as payload:
            var handle = payload.value
            defer handle.release()

            var spins = 0
            while spins < 100000:
                aio.pump(runtime)
                var messages = shared_mailbox.drain()
                if messages.len() == 0:
                    messages.release()
                    spins += 1
                    continue

                if messages.len() != 2:
                    messages.release()
                    return 3

                let first = messages.get(0) else:
                    messages.release()
                    return 4

                let second = messages.get(1) else:
                    messages.release()
                    return 5

                unsafe:
                    if read(first) != 40:
                        messages.release()
                        return 6
                    if read(second) != 2:
                        messages.release()
                        return 7

                messages.release()

                let join_result = handle.join()
                match join_result:
                    Result.failure as join_payload:
                        var error = join_payload.error
                        defer error.release()
                        return 8
                    Result.success as join_payload:
                        if not join_payload.value:
                            return 9
                return 0

            return 10

function main() -> int:
    return aio.with_runtime(run_with_runtime)

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-thread-sync") do |dir|
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
