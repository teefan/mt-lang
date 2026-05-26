# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdJobsTest < Minitest::Test
  def test_jobs_pool_create_on_processes_submitted_jobs_and_drains_completions
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.async as aio
import std.jobs as jobs

struct SquareJob:
    value: int
    result: int
    completed: bool

function run_square(arg_raw: ptr[void]) -> void:
    let job = unsafe: ptr[SquareJob]<-arg_raw
    unsafe: read(job).result = read(job).value * read(job).value


function complete_square(arg_raw: ptr[void]) -> void:
    let job = unsafe: ptr[SquareJob]<-arg_raw
    unsafe: read(job).completed = true

function run_with_runtime(runtime: aio.Runtime) -> int:
    let pool_result = jobs.create_on(runtime, 2)
    match pool_result:
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            var pool = payload.value
            defer pool.release()

            var first_job = SquareJob(value = 3, result = 0, completed = false)
            var second_job = SquareJob(value = 4, result = 0, completed = false)

            match pool.submit(jobs.WorkItem.create(run_square, complete_square, unsafe: ptr[void]<-ptr_of(first_job))):
                Result.failure as submit_payload:
                    var error = submit_payload.error
                    defer error.release()
                    return 2
                Result.success as submit_payload:
                    if not submit_payload.value:
                        return 3

            match pool.submit(jobs.WorkItem.create(run_square, complete_square, unsafe: ptr[void]<-ptr_of(second_job))):
                Result.failure as submit_payload:
                    var error = submit_payload.error
                    defer error.release()
                    return 4
                Result.success as submit_payload:
                    if not submit_payload.value:
                        return 5

            var total = 0
            var spins = 0
            while spins < 100000:
                aio.pump(runtime)
                total += int<-pool.drain_completed()

                if first_job.completed and second_job.completed:
                    if first_job.result + second_job.result != 25:
                        return 6
                    if pool.queued_jobs() != 0:
                        return 7
                    if pool.active_jobs() != 0:
                        return 8
                    if not pool.is_idle():
                        return 9
                    return 0

                spins += 1

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

  def test_jobs_pool_create_supports_try_complete_polling
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.async as aio
import std.jobs as jobs

struct IncrementJob:
    value: int
    result: int
    completed: bool

function run_increment(arg_raw: ptr[void]) -> void:
    let job = unsafe: ptr[IncrementJob]<-arg_raw
    unsafe: read(job).result = read(job).value + 1


function complete_increment(arg_raw: ptr[void]) -> void:
    let job = unsafe: ptr[IncrementJob]<-arg_raw
    unsafe: read(job).completed = true

function run_with_runtime(runtime: aio.Runtime) -> int:
    let pool_result = jobs.create(1)
    match pool_result:
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            var pool = payload.value
            defer pool.release()

            var job = IncrementJob(value = 41, result = 0, completed = false)

            match pool.submit(jobs.WorkItem.create(run_increment, complete_increment, unsafe: ptr[void]<-ptr_of(job))):
                Result.failure as submit_payload:
                    var error = submit_payload.error
                    defer error.release()
                    return 2
                Result.success as submit_payload:
                    if not submit_payload.value:
                        return 3

            var spins = 0
            while spins < 100000:
                aio.pump(runtime)
                if not pool.try_complete_one():
                    spins += 1
                    continue

                if job.result != 42:
                    return 4
                if not job.completed:
                    return 5
                if not pool.is_idle():
                    return 6
                return 0

            return 7

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
    Dir.mktmpdir("milk-tea-std-jobs") do |dir|
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
