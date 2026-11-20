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
#   --record FILE    record the self's normalized results to FILE (host-free)
#   --expect FILE    replay FILE and fail on any difference (host-free)
#   -h, --help       show this message
#
# Exit status: 0 when every comparable case matches, 1 otherwise.  A case may be
# marked `pending:` while its subsystem is unimplemented; it is reported as
# PENDING and never counts as a failure.  A pending case that starts matching is
# a failure, forcing the flag's removal so a landed feature cannot silently
# regress back into pending.

require "fileutils"
require "open3"
require "stringio"
require "tmpdir"
require_relative "lib/golden"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

self_bin = nil
max_diffs = 25
keep = false
quiet = false
filter = nil
record_path = nil
expect_path = nil

argv = ARGV.dup
until argv.empty?
  a = argv.shift
  case a
  when "--self"      then self_bin = argv.shift
  when "--max-diffs" then max_diffs = argv.shift.to_i
  when "--keep"      then keep = true
  when "-q", "--quiet" then quiet = true
  when "-f", "--filter" then filter = argv.shift
  when "--record" then record_path = argv.shift
  when "--expect" then expect_path = argv.shift
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

record_path = File.expand_path(record_path, ROOT) if record_path
expect_path = File.expand_path(expect_path, ROOT) if expect_path
if record_path && expect_path
  warn "error: --record and --expect are mutually exclusive"
  exit 1
end
if record_path && filter
  warn "error: --record cannot be combined with --filter (it would truncate the fixture)"
  exit 1
end

newest_src = Dir.glob(File.join(ROOT, "projects", "mtc", "src", "**", "*.mt")).map { |f| File.mtime(f) }.max
warn "warning: #{self_bin} is older than the newest self-host source — rebuild it for accurate parity." if newest_src && File.mtime(self_bin) < newest_src

# ── fixtures ────────────────────────────────────────────────────────────────

FIXROOT = File.join(ROOT, "tmp", "cli-parity", "fixtures")

FIXTURES = {
  # A normal application package (with runtime assets for bundle/archive).
  "pkg/package.toml" => <<~TOML,
    [package]
    name = "pkg"
    version = "0.1.0"
    source_root = "src"

    [build]
    entry = "src/main.mt"
    assets = ["assets"]
  TOML
  "pkg/src/main.mt" => <<~'MT',
    import std.stdio as stdio

    public function add(a: int, b: int) -> int:
        return a + b

    function main() -> int:
        stdio.print_line(f"#{add(2, 3)}")
        return 0
    MT
  "pkg/src/unit.mt" => <<~'MT',
    @[test]
    function test_pkg_unit() -> void:
        expect(true)
    MT
  "pkg/assets/hello.txt" => "hello\n",
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
  "standalone/unicode.mt" => "## Café — a documented helper.\nfunction main() -> int:\n    return 0\n",
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

  # `mtc test` fixtures: passing/failing tests, a compile-fail fixture, death
  # tests (one aborts, one returns and must fail), the validation-error shapes,
  # a helper-only file and a file that does not parse (silently skipped).
  "testtree/pass.mt" => <<~'MT',
    @[test]
    function test_add() -> void:
        expect_eq(1 + 1, 2)

    @[test]
    function test_bool() -> void:
        expect(true)
    MT
  "testtree/fail.mt" => <<~'MT',
    @[test]
    function test_alpha() -> void:
        expect(false, "alpha <failed> & bad")

    @[test]
    function test_beta() -> void:
        expect_eq(1, 2)
    MT
  "testtree/compile_fail.mt" => <<~'MT',
    # expect-error: return type mismatch
    function bad_return() -> int:
        return "not an int"
    MT
  "testtree/death.mt" => <<~'MT',
    @[test]
    @[expect_fatal]
    function test_aborts() -> void:
        fatal("boom")

    @[test]
    @[expect_fatal]
    function test_returns() -> void:
        expect(true)
    MT
  "testtree/main_error.mt" => <<~'MT',
    @[test]
    function test_ok() -> void:
        expect(true)

    function main() -> int:
        return 0
    MT
  "testtree/param_error.mt" => <<~'MT',
    @[test]
    function test_param(x: int) -> void:
        expect(true)
    MT
  "testtree/sema_error.mt" => <<~'MT',
    @[test]
    function test_sema() -> void:
        let x: int = "not an int"
        expect(x == 0)
    MT
  "testtree/helper.mt" => "public function helper() -> int:\n    return 1\n",
  "testtree/parse_error.mt" => "function broken() -> int:\n    let x = 1 +\n    return 0\n",
  "testjobs/alpha.mt" => <<~'MT',
    @[test]
    function test_alpha() -> void:
        expect(true)
    MT
  "testjobs/beta.mt" => <<~'MT',
    @[test]
    function test_beta() -> void:
        expect(false, "beta")
    MT
  "testslow/slow.mt" => <<~'MT',
    import std.thread as thread

    @[test]
    function test_slow() -> void:
        thread.sleep_ms(1500)
        expect(true)
    MT

  # A tree whose discovery pass hits a lex error (the host lets it escape).
  "badlex/ok.mt" => <<~'MT',
    @[test]
    function test_ok() -> void:
        expect(true)
    MT
  "badlex/broken.mt" => "function broken( -> int:\n    return 0\n",

  # A C header for the bindgen CLI surface.
  "bindgen/probe.h" => <<~'H',
    #ifndef PROBE_H
    #define PROBE_H
    #define PROBE_VERSION 7
    typedef struct ProbePoint { int x; int y; } ProbePoint;
    typedef enum { PROBE_A = 0, PROBE_B = 1 } ProbeKind;
    int probe_add(int a, int b);
    unsigned long probe_count(const char *name);
    void probe_reset(void);
    #endif
  H

  # Empty directory for `lint --init` (the host writes `.mt-lint.yml` here).
  "initdir/.keep" => "",
}.freeze

def materialize_fixtures
  FileUtils.rm_rf(FIXROOT)
  FIXTURES.each do |rel, content|
    path = File.join(FIXROOT, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end

# Cases that mutate their working directory (`lint --init`, future `deps`
# writes) run host and self against the same pristine cwd: snapshot before the
# host, restore before the self, so each implementation sees the same state.
def snapshot_dir(path)
  backup = Dir.mktmpdir("cli-parity-case-")
  FileUtils.cp_r(File.join(path, "."), backup)
  backup
end

def restore_dir(path, backup)
  FileUtils.rm_rf(path)
  FileUtils.mkdir_p(path)
  FileUtils.cp_r(File.join(backup, "."), path)
end

# ── cases ───────────────────────────────────────────────────────────────────

def case_entry(name, argv, cwd: nil, stdin: nil, pending: false, isolate: false)
  { name:, argv:, cwd: cwd || FIXROOT, stdin:, pending:, isolate: }
end

def build_cases
  cases = []
  add = ->(name, argv, cwd: nil, pending: false, isolate: false) { cases << case_entry(name, argv, cwd:, pending:, isolate:) }
  pkg = File.join(FIXROOT, "pkg")

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
  add.call("parse-multiple", ["parse", "multi/a.mt", "multi/b.mt"])
  add.call("parse-directory", ["parse", "multi"])
  add.call("lower", ["lower", "standalone/clean.mt", "-I", FIXROOT])
  add.call("emit-c", ["emit-c", "standalone/clean.mt", "-I", FIXROOT])
  add.call("emit-c-external", ["emit-c", "standalone/external_bindings.mt", "-I", FIXROOT])
  add.call("emit-c-multiple", ["emit-c", "multi/a.mt", "multi/b.mt", "-I", FIXROOT])
  add.call("emit-c-directory", ["emit-c", "multi", "-I", FIXROOT])
  add.call("lower-directory", ["lower", "multi"])

  # check / lint / format / debug
  add.call("check-clean", ["check", "standalone/clean.mt"])
  add.call("check-sema-error", ["check", "standalone/sema_error.mt"])
  add.call("check-werror", ["check", "-Werror", "standalone/warns.mt"])
  add.call("check-platform", ["check", "--platform", "wasm", "standalone/clean.mt"])
  add.call("check-root", ["check", "--root", FIXROOT, "standalone/clean.mt"])
  add.call("lint-warns", ["lint", "standalone/warns.mt"])
  add.call("lint-clean", ["lint", "standalone/clean.mt"])
  add.call("lint-select", ["lint", "--select", "unused-local", "standalone/warns.mt"])
  add.call("lint-timings", ["lint", "--timings", "standalone/clean.mt"])
  add.call("lint-init", ["lint", "--init"], cwd: File.join(FIXROOT, "initdir"), isolate: true)
  add.call("lint-unknown-flag", ["lint", "--bogus", "standalone/clean.mt"])
  add.call("format-check", ["format", "--check", "standalone/clean.mt"])
  add.call("format-conflict", ["format", "--check", "--write", "standalone/clean.mt"])
  add.call("format-preserve", ["format", "--preserve", "standalone/warns.mt"])
  add.call("format-tidy", ["format", "--tidy", "standalone/warns.mt"])
  add.call("format-max-line-length", ["format", "--max-line-length", "20", "standalone/warns.mt"])
  add.call("format-directory-check", ["format", "--check", "multi"])
  add.call("format-multiple", ["format", "--check", "multi/a.mt", "multi/b.mt"])
  add.call("format-multiple-no-check", ["format", "multi/a.mt", "multi/b.mt"])
  add.call("format-directory-no-check", ["format", "multi"])
  add.call("format-parse-error", ["format", "standalone/syntax_error.mt"])
  add.call("format-unicode", ["format", "--canonical", "standalone/unicode.mt"])
  add.call("debug-missing-file", ["debug", "standalone/nope.mt"])
  add.call("debug", ["debug", "standalone/clean.mt", "-I", FIXROOT])

  # Package targets
  add.call("build-package", ["build", "pkg", "-I", FIXROOT, "--no-cache"])
  add.call("build-package-bundle", ["build", "pkg", "-I", FIXROOT, "--bundle", "--no-cache"])
  add.call("build-package-archive", ["build", "pkg", "-I", FIXROOT, "--archive", "--no-cache"])
  add.call("build-bundle-non-package", ["build", "standalone/clean.mt", "-I", FIXROOT, "--bundle"])
  add.call("build-package-clean", ["build", "pkg", "-I", FIXROOT, "--clean"])
  add.call("build-package-from-root", ["build", "."], cwd: File.join(FIXROOT, "pkg"))
  add.call("build-no-operand-package", ["build"], cwd: File.join(FIXROOT, "pkg"))
  add.call("build-no-operand-no-package", ["build"], cwd: FIXROOT)
  add.call("build-standalone", ["build", "standalone/clean.mt", "-I", FIXROOT, "--no-cache"])
  add.call("build-no-main", ["build", "standalone/no_main.mt", "-I", FIXROOT, "--no-cache"])
  add.call("build-no-package-toml", ["build", "standalone", "-I", FIXROOT])
  add.call("build-broken-entry", ["build", "broken", "-I", FIXROOT])
  add.call("build-library", ["build", "libpkg", "-I", FIXROOT])
  add.call("build-with-import", ["build", "standalone/uses_import.mt", "-I", FIXROOT, "--no-cache"])
  add.call("build-unknown-option", ["build", "standalone/clean.mt", "--bogus"])
  add.call("build-missing-value", ["build", "standalone/clean.mt", "--cc"])
  add.call("build-kind-bogus", ["build", "standalone/clean.mt", "--kind", "bogus"])
  add.call("build-locked", ["build", "pkg", "-I", FIXROOT, "--locked", "--no-cache"])
  add.call("build-frozen", ["build", "pkg", "-I", FIXROOT, "--frozen", "--no-cache"])
  add.call("build-wasm", ["build", "pkg", "-I", FIXROOT, "--platform", "wasm", "--no-cache"])
  add.call("run-package", ["run", "pkg", "-I", FIXROOT, "--no-cache"])
  add.call("run-standalone", ["run", "standalone/clean.mt", "-I", FIXROOT, "--no-cache"])
  add.call("run-no-operand-no-package", ["run"], cwd: FIXROOT)
  add.call("run-no-operand-package", ["run", "-I", FIXROOT], cwd: File.join(FIXROOT, "pkg"))
  add.call("run-no-operand-bare-package", ["run"], cwd: File.join(FIXROOT, "pkg"))
  add.call("run-module-missing", ["run-module", "nope.module", "-I", FIXROOT])
  add.call("run-bundle", ["run", "pkg", "-I", FIXROOT, "--bundle", "--no-cache"])
  add.call("run-archive", ["run", "pkg", "-I", FIXROOT, "--archive", "--no-cache"])
  add.call("new-missing-name", ["new"])
  add.call("new-existing-dir", ["new", "pkg"], cwd: FIXROOT)
  add.call("completions-bogus", ["completions", "powershell"])
  add.call("test-missing-operand", ["test"])
  # `mtc test`: file/directory operands, machine formats, filters, death tests,
  # validation errors and the build-error shapes.
  add.call("test-file-pass", ["test", "testtree/pass.mt"])
  add.call("test-file-fail", ["test", "testtree/fail.mt"])
  add.call("test-file-fail-tap", ["test", "testtree/fail.mt", "--format", "tap"])
  add.call("test-file-fail-junit", ["test", "testtree/fail.mt", "--format", "junit"])
  add.call("test-compile-fail-file", ["test", "testtree/compile_fail.mt"])
  add.call("test-compile-fail-tap", ["test", "testtree/compile_fail.mt", "--format", "tap"])
  add.call("test-file-name-filter", ["test", "testtree/pass.mt", "-n", "test_add"])
  add.call("test-file-name-filter-none", ["test", "testtree/pass.mt", "-n", "zzz"])
  add.call("test-no-tests-file", ["test", "testtree/helper.mt"])
  add.call("test-two-operands", ["test", "testtree/pass.mt", "testtree/helper.mt"])
  add.call("test-dashdash", ["test", "--", "testtree/pass.mt"])
  add.call("test-main-error-human", ["test", "testtree/main_error.mt"])
  add.call("test-main-error-tap", ["test", "testtree/main_error.mt", "--format", "tap"])
  add.call("test-param-error-tap", ["test", "testtree/param_error.mt", "--format", "tap"])
  add.call("test-sema-error-human", ["test", "testtree/sema_error.mt"])
  add.call("test-sema-error-tap", ["test", "testtree/sema_error.mt", "--format", "tap"])
  add.call("test-death-human", ["test", "testtree/death.mt"])
  add.call("test-death-tap", ["test", "testtree/death.mt", "--format", "tap"])
  add.call("test-death-junit", ["test", "testtree/death.mt", "--format", "junit"])
  add.call("test-dir-human", ["test", "testtree"])
  add.call("test-dir-tap", ["test", "testtree", "--format", "tap"])
  add.call("test-dir-junit", ["test", "testtree", "--format", "junit"])
  add.call("test-dir-name-filter", ["test", "testtree", "-n", "test_add"])
  add.call("test-dir-name-filter-none", ["test", "testtree", "-n", "zzz"])
  add.call("test-dir-filter-compile-fail", ["test", "testtree", "-n", "compile_fail"])
  add.call("test-lex-error-dir", ["test", "badlex"])
  add.call("test-lex-error-dir-tap", ["test", "badlex", "--format", "tap"])
  add.call("test-jobs-two", ["test", "testjobs", "--jobs", "2"])
  add.call("test-jobs-two-tap", ["test", "testjobs", "--jobs", "2", "--format", "tap"])
  add.call("test-timeout", ["test", "testslow", "--timeout", "1"])
  add.call("test-mem-cap", ["test", "testtree/pass.mt", "-n", "test_add", "--mem", "1"])
  add.call("test-sanitize", ["test", "testtree/pass.mt", "-n", "test_add", "--sanitize"])
  add.call("test-timeout-zero", ["test", "testtree/pass.mt", "--timeout", "0"])
  add.call("test-mem-zero", ["test", "testtree/pass.mt", "--mem", "0"])
  add.call("test-jobs-zero", ["test", "testtree/pass.mt", "--jobs", "0"])
  add.call("test-name-missing-value", ["test", "testtree/pass.mt", "-n"])
  add.call("test-format-invalid", ["test", "testtree/pass.mt", "--format", "bogus"])
  add.call("test-flag-precedence", ["test", "--bogus", "--timeout", "0", "testtree/pass.mt"])
  add.call("test-frozen-non-package", ["test", "--frozen", "testtree/pass.mt"])
  add.call("test-frozen-package", ["test", "--frozen"], cwd: pkg)
  add.call("test-locked-package", ["test", "--locked"], cwd: pkg)
  add.call("test-package-no-operand", ["test"], cwd: pkg)
  add.call("std-list", ["std", "list"])
  add.call("std-show-missing", ["std", "show", "no.such.module"])
  add.call("std-unknown-sub", ["std", "bogus"])
  add.call("cache-status", ["cache", "status"])
  add.call("toolchain-no-sub", ["toolchain"])
  add.call("toolchain-doctor", ["toolchain", "doctor"])
  add.call("deps-no-sub", ["deps"])
  add.call("deps-unknown-sub", ["deps", "bogus"])
  add.call("deps-tree", ["deps", "tree"], cwd: pkg)
  add.call("deps-lock-check", ["deps", "lock", "--check"], cwd: pkg)
  add.call("deps-fetch", ["deps", "fetch"], cwd: pkg)
  add.call("snapshot-no-arg", ["snapshot"])

  # Session-73 second batch: global extraction, resolution flags, per-command
  # operand models, empty/missing operands, and the remaining command surfaces.
  add.call("global-color-missing", ["--color"])
  add.call("global-color-before-command", ["--color", "version"])
  add.call("global-include-long-missing", ["--include-path"])
  add.call("global-include-before-global", ["-I", "-q", "lex", "standalone/clean.mt"])
  add.call("global-include-long-before-global", ["--include-path", "-q", "lex", "standalone/clean.mt"])

  add.call("lex-sexpr", ["lex", "standalone/clean.mt", "--sexpr"])
  add.call("lex-two-operands", ["lex", "standalone/clean.mt", "standalone/warns.mt"])
  add.call("lex-option-as-path", ["lex", "--bogus"])
  add.call("lex-dashdash", ["lex", "--", "standalone/clean.mt"])

  add.call("parse-locked", ["parse", "standalone/clean.mt", "--locked"])
  add.call("parse-frozen-file", ["parse", "standalone/clean.mt", "--frozen"])
  add.call("parse-werror", ["parse", "-Werror", "standalone/clean.mt"])
  add.call("parse-unexpected-flag", ["parse", "--bogus", "standalone/clean.mt"])
  add.call("parse-missing-file", ["parse", "standalone/nope.mt"])
  add.call("parse-root-flag", ["parse", "--root", ".", "standalone/clean.mt"])

  add.call("lower-locked", ["lower", "standalone/clean.mt", "--locked"])
  add.call("lower-frozen-file", ["lower", "standalone/clean.mt", "--frozen"])
  add.call("lower-werror", ["lower", "-Werror", "standalone/clean.mt"])
  add.call("lower-multiple", ["lower", "multi/a.mt", "multi/b.mt"])
  add.call("lower-unexpected-flag", ["lower", "--bogus", "standalone/clean.mt"])
  add.call("lower-missing-file", ["lower", "standalone/nope.mt"])
  add.call("lower-empty-dir", ["lower", "multi/empty"])

  add.call("emit-c-locked", ["emit-c", "standalone/clean.mt", "--locked"])
  add.call("emit-c-frozen-file", ["emit-c", "standalone/clean.mt", "--frozen"])
  add.call("emit-c-werror", ["emit-c", "-Werror", "standalone/clean.mt"])
  add.call("emit-c-missing-file", ["emit-c", "standalone/nope.mt"])

  add.call("check-frozen-file", ["check", "standalone/clean.mt", "--frozen"])
  add.call("check-frozen-package", ["check", "--frozen"], cwd: pkg)
  add.call("check-locked-package", ["check", "--locked"], cwd: pkg)
  add.call("check-empty-dir", ["check", "multi/empty"])
  add.call("check-missing-file", ["check", "standalone/nope.mt"])

  add.call("lint-frozen-file", ["lint", "standalone/clean.mt", "--frozen"])
  add.call("lint-frozen-package", ["lint", "--frozen"], cwd: pkg)
  add.call("lint-locked-package", ["lint", "--locked"], cwd: pkg)
  add.call("lint-empty-dir", ["lint", "multi/empty"])
  add.call("lint-missing-file", ["lint", "standalone/nope.mt"])

  add.call("debug-werror", ["debug", "-Werror", "standalone/clean.mt"])
  add.call("debug-extra-operand", ["debug", "standalone/clean.mt", "standalone/warns.mt"])
  add.call("debug-empty-dir", ["debug", "multi/empty"])
  add.call("debug-dashdash", ["debug", "--", "standalone/clean.mt"])

  add.call("build-profile-missing", ["build", "standalone/clean.mt", "--profile"])
  add.call("build-output-missing", ["build", "standalone/clean.mt", "-o"])
  add.call("build-keep-c-missing", ["build", "standalone/clean.mt", "--keep-c"])
  add.call("build-platform-missing", ["build", "standalone/clean.mt", "--platform"])
  add.call("build-profile-invalid", ["build", "standalone/clean.mt", "--profile", "bogus"])
  add.call("build-clean-no-package", ["build", "--clean"])
  add.call("run-profile-missing", ["run", "standalone/clean.mt", "--profile"])
  add.call("run-profile-invalid", ["run", "standalone/clean.mt", "--profile", "bogus"])
  add.call("run-missing-file", ["run", "standalone/nope.mt"])
  add.call("run-module-no-name", ["run-module"])
  add.call("run-module-not-found", ["run-module", "nope.module"])
  add.call("run-module-unknown-option", ["run-module", "--bogus"])
  add.call("run-module-dashdash", ["run-module", "--", "nope.module"])

  add.call("completions-bash", ["completions", "bash"])
  add.call("completions-zsh", ["completions", "zsh"])
  add.call("completions-fish", ["completions", "fish"])

  add.call("std-list-json", ["std", "list", "--json"])
  add.call("std-show-arena", ["std", "show", "mem.arena"])
  add.call("std-list-unknown-option", ["std", "list", "--bogus"])
  add.call("std-no-sub", ["std"])

  add.call("snapshot-theme-missing", ["snapshot", "standalone/clean.mt", "--theme", "nope.json"])
  add.call("snapshot-missing-input", ["snapshot", "standalone/nope.mt"])
  add.call("snapshot-theme-no-value", ["snapshot", "standalone/clean.mt", "--theme"])
  add.call("snapshot-output-no-value", ["snapshot", "standalone/clean.mt", "-o"])

  add.call("cache-no-sub", ["cache"])
  add.call("cache-unknown-sub", ["cache", "bogus"])
  add.call("cache-status-extra", ["cache", "status", "extra"])

  add.call("lsp-invalid-log-level", ["lsp", "--log-level", "bogus"])
  add.call("lsp-missing-log-level", ["lsp", "--log-level"])
  add.call("lsp-unknown-option", ["lsp", "--bogus"])
  add.call("lsp-unexpected-arg", ["lsp", "extra"])
  add.call("lsp-equals-invalid", ["lsp", "--log-level=bogus"])

  add.call("dap-adapter-not-found", ["dap", "--adapter-path", "nope.rb"])
  add.call("dap-adapter-no-value", ["dap", "--adapter-path"])
  add.call("dap-unknown-option", ["dap", "--bogus"])
  add.call("dap-unexpected-arg", ["dap", "extra"])

  add.call("bindgen-stdout", ["bindgen", "probe", "bindgen/probe.h"])
  add.call("bindgen-link", ["bindgen", "probe", "bindgen/probe.h", "--link", "probe"])
  add.call("bindgen-include", ["bindgen", "probe", "bindgen/probe.h", "--include", "stdio.h"])
  add.call("bindgen-missing-args", ["bindgen"])
  add.call("bindgen-missing-header", ["bindgen", "probe"])
  add.call("bindgen-unknown-option", ["bindgen", "probe", "bindgen/probe.h", "--bogus"])
  add.call("bindgen-output-missing-value", ["bindgen", "probe", "bindgen/probe.h", "-o"])
  add.call("bindgen-clang-missing", ["bindgen", "probe", "bindgen/probe.h", "--clang", "/nonexistent/clang"])

  add.call("deps-add-missing-path", ["deps", "add"], cwd: FIXROOT)
  add.call("deps-add-missing-name", ["deps", "add"], cwd: pkg)
  add.call("deps-remove-missing-name", ["deps", "remove"], cwd: pkg)
  add.call("deps-remove-extra", ["deps", "remove", "foo", "extra"], cwd: pkg)
  add.call("deps-fetch-unknown-option", ["deps", "fetch", "--bogus"])
  add.call("deps-update-missing-path", ["deps", "update"], cwd: FIXROOT)

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
  # `mtc test` synthesizes `<source dir>/__mt_test_runner_<pid>.mt` plus its
  # binary.  The pid is process-local, and the binary's directory is not part
  # of the contract (the host builds it in `Dir.tmpdir`, the self beside the
  # source, which is visible only in a spawn-failure message); the failure
  # text, streams and status still compare.
  text = text.gsub(%r{\S*/__mt_test_runner_\d+}, "<RUNNER>")
  text = text.gsub(/^built .*\[cached\]$/, "built <TARGET> [cached]")
  # `--timings` values (and phase breakdowns) are wall-clock measurements and
  # differ between any two runs; compare the report's structure only.
  text = text.gsub(/^(\s+\S+: )[\d.]+ms(?:\s+\(.*\))?$/, '\1<MS>')
  text = text.gsub(/^Total: [\d.]+ms$/, 'Total: <MS>')
  # `debug`'s bindings section keys its site rows by Ruby `object_id` (the
  # loader's node identities) — process-local allocation addresses with no
  # cross-implementation meaning.  The binding ids and the row order, which are
  # the observable resolution, still compare.
  text = text.gsub(/^(\s+obj )\d+( → binding_id: \d+)$/, '\1<NODE>\2')
  text
end

materialize_fixtures

cases = build_cases
cases = cases.select { |c| c[:name].match?(Regexp.new(filter)) } if filter

# Recorded mode: the self is the only compiler consulted.  The fixture is the
# post-retirement oracle, so `pending:` cases are recorded like any other (the
# pending flag describes host parity, not self behavior).
if record_path || expect_path
  # Build cases report `[cached]` on a warm cache, so record and replay both
  # need the same cache history.  An empty per-run root makes every run cold
  # and keeps the user's real cache untouched.
  cache_root = File.join(ROOT, "tmp", "cli-parity", "cache")
  FileUtils.rm_rf(cache_root)
  FileUtils.mkdir_p(cache_root)

  actual = {}
  cases.each do |c|
    isolate_backup = c[:isolate] ? snapshot_dir(c[:cwd]) : nil
    sout, serr, status = Open3.capture3({ "XDG_CACHE_HOME" => cache_root }, self_bin, *c[:argv], chdir: c[:cwd])
    restore_dir(c[:cwd], isolate_backup) if isolate_backup
    FileUtils.rm_rf(isolate_backup) if isolate_backup
    # Whether a build reports `[cached]` depends on artifacts left by earlier
    # cases in the sequence, so it is not a stable golden property (the live
    # parity mode still compares it).  Collapse the whole line.  `cache status`
    # prints a byte total that varies by a tenth of a KiB between runs, so keep
    # the counts and normalize the size.
    recorded_stdout = normalize(sout, self_bin: self_bin)
                        .gsub(/^built .*$/, "built <TARGET>")
                        .gsub(/^(cache\s+\d+ programs, \d+ binaries)\s+\([^)]*\)$/, '\1 (<SIZE>)')
    actual[c[:name]] = {
      "stdout" => recorded_stdout,
      "stderr" => normalize(serr, self_bin: self_bin),
      "rc" => status.exitstatus,
    }
  end

  if record_path
    Golden.write(record_path, "cli_parity", actual)
    puts "recorded #{actual.length} case(s) -> #{record_path}" unless quiet
    exit 0
  end

  expected = Golden.read(expect_path, "cli_parity")
  expected = expected.select { |name, _| actual.key?(name) } if filter
  diffs = Golden.diff(expected, actual)
  puts format("cases=%d golden=%d differ=%d", actual.length, expected.length, diffs.length)
  diffs.first(max_diffs).each { |line| puts "  #{line}" }
  exit(diffs.empty? ? 0 : 1)
end

require "milk_tea"

if !quiet
  puts "host: ruby #{RUBY_VERSION} (milk_tea #{MilkTea::VERSION})"
  puts "self: #{self_bin} (built #{File.mtime(self_bin).strftime('%Y-%m-%d %H:%M')})"
end

results = { pass: [], fail: [], pending: [] }
kept = File.join(ROOT, "tmp", "cli-parity", "cases")

cases.each do |c|
  argv = c[:argv]
  name = c[:name]
  isolate_backup = c[:isolate] ? snapshot_dir(c[:cwd]) : nil

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

  restore_dir(c[:cwd], isolate_backup) if isolate_backup

  sout, serr, status = Open3.capture3(self_bin, *argv, chdir: c[:cwd])
  src = status.exitstatus

  expected = [normalize(hout.string, self_bin:), normalize(herr.string, self_bin:), hrc]
  actual   = [normalize(sout,        self_bin:), normalize(serr,        self_bin:), src]

  if expected == actual
    if c[:pending]
      results[:fail] << [name, argv, expected, actual,
                         "pending case now matches; remove pending:"]
    else
      results[:pass] << name
    end
  elsif c[:pending]
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

  FileUtils.rm_rf(isolate_backup) if isolate_backup
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
  results[:fail].take(max_diffs).each do |name, argv, expected, actual, note|
    puts "\nDIFF #{name}   argv: mtc #{argv.join(' ')}"
    puts "  note: #{note}" if note
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
