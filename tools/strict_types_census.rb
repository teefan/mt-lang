#!/usr/bin/env ruby
# frozen_string_literal: true
#
# strict_types_census — run `mtc check --strict-types` over the standard
# library, examples, and the self-host sources, and print how often each
# implicit assignability pair is accepted.
#
# This is the Stage 0 observation tool for B3: no file is changed and warnings
# do not fail the run.  Compare the output before/after adding explicit
# coercion rules, and use it to choose the next safe tightening.
#
# Usage:
#   tools/strict_types_census.rb [options]
#
# Options:
#   --self PATH          compiler binary          (default: build/stage2/mtc)
#   --targets LIST       comma-separated paths    (default: std,examples,projects/mtc/src)
#   --fail-on-warning    exit 1 when any strict warning remains
#   -q, --quiet          print only the pair table
#   -h, --help           show this message
#
# Warning lines look like:
#   warning[strict-types]: strict assignability: implicit Box[int] -> Box[str] -- path:9:17

require "open3"

ROOT = File.expand_path("..", __dir__)
self_bin = File.join(ROOT, "build/stage2/mtc")
targets = %w[std examples projects/mtc/src]
quiet = false
fail_on_warning = false

argv = ARGV.dup
until argv.empty?
  arg = argv.shift
  case arg
  when "--self"
    self_bin = argv.shift
  when "--targets"
    targets = argv.shift.to_s.split(",").reject(&:empty?)
  when "-q", "--quiet"
    quiet = true
  when "--fail-on-warning"
    fail_on_warning = true
  when "-h", "--help"
    puts File.read(__FILE__).lines[2..].join.gsub(/^# ?/, "")
    exit 0
  else
    warn "error: unknown argument #{arg}"
    exit 2
  end
end

self_bin = File.expand_path(self_bin, ROOT)
unless File.executable?(self_bin)
  warn "error: compiler not executable: #{self_bin}"
  exit 2
end
if targets.empty?
  warn "error: no targets"
  exit 2
end

counts = Hash.new(0)
per_target = Hash.new { |h, k| h[k] = Hash.new(0) }
seen = {}

targets.each do |target|
  path = File.expand_path(target, ROOT)
  unless File.exist?(path)
    warn "error: target not found: #{target}"
    status = 2
    next
  end
  unless quiet
    puts "scanning #{target}"
  end
  out, err, result = Open3.capture3(
    self_bin, "check", "--strict-types", target, "-I", ROOT, chdir: ROOT
  )
  text = out + err
  text.each_line do |line|
    unless line.start_with?("warning[strict-types]: ")
      next
    end
    normalized = line.chomp
    next if seen[normalized]
    seen[normalized] = true
    message = normalized.sub("warning[strict-types]: ", "").sub(/ -- .*\z/, "")
    counts[message] += 1
    per_target[target][message] += 1
  end
  # `check` exits nonzero when the corpus has semantic errors.  The census is
  # an observation, not a gate, so keep the warnings it did produce.
  unless result.success? || quiet
    puts "  #{target}: check exited #{result.exitstatus}"
  end
end

total = counts.values.sum
puts
puts "strict-types census: #{total} unique warning(s), #{counts.length} distinct pair(s)"
per_target.each do |target, pairs|
  puts "  #{target}: #{pairs.values.sum} warning(s)"
end
puts
counts.sort_by { |message, count| [-count, message] }.each do |message, count|
  puts "#{count}\t#{message}"
end

exit(fail_on_warning && total > 0 ? 1 : 0)
