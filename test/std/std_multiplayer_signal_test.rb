# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerSignalTest < Minitest::Test
  def test_signal_payload_builders_and_validation
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'

import std.multiplayer.protocol as protocol
import std.multiplayer.signal as signal

function main() -> int:
    var offer = signal.offer("session-a", 42, "v=0\na=ice-ufrag:a", true)
    defer offer.release()

    let offer_ok = signal.validate_offer(offer, 42) else:
        return 1
    if not offer_ok:
        return 2

    match signal.validate_offer(offer, 43):
        Result.success as _:
            return 3
        Result.failure as payload:
            if payload.error.code != protocol.ErrorCode.invalid_argument:
                return 4

    var answer = signal.answer("session-a", 42, "v=0\na=ice-pwd:b", true)
    defer answer.release()

    let answer_ok = signal.validate_answer(answer, 42) else:
        return 5
    if not answer_ok:
        return 6

    var candidate = signal.candidate("session-a", "candidate:1 1 udp 123 127.0.0.1 4444 typ host")
    defer candidate.release()
    let candidate_ok = signal.validate_candidate(candidate) else:
        return 7
    if not candidate_ok:
        return 8

    var done = signal.gathering_done("session-a")
    defer done.release()
    let done_ok = signal.validate_gathering_done(done) else:
        return 9
    if not done_ok:
        return 10

    var invalid_offer = signal.offer("", 42, "", true)
    defer invalid_offer.release()
    match signal.validate_offer(invalid_offer, 42):
        Result.success as _:
            return 11
        Result.failure as payload:
            if payload.error.code != protocol.ErrorCode.invalid_argument:
                return 12

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-signal") do |dir|
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
