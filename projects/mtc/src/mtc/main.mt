## Self-hosted Milk Tea compiler CLI.
##
## Commands:
##   mtc lex <file>       Print the lexer token stream
##   mtc help             Print help

import std.asset_pack as asset_pack
import std.env as env
import std.fs as fs
import std.fmt as fmt_mod
import std.mem.heap as heap
import std.path as path_ops
import std.str as str
import std.string as string
import std.time as time
import std.vec as vec
import std.stdio as stdio
import std.process as process
import std.libuv as libuv
import std.tar as tar
import std.terminal as terminal

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.lexer.lexer as lexer
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.parser.ast as ast
import mtc.parser.literal_parsing as lparse
import mtc.float_text as float_text
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
import mtc.linter.config as lint_config
import mtc.linter.scope_tracking as scope_tracking
import mtc.linter.fix_engine as fix_engine
import mtc.lsp.server as lsp
import mtc.lsp.debug_info as debug_info
import mtc.lsp.debug_text as debug_text
import mtc.lsp.workspace as workspace
import mtc.lsp.semantic_tokens as sem_tokens
import mtc.dap.server as dap
import mtc.bindgen as bindgen
import mtc.imported_bindings.registry as ib_registry
import mtc.imported_bindings.main as ib_main
import mtc.sexpr as sexpr_mod
import mtc.std_catalog as std_catalog
import mtc.toolchain_cli as toolchain_cli
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
        return parse_command(args)

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


## Expand PATH|DIR operands the way the host's `expand_source_paths` does:
## each directory contributes its sorted `*.mt` files, every path appears once,
## and `paths` holds borrowed views kept alive by `owner` (or by the argv span).
function expand_source_operands(inputs: span[str], paths: ref[vec.Vec[str]], owner: ref[vec.Vec[string.String]]) -> void:
    var ii: ptr_uint = 0
    while ii < inputs.len:
        let input = inputs[ii]
        if fs.is_directory(input):
            match fs.list_files_recursive(input):
                Result.failure:
                    pass
                Result.success as entries_payload:
                    var entries = entries_payload.value
                    defer: entries.release()
                    var dir_files = vec.Vec[str].create()
                    defer: dir_files.release()
                    var ei: ptr_uint = 0
                    while ei < entries.len():
                        let name = entries.get(ei) else:
                            break
                        if name.ends_with(".mt"):
                            dir_files.push(name)
                        ei += 1
                    dir_files.sort_by(proc(left: ptr[str], right: ptr[str]) -> int: str.order(left, right))
                    var di: ptr_uint = 0
                    while di < dir_files.len():
                        let name = dir_files.get(di) else:
                            break
                        owner.push(string.String.from_str(unsafe: read(name)))
                        let stored = owner.get(owner.len() - 1) else:
                            break
                        push_unique_path(paths, unsafe: read(stored).as_str())
                        di += 1
        else:
            push_unique_path(paths, input)
        ii += 1


function push_unique_path(paths: ref[vec.Vec[str]], candidate: str) -> void:
    var i: ptr_uint = 0
    while i < paths.len():
        let existing = paths.get(i) else:
            break
        if unsafe: read(existing).equal(candidate):
            return
        i += 1
    paths.push(candidate)


## The host's `input_paths.length == 1 ? input_paths.first : join(", ")` label.
function operand_label(inputs: span[str]) -> string.String:
    var label = string.String.create()
    if inputs.len == 1:
        label.append(inputs[0])
        return label
    var i: ptr_uint = 0
    while i < inputs.len:
        if i > 0:
            label.append(", ")
        label.append(inputs[i])
        i += 1
    return label


## Print the host's `unexpected argument(s) for <command>: <args>` plus that
## command's usage block.
function reject_unexpected_operands(command: str, args: span[str]) -> int:
    var detail = string.String.create()
    defer: detail.release()
    detail.append("unexpected argument(s) for ")
    detail.append(command)
    detail.append(": ")
    var i: ptr_uint = 1
    while i < args.len:
        if i > 1:
            detail.append(" ")
        detail.append(args[i])
        i += 1
    eprint_line(detail.as_str())
    cli_help.print_command_help(command, true)
    return 1


## `mtc parse PATH|DIR [PATH|DIR ...] [--sexpr] [-I PATH]`.
function parse_command(args: span[str]) -> int:
    var sexpr = false
    var inputs = vec.Vec[str].create()
    defer: inputs.release()
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var platform = resolver.Platform.linux
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--sexpr":
            sexpr = true
            ai += 1
            continue
        if arg == "--":
            ai += 1
            while ai < args.len:
                inputs.push(args[ai])
                ai += 1
            continue
        if arg == "-I" or arg == "--include-path" or arg == "--root":
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
        if arg.starts_with("-"):
            return reject_unexpected_operands("parse", args)
        inputs.push(arg)
        ai += 1

    if inputs.len() == 0:
        eprint_line("missing source file path")
        cli_help.print_usage(true)
        return 1

    var paths = vec.Vec[str].create()
    defer: paths.release()
    var expanded_owner = vec.Vec[string.String].create()
    defer: expanded_owner.release()
    expand_source_operands(inputs.as_span(), ref_of(paths), ref_of(expanded_owner))
    if paths.len() == 0:
        var label = operand_label(inputs.as_span())
        defer: label.release()
        var msg = string.String.create()
        defer: msg.release()
        msg.append("no .mt files found in ")
        msg.append(label.as_str())
        stdio.print_line(msg.as_str())
        return 0

    let multiple = paths.len() > 1
    var pi: ptr_uint = 0
    while pi < paths.len():
        let path_ptr = paths.get(pi) else:
            break
        let path = unsafe: read(path_ptr)
        if multiple and not sexpr:
            stdio.print_format(c"# --- %.*s ---\n", int<-(path.len), path.data)
        let rc = parse_one_path(path, sexpr)
        if rc != 0:
            return rc
        if multiple and pi + 1 < paths.len():
            stdio.print_line("")
        pi += 1
    return 0


function parse_one_path(file_path: str, sexpr: bool) -> int:
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
            # The host's parse command lexes first; a lexer error aborts before
            # parsing (`Lexer.lex` raises, the CLI renders `error[lex/error]`).
            var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
            defer: lex_diags.release()
            let _lexed = lexer.lex_reporting(source, ref_of(lex_diags))
            if lex_diags.len() > 0:
                print_lex_diagnostics(resolved.as_str(), source, lex_diags.as_span())
                return 1
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
        if arg == "-I" or arg == "--include-path":
            if i + 1 >= args.len:
                stdio.print_line("error: -I requires a directory")
                return 1
            roots.push(args[i + 1])
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
        if arg == "--":
            i += 1
            while i < args.len:
                input_paths.push(args[i])
                i += 1
            continue
        if arg.starts_with("-"):
            return reject_unexpected_operands("check", args)
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
            let printed_errors = print_program_diagnostics(ref_of(program))
            file_count += 1
            total_errors += printed_errors
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
function print_program_diagnostics(program: ref[loader.Program]) -> ptr_uint:
    var printed_errors: ptr_uint = 0
    var seen_error_paths = vec.Vec[str].create()
    defer: seen_error_paths.clear()
    var i: ptr_uint = 0
    while i < program.diagnostics.len():
        let d = program.diagnostics.get(i) else:
            break
        unsafe:
            let rd = read(d)
            let message = rd.message.as_str()
            let location = rd.path.as_str()
            let prefix = if rd.severity == "warning": "warning" else: "error"
            # The host aborts a file at its first semantic error, so later
            # diagnostics for the same path cannot exist there.
            if rd.severity != "warning":
                var already_seen = false
                var spi: ptr_uint = 0
                while spi < seen_error_paths.len():
                    let sp = seen_error_paths.get(spi) else:
                        break
                    if unsafe: read(sp) == location:
                        already_seen = true
                        break
                    spi += 1
                if already_seen:
                    i += 1
                    continue
                seen_error_paths.push(location)
                printed_errors += 1
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
    return printed_errors


## Print a lexer error in the host CLI's `error[lex/error]` block form.
function print_lex_diagnostics(path: str, source: str, diags: span[token_mod.LexDiagnostic]) -> void:
    var i: ptr_uint = 0
    while i < diags.len:
        let d = unsafe: read(diags.data + i)
        print_diagnostic_block(path, source, d.line, d.column, "lex/error", str.cstr_as_str(d.message))
        i += 1
    let _ = terminal.flush_stderr()


## Print a parse error in the host CLI's `error[parse/error]` block form.
function print_parse_diagnostics(path: str, source: str, diags: span[pstate.ParseDiagnostic]) -> void:
    var i: ptr_uint = 0
    while i < diags.len:
        let d = unsafe: read(diags.data + i)
        print_diagnostic_block(path, source, d.line, d.column, "parse/error", str.cstr_as_str(d.message))
        i += 1
    let _ = terminal.flush_stderr()


## `error[<code>]: <message> -- <path>:<line>:<col>` plus the source line and
## caret, the host ErrorFormatter's block.
function print_diagnostic_block(path: str, source: str, line: ptr_uint, column: ptr_uint, code: str, message: str) -> void:
    var block = string.String.create()
    defer: block.release()
    block.append("error[")
    block.append(code)
    block.append("]: ")
    block.append(message)
    block.append(" -- ")
    block.append(path)
    block.append(":")
    block.append(ptr_uint_to_str(line))
    block.append(":")
    block.append(ptr_uint_to_str(column))
    block.append("\n")
    if line >= 1:
        var current_line: ptr_uint = 1
        var pos: ptr_uint = 0
        while pos < source.len and current_line < line:
            if source.byte_at(pos) == 10:
                current_line += 1
            pos += 1
        let line_start = pos
        while pos < source.len and source.byte_at(pos) != 10:
            pos += 1
        let line_end = pos
        if line_start <= line_end:
            let source_line = source.slice(line_start, line_end - line_start)
            var gutter = rjust_line_number(line)
            defer: gutter.release()
            block.append("   |\n")
            block.append(gutter.as_str())
            block.append(" | ")
            block.append(source_line)
            block.append("\n")
            block.append("      | ")
            var sp: ptr_uint = 1
            while sp < column:
                block.push_byte(32)
                sp += 1
            block.push_byte(94)
            block.append("\n")
    let _ = terminal.write_stderr(block.as_str())


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
## `lint --init`: write the host's default `.mt-lint.yml` in the current
## directory (the same 43-code select list and 120-column limit).
function init_lint_config() -> int:
    match fs.current_directory():
        Result.failure:
            eprint_line("cannot determine the current directory")
            return 1
        Result.success as cwd_payload:
            var cwd = cwd_payload.value
            defer: cwd.release()
            var path = path_ops.join(cwd.as_str(), lint_config.CONFIG_FILE_NAME)
            defer: path.release()
            if fs.exists(path.as_str()):
                var exists_msg = string.String.create()
                defer: exists_msg.release()
                exists_msg.append("lint config already exists at ")
                exists_msg.append(path.as_str())
                eprint_line(exists_msg.as_str())
                return 1

            var content = string.String.create()
            defer: content.release()
            content.append("# Default Milk Tea lint configuration.\n")
            content.append("# Remove entries from `select` to disable rules globally.\n")
            content.append("max_line_length: 120\n")
            content.append("select:\n")
            var codes = linter.known_rule_codes()
            defer: codes.release()
            var ci: ptr_uint = 0
            while ci < codes.len():
                let cp = codes.get(ci) else:
                    break
                content.append("  - ")
                content.append(unsafe: read(cp))
                content.push_byte(10)
                ci += 1
            content.append("ignore: []\n")

            match fs.write_text(path.as_str(), content.as_str()):
                Result.success:
                    if not cli_quiet:
                        var created = string.String.create()
                        defer: created.release()
                        created.append("created ")
                        created.append(path.as_str())
                        stdio.print_line(created.as_str())
                    return 0
                Result.failure as write_error:
                    var write_failure = write_error.error
                    defer: write_failure.release()
                    var msg = string.String.create()
                    defer: msg.release()
                    msg.append("error: cannot write ")
                    msg.append(path.as_str())
                    eprint_line(msg.as_str())
                    return 1


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
    var init_mode = false
    var locked_flag = false
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var platform = resolver.Platform.linux
    var i: ptr_uint = 1
    while i < args.len:
        let arg = args[i]
        if arg == "-I" or arg == "--include-path":
            if i + 1 < args.len:
                roots.push(args[i + 1])
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
            locked_flag = true
            i += 1
            continue
        if arg == "--init":
            init_mode = true
            i += 1
            continue
        if arg == "--select":
            i += 1
            if i >= args.len:
                eprint_line("--select requires a comma-separated list of rule codes")
                return 1
            collect_filter_codes(args[i], ref_of(select_set))
            i += 1
            continue
        if arg == "--ignore":
            i += 1
            if i >= args.len:
                eprint_line("--ignore requires a comma-separated list of rule codes")
                return 1
            collect_filter_codes(args[i], ref_of(ignore_set))
            i += 1
            continue
        if arg.starts_with("-"):
            var unknown = string.String.create()
            defer: unknown.release()
            unknown.append("unknown lint flag: ")
            unknown.append(arg)
            eprint_line(unknown.as_str())
            return 1
        input_paths.push(arg)
        i += 1

    if init_mode:
        if input_paths.len() > 0 or select_set.len() > 0 or ignore_set.len() > 0 or fix_mode or locked_flag:
            eprint_line("--init does not accept source paths or lint options")
            return 1
        return init_lint_config()

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
            # `run`/`build` with no operand in a package root default to that
            # package (the host's package-root discovery).
            if fs.is_file("package.toml"):
                add_module_roots(".", roots, owned_roots)
                return Option[str].some(value = ".")
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
        eprint_line("root main is not a valid executable entrypoint; expected `function main() -> int|void`, `function main(argc: int, argv: ptr[cstr]) -> int|void`, `function main(argc: int, argv: ptr[ptr[char]]) -> int|void`, or `function main(args: span[str]) -> int|void`")
    else:
        eprint_line("no executable entrypoint found; define `main` with one of the supported executable signatures")
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
    if fs.is_directory(path):
        var manifest = path_ops.join(path, "package.toml")
        defer: manifest.release()
        if not fs.is_file(manifest.as_str()):
            return lower_directory(path, ref_of(roots), ref_of(owned_roots), platform, sexpr)
    return lower_one_path(path, ref_of(roots), ref_of(owned_roots), platform, sexpr)


## Expand a directory operand to its `.mt` files (sorted) and lower each one,
## printing the host's `# --- <path> ---` header when there is more than one.
function lower_directory(dir: str, roots: ref[vec.Vec[str]], owned: ref[vec.Vec[string.String]], platform: resolver.Platform, sexpr: bool) -> int:
    match fs.list_files_recursive(dir):
        Result.failure as failure:
            var err = failure.error
            defer: err.release()
            var msg = string.String.create()
            defer: msg.release()
            msg.append("cannot read ")
            msg.append(dir)
            eprint_line(msg.as_str())
            return 1
        Result.success as entries_payload:
            var entries = entries_payload.value
            defer: entries.release()
            var files = vec.Vec[str].create()
            defer: files.release()
            var ei: ptr_uint = 0
            while ei < entries.len():
                let name = entries.get(ei) else:
                    break
                if name.ends_with(".mt"):
                    files.push(name)
                ei += 1
            if files.len() == 0:
                stdio.print_format(c"no .mt files found in %.*s\n", int<-(dir.len), dir.data)
                return 0
            files.sort_by(proc(left: ptr[str], right: ptr[str]) -> int: str.order(left, right))
            let multiple = files.len() > 1
            var fi: ptr_uint = 0
            while fi < files.len():
                let file_ptr = files.get(fi) else:
                    break
                let file = unsafe: read(file_ptr)
                if multiple and not sexpr:
                    stdio.print_format(c"# --- %.*s ---\n", int<-(file.len), file.data)
                let rc = lower_one_path(file, roots, owned, platform, sexpr)
                if rc != 0:
                    return rc
                fi += 1
            return 0
    return 0


## Lower one source file and print the rendered IR (or its `--sexpr` dump).
function lower_one_path(path: str, roots: ref[vec.Vec[str]], owned: ref[vec.Vec[string.String]], platform: resolver.Platform, sexpr: bool) -> int:
    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, roots, ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1
    if not fs.exists(effective):
        var missing = string.String.create()
        defer: missing.release()
        missing.append("source file not found: ")
        missing.append(path)
        eprint_line(missing.as_str())
        entry_path_owner.release()
        source_root_owner.release()
        return 1
    add_module_roots(effective, roots, owned)

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer: program.release()

    if program.diagnostic_error_count() > 0:
        let _ = print_program_diagnostics(ref_of(program))
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    if reject_external_root(program):
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    let ir_program = lowering.lower(program)
    if sexpr:
        var dumped = sexpr_mod.dump_ir_with_analyses(ir_program, program.analyses.as_span())
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


## Resolve one `emit-c` operand the way the host's `resolve_program_path` does:
## a directory becomes its package's build entry (or the host's error); a file
## is used as given.  The resolved path is copied into `out_owner`, its borrowed
## view is pushed onto `out_paths`, and any package source root is registered.
function resolve_emit_c_operand(
    raw: str,
    roots: ref[vec.Vec[str]],
    owned_roots: ref[vec.Vec[string.String]],
    out_paths: ref[vec.Vec[str]],
    out_owner: ref[vec.Vec[string.String]],
) -> bool:
    if not fs.is_directory(raw):
        add_module_roots(raw, roots, owned_roots)
        out_owner.push(string.String.from_str(raw))
        let stored = out_owner.get(out_owner.len() - 1) else:
            return false
        out_paths.push(unsafe: read(stored).as_str())
        return true

    var manifest_path = path_ops.join(raw, "package.toml")
    defer: manifest_path.release()
    if not fs.is_file(manifest_path.as_str()):
        var msg = string.String.create()
        defer: msg.release()
        msg.append("no package.toml found in ")
        msg.append(raw)
        eprint_line(msg.as_str())
        return false

    match fs.read_text(manifest_path.as_str()):
        Result.failure:
            var msg = string.String.create()
            defer: msg.release()
            msg.append("failed to load package manifest for ")
            msg.append(raw)
            eprint_line(msg.as_str())
            return false
        Result.success as payload:
            var text = payload.value
            defer: text.release()

            let entry_val = read_toml_str(text.as_str(), "build", "entry")
            let entry = entry_val else:
                var msg = string.String.create()
                defer: msg.release()
                msg.append("no build entry found for ")
                msg.append(raw)
                eprint_line(msg.as_str())
                return false

            var source_root = string.String.from_str("src")
            match read_toml_str(text.as_str(), "package", "source_root"):
                Option.some as sr:
                    source_root.release()
                    source_root = sr.value
                Option.none:
                    pass

            var root_path = path_ops.join(raw, source_root.as_str())
            owned_roots.push(root_path)
            let root_stored = owned_roots.get(owned_roots.len() - 1) else:
                source_root.release()
                return false
            roots.push(unsafe: read(root_stored).as_str())

            var entry_path = path_ops.join(raw, entry.as_str())
            if not fs.is_file(entry_path.as_str()):
                var msg = string.String.create()
                defer: msg.release()
                msg.append("no build entry found for ")
                msg.append(raw)
                eprint_line(msg.as_str())
                source_root.release()
                entry_path.release()
                return false

            add_module_roots(entry_path.as_str(), roots, owned_roots)
            out_owner.push(entry_path)
            let stored = out_owner.get(out_owner.len() - 1) else:
                source_root.release()
                return false
            out_paths.push(unsafe: read(stored).as_str())
            source_root.release()
            return true


## Compile one checked program to C and print it.
function emit_c_one_path(path: str, roots: ref[vec.Vec[str]], owned_roots: ref[vec.Vec[string.String]], platform: resolver.Platform) -> int:
    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, roots, ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        entry_path_owner.release()
        source_root_owner.release()
        return 1
    if not fs.exists(effective):
        var missing = string.String.create()
        defer: missing.release()
        missing.append("source file not found: ")
        missing.append(path)
        eprint_line(missing.as_str())
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer: program.release()

    if program.diagnostic_error_count() > 0:
        let _ = print_program_diagnostics(ref_of(program))
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    if reject_external_root(program):
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    let ir_program = lowering.lower(program)
    var c_source = c_backend.generate_c(ir_program, false, false, false)
    defer: c_source.release()
    let text = c_source.as_str()
    stdio.print_format(c"%.*s", int<-(text.len), text.data)
    entry_path_owner.release()
    source_root_owner.release()
    return 0


## `mtc emit-c PATH|DIR [PATH|DIR ...] [-I PATH]`.
function emit_c_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var inputs = vec.Vec[str].create()
    defer: inputs.release()
    var platform = resolver.Platform.linux
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--":
            ai += 1
            while ai < args.len:
                inputs.push(args[ai])
                ai += 1
            continue
        if arg == "-I" or arg == "--include-path" or arg == "--root":
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
        if arg == "--locked" or arg == "--frozen":
            ai += 1
            continue
        if arg.starts_with("-"):
            return reject_unexpected_operands("emit-c", args)
        inputs.push(arg)
        ai += 1

    if inputs.len() == 0:
        eprint_line("missing source file path")
        cli_help.print_usage(true)
        return 1

    var program_paths = vec.Vec[str].create()
    defer: program_paths.release()
    var resolved_owner = vec.Vec[string.String].create()
    defer: resolved_owner.release()
    var ii: ptr_uint = 0
    while ii < inputs.len():
        let raw_ptr = inputs.get(ii) else:
            break
        let raw = unsafe: read(raw_ptr)
        if not resolve_emit_c_operand(raw, ref_of(roots), ref_of(owned_roots), ref_of(program_paths), ref_of(resolved_owner)):
            return 1
        ii += 1

    let multiple = program_paths.len() > 1
    var pi: ptr_uint = 0
    while pi < program_paths.len():
        let path_ptr = program_paths.get(pi) else:
            break
        let path = unsafe: read(path_ptr)
        if multiple:
            stdio.print_format(c"/* --- %.*s --- */\n", int<-(path.len), path.data)
        let rc = emit_c_one_path(path, ref_of(roots), ref_of(owned_roots), platform)
        if rc != 0:
            return rc
        if multiple and pi + 1 < program_paths.len():
            stdio.print_line("")
        pi += 1
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
        # The host only treats a directory as a package when its manifest
        # declares an entry; otherwise the operand is a directory where a file
        # was expected.
        var dir_msg = string.String.create()
        defer: dir_msg.release()
        var abs_dir = loader.absolute_path(dir)
        defer: abs_dir.release()
        dir_msg.append("expected a source file, got a directory: ")
        dir_msg.append(abs_dir.as_str())
        eprint_line(dir_msg.as_str())
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
            let declared_entry = entry_val else:
                # No `[build] entry`: the host falls back to the operand being a
                # plain source path, so a directory operand is rejected.
                var no_entry_msg = string.String.create()
                defer: no_entry_msg.release()
                var abs_dir = loader.absolute_path(dir)
                defer: abs_dir.release()
                no_entry_msg.append("expected a source file, got a directory: ")
                no_entry_msg.append(abs_dir.as_str())
                eprint_line(no_entry_msg.as_str())
                return Option[str].none
            read(entry_owner) = declared_entry

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
    if not fs.is_file(entry_path.as_str()):
        var missing_msg = string.String.create()
        defer: missing_msg.release()
        missing_msg.append("build.entry not found: ")
        missing_msg.append(entry_owner.as_str())
        var resolved_path = loader.absolute_path(entry_path.as_str())
        defer: resolved_path.release()
        missing_msg.append(" (resolved to ")
        missing_msg.append(resolved_path.as_str())
        missing_msg.append(")")
        eprint_line(missing_msg.as_str())
        entry_path.release()
        return Option[str].none
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
    var has_cli_profile = false
    var platform = resolver.Platform.linux
    var has_cli_platform = false
    var clean_mode = false
    var use_cache = true
    var sanitize = false
    var debug_guards: Option[bool] = Option[bool].none
    var kind = build_driver.BuildKind.executable
    var bundle_mode = false
    var archive_mode = false
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
        if arg == "--bundle":
            bundle_mode = true
            ai += 1
            continue
        if arg == "--archive":
            bundle_mode = true
            archive_mode = true
            ai += 1
            continue
        if arg == "--kind":
            if ai + 1 >= args.len:
                eprint_line("missing value for --kind")
                cli_help.print_usage(true)
                return 1
            let kind_name = args[ai + 1]
            if kind_name == "executable" or kind_name == "exe" or kind_name == "bin":
                kind = build_driver.BuildKind.executable
                ai += 2
                continue
            if kind_name == "static" or kind_name == "staticlib":
                kind = build_driver.BuildKind.kind_static
                ai += 2
                continue
            if kind_name == "shared" or kind_name == "dylib" or kind_name == "dll" or kind_name == "so":
                kind = build_driver.BuildKind.kind_shared
                ai += 2
                continue
            var bad_kind = string.String.create()
            defer: bad_kind.release()
            bad_kind.append("unknown build kind ")
            bad_kind.append(kind_name)
            bad_kind.append("; expected executable|static|shared")
            eprint_line(bad_kind.as_str())
            cli_help.print_usage(true)
            return 1
        if arg == "--keep-c":
            if ai + 1 >= args.len:
                stdio.print_line("error: --keep-c requires a path")
                return 1
            keep_c_path = Option[str].some(value= args[ai + 1])
            ai += 2
            continue
        if arg == "--cc":
            if ai + 1 >= args.len:
                eprint_line("missing value for --cc")
                cli_help.print_usage(true)
                return 1
            c_compiler = args[ai + 1]
            ai += 2
            continue
        if arg == "--no-cache":
            use_cache = false
            ai += 1
            continue
        if arg == "-I" or arg == "--root" or arg == "--include-path":
            filtered.push(arg)
            if ai + 1 < args.len:
                filtered.push(args[ai + 1])
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
        if arg == "--profile":
            if ai + 1 >= args.len:
                stdio.print_line("error: --profile requires a profile name (debug or release)")
                return 1
            profile_name = args[ai + 1]
            if not profile_name == "debug" and not profile_name == "release":
                stdio.print_line("error: --profile must be debug or release")
                return 1
            has_cli_profile = true
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
            has_cli_platform = true
            ai += 2
            continue
        if arg.starts_with("-"):
            var unknown_opt = string.String.create()
            defer: unknown_opt.release()
            unknown_opt.append("unknown build option ")
            unknown_opt.append(arg)
            eprint_line(unknown_opt.as_str())
            cli_help.print_usage(true)
            return 1
        filtered.push(arg)
        ai += 1
    let path = parse_source_operand(filtered.as_span(), ref_of(roots), ref_of(owned_roots), ref_of(platform)) else:
        return 1

    var entry_path_owner = string.String.create()
    defer: entry_path_owner.release()
    var source_root_owner = string.String.create()
    defer: source_root_owner.release()

    # Package manifest discovery: a directory operand uses its own manifest; a
    # source-file operand is a package build only when the manifest's entry is
    # that file (the host's `use_package_build_for?`).
    var package_opt = Option[package_manifest.PackageBuild].none
    var package_abs = loader.absolute_path(path)
    defer: package_abs.release()
    match package_manifest.load_package_for(package_abs.as_str()):
        Result.success as loaded:
            package_opt = loaded.value
        Result.failure as manifest_failure:
            let message = manifest_failure.error.as_str()
            eprint_line(message)
            manifest_failure.error.release()
            return 1
    defer: release_package_option(ref_of(package_opt))

    var output_owner = string.String.create()
    defer: output_owner.release()
    var bundle_root = string.String.create()
    defer: bundle_root.release()
    var clean_target = string.String.create()
    defer: clean_target.release()
    var clean_target_is_tree = false
    var effective: str = ""
    let display_path = path
    var is_package = false

    match package_opt:
        Option.some as package_ref:
            let pkg = package_ref.value
            is_package = true
            if pkg.kind == package_manifest.PackageKind.library and kind == build_driver.BuildKind.executable:
                var message = string.String.create()
                defer: message.release()
                message.append("cannot build library package ")
                message.append(pkg.name.as_str())
                message.append(" as an executable")
                eprint_line(message.as_str())
                return 1
            match pkg.source_path:
                Option.some as declared_source:
                    effective = declared_source.value.as_str()
                Option.none:
                    var message = string.String.create()
                    defer: message.release()
                    message.append("application package ")
                    message.append(pkg.name.as_str())
                    message.append(" has no build entry; set build.entry or create src/main.mt")
                    eprint_line(message.as_str())
                    return 1
            roots.push(pkg.source_root.as_str())
            if not has_cli_profile:
                profile_name = pkg.profile
            if not has_cli_platform:
                platform = platform_from_manifest(pkg.platform)
            let extension = if platform == resolver.Platform.windows: ".exe" else: ""
            if bundle_mode:
                if platform == resolver.Platform.wasm:
                    eprint_line("bundle mode is supported only for native package builds")
                    return 1
                match output_override:
                    Option.some as explicit_root:
                        bundle_root.append(explicit_root.value)
                    Option.none:
                        match pkg.output_path:
                            Option.some as manifest_output:
                                bundle_root.append(manifest_output.value.as_str())
                            Option.none:
                                var computed = path_ops.join(pkg.root_dir.as_str(), "build/dist")
                                defer: computed.release()
                                var with_platform = path_ops.join(computed.as_str(), platform_label(platform))
                                defer: with_platform.release()
                                var with_profile = path_ops.join(with_platform.as_str(), profile_name)
                                defer: with_profile.release()
                                var with_name = path_ops.join(with_profile.as_str(), pkg.name.as_str())
                                defer: with_name.release()
                                bundle_root.append(with_name.as_str())
                output_owner.append(bundle_root.as_str())
                output_owner.push_byte('/')
                output_owner.append(pkg.name.as_str())
                output_owner.append(extension)
                match output_override:
                    Option.some:
                        clean_target.append(bundle_root.as_str())
                        clean_target_is_tree = true
                    Option.none:
                        match pkg.output_path:
                            Option.some:
                                clean_target.append(bundle_root.as_str())
                                clean_target_is_tree = true
                            Option.none:
                                clean_target.append(pkg.root_dir.as_str())
                                clean_target.append("/build/dist")
                                clean_target_is_tree = true
            else:
                match output_override:
                    Option.some as explicit_output:
                        output_owner.append(explicit_output.value)
                        clean_target.append(explicit_output.value)
                    Option.none:
                        match pkg.output_path:
                            Option.some as manifest_output:
                                output_owner.append(manifest_output.value.as_str())
                                clean_target.append(manifest_output.value.as_str())
                            Option.none:
                                var computed = path_ops.join(pkg.root_dir.as_str(), "build/bin")
                                defer: computed.release()
                                var with_platform = path_ops.join(computed.as_str(), platform_label(platform))
                                defer: with_platform.release()
                                var with_profile = path_ops.join(with_platform.as_str(), profile_name)
                                defer: with_profile.release()
                                var with_name = path_ops.join(with_profile.as_str(), pkg.name.as_str())
                                defer: with_name.release()
                                output_owner.append(with_name.as_str())
                                output_owner.append(extension)
                                clean_target.append(pkg.root_dir.as_str())
                                clean_target.append("/build")
                                clean_target_is_tree = true
        Option.none:
            if bundle_mode:
                eprint_line("bundle mode requires a package build")
                return 1
            let fallback = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
                return 1
            effective = fallback
            match output_override:
                Option.some as explicit_output:
                    output_owner.append(explicit_output.value)
                    clean_target.append(explicit_output.value)
                Option.none:
                    var computed = default_output_path(effective)
                    defer: computed.release()
                    output_owner.append(computed.as_str())
                    clean_target.append(computed.as_str())

    if not fs.exists(effective):
        var missing = string.String.create()
        defer: missing.release()
        missing.append("source file not found: ")
        missing.append(display_path)
        eprint_line(missing.as_str())
        return 1

    # --clean removes the generated output artifact without compiling.
    if clean_mode:
        if clean_target_is_tree:
            if fs.exists(clean_target.as_str()):
                match fs.remove_tree(clean_target.as_str()):
                    Result.failure as failure:
                        var message = failure.error
                        defer: message.release()
                        stdio.print_format(c"error: cannot remove %.*s\n", int<-(clean_target.as_str().len), clean_target.as_str().data)
                        return 1
                    Result.success:
                        pass
        else if fs.exists(clean_target.as_str()):
            match fs.remove(clean_target.as_str()):
                Result.failure as failure:
                    var message = failure.error
                    defer: message.release()
                    stdio.print_format(c"error: cannot remove %.*s\n", int<-(clean_target.as_str().len), clean_target.as_str().data)
                    return 1
                Result.success:
                    pass
        if not cli_quiet:
            stdio.print_format(c"cleaned %.*s\n", int<-(clean_target.as_str().len), clean_target.as_str().data)
        return 0

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer: program.release()

    if program.diagnostic_error_count() > 0:
        let _ = print_program_diagnostics(ref_of(program))
        return 1

    if reject_external_root(program):
        return 1

    let ir_program = lowering.lower(program)

    if kind == build_driver.BuildKind.executable and reject_missing_entrypoint(program, ir_program):
        return 1

    if keep_c_path.is_some():
        keep_c_to_file(ir_program, keep_c_path.unwrap())

    let output_dir = path_ops.dirname(output_owner.as_str())
    match fs.create_directories(output_dir):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            var message = string.String.create()
            defer: message.release()
            message.append("error: cannot create output directory ")
            message.append(output_dir)
            message.append(": ")
            message.append(dir_error.message.as_str())
            dir_error.release()
            eprint_line(message.as_str())
            return 1
        Result.success:
            pass

    # Binary cache: an unchanged program (same mtc executable, C compiler,
    # configuration, and module sources) reuses the previously built binary.
    # --keep-c always rebuilds so the saved C matches the produced binary.
    # Libraries are not cached (the cache materializes executables and its key
    # does not encode the artifact kind).  Asset staging and the bundle archive
    # are re-run on a hit, as the host's `build_cached` does.
    let cache_enabled = use_cache and keep_c_path.is_none() and kind == build_driver.BuildKind.executable
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
                let copied = build_cache.materialize(cached.as_str(), output_owner.as_str())
                cached.release()
                if copied:
                    match stage_package_assets(package_opt, output_owner.as_str(), bundle_mode):
                        Result.success:
                            pass
                        Result.failure as asset_failure:
                            var asset_error = asset_failure.error
                            var message = string.String.create()
                            defer: message.release()
                            message.append("error: ")
                            message.append(asset_error.as_str())
                            asset_error.release()
                            eprint_line(message.as_str())
                            return 1
                    var cached_archive = string.String.create()
                    defer: cached_archive.release()
                    if archive_mode:
                        match write_bundle_archive(bundle_root.as_str(), ref_of(cached_archive)):
                            Result.success:
                                pass
                            Result.failure as archive_failure:
                                var archive_error = archive_failure.error
                                var message = string.String.create()
                                defer: message.release()
                                message.append("error: ")
                                message.append(archive_error.as_str())
                                archive_error.release()
                                eprint_line(message.as_str())
                                return 1
                    if not cli_quiet:
                        if bundle_mode:
                            stdio.print_format(
                                c"built %.*s -> %.*s\n",
                                int<-(display_path.len), display_path.data,
                                int<-(output_dir.len), output_dir.data,
                            )
                            stdio.print_format(
                                c"entry executable %.*s\n",
                                int<-(output_owner.as_str().len), output_owner.as_str().data,
                            )
                            stdio.print_line("  [cached]")
                            if archive_mode:
                                stdio.print_format(
                                    c"archive %.*s\n",
                                    int<-(cached_archive.as_str().len), cached_archive.as_str().data,
                                )
                        else:
                            stdio.print_format(
                                c"built %.*s -> %.*s  [cached]\n",
                                int<-(display_path.len), display_path.data,
                                int<-(output_owner.as_str().len), output_owner.as_str().data,
                            )
                    return 0
            Option.none:
                pass

    match build_driver.build(program, ir_program, output_owner.as_str(), c_compiler, roots.as_span(), sanitize, profile_name, debug_guards, kind):
        Result.success as built:
            var output = built.value
            defer: output.release()
            if cache_enabled:
                build_cache.store(cache_key.as_str(), output.as_str())
            match stage_package_assets(package_opt, output_owner.as_str(), bundle_mode):
                Result.success:
                    pass
                Result.failure as asset_failure:
                    var asset_error = asset_failure.error
                    var message = string.String.create()
                    defer: message.release()
                    message.append("error: ")
                    message.append(asset_error.as_str())
                    asset_error.release()
                    eprint_line(message.as_str())
                    return 1
            var archive_owner = string.String.create()
            defer: archive_owner.release()
            if archive_mode:
                match write_bundle_archive(bundle_root.as_str(), ref_of(archive_owner)):
                    Result.success:
                        pass
                    Result.failure as archive_failure:
                        var archive_error = archive_failure.error
                        var message = string.String.create()
                        defer: message.release()
                        message.append("error: ")
                        message.append(archive_error.as_str())
                        archive_error.release()
                        eprint_line(message.as_str())
                        return 1
            if not cli_quiet:
                if bundle_mode:
                    stdio.print_format(
                        c"built %.*s -> %.*s\n",
                        int<-(display_path.len), display_path.data,
                        int<-(output_dir.len), output_dir.data,
                    )
                    stdio.print_format(
                        c"entry executable %.*s\n",
                        int<-(output_owner.as_str().len), output_owner.as_str().data,
                    )
                    if archive_mode:
                        stdio.print_format(
                            c"archive %.*s\n",
                            int<-(archive_owner.as_str().len), archive_owner.as_str().data,
                        )
                else:
                    stdio.print_format(
                        c"built %.*s -> %.*s\n",
                        int<-(display_path.len), display_path.data,
                        int<-(output_owner.as_str().len), output_owner.as_str().data,
                    )
            return 0
        Result.failure as failure:
            var message = failure.error
            defer: message.release()
            let text = message.as_str()
            stdio.print_format(c"error: %.*s\n", int<-(text.len), text.data)
            return 1


## Release the optional package manifest (its owned strings) at scope exit.
function release_package_option(option: ref[Option[package_manifest.PackageBuild]]) -> void:
    match read(option):
        Option.some as package:
            package.value.release()
        Option.none:
            pass


function platform_from_manifest(label: str) -> resolver.Platform:
    if label == "windows":
        return resolver.Platform.windows
    if label == "wasm":
        return resolver.Platform.wasm
    return resolver.Platform.linux


function path_is_within(path: str, root: str) -> bool:
    if path.equal(root):
        return true
    if path.len <= root.len:
        return false
    if not path.slice(0, root.len).equal(root):
        return false
    return path.byte_at(root.len) == '/'


## Stage a package's `build.assets` beside the executable: packed into
## `assets.mtpack` in bundle mode, copied as-is otherwise (the host's
## `stage_runtime_assets`).
function stage_package_assets(option: Option[package_manifest.PackageBuild], output_path: str, bundle_mode: bool) -> Result[bool, string.String]:
    match option:
        Option.none:
            return Result[bool, string.String].success(value = true)
        Option.some as package_ref:
            let package = package_ref.value
            if package.assets.len() == 0:
                return Result[bool, string.String].success(value = true)
            let output_dir = path_ops.dirname(output_path)
            if bundle_mode:
                var pack_path = path_ops.join(output_dir, "assets.mtpack")
                defer: pack_path.release()
                return asset_pack.write(pack_path.as_str(), package.assets.as_span())

            var i: ptr_uint = 0
            while i < package.assets.len():
                let asset_ptr = package.assets.get(i) else:
                    break
                let asset = unsafe: read(asset_ptr).as_str()
                var staged = path_ops.join(output_dir, path_ops.basename(asset))
                if staged.as_str().equal(asset):
                    staged.release()
                    i += 1
                    continue
                if fs.is_directory(asset) and path_is_within(staged.as_str(), asset):
                    var message = string.String.from_str("native runtime asset output would be written inside build.assets source tree: ")
                    message.append(staged.as_str())
                    staged.release()
                    return Result[bool, string.String].failure(error = message)
                if fs.exists(staged.as_str()):
                    match fs.remove_tree(staged.as_str()):
                        Result.failure as remove_failure:
                            var remove_error = remove_failure.error
                            var message = string.String.from_str(remove_error.message.as_str())
                            remove_error.release()
                            staged.release()
                            return Result[bool, string.String].failure(error = message)
                        Result.success:
                            pass
                match fs.copy_entry(asset, staged.as_str()):
                    Result.failure as copy_failure:
                        var copy_error = copy_failure.error
                        var message = string.String.from_str(copy_error.message.as_str())
                        copy_error.release()
                        staged.release()
                        return Result[bool, string.String].failure(error = message)
                    Result.success:
                        pass
                staged.release()
                i += 1
            return Result[bool, string.String].success(value = true)


## Write `<bundle_root>.tar.gz` (the host's `write_bundle_archive`).
function write_bundle_archive(bundle_root: str, archive_owner: ref[string.String]) -> Result[bool, string.String]:
    read(archive_owner).append(bundle_root)
    read(archive_owner).append(".tar.gz")
    match tar.archive_directory_gzip(bundle_root, path_ops.basename(bundle_root), true):
        Result.success as archive_payload:
            var data = archive_payload.value
            defer: data.release()
            match fs.write_bytes(read(archive_owner).as_str(), data.as_span()):
                Result.failure as write_failure:
                    var write_error = write_failure.error
                    var message = string.String.from_str("could not write archive: ")
                    message.append(write_error.message.as_str())
                    write_error.release()
                    return Result[bool, string.String].failure(error = message)
                Result.success:
                    return Result[bool, string.String].success(value = true)
        Result.failure as archive_failure:
            var archive_error = archive_failure.error
            var message = string.String.from_str(archive_error.message.as_str())
            archive_error.release()
            return Result[bool, string.String].failure(error = message)


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
                eprint_line("missing value for --cc")
                cli_help.print_usage(true)
                return 1
            c_compiler = args[ai + 1]
            ai += 2
            continue
        if arg == "--no-cache":
            use_cache = false
            ai += 1
            continue
        if arg == "-I" or arg == "--root" or arg == "--include-path":
            filtered.push(arg)
            if ai + 1 < args.len:
                filtered.push(args[ai + 1])
            ai += 2
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
        if arg.starts_with("-"):
            var unknown_opt = string.String.create()
            defer: unknown_opt.release()
            unknown_opt.append("unknown build option ")
            unknown_opt.append(arg)
            eprint_line(unknown_opt.as_str())
            cli_help.print_usage(true)
            return 1
        filtered.push(arg)
        ai += 1
    let path = parse_source_operand(filtered.as_span(), ref_of(roots), ref_of(owned_roots), ref_of(platform)) else:
        return 1
    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1
    if not fs.exists(effective):
        var missing = string.String.create()
        defer: missing.release()
        missing.append("source file not found: ")
        missing.append(path)
        eprint_line(missing.as_str())
        return 1

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer: program.release()

    if program.diagnostic_error_count() > 0:
        let _ = print_program_diagnostics(ref_of(program))
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
                    let run_status = execute_binary(cached_output.as_str(), ref_of(program_args))
                    if not cli_quiet:
                        stdio.print_line("[cached]")
                    return run_status
            Option.none:
                pass

    match build_driver.build(program, ir_program, output_path.as_str(), c_compiler, roots.as_span(), sanitize, profile_name, debug_guards, build_driver.BuildKind.executable):
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
        eprint_line("missing project name")
        cli_help.print_usage(true)
        return 1
    if args.len > 2:
        let extra = args[2]
        var extra_msg = string.String.create()
        defer: extra_msg.release()
        extra_msg.append("unknown new option ")
        extra_msg.append(extra)
        eprint_line(extra_msg.as_str())
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
        var not_dir_msg = string.String.create()
        defer: not_dir_msg.release()
        not_dir_msg.append("project path is not a directory: ")
        not_dir_msg.append(abs_path)
        eprint_line(not_dir_msg.as_str())
        return 1
    if fs.is_directory(abs_path):
        match fs.list_entries(abs_path):
            Result.success as entries_payload:
                var entries = entries_payload.value
                let count = entries.len()
                entries.release()
                if count > 0:
                    var exists_msg = string.String.create()
                    defer: exists_msg.release()
                    exists_msg.append("project directory already exists and is not empty: ")
                    exists_msg.append(abs_path)
                    eprint_line(exists_msg.as_str())
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
        eprint_line("completions: shell must be bash, zsh, or fish")
        let _ = cli_help.print_command_help("completions", true)
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
    eprint_line("completions: shell must be bash, zsh, or fish")
    let _ = cli_help.print_command_help("completions", true)
    return 1


## `format_size` (Ruby's `%.1f` over the 1024-based unit).
function print_human_size(bytes: ptr_uint) -> void:
    if bytes == 0:
        stdio.print_line("0 B")
        return
    var exp: ptr_uint = 0
    var divisor: double = 1.0
    while exp < 3 and double<-bytes >= divisor * 1024.0:
        divisor = divisor * 1024.0
        exp += 1
    let value = double<-bytes / divisor
    let unit = if exp == 0: c"B" else: if exp == 1: c"KiB" else: if exp == 2: c"MiB" else: c"GiB"
    stdio.print_format(c"%.1f %s", value, unit)


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
        var root = build_cache.cache_root_path()
        let root_text = root.as_str()
        if not fs.is_directory(root_text):
            stdio.print_line("cache is already empty")
            root.release()
            return 0
        match build_cache.purge():
            Result.failure as failure:
                var msg = string.String.from_str("cache purge failed: ")
                msg.append(failure.error.as_str())
                let msg_text = msg.as_str()
                stdio.print_format(c"%.*s\n", int<-(msg_text.len), msg_text.data)
                msg.release()
                root.release()
                return 1
            Result.success:
                stdio.print_format(c"purged %.*s\n", int<-(root_text.len), root_text.data)
                root.release()
                return 0
    if sub == "status":
        var root = build_cache.cache_root_path()
        let root_text = root.as_str()
        if not fs.is_directory(root_text):
            stdio.print_format(c"cache directory does not exist: %.*s\n", int<-(root_text.len), root_text.data)
            root.release()
            return 0
        var st = build_cache.status()
        stdio.print_format(c"cache  %zu programs, %zu binaries  (", st.programs, st.binaries)
        print_human_size(st.total_bytes)
        stdio.print_format(c")\n  root  %.*s\n", int<-(root_text.len), root_text.data)
        root.release()
        return 0
    var unknown_msg = string.String.create()
    defer: unknown_msg.release()
    unknown_msg.append("unknown cache subcommand ")
    unknown_msg.append(sub)
    eprint_line(unknown_msg.as_str())
    let _ = cli_help.print_command_help("cache", true)
    return 1


## Generate a binding module from a C header.
## Usage: mtc bindgen MODULE HEADER [-o OUTPUT] [--link LIB] [--include HEADER] [--clang PATH]
function bindgen_command(args: span[str]) -> int:
    var module_name: Option[str] = Option[str].none
    var header: Option[str] = Option[str].none
    var output: Option[str] = Option[str].none
    var nullable_report: Option[str] = Option[str].none
    var nullable_policy: Option[str] = Option[str].none
    var link_libs = vec.Vec[str].create()
    var includes = vec.Vec[str].create()
    var clang_args = vec.Vec[str].create()
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
        else if arg == "--clang-arg":
            ai += 1
            if ai >= args.len:
                eprint_line("missing value for --clang-arg")
                let _ = cli_help.print_command_help("bindgen", true)
                return 1
            clang_args.push(args[ai])
        else if arg == "--nullable-report":
            ai += 1
            if ai >= args.len:
                eprint_line("missing value for --nullable-report")
                let _ = cli_help.print_command_help("bindgen", true)
                return 1
            nullable_report = Option[str].some(value = args[ai])
        else if arg == "--nullable-policy":
            ai += 1
            if ai >= args.len:
                eprint_line("missing value for --nullable-policy")
                let _ = cli_help.print_command_help("bindgen", true)
                return 1
            nullable_policy = Option[str].some(value = args[ai])
        else if arg == "--help" or arg == "-h":
            stdio.print_line("usage: mtc bindgen MODULE HEADER [-o OUTPUT] [--link LIB] [--include HEADER] [--clang PATH] [--clang-arg ARG] [--nullable-policy PATH] [--nullable-report PATH]")
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

    var policy: bindgen.NullablePolicy
    match nullable_policy:
        Option.some as policy_path:
            match bindgen.load_nullable_policy(policy_path.value):
                Result.success as loaded:
                    policy = loaded.value
                Result.failure as load_failure:
                    let message = load_failure.error.as_str()
                    eprint_line(message)
                    load_failure.error.release()
                    link_libs.release()
                    includes.release()
                    clang_args.release()
                    return 1
        Option.none:
            policy = bindgen.NullablePolicy(
                return_overrides = vec.Vec[bindgen.TypeOverride].create(),
                param_overrides = vec.Vec[bindgen.ParamOverride].create(),
            )
    defer: policy.release()

    var header_abs = loader.absolute_path(header_path)
    defer: header_abs.release()

    var opts = bindgen.BindgenOptions(
        module_name = string.String.from_str(mod_name),
        header_path = string.String.from_str(header_abs.as_str()),
        output_path = output,
        link_libs = link_libs,
        include_headers = includes,
        clang_bin = clang_str,
        clang_args = clang_args,
        return_overrides = policy.return_overrides,
        param_overrides = policy.param_overrides,
        report_header_path = header_abs.as_str(),
    )
    defer: opts.module_name.release()
    defer: opts.header_path.release()

    if nullable_report.is_some():
        let report_arg = nullable_report.unwrap()
        var report_path = loader.absolute_path(report_arg)
        defer: report_path.release()
        match bindgen.generate_with_report(ref_of(opts)):
            Result.success as generated:
                var generated_output = generated.value
                defer: generated_output.source.release()
                defer: generated_output.report.release()
                if not write_nullable_report(report_path.as_str(), generated_output.report.as_str()):
                    return 1
                match output:
                    Option.some as out_file:
                        match fs.write_text(out_file.value, generated_output.source.as_str()):
                            Result.success:
                                stdio.print_format(c"generated %.*s -> %.*s\n",
                                    int<-(header_path.len), header_path.data,
                                    int<-(out_file.value.len), out_file.value.data)
                                stdio.print_format(c"nullable report %.*s -> %.*s\n",
                                    int<-(header_path.len), header_path.data,
                                    int<-(report_path.as_str().len), report_path.as_str().data)
                            Result.failure:
                                stdio.print_line("bindgen: could not write output file")
                                return 1
                    Option.none:
                        let st = generated_output.source.as_str()
                        stdio.print_format(c"%.*s", int<-(st.len), st.data)
                        var wrote = string.String.create()
                        defer: wrote.release()
                        wrote.append("wrote nullable report ")
                        wrote.append(report_path.as_str())
                        eprint_line(wrote.as_str())
                return 0
            Result.failure as failure:
                let mt = failure.error.as_str()
                eprint_line(mt)
                failure.error.release()
                return 1

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
            eprint_line(mt)
            failure.error.release()
            return 1


## Write the nullable-policy report, creating its parent directory.  Reports a
## write failure on stderr (the host raises through the CLI error formatter).
function write_nullable_report(path: str, report: str) -> bool:
    let parent = path_ops.dirname(path)
    match fs.create_directories(parent):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            eprint_line(dir_error.message.as_str())
            dir_error.release()
            return false
        Result.success:
            pass
    match fs.write_text(path, report):
        Result.failure as write_failure:
            var write_error = write_failure.error
            eprint_line(write_error.message.as_str())
            write_error.release()
            return false
        Result.success:
            return true


const IB_MODE_WRITE: int = 0
const IB_MODE_CHECK: int = 1
const IB_MODE_STDOUT: int = 2

const IB_OK: int = 0
const IB_FAILED: int = 1
const IB_CHANGED: int = 2
const IB_NEW: int = 3


## Outcome of generating one imported binding.  `first_diff_*` are meaningful
## only for a check-mode status of `IB_CHANGED`.
struct IbOutcome:
    status: int
    first_diff_offset: ptr_uint
    first_diff_line: ptr_uint


## Regenerate imported binding modules from raw C bindings and JSON policies.
function imported_bindings_command(args: span[str]) -> int:
    var do_all = false
    var do_check = false
    var do_soft = false
    var do_stdout = false
    var json_path: str = ""
    var lib_name: str = ""

    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--all":
            do_all = true
        else if arg == "--check":
            do_check = true
        else if arg == "--soft":
            do_soft = true
        else if arg == "--stdout":
            do_stdout = true
        else if arg == "--json":
            if ai + 1 >= args.len:
                stdio.print_line("imported-bindings: missing value for --json")
                return 1
            ai += 1
            json_path = args[ai]
        else if arg == "--help" or arg == "-h":
            stdio.print_line("usage: mtc imported-bindings <name>|--all [--check|--stdout] [--json PATH] [--soft]")
            return 0
        else if lib_name.len == 0:
            lib_name = arg
        else:
            stdio.print_format(c"imported-bindings: unexpected argument '%.*s'\n", int<-(arg.len), arg.data)
            return 1
        ai += 1

    if do_soft and not do_check:
        stdio.print_line("imported-bindings: --soft requires --check")
        return 1
    if do_stdout and do_all:
        stdio.print_line("imported-bindings: --stdout requires a single library name")
        return 1
    if do_stdout and do_check:
        stdio.print_line("imported-bindings: --stdout and --check are mutually exclusive")
        return 1

    var mode = IB_MODE_WRITE
    if do_check:
        mode = IB_MODE_CHECK
    else if do_stdout:
        mode = IB_MODE_STDOUT

    var total: ptr_uint = 0
    var verified: ptr_uint = 0
    var changed: ptr_uint = 0
    var created: ptr_uint = 0
    var failed: ptr_uint = 0
    var json_entries = string.String.create()
    var json_first = true

    if do_all:
        var i: ptr_uint = 0
        while i < ib_registry.ALL_COUNT:
            let entry_ptr = get(ib_registry.ALL, i) else:
                break
            let entry = unsafe: read(entry_ptr)
            let outcome = regenerate_one(entry.policy_path, entry.binding_path, entry.raw_module_name, mode)
            total += 1
            if outcome.status == IB_OK:
                verified += 1
            else if outcome.status == IB_CHANGED:
                changed += 1
            else if outcome.status == IB_NEW:
                created += 1
            else:
                failed += 1
            if json_path.len > 0:
                append_ib_json_entry(ref_of(json_entries), ref_of(json_first),
                    entry.name, entry.binding_path, outcome, mode)
            i += 1
    else:
        if lib_name.len == 0:
            stdio.print_line("imported-bindings: missing library name or --all")
            json_entries.release()
            return 1

        let entry = find_ib_entry(lib_name) else:
            stdio.print_format(c"imported-bindings: unknown library '%.*s'\n", int<-(lib_name.len), lib_name.data)
            json_entries.release()
            return 1

        let outcome = regenerate_one(entry.policy_path, entry.binding_path, entry.raw_module_name, mode)
        total = 1
        if outcome.status == IB_OK:
            verified = 1
        else if outcome.status == IB_CHANGED:
            changed = 1
        else if outcome.status == IB_NEW:
            created = 1
        else:
            failed = 1
        if json_path.len > 0:
            append_ib_json_entry(ref_of(json_entries), ref_of(json_first),
                entry.name, entry.binding_path, outcome, mode)

    if json_path.len > 0:
        var json = string.String.create()
        json.append("{\"bindings\":[")
        json.append(json_entries.as_str())
        json.append("],\"summary\":{\"total\":")
        json.append(ptr_uint_to_str(total))
        json.append(",\"verified\":")
        json.append(ptr_uint_to_str(verified))
        json.append(",\"changed\":")
        json.append(ptr_uint_to_str(changed))
        json.append(",\"new\":")
        json.append(ptr_uint_to_str(created))
        json.append(",\"failed\":")
        json.append(ptr_uint_to_str(failed))
        json.append("}}\n")
        match fs.write_text(json_path, json.as_str()):
            Result.failure as write_failure:
                var write_error = write_failure.error
                stdio.print_format(c"imported-bindings: could not write %.*s\n", int<-(json_path.len), json_path.data)
                write_error.release()
                json.release()
                json_entries.release()
                return 1
            Result.success:
                pass
        json.release()
    json_entries.release()

    if do_all:
        if mode == IB_MODE_CHECK:
            stdio.print_format(c"verified %d / changed %d / new %d of %d\n",
                int<-verified, int<-changed, int<-created, int<-total)
        else:
            stdio.print_format(c"generated %d imported bindings\n", int<-total)
    if failed > 0:
        stdio.print_format(c"%d binding(s) failed\n", int<-failed)
        return 1
    if mode == IB_MODE_CHECK and (changed + created) > 0 and not do_soft:
        return 1
    return 0


function append_ib_json_entry(
    buf: ref[string.String],
    first: ref[bool],
    name: str,
    path: str,
    outcome: IbOutcome,
    mode: int,
) -> void:
    if not read(first):
        buf.push_byte(',')
    read(first) = false
    buf.append("{\"name\":")
    append_json_string(buf, name)
    buf.append(",\"path\":")
    append_json_string(buf, path)
    buf.append(",\"status\":")
    append_json_string(buf, ib_status_label(outcome.status, mode))
    buf.append(",\"first_diff_offset\":")
    buf.append(ptr_uint_to_str(outcome.first_diff_offset))
    buf.append(",\"first_diff_line\":")
    buf.append(ptr_uint_to_str(outcome.first_diff_line))
    buf.push_byte('}')


function ib_status_label(status: int, mode: int) -> str:
    if status == IB_CHANGED:
        return "changed"
    if status == IB_NEW:
        return "new"
    if status == IB_FAILED:
        return "failed"
    if mode == IB_MODE_CHECK:
        return "verified"
    return "generated"


function first_diff_offset(new_src: str, old_src: str) -> ptr_uint:
    var limit = new_src.len
    if old_src.len < limit:
        limit = old_src.len
    var i: ptr_uint = 0
    while i < limit:
        if new_src.byte_at(i) != old_src.byte_at(i):
            return i
        i += 1
    return limit


function line_at_offset(text: str, offset: ptr_uint) -> ptr_uint:
    var line: ptr_uint = 1
    var i: ptr_uint = 0
    while i < offset and i < text.len:
        if text.byte_at(i) == 10:
            line += 1
        i += 1
    return line


function find_ib_entry(name: str) -> Option[ib_registry.BindingEntry]:
    var i: ptr_uint = 0
    while i < ib_registry.ALL_COUNT:
        let entry_ptr = get(ib_registry.ALL, i) else:
            break
        let entry = unsafe: read(entry_ptr)
        if entry.name.equal(name):
            return Option[ib_registry.BindingEntry].some(value = entry)
        i += 1
    return Option[ib_registry.BindingEntry].none


function regenerate_one(policy_path: str, output_path: str, raw_module_name: str, mode: int) -> IbOutcome:
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
            if mode == IB_MODE_STDOUT:
                var message = string.String.create()
                message.append("imported-bindings: ")
                message.append(p.error.as_str())
                eprint_line(message.as_str())
                message.release()
            else:
                stdio.print_format(c"imported-bindings: %.*s\n", int<-(p.error.as_str().len), p.error.as_str().data)
            p.error.release()
            raw_buf.release()
            return IbOutcome(status = IB_FAILED, first_diff_offset = 0, first_diff_line = 0)
        Result.success as p:
            if mode == IB_MODE_STDOUT:
                stdio.print_format(c"%.*s", int<-(p.value.as_str().len), p.value.as_str().data)
                p.value.release()
                raw_buf.release()
                return IbOutcome(status = IB_OK, first_diff_offset = 0, first_diff_line = 0)

            if mode == IB_MODE_CHECK:
                var status = IB_OK
                var diff_offset: ptr_uint = 0
                var diff_line: ptr_uint = 0
                match fs.read_text(output_path):
                    Result.failure:
                        stdio.print_format(c"(new) %.*s would be generated\n", int<-(output_path.len), output_path.data)
                        status = IB_NEW
                    Result.success as existing:
                        let new_src = p.value.as_str()
                        let old_src = existing.value.as_str()
                        if new_src.equal(old_src):
                            stdio.print_format(c"verified %.*s\n", int<-(output_path.len), output_path.data)
                        else:
                            diff_offset = first_diff_offset(new_src, old_src)
                            diff_line = line_at_offset(new_src, diff_offset)
                            stdio.print_format(c"changed %.*s\n", int<-(output_path.len), output_path.data)
                            status = IB_CHANGED
                        existing.value.release()
                p.value.release()
                raw_buf.release()
                return IbOutcome(status = status, first_diff_offset = diff_offset, first_diff_line = diff_line)

            match fs.write_text(output_path, p.value.as_str()):
                Result.failure:
                    stdio.print_format(c"imported-bindings: could not write %.*s\n", int<-(output_path.len), output_path.data)
                    p.value.release()
                    raw_buf.release()
                    return IbOutcome(status = IB_FAILED, first_diff_offset = 0, first_diff_line = 0)
                Result.success:
                    stdio.print_format(c"generated %.*s + %.*s -> %.*s\n",
                        int<-(raw_module_name.len), raw_module_name.data,
                        int<-(policy_path.len), policy_path.data,
                        int<-(output_path.len), output_path.data)
            p.value.release()
            raw_buf.release()
            return IbOutcome(status = IB_OK, first_diff_offset = 0, first_diff_line = 0)
function toolchain_command(args: span[str]) -> int:
    return toolchain_cli.run(args)


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
    var unknown_sub = string.String.create()
    defer: unknown_sub.release()
    unknown_sub.append("unknown std subcommand ")
    unknown_sub.append(sub)
    eprint_line(unknown_sub.as_str())
    let _ = cli_help.print_command_help("std", true)
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


function std_module_not_found(name: str) -> void:
    var msg = string.String.create()
    defer: msg.release()
    msg.append("std module not found: ")
    msg.append(name)
    eprint_line(msg.as_str())


function std_show_command(name: str) -> int:
    if name.len == 0 or name.contains_substring(".."):
        std_module_not_found(name)
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
    std_module_not_found(name)
    return 1


function print_std_source(path: str, name: str) -> int:
    match fs.read_text(path):
        Result.success as payload:
            var content = payload.value
            defer: content.release()
            stdio.print_format(c"%.*s", int<-(content.as_str().len), content.as_str().data)
            return 0
        Result.failure:
            std_module_not_found(name)
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
        eprint_line("snapshot: missing source file path")
        cli_help.print_usage(true)
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
    defer: entry_path_owner.release()
    defer: source_root_owner.release()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1
    if not fs.exists(effective):
        var missing = string.String.create()
        defer: missing.release()
        missing.append("source file not found: ")
        missing.append(path)
        eprint_line(missing.as_str())
        return 1

    var display_path = loader.absolute_path(effective)
    defer: display_path.release()

    var ws = workspace.Workspace.create(effective)
    defer: ws.release()
    var ri: ptr_uint = roots.len()
    while ri > 0:
        ri -= 1
        let rp = roots.get(ri) else:
            break
        ws.module_roots.insert(0, string.String.from_str(unsafe: read(rp)))

    var text = debug_info.build_cli_debug_text(ref_of(ws), effective, display_path.as_str())
    defer: text.release()
    stdio.print_line(text.as_str())
    return 0


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


## Format one source file and apply the single-file output rules.
function format_one_path(
    path: str,
    check_mode: bool,
    write_mode: bool,
    timings: bool,
    mode: tidy.FormatMode,
    explicit_max_line_length: ptr_uint,
) -> int:
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
            stdio.print_format(c"error: cannot read %.*s\n", int<-(path.len), path.data)
            return 1


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
                        stdio.print_format(c"error: %.*s: parse error\n", int<-(path.len), path.data)
                        return 1
                    defer: formatted.release()
                    if source.as_str() != formatted.as_str():
                        stdio.print_format(c"needs formatting %.*s\n", int<-(path.len), path.data)
                        needs.push(string.String.from_str(path))
                Result.failure as err:
                    var msg = err.error
                    defer: msg.release()
                    stdio.print_format(c"error: cannot read %.*s\n", int<-(path.len), path.data)
                    return 1
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
                    stdio.print_format(c"error: %.*s: parse error\n", int<-(path.len), path.data)
                    return 1
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
                stdio.print_format(c"error: cannot read %.*s\n", int<-(path.len), path.data)
                return 1
        pi += 1
    stdio.print_format(c"formatted %d of %d file(s)\n", int<-(changed), int<-(paths.len()))
    return 0


## `mtc format PATH|DIR [PATH|DIR ...] [--check|--write] [--safe|--canonical|
## --preserve|--tidy] [--max-line-length N] [--timings]`.
function format_command(args: span[str]) -> int:
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
                eprint_line("missing value for --max-line-length")
                cli_help.print_usage(true)
                return 1
            let parsed = parse_positive_int(args[ai + 1]) else:
                eprint_line("--max-line-length must be a positive integer")
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
            eprint_line(unknown.as_str())
            cli_help.print_usage(true)
            return 1
        inputs.push(arg)
        ai += 1

    if check_mode and write_mode:
        eprint_line("format options --check and --write cannot be combined")
        cli_help.print_usage(true)
        return 1

    if inputs.len() == 0:
        eprint_line("missing source file path")
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

    var paths = vec.Vec[str].create()
    defer: paths.release()
    var expanded_owner = vec.Vec[string.String].create()
    defer: expanded_owner.release()
    expand_source_operands(inputs.as_span(), ref_of(paths), ref_of(expanded_owner))
    if paths.len() == 0:
        var label = operand_label(inputs.as_span())
        defer: label.release()
        var msg = string.String.create()
        defer: msg.release()
        msg.append("no .mt files found in ")
        msg.append(label.as_str())
        stdio.print_line(msg.as_str())
        return 0

    let multiple_sources = inputs.len() > 1 or has_directory
    if multiple_sources:
        if not check_mode and not write_mode:
            eprint_line("format on multiple sources requires --check or --write")
            cli_help.print_usage(true)
            return 1
        return format_paths_command(ref_of(paths), check_mode, write_mode, mode, explicit_max_line_length)

    let path_ptr = paths.get(0) else:
        return 0
    let path = unsafe: read(path_ptr)
    return format_one_path(path, check_mode, write_mode, timings, mode, explicit_max_line_length)


## The default output path for a source build: the source path with its `.mt`
## extension removed (matching the Ruby CLI's direct-source-build behaviour).
function default_output_path(path: str) -> string.String:
    if path.ends_with(".mt"):
        return string.String.from_str(path.slice(0, path.len - 3))
    return j2_path(path, ".out")


function keep_c_to_file(ir_program: ir.Program, output_path_str: str) -> void:
    var c_source = c_backend.generate_c(ir_program, false, false, false)
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


## Ruby `String#inspect` for a lexeme (the host's token dump prints
## `lexeme="..."` with escaped control characters).
function append_ruby_inspect(buf: ref[string.String], text: str) -> void:
    buf.push_byte(34)
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == 34:
            buf.append("\\\"")
        else if b == 92:
            buf.append("\\\\")
        else if b == 10:
            buf.append("\\n")
        else if b == 9:
            buf.append("\\t")
        else if b == 13:
            buf.append("\\r")
        else if b == 27:
            buf.append("\\e")
        else if b < 32 or b == 127:
            buf.append("\\x")
            let hi = b >> 4
            let lo = b & 15
            buf.push_byte(if hi < 10: ubyte<-(48 + hi) else: ubyte<-(55 + hi))
            buf.push_byte(if lo < 10: ubyte<-(48 + lo) else: ubyte<-(55 + lo))
        else:
            buf.push_byte(b)
        i += 1
    buf.push_byte(34)


## The host's `Token#literal` rendering for the pretty-printed token dump.
## Integers and floats carry the parsed value; every other token is `nil`.
function append_lex_token_literal(buf: ref[string.String], kind: tk.TokenKind, lexeme: str) -> void:
    if kind == tk.TokenKind.integer:
        fmt_mod.append_ulong(buf, lex_integer_value(lexeme))
    else if kind == tk.TokenKind.float_literal:
        let value = lparse.parse_float_literal(lexeme)
        buf.append(float_text.double_to_str(value))
    else:
        buf.append("nil")


## The numeric value of an integer token, following the host lexer's scan:
## prefixed bases consume their own digit alphabet, then a type suffix is
## ignored (`0x1Fu` -> 31, `0xab` -> 171).
function lex_integer_value(lexeme: str) -> ulong:
    var i: ptr_uint = 0
    var base: ulong = 10
    if lexeme.len >= 2 and lexeme.byte_at(0) == 48 and (lexeme.byte_at(1) == 120 or lexeme.byte_at(1) == 88):
        base = 16
        i = 2
    else if lexeme.len >= 2 and lexeme.byte_at(0) == 48 and (lexeme.byte_at(1) == 98 or lexeme.byte_at(1) == 66):
        base = 2
        i = 2
    var value: ulong = 0
    while i < lexeme.len:
        let b = lexeme.byte_at(i)
        var digit: ulong = 0
        var valid = true
        if b >= 48 and b <= 57:
            digit = ulong<-(b - 48)
        else if b >= 97 and b <= 102:
            digit = ulong<-(b - 87)
        else if b >= 65 and b <= 70:
            digit = ulong<-(b - 55)
        else if b == 95:
            i += 1
            continue
        else:
            valid = false
        if not valid or digit >= base:
            break
        value = value * base + digit
        i += 1
    return value


function lex_command(file_path: str, machine: bool, sexpr: bool) -> int:
    if not fs.exists(file_path):
        var missing = string.String.create()
        defer: missing.release()
        missing.append("source file not found: ")
        missing.append(file_path)
        eprint_line(missing.as_str())
        return 1
    if fs.is_directory(file_path):
        var dir_msg = string.String.create()
        defer: dir_msg.release()
        dir_msg.append("expected a source file, got a directory: ")
        dir_msg.append(file_path)
        eprint_line(dir_msg.as_str())
        return 1
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
                print_lex_diagnostics(file_path, source, diags.as_span())
                diags.release()
                return 1

            if sexpr:
                var dumped = sexpr_mod.dump_tokens(tokens.as_span(), source)
                defer: dumped.release()
                stdio.print_format(c"%.*s\n", int<-(dumped.as_str().len), dumped.as_str().data)
                diags.release()
                return 0

            if machine:
                stdio.print_format(c"── Tokens  %d  ──\n", int<-(tokens.len()))
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
                # The host prints `PP.pp(tokens)` — Ruby's pretty-printed array
                # of `MilkTea::Token` Data objects, one field per line.
                var k: ptr_uint = 0
                while k < tokens.len():
                    let tok = tokens.get(k) else:
                        break
                    unsafe:
                        let t = read(tok)
                        let lexeme = token_mod.token_lexeme(t, source)
                        var line = string.String.create()
                        defer: line.release()
                        if k == 0:
                            line.append("[#<data MilkTea::Token")
                        else:
                            line.append(" #<data MilkTea::Token")
                        stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
                        line.clear()
                        line.append("  type=:")
                        line.append(token_mod.kind_name(t.kind))
                        line.append(",")
                        stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
                        line.clear()
                        line.append("  lexeme=")
                        append_ruby_inspect(ref_of(line), lexeme)
                        line.append(",")
                        stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
                        line.clear()
                        line.append("  literal=")
                        append_lex_token_literal(ref_of(line), t.kind, lexeme)
                        line.append(",")
                        stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
                        line.clear()
                        line.append("  line=")
                        fmt_mod.append_ptr_uint(ref_of(line), t.line)
                        line.append(",")
                        stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
                        line.clear()
                        line.append("  column=")
                        fmt_mod.append_ptr_uint(ref_of(line), t.column)
                        line.append(",")
                        stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
                        line.clear()
                        line.append("  start_offset=")
                        fmt_mod.append_ptr_uint(ref_of(line), t.start_offset)
                        line.append(",")
                        stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
                        line.clear()
                        line.append("  end_offset=")
                        fmt_mod.append_ptr_uint(ref_of(line), t.end_offset)
                        line.append(",")
                        stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
                        line.clear()
                        line.append("  leading_trivia=[]")
                        line.append(",")
                        stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
                        line.clear()
                        line.append("  trailing_trivia=[]")
                        line.append(">")
                        if k + 1 == tokens.len():
                            line.append("]")
                        else:
                            line.append(",")
                        stdio.print_format(c"%.*s\n", int<-(line.as_str().len), line.as_str().data)
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
## `# expect-error:` substring appears in some error diagnostic.  Returns 0 when
## the expectations are satisfied and 1 otherwise; `header` prints the
## directory-mode `# <file>` line.
function run_compile_fail_file(file_path: str, source_text: str, options: TestRunOptions, header: bool, results: ref[vec.Vec[TestResult]]) -> int:
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

    var program = loader.check_program(file_path, eff_roots.as_span(), options.platform)
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
                fail_reason.assign("no diagnostic matched ")
                var inspected = debug_text.ruby_inspect(exp)
                fail_reason.append(inspected.as_str())
                inspected.release()
                break
            ei += 1

    let machine = options.format != OutputFormat.human
    if machine:
        var name = string.String.from_str(file_path)
        name.append(" (compile-fail)")
        if passed:
            results.push(TestResult(name = name, status = TestStatus.ok, detail = string.String.create(), has_detail = false))
        else:
            results.push(TestResult(name = name, status = TestStatus.fail, detail = string.String.from_str(fail_reason.as_str()), has_detail = true))
    else:
        if header:
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
        return 0
    return 1


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


## How a discovered test file runs (`TestFileKind.lex_error` aborts the run:
## the host's discovery rescues parse errors but lets a LexError escape).
enum TestFileKind: ubyte
    none = 0
    test = 1
    compile_fail = 2
    lex_error = 3


## Discover and run @[test] functions from a file or directory.  Scans all .mt
## files, synthesizes a runner per file, builds and runs it in-process under a
## timeout/memory sandbox.  With --format tap|junit the per-test outcomes are
## re-emitted in the machine-readable format instead of the human summary.
## `--jobs` is validated and accepted; files still run in order — the host's
## fork-per-file mode only changes wall time (and folds a child's stderr into
## its stdout), so the sequential run is the equivalent without that wart.
function test_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var positional = vec.Vec[str].create()
    defer: positional.release()
    var name_filter: Option[str] = Option[str].none
    var timeout_seconds: ptr_uint = 30
    var memory_mb: ptr_uint = 1024
    var jobs: ptr_uint = 1
    var sanitize = false
    var format = OutputFormat.human
    var cc = "cc"
    var profile = "debug"
    var platform = resolver.Platform.linux
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--root" or arg == "-I" or arg == "--include-path":
            if ai + 1 >= args.len:
                eprint_line("missing value for -I")
                ai += 1
                continue
            roots.push(args[ai + 1])
            ai += 2
            continue
        if arg == "-n" or arg == "--name":
            if ai + 1 >= args.len:
                eprint_line("-n requires a name substring")
                return 1
            name_filter = Option[str].some(value= args[ai + 1])
            ai += 2
            continue
        if arg == "--timeout":
            if ai + 1 >= args.len:
                eprint_line("--timeout requires a positive integer (seconds)")
                return 1
            let seconds = parse_positive_int(args[ai + 1]) else:
                eprint_line("--timeout requires a positive integer (seconds)")
                return 1
            timeout_seconds = seconds
            ai += 2
            continue
        if arg == "--mem":
            if ai + 1 >= args.len:
                eprint_line("--mem requires a positive integer (megabytes)")
                return 1
            let megabytes = parse_positive_int(args[ai + 1]) else:
                eprint_line("--mem requires a positive integer (megabytes)")
                return 1
            memory_mb = megabytes
            ai += 2
            continue
        if arg == "--jobs":
            if ai + 1 >= args.len:
                eprint_line("--jobs requires a positive integer")
                return 1
            let count = parse_positive_int(args[ai + 1]) else:
                eprint_line("--jobs requires a positive integer")
                return 1
            jobs = count
            ai += 2
            continue
        if arg == "--format":
            if ai + 1 >= args.len:
                eprint_line("--format must be human, tap, or junit")
                return 1
            let fmt_name = args[ai + 1]
            if fmt_name == "human":
                format = OutputFormat.human
            else if fmt_name == "tap":
                format = OutputFormat.tap
            else if fmt_name == "junit":
                format = OutputFormat.junit
            else:
                eprint_line("--format must be human, tap, or junit")
                return 1
            ai += 2
            continue
        if arg == "--sanitize":
            sanitize = true
            ai += 1
            continue
        if arg == "--":
            var rest = ai + 1
            while rest < args.len:
                positional.push(args[rest])
                rest += 1
            break
        if arg == "-o" or arg == "--output" or arg == "--keep-c" or arg == "--cc" or arg == "--profile" or arg == "--platform":
            if ai + 1 >= args.len:
                eprint_missing_option_value(arg)
                return 1
            let value = args[ai + 1]
            if arg == "--cc":
                cc = value
            else if arg == "--profile":
                if not value == "debug" and not value == "release":
                    var bad_profile = string.String.create()
                    defer: bad_profile.release()
                    bad_profile.append("unknown profile ")
                    bad_profile.append(value)
                    bad_profile.append("; expected debug|release")
                    eprint_line(bad_profile.as_str())
                    return 1
                profile = value
            else if arg == "--platform":
                if value == "linux":
                    platform = resolver.Platform.linux
                else if value == "windows":
                    platform = resolver.Platform.windows
                else if value == "wasm":
                    platform = resolver.Platform.wasm
                else:
                    var bad_platform = string.String.create()
                    defer: bad_platform.release()
                    bad_platform.append("unknown platform ")
                    bad_platform.append(value)
                    bad_platform.append("; expected linux|windows|wasm")
                    eprint_line(bad_platform.as_str())
                    return 1
            ai += 2
            continue
        if arg == "--kind":
            if ai + 1 >= args.len:
                eprint_missing_option_value(arg)
                return 1
            let kind_name = args[ai + 1]
            if not is_known_build_kind(kind_name):
                var bad_kind = string.String.create()
                defer: bad_kind.release()
                bad_kind.append("unknown build kind ")
                bad_kind.append(kind_name)
                bad_kind.append("; expected executable|static|shared")
                eprint_line(bad_kind.as_str())
                cli_help.print_usage(true)
                return 1
            ai += 2
            continue
        if arg == "--bundle" or arg == "--archive" or arg == "--locked" or arg == "--frozen" or arg == "--no-cache" or arg == "--timings" or arg == "--debug-guards" or arg == "--no-debug-guards":
            ai += 1
            continue
        if arg.starts_with("-"):
            var unknown_opt = string.String.create()
            defer: unknown_opt.release()
            unknown_opt.append("unknown build option ")
            unknown_opt.append(arg)
            eprint_line(unknown_opt.as_str())
            cli_help.print_usage(true)
            return 1
        positional.push(arg)
        ai += 1

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
            eprint_line("missing source file path")
            cli_help.print_usage(true)
            return 1

    let options = TestRunOptions(
        roots = roots.as_span(),
        name_filter = name_filter,
        timeout_seconds = timeout_seconds,
        memory_mb = memory_mb,
        jobs = jobs,
        sanitize = sanitize,
        format = format,
        cc = cc,
        profile = profile,
        platform = platform,
    )

    if fs.is_directory(path):
        return run_test_directory(path, options)
    if fs.exists(path):
        return run_test_file_path(path, options)

    var not_found = string.String.create()
    defer: not_found.release()
    not_found.append("mtc test: not a file or directory: ")
    not_found.append(path)
    eprint_line(not_found.as_str())
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
            eprint_line(cannot_read.as_str())
            return 1
        Result.success as content_payload:
            var source = content_payload.value
            defer: source.release()
            let source_text = source.as_str()
            var rc: int = 0
            if is_compile_fail_fixture(source_text):
                var results = vec.Vec[TestResult].create()
                defer: release_test_results(ref_of(results))
                rc = run_compile_fail_file(path, source_text, options, false, ref_of(results))
                emit_machine_output(options.format, ref_of(results))
                return rc

            var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
            defer: lex_diags.release()
            let _tokens = lexer.lex_reporting(source_text, ref_of(lex_diags))
            if lex_diags.len() > 0:
                print_lex_diagnostics(path, source_text, lex_diags.as_span())
                return 1

            var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer: parse_diags.release()
            let _file = parser.parse_source(source_text, ref_of(parse_diags))
            if parse_diags.len() > 0:
                print_parse_diagnostics(path, source_text, parse_diags.as_span())
                return 1

            var results = vec.Vec[TestResult].create()
            defer: release_test_results(ref_of(results))
            rc = run_tests_from_source(path, source_text, options, false, ref_of(results))
            emit_machine_output(options.format, ref_of(results))
            return rc


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
                        var file_rc: int = 0
                        if kind == TestFileKind.compile_fail:
                            file_rc = run_compile_fail_file(entry_name, source.as_str(), options, true, ref_of(results))
                        else:
                            file_rc = run_tests_from_source(entry_name, source.as_str(), options, true, ref_of(results))
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
    let _tokens = lexer.lex_reporting(source, ref_of(lex_diags))
    if lex_diags.len() > 0:
        print_lex_diagnostics(path, source, lex_diags.as_span())
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
## take no parameters, a file with no tests reports (file operands only) and a
## directory run prints its `# <file>` header first.
function run_tests_from_source(file_path: str, source: str, options: TestRunOptions, header: bool, results: ref[vec.Vec[TestResult]]) -> int:
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

    if has_main:
        var main_error = string.String.create()
        defer: main_error.release()
        main_error.append("a test file must not define 'main': ")
        main_error.append(file_path)
        eprint_line(main_error.as_str())
        return 1

    let machine = options.format != OutputFormat.human
    if all_test_count == 0:
        if not header and not machine:
            stdio.print_format(c"no @[test] functions found in %.*s\n", int<-(file_path.len), file_path.data)
        return 0

    if test_names.len() == 0 and death_names.len() == 0:
        return 0

    if invalid_name.len > 0:
        var param_error = string.String.create()
        defer: param_error.release()
        param_error.append("@[test] function '")
        param_error.append(invalid_name)
        param_error.append("' must take no parameters")
        eprint_line(param_error.as_str())
        return 1

    if header and not machine:
        stdio.print_format(c"# %.*s\n", int<-(file_path.len), file_path.data)

    var file_failed = 0
    if test_names.len() > 0:
        if run_normal_test_runner(file_path, source, ref_of(test_names), options, results) != 0:
            file_failed = 1

    var dj: ptr_uint = 0
    while dj < death_names.len():
        let dn_ptr = death_names.get(dj) else:
            break
        if not run_death_test(file_path, source, unsafe: read(dn_ptr), options, results):
            file_failed = 1
        dj += 1
    return file_failed


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
function eprint_missing_option_value(option: str) -> void:
    var text = string.String.create()
    defer: text.release()
    text.append("missing value for ")
    text.append(option)
    eprint_line(text.as_str())
    cli_help.print_usage(true)


## The `--kind` names the host accepts (aliases included).
function is_known_build_kind(name: str) -> bool:
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
## imports like `mtc.linter.fix_engine` resolve.  `quiet` suppresses the
## diagnostics (machine-readable output captures and discards them, as the host
## buffers the whole human run before re-emitting the results).
function build_runner_file(source_path: str, options: TestRunOptions, output_path: str, quiet: bool) -> Result[bool, string.String]:
    var runner_roots = vec.Vec[str].create()
    defer: runner_roots.release()
    var ri: ptr_uint = 0
    while ri < options.roots.len:
        unsafe:
            runner_roots.push(read(options.roots.data + ri))
        ri += 1

    var package_src_root = find_project_src_root(source_path)
    if package_src_root.is_some():
        runner_roots.push(package_src_root.unwrap())

    var program = loader.check_program(source_path, runner_roots.as_span(), options.platform)
    defer: program.release()

    if program.diagnostic_error_count() > 0:
        if not quiet:
            let _ = print_program_diagnostics(ref_of(program))
        return Result[bool, string.String].failure(error = string.String.from_str(""))

    let ir_program = lowering.lower(program)

    # The host forces guards off for synthesized test runners, regardless of
    # the debug profile.
    match build_driver.build(program, ir_program, output_path, options.cc, runner_roots.as_span(), options.sanitize, options.profile, Option[bool].some(value = false), build_driver.BuildKind.executable):
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


## The host's runner path: `<source dir>/__mt_test_runner_<pid><suffix>`.  The
## pid keeps a concurrent `mtc test` (and the discovery rule that ignores
## `__mt_test_runner_` files) from colliding with another process's runner.
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


## Build one runner binary whose `main(args)` dispatches to a single @[test]
## function selected by `args[1]`, then run it once per test in its own process
## so an aborting assertion is isolated to that test.  Returns 1 when the runner
## fails to build or any test fails.
function run_normal_test_runner(file_path: str, source_text: str, test_names: ref[vec.Vec[str]], options: TestRunOptions, results: ref[vec.Vec[TestResult]]) -> int:
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
            return 1

    var runner_bin_str = test_runner_path(dirname, "")
    defer: runner_bin_str.release()

    let machine = options.format != OutputFormat.human
    var build_failed = false
    match build_runner_file(runner_path_str.as_str(), options, runner_bin_str.as_str(), machine):
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
        return 1
    return 0


## Run a single @[expect_fatal] death test in its own binary.  The synthesized
## main calls the test and returns 0 on either outcome; the test passes only if
## the process aborts (fatal / failed safety check) instead of returning or
## timing out.
function run_death_test(file_path: str, source_text: str, test_name: str, options: TestRunOptions, results: ref[vec.Vec[TestResult]]) -> bool:
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
    var runner_path_str = test_runner_path(dirname, ".mt")
    defer: runner_path_str.release()

    match fs.write_text(runner_path_str.as_str(), runner_source.as_str()):
        Result.success:
            pass
        Result.failure:
            return false

    var runner_bin_str = test_runner_path(dirname, "")
    defer: runner_bin_str.release()

    var build_ok = false
    let machine = options.format != OutputFormat.human
    match build_runner_file(runner_path_str.as_str(), options, runner_bin_str.as_str(), machine):
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
