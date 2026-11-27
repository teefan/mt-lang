#!/usr/bin/env ruby
# frozen_string_literal: true
#
# split_build — prove that multi-TU `--split` emission is behaviorally identical
# to the single-file build and that the split-built compiler still passes both
# in-language suites.
#
# Usage:
#   tools/split_build.rb [--self PATH] [--quick]
#
# --quick runs only the sample builds (used by CI); the default also split-builds
# the compiler and runs `test projects/mtc` and `test/mt` with it.

require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
self_bin = File.join(ROOT, "build/stage2/mtc")
quick = false

argv = ARGV.dup
until argv.empty?
  arg = argv.shift
  case arg
  when "--self"
    self_bin = File.expand_path(argv.shift.to_s, ROOT)
  when "--quick"
    quick = true
  when "-h", "--help"
    puts "usage: tools/split_build.rb [--self PATH] [--quick]"
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

failures = []

def capture(*argv)
  Open3.capture3(*argv, chdir: ROOT)
end

def report_failure(failures, name, message)
  failures << "#{name}: #{message}"
end

def run_case(failures, bin, name, source)
  Dir.mktmpdir("mtc-split-gate-") do |dir|
    single = File.join(dir, "single")
    split = File.join(dir, "split")
    out, err, status = capture(bin, "build", source, "-I", ROOT, "-o", single, "--no-cache")
    unless status.success?
      report_failure(failures, "#{name}-single-build", (out + err).lines.last(8).join)
      return
    end
    out, err, status = capture(bin, "build", "--split", source, "-I", ROOT, "-o", split, "--no-cache")
    unless status.success?
      report_failure(failures, "#{name}-split-build", (out + err).lines.last(8).join)
      return
    end
    single_out, single_err, single_status = capture(single)
    split_out, split_err, split_status = capture(split)
    unless single_out == split_out && single_status.exitstatus == split_status.exitstatus
      report_failure(
        failures,
        name,
        "single stdout/exit #{single_out.inspect}/#{single_status.exitstatus} != " \
        "split #{split_out.inspect}/#{split_status.exitstatus}; stderr=#{split_err.inspect}"
      )
    end
  end
end

def stats(out)
  match = out.match(/split: (\d+) object\(s\) reused, (\d+) compiled/)
  return nil unless match
  [match[1].to_i, match[2].to_i]
end

def cache_case(failures, bin)
  Dir.mktmpdir("mtc-split-cache-") do |dir|
    lib = File.join(dir, "lib.mt")
    main = File.join(dir, "main.mt")
    nonce = "#{Process.pid}_#{Time.now.to_i}"
    File.write(lib, <<~MT)
      public function value_#{nonce}() -> int:
          return 1
    MT
    File.write(main, <<~MT)
      import lib

      function main() -> int:
          return lib.value_#{nonce}()
    MT
    output = File.join(dir, "app")
    out, err, status = capture(bin, "build", "--split", main, "-I", dir, "-o", output)
    first = stats(out + err)
    unless status.success? && first == [0, 3]
      report_failure(failures, "object-cache-first", "status=#{status.exitstatus} stats=#{first.inspect} #{(out + err).lines.last(6).join}")
      next
    end
    out, err, status = capture(bin, "build", "--split", main, "-I", dir, "-o", output)
    second = stats(out + err)
    unless status.success? && second == [3, 0]
      report_failure(failures, "object-cache-hit", "status=#{status.exitstatus} stats=#{second.inspect} #{(out + err).lines.last(6).join}")
      next
    end
    File.write(lib, <<~MT)
      public function value_#{nonce}() -> int:
          return 2
    MT
    out, err, status = capture(bin, "build", "--split", main, "-I", dir, "-o", output)
    third = stats(out + err)
    unless status.success? && third == [2, 1]
      report_failure(failures, "object-cache-edit", "status=#{status.exitstatus} stats=#{third.inspect} #{(out + err).lines.last(6).join}")
      next
    end
    _out, _err, run_status = capture(output)
    unless run_status.exitstatus == 2
      report_failure(failures, "object-cache-run", "exit #{run_status.exitstatus} != 2")
    end
  end
end

run_case(failures, self_bin, "array_to_span", "conformance/memory/array_to_span.mt")
run_case(failures, self_bin, "string_builder", "conformance/stdlib/string_builder.mt")
run_case(failures, self_bin, "defer_order", "conformance/control/defer_order.mt")
run_case(failures, self_bin, "tuple_literal", "conformance/types/tuple_array_literal.mt")
cache_case(failures, self_bin)

unless quick
  Dir.mktmpdir("mtc-split-self-") do |dir|
    compiler = File.join(dir, "mtc-split")
    out, err, status = capture(
      self_bin, "build", "--split", "projects/mtc", "-I", ROOT, "-o", compiler
    )
    unless status.success?
      report_failure(failures, "compiler-split-build", (out + err).lines.last(12).join)
      next
    end
    out, err, status = capture(compiler, "version")
    unless status.success? && out.include?("0.7.0")
      report_failure(failures, "compiler-split-version", (out + err).lines.last(4).join)
    end
    out, err, status = capture(compiler, "test", "projects/mtc", "-I", ROOT, "--timeout", "120")
    unless status.success? && out.include?("23 test file(s), 0 failed")
      report_failure(failures, "compiler-split-self", (out + err).lines.last(6).join)
    end
    out, err, status = capture(compiler, "test", "test/mt", "-I", ROOT, "--timeout", "120")
    unless status.success? && out.include?("106 test file(s), 0 failed")
      report_failure(failures, "compiler-split-test-mt", (out + err).lines.last(6).join)
    end
  end
end

failures.each { |failure| puts "FAIL - #{failure}" }
puts "split_build: #{failures.empty? ? "ok" : "failed"} (#{quick ? "quick" : "full"})"
exit(failures.empty? ? 0 : 1)
