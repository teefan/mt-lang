#!/usr/bin/env ruby
# frozen_string_literal: true
#
# conformance — run the hand-written, spec-derived conformance cases.
#
# Expectations are checked in beside each case and are intentionally not
# generated or refreshed by this tool.  A failing expectation is a spec
# decision to review, not a difference to record.
#
# Usage:
#   tools/conformance.rb [--self PATH] [--filter SUBSTRING] [-q]
#
# Case format:
#   conformance/**/*.mt          the program
#   conformance/**/*.json        sibling expectation
#
# Run case:
#   {"mode":"run","stdout":"...","exit":0,"stderr_contains":["..."]}
#
# Check case:
#   {"mode":"check","errors":[
#     {"code":"sema/error","line":9,"column":12,"message_contains":"expects"}
#   ]}
#
# `line` and `column` are optional; when present they must match exactly.
# Check cases may set "strict": true to run `check --strict-types`.
# Run cases may set "strict": true to build with `--strict-types`; warnings do
# not fail the build, but a strict warning is reported by the case output checks
# only when explicitly requested with "stderr_contains".
#
# Run cases may also set "build_args": ["--split", ...] to pass build options.
# Verify-IR cases run `lower --verify-ir` and require a zero exit status.

require "json"
require "open3"
require "tmpdir"
require "timeout"

ROOT = File.expand_path("..", __dir__)
self_bin = File.join(ROOT, "build/stage2/mtc")
filter = nil
quiet = false

argv = ARGV.dup
until argv.empty?
  arg = argv.shift
  case arg
  when "--self"
    self_bin = File.expand_path(argv.shift.to_s, ROOT)
  when "--filter"
    filter = argv.shift
  when "-q", "--quiet"
    quiet = true
  when "-h", "--help"
    puts File.read(__FILE__).lines[2..].join.gsub(/^# ?/, "")
    exit 0
  else
    warn "error: unknown argument #{arg}"
    exit 2
  end
end

unless File.executable?(self_bin)
  warn "error: compiler not executable: #{self_bin}"
  exit 2
end

cases = Dir[File.join(ROOT, "conformance/**/*.mt")].sort
cases = cases.select { |path| path.include?(filter) } if filter
if cases.empty?
  warn "error: no conformance cases#{filter ? " matching #{filter}" : ""}"
  exit 2
end

failures = []

def capture(*argv)
  Open3.capture3(*argv, chdir: ROOT)
end

def fail_case(failures, name, message)
  failures << [name, message]
end

cases.each do |source|
  relative = source.delete_prefix("#{ROOT}/")
  name = relative.delete_suffix(".mt")
  expectation_path = source.sub(/\.mt\z/, ".json")
  unless File.file?(expectation_path)
    fail_case(failures, name, "missing expectation #{expectation_path.delete_prefix("#{ROOT}/")}")
    next
  end

  begin
    spec = JSON.parse(File.read(expectation_path))
  rescue JSON::ParserError => e
    fail_case(failures, name, "invalid expectation JSON: #{e.message}")
    next
  end

  source_text = File.read(source)
  unless source_text.lines.any? { |line| line.start_with?("# Spec: ") }
    fail_case(failures, name, "missing '# Spec: <section>' citation")
    next
  end

  mode = spec.fetch("mode", "run")
  if mode == "verify-ir"
    out, err, status = capture(self_bin, "lower", source, "-I", ROOT, "--verify-ir")
    unless status.success?
      fail_case(failures, name, "verify-ir failed:\n#{(out + err).lines.last(12).join}")
      next
    end
    spec.fetch("stderr_contains", []).each do |needle|
      unless err.include?(needle)
        fail_case(failures, name, "stderr does not contain #{needle.inspect}")
        break
      end
    end
  elsif mode == "check"
    args = [self_bin, "check", source, "-I", ROOT]
    args << "--strict-types" if spec["strict"]
    out, err, status = capture(*args)
    text = out + err
    actual = []
    text.each_line do |line|
      match = line.match(/\Aerror\[([^\]]+)\]: (.*?) -- .*:(\d+):(\d+)\s*\z/)
      next unless match
      actual << {
        "code" => match[1],
        "message" => match[2],
        "line" => match[3].to_i,
        "column" => match[4].to_i
      }
    end

    expected = spec.fetch("errors", [])
    if actual.length != expected.length
      fail_case(
        failures,
        name,
        "expected #{expected.length} error(s), got #{actual.length}: " \
        "#{actual.map { |e| "#{e["code"]}:#{e["line"]}:#{e["column"]} #{e["message"]}" }.join(" | ")}"
      )
      next
    end

    actual.each_with_index do |got, index|
      want = expected[index]
      unless got["code"] == want["code"]
        fail_case(failures, name, "error #{index + 1} code #{got["code"]} != #{want["code"]}")
        next
      end
      if want.key?("line") && got["line"] != want["line"]
        fail_case(failures, name, "error #{index + 1} line #{got["line"]} != #{want["line"]}")
        next
      end
      if want.key?("column") && got["column"] != want["column"]
        fail_case(failures, name, "error #{index + 1} column #{got["column"]} != #{want["column"]}")
        next
      end
      if want.key?("message_contains") && !got["message"].include?(want["message_contains"])
        fail_case(
          failures,
          name,
          "error #{index + 1} message #{got["message"].inspect} does not contain #{want["message_contains"].inspect}"
        )
      end
    end
  elsif mode == "run"
    Dir.mktmpdir("mtc-conformance-") do |dir|
      binary = File.join(dir, "case")
      build_args = [self_bin, "build", source, "-I", ROOT, "-o", binary, "--no-cache"]
      build_args << "--strict-types" if spec["strict"]
      build_args.concat(spec.fetch("build_args", []))
      bout, berr, bstatus = capture(*build_args)
      unless bstatus.success?
        fail_case(failures, name, "build failed:\n#{(bout + berr).lines.last(12).join}")
        next
      end

      timeout = spec.fetch("timeout", 20)
      begin
        out, err, status = Timeout.timeout(timeout) { capture(binary) }
      rescue Timeout::Error
        fail_case(failures, name, "run timed out after #{timeout}s")
        next
      end

      want_stdout = spec.fetch("stdout", "")
      unless out == want_stdout
        fail_case(failures, name, "stdout #{out.inspect} != #{want_stdout.inspect}")
        next
      end
      want_exit = spec.fetch("exit", 0)
      unless status.exitstatus == want_exit
        fail_case(failures, name, "exit #{status.exitstatus} != #{want_exit}")
        next
      end
      spec.fetch("stderr_contains", []).each do |needle|
        unless err.include?(needle)
          fail_case(failures, name, "stderr does not contain #{needle.inspect}")
          break
        end
      end
    end
  else
    fail_case(failures, name, "unknown mode #{mode.inspect}")
  end
end

failures.each do |name, message|
  puts "FAIL - #{name}: #{message}"
end
puts "conformance: #{cases.length - failures.length} passed, #{failures.length} failed of #{cases.length}"
exit(failures.empty? ? 0 : 1)
