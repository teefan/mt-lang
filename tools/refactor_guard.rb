#!/usr/bin/env ruby
# frozen_string_literal: true

# refactor_guard — structural checks for the self-host compiler tree.
#
# The parity harnesses prove observable behavior; this tool measures what they
# cannot see: module layering, naming, dead exports, duplication, size, and
# marker hygiene.  It is the structural half of the refactoring safety suite
# (see docs/refactoring.md).
#
# Usage:
#   ruby tools/refactor_guard.rb                 report (exit 0)
#   ruby tools/refactor_guard.rb --check         hard invariants (layering,
#                                                naming, markers); exit 1 on a
#                                                new violation
#   ruby tools/refactor_guard.rb --check --strict
#                                                + new dead-export candidates
#   ruby tools/refactor_guard.rb --check --strict --ratchet
#                                                + code/duplication growth and
#                                                test-count drops
#   ruby tools/refactor_guard.rb --write-baseline
#                                                refresh tools/refactor_baseline.json
#
# Options:
#   --root DIR        repository root (default: this checkout)
#   --baseline FILE   baseline path (default: tools/refactor_baseline.json)
#   --window N        duplication window in normalized lines (default: 12)
#   --tolerance N     allowed code-line growth in ratchet mode (default: 0)
#   --json FILE       write the full report as JSON
#   --top N           report rows per section (default: 10)
#   -q, --quiet       check: one summary line; report: nothing
#
# Exit status: 0 when the requested mode passes, 1 on a violation, 2 on usage.

require "json"
require "optparse"
require_relative "../lib/milk_tea/tooling/refactor_guard"

ROOT = File.expand_path("..", __dir__)

options = {
  root: ROOT,
  baseline: nil,
  window: MilkTea::RefactorGuard::DEFAULT_WINDOW,
  tolerance: 0,
  check: false,
  strict: false,
  ratchet: false,
  write_baseline: false,
  json: nil,
  top: 10,
  quiet: false,
}

OptionParser.new do |opts|
  opts.banner = "Usage: tools/refactor_guard.rb [options]"
  opts.on("--root DIR") { |value| options[:root] = File.expand_path(value, ROOT) }
  opts.on("--baseline FILE") { |value| options[:baseline] = File.expand_path(value, ROOT) }
  opts.on("--window N", Integer) { |value| options[:window] = value }
  opts.on("--tolerance N", Integer) { |value| options[:tolerance] = value }
  opts.on("--check") { options[:check] = true }
  opts.on("--strict") { options[:strict] = true }
  opts.on("--ratchet") { options[:ratchet] = true }
  opts.on("--write-baseline") { options[:write_baseline] = true }
  opts.on("--json FILE") { |value| options[:json] = File.expand_path(value, ROOT) }
  opts.on("--top N", Integer) { |value| options[:top] = value }
  opts.on("-q", "--quiet") { options[:quiet] = true }
  opts.on("-h", "--help") { puts opts; exit 0 }
end.parse!

guard = MilkTea::RefactorGuard.new(
  root: options[:root],
  baseline_path: options[:baseline],
  window: options[:window],
  tolerance: options[:tolerance],
)

if options[:write_baseline]
  path = guard.write_baseline
  puts "wrote #{path.delete_prefix("#{guard.root}/")}"
  exit 0
end

if options[:check]
  ok, failures = guard.check(strict: options[:strict], ratchet: options[:ratchet])
  if ok
    puts "refactor_guard: ok"
    exit 0
  end

  warn "refactor_guard: FAIL (#{failures.length})"
  failures.each { |failure| warn "  #{failure}" }
  exit 1
end

report = guard.build_report
if options[:json]
  File.write(options[:json], "#{JSON.pretty_generate(report)}\n")
  puts "wrote #{options[:json]}" unless options[:quiet]
end
guard.render_report(report, $stdout, top: options[:top]) unless options[:quiet]
