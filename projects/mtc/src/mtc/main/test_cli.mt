## `mtc test` — the test runner, death tests, compile-fail fixtures, and the
## human/TAP/JUnit reporters.  Extracted from main.mt.

import std.fs as fs
import std.libuv as libuv
import std.mem.heap as heap_mod
import std.path as path_ops
import std.process as process
import std.str as str
import std.string as string
import std.stdio as stdio
import std.vec as vec

import mtc.build as build_driver
import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver
import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lowering.lowering as lowering
import mtc.lsp.debug_text as debug_text
import mtc.packages.lock as package_lock
import mtc.cli_help as cli_help
import mtc.main as main


## Machine-readable test output selection.
enum OutputFormat: ubyte
    human = 0
    tap   = 1
    junit = 2


enum TestStatus: ubyte
    ok   = 0
    skip = 1
    fail = 2


## Why a test file's run stopped.  `build_error` is distinct from a test
## failure: the host lets that exception escape the file (so a file operand
## renders one diagnostic line and emits no machine output, while a directory
## run reports the file-level `(build error)` row and continues).
enum TestFileOutcome: ubyte
    ok          = 0
    test_failed = 1
    build_error = 2


## A single parsed test outcome for machine-readable (TAP/JUnit) emission.
struct TestResult:
    name: string.String
    status: TestStatus
    detail: string.String
    has_detail: bool


extending TestResult:
    editable function release() -> void:
        this.name.release()
        this.detail.release()


## Parse one runner output line (`ok   - name`, `skip - name: detail`,
## `FAIL - name: detail`) into a TestResult; none for unrelated lines.
function parse_runner_line(line: str) -> Option[TestResult]:
    var status = TestStatus.ok
    if line.starts_with("ok   - "):
        status = TestStatus.ok
    else if line.starts_with("skip - "):
        status = TestStatus.skip
    else if line.starts_with("FAIL - "):
        status = TestStatus.fail
    else:
        return Option[TestResult].none

    let rest = line.slice(7, line.len - 7)
    if status == TestStatus.ok:
        return Option[TestResult].some(value= TestResult(
            name = string.String.from_str(rest),
            status = status,
            detail = string.String.create(),
            has_detail = false,
        ))

    match rest.find_substring(": "):
        Option.some as idx:
            let name_text = rest.slice(0, idx.value)
            let detail_text = rest.slice(idx.value + 2, rest.len - idx.value - 2)
            return Option[TestResult].some(value= TestResult(
                name = string.String.from_str(name_text),
                status = status,
                detail = string.String.from_str(detail_text),
                has_detail = true,
            ))
        Option.none:
            return Option[TestResult].some(value= TestResult(
                name = string.String.from_str(rest),
                status = status,
                detail = string.String.create(),
                has_detail = false,
            ))


## Parse runner stdout, appending each `ok/skip/FAIL` line to `results`.
function collect_runner_results(output: str, results: ref[vec.Vec[TestResult]]) -> void:
    var start: ptr_uint = 0
    var pos: ptr_uint = 0
    while pos <= output.len:
        if pos == output.len or output.byte_at(pos) == 10:
            if pos > start:
                let line = output.slice(start, pos - start)
                match parse_runner_line(line):
                    Option.some as parsed:
                        results.push(parsed.value)
                    Option.none:
                        pass
            start = pos + 1
        pos += 1


## Escape the five XML metacharacters for JUnit attribute/text content.
function xml_escape(value: str) -> string.String:
    var result = string.String.with_capacity(value.len)
    var i: ptr_uint = 0
    while i < value.len:
        let b = value.byte_at(i)
        if b == '&':
            result.append("&amp;")
        else if b == '<':
            result.append("&lt;")
        else if b == '>':
            result.append("&gt;")
        else if b == '"':
            result.append("&quot;")
        else:
            result.push_byte(b)
        i += 1
    return result


function emit_tap(results: ref[vec.Vec[TestResult]]) -> void:
    stdio.print_line("TAP version 13")
    stdio.print_format(c"1..%d\n", int<-(results.len()))
    var i: ptr_uint = 0
    while i < results.len():
        let rp = results.get(i) else:
            break
        let number = int<-(i + 1)
        unsafe:
            let r = read(rp)
            let name = r.name.as_str()
            match r.status:
                TestStatus.ok:
                    stdio.print_format(c"ok %d - %.*s\n", number, int<-(name.len), name.data)
                TestStatus.skip:
                    if r.has_detail:
                        let d = r.detail.as_str()
                        stdio.print_format(c"ok %d - %.*s # SKIP %.*s\n", number, int<-(name.len), name.data, int<-(d.len), d.data)
                    else:
                        stdio.print_format(c"ok %d - %.*s # SKIP\n", number, int<-(name.len), name.data)
                TestStatus.fail:
                    stdio.print_format(c"not ok %d - %.*s\n", number, int<-(name.len), name.data)
                    if r.has_detail:
                        let d = r.detail.as_str()
                        stdio.print_line("  ---")
                        stdio.print_format(c"  message: %.*s\n", int<-(d.len), d.data)
                        stdio.print_line("  ...")
        i += 1


function emit_junit(results: ref[vec.Vec[TestResult]]) -> void:
    var failures: ptr_uint = 0
    var skipped: ptr_uint = 0
    var ci: ptr_uint = 0
    while ci < results.len():
        let rp = results.get(ci) else:
            break
        unsafe:
            match read(rp).status:
                TestStatus.fail:
                    failures += 1
                TestStatus.skip:
                    skipped += 1
                TestStatus.ok:
                    pass
        ci += 1

    let total = int<-(results.len())
    stdio.print_line("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    stdio.print_format(c"<testsuites tests=\"%d\" failures=\"%d\" skipped=\"%d\">\n", total, int<-failures, int<-skipped)
    stdio.print_format(c"  <testsuite name=\"mtc test\" tests=\"%d\" failures=\"%d\" skipped=\"%d\">\n", total, int<-failures, int<-skipped)
    var i: ptr_uint = 0
    while i < results.len():
        let rp = results.get(i) else:
            break
        unsafe:
            let r = read(rp)
            var name_escaped = xml_escape(r.name.as_str())
            let name = name_escaped.as_str()
            match r.status:
                TestStatus.ok:
                    stdio.print_format(c"    <testcase name=\"%.*s\"/>\n", int<-(name.len), name.data)
                TestStatus.skip:
                    stdio.print_format(c"    <testcase name=\"%.*s\"><skipped/></testcase>\n", int<-(name.len), name.data)
                TestStatus.fail:
                    var detail_escaped = if r.has_detail: xml_escape(r.detail.as_str()) else: string.String.from_str("failed")
                    let detail = detail_escaped.as_str()
                    stdio.print_format(
                        c"    <testcase name=\"%.*s\"><failure message=\"%.*s\"/></testcase>\n",
                        int<-(name.len), name.data,
                        int<-(detail.len), detail.data,
                    )
                    detail_escaped.release()
            name_escaped.release()
        i += 1
    stdio.print_line("  </testsuite>")
    stdio.print_line("</testsuites>")


## Parse one `# expect-error: <text>` directive line, returning the expected
## diagnostic substring (a borrowed slice of the line).  None for other lines.
function parse_expect_error_line(line: str) -> Option[str]:
    let trimmed = line.trim_ascii_whitespace()
    if not trimmed.starts_with("#"):
        return Option[str].none
    let after_hash = trimmed.slice(1, trimmed.len - 1).trim_ascii_whitespace()
    if not after_hash.starts_with("expect-error:"):
        return Option[str].none
    let marker_len = 13z
    return Option[str].some(value= after_hash.slice(marker_len, after_hash.len - marker_len).trim_ascii_whitespace())


## Collect every `# expect-error:` expectation in `source` into `out` (borrowed
## slices of `source`).  The presence of any expectation marks a compile-fail
## fixture.
function collect_expect_errors(source: str, sink: ref[vec.Vec[str]]) -> void:
    var start: ptr_uint = 0
    var pos: ptr_uint = 0
    while pos <= source.len:
        if pos == source.len or source.byte_at(pos) == 10:
            if pos > start:
                let line = source.slice(start, pos - start)
                match parse_expect_error_line(line):
                    Option.some as expected:
                        sink.push(expected.value)
                    Option.none:
                        pass
            start = pos + 1
        pos += 1


function is_compile_fail_fixture(source: str) -> bool:
    var expectations = vec.Vec[str].create()
    defer: expectations.release()
    collect_expect_errors(source, ref_of(expectations))
    return expectations.len() > 0


## Run a compile-fail fixture: type-check the file and verify every
## `# expect-error:` substring appears in some error diagnostic.  Returns 0 when
## the expectations are satisfied and 1 otherwise.
function run_compile_fail_file(file_path: str, source_text: str, options: TestRunOptions, results: ref[vec.Vec[TestResult]]) -> int:
    var expected = vec.Vec[str].create()
    defer: expected.release()
    collect_expect_errors(source_text, ref_of(expected))

    var eff_roots = vec.Vec[str].create()
    defer: eff_roots.release()
    var ri: ptr_uint = 0
    while ri < options.roots.len:
        unsafe:
            eff_roots.push(read(options.roots.data + ri))
        ri += 1
    eff_roots.push(path_ops.dirname(file_path))

    # Fixture files run one after another, so the whole check is region-scoped:
    # the program's AST, analyses and diagnostics are reclaimed before the next
    # fixture instead of accumulating for the length of the run.  A single-file
    # run keeps the plain heap: a region's bump allocation is a net loss there.
    if options.scoped:
        var fixture_region = heap_mod.create_region()
        let previous_region = heap_mod.begin_region(ptr_of(fixture_region))
        let verdict = check_compile_fail_expectations(file_path, expected.as_span(), eff_roots.as_span(), options.platform)
        heap_mod.end_region(previous_region)
        fixture_region.release_all()
        return report_compile_fail_verdict(file_path, expected.as_span(), verdict, options, results)
    let verdict = check_compile_fail_expectations(file_path, expected.as_span(), eff_roots.as_span(), options.platform)
    return report_compile_fail_verdict(file_path, expected.as_span(), verdict, options, results)


## Print or record one compile-fail fixture's verdict.  The reason is rebuilt
## here from `unmatched_index`, outside any per-file region, so nothing points
## into freed memory.
function report_compile_fail_verdict(file_path: str, expected: span[str], verdict: CompileFailVerdict, options: TestRunOptions, results: ref[vec.Vec[TestResult]]) -> int:
    var passed = verdict.outcome == CompileFailOutcome.passed
    var fail_reason = string.String.create()
    defer: fail_reason.release()
    match verdict.outcome:
        CompileFailOutcome.passed:
            pass
        CompileFailOutcome.compiled_cleanly:
            fail_reason.append("expected a compile error, but it compiled cleanly")
        CompileFailOutcome.unmatched:
            let exp = unsafe: read(expected.data + verdict.unmatched_index)
            fail_reason.append("no diagnostic matched ")
            var inspected = debug_text.ruby_inspect(exp)
            fail_reason.append(inspected.as_str())
            inspected.release()

    let machine = options.format != OutputFormat.human
    if machine:
        var name = string.String.from_str(file_path)
        name.append(" (compile-fail)")
        if passed:
            results.push(TestResult(name = name, status = TestStatus.ok, detail = string.String.create(), has_detail = false))
        else:
            results.push(TestResult(name = name, status = TestStatus.fail, detail = string.String.from_str(fail_reason.as_str()), has_detail = true))
    else:
        if passed:
            stdio.print_format(c"ok   - %.*s (compile-fail)\n", int<-(file_path.len), file_path.data)
        else:
            let reason = fail_reason.as_str()
            stdio.print_format(
                c"FAIL - %.*s (compile-fail): %.*s\n",
                int<-(file_path.len), file_path.data,
                int<-(reason.len), reason.data,
            )

    if passed:
        return 0
    return 1


## One compile-fail fixture's verdict.  It carries no borrowed text: the reason
## is rebuilt by the caller from `unmatched_index`, so nothing points into the
## per-file region that is freed before the caller reads it.
enum CompileFailOutcome: ubyte
    passed = 0
    compiled_cleanly = 1
    unmatched = 2


struct CompileFailVerdict:
    outcome: CompileFailOutcome
    unmatched_index: ptr_uint


## Type-check one fixture and compare its error diagnostics against the
## fixture's `# expect-error:` list.  Runs inside the caller's region, so the
## loaded program is reclaimed with it; only the outcome crosses the boundary.
function check_compile_fail_expectations(file_path: str, expected: span[str], eff_roots: span[str], platform: resolver.Platform) -> CompileFailVerdict:
    var program = loader.check_program(file_path, eff_roots, platform)
    defer: program.release()

    var error_msgs = vec.Vec[str].create()
    defer: error_msgs.release()
    var di: ptr_uint = 0
    while di < program.diagnostics.len():
        let dp = program.diagnostics.get(di) else:
            break
        unsafe:
            if read(dp).severity == "error":
                error_msgs.push(read(dp).message.as_str())
        di += 1

    if error_msgs.len() == 0:
        return CompileFailVerdict(outcome = CompileFailOutcome.compiled_cleanly, unmatched_index = 0)
    var ei: ptr_uint = 0
    while ei < expected.len:
        let exp = unsafe: read(expected.data + ei)
        var found = false
        var mi: ptr_uint = 0
        while mi < error_msgs.len():
            let mp = error_msgs.get(mi) else:
                break
            if unsafe: read(mp).contains_substring(exp):
                found = true
                break
            mi += 1
        if not found:
            return CompileFailVerdict(outcome = CompileFailOutcome.unmatched, unmatched_index = ei)
        ei += 1
    return CompileFailVerdict(outcome = CompileFailOutcome.passed, unmatched_index = 0)


## Runner settings shared by the directory and single-file paths.
struct TestRunOptions:
    roots: span[str]
    name_filter: Option[str]
    timeout_seconds: ptr_uint
    memory_mb: ptr_uint
    jobs: ptr_uint
    sanitize: bool
    format: OutputFormat
    cc: str
    profile: str
    platform: resolver.Platform
    locked: bool
    ## True when the run covers more than one file: compile-fail fixtures then
    ## compile inside a per-file heap region (a single-file run keeps the plain
    ## heap, where a region's bump allocation only inflates the peak).
    scoped: bool


## How a discovered test file runs (`TestFileKind.lex_error` aborts the run:
## the host's discovery rescues parse errors but lets a LexError escape).
enum TestFileKind: ubyte
    none = 0
    test = 1
    compile_fail = 2
    lex_error = 3


## Test-limit flags extracted before the build-option pass.
struct TestLimitFlags:
    name_filter: Option[str]
    timeout_seconds: ptr_uint
    memory_mb: ptr_uint
    jobs: ptr_uint
    format: OutputFormat
    sanitize: bool


## Build-pass flags consumed by the test runner.
struct TestBuildFlags:
    cc: str
    profile: str
    platform: resolver.Platform
    locked: bool
    frozen: bool


## The host extracts the test-limit flags first (`extract_test_limit_flags!`),
## so an invalid --timeout/--mem/--jobs/-n/--format is reported before an
## unknown build option even when it appears later on the command line.
function parse_test_limit_flags(args: span[str], remaining: ref[vec.Vec[str]]) -> Option[TestLimitFlags]:
    var parsed = TestLimitFlags(
        name_filter = Option[str].none,
        timeout_seconds = 30,
        memory_mb = 1024,
        jobs = 1,
        format = OutputFormat.human,
        sanitize = false,
    )
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "-n" or arg == "--name":
            if ai + 1 >= args.len:
                main.eprint_line("-n requires a name substring")
                return Option[TestLimitFlags].none
            parsed.name_filter = Option[str].some(value= args[ai + 1])
            ai += 2
            continue
        if arg == "--timeout":
            if ai + 1 >= args.len:
                main.eprint_line("--timeout requires a positive integer (seconds)")
                return Option[TestLimitFlags].none
            let seconds = main.parse_positive_int(args[ai + 1]) else:
                main.eprint_line("--timeout requires a positive integer (seconds)")
                return Option[TestLimitFlags].none
            parsed.timeout_seconds = seconds
            ai += 2
            continue
        if arg == "--mem":
            if ai + 1 >= args.len:
                main.eprint_line("--mem requires a positive integer (megabytes)")
                return Option[TestLimitFlags].none
            let megabytes = main.parse_positive_int(args[ai + 1]) else:
                main.eprint_line("--mem requires a positive integer (megabytes)")
                return Option[TestLimitFlags].none
            parsed.memory_mb = megabytes
            ai += 2
            continue
        if arg == "--jobs":
            if ai + 1 >= args.len:
                main.eprint_line("--jobs requires a positive integer")
                return Option[TestLimitFlags].none
            let count = main.parse_positive_int(args[ai + 1]) else:
                main.eprint_line("--jobs requires a positive integer")
                return Option[TestLimitFlags].none
            parsed.jobs = count
            ai += 2
            continue
        if arg == "--format":
            if ai + 1 >= args.len:
                main.eprint_line("--format must be human, tap, or junit")
                return Option[TestLimitFlags].none
            let fmt_name = args[ai + 1]
            if fmt_name == "human":
                parsed.format = OutputFormat.human
            else if fmt_name == "tap":
                parsed.format = OutputFormat.tap
            else if fmt_name == "junit":
                parsed.format = OutputFormat.junit
            else:
                main.eprint_line("--format must be human, tap, or junit")
                return Option[TestLimitFlags].none
            ai += 2
            continue
        if arg == "--sanitize":
            parsed.sanitize = true
            ai += 1
            continue
        if arg == "--":
            var rest = ai
            while rest < args.len:
                read(remaining).push(args[rest])
                rest += 1
            break
        read(remaining).push(arg)
        ai += 1
    return Option[TestLimitFlags].some(value = parsed)


## Parse the remaining test arguments: module roots, positional operands, and
## the build-pass flags the host accepts for a test build.
function parse_test_build_flags(
    remaining: ref[vec.Vec[str]],
    roots: ref[vec.Vec[str]],
    positional: ref[vec.Vec[str]],
) -> Option[TestBuildFlags]:
    var parsed = TestBuildFlags(
        cc = "cc",
        profile = "debug",
        platform = resolver.Platform.linux,
        locked = false,
        frozen = false,
    )
    var bi: ptr_uint = 0
    while bi < read(remaining).len():
        let arg_ptr = read(remaining).get(bi) else:
            break
        let arg = unsafe: read(arg_ptr)
        if arg == "-I" or arg == "--include-path":
            if bi + 1 >= read(remaining).len():
                main.eprint_line("missing value for -I")
                bi += 1
                continue
            let value_ptr = read(remaining).get(bi + 1) else:
                main.eprint_line("missing value for -I")
                break
            read(roots).push(unsafe: read(value_ptr))
            bi += 2
            continue
        if arg == "--":
            var rest = bi + 1
            while rest < read(remaining).len():
                let rest_ptr = read(remaining).get(rest) else:
                    break
                read(positional).push(unsafe: read(rest_ptr))
                rest += 1
            break
        if arg == "-o" or arg == "--output" or arg == "--keep-c" or arg == "--cc" or arg == "--profile" or arg == "--platform":
            if bi + 1 >= read(remaining).len():
                eprint_missing_option_value(arg)
                return Option[TestBuildFlags].none
            let value_ptr = read(remaining).get(bi + 1) else:
                eprint_missing_option_value(arg)
                return Option[TestBuildFlags].none
            let value = unsafe: read(value_ptr)
            if arg == "--cc":
                parsed.cc = value
            else if arg == "--profile":
                if not value == "debug" and not value == "release":
                    var bad_profile = string.String.create()
                    defer: bad_profile.release()
                    bad_profile.append("unknown profile ")
                    bad_profile.append(value)
                    bad_profile.append("; expected debug|release")
                    main.eprint_line(bad_profile.as_str())
                    return Option[TestBuildFlags].none
                parsed.profile = value
            else if arg == "--platform":
                if value == "linux":
                    parsed.platform = resolver.Platform.linux
                else if value == "windows":
                    parsed.platform = resolver.Platform.windows
                else if value == "wasm":
                    parsed.platform = resolver.Platform.wasm
                else:
                    var bad_platform = string.String.create()
                    defer: bad_platform.release()
                    bad_platform.append("unknown platform ")
                    bad_platform.append(value)
                    bad_platform.append("; expected linux|windows|wasm")
                    main.eprint_line(bad_platform.as_str())
                    return Option[TestBuildFlags].none
            bi += 2
            continue
        if arg == "--kind":
            if bi + 1 >= read(remaining).len():
                eprint_missing_option_value(arg)
                return Option[TestBuildFlags].none
            let kind_ptr = read(remaining).get(bi + 1) else:
                eprint_missing_option_value(arg)
                return Option[TestBuildFlags].none
            let kind_name = unsafe: read(kind_ptr)
            if not is_known_build_kind(kind_name):
                var bad_kind = string.String.create()
                defer: bad_kind.release()
                bad_kind.append("unknown build kind ")
                bad_kind.append(kind_name)
                bad_kind.append("; expected executable|static|shared")
                main.eprint_line(bad_kind.as_str())
                cli_help.print_usage(true)
                return Option[TestBuildFlags].none
            bi += 2
            continue
        if arg == "--locked":
            parsed.locked = true
            bi += 1
            continue
        if arg == "--frozen":
            parsed.locked = true
            parsed.frozen = true
            bi += 1
            continue
        if arg == "--bundle" or arg == "--archive" or arg == "--no-cache" or arg == "--timings" or arg == "--debug-guards" or arg == "--no-debug-guards":
            bi += 1
            continue
        if arg.starts_with("-"):
            var unknown_opt = string.String.create()
            defer: unknown_opt.release()
            unknown_opt.append("unknown build option ")
            unknown_opt.append(arg)
            main.eprint_line(unknown_opt.as_str())
            cli_help.print_usage(true)
            return Option[TestBuildFlags].none
        read(positional).push(arg)
        bi += 1
    return Option[TestBuildFlags].some(value = parsed)


## Discover and run @[test] functions from a file or directory.  Scans all .mt
## files, synthesizes a runner per file, builds and runs it in-process under a
## timeout/memory sandbox.  With --format tap|junit the per-test outcomes are
## re-emitted in the machine-readable format instead of the human summary.
## `--jobs` is validated and accepted; files still run in order — the host's
## fork-per-file mode only changes wall time (and folds a child's stderr into
## its stdout), so the sequential run is the equivalent without that wart.
public function test_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var positional = vec.Vec[str].create()
    defer: positional.release()
    var remaining = vec.Vec[str].create()
    defer: remaining.release()

    let limit_flags = parse_test_limit_flags(args, ref_of(remaining)) else:
        return 1
    let build_flags = parse_test_build_flags(ref_of(remaining), ref_of(roots), ref_of(positional)) else:
        return 1

    var cwd_owner = string.String.create()
    defer: cwd_owner.release()
    var path: str = ""
    let first_positional = positional.get(0)
    if first_positional != null:
        path = unsafe: read(first_positional)
    else:
        match fs.current_directory():
            Result.success as cwd_payload:
                var package_path = path_ops.join(cwd_payload.value.as_str(), "package.toml")
                let has_package = fs.exists(package_path.as_str())
                package_path.release()
                if has_package:
                    cwd_owner.append(cwd_payload.value.as_str())
                    path = cwd_owner.as_str()
                else:
                    cwd_payload.value.release()
            Result.failure:
                pass
        if path.len == 0:
            main.eprint_line("missing source file path")
            cli_help.print_usage(true)
            return 1

    if build_flags.frozen:
        match package_lock.ensure_current(path, true):
            Result.failure as check_failure:
                var message = check_failure.error
                main.eprint_line(message.as_str())
                message.release()
                return 1
            Result.success:
                pass

    let options = TestRunOptions(
        roots = roots.as_span(),
        name_filter = limit_flags.name_filter,
        timeout_seconds = limit_flags.timeout_seconds,
        memory_mb = limit_flags.memory_mb,
        jobs = limit_flags.jobs,
        sanitize = limit_flags.sanitize,
        format = limit_flags.format,
        cc = build_flags.cc,
        profile = build_flags.profile,
        platform = build_flags.platform,
        locked = build_flags.locked,
        scoped = fs.is_directory(path),
    )

    if fs.is_directory(path):
        return run_test_directory(path, options)
    if fs.exists(path):
        return run_test_file_path(path, options)

    var not_found = string.String.create()
    defer: not_found.release()
    not_found.append("mtc test: not a file or directory: ")
    not_found.append(path)
    main.eprint_line(not_found.as_str())
    return 1


## One file operand: the host's `dispatch_test_run` file branch.  A compile-fail
## fixture runs alone; a normal file must lex and parse before its tests run.
function run_test_file_path(path: str, options: TestRunOptions) -> int:
    match fs.read_text(path):
        Result.failure:
            var cannot_read = string.String.create()
            defer: cannot_read.release()
            cannot_read.append("error: cannot read '")
            cannot_read.append(path)
            cannot_read.append("'")
            main.eprint_line(cannot_read.as_str())
            return 1
        Result.success as content_payload:
            var source = content_payload.value
            defer: source.release()
            let source_text = source.as_str()
            var rc: int = 0
            if is_compile_fail_fixture(source_text):
                var results = vec.Vec[TestResult].create()
                defer: release_test_results(ref_of(results))
                rc = run_compile_fail_file(path, source_text, options, ref_of(results))
                emit_machine_output(options.format, ref_of(results))
                return rc

            var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
            defer: lex_diags.release()
            let _tokens = lexer_mod.lex_reporting(source_text, ref_of(lex_diags))
            if lex_diags.len() > 0:
                main.print_lex_diagnostics(path, source_text, lex_diags.as_span())
                return 1

            var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer: parse_diags.release()
            let _file = parser.parse_source(source_text, ref_of(parse_diags))
            if parse_diags.len() > 0:
                main.print_parse_diagnostics(path, source_text, parse_diags.as_span())
                return 1

            var results = vec.Vec[TestResult].create()
            defer: release_test_results(ref_of(results))
            let outcome = run_tests_from_source(path, source_text, options, false, ref_of(results))
            # The host lets a build failure escape the file operand: no machine
            # report is emitted, only the one diagnostic line.
            if outcome == TestFileOutcome.build_error:
                return 1
            emit_machine_output(options.format, ref_of(results))
            if outcome == TestFileOutcome.test_failed:
                return 1
            return 0


## Emit TAP/JUnit for a completed run; human mode prints nothing extra.
function emit_machine_output(format: OutputFormat, results: ref[vec.Vec[TestResult]]) -> void:
    if format == OutputFormat.tap:
        emit_tap(results)
    else if format == OutputFormat.junit:
        emit_junit(results)


## Discover every test file (the host's `discover_test_files`) and only then
## run them, so a lex error anywhere in the tree aborts before any file's
## output, as the host's discovery pass does.
function run_test_directory(directory: str, options: TestRunOptions) -> int:
    var results = vec.Vec[TestResult].create()
    defer: release_test_results(ref_of(results))
    let machine = options.format != OutputFormat.human
    var failed: ptr_uint = 0

    match fs.list_files_recursive(directory):
        Result.success as entries_payload:
            var entries = entries_payload.value
            defer: entries.release()

            var discovered = vec.Vec[ptr_uint].create()
            defer: discovered.release()
            var kinds = vec.Vec[TestFileKind].create()
            defer: kinds.release()

            var index: ptr_uint = 0
            while index < entries.len():
                match entries.get(index):
                    Option.some as name_payload:
                        let entry_name = name_payload.value
                        if entry_name.ends_with(".mt"):
                            match fs.read_text(entry_name):
                                Result.success as content:
                                    var source = content.value
                                    let kind = classify_test_file(entry_name, source.as_str(), options.name_filter)
                                    source.release()
                                    if kind == TestFileKind.lex_error:
                                        return 1
                                    if kind != TestFileKind.none:
                                        discovered.push(index)
                                        kinds.push(kind)
                                Result.failure as read_err:
                                    var em = read_err.error
                                    em.release()
                    Option.none:
                        pass
                index += 1

            let file_count = discovered.len()
            var run_index: ptr_uint = 0
            while run_index < discovered.len():
                let discovered_ptr = discovered.get(run_index) else:
                    break
                let entry_index = unsafe: read(discovered_ptr)
                let entry_name = entries.get(entry_index) else:
                    break
                let kind_ptr = kinds.get(run_index) else:
                    break
                let kind = unsafe: read(kind_ptr)
                match fs.read_text(entry_name):
                    Result.success as content:
                        var source = content.value
                        # The host prints the file header before running it, so a
                        # file that fails validation still shows its header.
                        if not machine:
                            stdio.print_format(c"# %.*s\n", int<-(entry_name.len), entry_name.data)
                        var file_rc: int = 0
                        if kind == TestFileKind.compile_fail:
                            file_rc = run_compile_fail_file(entry_name, source.as_str(), options, ref_of(results))
                        else:
                            let outcome = run_tests_from_source(entry_name, source.as_str(), options, true, ref_of(results))
                            file_rc = if outcome == TestFileOutcome.ok: 0 else: 1
                        if file_rc != 0:
                            failed += 1
                        source.release()
                    Result.failure as read_err:
                        var em = read_err.error
                        em.release()
                        failed += 1
                run_index += 1

            if machine:
                emit_machine_output(options.format, ref_of(results))
                if failed > 0:
                    return 1
                return 0

            if file_count == 0:
                match options.name_filter:
                    Option.some as needle:
                        stdio.print_format(
                            c"no tests matched -n '%.*s' under %.*s\n",
                            int<-(needle.value.len), needle.value.data,
                            int<-(directory.len), directory.data,
                        )
                    Option.none:
                        stdio.print_format(
                            c"no @[test] functions or # expect-error: fixtures found under %.*s\n",
                            int<-(directory.len), directory.data,
                        )
                return 0

            stdio.print_line("")
            stdio.print_format(c"%d test file(s), %d failed\n", int<-file_count, int<-failed)
            if failed > 0:
                return 1
            return 0
        Result.failure as failure_payload:
            var err = failure_payload.error
            defer: err.release()
            stdio.print_format(c"error: cannot list directory %.*s\n", int<-(directory.len), directory.data)
            return 1


## The host's `classify_test_file`: a `# expect-error:` fixture (basename
## matches the filter) or a parseable file declaring a matching @[test]
## function.  Lex errors are printed and abort the run (the host's discovery
## rescues only ParseError).
function classify_test_file(path: str, source: str, name_filter: Option[str]) -> TestFileKind:
    if is_compile_fail_fixture(source):
        if matches_name_filter(basename_without_mt(path), name_filter):
            return TestFileKind.compile_fail
        return TestFileKind.none

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    let _tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    if lex_diags.len() > 0:
        main.print_lex_diagnostics(path, source, lex_diags.as_span())
        return TestFileKind.lex_error

    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    let file = parser.parse_source(source, ref_of(diags))
    if diags.len() > 0:
        return TestFileKind.none

    var di: ptr_uint = 0
    while di < file.declarations.len:
        unsafe:
            match read(file.declarations.data + di):
                ast.Decl.decl_function as fun:
                    if has_test_attribute(fun.attributes) and matches_name_filter(fun.name, name_filter):
                        return TestFileKind.test
                _:
                    pass
        di += 1
    return TestFileKind.none


function basename_without_mt(path: str) -> str:
    let name = path_ops.basename(path)
    if name.ends_with(".mt"):
        return name.slice(0, name.len - 3)
    return name


## True when the attribute list carries an `@[test]` application.
function has_test_attribute(attributes: span[ast.AttributeApplication]) -> bool:
    var ai: ptr_uint = 0
    while ai < attributes.len:
        let attr = unsafe: read(attributes.data + ai)
        if attr.name.parts.len == 1:
            let an = unsafe: read(attr.name.parts.data + 0)
            if an == "test":
                return true
        ai += 1
    return false


## Run the @[test]/@[expect_fatal] functions of an already-read source.  The
## host's `run_test_file`: a file may not define `main`, filtered tests must
## take no parameters, and a file with no tests reports (file operands only).
## `directory` selects the host's channel/error shape: the directory loop guards
## a build failure into the file's `(build error)` row, while a file operand
## lets it escape.
function run_tests_from_source(file_path: str, source: str, options: TestRunOptions, directory: bool, results: ref[vec.Vec[TestResult]]) -> TestFileOutcome:
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    let file = parser.parse_source(source, ref_of(parse_diags))

    var has_main = false
    var invalid_name = ""
    var all_test_count: ptr_uint = 0
    var test_names = vec.Vec[str].create()
    defer: test_names.release()
    var death_names = vec.Vec[str].create()
    defer: death_names.release()
    var di: ptr_uint = 0
    while di < file.declarations.len:
        unsafe:
            match read(file.declarations.data + di):
                ast.Decl.decl_function as fun:
                    if fun.name == "main":
                        has_main = true
                    var is_test = false
                    var is_fatal = false
                    var ai: ptr_uint = 0
                    while ai < fun.attributes.len:
                        let attr = read(fun.attributes.data + ai)
                        if attr.name.parts.len == 1:
                            let an = read(attr.name.parts.data + 0)
                            if an == "test":
                                is_test = true
                            else if an == "expect_fatal":
                                is_fatal = true
                        ai += 1
                    if is_test:
                        all_test_count += 1
                        if matches_name_filter(fun.name, options.name_filter):
                            if fun.method_params.len > 0 and invalid_name.len == 0:
                                invalid_name = fun.name
                            if is_fatal:
                                death_names.push(fun.name)
                            else:
                                test_names.push(fun.name)
                _:
                    pass
        di += 1

    let machine = options.format != OutputFormat.human
    if has_main:
        if not machine:
            var main_error = string.String.create()
            defer: main_error.release()
            main_error.append("a test file must not define 'main': ")
            main_error.append(file_path)
            main.eprint_line(main_error.as_str())
        return TestFileOutcome.test_failed

    if all_test_count == 0:
        if not directory and not machine:
            stdio.print_format(c"no @[test] functions found in %.*s\n", int<-(file_path.len), file_path.data)
        return TestFileOutcome.ok

    if test_names.len() == 0 and death_names.len() == 0:
        return TestFileOutcome.ok

    if invalid_name.len > 0:
        if not machine:
            var param_error = string.String.create()
            defer: param_error.release()
            param_error.append("@[test] function '")
            param_error.append(invalid_name)
            param_error.append("' must take no parameters")
            main.eprint_line(param_error.as_str())
        return TestFileOutcome.test_failed

    var file_failed = false
    if test_names.len() > 0:
        let outcome = run_normal_test_runner(file_path, source, ref_of(test_names), options, directory, results)
        if outcome == TestFileOutcome.build_error:
            return TestFileOutcome.build_error
        if outcome == TestFileOutcome.test_failed:
            file_failed = true

    var dj: ptr_uint = 0
    while dj < death_names.len():
        let dn_ptr = death_names.get(dj) else:
            break
        let outcome = run_death_test(file_path, source, unsafe: read(dn_ptr), options, directory, results)
        if outcome == TestFileOutcome.build_error:
            return TestFileOutcome.build_error
        if outcome == TestFileOutcome.test_failed:
            file_failed = true
        dj += 1
    if file_failed:
        return TestFileOutcome.test_failed
    return TestFileOutcome.ok


## Release every parsed result row, then the vector.
function release_test_results(results: ref[vec.Vec[TestResult]]) -> void:
    var i: ptr_uint = 0
    while i < results.len():
        let rp = results.get(i) else:
            break
        unsafe:
            read(rp).release()
        i += 1
    results.release()


## `missing value for <option>` plus the usage block, the host's
## `reject_missing_option_value`.
public function eprint_missing_option_value(option: str) -> void:
    var text = string.String.create()
    defer: text.release()
    text.append("missing value for ")
    text.append(option)
    main.eprint_line(text.as_str())
    cli_help.print_usage(true)


## The `--kind` names the host accepts (aliases included).
public function is_known_build_kind(name: str) -> bool:
    return (
        name == "executable" or name == "exe" or name == "bin"
        or name == "static" or name == "staticlib"
        or name == "shared" or name == "dylib" or name == "dll" or name == "so"
    )


## True when `name` should run under the active `-n` filter: no filter matches
## everything, otherwise the test name must contain the filter substring.
function matches_name_filter(name: str, name_filter: Option[str]) -> bool:
    match name_filter:
        Option.some as needle:
            return name.contains_substring(needle.value)
        Option.none:
            return true


## Count @[test] / @[expect_fatal] annotations in a .mt file.
function count_tests_in_file(file_path: str) -> int:
    match fs.read_text(file_path):
        Result.success as content_payload:
            var source = content_payload.value
            defer: source.release()
            var diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer: diags.release()
            let file = parser.parse_source(source.as_str(), ref_of(diags))
            var count: int = 0
            var di: ptr_uint = 0
            while di < file.declarations.len:
                unsafe:
                    var d = read(file.declarations.data + di)
                    match d:
                        ast.Decl.decl_function as fun:
                            var ai: ptr_uint = 0
                            while ai < fun.attributes.len:
                                let attr = read(fun.attributes.data + ai)
                                if attr.name.parts.len == 1:
                                    let an = read(attr.name.parts.data + 0)
                                    if an == "test" or an == "expect_fatal":
                                        count += 1
                                        break
                                ai += 1
                        _:
                            pass
                di += 1
            return count
        Result.failure:
            return 0


## Run `binary_path` under a sandbox: `timeout <sec> bash -c 'ulimit -v <kb>;
## exec "$@"'`, capturing output.  `timeout` reports exit 124 on expiry and the
## `ulimit -v` cap bounds virtual memory so a hung/runaway binary cannot stall
## or exhaust the host.
function run_sandboxed(binary_path: str, timeout_seconds: ptr_uint, memory_mb: ptr_uint, sanitize: bool, extra_arg: Option[str]) -> Result[process.CaptureResult, process.ProcessError]:
    var ulimit_cmd = string.String.create()
    defer: ulimit_cmd.release()
    var run_cmd = vec.Vec[str].create()
    defer: run_cmd.release()
    run_cmd.push("timeout")
    run_cmd.push(main.ptr_uint_to_str(timeout_seconds))
    if sanitize:
        # ASan reserves a huge shadow address space, so the `ulimit -v` cap
        # must be skipped for sanitized runs (mirrors Ruby's spawn_sandboxed,
        # which omits :rlimit_as when @test_sanitize is set).
        run_cmd.push(binary_path)
    else:
        ulimit_cmd.append("ulimit -v ")
        ulimit_cmd.append(main.ptr_uint_to_str(memory_mb * 1024z))
        ulimit_cmd.append("; exec \"$@\"")
        run_cmd.push("bash")
        run_cmd.push("-c")
        run_cmd.push(ulimit_cmd.as_str())
        run_cmd.push("mt")
        run_cmd.push(binary_path)
    match extra_arg:
        Option.some as extra:
            run_cmd.push(extra.value)
        Option.none:
            pass
    return process.capture(run_cmd.as_span())


## Build a runner .mt source file in-process using the self-host compiler.
## Module roots mirror the host's `module_roots_for` for the test source: the
## explicit `-I` roots, the discovered project root, the enclosing package's
## source root and the compiler's own roots, plus the cwd's ambient roots.
## A build failure returns the host's single diagnostic line.
function build_runner_file(source_path: str, options: TestRunOptions, output_path: str) -> Result[bool, string.String]:
    var runner_roots = vec.Vec[str].create()
    defer: runner_roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var ri: ptr_uint = 0
    while ri < options.roots.len:
        unsafe:
            runner_roots.push(read(options.roots.data + ri))
        ri += 1

    main.add_module_roots(source_path, ref_of(runner_roots), ref_of(owned_roots))
    match fs.current_directory():
        Result.success as cwd_payload:
            var cwd = cwd_payload.value
            main.add_module_roots(cwd.as_str(), ref_of(runner_roots), ref_of(owned_roots))
            cwd.release()
        Result.failure as cwd_failure:
            var cwd_error = cwd_failure.error
            cwd_error.release()

    # The host resolves the package graph per test file (`module_roots_for` +
    # `package_graph_for` with the run's `locked` flag), so a lock failure is
    # that file's build error rather than a command-level message.
    if options.locked:
        match main.apply_package_resolution_result(source_path, true, false, ref_of(runner_roots), ref_of(owned_roots)):
            Result.failure as resolution_failure:
                return Result[bool, string.String].failure(error = resolution_failure.error)
            Result.success:
                pass

    # Compile the runner inside a heap region: the parser/AST, analyzer,
    # lowering IR, and C backend allocations for this one runner are reclaimed
    # in one step.  Without it, each in-process test build retained its AST,
    # analysis, and IR until process exit (measured ~0.4-0.7 GB per file).
    var build_region = heap_mod.create_region()
    let previous_region = heap_mod.begin_region(ptr_of(build_region))
    var program = loader.check_program(source_path, runner_roots.as_span(), options.platform)

    if program.diagnostic_error_count() > 0:
        let first = main.first_error_line(ref_of(program))
        # The diagnostic is region-owned; copy it out before freeing the region.
        heap_mod.end_region(previous_region)
        var message = string.String.from_str(first.as_str())
        build_region.release_all()
        return Result[bool, string.String].failure(error = message)

    let ir_program = lowering.lower(program)

    # The host forces guards off for synthesized test runners, regardless of
    # the debug profile.
    match build_driver.build(
        program, ir_program, output_path, options.cc, runner_roots.as_span(), options.sanitize, options.profile,
        Option[bool].some(value = false), build_driver.BuildKind.executable, options.platform,
        Option[str].none, span[string.String](), Option[str].none
    ):
        Result.success:
            heap_mod.end_region(previous_region)
            build_region.release_all()
            return Result[bool, string.String].success(value = true)
        Result.failure as failure:
            let error_text = failure.error.as_str()
            heap_mod.end_region(previous_region)
            var message = string.String.from_str(error_text)
            build_region.release_all()
            return Result[bool, string.String].failure(error = message)


## The host's runner source path: `<source dir>/__mt_test_runner_<pid><suffix>`.
## The pid keeps a concurrent `mtc test` (and the discovery rule that ignores
## `__mt_test_runner_` files) from colliding with another process's runner.
## The host builds the binary in `Dir.tmpdir`; the self keeps it beside the
## runner source so the self-host runtime's own `compiler_root_candidates`
## (which walks up from the running executable to the enclosing `std/`) keeps
## working inside a test process.
function test_runner_path(dirname: str, suffix: str) -> string.String:
    var path = string.String.from_str(dirname)
    path.append("/__mt_test_runner_")
    path.append_format(f"#{libuv.os_getpid()}")
    path.append(suffix)
    return path


## The first non-blank line of `text`, trimmed (the host's `first_fail_message`).
## The `timeout` wrapper's core-dump notice is not the child's output and is
## skipped: this coreutils ships no `--quiet`, and the host's direct spawn has
## no wrapper to report through.
function first_nonblank_line(text: str) -> str:
    var start: ptr_uint = 0
    var pos: ptr_uint = 0
    while pos <= text.len:
        if pos == text.len or text.byte_at(pos) == 10:
            let line = text.slice(start, pos - start).trim_ascii_whitespace()
            if line.len > 0 and not line.starts_with("timeout: the monitored command"):
                return line
            start = pos + 1
        pos += 1
    return ""


## Render a runner build failure the way the host's guard/exception split does:
## a directory run in machine mode records the file's `(build error)` row and
## drops the message (the host buffers it); a directory human run prints the
## FAILED header and the message on stderr; a file operand always prints the
## message on stderr and never emits machine output.
function report_runner_build_error(file_path: str, message: str, options: TestRunOptions, directory: bool, results: ref[vec.Vec[TestResult]]) -> void:
    let machine = options.format != OutputFormat.human
    if directory and machine:
        var name = string.String.from_str(file_path)
        name.append(" (build error)")
        results.push(TestResult(
            name = name,
            status = TestStatus.fail,
            detail = string.String.from_str("build error"),
            has_detail = true,
        ))
        return
    if directory:
        var marker = string.String.create()
        defer: marker.release()
        marker.append("FAILED - ")
        marker.append(file_path)
        marker.append(" (build error)")
        main.eprint_line(marker.as_str())
    if message.len > 0:
        main.eprint_message(message)


## Build one runner binary whose `main(args)` dispatches to a single @[test]
## function selected by `args[1]`, then run it once per test in its own process
## so an aborting assertion is isolated to that test.
function run_normal_test_runner(file_path: str, source_text: str, test_names: ref[vec.Vec[str]], options: TestRunOptions, directory: bool, results: ref[vec.Vec[TestResult]]) -> TestFileOutcome:
    var runner_source = string.String.create()
    defer: runner_source.release()
    runner_source.append(source_text)
    runner_source.append("\n\nfunction main(args: span[str]) -> int:\n")
    runner_source.append("    let which = if args.len > 1: args[1] else: \"\"\n")
    runner_source.append("    match which:\n")
    var ti: ptr_uint = 0
    while ti < test_names.len():
        let tn_ptr = test_names.get(ti) else:
            break
        let tn = unsafe: read(tn_ptr)
        runner_source.append("        \"")
        runner_source.append(tn)
        runner_source.append("\":\n            ")
        runner_source.append(tn)
        runner_source.append("()\n")
        ti += 1
    runner_source.append("        _:\n            return 2\n")
    runner_source.append("    return 0\n")

    let dirname = path_ops.dirname(file_path)
    var runner_path_str = test_runner_path(dirname, ".mt")
    defer: runner_path_str.release()

    match fs.write_text(runner_path_str.as_str(), runner_source.as_str()):
        Result.success:
            pass
        Result.failure:
            return TestFileOutcome.build_error

    var runner_bin_str = test_runner_path(dirname, "")
    defer: runner_bin_str.release()

    match build_runner_file(runner_path_str.as_str(), options, runner_bin_str.as_str()):
        Result.failure as build_err:
            var message = build_err.error
            report_runner_build_error(file_path, message.as_str(), options, directory, results)
            message.release()
            let _rb = fs.remove(runner_path_str.as_str())
            return TestFileOutcome.build_error
        Result.success:
            pass

    let machine = options.format != OutputFormat.human
    var any_failed = false
    var ti2: ptr_uint = 0
    while ti2 < test_names.len():
        let tn_ptr = test_names.get(ti2) else:
            break
        let tn = unsafe: read(tn_ptr)
        match run_sandboxed(runner_bin_str.as_str(), options.timeout_seconds, options.memory_mb, options.sanitize, Option[str].some(value = tn)):
            Result.success as run_result:
                var capture_result = run_result.value
                let code = capture_result.status.normalized_code()
                if code == 0:
                    if machine:
                        results.push(TestResult(name = string.String.from_str(tn), status = TestStatus.ok, detail = string.String.create(), has_detail = false))
                    else:
                        stdio.print_format(c"ok   - %.*s\n", int<-(tn.len), tn.data)
                else:
                    any_failed = true
                    var detail = string.String.create()
                    if code == 124:
                        detail.append("timed out")
                    else:
                        match capture_result.stderr_text():
                            Option.some as et:
                                let line = first_nonblank_line(et.value)
                                if line.len > 0:
                                    detail.append(line)
                            Option.none:
                                pass
                        if detail.len() == 0:
                            match capture_result.stdout_text():
                                Option.some as ot:
                                    let line = first_nonblank_line(ot.value)
                                    if line.len > 0:
                                        detail.append(line)
                                Option.none:
                                    pass
                        if detail.len() == 0:
                            detail.append("test aborted")
                    if machine:
                        results.push(TestResult(name = string.String.from_str(tn), status = TestStatus.fail, detail = detail, has_detail = true))
                    else:
                        let detail_text = detail.as_str()
                        stdio.print_format(c"FAIL - %.*s: %.*s\n", int<-(tn.len), tn.data, int<-(detail_text.len), detail_text.data)
                        detail.release()
                capture_result.release()
            Result.failure:
                any_failed = true
                if machine:
                    results.push(TestResult(name = string.String.from_str(tn), status = TestStatus.fail, detail = string.String.from_str("runner crashed"), has_detail = true))
                else:
                    stdio.print_format(c"FAIL - %.*s: runner crashed\n", int<-(tn.len), tn.data)
        ti2 += 1

    let _r1 = fs.remove(runner_path_str.as_str())
    let _r2 = fs.remove(runner_bin_str.as_str())
    if any_failed:
        return TestFileOutcome.test_failed
    return TestFileOutcome.ok


## Run a single @[expect_fatal] death test in its own binary.  The synthesized
## main calls the test and returns 0 on either outcome, exactly as the host's
## `death_test_runner_main`; the test passes only if the process aborts (fatal /
## failed safety check) instead of returning or timing out.
function run_death_test(file_path: str, source_text: str, test_name: str, options: TestRunOptions, directory: bool, results: ref[vec.Vec[TestResult]]) -> TestFileOutcome:
    var runner_source = string.String.create()
    defer: runner_source.release()
    runner_source.append(source_text)
    runner_source.append("\n\nfunction main() -> int:\n    ")
    runner_source.append(test_name)
    runner_source.append("()\n    return 0\n")

    let dirname = path_ops.dirname(file_path)
    var runner_path_str = test_runner_path(dirname, ".mt")
    defer: runner_path_str.release()

    match fs.write_text(runner_path_str.as_str(), runner_source.as_str()):
        Result.success:
            pass
        Result.failure:
            return TestFileOutcome.build_error

    var runner_bin_str = test_runner_path(dirname, "")
    defer: runner_bin_str.release()

    match build_runner_file(runner_path_str.as_str(), options, runner_bin_str.as_str()):
        Result.failure as build_err:
            var message = build_err.error
            report_runner_build_error(file_path, message.as_str(), options, directory, results)
            message.release()
            let _rb = fs.remove(runner_path_str.as_str())
            return TestFileOutcome.build_error
        Result.success:
            pass

    var passed = false
    var reason = "expected a fatal abort, but the test returned"
    match run_sandboxed(runner_bin_str.as_str(), options.timeout_seconds, options.memory_mb, options.sanitize, Option[str].none):
        Result.success as run_result:
            var capture_result = run_result.value
            defer: capture_result.release()
            let code = capture_result.status.normalized_code()
            if code == 124:
                reason = "timed out"
            else if code == 0:
                reason = "expected a fatal abort, but the test returned"
            else:
                passed = true
        Result.failure:
            reason = "runner crashed"

    let _r1 = fs.remove(runner_path_str.as_str())
    let _r2 = fs.remove(runner_bin_str.as_str())

    let machine = options.format != OutputFormat.human
    if machine:
        var name = string.String.from_str(test_name)
        name.append(" (expect_fatal)")
        if passed:
            results.push(TestResult(name = name, status = TestStatus.ok, detail = string.String.create(), has_detail = false))
        else:
            results.push(TestResult(name = name, status = TestStatus.fail, detail = string.String.from_str(reason), has_detail = true))
    else:
        if passed:
            stdio.print_format(c"ok   - %.*s (expect_fatal)\n", int<-(test_name.len), test_name.data)
        else:
            stdio.print_format(
                c"FAIL - %.*s (expect_fatal): %.*s\n",
                int<-(test_name.len), test_name.data,
                int<-(reason.len), reason.data,
            )
    if passed:
        return TestFileOutcome.ok
    return TestFileOutcome.test_failed
