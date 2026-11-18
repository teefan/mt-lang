## `mtc format` — single-file and batch formatting with check/write/timing modes.
## Extracted from main.mt.

import std.fs as fs
import std.fmt as fmt_mod
import std.str as str
import std.string as string
import std.stdio as stdio
import std.time as time
import std.vec as vec

import mtc.formatter.tidy as tidy
import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.profile as profile_mod
import mtc.cli_help as cli_help
import mtc.main as main


## Report a formatter failure the way the host CLI does: the lexer's
## `error[lex/error]` blocks when lexing failed, else the parser's
## `error[parse/error]` blocks, on stderr.
function report_format_failure(path: str, source: str) -> int:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    let _tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    if lex_diags.len() > 0:
        let lex_ptr = lex_diags.get(0) else:
            return 1
        let lex = unsafe: read(lex_ptr)
        main.print_diagnostic_block(path, source, lex.line, lex.column, "lex/error", str.cstr_as_str(lex.message))
        return 1
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    let _file = parser.parse_source(source, ref_of(parse_diags))
    if parse_diags.len() > 0:
        let parsed_ptr = parse_diags.get(0) else:
            return 1
        let parsed = unsafe: read(parsed_ptr)
        main.print_diagnostic_block(path, source, parsed.line, parsed.column, "parse/error", str.cstr_as_str(parsed.message))
        return 1
    return 1


## Format one source file and apply the single-file output rules.
function format_one_path(
    path: str,
    check_mode: bool,
    write_mode: bool,
    timings: bool,
    mode: tidy.FormatMode,
    explicit_max_line_length: ptr_uint,
) -> int:
    if main.cli_is_verbose():
        if write_mode:
            stdio.print_format(c"formatting %.*s\n", int<-(path.len), path.data)
        else:
            stdio.print_format(c"checking %.*s\n", int<-(path.len), path.data)

    var format_profile = profile_mod.create()
    defer: profile_mod.release(ref_of(format_profile))
    var profile_ptr: ptr[profile_mod.Profile]? = null
    if timings:
        profile_ptr = ptr_of(format_profile)

    match fs.read_text(path):
        Result.success as content:
            var source = content.value
            defer: source.release()
            let source_text = source.as_str()

            let started_ms = monotonic_ms()
            var formatted = tidy.format_source_profiled(source_text, path, mode, explicit_max_line_length, profile_ptr) else:
                return report_format_failure(path, source_text)
            defer: formatted.release()
            let fmt_text = formatted.as_str()

            var exit_code = 0
            if write_mode:
                if source_text == fmt_text:
                    stdio.print_format(c"already formatted %.*s\n", int<-(path.len), path.data)
                else:
                    match fs.write_text(path, fmt_text):
                        Result.success:
                            stdio.print_format(c"formatted %.*s\n", int<-(path.len), path.data)
                        Result.failure as err:
                            var msg = err.error
                            defer: msg.release()
                            stdio.print_format(c"error: cannot write %.*s\n", int<-(path.len), path.data)
                            exit_code = 1
            else if check_mode:
                if source_text == fmt_text:
                    stdio.print_format(c"already formatted %.*s\n", int<-(path.len), path.data)
                else:
                    stdio.print_format(c"needs formatting %.*s\n", int<-(path.len), path.data)
                    exit_code = 1
            else:
                stdio.print_format(c"%.*s", int<-(fmt_text.len), fmt_text.data)
            if timings:
                print_format_profile(path, monotonic_ms() - started_ms, ref_of(format_profile))
            return exit_code
        Result.failure as err:
            var msg = err.error
            defer: msg.release()
            return main.report_missing_source(path)


## Format several sources (a directory operand or more than one path).  The
## host requires --check or --write here and prints a batch summary.
function format_paths_command(
    paths: ref[vec.Vec[str]],
    check_mode: bool,
    write_mode: bool,
    mode: tidy.FormatMode,
    explicit_max_line_length: ptr_uint,
) -> int:
    if check_mode:
        var needs = vec.Vec[string.String].create()
        defer: needs.release()
        var pi: ptr_uint = 0
        while pi < paths.len():
            let path_ptr = paths.get(pi) else:
                break
            let path = unsafe: read(path_ptr)
            match fs.read_text(path):
                Result.success as content:
                    var source = content.value
                    defer: source.release()
                    var formatted = tidy.format_source(source.as_str(), path, mode, explicit_max_line_length) else:
                        return report_format_failure(path, source.as_str())
                    defer: formatted.release()
                    if source.as_str() != formatted.as_str():
                        stdio.print_format(c"needs formatting %.*s\n", int<-(path.len), path.data)
                        needs.push(string.String.from_str(path))
                Result.failure as err:
                    var msg = err.error
                    defer: msg.release()
                    return main.report_missing_source(path)
            pi += 1
        if needs.len() == 0:
            stdio.print_format(c"all %d file(s) already formatted\n", int<-(paths.len()))
            return 0
        stdio.print_format(c"%d file(s) need formatting\n", int<-(needs.len()))
        return 1

    var changed: ptr_uint = 0
    var pi: ptr_uint = 0
    while pi < paths.len():
        let path_ptr = paths.get(pi) else:
            break
        let path = unsafe: read(path_ptr)
        match fs.read_text(path):
            Result.success as content:
                var source = content.value
                defer: source.release()
                var formatted = tidy.format_source(source.as_str(), path, mode, explicit_max_line_length) else:
                    return report_format_failure(path, source.as_str())
                defer: formatted.release()
                if source.as_str() != formatted.as_str():
                    match fs.write_text(path, formatted.as_str()):
                        Result.success:
                            stdio.print_format(c"formatted %.*s\n", int<-(path.len), path.data)
                            changed += 1
                        Result.failure as err:
                            var msg = err.error
                            defer: msg.release()
                            stdio.print_format(c"error: cannot write %.*s\n", int<-(path.len), path.data)
                            return 1
            Result.failure as err:
                var msg = err.error
                defer: msg.release()
                return main.report_missing_source(path)
        pi += 1
    stdio.print_format(c"formatted %d of %d file(s)\n", int<-(changed), int<-(paths.len()))
    return 0


## `mtc format PATH|DIR [PATH|DIR ...] [--check|--write] [--safe|--canonical|
## --preserve|--tidy] [--max-line-length N] [--timings]`.
public function format_command(args: span[str]) -> int:
    var inputs = vec.Vec[str].create()
    defer: inputs.release()
    var check_mode = false
    var write_mode = false
    var timings = false
    var mode = tidy.FormatMode.safe
    var explicit_max_line_length: ptr_uint = 0
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--check":
            check_mode = true
            ai += 1
            continue
        if arg == "--timings":
            timings = true
            ai += 1
            continue
        if arg == "--write" or arg == "-w":
            write_mode = true
            ai += 1
            continue
        if arg == "--preserve":
            mode = tidy.FormatMode.preserve
            ai += 1
            continue
        if arg == "--canonical":
            mode = tidy.FormatMode.canonical
            ai += 1
            continue
        if arg == "--safe":
            mode = tidy.FormatMode.safe
            ai += 1
            continue
        if arg == "--tidy":
            mode = tidy.FormatMode.tidy
            ai += 1
            continue
        if arg == "--max-line-length":
            if ai + 1 >= args.len:
                main.eprint_line("missing value for --max-line-length")
                cli_help.print_usage(true)
                return 1
            let parsed = main.parse_positive_int(args[ai + 1]) else:
                main.eprint_line("--max-line-length must be a positive integer")
                cli_help.print_usage(true)
                return 1
            explicit_max_line_length = parsed
            ai += 2
            continue
        if arg == "--":
            ai += 1
            while ai < args.len:
                inputs.push(args[ai])
                ai += 1
            continue
        if arg.starts_with("-"):
            var unknown = string.String.create()
            defer: unknown.release()
            unknown.append("unknown format option ")
            unknown.append(arg)
            main.eprint_line(unknown.as_str())
            cli_help.print_usage(true)
            return 1
        inputs.push(arg)
        ai += 1

    if check_mode and write_mode:
        main.eprint_line("format options --check and --write cannot be combined")
        cli_help.print_usage(true)
        return 1

    if inputs.len() == 0:
        main.eprint_line("missing source file path")
        cli_help.print_usage(true)
        return 1

    var has_directory = false
    var di: ptr_uint = 0
    while di < inputs.len():
        let input_ptr = inputs.get(di) else:
            break
        if fs.is_directory(unsafe: read(input_ptr)):
            has_directory = true
        di += 1

    let multiple_sources = inputs.len() > 1 or has_directory
    # Reject a multi-source run before expanding the operands: walking a large
    # tree only to print the usage error is the host's behaviour too, but the
    # self's recursive walk is far dearer than the host's `Dir.glob`.
    if multiple_sources and not check_mode and not write_mode:
        main.eprint_line("format on multiple sources requires --check or --write")
        cli_help.print_usage(true)
        return 1

    var paths = vec.Vec[str].create()
    defer: paths.release()
    var expanded_owner = vec.Vec[string.String].create()
    defer: expanded_owner.release()
    main.expand_source_operands(inputs.as_span(), ref_of(paths), ref_of(expanded_owner))
    if paths.len() == 0:
        var label = main.operand_label(inputs.as_span())
        defer: label.release()
        var msg = string.String.create()
        defer: msg.release()
        msg.append("no .mt files found in ")
        msg.append(label.as_str())
        stdio.print_line(msg.as_str())
        return 0

    if multiple_sources:
        return format_paths_command(ref_of(paths), check_mode, write_mode, mode, explicit_max_line_length)

    let path_ptr = paths.get(0) else:
        return 0
    let path = unsafe: read(path_ptr)
    return format_one_path(path, check_mode, write_mode, timings, mode, explicit_max_line_length)


## The default output path for a source build: the source path with its `.mt`
## extension removed (matching the Ruby CLI's direct-source-build behaviour).
public function default_output_path(path: str) -> string.String:
    if path.ends_with(".mt"):
        return string.String.from_str(path.slice(0, path.len - 3))
    return main.j2_path(path, ".out")


## Milliseconds from the monotonic clock, used by `--timings` reports.
public function monotonic_ms() -> double:
    var ts = zero[time.TimeSpec]
    let rc = time.monotonic(ref_of(ts))
    if rc != 0:
        return 0.0
    return double<-ts.tv_sec * 1000.0 + double<-ts.tv_nsec / 1000000.0


## The host's single-file format profile: a leading blank line, then
## `format profile <path>: <%.1f>ms (<phases >= 0.1ms, by descending total>)`.
function print_format_profile(path: str, total_ms: double, profile: ref[profile_mod.Profile]) -> void:
    var line = string.String.create()
    defer: line.release()
    line.push_byte(10)
    line.append("format profile ")
    line.append(path)
    line.append(": ")
    fmt_mod.append_double_precision(ref_of(line), total_ms, 1)
    line.append("ms")
    var phases = profile_mod.phases_desc_text(profile, 0.1, true)
    defer: phases.release()
    if phases.len() > 0:
        line.append(" (")
        line.append(phases.as_str())
        line.append(")")
    stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
