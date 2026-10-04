## Self-hosted Milk Tea compiler CLI.
##
## Commands:
##   mtc lex <file>       Print the lexer token stream
##   mtc help             Print help

import std.env as env
import std.fs as fs
import std.fmt as fmt_mod
import std.mem.heap as heap
import std.path as path_ops
import std.str
import std.string as string
import std.time as time
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
import mtc.formatter.tidy as tidy
import mtc.profile as profile_mod
import mtc.loader.path_resolver as resolver
import mtc.loader.package_manifest as package_manifest
import mtc.loader.module_loader as loader
import mtc.semantic.analyzer as analyzer
import mtc.lowering.lowering as lowering
import mtc.c_backend.c_backend as c_backend
import mtc.ir as ir
import mtc.build as build_driver
import mtc.build_cache as build_cache
import mtc.pretty_printer.ast_formatter as fmt
import mtc.linter.linter as linter
import mtc.linter.scope_tracking as scope_tracking
import mtc.linter.fix_engine as fix_engine
import mtc.lsp.server as lsp
import mtc.lsp.semantic_tokens as sem_tokens
import mtc.dap.server as dap
import mtc.bindgen as bindgen
import mtc.imported_bindings.registry as ib_registry
import mtc.imported_bindings.main as ib_main
import mtc.sexpr as sexpr_mod
import mtc.std_catalog as std_catalog
import mtc.version_info as ver
import mtc.cli_help as cli_help


## Global CLI flags parsed by `dispatch_cli` (mirror Ruby's `-v`/`-q`/`--color`).
## `cli_quiet` suppresses informational output; `cli_verbose` prints per-file
## action lines in lint/format; `cli_color` is accepted for compatibility.
var cli_quiet: bool = false
var cli_verbose: bool = false
var cli_color: str = "auto"


## Write one line to stderr — CLI errors and usage blocks go there, as in the host.
function eprint_line(text: str) -> void:
    let _ = terminal.write_stderr(text)
    let _ = terminal.write_stderr("\n")
    let _ = terminal.flush_stderr()


## `unknown option <flag> for <command>` on stderr, mirroring the host.
function eprint_unknown_option(flag: str, command: str) -> void:
    var buf = string.String.create()
    defer: buf.release()
    buf.append("unknown option ")
    buf.append(flag)
    buf.append(" for ")
    buf.append(command)
    eprint_line(buf.as_str())


## Commands that accept module-root flags (host: `command_supports_include_paths?`).
function command_supports_include_paths(command: str) -> bool:
    return command == "parse" or command == "lint" or command == "check" or command == "lower" or command == "emit-c" or command == "build" or command == "run" or command == "test" or command == "debug"


function main(args: span[str]) -> int:
    if args.len < 2:
        cli_help.print_help(false)
        return 0
    let cli_args = unsafe: span[str](data = args.data + 1, len = args.len - 1)
    return dispatch_cli(cli_args)


function dispatch_cli(raw_args: span[str]) -> int:
    if raw_args.len < 1:
        cli_help.print_help(false)
        return 0

    # Global flags (`-v`/`--verbose`, `-q`/`--quiet`, `--color MODE`,
    # `-I`/`--include-path DIR`) may appear before the command; strip them here.
    # Scanning stops at `--` so `run` program arguments pass through untouched.
    var filtered = vec.Vec[str].create()
    defer: filtered.release()
    var include_pairs = vec.Vec[str].create()
    defer: include_pairs.release()
    var fi: ptr_uint = 0
    var saw_dashdash = false
    var saw_include = false
    var include_flag = ""
    while fi < raw_args.len:
        let a = raw_args[fi]
        if saw_dashdash:
            filtered.push(a)
            fi += 1
            continue
        if a == "--":
            saw_dashdash = true
            filtered.push(a)
            fi += 1
            continue
        if a == "-v" or a == "--verbose":
            cli_verbose = true
            fi += 1
            continue
        if a == "-q" or a == "--quiet":
            cli_quiet = true
            fi += 1
            continue
        if a == "--color" or a.starts_with("--color="):
            var value = ""
            if a.starts_with("--color="):
                value = a.slice(8, a.len - 8)
                fi += 1
            else if fi + 1 < raw_args.len:
                value = raw_args[fi + 1]
                fi += 2
            else:
                fi += 1
            if value != "auto" and value != "always" and value != "never":
                var invalid = string.String.create()
                defer: invalid.release()
                invalid.append("--color must be auto, always, or never (got ")
                invalid.append(value)
                invalid.append(")")
                eprint_line(invalid.as_str())
                return 1
            cli_color = value
            continue
        if a == "-I" or a == "--include-path":
            if fi + 1 < raw_args.len and not raw_args[fi + 1].starts_with("-"):
                include_pairs.push(a)
                include_pairs.push(raw_args[fi + 1])
                saw_include = true
                include_flag = a
                fi += 2
            else:
                eprint_line("missing value for -I")
                fi += 1
            continue
        filtered.push(a)
        fi += 1

    if filtered.len() < 1:
        cli_help.print_help(false)
        return 0

    # Module roots are put back after the command name (the host keeps them out
    # of argv and hands them to the module loader; the commands here parse them
    # from their own arguments, so they must follow the command).
    let first_arg = filtered.get(0) else:
        cli_help.print_help(false)
        return 0
    if saw_include and command_supports_include_paths(unsafe: read(first_arg)):
        var with_roots = vec.Vec[str].create()
        with_roots.push(unsafe: read(first_arg))
        var ri: ptr_uint = 0
        while ri < include_pairs.len():
            let pair_item = include_pairs.get(ri) else:
                break
            with_roots.push(unsafe: read(pair_item))
            ri += 1
        var rj: ptr_uint = 1
        while rj < filtered.len():
            let rest = filtered.get(rj) else:
                break
            with_roots.push(unsafe: read(rest))
            rj += 1
        var stale = filtered
        filtered = with_roots
        stale.release()

    let args = filtered.as_span()

    let cmd = args[0]

    if cmd == "version" or cmd == "--version" or cmd == "-V":
        stdio.print_format(c"mtc %.*s\n", int<-(cli_help.VERSION.len), cli_help.VERSION.data)
        return 0

    # `mtc`, `mtc -h|--help`, `mtc help [command]` all print help and exit 0.
    if cmd == "-h" or cmd == "--help":
        cli_help.print_help(false)
        return 0

    if cmd == "help":
        if args.len > 1:
            if not cli_help.print_command_help(args[1], false):
                cli_help.print_usage(false)
            return 0
        cli_help.print_help(false)
        return 0

    if saw_include and not command_supports_include_paths(cmd):
        eprint_unknown_option(include_flag, cmd)
        cli_help.print_usage(true)
        return 1

    # `mtc <command> --help|-h` prints that command's help block.
    if args.len > 1 and (args[1] == "-h" or args[1] == "--help"):
        if not cli_help.print_command_help(cmd, false):
            cli_help.print_usage(false)
        return 0

    if cmd == "lex":
        var machine = false
        var sexpr = false
        var lex_file: Option[str] = Option[str].none
        var li: ptr_uint = 1
        while li < args.len:
            let a = args[li]
            if a == "--":
                li += 1
                continue
            if a == "--machine":
                machine = true
            else if a == "--sexpr":
                sexpr = true
            else if a.starts_with("-"):
                stdio.print_format(c"unknown option: %.*s\n", int<-(a.len), a.data)
                return 1
            else:
                match lex_file:
                    Option.some:
                        stdio.print_format(c"unknown option: %.*s\n", int<-(a.len), a.data)
                        return 1
                    Option.none:
                        lex_file = Option[str].some(value = a)
            li += 1
        let lf = lex_file else:
            eprint_line("missing source file path")
            cli_help.print_usage(true)
            return 1
        return lex_command(lf, machine, sexpr)

    if cmd == "parse":
        var parse_file: Option[str] = Option[str].none
        var parse_sexpr = false
        var pi: ptr_uint = 1
        while pi < args.len:
            let a = args[pi]
            if a == "--":
                pi += 1
                continue
            if a == "--sexpr":
                parse_sexpr = true
            else if a.starts_with("-"):
                stdio.print_format(c"unknown option: %.*s\n", int<-(a.len), a.data)
                return 1
            else:
                match parse_file:
                    Option.some:
                        stdio.print_format(c"unknown option: %.*s\n", int<-(a.len), a.data)
                        return 1
                    Option.none:
                        parse_file = Option[str].some(value = a)
            pi += 1
        let pf = parse_file else:
            eprint_line("missing source file path")
            cli_help.print_usage(true)
            return 1
        return parse_command(pf, parse_sexpr)

    if cmd == "check":
        if args.len < 2:
            eprint_line("missing source file path")
            cli_help.print_usage(true)
            return 1
        return check_command(args)

    if cmd == "lint":
        if args.len < 2:
            eprint_line("missing source file path")
            cli_help.print_usage(true)
            return 1
        return lint_command(args)

    if cmd == "lower":
        if args.len < 2:
            eprint_line("missing source file path")
            cli_help.print_usage(true)
            return 1
        return lower_command(args)

    if cmd == "emit-c":
        if args.len < 2:
            eprint_line("missing source file path")
            cli_help.print_usage(true)
            return 1
        return emit_c_command(args)

    if cmd == "build":
        if args.len < 2:
            eprint_line("missing source file path")
            cli_help.print_usage(true)
            return 1
        return build_command(args)

    if cmd == "run":
        if args.len < 2:
            eprint_line("missing source file path")
            cli_help.print_usage(true)
            return 1
        return run_command(args)

    if cmd == "run-module":
        if args.len < 2:
            eprint_line("missing source file path")
            cli_help.print_usage(true)
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

    if cmd == "bindgen":
        return bindgen_command(args)

    if cmd == "imported-bindings":
        return imported_bindings_command(args)

    if cmd == "toolchain":
        return toolchain_command(args)

    if cmd == "std":
        return std_command(args)

    if cmd == "snapshot":
        return snapshot_command(args)

    if cmd == "debug":
        return debug_command(args)

    # Unknown command: the host prints its usage block to stderr and exits 1.
    cli_help.print_usage(true)
    return 1


## Ambient module roots for `parse`: the host resolves a file's module name
## against its package source root (nearest `package.toml`) or the nearest
## ancestor containing `std/`, falling back to the basename.
function parse_module_name(file_path: str) -> string.String:
    var abs_owner = loader.absolute_path(file_path)
    defer: abs_owner.release()
    let abs_path = abs_owner.as_str()
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var package_root_owner = string.String.create()
    defer: package_root_owner.release()
    match fs.find_ancestor_containing(abs_path, "package.toml"):
        Option.some as pkg_dir:
            var manifest_path = path_ops.join(pkg_dir.value.as_str(), "package.toml")
            defer: manifest_path.release()
            var source_root_owner = string.String.create()
            defer: source_root_owner.release()
            source_root_owner.append("src")
            match fs.read_text(manifest_path.as_str()):
                Result.success as payload:
                    var manifest_text = payload.value
                    defer: manifest_text.release()
                    match read_toml_str(manifest_text.as_str(), "package", "source_root"):
                        Option.some as sr:
                            source_root_owner.release()
                            source_root_owner = string.String.from_str(sr.value.as_str())
                        Option.none:
                            pass
                Result.failure:
                    pass
            package_root_owner.release()
            package_root_owner = path_ops.join(pkg_dir.value.as_str(), source_root_owner.as_str())
            roots.push(package_root_owner.as_str())
        Option.none:
            pass
    # Project-root fallback (nearest ancestor containing `std`), mirroring the
    # host's `project_root_for_path`.  This is needed when a file lies outside
    # its package's source root (e.g. `projects/mtc/test/...`), where the host
    # falls back to the repo root rather than the bare file name.
    match fs.find_ancestor_containing(abs_path, "std"):
        Option.some as project_dir:
            roots.push(project_dir.value.as_str())
        Option.none:
            pass
    return resolver.infer_module_name(abs_path, roots.as_span())


function parse_command(file_path: str, sexpr: bool) -> int:
    # Resolve to the active-platform variant (`name.mt` -> `name.linux.mt` when
    # a sibling exists), matching the Ruby loader's `load_file`.
    var abs_owner = loader.absolute_path(file_path)
    defer: abs_owner.release()
    var resolved = resolver.resolve_source_path(abs_owner.as_str(), resolver.Platform.linux)
    defer: resolved.release()

    match fs.read_text(resolved.as_str()):
        Result.failure:
            stdio.print_format(c"error: cannot read '%.*s'\n", int<-(file_path.len), file_path.data)
            return 1
        Result.success as payload:
            var content = payload.value
            defer: content.release()

            let source = content.as_str()
            var diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer: diags.release()
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

            if sexpr:
                var module_owner = parse_module_name(resolved.as_str())
                defer: module_owner.release()
                var dumped = sexpr_mod.dump_ast(file, module_owner.as_str())
                defer: dumped.release()
                stdio.print_format(c"%.*s\n", int<-(dumped.as_str().len), dumped.as_str().data)
                return 0

            var rendered = ast_formatter.format_source_file(file)
            defer: rendered.release()
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
##   --locked              (accepted — requires package-graph resolution)
##   --frozen              (accepted — implies --locked)
function check_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var input_paths = vec.Vec[str].create()
    defer: input_paths.release()
    var platform = resolver.Platform.linux
    var warnings_as_errors = false

    var i: ptr_uint = 1
    while i < args.len:
        let arg = args[i]
        if arg == "--root" or arg == "-I" or arg == "--include-path":
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
            # Accepted for CLI compatibility; package-graph resolution is not yet implemented.
            i += 1
            continue
        input_paths.push(arg)
        i += 1

    if input_paths.is_empty():
        eprint_line("missing source file path")
        cli_help.print_usage(true)
        return 1

    # Expand directories to their .mt files.
    # Paths are copied into owned Strings so they do not dangle when a directory
    # listing's Entries buffer is released.
    var source_files = vec.Vec[string.String].create()
    defer: source_files.release()
    var si: ptr_uint = 0
    while si < input_paths.len():
        let raw = input_paths.get(si) else:
            break
        let path = unsafe: read(raw)
        if fs.is_directory(path):
            match fs.list_files_recursive(path):
                Result.success as entries_payload:
                    var entries = entries_payload.value
                    defer: entries.release()
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
                    defer: err_msg.release()
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
        defer: file_roots.release()
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

        # Ruby's `roots_for_path` always appends the discovered project root, so
        # `mtc check examples/x.mt` resolves `std.*` without an explicit `-I`.
        # The source's own directory stays the last-resort root for a lone file
        # that lives outside any project (adding it up front would shadow the
        # project root, since roots are matched longest-first).
        add_module_roots(effective, ref_of(file_roots), ref_of(owned_roots))
        if file_roots.is_empty():
            file_roots.push(path_ops.dirname(effective))

        var program = loader.check_program(effective, file_roots.as_span(), platform)
        defer: program.release()

        let errors = program.diagnostic_error_count()
        let warnings = program.diagnostic_warning_count()

        if errors == 0 and warnings == 0:
            # The host's `info` line is verbose-only; default runs stay silent.
            if cli_verbose:
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
                    defer: src.release()
                    var diags = vec.Vec[pstate.ParseDiagnostic].create()
                    defer: diags.release()
                    var lfile = parser.parse_source(src.as_str(), ref_of(diags))
                    # Same options as `mtc lint` (the host's `check` runs the full
                    # lint): owning types, unresolved imports and the analysis'
                    # editable receivers, with `.mt-lint.yml` applied by the
                    # linter itself.
                    var options = linter.default_lint_options()
                    options.owning_type_names = program.owning_type_span()
                    var unresolved = vec.Vec[str].create()
                    defer: unresolved.release()
                    if program.analyses.len() > 0:
                        var up: ptr_uint = 0
                        while up < program.unresolved_import_paths.len():
                            let upp = program.unresolved_import_paths.get(up) else:
                                break
                            unresolved.push(unsafe: read(upp).as_str())
                            up += 1
                        options.unresolved_import_paths = unresolved.as_span()
                        let root_analysis_ptr = program.analyses.get(program.root_index)
                        if root_analysis_ptr != null:
                            unsafe:
                                options.editable_sites = read(root_analysis_ptr).editable_receiver_sites.as_span()
                                options.mutating_sites = read(root_analysis_ptr).mutating_argument_sites.as_span()
                                options.analysis = root_analysis_ptr
                    let maybe_analysis = options.analysis
                    if maybe_analysis != null:
                        unsafe:
                            lfile = read(maybe_analysis).source_file
                    var providers = scope_tracking.build_import_method_providers(lfile, program.analyses.as_span())
                    defer: providers.release()
                    options.method_providers = providers.as_span()
                    var lwarns = linter.lint_source_with(lfile, src.as_str(), effective, options)
                    defer: lwarns.release()
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
##     error[sema/error]: <message> -- <path>:<line>:<column>
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
            var block = string.String.create()
            defer: block.release()
            block.append(prefix)
            block.append("[")
            block.append(rd.code)
            block.append("]: ")
            block.append(message)
            block.append(" -- ")
            block.append(location)
            block.append(":")
            block.append(ptr_uint_to_str(rd.line))
            block.append(":")
            block.append(ptr_uint_to_str(rd.column))
            block.append("\n")
            # Show source context when the diagnostic has a real line and the
            # file is readable.
            if rd.line >= 1:
                match fs.read_text(location):
                    Result.success as source_content:
                        var source_str = source_content.value
                        defer: source_str.release()
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
                            defer: gutter.release()
                            block.append("   |\n")
                            block.append(gutter.as_str())
                            block.append(" | ")
                            block.append(source_line)
                            block.append("\n")
                            block.append("      | ")
                            var sp: ptr_uint = 1
                            while sp < rd.column:
                                block.push_byte(32)
                                sp += 1
                            block.push_byte(94)
                            block.append("\n")
                    Result.failure:
                        pass
            let _ = terminal.write_stderr(block.as_str())
        i += 1
    let _ = terminal.flush_stderr()


## Append "<n> <singular|plural>" (e.g. "1 error", "3 errors") to `buf`.
function append_count_phrase(buf: ref[string.String], n: ptr_uint, singular: str, plural: str) -> void:
    buf.append(ptr_uint_to_str(n))
    buf.push_byte(32)
    if n == 1:
        buf.append(singular)
    else:
        buf.append(plural)


## Print the trailing check summary the way the Ruby CLI does: a blank line,
## then `<N errors[; M warnings][; K notes]>` plus ` found` when there is at
## least one error, on stderr (`1 error found`, `2 warnings`).
function report_check_summary(errors: ptr_uint, warnings: ptr_uint, file_count: ptr_uint, warnings_as_errors: bool) -> void:
    if errors == 0 and warnings == 0:
        return
    eprint_line("")
    var body = string.String.create()
    defer: body.release()
    if errors > 0:
        append_count_phrase(ref_of(body), errors, "error", "errors")
    if warnings > 0:
        if errors > 0:
            body.append("; ")
        append_count_phrase(ref_of(body), warnings, "warning", "warnings")
    if errors > 0:
        body.append(" found")
    eprint_line(body.as_str())


## Lint source files and print `path:line: code: message` per warning, matching
## the Ruby `mtc lint` command.  Directories are expanded to their `.mt` files
## in sorted order.  Exits 1 when any warning is found.
function lint_command(args: span[str]) -> int:
    var input_paths = vec.Vec[str].create()
    defer: input_paths.release()
    var select_set = vec.Vec[str].create()
    defer: select_set.release()
    var ignore_set = vec.Vec[str].create()
    defer: ignore_set.release()
    var fix_mode = false
    var ignore_generated = false
    var timings = false
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var platform = resolver.Platform.linux
    var i: ptr_uint = 1
    while i < args.len:
        let arg = args[i]
        if arg == "-I" or arg == "--root" or arg == "--include-path":
            if i + 1 < args.len:
                roots.push(args[i + 1])
            i += 2
            continue
        if arg == "--platform":
            if i + 1 < args.len:
                match parse_platform_name(args[i + 1]):
                    Option.some as plat:
                        platform = plat.value
                    Option.none:
                        pass
            i += 2
            continue
        if arg == "--fix":
            fix_mode = true
            i += 1
            continue
        if arg == "--ignore-generated":
            ignore_generated = true
            i += 1
            continue
        if arg == "--timings":
            timings = true
            i += 1
            continue
        # Accepted for CLI compatibility; package-graph resolution is not yet
        # implemented (mirrors `check`).
        if arg == "--locked" or arg == "--frozen":
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
        eprint_line("missing source file path")
        cli_help.print_usage(true)
        return 1

    # Collect .mt files.  Paths are copied into owned Strings so they do not
    # dangle when a directory listing's Entries buffer is released.
    var source_files = vec.Vec[string.String].create()
    defer: source_files.release()
    var si: ptr_uint = 0
    while si < input_paths.len():
        let raw = input_paths.get(si) else:
            break
        let path = unsafe: read(raw)
        if fs.is_directory(path):
            match fs.list_files_recursive(path):
                Result.success as entries_payload:
                    var entries = entries_payload.value
                    defer: entries.release()
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
                    defer: err_msg.release()
                    stdio.print_format(c"error: cannot list %.*s\n", int<-(path.len), path.data)
                    return 1
        else:
            source_files.push(string.String.from_str(path))
        si += 1

    var total_warnings: ptr_uint = 0
    var files_with_warnings: ptr_uint = 0

    # The `--timings` profiles, one per linted file, printed after the scan.
    var timing_entries = vec.Vec[LintTimingEntry].create()
    defer: release_lint_timing_entries(ref_of(timing_entries))

    var fi: ptr_uint = 0
    while fi < source_files.len():
        let fp_ptr = source_files.get(fi) else:
            break
        let fp = unsafe: read(fp_ptr).as_str()
        if cli_verbose:
            if fix_mode:
                stdio.print_format(c"fixing %.*s\n", int<-(fp.len), fp.data)
            else:
                stdio.print_format(c"linting %.*s\n", int<-(fp.len), fp.data)
        match fs.read_text(fp):
            Result.success as content:
                var src = content.value
                defer: src.release()

                # `--ignore-generated` skips files emitted by the compiler
                # (first line starts with the generated-file header).
                if ignore_generated and src.as_str().starts_with("# generated by mtc"):
                    fi += 1
                    continue

                # Load the module so the lint sees what the analyzer knows: which
                # methods are `editable` (prefer-let on `var v` + `v.push(1)`),
                # which types own resources, and which imports failed.  The host's
                # linter runs on analyzed files too.
                var lint_roots = vec.Vec[str].create()
                defer: lint_roots.release()
                var rj: ptr_uint = 0
                while rj < roots.len():
                    let rp = roots.get(rj) else:
                        break
                    lint_roots.push(unsafe: read(rp))
                    rj += 1
                var entry_path_owner = string.String.create()
                defer: entry_path_owner.release()
                var source_root_owner = string.String.create()
                defer: source_root_owner.release()
                var lint_target = fp
                match effective_source_path(fp, ref_of(lint_roots), ref_of(entry_path_owner), ref_of(source_root_owner)):
                    Option.some as eff:
                        lint_target = eff.value
                    Option.none:
                        pass
                add_module_roots(lint_target, ref_of(lint_roots), ref_of(owned_roots))
                if lint_roots.is_empty():
                    lint_roots.push(path_ops.dirname(lint_target))
                var lint_program = loader.check_program(lint_target, lint_roots.as_span(), platform)
                defer: lint_program.release()
                var owning_names = lint_program.owning_type_span()
                var unresolved_paths = vec.Vec[str].create()
                defer: unresolved_paths.release()
                var options = linter.default_lint_options()
                options.owning_type_names = owning_names
                options.select = select_set.as_span()
                options.ignore = ignore_set.as_span()
                if lint_program.analyses.len() > 0:
                    var up: ptr_uint = 0
                    while up < lint_program.unresolved_import_paths.len():
                        let upp = lint_program.unresolved_import_paths.get(up) else:
                            break
                        unresolved_paths.push(unsafe: read(upp).as_str())
                        up += 1
                    options.unresolved_import_paths = unresolved_paths.as_span()
                    let root_analysis_ptr = lint_program.analyses.get(lint_program.root_index)
                    if root_analysis_ptr != null:
                        unsafe:
                            options.editable_sites = read(root_analysis_ptr).editable_receiver_sites.as_span()
                            options.mutating_sites = read(root_analysis_ptr).mutating_argument_sites.as_span()
                            options.analysis = root_analysis_ptr

                var file_profile: ptr[profile_mod.Profile]? = null
                if timings:
                    file_profile = new_heap_profile()
                options.profile = file_profile

                if fix_mode:
                    let fix_started_ms = monotonic_ms()
                    var fixed = fix_engine.fix_source(src.as_str(), fp, options)
                    defer: fixed.release()
                    if timings:
                        push_lint_timing(ref_of(timing_entries), fp, file_profile, monotonic_ms() - fix_started_ms, true)
                        file_profile = null
                    if not fixed.as_str().equal(src.as_str()):
                        match fs.write_text(fp, fixed.as_str()):
                            Result.success:
                                if not cli_quiet:
                                    stdio.print_format(c"fixed %.*s\n", int<-(fp.len), fp.data)
                            Result.failure as write_err:
                                var wem = write_err.error
                                defer: wem.release()
                                stdio.print_format(c"error: cannot write %.*s\n", int<-(fp.len), fp.data)
                    fi += 1
                    continue

                var diags = vec.Vec[pstate.ParseDiagnostic].create()
                defer: diags.release()
                var file = parser.parse_source(src.as_str(), ref_of(diags))
                # The analysis' expression-type maps are keyed by expression
                # pointer, so lint the AST the analysis was built from (the host
                # lints `facts.ast` too); the fresh parse is the fallback.
                let maybe_analysis = options.analysis
                if maybe_analysis != null:
                    unsafe:
                        file = read(maybe_analysis).source_file

                var providers = scope_tracking.build_import_method_providers(file, lint_program.analyses.as_span())
                defer: providers.release()
                options.method_providers = providers.as_span()
                let lint_scan_started_ms = monotonic_ms()
                var warns = linter.lint_source_with(file, src.as_str(), fp, options)
                let lint_scan_total_ms = monotonic_ms() - lint_scan_started_ms
                defer: warns.release()
                if timings:
                    push_lint_timing(ref_of(timing_entries), fp, file_profile, lint_scan_total_ms, false)
                    file_profile = null
                if warns.len() > 0:
                    files_with_warnings += 1
                total_warnings += warns.len()
                var wi: ptr_uint = 0
                while wi < warns.len():
                    let wp = warns.get(wi) else:
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
        if timings:
            print_lint_rule_profiles(ref_of(timing_entries))
            print_lint_file_profiles(ref_of(timing_entries))
        return 0

    if total_warnings == 0:
        if input_paths.len() == 1:
            let ip = input_paths.get(0) else:
                return 0
            let ip_str = unsafe: read(ip)
            stdio.print_format(c"clean %.*s\n", int<-(ip_str.len), ip_str.data)
        else:
            stdio.print_format(c"clean %d file(s)\n", int<-(source_files.len()))
        # The host prints only the file-profile block for a clean run.
        if timings:
            print_lint_file_profiles(ref_of(timing_entries))
        return 0

    if timings:
        print_lint_rule_profiles(ref_of(timing_entries))
        print_lint_file_profiles(ref_of(timing_entries))

    let noun = if total_warnings == 1: "warning" else: "warnings"
    var files_str = string.String.create()
    defer: files_str.release()
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
function parse_source_operand(args: span[str], roots: ref[vec.Vec[str]], owned_roots: ref[vec.Vec[string.String]], platform: ref[resolver.Platform]) -> Option[str]:
    var file_path: Option[str] = Option[str].none
    var i: ptr_uint = 1
    while i < args.len:
        let arg = args[i]
        if arg == "--root" or arg == "-I" or arg == "--include-path":
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
            # The nearest ancestor containing `std/` is a module root even when
            # explicit `-I` roots are given: Ruby's `ModuleRoots.roots_for_path`
            # always appends the discovered project root (and the compiler's own
            # root) to whatever the caller passed.  Adding the source's own
            # directory instead would shadow it (roots are matched
            # longest-first) and derive a basename-only module name (e.g. the
            # invalid C identifier `2d_camera_mouse_zoom_main`).
            add_module_roots(p.value, roots, owned_roots)
            return Option[str].some(value = p.value)
        Option.none:
            eprint_line("missing source file path")
            cli_help.print_usage(true)
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
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var platform = resolver.Platform.linux
    var sexpr = false
    var filtered = vec.Vec[str].create()
    defer: filtered.release()
    filtered.push("lower")
    var fi: ptr_uint = 1
    while fi < args.len:
        if args[fi] == "--sexpr":
            sexpr = true
        else:
            filtered.push(args[fi])
        fi += 1
    let path = parse_source_operand(filtered.as_span(), ref_of(roots), ref_of(owned_roots), ref_of(platform)) else:
        return 1

    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer: program.release()

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
    if sexpr:
        var dumped = sexpr_mod.dump_ir(ir_program)
        defer: dumped.release()
        stdio.print_format(c"%.*s\n", int<-(dumped.as_str().len), dumped.as_str().data)
        entry_path_owner.release()
        source_root_owner.release()
        return 0
    var rendered = ir_formatter.format_program(ir_program)
    defer: rendered.release()
    let text = rendered.as_str()
    stdio.print_format(c"%.*s", int<-(text.len), text.data)
    entry_path_owner.release()
    source_root_owner.release()
    return 0


## Compile a checked program to C and print it (`mtc emit-c`).
## Supports both `.mt` files and package directory targets.
function emit_c_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var platform = resolver.Platform.linux
    let path = parse_source_operand(args, ref_of(roots), ref_of(owned_roots), ref_of(platform)) else:
        return 1

    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer: program.release()

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
    var c_source = c_backend.generate_c(ir_program, false, false)
    defer: c_source.release()
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
    defer: manifest_path.release()
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
            defer: source.release()
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
## The path is absolutized first (like Ruby's `ModuleRoots.project_root_for_path`
## calls `File.expand_path`), so a relative source operand still resolves the
## project root — `mtc build standalone/x.mt` run from a fixture directory must
## find the enclosing `std/`.  `owned` keeps the absolutized string alive because
## `roots` holds borrowed views into it.
function discover_project_root(source_path: str, roots: ref[vec.Vec[str]], owned: ref[vec.Vec[string.String]]) -> void:
    owned.push(loader.absolute_path(source_path))
    let last = owned.get(owned.len() - 1) else:
        return
    let abs_path = unsafe: read(last).as_str()
    var current = if fs.is_directory(abs_path): abs_path else: path_ops.dirname(abs_path)
    while true:
        var joined = path_ops.join(current, "std")
        defer: joined.release()
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


## Ruby's `ModuleRoots.roots_for_path` in one step: the discovered project root,
## the enclosing package's source root, and the compiler's own roots
## (`$MILK_TEA_MODULE_ROOT` / `$MILK_TEA_STD_ROOT` and the `std/` next to the
## running binary).  A project living outside this tree still resolves `std.*`,
## and its own modules resolve by their bare names.
function add_module_roots(source_path: str, roots: ref[vec.Vec[str]], owned: ref[vec.Vec[string.String]]) -> void:
    discover_project_root(source_path, roots, owned)

    var candidates = vec.Vec[string.String].create()
    defer: candidates.release()

    match package_manifest.package_source_root_for_path(source_path):
        Option.some as package_root:
            candidates.push(package_root.value)
        Option.none:
            pass

    var compiler_roots = resolver.compiler_root_candidates()
    defer: compiler_roots.release()
    var ci: ptr_uint = 0
    while ci < compiler_roots.len():
        let entry = compiler_roots.get(ci) else:
            break
        candidates.push(string.String.from_str(unsafe: read(entry).as_str()))
        ci += 1

    var i: ptr_uint = 0
    while i < candidates.len():
        let candidate_entry = candidates.get(i) else:
            break
        let candidate = unsafe: read(candidate_entry).as_str()

        var already_present = false
        var j: ptr_uint = 0
        while j < roots.len():
            let existing = roots.get(j) else:
                break
            if unsafe: read(existing).equal(candidate):
                already_present = true
                break
            j += 1

        if not already_present:
            owned.push(string.String.from_str(candidate))
            let pushed = owned.get(owned.len() - 1) else:
                break
            roots.push(unsafe: read(pushed).as_str())
        i += 1


## Build a program (`mtc build`).  Supports both single `.mt` files and package
## directory targets (reads package.toml for the entry point).
function build_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var output_override: Option[str] = Option[str].none
    var keep_c_path: Option[str] = Option[str].none
    var c_compiler = "cc"
    var profile_name = "debug"
    var platform = resolver.Platform.linux
    var clean_mode = false
    var use_cache = true
    var sanitize = false
    var debug_guards: Option[bool] = Option[bool].none
    var filtered = vec.Vec[str].create()
    defer: filtered.release()
    filtered.push("build")
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "-o" or arg == "--output":
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
        if arg == "--debug-guards":
            debug_guards = Option[bool].some(value = true)
            ai += 1
            continue
        if arg == "--no-debug-guards":
            debug_guards = Option[bool].some(value = false)
            ai += 1
            continue
        # Accepted for CLI compatibility; the Ruby build also ignores it.
        if arg == "--timings":
            ai += 1
            continue
        # Accepted for CLI compatibility; package-graph resolution is not yet
        # implemented (mirrors `check`).
        if arg == "--locked" or arg == "--frozen":
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
    let path = parse_source_operand(filtered.as_span(), ref_of(roots), ref_of(owned_roots), ref_of(platform)) else:
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
        defer: clean_output.release()
        if fs.exists(clean_output.as_str()):
            match fs.remove(clean_output.as_str()):
                Result.success:
                    if not cli_quiet:
                        stdio.print_format(c"cleaned %.*s\n", int<-(clean_output.as_str().len), clean_output.as_str().data)
                Result.failure as failure:
                    var msg = failure.error
                    defer: msg.release()
                    stdio.print_format(c"error: cannot remove %.*s\n", int<-(clean_output.as_str().len), clean_output.as_str().data)
                    entry_path_owner.release()
                    source_root_owner.release()
                    return 1
        else:
            if not cli_quiet:
                stdio.print_format(c"cleaned %.*s\n", int<-(clean_output.as_str().len), clean_output.as_str().data)
        entry_path_owner.release()
        source_root_owner.release()
        return 0

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer: program.release()

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
    defer: cache_key.release()
    if cache_enabled:
        var build_guards = profile_name == "debug"
        match debug_guards:
            Option.some as override:
                build_guards = override.value
            Option.none:
                pass
        var computed_key = build_cache.compute_key(ref_of(program), c_compiler, platform_label(platform), profile_name, sanitize, build_guards)
        cache_key.append(computed_key.as_str())
        computed_key.release()
        match build_cache.lookup(cache_key.as_str()):
            Option.some as hit:
                var cached = hit.value
                let copied = build_cache.materialize(cached.as_str(), output_path.as_str())
                cached.release()
                if copied:
                    if not cli_quiet:
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

    match build_driver.build(program, ir_program, output_path.as_str(), c_compiler, roots.as_span(), sanitize, profile_name, debug_guards):
        Result.success as built:
            var output = built.value
            defer: output.release()
            output_path.release()
            if cache_enabled:
                build_cache.store(cache_key.as_str(), output.as_str())
            if not cli_quiet:
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
            defer: message.release()
            let text = message.as_str()
            stdio.print_format(c"error: %.*s\n", int<-(text.len), text.data)
            output_path.release()
            entry_path_owner.release()
            source_root_owner.release()
            return 1


## Run a program (`mtc run`).  Builds and then executes the binary.
function run_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var output_override: Option[str] = Option[str].none
    var keep_c_path: Option[str] = Option[str].none
    var c_compiler = "cc"
    var profile_name = "debug"
    var platform = resolver.Platform.linux
    var use_cache = true
    var sanitize = false
    var debug_guards: Option[bool] = Option[bool].none
    var program_args = vec.Vec[str].create()
    defer: program_args.release()
    var filtered = vec.Vec[str].create()
    defer: filtered.release()
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
        if arg == "-o" or arg == "--output":
            if ai + 1 >= args.len:
                stdio.print_line("error: -o requires an output path")
                return 1
            output_override = Option[str].some(value = args[ai + 1])
            ai += 2
            continue
        if arg == "--keep-c":
            if ai + 1 >= args.len:
                stdio.print_line("error: --keep-c requires a path")
                return 1
            keep_c_path = Option[str].some(value = args[ai + 1])
            ai += 2
            continue
        if arg == "--sanitize":
            sanitize = true
            use_cache = false
            ai += 1
            continue
        if arg == "--debug-guards":
            debug_guards = Option[bool].some(value = true)
            ai += 1
            continue
        if arg == "--no-debug-guards":
            debug_guards = Option[bool].some(value = false)
            ai += 1
            continue
        # Accepted for CLI compatibility; the Ruby build also ignores it.
        if arg == "--timings":
            ai += 1
            continue
        # Accepted for CLI compatibility; package-graph resolution is not yet
        # implemented (mirrors `check`).
        if arg == "--locked" or arg == "--frozen":
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
    let path = parse_source_operand(filtered.as_span(), ref_of(roots), ref_of(owned_roots), ref_of(platform)) else:
        return 1
    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer: program.release()

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
        # Ruby's `run` builds into a temporary directory; use a unique /tmp
        # path so running an example does not drop a binary next to its source
        # (and parallel runs stay independent).
        var default_out = default_output_path(effective)
        defer: default_out.release()
        output_path = string.String.from_str("/tmp/mtc_run_")
        output_path.append(path_ops.basename(default_out.as_str()))
        output_path.push_byte('_')
        fmt_mod.append_long(ref_of(output_path), long<-time.now())

    # Binary cache: reuse the previously built binary when nothing changed.
    # --keep-c always rebuilds so the saved C matches the produced binary.
    let run_cache_enabled = use_cache and keep_c_path.is_none()
    var cache_key = string.String.create()
    defer: cache_key.release()
    if run_cache_enabled:
        var run_guards = profile_name == "debug"
        match debug_guards:
            Option.some as override:
                run_guards = override.value
            Option.none:
                pass
        var computed_key = build_cache.compute_key(ref_of(program), c_compiler, platform_label(platform), profile_name, sanitize, run_guards)
        cache_key.append(computed_key.as_str())
        computed_key.release()
        match build_cache.lookup(cache_key.as_str()):
            Option.some as hit:
                var cached = hit.value
                let copied = build_cache.materialize(cached.as_str(), output_path.as_str())
                cached.release()
                if copied:
                    var cached_output = string.String.from_str(output_path.as_str())
                    defer: cached_output.release()
                    output_path.release()
                    entry_path_owner.release()
                    source_root_owner.release()
                    return execute_binary(cached_output.as_str(), ref_of(program_args))
            Option.none:
                pass

    match build_driver.build(program, ir_program, output_path.as_str(), c_compiler, roots.as_span(), sanitize, profile_name, debug_guards):
        Result.success as built:
            var built_path = built.value
            defer: built_path.release()
            var owned_output = string.String.from_str(output_path.as_str())
            output_path.release()
            defer: owned_output.release()
            entry_path_owner.release()
            source_root_owner.release()
            if run_cache_enabled:
                build_cache.store(cache_key.as_str(), owned_output.as_str())
            return execute_binary(owned_output.as_str(), ref_of(program_args))
        Result.failure as failure:
            var message = failure.error
            defer: message.release()
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
    defer: cmd.release()
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
            defer: capture_result.release()
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
    defer: roots.release()

    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--":
            break
        if arg == "--root" or arg == "-I" or arg == "--include-path":
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
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    defer: cwd.release()
    match fs.current_directory():
        Result.success as dir_payload:
            cwd.release()
            cwd = dir_payload.value
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            dir_error.release()
    if cwd.len() > 0:
        roots.push(cwd.as_str())
        add_module_roots(cwd.as_str(), ref_of(roots), ref_of(owned_roots))

    var resolved = resolve_app_module(name, ref_of(roots)) else:
        stdio.print_format(c"run-module module not found: %.*s\n", int<-(name.len), name.data)
        return 1
    defer: resolved.release()

    var run_args = vec.Vec[str].create()
    defer: run_args.release()
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
    defer: relative.release()
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
    defer: absolute.release()
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
    defer: entry_dir.release()
    match fs.create_directories(entry_dir.as_str()):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            dir_error.release()
            stdio.print_format(c"could not create project directory: %.*s\n", int<-(abs_path.len), abs_path.data)
            return 1
        Result.success:
            pass

    var package_name = snake_case_identifier(path_ops.basename(abs_path))
    defer: package_name.release()

    var manifest = string.String.create()
    defer: manifest.release()
    manifest.append("[package]\nname = \"")
    manifest.append(package_name.as_str())
    manifest.append("\"\nversion = \"0.1.0\"\nsource_root = \"src\"\n\n[build]\nentry = \"src/main.mt\"\n")

    var manifest_path = path_ops.join(abs_path, "package.toml")
    defer: manifest_path.release()
    match fs.write_text(manifest_path.as_str(), manifest.as_str()):
        Result.failure as write_failure:
            var write_error = write_failure.error
            write_error.release()
            stdio.print_line("could not write package.toml")
            return 1
        Result.success:
            pass

    var entry_path = path_ops.join(entry_dir.as_str(), "main.mt")
    defer: entry_path.release()
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


## Generate a binding module from a C header.
## Usage: mtc bindgen MODULE HEADER [-o OUTPUT] [--link LIB] [--include HEADER] [--clang PATH]
function bindgen_command(args: span[str]) -> int:
    var module_name: Option[str] = Option[str].none
    var header: Option[str] = Option[str].none
    var output: Option[str] = Option[str].none
    var link_libs = vec.Vec[str].create()
    var includes = vec.Vec[str].create()
    var clang_str: str = ""

    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "-o" or arg == "--output":
            ai += 1
            if ai >= args.len:
                stdio.print_line("bindgen: -o requires an output path")
                return 1
            output = Option[str].some(value = args[ai])
        else if arg == "--link":
            ai += 1
            if ai >= args.len:
                stdio.print_line("bindgen: --link requires a library name")
                return 1
            link_libs.push(args[ai])
        else if arg == "--include":
            ai += 1
            if ai >= args.len:
                stdio.print_line("bindgen: --include requires a header name")
                return 1
            includes.push(args[ai])
        else if arg == "--clang":
            ai += 1
            if ai >= args.len:
                stdio.print_line("bindgen: --clang requires a path")
                return 1
            clang_str = args[ai]
        else if arg == "--help" or arg == "-h":
            stdio.print_line("usage: mtc bindgen MODULE HEADER [-o OUTPUT] [--link LIB] [--include HEADER] [--clang PATH]")
            return 0
        else if module_name.is_none():
            module_name = Option[str].some(value = arg)
        else if header.is_none():
            header = Option[str].some(value = arg)
        else:
            stdio.print_line("bindgen: unexpected argument")
            return 1
        ai += 1

    let mod_name = module_name else:
        stdio.print_line("bindgen: missing module name")
        return 1
    let header_path = header else:
        stdio.print_line("bindgen: missing header path")
        return 1

    var opts = bindgen.BindgenOptions(
        module_name = string.String.from_str(mod_name),
        header_path = string.String.from_str(header_path),
        output_path = output,
        link_libs = link_libs,
        include_headers = includes,
        clang_bin = clang_str,
    )

    match bindgen.generate(ref_of(opts)):
        Result.success as generated:
            var source = generated.value
            defer: source.release()
            match output:
                Option.some as out_file:
                    match fs.write_text(out_file.value, source.as_str()):
                        Result.success:
                            stdio.print_format(c"generated %.*s -> %.*s\n",
                                int<-(header_path.len), header_path.data,
                                int<-(out_file.value.len), out_file.value.data)
                        Result.failure:
                            stdio.print_line("bindgen: could not write output file")
                            return 1
                Option.none:
                    let st = source.as_str()
                    stdio.print_format(c"%.*s", int<-(st.len), st.data)
            return 0
        Result.failure as failure:
            let mt = failure.error.as_str()
            stdio.print_format(c"bindgen: %.*s\n", int<-(mt.len), mt.data)
            failure.error.release()
            return 1


## Regenerate imported binding modules from raw C bindings and JSON policies.
function imported_bindings_command(args: span[str]) -> int:
    var do_all = false
    var do_check = false
    var lib_name: str = ""

    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--all":
            do_all = true
        else if arg == "--check":
            do_check = true
        else if arg == "--help" or arg == "-h":
            stdio.print_line("usage: mtc imported-bindings <name> [--check] [--all]")
            return 0
        else if lib_name.len == 0:
            lib_name = arg
        else:
            stdio.print_format(c"imported-bindings: unexpected argument '%.*s'\n", int<-(arg.len), arg.data)
            return 1
        ai += 1

    if do_all:
        var failed: ptr_uint = 0
        var i: ptr_uint = 0
        while i < 28:
            let entry_ptr = get(ib_registry.ALL, i) else:
                break
            let entry = unsafe: read(entry_ptr)
            if regenerate_one(entry.policy_path, entry.binding_path, entry.raw_module_name, do_check) != 0:
                failed += 1
            i += 1
        if failed == 0:
            stdio.print_line("all 28 imported bindings generated")
        else:
            stdio.print_format(c"%d binding(s) failed\n", int<-(failed))
            return 1
        return 0

    if lib_name.len == 0:
        stdio.print_line("imported-bindings: missing library name or --all")
        return 1

    let entry = find_ib_entry(lib_name) else:
        stdio.print_format(c"imported-bindings: unknown library '%.*s'\n", int<-(lib_name.len), lib_name.data)
        return 1

    return regenerate_one(entry.policy_path, entry.binding_path, entry.raw_module_name, do_check)


function find_ib_entry(name: str) -> Option[ib_registry.BindingEntry]:
    var i: ptr_uint = 0
    while i < 28:
        let entry_ptr = get(ib_registry.ALL, i) else:
            break
        let entry = unsafe: read(entry_ptr)
        if entry.name.equal(name):
            return Option[ib_registry.BindingEntry].some(value = entry)
        i += 1
    return Option[ib_registry.BindingEntry].none


function regenerate_one(policy_path: str, output_path: str, raw_module_name: str, do_check: bool) -> int:
    # Resolve raw module path: std.c.raymath -> std/c/raymath.mt
    var raw_buf = string.String.with_capacity(raw_module_name.len + 3)
    var ri: ptr_uint = 0
    while ri < raw_module_name.len:
        let ch = raw_module_name.byte_at(ri)
        if ch == '.':
            raw_buf.push_byte('/')
        else:
            raw_buf.push_byte(ch)
        ri += 1
    raw_buf.append(".mt")
    let raw_path = raw_buf.as_str()

    match ib_main.generate(policy_path, raw_path):
        Result.failure as p:
            stdio.print_format(c"imported-bindings: %.*s\n", int<-(p.error.as_str().len), p.error.as_str().data)
            p.error.release()
            raw_buf.release()
            return 1
        Result.success as p:
            if do_check:
                match fs.read_text(output_path):
                    Result.failure:
                        stdio.print_format(c"(new) %.*s would be generated\n", int<-(output_path.len), output_path.data)
                        p.value.release()
                        raw_buf.release()
                        return 0
                    Result.success as existing:
                        let new_src = p.value.as_str()
                        let old_src = existing.value.as_str()
                        if new_src.equal(old_src):
                            stdio.print_format(c"verified %.*s\n", int<-(output_path.len), output_path.data)
                        else:
                            stdio.print_format(c"changed %.*s\n", int<-(output_path.len), output_path.data)
                        existing.value.release()
                p.value.release()
            else:
                match fs.write_text(output_path, p.value.as_str()):
                    Result.failure:
                        stdio.print_format(c"imported-bindings: could not write %.*s\n", int<-(output_path.len), output_path.data)
                        p.value.release()
                        raw_buf.release()
                        return 1
                    Result.success:
                        stdio.print_format(c"generated %.*s + %.*s -> %.*s\n",
                            int<-(raw_module_name.len), raw_module_name.data,
                            int<-(policy_path.len), policy_path.data,
                            int<-(output_path.len), output_path.data)
                p.value.release()
            raw_buf.release()
            return 0
function toolchain_command(args: span[str]) -> int:
    if args.len < 2:
        stdio.print_line("toolchain: missing subcommand")
        stdio.print_line("")
        stdio.print_line("subcommands:")
        stdio.print_line("  doctor      check build tool availability")
        return 1

    let sub = args[1]
    if sub == "--help" or sub == "-h":
        stdio.print_line("usage: mtc toolchain <doctor>")
        return 0

    if sub == "doctor":
        return toolchain_doctor()

    stdio.print_line("toolchain: unknown subcommand")
    return 1


function toolchain_doctor() -> int:
    var all_ok = true
    var checks: array[str, 6] = array[str, 6]("cc", "ar", "clang", "cmake", "ninja", "git")

    var i: ptr_uint = 0
    while i < 6:
        let tool = checks[i]
        if is_executable_on_path(tool):
            stdio.print_format(c"ok   %.*s\n", int<-(tool.len), tool.data)
        else:
            stdio.print_format(c"fail %.*s (not found on PATH)\n", int<-(tool.len), tool.data)
            all_ok = false
        i += 1

    if all_ok:
        return 0
    return 1


function is_executable_on_path(name: str) -> bool:
    var which_cmd = vec.Vec[str].create()
    defer: which_cmd.release()
    which_cmd.push("which")
    which_cmd.push(name)
    match process.capture(which_cmd.as_span()):
        Result.success as captured:
            var result = captured.value
            defer: result.stdout.release()
            defer: result.stderr.release()
            return result.status.exit_code == 0
        Result.failure:
            return false


## A standard-library catalog entry (name, doc summary, category, source path).
struct StdCatalogEntry:
    name: string.String
    description: string.String
    category: string.String
    path: string.String


## `mtc std list|show` — list standard-library modules and print their source,
## mirroring the Ruby CLI's StdCatalog.
function std_command(args: span[str]) -> int:
    if args.len < 2:
        stdio.print_line("missing std subcommand (expected list or show)")
        return 1
    let sub = args[1]
    if sub == "list":
        var as_json = false
        var ai: ptr_uint = 2
        while ai < args.len:
            if args[ai] == "--json":
                as_json = true
            else:
                stdio.print_format(c"unknown std list option %.*s\n", int<-(args[ai].len), args[ai].data)
                return 1
            ai += 1
        return std_list_command(as_json)
    if sub == "show":
        if args.len < 3:
            stdio.print_line("missing module name")
            return 1
        return std_show_command(args[2])
    stdio.print_format(c"unknown std subcommand %.*s\n", int<-(sub.len), sub.data)
    return 1


## Locate the standard library directory: `$MILK_TEA_STD_ROOT` when set, else the
## `std/` directory under the current directory's project root.
function std_root_dir() -> Option[string.String]:
    match env.get("MILK_TEA_STD_ROOT"):
        Option.some as v:
            if fs.is_directory(v.value):
                return Option[string.String].some(value = string.String.from_str(v.value))
        Option.none:
            pass
    var cwd = string.String.create()
    defer: cwd.release()
    match fs.current_directory():
        Result.success as cwd_payload:
            cwd.release()
            cwd = cwd_payload.value
        Result.failure:
            pass
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    if cwd.len() > 0:
        roots.push(cwd.as_str())
        add_module_roots(cwd.as_str(), ref_of(roots), ref_of(owned_roots))
    var i: ptr_uint = 0
    while i < roots.len():
        let rp = roots.get(i) else:
            break
        let root = unsafe: read(rp)
        var candidate = path_ops.join(root, "std")
        if fs.is_directory(candidate.as_str()):
            return Option[string.String].some(value = candidate)
        candidate.release()
        i += 1
    return Option[string.String].none


function std_list_command(as_json: bool) -> int:
    let root_opt = std_root_dir() else:
        stdio.print_line("std: cannot locate the standard library (set MILK_TEA_STD_ROOT)")
        return 1
    var root = root_opt
    defer: root.release()
    var entries = collect_std_entries(root.as_str())
    defer: release_std_entries(ref_of(entries))
    if as_json:
        emit_std_json(ref_of(entries))
        return 0
    print_std_entries(ref_of(entries))
    return 0


function std_show_command(name: str) -> int:
    if name.len == 0 or name.contains_substring(".."):
        stdio.print_format(c"std module not found: %.*s\n", int<-(name.len), name.data)
        return 1
    let root_opt = std_root_dir() else:
        stdio.print_line("std: cannot locate the standard library (set MILK_TEA_STD_ROOT)")
        return 1
    var root = root_opt
    defer: root.release()
    var relative = string.String.create()
    defer: relative.release()
    var i: ptr_uint = 0
    while i < name.len:
        let b = name.byte_at(i)
        if b == '.':
            relative.push_byte('/')
        else:
            relative.push_byte(b)
        i += 1
    var base_path = path_ops.join(root.as_str(), relative.as_str())
    # `.linux`/`.windows`/`.wasm` variants are preferred over the shared file,
    # matching the compiler's import resolution.
    var variant_path = string.String.create()
    defer: variant_path.release()
    variant_path.append(base_path.as_str())
    variant_path.append(".linux.mt")
    var shared_path = string.String.create()
    defer: shared_path.release()
    shared_path.append(base_path.as_str())
    shared_path.append(".mt")
    if fs.is_file(variant_path.as_str()):
        return print_std_source(variant_path.as_str(), name)
    if fs.is_file(shared_path.as_str()):
        return print_std_source(shared_path.as_str(), name)
    stdio.print_format(c"std module not found: %.*s\n", int<-(name.len), name.data)
    return 1


function print_std_source(path: str, name: str) -> int:
    match fs.read_text(path):
        Result.success as payload:
            var content = payload.value
            defer: content.release()
            stdio.print_format(c"%.*s", int<-(content.as_str().len), content.as_str().data)
            return 0
        Result.failure:
            stdio.print_format(c"std module not found: %.*s\n", int<-(name.len), name.data)
            return 1


function collect_std_entries(root: str) -> vec.Vec[StdCatalogEntry]:
    var entries = vec.Vec[StdCatalogEntry].create()
    match fs.list_entries(root):
        Result.success as names_payload:
            var names = names_payload.value
            defer: names.release()
            var i: ptr_uint = 0
            while i < names.len():
                let name = names.get(i) else:
                    break
                var full = path_ops.join(root, name)
                defer: full.release()
                if name.ends_with(".mt") and fs.is_file(full.as_str()):
                    std_add_entry(ref_of(entries), full.as_str(), std_logical_name(name))
                else if fs.is_directory(full.as_str()) and not name.equal("c"):
                    match fs.list_entries(full.as_str()):
                        Result.success as sub_payload:
                            var subs = sub_payload.value
                            defer: subs.release()
                            var si: ptr_uint = 0
                            while si < subs.len():
                                let sname = subs.get(si) else:
                                    break
                                if sname.ends_with(".mt"):
                                    var sfull = path_ops.join(full.as_str(), sname)
                                    if fs.is_file(sfull.as_str()):
                                        var logical = string.String.create()
                                        logical.append(name)
                                        logical.push_byte('.')
                                        logical.append(std_logical_name(sname))
                                        std_add_entry(ref_of(entries), sfull.as_str(), logical.as_str())
                                        logical.release()
                                    sfull.release()
                                si += 1
                        Result.failure:
                            pass
                i += 1
        Result.failure:
            pass
    entries.sort_by(std_entry_compare)
    return entries


function std_entry_compare(left: ptr[StdCatalogEntry], right: ptr[StdCatalogEntry]) -> int:
    let l = unsafe: read(left).name.as_str()
    let r = unsafe: read(right).name.as_str()
    return l.compare(r)


## The logical module name of a `std/*.mt` file: the stem with any platform
## suffix (`.linux`/`.windows`/`.wasm`) removed.
function std_logical_name(filename: str) -> str:
    var stem = filename.slice(0, filename.len - 3)
    if stem.ends_with(".linux"):
        return stem.slice(0, stem.len - 6)
    if stem.ends_with(".windows"):
        return stem.slice(0, stem.len - 8)
    if stem.ends_with(".wasm"):
        return stem.slice(0, stem.len - 5)
    return stem


## Add (or replace) an entry for a module file.  Generated modules are skipped;
## the shared file beats platform variants, and among variants the host platform
## (linux) wins.
function std_add_entry(entries: ref[vec.Vec[StdCatalogEntry]], path: str, name: str) -> void:
    match fs.read_text(path):
        Result.success as payload:
            var content = payload.value
            defer: content.release()
            let text = content.as_str()
            if text.starts_with("# generated by mtc"):
                return
            var description = string.String.create()
            defer: description.release()
            var category = string.String.create()
            defer: category.release()
            match std_catalog.std_registry_lookup(name):
                Option.some as info:
                    category.append(info.value.category)
                    description.append(info.value.description)
                Option.none:
                    description.append(std_doc_summary(text))
            # Replace an existing entry when this path is preferred.
            var existing: ptr[StdCatalogEntry]? = null
            var idx: ptr_uint = 0
            while idx < entries.len():
                let ep = entries.get(idx) else:
                    break
                if unsafe: read(ep).name.as_str() == name:
                    existing = ep
                    break
                idx += 1
            if existing != null:
                let old_path = unsafe: read(ptr[StdCatalogEntry]<-existing).path.as_str()
                if not std_path_preferred(path, old_path):
                    return
                var old = unsafe: read(ptr[StdCatalogEntry]<-existing)
                old.description.release()
                old.category.release()
                old.path.release()
                old.description = string.String.from_str(description.as_str())
                old.category = string.String.from_str(category.as_str())
                old.path = string.String.from_str(path)
                unsafe:
                    read(ptr[StdCatalogEntry]<-existing) = old
                return
            entries.push(StdCatalogEntry(
                name = string.String.from_str(name),
                description = string.String.from_str(description.as_str()),
                category = string.String.from_str(category.as_str()),
                path = string.String.from_str(path),
            ))
        Result.failure:
            pass


## Prefer a shared file over any platform variant; among variants the host
## platform (linux) wins, then the alphabetically smaller path.
function std_path_preferred(candidate: str, current: str) -> bool:
    let (c_variant, c_platform) = std_path_rank(candidate)
    let (u_variant, u_platform) = std_path_rank(current)
    if c_variant != u_variant:
        return c_variant < u_variant
    if c_platform != u_platform:
        return c_platform < u_platform
    return candidate.compare(current) < 0


function std_path_rank(path: str) -> (int, int):
    var is_variant = false
    var platform = 0
    if path.ends_with(".linux.mt"):
        is_variant = true
        platform = 0
    else if path.ends_with(".windows.mt"):
        is_variant = true
        platform = 1
    else if path.ends_with(".wasm.mt"):
        is_variant = true
        platform = 2
    if is_variant:
        return (1, platform)
    return (0, 0)


## The first `##` doc-comment line of a module, or an empty string.
function std_doc_summary(source: str) -> str:
    var pos: ptr_uint = 0
    while pos < source.len:
        var line_end = pos
        while line_end < source.len and source.byte_at(line_end) != 10:
            line_end += 1
        let line = source.slice(pos, line_end - pos)
        var trimmed = line
        while trimmed.len > 0 and (trimmed.byte_at(0) == 32 or trimmed.byte_at(0) == 9):
            trimmed = trimmed.slice(1, trimmed.len - 1)
        if trimmed.len > 0:
            if trimmed.starts_with("##"):
                var text = trimmed.slice(2, trimmed.len - 2)
                while text.len > 0 and text.byte_at(0) == 32:
                    text = text.slice(1, text.len - 1)
                while text.len > 0 and (text.byte_at(text.len - 1) == 32 or text.byte_at(text.len - 1) == 13):
                    text = text.slice(0, text.len - 1)
                return text
            break
        pos = line_end + 1
    return ""


function release_std_entries(entries: ref[vec.Vec[StdCatalogEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        unsafe:
            var e = read(ep)
            e.name.release()
            e.description.release()
            e.category.release()
            e.path.release()
        i += 1
    entries.release()


function append_padded(buf: ref[string.String], text: str, width: ptr_uint) -> void:
    buf.append(text)
    var pad = if text.len < width: width - text.len else: 0
    while pad > 0:
        buf.push_byte(' ')
        pad -= 1


function print_std_entries(entries: ref[vec.Vec[StdCatalogEntry]]) -> void:
    var name_width: ptr_uint = 0
    var description_width: ptr_uint = 0
    var i: ptr_uint = 0
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        unsafe:
            let e = read(ep)
            if e.name.as_str().len > name_width:
                name_width = e.name.as_str().len
            if e.description.as_str().len > description_width:
                description_width = e.description.as_str().len
        i += 1
    var ci: ptr_uint = 0
    while ci < std_catalog.std_category_order_count():
        let category = std_catalog.std_category_order_at(ci)
        var printed_header = false
        var ei: ptr_uint = 0
        while ei < entries.len():
            let ep = entries.get(ei) else:
                break
            unsafe:
                let e = read(ep)
                if e.category.as_str() == category and category.len > 0:
                    if not printed_header:
                        stdio.print_format(c"%.*s:\n", int<-(category.len), category.data)
                        printed_header = true
                    var line = string.String.create()
                    defer: line.release()
                    line.append("  ")
                    append_padded(ref_of(line), e.name.as_str(), name_width)
                    line.append("  ")
                    let description = if e.description.as_str().len > 0: e.description.as_str() else: "(no description)"
                    append_padded(ref_of(line), description, description_width)
                    line.append("  ")
                    line.append(e.path.as_str())
                    stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
            ei += 1
        if printed_header:
            stdio.print_line("")
        ci += 1


function append_json_string(buf: ref[string.String], text: str) -> void:
    buf.push_byte('"')
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == 34:
            buf.append("\\\"")
        else if b == 92:
            buf.append("\\\\")
        else if b == 10:
            buf.append("\\n")
        else if b == 13:
            buf.append("\\r")
        else if b == 9:
            buf.append("\\t")
        else:
            buf.push_byte(b)
        i += 1
    buf.push_byte('"')


function emit_std_json(entries: ref[vec.Vec[StdCatalogEntry]]) -> void:
    var buf = string.String.create()
    defer: buf.release()
    buf.push_byte('[')
    var i: ptr_uint = 0
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        unsafe:
            let e = read(ep)
            if i > 0:
                buf.push_byte(',')
            buf.append("{\"name\":")
            append_json_string(ref_of(buf), e.name.as_str())
            buf.append(",\"description\":")
            if e.description.as_str().len > 0:
                append_json_string(ref_of(buf), e.description.as_str())
            else:
                buf.append("null")
            buf.append(",\"category\":")
            if e.category.as_str().len > 0:
                append_json_string(ref_of(buf), e.category.as_str())
            else:
                buf.append("null")
            buf.append(",\"path\":")
            append_json_string(ref_of(buf), e.path.as_str())
            buf.push_byte('}')
        i += 1
    buf.push_byte(']')
    stdio.print_format(c"%.*s\n", int<-(buf.as_str().len), buf.as_str().data)


function snapshot_command(args: span[str]) -> int:
    var input_path_opt: Option[str] = Option[str].none
    var theme_path_opt: Option[str] = Option[str].none
    var output_path_opt: Option[str] = Option[str].none
    var textmate_only = false
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--theme" or arg == "-t":
            if ai + 1 >= args.len:
                stdio.print_line("snapshot: missing value for --theme")
                return 1
            theme_path_opt = Option[str].some(value = args[ai + 1])
            ai += 2
            continue
        if arg == "--output" or arg == "-o":
            if ai + 1 >= args.len:
                stdio.print_line("snapshot: missing value for --output")
                return 1
            output_path_opt = Option[str].some(value = args[ai + 1])
            ai += 2
            continue
        if arg == "--textmate-only":
            textmate_only = true
            ai += 1
            continue
        if arg.starts_with("-"):
            stdio.print_format(c"snapshot: unknown option %.*s\n", int<-(arg.len), arg.data)
            return 1
        if input_path_opt.is_some():
            stdio.print_format(c"snapshot: unexpected argument %.*s\n", int<-(arg.len), arg.data)
            return 1
        input_path_opt = Option[str].some(value = arg)
        ai += 1

    let input_path = input_path_opt else:
        stdio.print_line("snapshot: missing source file path")
        return 1

    if not fs.is_file(input_path):
        stdio.print_format(c"snapshot: source file not found: %.*s\n", int<-(input_path.len), input_path.data)
        return 1

    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    add_module_roots(input_path, ref_of(roots), ref_of(owned_roots))

    var project_root: Option[str] = Option[str].none
    if roots.len() > 0:
        unsafe:
            let rp = roots.get(roots.len() - 1) else:
                fatal(c"snapshot root missing")
            project_root = Option[str].some(value = read(rp))

    let pr = if project_root.is_some(): project_root.unwrap() else: path_ops.dirname(input_path)

    var snapshot_js = path_ops.join(pr, "bindings/vscode/scripts/snapshot.js")
    defer: snapshot_js.release()
    if not fs.is_file(snapshot_js.as_str()):
        stdio.print_format(
            c"snapshot: internal script not found at %.*s\n",
            int<-(snapshot_js.as_str().len), snapshot_js.as_str().data,
        )
        return 1

    var resolved_theme = string.String.create()
    defer: resolved_theme.release()
    match theme_path_opt:
        Option.some as tp:
            resolved_theme.append(tp.value)
        Option.none:
            var default_theme = path_ops.join(pr, "bindings/vscode/themes/2026-dark.json")
            resolved_theme.append(default_theme.as_str())
            default_theme.release()

    if not fs.is_file(resolved_theme.as_str()):
        stdio.print_format(
            c"snapshot: theme file not found: %.*s\n",
            int<-(resolved_theme.as_str().len), resolved_theme.as_str().data,
        )
        return 1

    var semantic_json_owned: Option[string.String] = Option[string.String].none
    var semantic_temp_path: Option[string.String] = Option[string.String].none
    if not textmate_only:
        match fs.read_text(input_path):
            Result.success as src_payload:
                var source = src_payload.value
                defer: source.release()
                var entries_json = sem_tokens.snapshot_semantic_entries(source.as_str())
                if entries_json.len() > 2:
                    match fs.create_temporary_file_in_system_temp("mt_semantic_", ".json"):
                        Result.success as tmp_payload:
                            var tmp_path = tmp_payload.value
                            match fs.write_text(tmp_path.as_str(), entries_json.as_str()):
                                Result.success:
                                    semantic_json_owned = Option[string.String].some(value = entries_json)
                                    semantic_temp_path = Option[string.String].some(value = tmp_path)
                                Result.failure as write_err:
                                    write_err.error.release()
                                    tmp_path.release()
                                    entries_json.release()
                        Result.failure as tmp_err:
                            tmp_err.error.release()
                            entries_json.release()
                else:
                    entries_json.release()
            Result.failure:
                pass

    var node_cmd = vec.Vec[str].create()
    defer: node_cmd.release()
    node_cmd.push("node")
    node_cmd.push(snapshot_js.as_str())
    node_cmd.push(input_path)
    node_cmd.push("-t")
    node_cmd.push(resolved_theme.as_str())
    match output_path_opt:
        Option.some as op:
            node_cmd.push("-o")
            node_cmd.push(op.value)
        Option.none:
            pass
    match semantic_temp_path:
        Option.some as sem_path:
            node_cmd.push("-s")
            node_cmd.push(sem_path.value.as_str())
        Option.none:
            pass

    var exit_code: int = 1
    match process.capture(node_cmd.as_span()):
        Result.success as captured:
            var result = captured.value
            defer: result.release()
            let stdout_opt = result.stdout_text()
            if stdout_opt.is_some():
                let stdout_text = stdout_opt.unwrap()
                if output_path_opt.is_none():
                    stdio.print_format(c"%.*s", int<-(stdout_text.len), stdout_text.data)
            let stderr_opt = result.stderr_text()
            if stderr_opt.is_some():
                let stderr_text = stderr_opt.unwrap()
                if stderr_text.len > 0:
                    let _w = terminal.write_stderr(stderr_text)
            exit_code = int<-(result.status.exit_code)
        Result.failure:
            stdio.print_line("snapshot: node execution failed")

    match semantic_temp_path:
        Option.some as tp:
            let _ = fs.remove(tp.value.as_str())
            tp.value.release()
        Option.none:
            pass
    match semantic_json_owned:
        Option.some as j:
            j.value.release()
        Option.none:
            pass

    return exit_code


function debug_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var platform = resolver.Platform.linux

    var filtered = vec.Vec[str].create()
    defer: filtered.release()
    filtered.push("debug")
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--root" or arg == "-I" or arg == "--include-path":
            if ai + 1 >= args.len:
                stdio.print_line("error: -I requires a directory")
                return 1
            roots.push(args[ai + 1])
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

    let path = parse_source_operand(filtered.as_span(), ref_of(roots), ref_of(owned_roots), ref_of(platform)) else:
        return 1

    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer: program.release()

    stdio.print_format(c"File: %.*s\n", int<-(effective.len), effective.data)

    # Source info
    match fs.read_text(effective):
        Result.failure:
            pass
        Result.success as src_payload:
            var source_text = src_payload.value
            defer: source_text.release()
            let source = source_text.as_str()
            stdio.print_format(c"Content: %d lines, %d bytes\n\n", int<-(line_count(source)), int<-(source.len))

            # Token summary
            var all_tokens = lexer.lex(source)
            defer: all_tokens.release()
            print_token_summary(ref_of(all_tokens))
            stdio.print_line("")

    # Parse diagnostics from program
    stdio.print_line("── Diagnostics ──")
    if program.diagnostics.len() == 0:
        stdio.print_line("  (none)")
    else:
        var di: ptr_uint = 0
        while di < program.diagnostics.len():
            let dp = program.diagnostics.get(di) else:
                break
            let d = unsafe: read(dp)
            stdio.print_format(c"  %.*s: %.*s\n", int<-(d.path.len), d.path.data, int<-(d.message.len), d.message.data)
            di += 1
    stdio.print_line("")

    # Root analysis facts
    let root_analysis_ptr = program.analyses.get(program.root_index) else:
        stdio.print_line("── Facts  (no analyses) ──")
        entry_path_owner.release()
        source_root_owner.release()
        return 0

    let analysis = unsafe: read(root_analysis_ptr)
    let type_count = analysis.types.len()
    let fn_count = analysis.functions.len()
    let val_count = analysis.value_types.len()
    let struct_count = analysis.structs.len()
    let iface_count = analysis.interfaces.len()
    let import_count = analysis.imports.len()
    let alias_count = analysis.type_alias_types.len()
    let method_count = analysis.method_sigs.len()

    stdio.print_format(c"── Facts  module \"%.*s\"  ", int<-(analysis.module_name.len), analysis.module_name.data)
    stdio.print_format(c"%d types, %d functions, %d values, %d structs, ", int<-(type_count), int<-(fn_count), int<-(val_count), int<-(struct_count))
    stdio.print_format(c"%d interfaces, %d imports, %d aliases, %d methods\n", int<-(iface_count), int<-(import_count), int<-(alias_count), int<-(method_count))

    # Functions
    if fn_count > 0:
        stdio.print_line("")
        stdio.print_line("  Functions:")
        var fn_keys = analysis.functions.keys()
        while true:
            let kp = fn_keys.next() else:
                break
            let name = unsafe: read(kp)
            let sig_ptr = analysis.functions.get(name) else:
                fatal(c"debug missing fn sig")
            let sig = unsafe: read(sig_ptr)
            stdio.print_format(c"    %.*s(", int<-(name.len), name.data)
            var pi2: ptr_uint = 0
            while pi2 < sig.params.len:
                let param = unsafe: read(sig.params.data + pi2)
                if pi2 > 0:
                    stdio.print_format(c", ")
                stdio.print_format(c"%.*s", int<-(param.name.len), param.name.data)
                pi2 += 1
            stdio.print_format(c")\n")

    # Structs
    if struct_count > 0:
        stdio.print_line("")
        stdio.print_line("  Structs:")
        var s_keys = analysis.structs.keys()
        while true:
            let kp = s_keys.next() else:
                break
            let name = unsafe: read(kp)
            stdio.print_format(c"    %.*s\n", int<-(name.len), name.data)

    # Interfaces
    if iface_count > 0:
        stdio.print_line("")
        stdio.print_line("  Interfaces:")
        var i_keys = analysis.interfaces.keys()
        while true:
            let kp = i_keys.next() else:
                break
            let name = unsafe: read(kp)
            stdio.print_format(c"    %.*s\n", int<-(name.len), name.data)

    # Imports
    if import_count > 0:
        stdio.print_line("")
        stdio.print_line("  Imports:")
        var imp_keys = analysis.imports.keys()
        while true:
            let kp = imp_keys.next() else:
                break
            let alias = unsafe: read(kp)
            let path_ptr = analysis.imports.get(alias) else:
                fatal(c"debug missing import")
            let path_val = unsafe: read(path_ptr)
            stdio.print_format(c"    %.*s → %.*s\n", int<-(alias.len), alias.data, int<-(path_val.len), path_val.data)

    # Type aliases
    if alias_count > 0:
        stdio.print_line("")
        stdio.print_line("  Type Aliases:")
        var ta_keys = analysis.type_alias_types.keys()
        while true:
            let kp = ta_keys.next() else:
                break
            let name = unsafe: read(kp)
            stdio.print_format(c"    %.*s\n", int<-(name.len), name.data)

    entry_path_owner.release()
    source_root_owner.release()
    return 0


function line_count(source: str) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == 10:
            count += 1
        i += 1
    if source.len > 0 and source.byte_at(source.len - 1) != 10:
        count += 1
    return count


function print_token_summary(tokens: ref[vec.Vec[token_mod.Token]]) -> void:
    var ident_count: ptr_uint = 0
    var nl_count: ptr_uint = 0
    stdio.print_format(c"── Tokens  %d  (", int<-(tokens.len()))
    var ti: ptr_uint = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let t = unsafe: read(tp)
        if t.kind == tk.TokenKind.newline:
            nl_count += 1
        if t.kind == tk.TokenKind.identifier:
            ident_count += 1
        ti += 1
    stdio.print_format(c"%d identifier, %d newline", int<-(ident_count), int<-(nl_count))
    stdio.print_line(c")")


struct CommandSummary:
    name: str
    summary: str


## The self-host's implemented command set with the same one-line summaries as
## Ruby's CLI::COMMANDS (used by the zsh/fish completion scripts).
function command_summary_count() -> ptr_uint:
    return 19


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
    if index == 13:
        return CommandSummary(name = "bindgen", summary = "Generate a binding module from a C header")
    if index == 14:
        return CommandSummary(name = "toolchain", summary = "Manage the native toolchain")
    if index == 15:
        return CommandSummary(name = "std", summary = "List standard library modules and print their source")
    if index == 16:
        return CommandSummary(name = "snapshot", summary = "Render a highlighted HTML snapshot")
    if index == 17:
        return CommandSummary(name = "debug", summary = "Print tokens, AST facts, and diagnostics")
    return CommandSummary(name = "completions", summary = "Print a shell completion script")


## Format a source file: parse, pretty-print, and either print to stdout,
## check for formatting diffs, or write back to the file.
function format_command(args: span[str]) -> int:
    var file_path: Option[str] = Option[str].none
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
                stdio.print_line("error: --max-line-length requires a value")
                return 1
            let parsed = parse_positive_int(args[ai + 1]) else:
                stdio.print_line("--max-line-length must be a positive integer")
                return 1
            explicit_max_line_length = parsed
            ai += 2
            continue
        if arg == "--":
            ai += 1
            while ai < args.len:
                if file_path.is_none():
                    file_path = Option[str].some(value= args[ai])
                ai += 1
            continue
        if file_path.is_none():
            file_path = Option[str].some(value= arg)
            ai += 1
            continue
        stdio.print_format(c"error: unknown option %.*s\n", int<-(arg.len), arg.data)
        return 1

    if check_mode and write_mode:
        stdio.print_line("format options --check and --write cannot be combined")
        return 1

    let path = file_path else:
        stdio.print_line("error: format requires a source file path")
        return 1

    if cli_verbose:
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
                stdio.print_format(c"error: %.*s: parse error\n", int<-(path.len), path.data)
                return 1
            defer: formatted.release()
            let fmt_text = formatted.as_str()

            var exit_code = 0
            if write_mode:
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
            stdio.print_format(c"error: cannot read %.*s\n", int<-(path.len), path.data)
            return 1


## The default output path for a source build: the source path with its `.mt`
## extension removed (matching the Ruby CLI's direct-source-build behaviour).
function default_output_path(path: str) -> string.String:
    if path.ends_with(".mt"):
        return string.String.from_str(path.slice(0, path.len - 3))
    return j2_path(path, ".out")


function keep_c_to_file(ir_program: ir.Program, output_path_str: str) -> void:
    var c_source = c_backend.generate_c(ir_program, false, false)
    defer: c_source.release()
    match fs.write_text(output_path_str, c_source.as_str()):
        Result.success:
            if not cli_quiet:
                stdio.print_format(c"saved C to %.*s\n", int<-(output_path_str.len), output_path_str.data)
        Result.failure as failure:
            var err = failure.error
            defer: err.release()
            stdio.print_format(
                c"warning: could not write C to %.*s\n",
                int<-(output_path_str.len), output_path_str.data,
            )


## Milliseconds from the monotonic clock, used by `--timings` reports.
function monotonic_ms() -> double:
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


## One linted file's `--timings` profile (the host's `lint_profiles` entry):
## its path, the per-rule phase profile (heap-allocated; the entry owns it),
## the scan's total milliseconds, and which scan produced it.
struct LintTimingEntry:
    path: string.String
    profile: ptr[profile_mod.Profile]
    total_ms: double
    pre_fix: bool


## A heap profile for one linted file.
function new_heap_profile() -> ptr[profile_mod.Profile]:
    let memory = unsafe: ptr[profile_mod.Profile]<-heap.must_alloc[profile_mod.Profile](1)
    unsafe:
        read(memory) = profile_mod.create()
    return memory


## Release a heap profile and its storage.
function release_heap_profile(profile: ptr[profile_mod.Profile]) -> void:
    unsafe:
        var value = read(profile)
        profile_mod.release(ref_of(value))
    heap.release(profile)


## Move one file's profile into the timing entries (a no-op without a profile).
function push_lint_timing(entries: ref[vec.Vec[LintTimingEntry]], path: str, profile: ptr[profile_mod.Profile]?, total_ms: double, pre_fix: bool) -> void:
    let p = profile else:
        return
    entries.push(LintTimingEntry(path = string.String.from_str(path), profile = p, total_ms = total_ms, pre_fix = pre_fix))


function release_lint_timing_entries(entries: ref[vec.Vec[LintTimingEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        unsafe:
            var entry = read(ep)
            entry.path.release()
            release_heap_profile(entry.profile)
        i += 1
    entries.release()


## The host's `print_lint_rule_profiles`: per file, `lint profile <path>
## (<mode>): rules=… total=…`, the per-rule rows (code, count, total, average,
## share), then the non-rule hot phases.
function print_lint_rule_profiles(entries: ref[vec.Vec[LintTimingEntry]]) -> void:
    var ei: ptr_uint = 0
    while ei < entries.len():
        let ep = entries.get(ei) else:
            break
        var entry = unsafe: read(ep)
        var profile_value = unsafe: read(entry.profile)
        let rule_total = profile_mod.prefix_total_ms(ref_of(profile_value), "rule.")
        let overall_total = profile_mod.total_ms(ref_of(profile_value))

        var line = string.String.create()
        defer: line.release()
        line.append("lint profile ")
        line.append(entry.path.as_str())
        line.append(if entry.pre_fix: " (pre-fix scan): rules=" else: " (lint scan): rules=")
        fmt_mod.append_double_precision(ref_of(line), rule_total, 1)
        line.append("ms total=")
        fmt_mod.append_double_precision(ref_of(line), overall_total, 1)
        line.append("ms")
        stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)

        var rows = profile_mod.rule_rows(ref_of(profile_value), 12, 0.0)
        defer: release_rule_rows(ref_of(rows))
        if rows.len() == 0:
            stdio.print_format(c"  no rule timing data captured\n")
        else:
            var ri: ptr_uint = 0
            while ri < rows.len():
                let rp = rows.get(ri) else:
                    break
                let row = unsafe: read(rp)
                var row_text = string.String.create()
                defer: row_text.release()
                row_text.append("  ")
                row_text.append(row.code.as_str())
                row_text.append_format(f":#{row.count}x total=")
                fmt_mod.append_double_precision(ref_of(row_text), row.total_ms, 1)
                row_text.append("ms avg=")
                fmt_mod.append_double_precision(ref_of(row_text), row.avg_ms, 2)
                row_text.append("ms share=")
                fmt_mod.append_double_precision(ref_of(row_text), row.share, 1)
                row_text.append("%")
                stdio.print_format(c"%.*s\n", int<-(row_text.as_str().len), row_text.as_str().data)
                ri += 1
        var hot = profile_mod.hot_phases_text(ref_of(profile_value), 5, 1.0)
        defer: hot.release()
        if hot.len() > 0:
            var hot_line = string.String.create()
            defer: hot_line.release()
            hot_line.append("  non-rule hot phases: ")
            hot_line.append(hot.as_str())
            stdio.print_format(c"%.*s\n", int<-(hot_line.as_str().len), hot_line.as_str().data)
        ei += 1


function release_rule_rows(rows: ref[vec.Vec[profile_mod.RuleRow]]) -> void:
    var i: ptr_uint = 0
    while i < rows.len():
        let rp = rows.get(i) else:
            break
        unsafe:
            var row = read(rp)
            row.code.release()
        i += 1
    rows.release()


## The host's `print_lint_file_profiles`: a blank line, `Profile (lint): N
## file(s)`, each file's non-rule phases (>= 1ms) by descending total, and the
## summed total.
function print_lint_file_profiles(entries: ref[vec.Vec[LintTimingEntry]]) -> void:
    if entries.len() == 0:
        return
    var order = vec.Vec[ptr_uint].create()
    defer: order.release()
    var i: ptr_uint = 0
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        let total = unsafe: read(ep).total_ms
        order.push(i)
        var j = i
        while j > 0:
            let prev_ptr = order.get(j - 1) else:
                break
            let prev_index = unsafe: read(prev_ptr)
            let prev_entry_ptr = entries.get(prev_index) else:
                break
            let prev_total = unsafe: read(prev_entry_ptr).total_ms
            if prev_total >= total:
                break
            let cur_ptr = order.get(j) else:
                break
            unsafe:
                read(cur_ptr) = prev_index
            j -= 1
        let slot_ptr = order.get(j) else:
            break
        unsafe:
            read(slot_ptr) = i
        i += 1

    var header = string.String.create()
    defer: header.release()
    header.push_byte(10)
    header.append("Profile (lint): ")
    header.append_format(f"#{order.len()} file(s)")
    stdio.print_format(c"%.*s\n", int<-(header.as_str().len), header.as_str().data)

    var total: double = 0.0
    var oi: ptr_uint = 0
    while oi < order.len():
        let idx_ptr = order.get(oi) else:
            break
        let idx = unsafe: read(idx_ptr)
        let entry_ptr = entries.get(idx) else:
            break
        var entry = unsafe: read(entry_ptr)
        total = total + entry.total_ms
        var profile_value = unsafe: read(entry.profile)
        var phases = profile_mod.phases_desc_text(ref_of(profile_value), 1.0, false)
        defer: phases.release()
        var file_line = string.String.create()
        defer: file_line.release()
        file_line.append("  ")
        file_line.append(entry.path.as_str())
        file_line.append(": ")
        fmt_mod.append_double_precision(ref_of(file_line), entry.total_ms, 1)
        file_line.append("ms")
        if phases.len() > 0:
            file_line.append(" (")
            file_line.append(phases.as_str())
            file_line.append(")")
        stdio.print_format(c"%.*s\n", int<-(file_line.as_str().len), file_line.as_str().data)
        oi += 1

    var total_line = string.String.create()
    defer: total_line.release()
    total_line.append("Total: ")
    fmt_mod.append_double_precision(ref_of(total_line), total, 1)
    total_line.append("ms")
    stdio.print_format(c"%.*s\n", int<-(total_line.as_str().len), total_line.as_str().data)


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


function lex_command(file_path: str, machine: bool, sexpr: bool) -> int:
    match fs.read_text(file_path):
        Result.failure:
            stdio.print_format(c"error: cannot read '%.*s'\n", int<-(file_path.len), file_path.data)
            return 1
        Result.success as payload:
            var content = payload.value
            defer: content.release()

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

            if sexpr:
                var dumped = sexpr_mod.dump_tokens(tokens.as_span(), source)
                defer: dumped.release()
                stdio.print_format(c"%.*s\n", int<-(dumped.as_str().len), dumped.as_str().data)
                diags.release()
                return 0

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
    defer: expectations.release()
    collect_expect_errors(source, ref_of(expectations))
    return expectations.len() > 0


## Run a compile-fail fixture: type-check the file and verify every
## `# expect-error:` substring appears in some error diagnostic.  Returns
## (1, 0) when the expectations are satisfied and (1, 1) otherwise, so the
## fixture is counted like a test file.
function run_compile_fail_file(file_path: str, source_text: str, roots: ref[vec.Vec[str]], machine: bool, results: ref[vec.Vec[TestResult]]) -> (int, int):
    var expected = vec.Vec[str].create()
    defer: expected.release()
    collect_expect_errors(source_text, ref_of(expected))

    var eff_roots = vec.Vec[str].create()
    defer: eff_roots.release()
    var ri: ptr_uint = 0
    while ri < roots.len():
        let rp = roots.get(ri) else:
            break
        unsafe:
            eff_roots.push(read(rp))
        ri += 1
    eff_roots.push(path_ops.dirname(file_path))

    var program = loader.check_program(file_path, eff_roots.as_span(), resolver.Platform.linux)
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

    var passed = true
    var fail_reason = string.String.create()
    defer: fail_reason.release()
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
## synthesizes a std.testing runner per file, builds and runs it in-process
## under a timeout/memory sandbox.  With --format tap|junit the per-test
## outcomes are parsed and re-emitted in the machine-readable format instead of
## the human summary.
function test_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var test_dir = "."
    var name_filter: Option[str] = Option[str].none
    var timeout_seconds: ptr_uint = 30
    var memory_mb: ptr_uint = 1024
    var sanitize = false
    var format = OutputFormat.human
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--root" or arg == "-I" or arg == "--include-path":
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
        if arg == "--sanitize":
            sanitize = true
            ai += 1
            continue
        test_dir = arg
        ai += 1

    if not fs.is_directory(test_dir):
        stdio.print_format(c"error: not a directory: %.*s\n", int<-(test_dir.len), test_dir.data)
        return 1

    match fs.list_files_recursive(test_dir):
        Result.success as entries_payload:
            var entries = entries_payload.value
            defer: entries.release()
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
                                            timeout_seconds, memory_mb, sanitize, machine, ref_of(results)
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
            defer: err.release()
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


function run_test_file(file_path: str, roots: ref[vec.Vec[str]], counter: ref[ptr_uint], name_filter: Option[str], timeout_seconds: ptr_uint, memory_mb: ptr_uint, sanitize: bool, machine: bool, results: ref[vec.Vec[TestResult]]) -> (int, int):
    match fs.read_text(file_path):
        Result.success as content_payload:
            var source = content_payload.value
            defer: source.release()
            let source_text = source.as_str()

            var diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer: diags.release()
            let file = parser.parse_source(source_text, ref_of(diags))
            if diags.len() > 0:
                return (0, 0)

            var test_names = vec.Vec[str].create()
            defer: test_names.release()
            var death_names = vec.Vec[str].create()
            defer: death_names.release()
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

            if not machine:
                stdio.print_format(c"# %.*s\n", int<-(file_path.len), file_path.data)

            var file_failed = 0
            if test_names.len() > 0:
                if run_normal_test_runner(file_path, source_text, ref_of(test_names), roots, counter, timeout_seconds, memory_mb, sanitize, machine, results) != 0:
                    file_failed = 1

            var dj: ptr_uint = 0
            while dj < death_names.len():
                let dn_ptr = death_names.get(dj) else:
                    break
                if not run_death_test(file_path, source_text, unsafe: read(dn_ptr), roots, counter, timeout_seconds, memory_mb, sanitize, machine, results):
                    file_failed = 1
                dj += 1

            return (int<-(test_names.len() + death_names.len()), file_failed)
        Result.failure:
            return (0, 0)


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
    run_cmd.push(ptr_uint_to_str(timeout_seconds))
    if sanitize:
        # ASan reserves a huge shadow address space, so the `ulimit -v` cap
        # must be skipped for sanitized runs (mirrors Ruby's spawn_sandboxed,
        # which omits :rlimit_as when @test_sanitize is set).
        run_cmd.push(binary_path)
    else:
        ulimit_cmd.append("ulimit -v ")
        ulimit_cmd.append(ptr_uint_to_str(memory_mb * 1024z))
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
## Walks up from the source path to find the project's `src/` directory so
## imports like `mtc.linter.fix_engine` resolve.
function build_runner_file(source_path: str, roots: span[str], output_path: str, sanitize: bool) -> Result[bool, string.String]:
    var runner_roots = vec.Vec[str].create()
    defer: runner_roots.release()
    var ri: ptr_uint = 0
    while ri < roots.len:
        unsafe:
            runner_roots.push(read(roots.data + ri))
        ri += 1

    var package_src_root = find_project_src_root(source_path)
    if package_src_root.is_some():
        runner_roots.push(package_src_root.unwrap())

    var program = loader.check_program(source_path, runner_roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    if program.diagnostic_error_count() > 0:
        print_program_diagnostics(ref_of(program))
        return Result[bool, string.String].failure(error = string.String.from_str(""))

    let ir_program = lowering.lower(program)

    var c_compiler = "cc"
    match build_driver.build(program, ir_program, output_path, c_compiler, runner_roots.as_span(), sanitize, "debug", Option[bool].none):
        Result.success:
            return Result[bool, string.String].success(value = true)
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)


## Walk up from `source_path` looking for the project's `src/mtc/` directory,
## returning the `src/` parent.  Returns none when not found.
function find_project_src_root(source_path: str) -> Option[str]:
    var current = path_ops.dirname(source_path)
    while current != "":
        var src_mtc = path_ops.join(current, "src/mtc")
        let found = fs.is_directory(src_mtc.as_str())
        src_mtc.release()
        if found:
            var src = path_ops.join(current, "src")
            return Option[str].some(value = src.as_str())
        let parent = path_ops.dirname(current)
        if parent == current or parent == "":
            break
        current = parent
    return Option[str].none


## Build one runner binary whose `main(args)` dispatches to a single @[test]
## function selected by `args[1]`, then run it once per test in its own process
## so an aborting assertion is isolated to that test.  Returns 1 when the runner
## fails to build or any test fails.
function run_normal_test_runner(file_path: str, source_text: str, test_names: ref[vec.Vec[str]], roots: ref[vec.Vec[str]], counter: ref[ptr_uint], timeout_seconds: ptr_uint, memory_mb: ptr_uint, sanitize: bool, machine: bool, results: ref[vec.Vec[TestResult]]) -> int:
    var runner_source = string.String.create()
    defer: runner_source.release()
    runner_source.append(source_text)
    runner_source.append("\n\nfunction main(args: span[str]) -> int:\n")
    runner_source.append("    let __mt_test_which = if args.len > 1: args[1] else: \"\"\n")
    runner_source.append("    match __mt_test_which:\n")
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
    runner_source.append("        _:\n            return 1\n")
    runner_source.append("    return 0\n")

    let dirname = path_ops.dirname(file_path)
    let counter_val = read(counter)
    read(counter) = counter_val + 1z
    var runner_num_str = ptr_uint_to_str(counter_val)
    var runner_path_str = string.String.create()
    runner_path_str.append(dirname)
    runner_path_str.append("/__mt_test_runner_")
    runner_path_str.append(runner_num_str)
    runner_path_str.append(".mt")
    defer: runner_path_str.release()

    match fs.write_text(runner_path_str.as_str(), runner_source.as_str()):
        Result.success:
            pass
        Result.failure:
            return 1

    var runner_bin_str = string.String.create()
    runner_bin_str.append(dirname)
    runner_bin_str.append("/__mt_test_runner_")
    runner_bin_str.append(runner_num_str)
    defer: runner_bin_str.release()

    var build_failed = false
    match build_runner_file(runner_path_str.as_str(), roots.as_span(), runner_bin_str.as_str(), sanitize):
        Result.failure as build_err:
            if not machine:
                let be_text = build_err.error.as_str()
                if be_text.len > 0:
                    stdio.print_format(c"%.*s", int<-(be_text.len), be_text.data)
            build_err.error.release()
            build_failed = true
        Result.success:
            pass

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

    var any_failed = false
    var ti2: ptr_uint = 0
    while ti2 < test_names.len():
        let tn_ptr = test_names.get(ti2) else:
            break
        let tn = unsafe: read(tn_ptr)
        match run_sandboxed(runner_bin_str.as_str(), timeout_seconds, memory_mb, sanitize, Option[str].some(value = tn)):
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
                        let err_text = capture_result.stderr_text()
                        match err_text:
                            Option.some as et:
                                if et.value.len > 0:
                                    detail.append(et.value)
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
        return 1
    return 0


## Run a single @[expect_fatal] death test in its own binary.  The synthesized
## main calls the test and returns 0 on either outcome; the test passes only if
## the process aborts (fatal / failed safety check) instead of returning or
## timing out.
function run_death_test(file_path: str, source_text: str, test_name: str, roots: ref[vec.Vec[str]], counter: ref[ptr_uint], timeout_seconds: ptr_uint, memory_mb: ptr_uint, sanitize: bool, machine: bool, results: ref[vec.Vec[TestResult]]) -> bool:
    var runner_source = string.String.create()
    defer: runner_source.release()
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
    defer: runner_path_str.release()

    match fs.write_text(runner_path_str.as_str(), runner_source.as_str()):
        Result.success:
            pass
        Result.failure:
            return false

    var runner_bin_str = string.String.create()
    runner_bin_str.append(dirname)
    runner_bin_str.append("/__mt_test_runner_")
    runner_bin_str.append(runner_num_str)
    defer: runner_bin_str.release()

    var build_ok = false
    match build_runner_file(runner_path_str.as_str(), roots.as_span(), runner_bin_str.as_str(), sanitize):
        Result.success:
            build_ok = true
        Result.failure as build_err:
            build_err.error.release()
            build_ok = false

    var passed = false
    var reason = "expected a fatal abort, but the test returned"
    if not build_ok:
        reason = "build error"
    else:
        match run_sandboxed(runner_bin_str.as_str(), timeout_seconds, memory_mb, sanitize, Option[str].none):
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
