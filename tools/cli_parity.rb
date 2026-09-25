#!/usr/bin/env ruby
# frozen_string_literal: true
#
# cli_parity — compare the self-hosted `mtc` CLI against the Ruby host compiler,
# byte for byte: stdout, stderr and exit status for the same argv in the same
# working directory.
#
# The Ruby host is loaded once in the parent (its CLI is invoked in-process),
# while the self-host binary is spawned per case.  Fixtures are materialized
# into tmp/cli-parity/fixtures so the matrix is self-contained.
#
# Usage:
#   tools/cli_parity.rb [options]
#
# Options:
#   --self PATH      self-host compiler binary  (default: build/stage2/mtc)
#   --max-diffs N    failing cases to detail    (default: 25)
#   --keep           keep the materialized fixtures and per-case outputs
#   -q, --quiet      print only the summary
#   -f, --filter RE  only run cases whose name matches RE
#   -h, --help       show this message
#
# Exit status: 0 when every comparable case matches, 1 otherwise.  Cases listed
# in KNOWN_GAPS are reported as PENDING and never counted as failures, so the
# deferred subsystems stay visible without painting the harness red.

require "fileutils"
require "open3"
require "stringio"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

# Invocations that depend on subsystems the self-host does not implement yet
# (see docs/self-host-plan.md "Self-host CLI gaps").  Reported, never counted.
KNOWN_GAPS = [
  /^deps\b/,
  /^docs\b/,
  /--bundle\b/,
  /--archive\b/,
  /^toolchain bootstrap\b/,
  /--locked\b/,
  /--frozen\b/,
  /--tidy\b/,
  /--preserve\b/,
  /--max-line-length\b/,
  /--platform wasm\b/,
  /^build --kind (static|shared)\b/,
].freeze

self_bin = nil
max_diffs = 25
keep = false
quiet = false
filter = nil

argv = ARGV.dup
until argv.empty?
  a = argv.shift
  case a
  when "--self"      then self_bin = argv.shift
  when "--max-diffs" then max_diffs = argv.shift.to_i
  when "--keep"      then keep = true
  when "-q", "--quiet" then quiet = true
  when "-f", "--filter" then filter = argv.shift
  when "-h", "--help"
    puts File.read(__FILE__).lines.drop(2).take_while { |l| l.start_with?("#") }
             .map { |l| l.sub(/\A# ?/, "") }.join
    exit 0
  else
    warn "unknown option: #{a}"
    exit 1
  end
end

self_bin ||= File.join(ROOT, "build", "stage2", "mtc")
self_bin = File.expand_path(self_bin)
unless File.executable?(self_bin)
  warn "error: self-host compiler not found or not executable: #{self_bin}"
  warn "       build one with: ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o #{self_bin}"
  exit 1
end

newest_src = Dir.glob(File.join(ROOT, "projects", "mtc", "src", "**", "*.mt")).map { |f| File.mtime(f) }.max
warn "warning: #{self_bin} is older than the newest self-host source — rebuild it for accurate parity." if newest_src && File.mtime(self_bin) < newest_src

# ── fixtures ────────────────────────────────────────────────────────────────

FIXROOT = File.join(ROOT, "tmp", "cli-parity", "fixtures")

FIXTURES = {
  # A normal application package.
  "pkg/package.toml" => <<~TOML,
    [package]
    name = "pkg"
    version = "0.1.0"
    source_root = "src"

    [build]
    entry = "src/main.mt"
  TOML
  "pkg/src/main.mt" => <<~MT,
    public function add(a: int, b: int) -> int:
        return a + b

    function main() -> int:
        print(add(2, 3))
        return 0
    MT
  "pkg/src/platform_info.linux.mt" => "public const PLATFORM: str = \"linux\"\n",
  "pkg/src/platform_info.windows.mt" => "public const PLATFORM: str = \"windows\"\n",

  # A package whose entry does not exist (manifest error path).
  "broken/package.toml" => <<~TOML,
    [package]
    name = "broken"
    source_root = "src"

    [build]
    entry = "src/nope.mt"
  TOML
  "broken/src/main.mt" => "function main() -> int:\n    return 0\n",

  # A library package (no entry point).
  "libpkg/package.toml" => <<~TOML,
    [package]
    name = "libpkg"
    kind = "library"
    source_root = "src"
  TOML
  "libpkg/src/helper.mt" => "public function twice(x: int) -> int:\n    return x * 2\n",

  # Standalone files.
  "standalone/clean.mt" => <<~MT,
    function helper(x: int) -> int:
        return x + 1

    function main() -> int:
        print(helper(41))
        return 0
    MT
  "standalone/warns.mt" => <<~MT,
    function main() -> int:
        let unused = 5
        var counter = 0
        counter = 1
        print(counter)
        return 0
    MT
  "standalone/syntax_error.mt" => "function main() -> int:\n    let x = (\n    return 0\n",
  "standalone/sema_error.mt" => "function main() -> int:\n    let x: int = \"not an int\"\n    print(x)\n    return 0\n",
  "standalone/no_main.mt" => "public function lib_fn(x: int) -> int:\n    return x\n",
  "standalone/external_bindings.mt" => <<~MT,
    external function puts(s: cstr) -> int

    public function say(message: str) -> void:
        puts(message as cstr)
  MT
  "standalone/uses_import.mt" => <<~MT,
    import std.vec as vec

    function main() -> int:
        var items = vec.Vec[int].create()
        items.push(7)
        let total = items.get(0) else:
            return 1
        print(total)
        items.release()
        return 0
    MT

  # A directory of source files (directory-operand expansion).
  "multi/a.mt" => "public function a() -> int:\n    return 1\n",
  "multi/b.mt" => "public function b() -> int:\n    return 2\n",
  "multi/empty/.keep" => "",
}.freeze

def materialize_fixtures
  FileUtils.rm_rf(FIXROOT)
  FIXTURES.each do |rel, content|
    path = File.join(FIXROOT, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end

# ── cases ───────────────────────────────────────────────────────────────────

def case_entry(name, argv, cwd: nil, stdin: nil)
  { name:, argv:, cwd: cwd || FIXROOT, stdin: }
end

def build_cases
  cases = []
  add = ->(name, argv, cwd: nil) { cases << case_entry(name, argv, cwd:) }

  # Version / help / dispatch
  add.call("version", ["version"])
  add.call("version-long", ["--version"])
  add.call("version-short", ["-V"])
  add.call("no-args", [])
  add.call("help", ["help"])
  add.call("help-long", ["--help"])
  add.call("help-short", ["-h"])
  add.call("help-topic", ["help", "build"])
  add.call("help-unknown-topic", ["help", "bogus"])
  add.call("unknown-command", ["bogus"])
  add.call("global-color-invalid", ["--color", "rainbow", "version"])
  add.call("include-path-toolchain", ["-I", ".", "toolchain", "doctor"])
  add.call("include-path-missing-value", ["-I"])

  # lex / parse / lower / emit-c on a standalone file
  add.call("lex", ["lex", "standalone/clean.mt"])
  add.call("lex-missing-file", ["lex", "standalone/nope.mt"])
  add.call("lex-directory", ["lex", "standalone"])
  add.call("parse", ["parse", "standalone/clean.mt"])
  add.call("parse-no-path", ["parse"])
  add.call("parse-syntax-error", ["parse", "standalone/syntax_error.mt"])
  add.call("lower", ["lower", "standalone/clean.mt", "-I", FIXROOT])
  add.call("emit-c", ["emit-c", "standalone/clean.mt", "-I", FIXROOT])
  add.call("emit-c-external", ["emit-c", "standalone/external_bindings.mt", "-I", FIXROOT])
  add.call("lower-directory", ["lower", "multi"])

  # check / lint / format / debug
  add.call("check-clean", ["check", "standalone/clean.mt"])
  add.call("check-sema-error", ["check", "standalone/sema_error.mt"])
  add.call("check-werror", ["check", "-Werror", "standalone/warns.mt"])
  add.call("lint-warns", ["lint", "standalone/warns.mt"])
  add.call("lint-clean", ["lint", "standalone/clean.mt"])
  add.call("lint-select", ["lint", "--select", "unused-local", "standalone/warns.mt"])
  add.call("lint-timings", ["lint", "--timings", "standalone/clean.mt"])
  add.call("format-check", ["format", "--check", "standalone/clean.mt"])
  add.call("format-conflict", ["format", "--check", "--write", "standalone/clean.mt"])
  add.call("format-preserve", ["format", "--preserve", "standalone/warns.mt"])
  add.call("debug-missing-file", ["debug", "standalone/nope.mt"])
  add.call("debug", ["debug", "standalone/clean.mt", "-I", FIXROOT])

  # Package targets
  add.call("build-package", ["build", "pkg", "-I", FIXROOT, "--no-cache"])
  add.call("build-package-from-root", ["build", "."], cwd: File.join(FIXROOT, "pkg"))
  add.call("build-standalone", ["build", "standalone/clean.mt", "-I", FIXROOT, "--no-cache"])
  add.call("build-no-main", ["build", "standalone/no_main.mt", "-I", FIXROOT, "--no-cache"])
  add.call("build-no-package-toml", ["build", "standalone", "-I", FIXROOT])
  add.call("build-broken-entry", ["build", "broken", "-I", FIXROOT])
  add.call("build-library", ["build", "libpkg", "-I", FIXROOT])
  add.call("build-with-import", ["build", "standalone/uses_import.mt", "-I", FIXROOT, "--no-cache"])
  add.call("build-unknown-option", ["build", "standalone/clean.mt", "--bogus"])
  add.call("build-missing-value", ["build", "standalone/clean.mt", "--cc"])
  add.call("build-kind-bogus", ["build", "standalone/clean.mt", "--kind", "bogus"])
  add.call("run-package", ["run", "pkg", "-I", FIXROOT, "--no-cache"])
  add.call("run-standalone", ["run", "standalone/clean.mt", "-I", FIXROOT, "--no-cache"])
  add.call("run-no-operand-no-package", ["run"], cwd: FIXROOT)
  add.call("run-no-operand-package", ["run", "-I", FIXROOT], cwd: File.join(FIXROOT, "pkg"))
  add.call("run-module-missing", ["run-module", "nope.module", "-I", FIXROOT])
  add.call("new-missing-name", ["new"])
  add.call("new-existing-dir", ["new", "pkg"], cwd: FIXROOT)
  add.call("completions-bogus", ["completions", "powershell"])
  add.call("test-missing-operand", ["test"])
  add.call("std-list", ["std", "list"])
  add.call("std-show-missing", ["std", "show", "no.such.module"])
  add.call("std-unknown-sub", ["std", "bogus"])
  add.call("cache-status", ["cache", "status"])
  add.call("toolchain-no-sub", ["toolchain"])
  add.call("snapshot-no-arg", ["snapshot"])

  cases
end

# ── comparison ──────────────────────────────────────────────────────────────

# Normalize machine- and fixture-specific text so a real divergence is not
# hidden behind temp paths.  Deliberately conservative: anything not listed here
# must match byte for byte (that includes the version string and help text).
def normalize(text, self_bin:)
  text = text.dup
  text = text.gsub(FIXROOT, "<FIXTURE>")
  text = text.gsub(ROOT, "<ROOT>")
  text = text.gsub(self_bin, "<SELF>")
  text = text.gsub(%r{/tmp/mtc_build_[A-Za-z0-9_.]+\.c}, "<TMPC>")
  text = text.gsub(%r{/tmp/[A-Za-z0-9_.-]*mtc[A-Za-z0-9_.-]*}, "<TMP>")
  text = text.gsub(/^built .*\[cached\]$/, "built <TARGET> [cached]")
  text
end

require "milk_tea"

if !quiet
  puts "host: ruby #{RUBY_VERSION} (milk_tea #{MilkTea::VERSION})"
  puts "self: #{self_bin} (built #{File.mtime(self_bin).strftime('%Y-%m-%d %H:%M')})"
end

materialize_fixtures

cases = build_cases
cases = cases.select { |c| c[:name].match?(Regexp.new(filter)) } if filter

results = { pass: [], fail: [], pending: [] }
kept = File.join(ROOT, "tmp", "cli-parity", "cases")

cases.each do |c|
  argv = c[:argv]
  gap = KNOWN_GAPS.any? { |re| argv.join(" ").match?(re) }
  name = c[:name]

  hout = StringIO.new
  herr = StringIO.new
  hrc =
    begin
      # The host CLI runs in-process, so its working directory must be set to the
      # case's cwd for relative operands to resolve like the spawned self-host.
      Dir.chdir(c[:cwd]) do
        MilkTea::CLI.start(argv.dup, out: hout, err: herr)
      end
    rescue StandardError => e
      herr.puts "harness exception: #{e.class}: #{e.message}"
      99
    end

  sout, serr, status = Open3.capture3(self_bin, *argv, chdir: c[:cwd])
  src = status.exitstatus

  expected = [normalize(hout.string, self_bin:), normalize(herr.string, self_bin:), hrc]
  actual   = [normalize(sout,        self_bin:), normalize(serr,        self_bin:), src]

  if expected == actual
    results[:pass] << name
  elsif gap
    results[:pending] << name
  else
    results[:fail] << [name, argv, expected, actual]
  end

  if keep
    dir = File.join(kept, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "host.out"), hout.string)
    File.write(File.join(dir, "host.err"), herr.string)
    File.write(File.join(dir, "host.rc"), hrc.to_s)
    File.write(File.join(dir, "self.out"), sout)
    File.write(File.join(dir, "self.err"), serr)
    File.write(File.join(dir, "self.rc"), src.to_s)
  end
end

FileUtils.rm_rf(File.join(ROOT, "tmp", "cli-parity", "fixtures")) unless keep

def first_diff(a, b)
  n = [a.length, b.length].min
  i = 0
  i += 1 while i < n && a[i] == b[i]
  i
end

def snippet(text, at)
  text[[at - 60, 0].max, 200].to_s.gsub(/\s+/, " ").strip
end

puts format("cases=%d match=%d differ=%d pending=%d",
            cases.length, results[:pass].length, results[:fail].length, results[:pending].length)

unless quiet
  results[:fail].take(max_diffs).each do |name, argv, expected, actual|
    puts "\nDIFF #{name}   argv: mtc #{argv.join(' ')}"
    %w[stdout stderr].each_with_index do |stream, i|
      next if expected[i] == actual[i]
      at = first_diff(expected[i], actual[i])
      puts "  #{stream} @#{at}"
      puts "    host: #{snippet(expected[i], at)}"
      puts "    self: #{snippet(actual[i], at)}"
    end
    puts "  exit: host=#{expected[2]} self=#{actual[2]}" if expected[2] != actual[2]
  end
  puts "\n... #{results[:fail].length - max_diffs} more differing case(s)" if results[:fail].length > max_diffs
  puts "pending (known gaps): #{results[:pending].join(', ')}" unless results[:pending].empty?
  puts "kept per-case outputs under tmp/cli-parity/cases/" if keep
end

exit(results[:fail].empty? ? 0 : 1)
