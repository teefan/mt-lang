## Self-hosted Milk Tea compiler CLI.
##
## Commands:
##   mtc lex <file>       Print the lexer token stream
##   mtc help             Print help

import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec
import std.stdio as stdio
import std.process as process
import std.terminal as terminal

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.lexer.lexer as lexer
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.parser.ast as ast
import mtc.pretty_printer.ast_formatter as ast_formatter
import mtc.pretty_printer.ir_formatter as ir_formatter
import mtc.loader.path_resolver as resolver
import mtc.loader.module_loader as loader
import mtc.lowering.lowering as lowering
import mtc.c_backend.c_backend as c_backend
import mtc.ir as ir
import mtc.build as build_driver
import mtc.build_cache as build_cache
import mtc.pretty_printer.ast_formatter as fmt
import mtc.linter.linter as linter
import mtc.linter.config as lint_config
import mtc.linter.fix_engine as fix_engine
import mtc.lsp.server as lsp
import mtc.dap.server as dap


function main(args: span[str]) -> int:
    if args.len < 1:
        print_help()
        return 1

    let cmd = args[0]

    if cmd == "version" or cmd == "--version" or cmd == "-V":
        stdio.print_line("mtc 0.1.0")
        return 0

    if cmd == "lex":
        var machine = false
        var file_index: ptr_uint = 1
        if args.len >= 2 and args[1] == "--machine":
            machine = true
            file_index = 2
        if args.len <= file_index:
            print_help()
            return 1
        return lex_command(args[file_index], machine)

    if cmd == "parse":
        if args.len < 2:
            print_help()
            return 1
        return parse_command(args[1])

    if cmd == "check":
        if args.len < 2:
            print_help()
            return 1
        return check_command(args)

    if cmd == "lint":
        if args.len < 2:
            print_help()
            return 1
        return lint_command(args)

    if cmd == "lower":
        if args.len < 2:
            print_help()
            return 1
        return lower_command(args)

    if cmd == "emit-c":
        if args.len < 2:
            print_help()
            return 1
        return emit_c_command(args)

    if cmd == "build":
        if args.len < 2:
            print_help()
            return 1
        return build_command(args)

    if cmd == "run":
        if args.len < 2:
            print_help()
            return 1
        return run_command(args)

    if cmd == "run-module":
        if args.len < 2:
            print_help()
            return 1
        return run_module_command(args)

    if cmd == "new":
        return new_command(args)

    if cmd == "completions":
        return completions_command(args)

    if cmd == "test":
        return test_command(args)

    if cmd == "format":
        return format_command(args)

    if cmd == "lsp":
        return lsp.run(args)

    if cmd == "dap":
        return dap.run(args)

    if cmd == "cache":
        return cache_command(args)

    if cmd == "help":
        print_help()
        return 0

    print_unknown(cmd)
    return 1


function print_help() -> void:
    stdio.print_line("mtc — self-hosted Milk Tea compiler")
    stdio.print_line("")
    stdio.print_line("usage: mtc <command> [args...]")
    stdio.print_line("")
    stdio.print_line("commands:")
    stdio.print_line("  lex   <file> [--machine]                           print the lexer token stream")
    stdio.print_line("  parse <file>                                       parse source and print AST")
    stdio.print_line("  check <file|dir>... [-I DIR]... [--platform NAME] [-Werror] [--locked] [--frozen]  type-check files/package and imports")
    stdio.print_line("  lint  <file|dir>...                                 report style/correctness warnings")
    stdio.print_line("  lower <file|dir> [-I DIR]... [--platform NAME]     lower to IR and print it")
    stdio.print_line("  emit-c <file|dir> [-I DIR]... [--platform NAME]    compile to C and print it")
    stdio.print_line("  build <file|dir> [-I DIR]... [-o OUTPUT] [--cc CC] [--keep-c PATH] [--profile debug|release] [--platform linux|windows|wasm] [--no-cache] [--clean]")
    stdio.print_line("  run   <file|dir> [-I DIR]... [-o OUTPUT] [--cc CC] [--profile debug|release] [--platform linux|windows|wasm] [--no-cache] [-- ARGS...]")
    stdio.print_line("  run-module <module> [run options...]                resolve, build, and run a module by name")
    stdio.print_line("  test  <dir> [-I DIR]... [-n NAME] [--timeout SECONDS] [--mem MB] [--format human|tap|junit]  discover and run @[test] functions")
    stdio.print_line("  new   <path>                                        scaffold a new package")
    stdio.print_line("  format <file> [--check|--write]                     format source and print, check, or write back")
    stdio.print_line("  completions bash|zsh|fish                           print a shell completion script")
    stdio.print_line("  version|--version|-V                                print version and exit")
    stdio.print_line("  help                                                print this help")


function print_unknown(cmd: str) -> void:
    stdio.print_format(c"mtc: unknown command '%.*s'\n", int<-(cmd.len), cmd.data)


function parse_command(file_path: str) -> int:
    match fs.read_text(file_path):
        Result.failure:
            stdio.print_format(c"error: cannot read '%.*s'\n", int<-(file_path.len), file_path.data)
            return 1
        Result.success as payload:
            var content = payload.value
            defer content.release()

            let source = content.as_str()
            var diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer diags.release()
            let file = parser.parse_source(source, ref_of(diags))

            if diags.len() > 0:
                var di: ptr_uint = 0
                while di < diags.len():
                    let d = diags.get(di) else:
                        break
                    unsafe:
                        let rd = read(d)
                        stdio.print_format(
                            c"parse error: L%d:%d lexeme='%.*s' kind=%.*s: %s\n",
                            int<-(rd.line),
                            int<-(rd.column),
                            int<-(rd.lexeme.len), rd.lexeme.data,
                            int<-(rd.kind.len), rd.kind.data,
                            rd.message,
                        )
                    di += 1
                return 1

            var rendered = ast_formatter.format_source_file(file)
            defer rendered.release()
            let text = rendered.as_str()
            stdio.print_format(c"%.*s", int<-(text.len), text.data)
            return 0


## Type-check source files and their transitive imports.  Accepts `.mt` files,
## directories (recursively discovers `*.mt`), and package directory targets
## (reads package.toml).  Imports are resolved against `-I DIR` / `--root DIR`
## module roots (repeatable); when none are given the root defaults to the file's
## directory.
##
## Flags:
##   -I DIR, --root DIR    module search root (repeatable)
##   --platform NAME       target platform (linux|windows|wasm, default: linux)
##   -Werror               treat warnings as errors
##   --locked              (accepted, not yet wired — requires package.toml)
##   --frozen              (accepted, not yet wired — implies --locked)
function check_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer roots.release()
    var input_paths = vec.Vec[str].create()
    defer input_paths.release()
    var platform = resolver.Platform.linux
    var warnings_as_errors = false

    var i: ptr_uint = 1
    while i < args.len:
        let arg = args[i]
        if arg == "--root" or arg == "-I":
            if i + 1 >= args.len:
                stdio.print_line("error: -I requires a directory")
                return 1
            roots.push(args[i + 1])
            i += 2
            continue
        if arg == "--platform":
            if i + 1 >= args.len:
                stdio.print_line("error: --platform requires linux, windows, or wasm")
                return 1
            match parse_platform_name(args[i + 1]):
                Option.some as plat:
                    platform = plat.value
                Option.none:
                    return 1
            i += 2
            continue
        if arg == "-Werror" or arg == "--warnings-as-errors":
            warnings_as_errors = true
            i += 1
            continue
        if arg == "--locked" or arg == "--frozen":
            # Accepted for CLI compatibility; package lock not yet wired.
            i += 1
            continue
        input_paths.push(arg)
        i += 1

    if input_paths.is_empty():
        print_help()
        return 1

    # Expand directories to their .mt files.
    # Paths are copied into owned Strings so they do not dangle when a directory
    # listing's Entries buffer is released.
    var source_files = vec.Vec[string.String].create()
    defer source_files.release()
    var si: ptr_uint = 0
    while si < input_paths.len():
        let raw = input_paths.get(si) else:
            break
        let path = unsafe: read(raw)
        if fs.is_directory(path):
            match fs.list_files_recursive(path):
                Result.success as entries_payload:
                    var entries = entries_payload.value
                    defer entries.release()
                    var ei: ptr_uint = 0
                    while ei < entries.len():
                        match entries.get(ei):
                            Option.some as name_payload:
                                let entry_name = name_payload.value
                                if entry_name.ends_with(".mt") and not entry_name.starts_with("__mt_test_runner_"):
                                    source_files.push(string.String.from_str(entry_name))
                            Option.none:
                                pass
                        ei += 1
                Result.failure as err_payload:
                    var err_msg = err_payload.error
                    defer err_msg.release()
                    stdio.print_format(c"error: cannot list %.*s\n", int<-(path.len), path.data)
                    return 1
        else:
            source_files.push(string.String.from_str(path))
        si += 1

    if source_files.is_empty():
        stdio.print_line("no .mt files found")
        return 0

    var total_errors: ptr_uint = 0
    var total_warnings: ptr_uint = 0
    var file_count: ptr_uint = 0

    var fi: ptr_uint = 0
    while fi < source_files.len():
        let raw_path = source_files.get(fi) else:
            break
        let source_path = unsafe: read(raw_path).as_str()

        var file_roots = vec.Vec[str].create()
        defer file_roots.release()
        var rj: ptr_uint = 0
        while rj < roots.len():
            let rp = roots.get(rj) else:
                break
            unsafe:
                file_roots.push(read(rp))
            rj += 1

        var entry_path_owner = string.String.create()
        var source_root_owner = string.String.create()
        let effective = effective_source_path(source_path, ref_of(file_roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
            continue

        if file_roots.is_empty():
            file_roots.push(path_ops.dirname(effective))

        var program = loader.check_program(effective, file_roots.as_span(), platform)
        defer program.release()

        let errors = program.diagnostic_error_count()
        let warnings = program.diagnostic_warning_count()

        if errors == 0 and warnings == 0:
            let module_name = program.root_module_name()
            stdio.print_format(
                c"checked %.*s as %.*s\n",
                int<-(effective.len), effective.data,
                int<-(module_name.len), module_name.data,
            )
        else:
            print_program_diagnostics(ref_of(program))
            file_count += 1
            total_errors += errors
            total_warnings += warnings

        # Run linter on clean files to catch style hints.
        if errors == 0:
            match fs.read_text(effective):
                Result.success as content:
                    var src = content.value
                    defer src.release()
                    var diags = vec.Vec[pstate.ParseDiagnostic].create()
                    defer diags.release()
                    let lfile = parser.parse_source(src.as_str(), ref_of(diags))
                    var lwarns = linter.lint_source(lfile, src.as_str(), effective, span[str]())
                    defer lwarns.release()
                    if lwarns.len() > 0:
                        var lwi: ptr_uint = 0
                        while lwi < lwarns.len():
                            let lwp = lwarns.get(lwi) else:
                                break
                            unsafe:
                                let lw = read(lwp)
                                stdio.print_format(
                                    c"%.*s:%d: %.*s: %.*s\n",
                                    int<-(lw.path.len), lw.path.data,
                                    int<-(lw.line),
                                    int<-(lw.code.len), lw.code.data,
                                    int<-(lw.message.len), lw.message.data,
                                )
                            lwi += 1
                        total_warnings += lwarns.len()
                        if total_errors == 0 and warnings == 0:
                            file_count += 1
                Result.failure as read_err:
                    var em = read_err.error
                    em.release()

        entry_path_owner.release()
        source_root_owner.release()
        fi += 1

    report_check_summary(total_errors, total_warnings, file_count, warnings_as_errors)
    if total_errors > 0:
        return 1
    if warnings_as_errors and total_warnings > 0:
        return 1
    return 0


## Right-justify a `ptr_uint` to a minimum width of 5 with leading spaces, the
## line-number gutter width used by the diagnostic renderer (matches Ruby's
## `line.to_s.rjust(5)`).
function rjust_line_number(line: ptr_uint) -> string.String:
    let num = ptr_uint_to_str(line)
    var buf = string.String.create()
    if num.len < 5:
        var pad = 5 - num.len
        while pad > 0:
            buf.push_byte(32)
            pad -= 1
    buf.append(num)
    return buf


## Render a program's diagnostics in the shared Milk Tea format (matching the
## Ruby `ErrorFormatter`, no color):
##
##     error[sema/error]: <message>
##       --> <path>:<line>:<column>
##        |
##         2 | <source line>
##           | <caret>
function print_program_diagnostics(program: ref[loader.Program]) -> void:
    var i: ptr_uint = 0
    while i < program.diagnostics.len():
        let d = program.diagnostics.get(i) else:
            break
        unsafe:
            let rd = read(d)
            let message = rd.message.as_str()
            let location = rd.path.as_str()
            let prefix = if rd.severity == "warning": "warning" else: "error"
            stdio.print_format(
                c"%.*s[%.*s]: %.*s\n  --> %.*s:%d:%d\n",
                int<-(prefix.len), prefix.data,
                int<-(rd.code.len), rd.code.data,
                int<-(message.len), message.data,
                int<-(location.len), location.data,
                int<-(rd.line), int<-(rd.column),
            )
            # Show source context when the diagnostic has a real line and the
            # file is readable.
            if rd.line >= 1:
                match fs.read_text(location):
                    Result.success as source_content:
                        var source_str = source_content.value
                        defer source_str.release()
                        let source_text = source_str.as_str()
                        # Walk to the start of the target line.
                        var current_line: ptr_uint = 1
                        var pos: ptr_uint = 0
                        while pos < source_text.len and current_line < rd.line:
                            if source_text.byte_at(pos) == 10:
                                current_line += 1
                            pos += 1
                        let line_start = pos
                        while pos < source_text.len and source_text.byte_at(pos) != 10:
                            pos += 1
                        let line_end = pos
                        if line_start <= line_end:
                            let source_line = source_text.slice(line_start, line_end - line_start)
                            var gutter = rjust_line_number(rd.line)
                            defer gutter.release()
                            let gutter_str = gutter.as_str()
                            stdio.print_format(
                                c"   |\n%.*s | %.*s\n      | ",
                                int<-(gutter_str.len), gutter_str.data,
                                int<-(source_line.len), source_line.data,
                            )
                            var spaces = string.String.create()
                            defer spaces.release()
                            var sp: ptr_uint = 1
                            while sp < rd.column:
                                spaces.push_byte(32)
                                sp += 1
                            let spaces_text = spaces.as_str()
                            stdio.print_format(c"%.*s^\n", int<-(spaces_text.len), spaces_text.data)
                    Result.failure:
                        pass
        i += 1


## Append "<n> <singular|plural>" (e.g. "1 error", "3 errors") to `buf`.
function append_count_phrase(buf: ref[string.String], n: ptr_uint, singular: str, plural: str) -> void:
    buf.append(ptr_uint_to_str(n))
    buf.push_byte(32)
    if n == 1:
        buf.append(singular)
    else:
        buf.append(plural)


## Print the trailing check summary, matching the Ruby CLI: a blank line then
## `error: could not check due to <N errors[; M warnings]>`, or, when only
## warnings are present, `warning: <M warnings>`.
function report_check_summary(errors: ptr_uint, warnings: ptr_uint, file_count: ptr_uint, warnings_as_errors: bool) -> void:
    if errors == 0 and warnings == 0:
        return
    stdio.print_line("")
    var body = string.String.create()
    defer body.release()
    if errors > 0:
        append_count_phrase(ref_of(body), errors, "error", "errors")
    if warnings > 0:
        if errors > 0:
            body.append("; ")
        append_count_phrase(ref_of(body), warnings, "warning", "warnings")
    let body_str = body.as_str()
    if errors > 0:
        stdio.print_format(c"error: could not check due to %.*s\n", int<-(body_str.len), body_str.data)
    else:
        stdio.print_format(c"warning: %.*s\n", int<-(body_str.len), body_str.data)


## Lint source files and print `path:line: code: message` per warning, matching
## the Ruby `mtc lint` command.  Directories are expanded to their `.mt` files
## in sorted order.  Exits 1 when any warning is found.
function lint_command(args: span[str]) -> int:
    var input_paths = vec.Vec[str].create()
    defer input_paths.release()
    var select_set = vec.Vec[str].create()
    defer select_set.release()
    var ignore_set = vec.Vec[str].create()
    defer ignore_set.release()
    var fix_mode = false
    var i: ptr_uint = 1
    while i < args.len:
        let arg = args[i]
        if arg == "-I" or arg == "--root":
            i += 2
            continue
        if arg == "--fix":
            fix_mode = true
            i += 1
            continue
        if arg == "--select":
            i += 1
            if i < args.len:
                collect_filter_codes(args[i], ref_of(select_set))
            i += 1
            continue
        if arg == "--ignore":
            i += 1
            if i < args.len:
                collect_filter_codes(args[i], ref_of(ignore_set))
            i += 1
            continue
        if arg.starts_with("-"):
            # Other flags (--init, --locked, --profile) are silently skipped.
            i += 1
            continue
        input_paths.push(arg)
        i += 1

    if input_paths.is_empty():
        print_help()
        return 1

    # Collect .mt files.  Paths are copied into owned Strings so they do not
    # dangle when a directory listing's Entries buffer is released.
    var source_files = vec.Vec[string.String].create()
    defer source_files.release()
    var si: ptr_uint = 0
    while si < input_paths.len():
        let raw = input_paths.get(si) else:
            break
        let path = unsafe: read(raw)
        if fs.is_directory(path):
            match fs.list_files_recursive(path):
                Result.success as entries_payload:
                    var entries = entries_payload.value
                    defer entries.release()
                    var ei: ptr_uint = 0
                    while ei < entries.len():
                        match entries.get(ei):
                            Option.some as name_payload:
                                let entry_name = name_payload.value
                                if entry_name.ends_with(".mt") and not entry_name.starts_with("__mt_test_runner_"):
                                    source_files.push(string.String.from_str(entry_name))
                            Option.none:
                                pass
                        ei += 1
                Result.failure as err_payload:
                    var err_msg = err_payload.error
                    defer err_msg.release()
                    stdio.print_format(c"error: cannot list %.*s\n", int<-(path.len), path.data)
                    return 1
        else:
            source_files.push(string.String.from_str(path))
        si += 1

    var total_warnings: ptr_uint = 0
    var files_with_warnings: ptr_uint = 0

    var fi: ptr_uint = 0
    while fi < source_files.len():
        let fp_ptr = source_files.get(fi) else:
            break
        let fp = unsafe: read(fp_ptr).as_str()
        match fs.read_text(fp):
            Result.success as content:
                var src = content.value
                defer src.release()

                # `.mt-lint.yml` supplies select/ignore defaults (CLI flags
                # win) and the line-length limit.
                var cfg = lint_config.load_for_path(fp)
                defer cfg.release()
                var effective_select = vec.Vec[str].create()
                defer effective_select.release()
                var effective_ignore = vec.Vec[str].create()
                defer effective_ignore.release()
                merge_filter_codes(ref_of(effective_select), ref_of(select_set), ref_of(cfg.select))
                merge_filter_codes(ref_of(effective_ignore), ref_of(ignore_set), ref_of(cfg.ignore))
                let max_line_length = if cfg.max_line_length > 0: cfg.max_line_length else: 120z

                if fix_mode:
                    var fixed = fix_engine.fix_source(
                        src.as_str(),
                        fp,
                        span[str](),
                        ref_of(effective_select),
                        ref_of(effective_ignore)
                    )
                    defer fixed.release()
                    if not fixed.as_str().equal(src.as_str()):
                        match fs.write_text(fp, fixed.as_str()):
                            Result.success:
                                stdio.print_format(c"fixed %.*s\n", int<-(fp.len), fp.data)
                            Result.failure as write_err:
                                var wem = write_err.error
                                defer wem.release()
                                stdio.print_format(c"error: cannot write %.*s\n", int<-(fp.len), fp.data)
                    fi += 1
                    continue

                var diags = vec.Vec[pstate.ParseDiagnostic].create()
                defer diags.release()
                let file = parser.parse_source(src.as_str(), ref_of(diags))
                var warns = linter.lint_source_opts(file, src.as_str(), fp, span[str](), max_line_length)
                defer warns.release()
                var filtered = vec.Vec[linter.Warning].create()
                defer filtered.release()
                var wi: ptr_uint = 0
                while wi < warns.len():
                    let wp = warns.get(wi) else:
                        break
                    unsafe:
                        let w = read(wp)
                        if warning_allowed(w.code, ref_of(effective_select), ref_of(effective_ignore)):
                            filtered.push(w)
                    wi += 1
                if filtered.len() > 0:
                    files_with_warnings += 1
                total_warnings += filtered.len()
                wi = 0
                while wi < filtered.len():
                    let wp = filtered.get(wi) else:
                        break
                    unsafe:
                        let w = read(wp)
                        stdio.print_format(
                            c"%.*s:%d: %.*s: %.*s\n",
                            int<-(w.path.len), w.path.data,
                            int<-(w.line),
                            int<-(w.code.len), w.code.data,
                            int<-(w.message.len), w.message.data,
                        )
                    wi += 1
            Result.failure as read_err:
                var em = read_err.error
                em.release()
        fi += 1

    if fix_mode:
        return 0

    if total_warnings == 0:
        if input_paths.len() == 1:
            let ip = input_paths.get(0) else:
                return 0
            let ip_str = unsafe: read(ip)
            stdio.print_format(c"clean %.*s\n", int<-(ip_str.len), ip_str.data)
        else:
            stdio.print_format(c"clean %d file(s)\n", int<-(source_files.len()))
        return 0

    let noun = if total_warnings == 1: "warning" else: "warnings"
    var files_str = string.String.create()
    defer files_str.release()
    if files_with_warnings == 1:
        files_str.append("1 file")
    else:
        files_str.append(ptr_uint_to_str(files_with_warnings))
        files_str.append(" files")
    let files_text = files_str.as_str()
    stdio.print_format(
        c"Found %d %.*s in %.*s.\n",
        int<-(total_warnings),
        int<-(noun.len), noun.data,
        int<-(files_text.len), files_text.data,
    )
    return 1


## CLI filter codes win over config-file codes; config is the fallback.
## The output holds views into the CLI args or the (caller-kept) config.
function merge_filter_codes(
    output: ref[vec.Vec[str]],
    cli_codes: ref[vec.Vec[str]],
    config_codes: ref[vec.Vec[string.String]],
) -> void:
    if cli_codes.len() > 0:
        var i: ptr_uint = 0
        while i < cli_codes.len():
            let cp = cli_codes.get(i) else:
                break
            unsafe:
                output.push(read(cp))
            i += 1
        return
    var i: ptr_uint = 0
    while i < config_codes.len():
        let cp = config_codes.get(i) else:
            break
        unsafe:
            output.push(read(cp).as_str())
        i += 1


function warning_allowed(code: str, select_set: ref[vec.Vec[str]], ignore_set: ref[vec.Vec[str]]) -> bool:
    if ignore_set.len() > 0:
        var i: ptr_uint = 0
        while i < ignore_set.len():
            let ep = ignore_set.get(i) else:
                break
            if code.equal(unsafe: read(ep)):
                return false
            i += 1
    if select_set.len() > 0:
        var i: ptr_uint = 0
        while i < select_set.len():
            let ep = select_set.get(i) else:
                break
            if code.equal(unsafe: read(ep)):
                return true
            i += 1
        return false
    return true


function collect_filter_codes(list: str, output: ref[vec.Vec[str]]) -> void:
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < list.len:
        if list.byte_at(i) == ',':
            if i > start:
                output.push(list.slice(start, i - start))
            start = i + 1
        i += 1
    if i > start:
        output.push(list.slice(start, i - start))


## Parse a `--platform NAME` / `--profile NAME` argument value into a
## Platform enum.  Prints an error and returns none when the name is invalid.
function parse_platform_name(name: str) -> Option[resolver.Platform]:
    if name == "linux":
        return Option[resolver.Platform].some(value = resolver.Platform.linux)
    if name == "windows":
        return Option[resolver.Platform].some(value = resolver.Platform.windows)
    if name == "wasm":
        return Option[resolver.Platform].some(value = resolver.Platform.wasm)
    stdio.print_line("error: --platform must be linux, windows, or wasm")
    return Option[resolver.Platform].none


## The canonical name of a target platform (inverse of parse_platform_name).
function platform_label(platform: resolver.Platform) -> str:
    match platform:
        resolver.Platform.windows:
            return "windows"
        resolver.Platform.wasm:
            return "wasm"
        _:
            return "linux"


## Parse the `[-I DIR]... [--platform NAME] <source>` argument tail shared by
## the lower, emit-c, and build commands.  Fills `roots` (defaulting to the source
## directory when none is given), sets `platform` to the parsed platform (defaults
## to linux), and returns the source path, or none after printing an error / usage.
function parse_source_operand(args: span[str], roots: ref[vec.Vec[str]], platform: ref[resolver.Platform]) -> Option[str]:
    var file_path: Option[str] = Option[str].none
    var i: ptr_uint = 1
    while i < args.len:
        let arg = args[i]
        if arg == "--root" or arg == "-I":
            if i + 1 >= args.len:
                stdio.print_line("error: -I requires a directory")
                return Option[str].none
            roots.push(args[i + 1])
            i += 2
            continue
        if arg == "--platform":
            if i + 1 >= args.len:
                stdio.print_line("error: --platform requires linux, windows, or wasm")
                return Option[str].none
            match parse_platform_name(args[i + 1]):
                Option.some as plat:
                    read(platform) = plat.value
                Option.none:
                    return Option[str].none
            i += 2
            continue
        match file_path:
            Option.some:
                stdio.print_line("error: command accepts a single source path")
                return Option[str].none
            Option.none:
                file_path = Option[str].some(value = arg)
        i += 1

    match file_path:
        Option.some as p:
            if roots.is_empty():
                roots.push(path_ops.dirname(p.value))
                discover_project_root(p.value, roots)
            return Option[str].some(value = p.value)
        Option.none:
            print_help()
            return Option[str].none


## Reject a raw `external`-file target for a C-emitting command (lower, emit-c,
## build, run), printing the same message Ruby's Lowering raises.  Returns true
## when the root is a raw module (message already printed); the caller then
## cleans up and returns 1.
function reject_external_root(program: loader.Program) -> bool:
    if not program.root_is_raw_module():
        return false
    let name = program.root_module_name()
    stdio.print_format(c"cannot emit C for external file %.*s\n", int<-(name.len), name.data)
    return true


## Reject a build/run target with no valid executable entrypoint, mirroring
## Ruby's Build.ensure_program_has_entrypoint!.  Call after external-file
## rejection with the lowered IR.  Returns true when there is no entrypoint
## (message already printed); the caller then cleans up and returns 1.
function reject_missing_entrypoint(program: loader.Program, ir_program: ir.Program) -> bool:
    if ir.has_entrypoint(ir_program):
        return false
    if program.root_has_main():
        stdio.print_line("root main is not a valid executable entrypoint; expected `function main() -> int|void`, `function main(argc: int, argv: ptr[cstr]) -> int|void`, `function main(argc: int, argv: ptr[ptr[char]]) -> int|void`, or `function main(args: span[str]) -> int|void`")
    else:
        stdio.print_line("no executable entrypoint found; define `main` with one of the supported executable signatures")
    return true


## Lower a checked program to IR and print it (`mtc lower`).
## Supports both `.mt` files and package directory targets.
function lower_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer roots.release()
    var platform = resolver.Platform.linux
    let path = parse_source_operand(args, ref_of(roots), ref_of(platform)) else:
        return 1

    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer program.release()

    if program.diagnostic_error_count() > 0:
        print_program_diagnostics(ref_of(program))
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    if reject_external_root(program):
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    let ir_program = lowering.lower(program)
    var rendered = ir_formatter.format_program(ir_program)
    defer rendered.release()
    let text = rendered.as_str()
    stdio.print_format(c"%.*s", int<-(text.len), text.data)
    entry_path_owner.release()
    source_root_owner.release()
    return 0


## Compile a checked program to C and print it (`mtc emit-c`).
## Supports both `.mt` files and package directory targets.
function emit_c_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer roots.release()
    var platform = resolver.Platform.linux
    let path = parse_source_operand(args, ref_of(roots), ref_of(platform)) else:
        return 1

    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer program.release()

    if program.diagnostic_error_count() > 0:
        print_program_diagnostics(ref_of(program))
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    if reject_external_root(program):
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    let ir_program = lowering.lower(program)
    var c_source = c_backend.generate_c(ir_program)
    defer c_source.release()
    let text = c_source.as_str()
    stdio.print_format(c"%.*s", int<-(text.len), text.data)
    entry_path_owner.release()
    source_root_owner.release()
    return 0


## Extract a string value from a TOML document at the given section and key.
## Handles [section] headers and key = "value" assignments with double-quoted
## string values.  Comments (#) and blank lines are skipped.
function read_toml_str(source: str, section: str, key: str) -> Option[string.String]:
    var current: Option[str] = Option[str].none
    var pos: ptr_uint = 0
    let end_pos = source.len
    while pos < end_pos:
        let b = source.byte_at(pos)
        if b == 10:
            pos += 1
            continue
        if b == 13:
            pos += 1
            if pos < end_pos and source.byte_at(pos) == 10:
                pos += 1
            continue
        if b == 35:
            pos = skip_line(source, pos)
            continue
        if b == 91:
            let close = find_byte(source, pos + 1, ubyte<-91, ubyte<-93) else:
                pos = skip_line(source, pos)
                continue
            let sec_name = source.slice(pos + 1, close - pos - 1)
            current = Option[str].some(value= sec_name)
            pos = close + 1
            continue
        if b == 9 or b == 32:
            pos += 1
            continue
        match current:
            Option.some as sec:
                if sec.value == section:
                    let eq = find_byte(source, pos, ubyte<-91, ubyte<-61) else:
                        pos = skip_line(source, pos)
                        continue
                    let key_end = trim_right(source, pos, eq)
                    let line_key = source.slice(pos, key_end - pos)
                    if line_key == key:
                        let val_start = skip_ws_to(source, eq + 1, ubyte<-34) else:
                            pos = skip_line(source, pos)
                            continue
                        let val_end = find_byte(source, val_start + 1, ubyte<-91, ubyte<-34) else:
                            pos = skip_line(source, pos)
                            continue
                        return Option[string.String].some(value= string.String.from_str(
                            source.slice(val_start + 1, val_end - val_start - 1)
                        ))
                pos = skip_line(source, pos)
            Option.none:
                pos = skip_line(source, pos)

    return Option[string.String].none


function skip_line(source: str, pos: ptr_uint) -> ptr_uint:
    var cur = pos
    let end_pos = source.len
    while cur < end_pos:
        if source.byte_at(cur) == 10:
            return cur + 1
        cur += 1
    return end_pos


function find_byte(source: str, start: ptr_uint, t1: ubyte, needle: ubyte) -> Option[ptr_uint]:
    var pos = start
    let end_pos = source.len
    while pos < end_pos:
        let b = source.byte_at(pos)
        if b == 10 or b == t1:
            return Option[ptr_uint].none
        if b == needle:
            return Option[ptr_uint].some(value= pos)
        pos += 1
    return Option[ptr_uint].none


function skip_ws_to(source: str, start: ptr_uint, target: ubyte) -> Option[ptr_uint]:
    var pos = start
    let end_pos = source.len
    while pos < end_pos:
        let b = source.byte_at(pos)
        if b == target:
            return Option[ptr_uint].some(value= pos)
        if b == 10 or b == 13 or b == 35:
            return Option[ptr_uint].none
        if b != 9 and b != 32:
            return Option[ptr_uint].none
        pos += 1
    return Option[ptr_uint].none


function trim_right(source: str, start: ptr_uint, end: ptr_uint) -> ptr_uint:
    var pos = end
    while pos > start:
        let b = source.byte_at(pos - 1)
        if b != 32 and b != 9:
            return pos
        pos -= 1
    return start


## Resolve a directory target to its effective build entry path.  Reads
## `<dir>/package.toml`, extracts `build.entry` (defaulting to `src/main.mt`),
## and adds `<dir>/<source_root>` to `roots`.  The returned string borrows from
## `entry_owner` — keep both alive for the duration of the build.
function resolve_package_entry(dir: str, roots: ref[vec.Vec[str]], entry_owner: ref[string.String], source_root_owner: ref[string.String]) -> Option[str]:
    var manifest_path = path_ops.join(dir, "package.toml")
    defer manifest_path.release()
    if not fs.is_file(manifest_path.as_str()):
        stdio.print_format(
            c"error: no package.toml found in %.*s\n",
            int<-(dir.len), dir.data,
        )
        return Option[str].none

    match fs.read_text(manifest_path.as_str()):
        Result.failure:
            stdio.print_format(
                c"error: cannot read %.*s\n",
                int<-(manifest_path.as_str().len), manifest_path.as_str().data,
            )
            return Option[str].none
        Result.success as payload:
            var source = payload.value
            defer source.release()
            let toml_text = source.as_str()

            let entry_val = read_toml_str(toml_text, "build", "entry")
            read(entry_owner) = string.String.from_str("src/main.mt")
            match entry_val:
                Option.some as e:
                    read(entry_owner).release()
                    read(entry_owner) = e.value
                Option.none:
                    pass

            let root_val = read_toml_str(toml_text, "package", "source_root")
            read(source_root_owner) = string.String.from_str("src")
            match root_val:
                Option.some as r:
                    read(source_root_owner).release()
                    read(source_root_owner) = r.value
                Option.none:
                    pass

    var source_root_path = path_ops.join(dir, source_root_owner.as_str())
    roots.push(source_root_path.as_str())
    var entry_path = path_ops.join(dir, entry_owner.as_str())
    read(entry_owner).release()
    read(entry_owner) = entry_path
    return Option[str].some(value= entry_owner.as_str())


## Resolve the effective source path for a build target.  When `raw_path` is a
## directory, discovers package.toml and extracts the build entry; returns the
## resolved `.mt` file path.  When it is a plain file the path is returned
## as-is.  `entry_owner` and `source_root_owner` hold any package-derived
## borrows — keep both alive for the duration of the compilation.
function effective_source_path(raw_path: str, roots: ref[vec.Vec[str]], entry_owner: ref[string.String], source_root_owner: ref[string.String]) -> Option[str]:
    if fs.is_directory(raw_path):
        return resolve_package_entry(raw_path, roots, entry_owner, source_root_owner)

    return Option[str].some(value= raw_path)


## Walk up from `source_path` to find the nearest parent directory that
## contains a `std/` subdirectory, and push it onto `roots`.
## The backing string is stored in the module-level `owned_roots` Vec.
## Walk up from `source_path` to find the nearest parent directory that
## contains a `std/` subdirectory, and push it onto `roots`.
## Works entirely with non-owning str views borrowed from `source_path`,
## so no allocations are needed.
function discover_project_root(source_path: str, roots: ref[vec.Vec[str]]) -> void:
    var current = if fs.is_directory(source_path): source_path else: path_ops.dirname(source_path)
    while true:
        var joined = path_ops.join(current, "std")
        defer joined.release()
        if fs.is_directory(joined.as_str()):
            var i: ptr_uint = 0
            while i < roots.len():
                let ep = roots.get(i) else:
                    break
                if current.equal(unsafe: read(ep)):
                    return
                i += 1
            roots.push(current)
            return
        let parent = path_ops.dirname(current)
        if parent.equal(current):
            return
        current = parent


## Build a program (`mtc build`).  Supports both single `.mt` files and package
## directory targets (reads package.toml for the entry point).
function build_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer roots.release()
    var output_override: Option[str] = Option[str].none
    var keep_c_path: Option[str] = Option[str].none
    var c_compiler = "cc"
    var profile_name = "debug"
    var platform = resolver.Platform.linux
    var clean_mode = false
    var use_cache = true
    var sanitize = false
    var filtered = vec.Vec[str].create()
    defer filtered.release()
    filtered.push("build")
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "-o":
            if ai + 1 >= args.len:
                stdio.print_line("error: -o requires an output path")
                return 1
            output_override = Option[str].some(value= args[ai + 1])
            ai += 2
            continue
        if arg == "--clean":
            clean_mode = true
            ai += 1
            continue
        if arg == "--keep-c":
            if ai + 1 >= args.len:
                stdio.print_line("error: --keep-c requires a path")
                return 1
            keep_c_path = Option[str].some(value= args[ai + 1])
            ai += 2
            continue
        if arg == "--cc":
            if ai + 1 >= args.len:
                stdio.print_line("error: --cc requires a compiler name")
                return 1
            c_compiler = args[ai + 1]
            ai += 2
            continue
        if arg == "--no-cache":
            use_cache = false
            ai += 1
            continue
        if arg == "--sanitize":
            sanitize = true
            use_cache = false
            ai += 1
            continue
        if arg == "--profile":
            if ai + 1 >= args.len:
                stdio.print_line("error: --profile requires a profile name (debug or release)")
                return 1
            profile_name = args[ai + 1]
            if not profile_name == "debug" and not profile_name == "release":
                stdio.print_line("error: --profile must be debug or release")
                return 1
            ai += 2
            continue
        if arg == "--platform":
            if ai + 1 >= args.len:
                stdio.print_line("error: --platform requires linux, windows, or wasm")
                return 1
            match parse_platform_name(args[ai + 1]):
                Option.some as plat:
                    platform = plat.value
                Option.none:
                    return 1
            ai += 2
            continue
        filtered.push(arg)
        ai += 1
    let path = parse_source_operand(filtered.as_span(), ref_of(roots), ref_of(platform)) else:
        return 1

    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1

    # --clean removes the generated output artifact without compiling.
    if clean_mode:
        var clean_output: string.String
        if output_override.is_some():
            clean_output = string.String.from_str(output_override.unwrap())
        else:
            clean_output = default_output_path(effective)
        defer clean_output.release()
        if fs.exists(clean_output.as_str()):
            match fs.remove(clean_output.as_str()):
                Result.success:
                    stdio.print_format(c"cleaned %.*s\n", int<-(clean_output.as_str().len), clean_output.as_str().data)
                Result.failure as failure:
                    var msg = failure.error
                    defer msg.release()
                    stdio.print_format(c"error: cannot remove %.*s\n", int<-(clean_output.as_str().len), clean_output.as_str().data)
                    entry_path_owner.release()
                    source_root_owner.release()
                    return 1
        else:
            stdio.print_format(c"cleaned %.*s\n", int<-(clean_output.as_str().len), clean_output.as_str().data)
        entry_path_owner.release()
        source_root_owner.release()
        return 0

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer program.release()

    if program.diagnostic_error_count() > 0:
        print_program_diagnostics(ref_of(program))
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    if reject_external_root(program):
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    let ir_program = lowering.lower(program)

    if reject_missing_entrypoint(program, ir_program):
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    if keep_c_path.is_some():
        keep_c_to_file(ir_program, keep_c_path.unwrap())

    var output_path: string.String
    if output_override.is_some():
        output_path = string.String.from_str(output_override.unwrap())
    else:
        output_path = default_output_path(effective)

    # Binary cache: an unchanged program (same mtc executable, C compiler,
    # configuration, and module sources) reuses the previously built binary.
    # --keep-c always rebuilds so the saved C matches the produced binary.
    let cache_enabled = use_cache and keep_c_path.is_none()
    var cache_key = string.String.create()
    defer cache_key.release()
    if cache_enabled:
        var computed_key = build_cache.compute_key(ref_of(program), c_compiler, platform_label(platform))
        cache_key.append(computed_key.as_str())
        computed_key.release()
        match build_cache.lookup(cache_key.as_str()):
            Option.some as hit:
                var cached = hit.value
                let copied = build_cache.materialize(cached.as_str(), output_path.as_str())
                cached.release()
                if copied:
                    stdio.print_format(
                        c"built %.*s -> %.*s  [cached]\n",
                        int<-(effective.len), effective.data,
                        int<-(output_path.as_str().len), output_path.as_str().data,
                    )
                    output_path.release()
                    entry_path_owner.release()
                    source_root_owner.release()
                    return 0
            Option.none:
                pass

    match build_driver.build(program, ir_program, output_path.as_str(), c_compiler, roots.as_span(), sanitize):
        Result.success as built:
            var output = built.value
            defer output.release()
            output_path.release()
            if cache_enabled:
                build_cache.store(cache_key.as_str(), output.as_str())
            stdio.print_format(
                c"built %.*s -> %.*s\n",
                int<-(effective.len), effective.data,
                int<-(output.as_str().len), output.as_str().data,
            )
            entry_path_owner.release()
            source_root_owner.release()
            return 0
        Result.failure as failure:
            var message = failure.error
            defer message.release()
            let text = message.as_str()
            stdio.print_format(c"error: %.*s\n", int<-(text.len), text.data)
            output_path.release()
            entry_path_owner.release()
            source_root_owner.release()
            return 1


## Run a program (`mtc run`).  Builds and then executes the binary.
function run_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer roots.release()
    var output_override: Option[str] = Option[str].none
    var c_compiler = "cc"
    var profile_name = "debug"
    var platform = resolver.Platform.linux
    var use_cache = true
    var sanitize = false
    var program_args = vec.Vec[str].create()
    defer program_args.release()
    var filtered = vec.Vec[str].create()
    defer filtered.release()
    filtered.push("run")
    var ai: ptr_uint = 1
    var seen_dashdash = false
    while ai < args.len:
        let arg = args[ai]
        if seen_dashdash:
            program_args.push(args[ai])
            ai += 1
            continue
        if arg == "--":
            seen_dashdash = true
            ai += 1
            continue
        if arg == "--cc":
            if ai + 1 >= args.len:
                stdio.print_line("error: --cc requires a compiler name")
                return 1
            c_compiler = args[ai + 1]
            ai += 2
            continue
        if arg == "--no-cache":
            use_cache = false
            ai += 1
            continue
        if arg == "--cc":
            if ai + 1 >= args.len:
                stdio.print_line("error: --cc requires a compiler name")
                return 1
            c_compiler = args[ai + 1]
            ai += 2
            continue
        if arg == "--no-cache":
            use_cache = false
            ai += 1
            continue
        if arg == "--profile":
            if ai + 1 >= args.len:
                stdio.print_line("error: --profile requires a profile name (debug or release)")
                return 1
            profile_name = args[ai + 1]
            if not profile_name == "debug" and not profile_name == "release":
                stdio.print_line("error: --profile must be debug or release")
                return 1
            ai += 2
            continue
        if arg == "--platform":
            if ai + 1 >= args.len:
                stdio.print_line("error: --platform requires linux, windows, or wasm")
                return 1
            match parse_platform_name(args[ai + 1]):
                Option.some as plat:
                    platform = plat.value
                Option.none:
                    return 1
            ai += 2
            continue
        filtered.push(arg)
        ai += 1
    let path = parse_source_operand(filtered.as_span(), ref_of(roots), ref_of(platform)) else:
        return 1
    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer program.release()

    if program.diagnostic_error_count() > 0:
        print_program_diagnostics(ref_of(program))
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    if reject_external_root(program):
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    let ir_program = lowering.lower(program)

    if reject_missing_entrypoint(program, ir_program):
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    var output_path: string.String
    if output_override.is_some():
        output_path = string.String.from_str(output_override.unwrap())
    else:
        output_path = default_output_path(effective)

    # Binary cache: reuse the previously built binary when nothing changed.
    var cache_key = string.String.create()
    defer cache_key.release()
    if use_cache:
        var computed_key = build_cache.compute_key(ref_of(program), c_compiler, platform_label(platform))
        cache_key.append(computed_key.as_str())
        computed_key.release()
        match build_cache.lookup(cache_key.as_str()):
            Option.some as hit:
                var cached = hit.value
                let copied = build_cache.materialize(cached.as_str(), output_path.as_str())
                cached.release()
                if copied:
                    var cached_output = string.String.from_str(output_path.as_str())
                    defer cached_output.release()
                    output_path.release()
                    entry_path_owner.release()
                    source_root_owner.release()
                    return execute_binary(cached_output.as_str(), ref_of(program_args))
            Option.none:
                pass

    match build_driver.build(program, ir_program, output_path.as_str(), c_compiler, roots.as_span(), sanitize):
        Result.success as built:
            var built_path = built.value
            defer built_path.release()
            var owned_output = string.String.from_str(output_path.as_str())
            output_path.release()
            defer owned_output.release()
            entry_path_owner.release()
            source_root_owner.release()
            if use_cache:
                build_cache.store(cache_key.as_str(), owned_output.as_str())
            return execute_binary(owned_output.as_str(), ref_of(program_args))
        Result.failure as failure:
            var message = failure.error
            defer message.release()
            let text = message.as_str()
            stdio.print_format(c"error: %.*s\n", int<-(text.len), text.data)
            output_path.release()
            entry_path_owner.release()
            source_root_owner.release()
            return 1


## Execute a built binary with the forwarded program arguments, streaming its
## captured stdout/stderr and returning the normalized exit code.
function execute_binary(binary_path: str, program_args: ref[vec.Vec[str]]) -> int:
    var cmd = vec.Vec[str].create()
    defer cmd.release()
    cmd.push(binary_path)
    var pai: ptr_uint = 0
    while pai < program_args.len():
        let pa_ptr = program_args.get(pai) else:
            break
        unsafe:
            cmd.push(read(pa_ptr))
        pai += 1

    match process.capture(cmd.as_span()):
        Result.success as captured:
            var capture_result = captured.value
            defer capture_result.release()
            let stdout_text_opt = capture_result.stdout_text()
            if stdout_text_opt.is_some():
                let stdout_text = stdout_text_opt.unwrap()
                stdio.print_format(c"%.*s", int<-(stdout_text.len), stdout_text.data)
            let stderr_text_opt = capture_result.stderr_text()
            if stderr_text_opt.is_some():
                let stderr_text = stderr_text_opt.unwrap()
                let _w = terminal.write_stderr(stderr_text)
            return capture_result.status.normalized_code()
        Result.failure:
            stdio.print_format(c"error: cannot execute '%.*s'\n", int<-(binary_path.len), binary_path.data)
            return 1


## Resolve, build, and run a module by name (`mtc run-module std.tool.x`).
## The module name maps to `<name with . as />.mt`, resolved against each
## module root as `<root>/std/<rel>` then `<root>/<rel>` — mirroring Ruby's
## resolve_app_module.  The resolved file then flows through the ordinary
## `run` path with all other arguments preserved.
function run_module_command(args: span[str]) -> int:
    var module_name: Option[str] = Option[str].none
    var module_index: ptr_uint = 0
    var roots = vec.Vec[str].create()
    defer roots.release()

    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--":
            break
        if arg == "--root" or arg == "-I":
            if ai + 1 >= args.len:
                stdio.print_line("error: -I requires a directory")
                return 1
            roots.push(args[ai + 1])
            ai += 2
            continue
        if arg == "-o" or arg == "--cc" or arg == "--profile" or arg == "--platform" or arg == "--keep-c":
            ai += 2
            continue
        if arg.starts_with("-"):
            ai += 1
            continue
        module_name = Option[str].some(value = arg)
        module_index = ai
        break

    let name = module_name else:
        stdio.print_line("missing module name")
        return 1

    # Ambient roots: the current directory plus its enclosing project root.
    var cwd = string.String.create()
    defer cwd.release()
    match fs.current_directory():
        Result.success as dir_payload:
            cwd.release()
            cwd = dir_payload.value
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            dir_error.release()
    if cwd.len() > 0:
        roots.push(cwd.as_str())
        discover_project_root(cwd.as_str(), ref_of(roots))

    var resolved = resolve_app_module(name, ref_of(roots)) else:
        stdio.print_format(c"run-module module not found: %.*s\n", int<-(name.len), name.data)
        return 1
    defer resolved.release()

    var run_args = vec.Vec[str].create()
    defer run_args.release()
    run_args.push("run")
    var ri: ptr_uint = 1
    while ri < args.len:
        if ri == module_index:
            run_args.push(resolved.as_str())
        else:
            run_args.push(args[ri])
        ri += 1
    return run_command(run_args.as_span())


## Resolve a module name (`a.b.c`) to a source file against the module roots,
## preferring `<root>/std/a/b/c.mt` over `<root>/a/b/c.mt`.
function resolve_app_module(name: str, roots: ref[vec.Vec[str]]) -> Option[string.String]:
    var relative = string.String.create()
    defer relative.release()
    var ni: ptr_uint = 0
    while ni < name.len:
        let b = name.byte_at(ni)
        if b == '.':
            relative.push_byte('/')
        else:
            relative.push_byte(b)
        ni += 1
    relative.append(".mt")

    var i: ptr_uint = 0
    while i < roots.len():
        let root_ptr = roots.get(i) else:
            break
        let root = unsafe: read(root_ptr)
        var std_prefix = path_ops.join(root, "std")
        var std_candidate = path_ops.join(std_prefix.as_str(), relative.as_str())
        std_prefix.release()
        if fs.is_file(std_candidate.as_str()):
            return Option[string.String].some(value = std_candidate)
        std_candidate.release()
        var candidate = path_ops.join(root, relative.as_str())
        if fs.is_file(candidate.as_str()):
            return Option[string.String].some(value = candidate)
        candidate.release()
        i += 1
    return Option[string.String].none


## Scaffold a new application package (`mtc new my-project`): package.toml with
## a snake_case package name derived from the directory basename, plus an
## `src/main.mt` entry — mirroring Ruby's ProjectScaffold.
function new_command(args: span[str]) -> int:
    if args.len < 2:
        stdio.print_line("missing project name")
        return 1
    if args.len > 2:
        let extra = args[2]
        stdio.print_format(c"unknown new option %.*s\n", int<-(extra.len), extra.data)
        return 1

    let target = args[1]
    var absolute = string.String.create()
    defer absolute.release()
    if path_ops.is_absolute(target):
        absolute.append(target)
    else:
        match fs.current_directory():
            Result.success as dir_payload:
                var cwd = dir_payload.value
                var joined = path_ops.join(cwd.as_str(), target)
                cwd.release()
                absolute.append(joined.as_str())
                joined.release()
            Result.failure as dir_failure:
                var dir_error = dir_failure.error
                dir_error.release()
                absolute.append(target)

    let abs_path = absolute.as_str()
    if fs.exists(abs_path) and not fs.is_directory(abs_path):
        stdio.print_format(c"project path is not a directory: %.*s\n", int<-(abs_path.len), abs_path.data)
        return 1
    if fs.is_directory(abs_path):
        match fs.list_entries(abs_path):
            Result.success as entries_payload:
                var entries = entries_payload.value
                let count = entries.len()
                entries.release()
                if count > 0:
                    stdio.print_format(
                        c"project directory already exists and is not empty: %.*s\n",
                        int<-(abs_path.len), abs_path.data,
                    )
                    return 1
            Result.failure as list_failure:
                var list_error = list_failure.error
                list_error.release()

    var entry_dir = path_ops.join(abs_path, "src")
    defer entry_dir.release()
    match fs.create_directories(entry_dir.as_str()):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            dir_error.release()
            stdio.print_format(c"could not create project directory: %.*s\n", int<-(abs_path.len), abs_path.data)
            return 1
        Result.success:
            pass

    var package_name = snake_case_identifier(path_ops.basename(abs_path))
    defer package_name.release()

    var manifest = string.String.create()
    defer manifest.release()
    manifest.append("[package]\nname = \"")
    manifest.append(package_name.as_str())
    manifest.append("\"\nversion = \"0.1.0\"\nsource_root = \"src\"\n\n[build]\nentry = \"src/main.mt\"\n")

    var manifest_path = path_ops.join(abs_path, "package.toml")
    defer manifest_path.release()
    match fs.write_text(manifest_path.as_str(), manifest.as_str()):
        Result.failure as write_failure:
            var write_error = write_failure.error
            write_error.release()
            stdio.print_line("could not write package.toml")
            return 1
        Result.success:
            pass

    var entry_path = path_ops.join(entry_dir.as_str(), "main.mt")
    defer entry_path.release()
    match fs.write_text(entry_path.as_str(), "function main() -> int:\n    return 0\n"):
        Result.failure as entry_failure:
            var entry_error = entry_failure.error
            entry_error.release()
            stdio.print_line("could not write src/main.mt")
            return 1
        Result.success:
            pass

    stdio.print_format(c"created %.*s\n", int<-(abs_path.len), abs_path.data)
    return 0


## Normalize a directory basename to a snake_case package identifier, matching
## Ruby's PackageManifest.snake_case_identifier: camelCase boundaries become
## underscores, `-` and spaces map to `_`, runs of `_` collapse, and the result
## is lowercased (`MyProject` → `my_project`, `demo-app` → `demo_app`).
function snake_case_identifier(name: str) -> string.String:
    var result = string.String.create()
    var i: ptr_uint = 0
    while i < name.len:
        let b = name.byte_at(i)
        var mapped = b
        var boundary = false
        if b == '-' or b == ' ':
            mapped = '_'
        else if b >= 'A' and b <= 'Z':
            mapped = b + 32
            if i > 0:
                let prev = name.byte_at(i - 1)
                let prev_lower_or_digit = (prev >= 'a' and prev <= 'z') or (prev >= '0' and prev <= '9')
                let prev_upper_or_digit = (prev >= 'A' and prev <= 'Z') or (prev >= '0' and prev <= '9')
                var next_is_lower = false
                if i + 1 < name.len:
                    let next = name.byte_at(i + 1)
                    next_is_lower = next >= 'a' and next <= 'z'
                if prev_lower_or_digit:
                    boundary = true
                else if prev_upper_or_digit and next_is_lower:
                    boundary = true
        if boundary:
            result.push_byte('_')
        # Collapse runs of underscores (including pre-existing ones).
        if mapped == '_':
            if result.len() > 0 and result.as_str().byte_at(result.len() - 1) == '_':
                i += 1
                continue
        result.push_byte(mapped)
        i += 1
    return result


## Print a shell completion script (`mtc completions bash|zsh|fish`), mirroring
## Ruby's completions_command for the self-host's implemented command set.
function completions_command(args: span[str]) -> int:
    if args.len < 2:
        stdio.print_line("completions: shell must be bash, zsh, or fish")
        return 1
    let shell = args[1]
    if shell == "bash":
        stdio.print_line("# mtc bash completion. Source this file or install it into your bash")
        stdio.print_line("# completion directory (e.g. /etc/bash_completion.d/mtc).")
        stdio.print_line("_mtc() {")
        stdio.print_line("  local cur=\"${COMP_WORDS[COMP_CWORD]}\"")
        stdio.print_line("  if [ \"${COMP_CWORD}\" -eq 1 ]; then")
        stdio.print_line("    COMPREPLY=( $(compgen -W \"check build run run-module test new format lint lex parse lower emit-c completions help version\" -- \"${cur}\") )")
        stdio.print_line("  fi")
        stdio.print_line("}")
        stdio.print_line("complete -F _mtc mtc")
        return 0
    if shell == "zsh":
        stdio.print_line("#compdef mtc")
        stdio.print_line("# mtc zsh completion. Install onto your $fpath as _mtc.")
        stdio.print_line("_mtc() {")
        stdio.print_line("  local -a commands")
        stdio.print_line("  commands=(")
        var zi: ptr_uint = 0
        while zi < command_summary_count():
            let entry = command_summary_at(zi)
            stdio.print_format(c"    '%.*s:%.*s'\n", int<-(entry.name.len), entry.name.data, int<-(entry.summary.len), entry.summary.data)
            zi += 1
        stdio.print_line("  )")
        stdio.print_line("  if (( CURRENT == 2 )); then")
        stdio.print_line("    _describe 'mtc command' commands")
        stdio.print_line("  fi")
        stdio.print_line("}")
        stdio.print_line("_mtc \"$@\"")
        return 0
    if shell == "fish":
        stdio.print_line("# mtc fish completion. Install into ~/.config/fish/completions/mtc.fish.")
        var fi: ptr_uint = 0
        while fi < command_summary_count():
            let entry = command_summary_at(fi)
            stdio.print_format(
                c"complete -c mtc -f -n '__fish_use_subcommand' -a %.*s -d '%.*s'\n",
                int<-(entry.name.len), entry.name.data,
                int<-(entry.summary.len), entry.summary.data,
            )
            fi += 1
        return 0
    stdio.print_line("completions: shell must be bash, zsh, or fish")
    return 1


function cache_command(args: span[str]) -> int:
    if args.len < 2:
        stdio.print_line("mtc cache <subcommand>")
        stdio.print_line("")
        stdio.print_line("Commands:")
        stdio.print_line("  purge   Delete the build cache")
        stdio.print_line("  status  Show cache entry count and total size")
        stdio.print_line("")
        stdio.print_line("Flags:")
        stdio.print_line("  --help  Show cache command help")
        return 1
    let sub = args[1]
    if sub == "--help" or sub == "-h":
        stdio.print_line("mtc cache <subcommand>")
        stdio.print_line("")
        stdio.print_line("Commands:")
        stdio.print_line("  purge   Delete the build cache")
        stdio.print_line("  status  Show cache entry count and total size")
        return 0
    if sub == "purge":
        match build_cache.purge():
            Result.failure as failure:
                var msg = string.String.from_str("cache purge failed: ")
                msg.append(failure.error.as_str())
                let msg_text = msg.as_str()
                stdio.print_format(c"%.*s\n", int<-(msg_text.len), msg_text.data)
                msg.release()
                return 1
            Result.success as payload:
                var root = payload.value
                let text = root.as_str()
                stdio.print_format(c"purged %.*s\n", int<-(text.len), text.data)
                root.release()
                return 0
    if sub == "status":
        var st = build_cache.status()
        var root = build_cache.cache_root_path()
        let root_text = root.as_str()
        stdio.print_format(c"cache  %zu programs  %zu bytes\n", st.count, st.total_bytes)
        stdio.print_format(c"  root  %.*s\n", int<-(root_text.len), root_text.data)
        root.release()
        return 0
    stdio.print_line("unknown cache subcommand")
    return 1


struct CommandSummary:
    name: str
    summary: str


## The self-host's implemented command set with the same one-line summaries as
## Ruby's CLI::COMMANDS (used by the zsh/fish completion scripts).
function command_summary_count() -> ptr_uint:
    return 14


function command_summary_at(index: ptr_uint) -> CommandSummary:
    if index == 0:
        return CommandSummary(name = "check", summary = "Type-check and lint source files")
    if index == 1:
        return CommandSummary(name = "build", summary = "Compile a source file or package")
    if index == 2:
        return CommandSummary(name = "run", summary = "Build and execute a program")
    if index == 3:
        return CommandSummary(name = "run-module", summary = "Resolve, build, and run a module by name")
    if index == 4:
        return CommandSummary(name = "test", summary = "Discover and run @[test] functions")
    if index == 5:
        return CommandSummary(name = "new", summary = "Scaffold a new package")
    if index == 6:
        return CommandSummary(name = "format", summary = "Format source files in place or check formatting")
    if index == 7:
        return CommandSummary(name = "lint", summary = "Lint source files and report warnings")
    if index == 8:
        return CommandSummary(name = "lsp", summary = "Start the language server (stdio JSON-RPC)")
    if index == 9:
        return CommandSummary(name = "lex", summary = "Print the lexer token stream")
    if index == 10:
        return CommandSummary(name = "parse", summary = "Parse source and print the AST")
    if index == 11:
        return CommandSummary(name = "lower", summary = "Lower source to IR and print it")
    if index == 12:
        return CommandSummary(name = "emit-c", summary = "Compile source to C and print it")
    return CommandSummary(name = "completions", summary = "Print a shell completion script")


## Format a source file: parse, pretty-print, and either print to stdout,
## check for formatting diffs, or write back to the file.
function format_command(args: span[str]) -> int:
    var file_path: Option[str] = Option[str].none
    var check_mode = false
    var write_mode = false
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--check":
            check_mode = true
            ai += 1
            continue
        if arg == "--write":
            write_mode = true
            ai += 1
            continue
        if file_path.is_none():
            file_path = Option[str].some(value= arg)
            ai += 1
            continue
        stdio.print_format(c"error: unknown option %.*s\n", int<-(arg.len), arg.data)
        return 1

    let path = file_path else:
        stdio.print_line("error: format requires a source file path")
        return 1

    match fs.read_text(path):
        Result.success as content:
            var source = content.value
            defer source.release()
            let source_text = source.as_str()

            var diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer diags.release()
            let file = parser.parse_source(source_text, ref_of(diags))
            if diags.len() > 0:
                stdio.print_format(c"error: %.*s: parse error\n", int<-(path.len), path.data)
                return 1

            var formatted = fmt.format_source_file(file)
            defer formatted.release()
            let fmt_text = formatted.as_str()

            if write_mode:
                match fs.write_text(path, fmt_text):
                    Result.success:
                        stdio.print_format(c"formatted %.*s\n", int<-(path.len), path.data)
                        return 0
                    Result.failure as err:
                        var msg = err.error
                        defer msg.release()
                        stdio.print_format(c"error: cannot write %.*s\n", int<-(path.len), path.data)
                        return 1
            if check_mode:
                if source_text == fmt_text:
                    stdio.print_format(c"already formatted %.*s\n", int<-(path.len), path.data)
                    return 0
                stdio.print_format(c"needs formatting %.*s\n", int<-(path.len), path.data)
                return 1
            stdio.print_format(c"%.*s", int<-(fmt_text.len), fmt_text.data)
            return 0
        Result.failure as err:
            var msg = err.error
            defer msg.release()
            stdio.print_format(c"error: cannot read %.*s\n", int<-(path.len), path.data)
            return 1


## The default output path for a source build: the source path with its `.mt`
## extension removed (matching the Ruby CLI's direct-source-build behaviour).
function default_output_path(path: str) -> string.String:
    if path.ends_with(".mt"):
        return string.String.from_str(path.slice(0, path.len - 3))
    return j2_path(path, ".out")


function keep_c_to_file(ir_program: ir.Program, output_path_str: str) -> void:
    var c_source = c_backend.generate_c(ir_program)
    defer c_source.release()
    match fs.write_text(output_path_str, c_source.as_str()):
        Result.success:
            stdio.print_format(c"saved C to %.*s\n", int<-(output_path_str.len), output_path_str.data)
        Result.failure as failure:
            var err = failure.error
            defer err.release()
            stdio.print_format(
                c"warning: could not write C to %.*s\n",
                int<-(output_path_str.len), output_path_str.data,
            )


function j2_path(a: str, b: str) -> string.String:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf


## Parse a decimal string into a positive `ptr_uint`.  Returns none when the
## text is empty, contains a non-digit, or evaluates to zero.
function parse_positive_int(text: str) -> Option[ptr_uint]:
    if text.len == 0:
        return Option[ptr_uint].none
    var value: ptr_uint = 0
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b < 48 or b > 57:
            return Option[ptr_uint].none
        value = value * 10 + ptr_uint<-(int<-b - 48)
        i += 1
    if value == 0:
        return Option[ptr_uint].none
    return Option[ptr_uint].some(value= value)


function ptr_uint_to_str(value: ptr_uint) -> str:
    if value == 0:
        return "0"
    var buf = string.String.create()
    var n = value
    var digits = vec.Vec[ubyte].create()
    while n > 0:
        let d = n % 10
        digits.push(ubyte<-(int<-d + 48))
        n = n / 10
    var di = digits.len()
    while di > 0:
        di -= 1
        unsafe:
            let dp = ptr[ubyte]<-digits.data
            buf.push_byte(read(dp + di))
    return buf.as_str()


function lex_command(file_path: str, machine: bool) -> int:
    match fs.read_text(file_path):
        Result.failure:
            stdio.print_format(c"error: cannot read '%.*s'\n", int<-(file_path.len), file_path.data)
            return 1
        Result.success as payload:
            var content = payload.value
            defer content.release()

            let source = content.as_str()
            var diags = vec.Vec[token_mod.LexDiagnostic].create()
            var tokens = lexer.lex_reporting(source, ref_of(diags))

            if diags.len() > 0:
                var di: ptr_uint = 0
                while di < diags.len():
                    let d = diags.get(di) else:
                        break
                    unsafe:
                        let rd = read(d)
                        stdio.print_format(
                            c"%.*s:%d:%d: lex error: %s\n",
                            int<-(file_path.len), file_path.data,
                            int<-(rd.line),
                            int<-(rd.column),
                            rd.message,
                        )
                    di += 1

            stdio.print_format(c"── Tokens  %d  ──\n", int<-(tokens.len()))

            if machine:
                # Machine-readable: kind line col start end
                var j: ptr_uint = 0
                while j < tokens.len():
                    let tok = tokens.get(j) else:
                        break
                    unsafe:
                        let t = read(tok)
                        let kn = token_mod.kind_name(t.kind)
                        stdio.print_format(
                            c"%s %d %d %d %d\n",
                            kn,
                            int<-(t.line),
                            int<-(t.column),
                            int<-(t.start_offset),
                            int<-(t.end_offset),
                        )
                    j += 1
            else:
                # Human-readable
                var k: ptr_uint = 0
                while k < tokens.len():
                    let tok = tokens.get(k) else:
                        break
                    unsafe:
                        let t = read(tok)
                        let lexeme = token_mod.token_lexeme(t, source)
                        let kn = token_mod.kind_name(t.kind)
                        let end_col = if t.kind == tk.TokenKind.eof: t.column else: t.column + lexeme.len - 1z
                        stdio.print_format(
                            c"  %3d:%d-%-3d  %-24.*s %s\n",
                            int<-(t.line),
                            int<-(t.column),
                            int<-(end_col),
                            int<-(lexeme.len), lexeme.data,
                            kn,
                        )
                    k += 1
            diags.release()

    return 0


## Machine-readable test output selection.
enum OutputFormat: ubyte
    human = 0
    tap   = 1
    junit = 2


enum TestStatus: ubyte
    ok   = 0
    skip = 1
    fail = 2


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
    defer expectations.release()
    collect_expect_errors(source, ref_of(expectations))
    return expectations.len() > 0


## Run a compile-fail fixture: type-check the file and verify every
## `# expect-error:` substring appears in some error diagnostic.  Returns
## (1, 0) when the expectations are satisfied and (1, 1) otherwise, so the
## fixture is counted like a test file.
function run_compile_fail_file(file_path: str, source_text: str, roots: ref[vec.Vec[str]], machine: bool, results: ref[vec.Vec[TestResult]]) -> (int, int):
    var expected = vec.Vec[str].create()
    defer expected.release()
    collect_expect_errors(source_text, ref_of(expected))

    var eff_roots = vec.Vec[str].create()
    defer eff_roots.release()
    var ri: ptr_uint = 0
    while ri < roots.len():
        let rp = roots.get(ri) else:
            break
        unsafe:
            eff_roots.push(read(rp))
        ri += 1
    eff_roots.push(path_ops.dirname(file_path))

    var program = loader.check_program(file_path, eff_roots.as_span(), resolver.Platform.linux)
    defer program.release()

    var error_msgs = vec.Vec[str].create()
    defer error_msgs.release()
    var di: ptr_uint = 0
    while di < program.diagnostics.len():
        let dp = program.diagnostics.get(di) else:
            break
        unsafe:
            if read(dp).severity == "error":
                error_msgs.push(read(dp).message.as_str())
        di += 1

    var passed = true
    var fail_reason = string.String.create()
    defer fail_reason.release()
    if error_msgs.len() == 0:
        passed = false
        fail_reason.assign("expected a compile error, but it compiled cleanly")
    else:
        var ei: ptr_uint = 0
        while ei < expected.len():
            let ep = expected.get(ei) else:
                break
            let exp = unsafe: read(ep)
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
                passed = false
                fail_reason.assign("no diagnostic matched: ")
                fail_reason.append(exp)
                break
            ei += 1

    if machine:
        var name = string.String.from_str(file_path)
        name.append(" (compile-fail)")
        if passed:
            results.push(TestResult(name = name, status = TestStatus.ok, detail = string.String.create(), has_detail = false))
        else:
            results.push(TestResult(name = name, status = TestStatus.fail, detail = string.String.from_str(fail_reason.as_str()), has_detail = true))
    else:
        stdio.print_format(c"# %.*s\n", int<-(file_path.len), file_path.data)
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
        return (1, 0)
    return (1, 1)


## Discover and run @[test] functions under a directory.  Scans all .mt files,
## synthesizes a std.testing runner per file, builds it via bin/mtc, and runs
## it under a timeout/memory sandbox.  With --format tap|junit the per-test
## outcomes are parsed and re-emitted in the machine-readable format instead of
## the human summary.
function test_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer roots.release()
    var test_dir = "."
    var name_filter: Option[str] = Option[str].none
    var timeout_seconds: ptr_uint = 30
    var memory_mb: ptr_uint = 1024
    var format = OutputFormat.human
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--root" or arg == "-I":
            if ai + 1 >= args.len:
                stdio.print_line("error: -I requires a directory")
                return 1
            roots.push(args[ai + 1])
            ai += 2
            continue
        if arg == "-n" or arg == "--name":
            if ai + 1 >= args.len:
                stdio.print_line("error: -n requires a name substring")
                return 1
            name_filter = Option[str].some(value= args[ai + 1])
            ai += 2
            continue
        if arg == "--timeout":
            if ai + 1 >= args.len:
                stdio.print_line("error: --timeout requires a positive integer (seconds)")
                return 1
            let seconds = parse_positive_int(args[ai + 1]) else:
                stdio.print_line("error: --timeout requires a positive integer (seconds)")
                return 1
            timeout_seconds = seconds
            ai += 2
            continue
        if arg == "--mem":
            if ai + 1 >= args.len:
                stdio.print_line("error: --mem requires a positive integer (megabytes)")
                return 1
            let megabytes = parse_positive_int(args[ai + 1]) else:
                stdio.print_line("error: --mem requires a positive integer (megabytes)")
                return 1
            memory_mb = megabytes
            ai += 2
            continue
        if arg == "--format":
            if ai + 1 >= args.len:
                stdio.print_line("error: --format must be human, tap, or junit")
                return 1
            let fmt_name = args[ai + 1]
            if fmt_name == "human":
                format = OutputFormat.human
            else if fmt_name == "tap":
                format = OutputFormat.tap
            else if fmt_name == "junit":
                format = OutputFormat.junit
            else:
                stdio.print_line("error: --format must be human, tap, or junit")
                return 1
            ai += 2
            continue
        test_dir = arg
        ai += 1

    if not fs.is_directory(test_dir):
        stdio.print_format(c"error: not a directory: %.*s\n", int<-(test_dir.len), test_dir.data)
        return 1

    match fs.list_files_recursive(test_dir):
        Result.success as entries_payload:
            var entries = entries_payload.value
            defer entries.release()
            var total_passed: ptr_uint = 0
            var total_failed: ptr_uint = 0
            var file_count: ptr_uint = 0
            var runner_counter: ptr_uint = 0
            var results = vec.Vec[TestResult].create()
            let machine = format != OutputFormat.human
            var index: ptr_uint = 0
            while index < entries.len():
                match entries.get(index):
                    Option.some as name_payload:
                        let entry_name = name_payload.value
                        if entry_name.ends_with(".mt"):
                            match fs.read_text(entry_name):
                                Result.success as content:
                                    var src = content.value
                                    if is_compile_fail_fixture(src.as_str()):
                                        if matches_name_filter(path_ops.basename(entry_name), name_filter):
                                            let (cfp, cff) = run_compile_fail_file(
                                                entry_name, src.as_str(), ref_of(roots), machine, ref_of(results)
                                            )
                                            if cfp > 0 or cff > 0:
                                                file_count += 1
                                            total_passed += ptr_uint<-cfp
                                            total_failed += ptr_uint<-cff
                                        src.release()
                                    else:
                                        src.release()
                                        let (file_passed, file_failed) = run_test_file(
                                            entry_name, ref_of(roots), ref_of(runner_counter), name_filter,
                                            timeout_seconds, memory_mb, machine, ref_of(results)
                                        )
                                        if file_passed > 0 or file_failed > 0:
                                            file_count += 1
                                        total_passed += ptr_uint<-file_passed
                                        total_failed += ptr_uint<-file_failed
                                Result.failure as read_err:
                                    var em = read_err.error
                                    em.release()
                    Option.none:
                        pass
                index += 1

            if machine:
                if format == OutputFormat.tap:
                    emit_tap(ref_of(results))
                else:
                    emit_junit(ref_of(results))
                var ri: ptr_uint = 0
                while ri < results.len():
                    let rp = results.get(ri) else:
                        break
                    unsafe:
                        read(rp).release()
                    ri += 1
                results.release()
                if total_failed > 0:
                    return 1
                return 0

            results.release()
            if file_count == 0:
                match name_filter:
                    Option.some as needle:
                        stdio.print_format(
                            c"no tests matched -n '%.*s' under %.*s\n",
                            int<-(needle.value.len), needle.value.data,
                            int<-(test_dir.len), test_dir.data,
                        )
                    Option.none:
                        stdio.print_line("no @[test] functions found")
                return 0
            stdio.print_format(
                c"%d test file(s), %d failed\n",
                int<-file_count,
                int<-total_failed,
            )
            if total_failed > 0:
                return 1
            return 0
        Result.failure as failure_payload:
            var err = failure_payload.error
            defer err.release()
            stdio.print_format(
                c"error: cannot list directory %.*s\n",
                int<-(test_dir.len), test_dir.data,
            )
            return 1


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
            defer source.release()
            var diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer diags.release()
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


function run_test_file(file_path: str, roots: ref[vec.Vec[str]], counter: ref[ptr_uint], name_filter: Option[str], timeout_seconds: ptr_uint, memory_mb: ptr_uint, machine: bool, results: ref[vec.Vec[TestResult]]) -> (int, int):
    match fs.read_text(file_path):
        Result.success as content_payload:
            var source = content_payload.value
            defer source.release()
            let source_text = source.as_str()

            var diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer diags.release()
            let file = parser.parse_source(source_text, ref_of(diags))
            if diags.len() > 0:
                return (0, 0)

            var test_names = vec.Vec[str].create()
            defer test_names.release()
            var death_names = vec.Vec[str].create()
            defer death_names.release()
            var di: ptr_uint = 0
            while di < file.declarations.len:
                unsafe:
                    match read(file.declarations.data + di):
                        ast.Decl.decl_function as fun:
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
                            if is_test and matches_name_filter(fun.name, name_filter):
                                if is_fatal:
                                    death_names.push(fun.name)
                                else:
                                    test_names.push(fun.name)
                        _:
                            pass
                di += 1

            if test_names.len() == 0 and death_names.len() == 0:
                return (0, 0)

            var testing_alias = "t"
            var vi: ptr_uint = 0
            while vi < file.imports.len:
                unsafe:
                    match read(file.imports.data + vi):
                        ast.Decl.decl_import as imp:
                            if imp.path.parts.len >= 2:
                                let fp = read(imp.path.parts.data + 0)
                                let sp = read(imp.path.parts.data + 1)
                                if fp == "std" and sp == "testing":
                                    if imp.alias_name.is_some():
                                        testing_alias = imp.alias_name.unwrap()
                        _:
                            pass
                vi += 1

            if not machine:
                stdio.print_format(c"# %.*s\n", int<-(file_path.len), file_path.data)

            var file_failed = 0
            if test_names.len() > 0:
                if run_normal_test_runner(file_path, source_text, ref_of(test_names), testing_alias, roots, counter, timeout_seconds, memory_mb, machine, results) != 0:
                    file_failed = 1

            var dj: ptr_uint = 0
            while dj < death_names.len():
                let dn_ptr = death_names.get(dj) else:
                    break
                if not run_death_test(file_path, source_text, unsafe: read(dn_ptr), roots, counter, timeout_seconds, memory_mb, machine, results):
                    file_failed = 1
                dj += 1

            return (int<-(test_names.len() + death_names.len()), file_failed)
        Result.failure:
            return (0, 0)


## Run `binary_path` under a sandbox: `timeout <sec> bash -c 'ulimit -v <kb>;
## exec "$@"'`, capturing output.  `timeout` reports exit 124 on expiry and the
## `ulimit -v` cap bounds virtual memory so a hung/runaway binary cannot stall
## or exhaust the host.
function run_sandboxed(binary_path: str, timeout_seconds: ptr_uint, memory_mb: ptr_uint) -> Result[process.CaptureResult, process.ProcessError]:
    var ulimit_cmd = string.String.create()
    defer ulimit_cmd.release()
    ulimit_cmd.append("ulimit -v ")
    ulimit_cmd.append(ptr_uint_to_str(memory_mb * 1024z))
    ulimit_cmd.append("; exec \"$@\"")

    var run_cmd = vec.Vec[str].create()
    defer run_cmd.release()
    run_cmd.push("timeout")
    run_cmd.push(ptr_uint_to_str(timeout_seconds))
    run_cmd.push("bash")
    run_cmd.push("-c")
    run_cmd.push(ulimit_cmd.as_str())
    run_cmd.push("mt")
    run_cmd.push(binary_path)
    return process.capture(run_cmd.as_span())


## Synthesize, build, and run the std.testing runner for a file's normal
## @[test] functions.  Returns 1 when the runner fails to build, times out,
## crashes, or exits non-zero; 0 otherwise.
function run_normal_test_runner(file_path: str, source_text: str, test_names: ref[vec.Vec[str]], testing_alias: str, roots: ref[vec.Vec[str]], counter: ref[ptr_uint], timeout_seconds: ptr_uint, memory_mb: ptr_uint, machine: bool, results: ref[vec.Vec[TestResult]]) -> int:
    var runner_source = string.String.create()
    defer runner_source.release()
    runner_source.append(source_text)
    runner_source.append("\n\nfunction main() -> int:\n")
    runner_source.append("    var __mt_test_stats = ")
    runner_source.append(testing_alias)
    runner_source.append(".Stats.create()\n")
    var ti: ptr_uint = 0
    while ti < test_names.len():
        let tn_ptr = test_names.get(ti) else:
            break
        let tn = unsafe: read(tn_ptr)
        runner_source.append("    __mt_test_stats = ")
        runner_source.append(testing_alias)
        runner_source.append(".record(__mt_test_stats, \"")
        runner_source.append(tn)
        runner_source.append("\", ")
        runner_source.append(tn)
        runner_source.append("())\n")
        ti += 1
    runner_source.append("    return ")
    runner_source.append(testing_alias)
    runner_source.append(".summarize(__mt_test_stats)\n")

    let dirname = path_ops.dirname(file_path)
    let counter_val = read(counter)
    read(counter) = counter_val + 1z
    var runner_num_str = ptr_uint_to_str(counter_val)
    var runner_path_str = string.String.create()
    runner_path_str.append(dirname)
    runner_path_str.append("/__mt_test_runner_")
    runner_path_str.append(runner_num_str)
    runner_path_str.append(".mt")
    defer runner_path_str.release()

    match fs.write_text(runner_path_str.as_str(), runner_source.as_str()):
        Result.success:
            pass
        Result.failure:
            return 1

    var runner_bin_str = string.String.create()
    runner_bin_str.append(dirname)
    runner_bin_str.append("/__mt_test_runner_")
    runner_bin_str.append(runner_num_str)
    defer runner_bin_str.release()

    var build_cmd = vec.Vec[str].create()
    defer build_cmd.release()
    build_cmd.push("bin/mtc")
    build_cmd.push("build")
    build_cmd.push(runner_path_str.as_str())
    var bri: ptr_uint = 0
    while bri < roots.len():
        build_cmd.push("-I")
        unsafe:
            build_cmd.push(read(ptr[str]<-roots.data + bri))
        bri += 1
    build_cmd.push("-o")
    build_cmd.push(runner_bin_str.as_str())

    var build_failed = false
    match process.capture(build_cmd.as_span()):
        Result.success as captured:
            var build_result = captured.value
            defer build_result.release()
            if not machine:
                let build_stdout = build_result.stdout_text()
                if build_stdout.is_some():
                    stdio.print_format(c"%.*s", int<-(build_stdout.unwrap().len), build_stdout.unwrap().data)
                let build_stderr = build_result.stderr_text()
                if build_stderr.is_some():
                    stdio.print_format(c"%.*s", int<-(build_stderr.unwrap().len), build_stderr.unwrap().data)
            if build_result.status.normalized_code() != 0:
                build_failed = true
        Result.failure:
            build_failed = true

    if build_failed:
        if machine:
            var be_name = string.String.from_str(file_path)
            be_name.append(" (build error)")
            results.push(TestResult(
                name = be_name,
                status = TestStatus.fail,
                detail = string.String.from_str("build error"),
                has_detail = true,
            ))
        else:
            stdio.print_format(c"FAILED - %.*s (build error)\n", int<-(file_path.len), file_path.data)
        let _rb = fs.remove(runner_path_str.as_str())
        return 1

    var run_failed = false
    match run_sandboxed(runner_bin_str.as_str(), timeout_seconds, memory_mb):
        Result.success as run_result:
            var capture_result = run_result.value
            defer capture_result.release()
            let run_stdout = capture_result.stdout_text()
            if run_stdout.is_some():
                if machine:
                    collect_runner_results(run_stdout.unwrap(), results)
                else:
                    stdio.print_format(c"%.*s", int<-(run_stdout.unwrap().len), run_stdout.unwrap().data)
            if not machine:
                let run_stderr = capture_result.stderr_text()
                if run_stderr.is_some():
                    stdio.print_format(c"%.*s", int<-(run_stderr.unwrap().len), run_stderr.unwrap().data)
            let code = capture_result.status.normalized_code()
            if code == 124:
                if machine:
                    var to_name = string.String.from_str(file_path)
                    to_name.append(" (timed out)")
                    results.push(TestResult(
                        name = to_name,
                        status = TestStatus.fail,
                        detail = string.String.from_str("timed out"),
                        has_detail = true,
                    ))
                else:
                    stdio.print_format(c"test run timed out after %ds\n", int<-timeout_seconds)
                run_failed = true
            else if code != 0:
                run_failed = true
        Result.failure:
            if not machine:
                stdio.print_line("FAILED - runner crashed")
            run_failed = true

    let _r1 = fs.remove(runner_path_str.as_str())
    let _r2 = fs.remove(runner_bin_str.as_str())
    if run_failed:
        return 1
    return 0


## Run a single @[expect_fatal] death test in its own binary.  The synthesized
## main calls the test and returns 0 on either outcome; the test passes only if
## the process aborts (fatal / failed safety check) instead of returning or
## timing out.
function run_death_test(file_path: str, source_text: str, test_name: str, roots: ref[vec.Vec[str]], counter: ref[ptr_uint], timeout_seconds: ptr_uint, memory_mb: ptr_uint, machine: bool, results: ref[vec.Vec[TestResult]]) -> bool:
    var runner_source = string.String.create()
    defer runner_source.release()
    runner_source.append(source_text)
    runner_source.append("\n\nfunction main() -> int:\n")
    runner_source.append("    match ")
    runner_source.append(test_name)
    runner_source.append("():\n")
    runner_source.append("        Result.success:\n            return 0\n")
    runner_source.append("        Result.failure:\n            return 0\n")

    let dirname = path_ops.dirname(file_path)
    let counter_val = read(counter)
    read(counter) = counter_val + 1z
    var runner_num_str = ptr_uint_to_str(counter_val)
    var runner_path_str = string.String.create()
    runner_path_str.append(dirname)
    runner_path_str.append("/__mt_test_runner_")
    runner_path_str.append(runner_num_str)
    runner_path_str.append(".mt")
    defer runner_path_str.release()

    match fs.write_text(runner_path_str.as_str(), runner_source.as_str()):
        Result.success:
            pass
        Result.failure:
            return false

    var runner_bin_str = string.String.create()
    runner_bin_str.append(dirname)
    runner_bin_str.append("/__mt_test_runner_")
    runner_bin_str.append(runner_num_str)
    defer runner_bin_str.release()

    var build_cmd = vec.Vec[str].create()
    defer build_cmd.release()
    build_cmd.push("bin/mtc")
    build_cmd.push("build")
    build_cmd.push(runner_path_str.as_str())
    var bri: ptr_uint = 0
    while bri < roots.len():
        build_cmd.push("-I")
        unsafe:
            build_cmd.push(read(ptr[str]<-roots.data + bri))
        bri += 1
    build_cmd.push("-o")
    build_cmd.push(runner_bin_str.as_str())


    var build_ok = false
    match process.capture(build_cmd.as_span()):
        Result.success as captured:
            var build_result = captured.value
            defer build_result.release()
            if build_result.status.normalized_code() == 0:
                build_ok = true
        Result.failure:
            build_ok = false

    var passed = false
    var reason = "expected a fatal abort, but the test returned"
    if not build_ok:
        reason = "build error"
    else:
        match run_sandboxed(runner_bin_str.as_str(), timeout_seconds, memory_mb):
            Result.success as run_result:
                var capture_result = run_result.value
                defer capture_result.release()
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
    return passed
