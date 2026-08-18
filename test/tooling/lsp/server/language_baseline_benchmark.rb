#!/usr/bin/env ruby
# frozen_string_literal: true

# LSP hover/completion benchmark against examples/language_baseline.mt.
#
# Drives the real in-process server the way an editor would after opening the
# file, then reports per-request latency for hover and completion at multiple
# positions across the document.
#
# Run: ruby test/tooling/lsp/server/language_baseline_benchmark.rb [iters] [--profile]
#   iters      iteration count per position (default 5)
#   --profile  write stackprof wall-time profiles for hover and completion to
#              /tmp (requires the stackprof gem)

require_relative "helpers"

require "tmpdir"
require "json"

ITERS = (ARGV.first&.to_i || 5).clamp(1, 50)
PROFILE = ARGV.include?("--profile")

ROOT = LSPServerTestHelpers::ROOT_DIR
BASELINE = File.join(ROOT, "examples", "language_baseline.mt")

def find_pos(source, marker, offset: 0)
  lines = source.split("\n", -1)
  line_idx = lines.index { |l| l.include?(marker) }
  return nil unless line_idx

  col = lines[line_idx].index(marker) || 0
  [line_idx, col + offset]
end

def path_to_uri(path)
  "file://#{path.split('/').map { |seg| CGI.escape(seg).gsub('+', '%20') }.join('/')}"
end

class BenchProtocol
  attr_reader :responses, :errors

  def initialize
    @responses = []
    @errors = []
  end

  def read_message = nil

  def write_notification(_method, _params); end

  def write_response(id, result)
    @responses << { "id" => id, "result" => result }
  end

  def write_error(id, code, message)
    @errors << { "id" => id, "code" => code, "message" => message }
  end

  def send_request(_method, _params, &_callback); end
end

def time_calls(iterations)
  times = []
  iterations.times do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
  end
  times
end

def report(label, times)
  avg = times.sum / times.length
  puts format("%-40s %6d %10.3f %10.3f %10.3f", label, times.length, avg, times.min, times.max)
end

source = File.read(BASELINE)
uri = path_to_uri(BASELINE)

server = MilkTea::LSP::Server.new(protocol: BenchProtocol.new)
server.send(:handle_initialize, { "rootUri" => path_to_uri(ROOT), "capabilities" => {} })
server.send(:handle_initialized, {})
server.instance_variable_get(:@_indexing_thread)&.join
server.send(:stop_diagnostics_workers)

ws = server.instance_variable_get(:@workspace)
ws.open_document(uri, source)

pos = lambda { |line, char|
  { "textDocument" => { "uri" => uri }, "position" => { "line" => line, "character" => char } }
}

hover_positions = [
  find_pos(source, "function add(a: int"),
  find_pos(source, "greet(\"World\")"),
  find_pos(source, "Vec2(x = 1.0, y = 2.0)"),
  find_pos(source, "square(7)"),
  find_pos(source, "this.hp"),
  find_pos(source, "TokenKind.ident(name = \"hello\")"),
  find_pos(source, "Option[int].some(value = 42)"),
  find_pos(source, "Result[int, int].success(value = 7)"),
  find_pos(source, "parallel for i in 0..4"),
  find_pos(source, "struct_equality_demo()"),
  find_pos(source, "Mask.a"),
  find_pos(source, "fields_of(Particle)"),
  find_pos(source, "simd[float, 4]"),
  find_pos(source, "dyn[Shape]"),
  find_pos(source, "atomic[int]"),
].compact

completion_positions = [
  find_pos(source, "    let x = 10"),
  find_pos(source, "    var result: int"),
  find_pos(source, "    total += s.value"),
  find_pos(source, "    return sum_pos"),
  find_pos(source, "    counter.store(0)"),
  find_pos(source, "import std.async"),
  find_pos(source, "struct Vec2:"),
].compact

puts "=" * 72
puts "LSP baseline: #{File.basename(BASELINE)} (#{source.lines.count} lines, #{source.bytesize} bytes)"
puts "hover positions: #{hover_positions.length}, completion positions: #{completion_positions.length}, iters: #{ITERS}"
puts "=" * 72

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
server.send(:handle_hover, pos.call(*hover_positions.first))
facts_cold_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
puts format("%-40s %6s %10.3f", "hover (cold, includes facts)", "-", facts_cold_ms)

server.send(:handle_document_diagnostic, { "textDocument" => { "uri" => uri } })

t_all = Process.clock_gettime(Process::CLOCK_MONOTONIC)

if PROFILE
  begin
    require "stackprof"
  rescue LoadError
    warn "--profile requires the stackprof gem"
    exit 1
  end
  StackProf.run(mode: :wall, out: "/tmp/lsp_hover.stackprof", raw: true) do
    hover_positions.each do |lp|
      ITERS.times { server.send(:handle_hover, pos.call(*lp)) }
    end
  end
  StackProf.run(mode: :wall, out: "/tmp/lsp_completion.stackprof", raw: true) do
    completion_positions.each do |lp|
      ITERS.times { server.send(:handle_completion, pos.call(*lp)) }
    end
  end
end

hover_total = []
hover_positions.each do |lp|
  server.send(:handle_hover, pos.call(*lp)) # warmup
  hover_total.concat(time_calls(ITERS) { server.send(:handle_hover, pos.call(*lp)) })
end
report("hover (warm, all positions)", hover_total)

completion_total = []
completion_positions.each do |lp|
  server.send(:handle_completion, pos.call(*lp)) # warmup
  completion_total.concat(time_calls(ITERS) { server.send(:handle_completion, pos.call(*lp)) })
end
report("completion (warm, all positions)", completion_total)

puts "--- hover per position (single warm call) ---"
hover_positions.each do |lp|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  server.send(:handle_hover, pos.call(*lp))
  ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
  puts format("  %6.3f ms  line %3d char %3d", ms, lp[0], lp[1])
end

puts "--- completion per position (single warm call) ---"
completion_positions.each do |lp|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  server.send(:handle_completion, pos.call(*lp))
  ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
  puts format("  %6.3f ms  line %3d char %3d", ms, lp[0], lp[1])
end

total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_all) * 1000.0
puts format("%-40s %6s %10.3f", "total wall (all measurements)", "-", total_ms)
