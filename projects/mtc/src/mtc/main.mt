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
import std.json as json_mod
import std.map as map_mod
import std.stdio as stdio
import std.process as process
import std.libuv as libuv
import std.tar as tar
import std.terminal as terminal

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.lexer.lexer as lexer_mod
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
import mtc.linter.linter as linter_mod
import mtc.linter.config as lint_config
import mtc.linter.scope_tracking as scope_tracking
import mtc.linter.fix_engine as fix_engine
import mtc.lsp.server as lsp
import mtc.lsp.debug_info as debug_info
import mtc.lsp.debug_text as debug_text
import mtc.lsp.workspace as workspace
import mtc.lsp.semantic_tokens as semtok
import mtc.dap.server as dap
import mtc.bindgen as bindgen
import mtc.imported_bindings.registry as ib_registry
import mtc.imported_bindings.main as ib_main
import mtc.sexpr as sexpr_mod
import mtc.std_catalog as std_catalog
import mtc.main.std_cli as std_cli
import mtc.main.bindings_cli as bindings_cli
import mtc.main.format_cli as format_cli
import mtc.main.test_cli as test_cli
import mtc.main.snapshot_debug_cli as snapshot_debug_cli
import mtc.main.build_cli as build_cli
import mtc.docs_app as docs_app
import mtc.toolchain_cli as toolchain_cli
import mtc.packages.manager_cli as package_manager_cli
import mtc.packages.graph as graph
import mtc.packages.lock as package_lock
import mtc.packages.manifest as manifest
import mtc.packages.source as pkg_source
import mtc.wasm_preview as wasm_preview
import mtc.cli_help as cli_help

## Global CLI flags parsed by `dispatch_cli` (mirror Ruby's `-v`/`-q`/`--color`).
## `cli_quiet` suppresses informational output; `cli_verbose` prints per-file
## action lines in lint/format; `cli_color` is accepted for compatibility.
var cli_quiet: bool = false
var cli_verbose: bool = false
var cli_color: str = "auto"


## Read-only access to the `--verbose` flag for the extracted command modules.
public function cli_is_verbose() -> bool:
    return cli_verbose


## Read-only access to the `--quiet` flag for the extracted command modules.
public function cli_is_quiet() -> bool:
    return cli_quiet


## Write one line to stderr — CLI errors and usage blocks go there, as in the host.
public function eprint_line(text: str) -> void:
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


## Extract global `-v`/`-q`/`--color` flags, leaving the rest in `after_globals`.
## Scanning stops at `--`; returns false after an invalid `--color` diagnostic.
function extract_global_options(raw_args: span[str], after_globals: ref[vec.Vec[str]]) -> bool:
    var gi: ptr_uint = 0
    var forwarding = false
    while gi < raw_args.len:
        let a = raw_args[gi]
        if forwarding:
            read(after_globals).push(a)
            gi += 1
            continue
        if a == "--":
            forwarding = true
            read(after_globals).push(a)
            gi += 1
            continue
        if a == "-v" or a == "--verbose":
            cli_verbose = true
            gi += 1
            continue
        if a == "-q" or a == "--quiet":
            cli_quiet = true
            gi += 1
            continue
        if a == "--color" or a.starts_with("--color="):
            var value = ""
            var has_value = true
            if a.starts_with("--color="):
                value = a.slice(8, a.len - 8)
                gi += 1
            else if gi + 1 < raw_args.len:
                value = raw_args[gi + 1]
                gi += 2
            else:
                has_value = false
                gi += 1
            if value != "auto" and value != "always" and value != "never":
                var invalid = string.String.create()
                defer: invalid.release()
                invalid.append("--color must be auto, always, or never")
                if has_value:
                    invalid.append(" (got ")
                    invalid.append(value)
                    invalid.append(")")
                eprint_line(invalid.as_str())
                return false
            cli_color = value
            continue
        read(after_globals).push(a)
        gi += 1
    return true


## Module roots retained from the include sweep, plus the first `-I` spelling
## used for an unsupported-command diagnostic.
struct IncludeExtraction:
    saw_include: bool
    include_flag: str


## Extract `-I DIR`/`--include-path DIR` pairs into `include_pairs` and the rest
## into `filtered`, stopping at `--`.  A missing value is printed and skipped.
function extract_include_paths(
    after_globals: ref[vec.Vec[str]],
    filtered: ref[vec.Vec[str]],
    include_pairs: ref[vec.Vec[str]],
) -> IncludeExtraction:
    var saw_include = false
    var include_flag = ""
    var fi: ptr_uint = 0
    var saw_dashdash = false
    while fi < read(after_globals).len():
        let a_ptr = read(after_globals).get(fi) else:
            break
        let a = unsafe: read(a_ptr)
        if saw_dashdash:
            read(filtered).push(a)
            fi += 1
            continue
        if a == "--":
            saw_dashdash = true
            read(filtered).push(a)
            fi += 1
            continue
        if a == "-I" or a == "--include-path":
            var has_next = false
            var next_value = ""
            if fi + 1 < read(after_globals).len():
                let next_ptr = read(after_globals).get(fi + 1) else:
                    break
                next_value = unsafe: read(next_ptr)
                has_next = true
            if has_next and not next_value.starts_with("-"):
                if not saw_include:
                    include_flag = a
                    saw_include = true
                read(include_pairs).push(a)
                read(include_pairs).push(next_value)
                fi += 2
            else:
                var missing = string.String.create()
                defer: missing.release()
                missing.append("missing value for ")
                missing.append(a)
                eprint_line(missing.as_str())
                fi += 1
            continue
        read(filtered).push(a)
        fi += 1
    return IncludeExtraction(saw_include = saw_include, include_flag = include_flag)


## Dispatch one parsed command line.  `saw_include`/`include_flag` reproduce the
## host's unsupported-command diagnostic when a root was supplied.
function dispatch_command(args: span[str], saw_include: bool, include_flag: str) -> int:
    let cmd = args[0]

    # The compiler pipeline never reads the LSP-only analyzer facts; skipping
    # their collection avoids paying for them on compiler-sized modules.  The
    # LSP and the in-language semantic tests keep the default (enabled).
    if cmd == "check" or cmd == "lower" or cmd == "emit-c" or cmd == "build" or cmd == "run" or cmd == "lint":
        analyzer.set_tooling_facts(false)

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
        # The host's `lex_command`: `--sexpr` is recognized anywhere, any other
        # argument (flags included) is the path when none is set yet, and a
        # second argument is `unknown option: <arg>` on stderr.
        var sexpr = false
        var lex_file: Option[str] = Option[str].none
        var li: ptr_uint = 1
        while li < args.len:
            let a = args[li]
            if a == "--":
                li += 1
                continue
            if a == "--sexpr":
                sexpr = true
                li += 1
                continue
            match lex_file:
                Option.some:
                    var unknown = string.String.create()
                    defer: unknown.release()
                    unknown.append("unknown option: ")
                    unknown.append(a)
                    eprint_line(unknown.as_str())
                    cli_help.print_usage(true)
                    return 1
                Option.none:
                    lex_file = Option[str].some(value = a)
            li += 1
        let lf = lex_file else:
            eprint_line("missing source file path")
            cli_help.print_usage(true)
            return 1
        return lex_command(lf, sexpr)

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
        return build_cli.build_command(args)

    if cmd == "run":
        return build_cli.run_command(args)

    if cmd == "run-module":
        return build_cli.run_module_command(args)

    if cmd == "new":
        return scaffold_command(args)

    if cmd == "completions":
        return completions_command(args)

    if cmd == "test":
        return test_cli.test_command(args)

    if cmd == "format":
        return format_cli.format_command(args)

    if cmd == "lsp":
        if validate_lsp_args(args) != 0:
            return 1
        return lsp.run(args)

    if cmd == "dap":
        if validate_dap_args(args) != 0:
            return 1
        return dap.run(args)

    if cmd == "cache":
        return cache_command(args)

    if cmd == "bindgen":
        return bindings_cli.bindgen_command(args)

    if cmd == "imported-bindings":
        return bindings_cli.imported_bindings_command(args)

    if cmd == "docs":
        return docs_command(args)

    if cmd == "toolchain":
        return toolchain_command(args)

    if cmd == "deps":
        return package_manager_cli.run(args)

    if cmd == "std":
        return std_cli.std_command(args)

    if cmd == "snapshot":
        return snapshot_debug_cli.snapshot_command(args)

    if cmd == "debug":
        return snapshot_debug_cli.debug_command(args)

    # Unknown command: the host prints its usage block to stderr and exits 1.
    cli_help.print_usage(true)
    return 1


function dispatch_cli(raw_args: span[str]) -> int:
    if raw_args.len < 1:
        cli_help.print_help(false)
        return 0

    # Global flags (`-v`/`--verbose`, `-q`/`--quiet`, `--color MODE`) are
    # extracted first, exactly like the host's `extract_global_options!`: a
    # global flag between `-I` and its value is gone before the include pass
    # runs, so the include pass then consumes the following token.  Scanning
    # stops at `--`.
    var after_globals = vec.Vec[str].create()
    defer: after_globals.release()
    if not extract_global_options(raw_args, ref_of(after_globals)):
        return 1

    # Module roots (`-I DIR` / `--include-path DIR`) are extracted next, like
    # the host's `extract_include_paths!`, and put back after the command name
    # (the host hands them to the module loader; the commands here parse them
    # from their own arguments).  Unlike the host, scanning also stops at `--`,
    # so `run app -- -I x` forwards the argument to the program instead of
    # swallowing it.  The first flag is the one an unsupported-command error
    # names (the host's `@include_path_flags.first`).
    var filtered = vec.Vec[str].create()
    defer: filtered.release()
    var include_pairs = vec.Vec[str].create()
    defer: include_pairs.release()
    let include_scan = extract_include_paths(ref_of(after_globals), ref_of(filtered), ref_of(include_pairs))

    if filtered.len() < 1:
        cli_help.print_help(false)
        return 0

    # Module roots are put back after the command name (the host keeps them out
    # of argv and hands them to the module loader; the commands here parse them
    # from their own arguments, so they must follow the command).
    let first_arg = filtered.get(0) else:
        cli_help.print_help(false)
        return 0
    if include_scan.saw_include and command_supports_include_paths(unsafe: read(first_arg)):
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

    return dispatch_command(filtered.as_span(), include_scan.saw_include, include_scan.include_flag)


## The host's `lsp_command` flag parser: `--log-level LEVEL|--log-level=LEVEL`
## (trace/debug/info/warn/error), the `--stdio` no-op, and errors for any other
## option or positional.  Ruby renders an invalid level with `inspect` (quoted)
## and a missing value as the literal `nil`.
function validate_lsp_args(args: span[str]) -> int:
    var i: ptr_uint = 1
    while i < args.len:
        let arg = args[i]
        if arg == "--log-level":
            if i + 1 >= args.len:
                eprint_line("lsp: invalid --log-level nil (expected trace, debug, info, warn, or error)")
                return 1
            let value = args[i + 1]
            if not lsp_log_level_valid(value):
                var msg = string.String.create()
                defer: msg.release()
                msg.append("lsp: invalid --log-level \"")
                msg.append(value)
                msg.append("\" (expected trace, debug, info, warn, or error)")
                eprint_line(msg.as_str())
                return 1
            i += 2
            continue
        if arg.starts_with("--log-level=") and arg.len > 12:
            let value = arg.slice(12, arg.len - 12)
            if not lsp_log_level_valid(value):
                var msg = string.String.create()
                defer: msg.release()
                msg.append("lsp: invalid --log-level \"")
                msg.append(value)
                msg.append("\" (expected trace, debug, info, warn, or error)")
                eprint_line(msg.as_str())
                return 1
            i += 1
            continue
        if arg == "--stdio":
            i += 1
            continue
        if arg.starts_with("-"):
            var unknown = string.String.create()
            defer: unknown.release()
            unknown.append("lsp: unknown option ")
            unknown.append(arg)
            eprint_line(unknown.as_str())
            return 1
        var unexpected = string.String.create()
        defer: unexpected.release()
        unexpected.append("lsp: unexpected argument ")
        unexpected.append(arg)
        eprint_line(unexpected.as_str())
        return 1
    return 0


function lsp_log_level_valid(value: str) -> bool:
    return (
        value == "trace" or value == "debug" or value == "info"
        or value == "warn" or value == "error"
    )


## The host's `dap_command` flag parser.  `--log-level` is swallowed (a missing
## value is tolerated), `--backend` accepts any value, and `--adapter-path` must
## name an existing file.  Unknown options and positionals are errors.
function validate_dap_args(args: span[str]) -> int:
    var i: ptr_uint = 1
    while i < args.len:
        let arg = args[i]
        if arg == "--log-level":
            if i + 1 < args.len:
                i += 2
            else:
                i += 1
            continue
        if arg.starts_with("--log-level=") and arg.len > 12:
            i += 1
            continue
        if arg == "--backend":
            if i + 1 < args.len:
                i += 2
            else:
                i += 1
            continue
        if arg.starts_with("--backend=") and arg.len > 10:
            i += 1
            continue
        if arg == "--adapter-path":
            var value = ""
            if i + 1 < args.len:
                value = args[i + 1]
                i += 2
            else:
                i += 1
            if not fs.is_file(value):
                dap_adapter_not_found(value)
                return 1
            continue
        if arg.starts_with("--adapter-path=") and arg.len > 15:
            let value = arg.slice(15, arg.len - 15)
            if not fs.is_file(value):
                dap_adapter_not_found(value)
                return 1
            i += 1
            continue
        if arg.starts_with("-"):
            var unknown = string.String.create()
            defer: unknown.release()
            unknown.append("dap: unknown option ")
            unknown.append(arg)
            eprint_line(unknown.as_str())
            return 1
        var unexpected = string.String.create()
        defer: unexpected.release()
        unexpected.append("dap: unexpected argument ")
        unexpected.append(arg)
        eprint_line(unexpected.as_str())
        return 1
    return 0


function dap_adapter_not_found(value: str) -> void:
    var msg = string.String.create()
    defer: msg.release()
    msg.append("dap: adapter path not found: ")
    msg.append(value)
    eprint_line(msg.as_str())


## `mtc docs [--port|-p PORT] [--open|-o]`: the host parses only those flags
## and ignores everything after the first non-flag.
function docs_command(args: span[str]) -> int:
    var port = 0
    var open_flag = false
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--port" or arg == "-p":
            if ai + 1 < args.len:
                port = parse_docs_port(args[ai + 1])
                ai += 2
            else:
                ai += 1
            continue
        if arg == "--open" or arg == "-o":
            open_flag = true
            ai += 1
            continue
        break

    var root = docs_app.repo_root() else:
        eprint_line("docs: documentation root not found")
        return 1
    defer: root.release()
    return docs_app.serve(root.as_str(), port, open_flag)


function parse_docs_port(value: str) -> int:
    if value.len == 0:
        return 0
    var result: int = 0
    var index: ptr_uint = 0
    while index < value.len:
        let ch = value.byte_at(index)
        if ch < 48 or ch > 57:
            return 0
        result = result * 10 + int<-(ch - 48)
        if result > 65535:
            return 0
        index += 1
    if result <= 0 or result > 65535:
        return 0
    return result


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
public function expand_source_operands(
    inputs: span[str],
    paths: ref[vec.Vec[str]],
    owner: ref[vec.Vec[string.String]]
) -> void:
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
public function operand_label(inputs: span[str]) -> string.String:
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


## The host's `extract_resolution_flags!`: pull `--locked`, `--frozen` and
## `-Werror`/`--warnings-as-errors` out of the operand list (already stripped of
## the command's own flags), stopping at `--`.  Every other argument is copied
## to `remaining` in order.
struct ResolutionFlags:
    locked: bool
    frozen: bool
    warnings_as_errors: bool
    strict_types: bool


public function extract_resolution_flags_span(args: span[str], remaining: ref[vec.Vec[str]]) -> ResolutionFlags:
    var resolution = ResolutionFlags(locked = false, frozen = false, warnings_as_errors = false, strict_types = false)
    var i: ptr_uint = 0
    while i < args.len:
        let arg = args[i]
        if arg == "--locked":
            resolution.locked = true
        else if arg == "--frozen":
            resolution.locked = true
            resolution.frozen = true
        else if arg == "-Werror" or arg == "--warnings-as-errors":
            resolution.warnings_as_errors = true
        else if arg == "--strict-types":
            resolution.strict_types = true
        else if arg == "--":
            var rest = i + 1
            while rest < args.len:
                remaining.push(args[rest])
                rest += 1
            return resolution
        else:
            remaining.push(arg)
        i += 1
    return resolution


## The host's `validate_source_operands`: after resolution-flag extraction, an
## operand starting with `-` is an error.  Prints the message plus the command's
## help block to stderr.
public function validate_source_operands(command: str, operands: span[str]) -> int:
    var i: ptr_uint = 0
    while i < operands.len:
        if operands[i].starts_with("-"):
            var detail = string.String.create()
            defer: detail.release()
            detail.append("unexpected argument(s) for ")
            detail.append(command)
            detail.append(": ")
            var j: ptr_uint = 0
            while j < operands.len:
                if j > 0:
                    detail.append(" ")
                detail.append(operands[j])
                j += 1
            eprint_line(detail.as_str())
            cli_help.print_command_help(command, true)
            return 1
        i += 1
    return 0


## Split the include pairs `dispatch_cli` puts back after the command name
## (`-I DIR` / `--include-path DIR`) from the command's own operands and flags.
public function split_include_pairs(args: span[str], roots: ref[vec.Vec[str]], rest: ref[vec.Vec[str]]) -> void:
    var i: ptr_uint = 0
    while i < args.len:
        let arg = args[i]
        if (arg == "-I" or arg == "--include-path") and i + 1 < args.len:
            roots.push(args[i + 1])
            i += 2
            continue
        rest.push(arg)
        i += 1


## The host's `ensure_current_lockfile!` for one operand: a frozen run requires
## a current package.lock and reports `package manifest not found ...` /
## `package.lock is missing ...` / `package.lock is out of date ...`.
function ensure_current_lockfile_at(path: str) -> int:
    match package_lock.ensure_current(path, true):
        Result.failure as failure:
            var message = failure.error
            eprint_line(message.as_str())
            message.release()
            return 1
        Result.success:
            return 0


## The host's per-file package-graph resolution for a locked run: load the
## locked graph, add its source roots, and report `package lock not found ...`.
function apply_locked_resolution(
    path: str,
    resolution: ResolutionFlags,
    roots: ref[vec.Vec[str]],
    owned: ref[vec.Vec[string.String]]
) -> int:
    if not resolution.locked:
        return 0
    match apply_package_resolution_result(path, true, false, roots, owned):
        Result.failure as failure:
            var message = failure.error
            eprint_line(message.as_str())
            message.release()
            return 1
        Result.success:
            return 0


## Copy one root vector onto another (borrowed views; the owner keeps them alive).
function copy_roots(source: ref[vec.Vec[str]], dest: ref[vec.Vec[str]]) -> void:
    var i: ptr_uint = 0
    while i < source.len():
        let root_ptr = source.get(i) else:
            break
        dest.push(unsafe: read(root_ptr))
        i += 1


## `mtc parse PATH|DIR [PATH|DIR ...] [--sexpr] [--locked|--frozen] [-I PATH]`.
function parse_command(args: span[str]) -> int:
    var sexpr = false
    var stripped = vec.Vec[str].create()
    defer: stripped.release()
    var si: ptr_uint = 1
    while si < args.len:
        if args[si] == "--sexpr":
            sexpr = true
        else:
            stripped.push(args[si])
        si += 1
    if stripped.is_empty():
        eprint_line("missing source file path")
        cli_help.print_usage(true)
        return 1

    var roots = vec.Vec[str].create()
    defer: roots.release()
    var no_includes = vec.Vec[str].create()
    defer: no_includes.release()
    split_include_pairs(stripped.as_span(), ref_of(roots), ref_of(no_includes))

    var inputs = vec.Vec[str].create()
    defer: inputs.release()
    let resolution = extract_resolution_flags_span(no_includes.as_span(), ref_of(inputs))
    if validate_source_operands("parse", inputs.as_span()) != 0:
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

    if resolution.frozen:
        var fi: ptr_uint = 0
        while fi < paths.len():
            let fp = paths.get(fi) else:
                break
            if ensure_current_lockfile_at(unsafe: read(fp)) != 0:
                return 1
            fi += 1

    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    let multiple = paths.len() > 1
    var pi: ptr_uint = 0
    while pi < paths.len():
        let path_ptr = paths.get(pi) else:
            break
        let path = unsafe: read(path_ptr)
        if resolution.locked:
            var locked_roots = vec.Vec[str].create()
            defer: locked_roots.release()
            copy_roots(ref_of(roots), ref_of(locked_roots))
            var locked_owned = vec.Vec[string.String].create()
            defer: locked_owned.release()
            if apply_locked_resolution(path, resolution, ref_of(locked_roots), ref_of(locked_owned)) != 0:
                return 1
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
            # The host's loader raises `source file not found` with the
            # expanded path, rendered by the top-level handler on stderr.
            var missing = string.String.create()
            defer: missing.release()
            missing.append("source file not found: ")
            missing.append(abs_owner.as_str())
            eprint_line(missing.as_str())
            return 1
        Result.success as payload:
            var content = payload.value
            defer: content.release()

            let source = content.as_str()
            # The host's parse command lexes first; a lexer error aborts before
            # parsing (`Lexer.lex` raises, the CLI renders `error[lex/error]`).
            var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
            defer: lex_diags.release()
            let _lexed = lexer_mod.lex_reporting(source, ref_of(lex_diags))
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


## One file's `check` outcome.  `fatal` means the command must abort (a missing
## operand, the host's `read_source_file` raise).
struct CheckFileResult:
    errors: ptr_uint
    warnings: ptr_uint
    notes: ptr_uint
    fatal: bool


## A per-file heap region for the commands that process several sources.
## A region is a bump allocator: it frees everything at once and cannot reuse
## memory released inside it, so a file's transient garbage lands in the peak.
## Without it each file's AST, analyses and import bindings stayed live until
## process exit (~32 MB per file measured, which made `check` over the compiler
## tree grow to 15.2 GB).
struct FileRegion:
    region: heap.Region
    previous: ptr[heap.Region]?
    active: bool


## Whether one file's compile gets its own heap region.
##
## The region is a bump allocator: it frees a file's AST, analyses and IR in one
## step at file end, but while the file compiles its growth abandons copies that
## `realloc` would have reused — measured, a file's peak is up to ~2x with a
## region (`main.mt` 421 -> 946 MiB).
##
## So the region costs about one file-peak and buys release of *every* file after
## it.  With two files those are the same magnitude and it does not pay; from
## three on, retention is unbounded (each file ~32 MB, or a whole heavy peak) and
## it dominates.  Hence the region is used only when at least one file *follows*
## the next one — the last two files of a run are compiled without it.
##
## A size threshold is not usable here: a source's bytes do not predict its
## compile peak (`main.mt` is 158 KB and peaks at 798 MiB; the 1 MB
## `lowering.mt` peaks at 286 MiB), because the peak tracks the import graph the
## file pulls in.  Counting files needs no proxy and measured best on every
## shape: `main.mt` + a 60-byte file 946 -> 421 MiB, 40 small files 891 -> 381,
## 191 files 976, 8 heaviest 1,412.
function should_scope_file(remaining_after: ptr_uint) -> bool:
    return remaining_after >= 2


## Start a per-file region when `scoped`.  The returned value is inert
## otherwise, so callers end it unconditionally.
##
## `state` is written through a pointer rather than returned by value: the
## active-region registry holds `&state.region`, so the Region must live in the
## caller's frame — returning a struct by value would leave the registry
## pointing at a dead temporary.
function begin_file_region(state: ref[FileRegion], scoped: bool) -> void:
    read(state).region = heap.create_region()
    read(state).previous = null
    read(state).active = scoped
    if scoped:
        read(state).previous = heap.begin_region(ptr_of(read(state).region))


## End the per-file region: reclaim every allocation made since `begin_file_region`.
function end_file_region(state: ref[FileRegion]) -> void:
    if not read(state).active:
        return
    heap.end_region(read(state).previous)
    read(state).region.release_all()


## Check one source file and print its diagnostics.  Returns none when the
## operand resolves to no source file (the host skips it).
##
## `scoped` gives the file's compile its own heap region (see `FileRegion`); the
## caller sets it when the command processes more than one file.
function check_one_file(
    source_path: str,
    roots: ref[vec.Vec[str]],
    owned_roots: ref[vec.Vec[string.String]],
    platform: resolver.Platform,
    resolution: ResolutionFlags,
    lower_after_check: bool,
    scoped: bool,
) -> Option[CheckFileResult]:
    var file_roots = vec.Vec[str].create()
    defer: file_roots.release()
    copy_roots(roots, ref_of(file_roots))

    var entry_path_owner = string.String.create()
    defer: entry_path_owner.release()
    var source_root_owner = string.String.create()
    defer: source_root_owner.release()
    let effective = effective_source_path(
        source_path,
        ref_of(file_roots),
        ref_of(entry_path_owner),
        ref_of(source_root_owner)
    ) else:
        return Option[CheckFileResult].none

    # The host's diagnostics loop re-reads the file with `read_source_file`,
    # which raises for a missing operand and aborts the command before any
    # summary (the operand is rendered as given, not expanded).
    if not fs.exists(effective):
        var missing = string.String.create()
        defer: missing.release()
        missing.append("source file not found: ")
        missing.append(source_path)
        eprint_line(missing.as_str())
        return Option[CheckFileResult].some(value = CheckFileResult(
            errors = 0, warnings = 0, notes = 0, fatal = true
        ))

    var file_owned = vec.Vec[string.String].create()
    defer: file_owned.release()
    if resolution.locked:
        match apply_package_resolution_result(effective, true, false, ref_of(file_roots), ref_of(file_owned)):
            Result.failure as resolution_failure:
                var message = resolution_failure.error
                eprint_line(message.as_str())
                message.release()
                return Option[CheckFileResult].some(value = CheckFileResult(
                    errors = 1, warnings = 0, notes = 0, fatal = false
                ))
            Result.success:
                pass

    # Ruby's `roots_for_path` always appends the discovered project root, so
    # `mtc check examples/x.mt` resolves `std.*` without an explicit `-I`.
    # The source's own directory stays the last-resort root for a lone file
    # that lives outside any project (adding it up front would shadow the
    # project root, since roots are matched longest-first).
    add_module_roots(effective, ref_of(file_roots), owned_roots)
    if file_roots.is_empty():
        file_roots.push(path_ops.dirname(effective))

    # Compile this file inside a heap region when the command has more than one
    # source (see `FileRegion`): the AST, the analyses' maps and every binding
    # are then reclaimed in one step.  The region starts after `add_module_roots`,
    # which pushes into the caller-owned `owned_roots` and must stay ordinary
    # heap.
    var file_region = zero[FileRegion]
    begin_file_region(ref_of(file_region), scoped)
    defer: end_file_region(ref_of(file_region))

    var program = loader.check_program(effective, file_roots.as_span(), platform)
    defer: program.release()

    # The host lints with `File.expand_path(path)`, so a relative operand
    # still renders the diagnostic's absolute path.
    var lint_path_owner = loader.absolute_path(effective)
    defer: lint_path_owner.release()
    let lint_path = lint_path_owner.as_str()

    let file_errors = program.diagnostic_error_count()
    let warnings = program.diagnostic_warning_count()

    # The host's `check` prints a file's diagnostics (semantic then lint,
    # sorted by location) and reports `checked <path> as <module>` only when
    # the file produced none at all — the `elsif module_name` arm.
    var printed_errors: ptr_uint = 0
    var warning_count: ptr_uint = 0
    var note_count: ptr_uint = 0
    var file_diagnostic_count: ptr_uint = 0
    if file_errors > 0 or warnings > 0:
        printed_errors = print_program_diagnostics(ref_of(program))
        warning_count += warnings
        file_diagnostic_count += printed_errors
        file_diagnostic_count += warnings

    # Run linter on clean files to catch style hints.
    if file_errors == 0:
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
                var options = linter_mod.default_lint_options()
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
                            options.mutable_lvalue_sites = read(root_analysis_ptr).mutable_lvalue_sites.as_span()
                            options.directional_ffi_sites = read(root_analysis_ptr).directional_ffi_sites.as_span()
                            options.analysis = root_analysis_ptr
                let maybe_analysis = options.analysis
                if maybe_analysis != null:
                    unsafe:
                        lfile = read(maybe_analysis).source_file
                var providers = scope_tracking.build_import_method_providers(lfile, program.analyses.as_span())
                defer: providers.release()
                options.method_providers = providers.as_span()
                var lwarns = linter_mod.lint_source_with(lfile, src.as_str(), lint_path, options)
                defer: lwarns.release()
                if lwarns.len() > 0:
                    # The host's `check` sorts a file's diagnostics by
                    # `[line, column]` before printing (its `sort_by_location`);
                    # `lint` keeps emission order.
                    sort_lint_warnings_by_location(lwarns)
                    file_diagnostic_count += lwarns.len()
                    var lwi: ptr_uint = 0
                    while lwi < lwarns.len():
                        let lwp = lwarns.get(lwi) else:
                            break
                        unsafe:
                            let lw = read(lwp)
                            # The host's `check` renders every lint result
                            # through `ErrorFormatter` (a full block on
                            # stderr), not the one-line `lint` form, and
                            # buckets it by severity: warnings and hints
                            # carry their own counters ("39 warnings; 59
                            # notes"), so an all-hint file prints no summary.
                            match lw.severity:
                                "warning":
                                    warning_count += 1
                                "hint":
                                    note_count += 1
                                "info":
                                    note_count += 1
                                _:
                                    warning_count += 1
                            print_severity_diagnostic_block(
                                lw.path,
                                src.as_str(),
                                lw.line,
                                lw.column,
                                lw.length,
                                lw.severity,
                                lw.code,
                                lw.message,
                            )
                        lwi += 1
            Result.failure as read_err:
                var em = read_err.error
                em.release()

    # `check --lower`: run the middle-end after a clean semantic pass and report
    # user-reachable lowering errors with the same exit-code contract.
    if file_errors == 0 and lower_after_check:
        let lowering_outcome = lowering.lower_checked(program)
        if lowering_outcome.failed:
            lowering.print_lowering_error(lowering_outcome.error)
            printed_errors += 1
            file_diagnostic_count += 1

    if file_diagnostic_count == 0:
        # The host's `elsif module_name` arm: a file with no diagnostics at
        # all reports its resolved module name.  Prints unless `--quiet`.
        if not cli_quiet:
            let module_name = program.root_module_name()
            stdio.print_format(
                c"checked %.*s as %.*s\n",
                int<-(source_path.len), source_path.data,
                int<-(module_name.len), module_name.data,
            )
    return Option[CheckFileResult].some(value = CheckFileResult(
        errors = printed_errors,
        warnings = warning_count,
        notes = note_count,
        fatal = false,
    ))


## Type-check source files and their transitive imports.  Accepts `.mt` files,
## directories (recursively discovers `*.mt`), and package directory targets
## (reads package.toml).  Imports are resolved against `-I DIR` / `--root DIR`
## module roots (repeatable); when none are given the root defaults to the file's
## directory.
##
## Flags:
##   -I DIR, --include-path DIR    module search root (repeatable)
##   -Werror               treat warnings as errors
##   --locked              resolve dependencies from package.lock
##   --frozen              require a current package.lock (implies --locked)
function check_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var input_paths = vec.Vec[str].create()
    defer: input_paths.release()
    var platform = resolver.Platform.linux

    var stripped = vec.Vec[str].create()
    defer: stripped.release()
    split_include_pairs(unsafe: span[str](data = args.data + 1, len = args.len - 1), ref_of(roots), ref_of(stripped))
    if stripped.is_empty():
        eprint_line("missing source file path")
        cli_help.print_usage(true)
        return 1
    # `--lower` is a check-only flag; extract it before the shared resolution
    # flags so build/run/lower do not grow an ignored option.  A literal `--`
    # stops flag interpretation, as elsewhere.
    var lower_after_check = false
    var check_args = vec.Vec[str].create()
    defer: check_args.release()
    var seen_separator = false
    var ci: ptr_uint = 0
    while ci < stripped.len():
        let check_arg_ptr = stripped.get(ci) else:
            break
        let check_arg = unsafe: read(check_arg_ptr)
        if not seen_separator and check_arg == "--lower":
            lower_after_check = true
        else:
            check_args.push(check_arg)
            if check_arg == "--":
                seen_separator = true
        ci += 1
    let resolution = extract_resolution_flags_span(check_args.as_span(), ref_of(input_paths))
    analyzer.set_strict_assignability(resolution.strict_types)
    let warnings_as_errors = resolution.warnings_as_errors
    if input_paths.is_empty():
        eprint_line("missing source file path")
        cli_help.print_usage(true)
        return 1
    if validate_source_operands("check", input_paths.as_span()) != 0:
        return 1

    # Expand directories to their .mt files.  Paths are copied into owned
    # Strings so they do not dangle when a directory listing is released.
    var source_files = vec.Vec[string.String].create()
    defer: source_files.release()
    if not collect_lint_source_files(input_paths.as_span(), ref_of(source_files)):
        return 1

    if source_files.is_empty():
        var label = operand_label(input_paths.as_span())
        defer: label.release()
        var msg = string.String.create()
        defer: msg.release()
        msg.append("no .mt files found in ")
        msg.append(label.as_str())
        stdio.print_line(msg.as_str())
        return 0

    # The host's `ensure_current_lockfiles!`: every expanded path must belong to
    # a package whose lock is current.
    if resolution.frozen:
        var ffi: ptr_uint = 0
        while ffi < source_files.len():
            let fp = source_files.get(ffi) else:
                break
            if ensure_current_lockfile_at(unsafe: read(fp).as_str()) != 0:
                return 1
            ffi += 1

    var total_errors: ptr_uint = 0
    var total_warnings: ptr_uint = 0
    var total_notes: ptr_uint = 0

    var fi: ptr_uint = 0
    while fi < source_files.len():
        let raw_path = source_files.get(fi) else:
            break
        let source_path = unsafe: read(raw_path).as_str()
        let scoped = should_scope_file(source_files.len() - (fi + 1))
        let result = check_one_file(
            source_path,
            ref_of(roots),
            ref_of(owned_roots),
            platform,
            resolution,
            lower_after_check,
            scoped
        ) else:
            fi += 1
            continue
        if result.fatal:
            return 1
        total_errors += result.errors
        total_warnings += result.warnings
        total_notes += result.notes
        fi += 1

    let _ = terminal.flush_stderr()
    report_check_summary(total_errors, total_warnings, total_notes, warnings_as_errors)
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
public function print_program_diagnostics(program: ref[loader.Program]) -> ptr_uint:
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
            if rd.code.equal("load/error"):
                # A whole-file load failure has no position, and the host renders
                # it as `<message>: <path>` (its `ErrorFormatter` falls back to
                # the bare message when `line`/`column` are absent).
                block.append(message)
                block.append(": ")
                block.append(location)
                block.append("\n")
                let _ = terminal.write_stderr(block.as_str())
                i += 1
                continue
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
                            var tilde: ptr_uint = if rd.length > 0: rd.length - 1 else: 0
                            while tilde > 0:
                                block.push_byte(126)
                                tilde -= 1
                            block.append("\n")
                    Result.failure:
                        pass
            let _ = terminal.write_stderr(block.as_str())
        i += 1
    let _ = terminal.flush_stderr()
    return printed_errors


## The single-line form of a program's first error.  The test runner formats a
## build failure after the synthesized source has been deleted, so the host's
## `ErrorFormatter` has no source context: a semantic error renders as its
## location line, a module error renders bare (it carries no line/column), and
## a whole-file load failure as `<message>: <path>`.
public function first_error_line(program: ref[loader.Program]) -> string.String:
    var text = string.String.create()
    var i: ptr_uint = 0
    while i < program.diagnostics.len():
        let d = program.diagnostics.get(i) else:
            break
        unsafe:
            let rd = read(d)
            if rd.severity == "error":
                if rd.code.equal("module/error"):
                    text.append(rd.message.as_str())
                else if rd.code.equal("load/error"):
                    text.append(rd.message.as_str())
                    text.append(": ")
                    text.append(rd.path.as_str())
                else:
                    text.append("error[")
                    text.append(rd.code)
                    text.append("]: ")
                    text.append(rd.message.as_str())
                    text.append(" -- ")
                    text.append(rd.path.as_str())
                    text.append(":")
                    text.append(ptr_uint_to_str(rd.line))
                    text.append(":")
                    text.append(ptr_uint_to_str(rd.column))
                return text
        i += 1
    return text


## Write `text` to stderr with a trailing newline unless it already ends with
## one (the host prints exception messages through `@err.puts`).
public function eprint_message(text: str) -> void:
    let _ = terminal.write_stderr(text)
    if text.len == 0 or text.byte_at(text.len - 1) != 10:
        let _ = terminal.write_stderr("\n")
    let _ = terminal.flush_stderr()


## The host's `read_source_file` missing-file error: `source file not found:
## <path>` on stderr, with the operand as given.  Returns 1 for `return`.
public function report_missing_source(path: str) -> int:
    var missing = string.String.create()
    defer: missing.release()
    missing.append("source file not found: ")
    missing.append(path)
    eprint_line(missing.as_str())
    return 1


## Print a lexer error in the host CLI's `error[lex/error]` block form.
public function print_lex_diagnostics(path: str, source: str, diags: span[token_mod.LexDiagnostic]) -> void:
    var i: ptr_uint = 0
    while i < diags.len:
        let d = unsafe: read(diags.data + i)
        print_diagnostic_block(path, source, d.line, d.column, "lex/error", str.cstr_as_str(d.message))
        i += 1
    let _ = terminal.flush_stderr()


## Print a parse error in the host CLI's `error[parse/error]` block form.
public function print_parse_diagnostics(path: str, source: str, diags: span[pstate.ParseDiagnostic]) -> void:
    var i: ptr_uint = 0
    while i < diags.len:
        let d = unsafe: read(diags.data + i)
        print_diagnostic_block(path, source, d.line, d.column, "parse/error", str.cstr_as_str(d.message))
        i += 1
    let _ = terminal.flush_stderr()


## Append a source line as the host's ErrorFormatter renders it (a tab becomes
## one space), keeping the caret columns aligned.
function append_rendered_source_line(target: ref[string.String], source_line: str) -> void:
    var i: ptr_uint = 0
    while i < source_line.len:
        let ch = source_line.byte_at(i)
        if ch == 9:
            target.push_byte(32)
        else:
            target.push_byte(ch)
        i += 1


## `error[<code>]: <message> -- <path>:<line>:<col>` plus the source line and
## caret, the host ErrorFormatter's block.
public function print_diagnostic_block(
    path: str,
    source: str,
    line: ptr_uint,
    column: ptr_uint,
    code: str,
    message: str
) -> void:
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
            append_rendered_source_line(ref_of(block), source_line)
            block.append("\n")
            block.append("      | ")
            var sp: ptr_uint = 1
            while sp < column:
                block.push_byte(32)
                sp += 1
            block.push_byte(94)
            block.append("\n")
    let _ = terminal.write_stderr(block.as_str())


## Stable sort of lint warnings by `[line, column]`, the host's
## `sort_by_location` for `check` output.  Insertion sort keeps the ties in
## emission order, as Ruby's stable `sort_by` does.
function sort_lint_warnings_by_location(warnings: ref[vec.Vec[linter_mod.Warning]]) -> void:
    var i: ptr_uint = 1
    while i < warnings.len():
        let cur_ptr = warnings.get(i) else:
            break
        let cur = unsafe: read(cur_ptr)
        var j = i
        while j > 0:
            let prev_ptr = warnings.get(j - 1) else:
                break
            let prev = unsafe: read(prev_ptr)
            if prev.line < cur.line or (prev.line == cur.line and prev.column <= cur.column):
                break
            let dst_ptr = warnings.get(j) else:
                break
            unsafe:
                read(dst_ptr) = prev
            j -= 1
        let slot_ptr = warnings.get(j) else:
            break
        unsafe:
            read(slot_ptr) = cur
        i += 1


## Render one diagnostic in the host `ErrorFormatter` block form with its own
## severity label:
##
##     warning[code]: message -- path:line:col
##        |
##         2 | <source line>
##           | <caret run>
##
## `length` is the caret run length (1 for a single character).  A positionless
## diagnostic (line 0) renders the host's header line only, with the
## `path::` shape it uses when there is no `line`/`column`.
function print_severity_diagnostic_block(
    path: str,
    source: str,
    line: ptr_uint,
    column: ptr_uint,
    length: ptr_uint,
    severity: str,
    code: str,
    message: str,
) -> void:
    var block = string.String.create()
    defer: block.release()
    if line == 0:
        # The host's `ErrorFormatter` returns the bare message when the
        # diagnostic carries no `line` — a rule anchored at a positionless node
        # (a call, binary, or literal scrutinee) prints just its text.
        block.append(message)
        block.append("\n")
        let _ = terminal.write_stderr(block.as_str())
        return
    block.append(severity)
    block.append("[")
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
            append_rendered_source_line(ref_of(block), source_line)
            block.append("\n")
            block.append("      | ")
            var sp: ptr_uint = 1
            while sp < column:
                block.push_byte(32)
                sp += 1
            # The host's `ErrorFormatter`: a length of one is a lone `^`, a
            # longer span is `^` followed by `length-1` tildes.
            block.push_byte(94)
            var tildes: ptr_uint = if length > 1: length - 1 else: 0
            while tildes > 0:
                block.push_byte(126)
                tildes -= 1
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
## least one error, on stderr (`1 error found`, `2 warnings`).  A run whose only
## diagnostics are notes/hints prints no summary at all (the host's
## `elsif warning_count > 0` gate).
function report_check_summary(errors: ptr_uint, warnings: ptr_uint, notes: ptr_uint, warnings_as_errors: bool) -> void:
    if errors == 0 and warnings == 0 and notes == 0:
        return
    # The host prints the separator blank line for *any* diagnostic, but the
    # count line only when there is an error or a warning — a hint-only run
    # ends with the blank line alone (its `elsif warning_count > 0` gate).
    eprint_line("")
    if errors == 0 and warnings == 0:
        return
    var body = string.String.create()
    defer: body.release()
    if errors > 0:
        append_count_phrase(ref_of(body), errors, "error", "errors")
    if warnings > 0:
        if errors > 0:
            body.append("; ")
        append_count_phrase(ref_of(body), warnings, "warning", "warnings")
    if notes > 0:
        if errors > 0 or warnings > 0:
            body.append("; ")
        append_count_phrase(ref_of(body), notes, "note", "notes")
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
            var codes = linter_mod.known_rule_codes()
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


## Parsed `lint` flags; the path/list vectors stay with the caller.
struct LintFlags:
    fix_mode: bool
    ignore_generated: bool
    timings: bool
    init_mode: bool
    locked_flag: bool
    frozen_flag: bool


## Parse `lint` arguments, splitting `-I` pairs first and appending paths,
## select/ignore codes, roots, and the stripped argv to the caller's vectors.
## Returns none after printing a usage/diagnostic error.
function parse_lint_options(
    args: span[str],
    input_paths: ref[vec.Vec[str]],
    select_set: ref[vec.Vec[str]],
    ignore_set: ref[vec.Vec[str]],
    roots: ref[vec.Vec[str]],
    stripped: ref[vec.Vec[str]],
) -> Option[LintFlags]:
    var lint_flags = LintFlags(
        fix_mode = false,
        ignore_generated = false,
        timings = false,
        init_mode = false,
        locked_flag = false,
        frozen_flag = false,
    )
    split_include_pairs(unsafe: span[str](data = args.data + 1, len = args.len - 1), roots, stripped)
    var i: ptr_uint = 0
    while i < read(stripped).len():
        let arg_ptr = read(stripped).get(i) else:
            break
        let arg = unsafe: read(arg_ptr)
        if arg == "--fix":
            lint_flags.fix_mode = true
            i += 1
            continue
        if arg == "--ignore-generated":
            lint_flags.ignore_generated = true
            i += 1
            continue
        if arg == "--timings":
            lint_flags.timings = true
            i += 1
            continue
        if arg == "--locked":
            lint_flags.locked_flag = true
            i += 1
            continue
        if arg == "--frozen":
            lint_flags.locked_flag = true
            lint_flags.frozen_flag = true
            i += 1
            continue
        if arg == "--init":
            lint_flags.init_mode = true
            i += 1
            continue
        if arg == "--select":
            i += 1
            if i >= read(stripped).len():
                eprint_line("--select requires a comma-separated list of rule codes")
                return Option[LintFlags].none
            let value_ptr = read(stripped).get(i) else:
                eprint_line("--select requires a comma-separated list of rule codes")
                return Option[LintFlags].none
            collect_filter_codes(unsafe: read(value_ptr), select_set)
            i += 1
            continue
        if arg == "--ignore":
            i += 1
            if i >= read(stripped).len():
                eprint_line("--ignore requires a comma-separated list of rule codes")
                return Option[LintFlags].none
            let value_ptr = read(stripped).get(i) else:
                eprint_line("--ignore requires a comma-separated list of rule codes")
                return Option[LintFlags].none
            collect_filter_codes(unsafe: read(value_ptr), ignore_set)
            i += 1
            continue
        if arg == "--":
            i += 1
            while i < read(stripped).len():
                let rest_ptr = read(stripped).get(i) else:
                    break
                read(input_paths).push(unsafe: read(rest_ptr))
                i += 1
            break
        if arg.starts_with("-"):
            var unknown = string.String.create()
            defer: unknown.release()
            unknown.append("unknown lint flag: ")
            unknown.append(arg)
            eprint_line(unknown.as_str())
            return Option[LintFlags].none
        read(input_paths).push(arg)
        i += 1
    return Option[LintFlags].some(value = lint_flags)


## Expand directory operands into their `.mt` files (sorted, skipping
## synthesized runner sidecars) and copy file operands into owned strings.
## Returns false after printing a listing error.
function collect_lint_source_files(input_paths: span[str], source_files: ref[vec.Vec[string.String]]) -> bool:
    var si: ptr_uint = 0
    while si < input_paths.len:
        let path = input_paths[si]
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
                                    read(source_files).push(string.String.from_str(entry_name))
                            Option.none:
                                pass
                        ei += 1
                Result.failure as err_payload:
                    var err_msg = err_payload.error
                    defer: err_msg.release()
                    stdio.print_format(c"error: cannot list %.*s\n", int<-(path.len), path.data)
                    return false
        else:
            read(source_files).push(string.String.from_str(path))
        si += 1
    return true


## One file's lint outcome: its warning count (zero in fix mode) and whether it
## printed warnings.
struct LintFileResult:
    warnings: ptr_uint
    had_warnings: bool


## What one region-scoped lint pass measured and reported.
struct LintScan:
    warnings: ptr_uint
    fix_mode: bool
    elapsed_ms: double


## Lint (or fix) one source file inside a heap region of its own.  The caller
## owns the region boundary (see `lint_one_file`), so every allocation this
## function makes — the loaded program's AST and analyses, the lint AST, the
## warning list — is freed in one step once it returns; only counts and a
## duration come back.
function lint_file_scoped(
    src: str,
    fp: str,
    lint_target: str,
    lint_flags: LintFlags,
    platform: resolver.Platform,
    lint_roots: span[str],
    select_set: span[str],
    ignore_set: span[str],
    file_profile: ptr[profile_mod.Profile]?,
) -> LintScan:
    # Load the module so the lint sees what the analyzer knows: which
    # methods are `editable` (prefer-let on `var v` + `v.push(1)`),
    # which types own resources, and which imports failed.  The host's
    # linter runs on analyzed files too.
    var lint_program = loader.check_program(lint_target, lint_roots, platform)
    defer: lint_program.release()
    var owning_names = lint_program.owning_type_span()
    var unresolved_paths = vec.Vec[str].create()
    defer: unresolved_paths.release()
    var options = linter_mod.default_lint_options()
    options.owning_type_names = owning_names
    options.select = select_set
    options.ignore = ignore_set
    options.profile = file_profile
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
                options.mutable_lvalue_sites = read(root_analysis_ptr).mutable_lvalue_sites.as_span()
                options.directional_ffi_sites = read(root_analysis_ptr).directional_ffi_sites.as_span()
                options.analysis = root_analysis_ptr

    if lint_flags.fix_mode:
        let fix_started_ms = format_cli.monotonic_ms()
        var fixed = fix_engine.fix_source(src, fp, options)
        defer: fixed.release()
        let elapsed = format_cli.monotonic_ms() - fix_started_ms
        if not fixed.as_str().equal(src):
            match fs.write_text(fp, fixed.as_str()):
                Result.success:
                    if not cli_quiet:
                        stdio.print_format(c"fixed %.*s\n", int<-(fp.len), fp.data)
                Result.failure as write_err:
                    var wem = write_err.error
                    defer: wem.release()
                    stdio.print_format(c"error: cannot write %.*s\n", int<-(fp.len), fp.data)
        return LintScan(warnings = 0, fix_mode = true, elapsed_ms = elapsed)

    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    var file = parser.parse_source(src, ref_of(diags))
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
    let lint_scan_started_ms = format_cli.monotonic_ms()
    var warns = linter_mod.lint_source_with(file, src, fp, options)
    let lint_scan_total_ms = format_cli.monotonic_ms() - lint_scan_started_ms
    defer: warns.release()
    let warning_count = warns.len()
    var wi: ptr_uint = 0
    while wi < warns.len():
        let wp = warns.get(wi) else:
            break
        unsafe:
            let w = read(wp)
            if w.line == 0:
                stdio.print_format(
                    c"%.*s:: %.*s: %.*s\n",
                    int<-(w.path.len), w.path.data,
                    int<-(w.code.len), w.code.data,
                    int<-(w.message.len), w.message.data,
                )
            else:
                stdio.print_format(
                    c"%.*s:%d: %.*s: %.*s\n",
                    int<-(w.path.len), w.path.data,
                    int<-(w.line),
                    int<-(w.code.len), w.code.data,
                    int<-(w.message.len), w.message.data,
                )
        wi += 1
    return LintScan(warnings = warning_count, fix_mode = false, elapsed_ms = lint_scan_total_ms)


## Lint (or fix) one source file.  Returns none after printing a read/resolution
## error; `--ignore-generated` and `--fix` return a zero-warning result.
function lint_one_file(
    fp: str,
    lint_flags: LintFlags,
    platform: resolver.Platform,
    roots: span[str],
    owned_roots: ref[vec.Vec[string.String]],
    select_set: span[str],
    ignore_set: span[str],
    timing_entries: ref[vec.Vec[LintTimingEntry]],
    scoped: bool,
) -> Option[LintFileResult]:
    if cli_verbose:
        if lint_flags.fix_mode:
            stdio.print_format(c"fixing %.*s\n", int<-(fp.len), fp.data)
        else:
            stdio.print_format(c"linting %.*s\n", int<-(fp.len), fp.data)
    match fs.read_text(fp):
        Result.success as content:
            var src = content.value
            defer: src.release()

            # `--ignore-generated` skips files emitted by the compiler
            # (first line starts with the generated-file header).
            if lint_flags.ignore_generated and src.as_str().starts_with("# generated by mtc"):
                return Option[LintFileResult].some(value = LintFileResult(warnings = 0, had_warnings = false))

            var lint_roots = vec.Vec[str].create()
            defer: lint_roots.release()
            var rj: ptr_uint = 0
            while rj < roots.len:
                lint_roots.push(roots[rj])
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
            var lint_owned = vec.Vec[string.String].create()
            defer: lint_owned.release()
            if lint_flags.locked_flag:
                match apply_package_resolution_result(lint_target, true, false, ref_of(lint_roots), ref_of(lint_owned)):
                    Result.failure as resolution_failure:
                        var message = resolution_failure.error
                        eprint_line(message.as_str())
                        message.release()
                        return Option[LintFileResult].none
                    Result.success:
                        pass
            # The module roots land in this frame's vectors, which outlive the
            # per-file region below, so they are resolved before it starts.
            add_module_roots(lint_target, ref_of(lint_roots), owned_roots)
            if lint_roots.is_empty():
                lint_roots.push(path_ops.dirname(lint_target))

            # The `--timings` profile outlives this file (its entries print after
            # the whole run), so the Profile struct and the phase vectors it
            # grows are ordinary heap allocated *before* the per-file region:
            # an existing libc allocation grows through `libc.realloc` and is
            # never captured by the region.
            var file_profile: ptr[profile_mod.Profile]? = null
            if lint_flags.timings:
                file_profile = create_heap_profile()

            # Per-file region (see `FileRegion`): otherwise each linted file
            # retained its AST and analyses until process exit.  It is started
            # only for a multi-file run — for one file its bump allocation is a
            # net loss — so the timing entry below stays outside either way.
            var file_region = zero[FileRegion]
            begin_file_region(ref_of(file_region), scoped)
            let scanned = lint_file_scoped(
                src.as_str(), fp, lint_target, lint_flags, platform, lint_roots.as_span(),
                select_set, ignore_set, file_profile
            )
            end_file_region(ref_of(file_region))

            # The timing entry owns a path String and grows the caller's
            # entries vector, so it is built after the region is gone.
            if lint_flags.timings:
                push_lint_timing(timing_entries, fp, file_profile, scanned.elapsed_ms, scanned.fix_mode)
            if scanned.fix_mode:
                return Option[LintFileResult].some(value = LintFileResult(warnings = 0, had_warnings = false))
            return Option[LintFileResult].some(value = LintFileResult(
                warnings = scanned.warnings,
                had_warnings = scanned.warnings > 0,
            ))
        Result.failure as read_err:
            var em = read_err.error
            em.release()
            # The host's `read_source_file` raises `source file not found`
            # with the operand as given, rendered by the top-level handler.
            var missing = string.String.create()
            defer: missing.release()
            missing.append("source file not found: ")
            missing.append(fp)
            eprint_line(missing.as_str())
            return Option[LintFileResult].none


function lint_command(args: span[str]) -> int:
    var input_paths = vec.Vec[str].create()
    defer: input_paths.release()
    var select_set = vec.Vec[str].create()
    defer: select_set.release()
    var ignore_set = vec.Vec[str].create()
    defer: ignore_set.release()
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var stripped = vec.Vec[str].create()
    defer: stripped.release()
    let platform = resolver.Platform.linux
    let lint_flags = parse_lint_options(
        args, ref_of(input_paths), ref_of(select_set), ref_of(ignore_set), ref_of(roots), ref_of(stripped)
    ) else:
        return 1

    if lint_flags.init_mode:
        if (
            input_paths.len() > 0
            or select_set.len() > 0
            or ignore_set.len() > 0
            or lint_flags.fix_mode
            or lint_flags.locked_flag
        ):
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
    if not collect_lint_source_files(input_paths.as_span(), ref_of(source_files)):
        return 1

    if source_files.is_empty():
        var label = operand_label(input_paths.as_span())
        defer: label.release()
        var msg = string.String.create()
        defer: msg.release()
        msg.append("no .mt files found in ")
        msg.append(label.as_str())
        stdio.print_line(msg.as_str())
        return 0

    if lint_flags.frozen_flag:
        var ffi: ptr_uint = 0
        while ffi < source_files.len():
            let fp = source_files.get(ffi) else:
                break
            if ensure_current_lockfile_at(unsafe: read(fp).as_str()) != 0:
                return 1
            ffi += 1

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
        let scoped = should_scope_file(source_files.len() - (fi + 1))
        let result = lint_one_file(
            fp, lint_flags, platform, roots.as_span(), ref_of(owned_roots), select_set.as_span(), ignore_set.as_span(),
            ref_of(timing_entries), scoped
        ) else:
            return 1
        if result.had_warnings:
            files_with_warnings += 1
        total_warnings += result.warnings
        fi += 1

    if lint_flags.fix_mode:
        if lint_flags.timings:
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
        if lint_flags.timings:
            print_lint_file_profiles(ref_of(timing_entries))
        return 0

    if lint_flags.timings:
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
public function parse_platform_name(name: str) -> Option[resolver.Platform]:
    if name == "linux":
        return Option[resolver.Platform].some(value = resolver.Platform.linux)
    if name == "windows":
        return Option[resolver.Platform].some(value = resolver.Platform.windows)
    if name == "wasm":
        return Option[resolver.Platform].some(value = resolver.Platform.wasm)
    var bad = string.String.create()
    defer: bad.release()
    bad.append("unknown platform ")
    bad.append(name)
    bad.append("; expected linux|windows|wasm")
    eprint_line(bad.as_str())
    return Option[resolver.Platform].none


## The canonical name of a target platform (inverse of parse_platform_name).
public function platform_label(platform: resolver.Platform) -> str:
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
public function parse_source_operand(
    args: span[str],
    roots: ref[vec.Vec[str]],
    owned_roots: ref[vec.Vec[string.String]],
    platform: ref[resolver.Platform]
) -> Option[str]:
    var file_path: Option[str] = Option[str].none
    var i: ptr_uint = 1
    while i < args.len:
        let arg = args[i]
        if arg == "-I" or arg == "--include-path":
            if i + 1 >= args.len:
                stdio.print_line("error: -I requires a directory")
                return Option[str].none
            roots.push(args[i + 1])
            i += 2
            continue
        if arg == "--platform":
            if i + 1 >= args.len:
                test_cli.eprint_missing_option_value(arg)
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
public function reject_external_root(program: loader.Program) -> bool:
    if not program.root_is_raw_module():
        return false
    let name = program.root_module_name()
    stdio.print_format(c"cannot emit C for external file %.*s\n", int<-(name.len), name.data)
    return true


## Reject a build/run target with no valid executable entrypoint, mirroring
## Ruby's Build.ensure_program_has_entrypoint!.  Call after external-file
## rejection with the lowered IR.  Returns true when there is no entrypoint
## (message already printed); the caller then cleans up and returns 1.
public function reject_missing_entrypoint(program: loader.Program, ir_program: ir.Program) -> bool:
    if ir.has_entrypoint(ir_program):
        return false
    if program.root_has_main():
        eprint_line("root main is not a valid executable entrypoint; expected `function main() -> int|void`, `function main(argc: int, argv: ptr[cstr]) -> int|void`, `function main(argc: int, argv: ptr[ptr[char]]) -> int|void`, or `function main(args: span[str]) -> int|void`")
    else:
        eprint_line("no executable entrypoint found; define `main` with one of the supported executable signatures")
    return true


## Lower one or more source files to IR (`mtc lower`).  Mirrors the host's
## command: `--sexpr` is stripped anywhere, resolution flags are extracted, the
## operands are expanded (directories contribute every `.mt` file) and validated,
## and multiple outputs are separated by `# --- <path> ---` headers.
function lower_command(args: span[str]) -> int:
    var sexpr = false
    var stripped = vec.Vec[str].create()
    defer: stripped.release()
    var si: ptr_uint = 1
    while si < args.len:
        if args[si] == "--sexpr":
            sexpr = true
        else:
            stripped.push(args[si])
        si += 1
    if stripped.is_empty():
        eprint_line("missing source file path")
        cli_help.print_usage(true)
        return 1

    var roots = vec.Vec[str].create()
    defer: roots.release()
    var no_includes = vec.Vec[str].create()
    defer: no_includes.release()
    split_include_pairs(stripped.as_span(), ref_of(roots), ref_of(no_includes))

    var inputs = vec.Vec[str].create()
    defer: inputs.release()
    let resolution = extract_resolution_flags_span(no_includes.as_span(), ref_of(inputs))
    analyzer.set_strict_assignability(resolution.strict_types)
    if validate_source_operands("lower", inputs.as_span()) != 0:
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

    if resolution.frozen:
        var fi: ptr_uint = 0
        while fi < paths.len():
            let fp = paths.get(fi) else:
                break
            if ensure_current_lockfile_at(unsafe: read(fp)) != 0:
                return 1
            fi += 1

    let platform = resolver.Platform.linux
    let multiple = paths.len() > 1
    var pi: ptr_uint = 0
    while pi < paths.len():
        let path_ptr = paths.get(pi) else:
            break
        let path = unsafe: read(path_ptr)
        var file_roots = vec.Vec[str].create()
        defer: file_roots.release()
        copy_roots(ref_of(roots), ref_of(file_roots))
        var file_owned = vec.Vec[string.String].create()
        defer: file_owned.release()
        if apply_locked_resolution(path, resolution, ref_of(file_roots), ref_of(file_owned)) != 0:
            return 1
        let rc = lower_one_path(
            path,
            ref_of(file_roots),
            ref_of(file_owned),
            platform,
            sexpr,
            multiple and not sexpr,
            paths.len() - (pi + 1)
        )
        if rc != 0:
            return rc
        pi += 1
    return 0


## Lower one source file and print the rendered IR (or its `--sexpr` dump).
## The header is printed after a successful check, matching the host's loop
## (`check_program` raises before the header on an invalid file).
function lower_one_path(
    path: str,
    roots: ref[vec.Vec[str]],
    owned: ref[vec.Vec[string.String]],
    platform: resolver.Platform,
    sexpr: bool,
    header: bool,
    remaining_files: ptr_uint
) -> int:
    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, roots, ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1
    if not fs.exists(effective):
        var missing_abs = loader.absolute_path(path)
        defer: missing_abs.release()
        var missing = string.String.create()
        defer: missing.release()
        missing.append("source file not found: ")
        missing.append(missing_abs.as_str())
        eprint_line(missing.as_str())
        entry_path_owner.release()
        source_root_owner.release()
        return 1
    add_module_roots(effective, roots, owned)

    # Per-file region (see `FileRegion`): a multi-operand `lower` otherwise
    # retains every file's AST, analyses and IR until process exit.
    var file_region = zero[FileRegion]
    begin_file_region(ref_of(file_region), should_scope_file(remaining_files))
    defer: end_file_region(ref_of(file_region))

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer: program.release()

    if program.diagnostic_error_count() > 0:
        let _ = print_program_diagnostics(ref_of(program))
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    if header:
        stdio.print_format(c"# --- %.*s ---\n", int<-(path.len), path.data)

    if reject_external_root(program):
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    let lowering_outcome = lowering.lower_checked(program)
    if lowering_outcome.failed:
        lowering.print_lowering_error(lowering_outcome.error)
        entry_path_owner.release()
        source_root_owner.release()
        return 1
    let ir_program = lowering_outcome.program
    if sexpr:
        var dumped = sexpr_mod.dump_ir_with_analyses(ir_program, program.analyses.as_span())
        defer: dumped.release()
        stdio.print_format(c"%.*s\n", int<-(dumped.as_str().len), dumped.as_str().data)
        entry_path_owner.release()
        source_root_owner.release()
        return 0
    ir_formatter.write_program(ir_program)
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
function emit_c_one_path(
    path: str,
    roots: ref[vec.Vec[str]],
    owned_roots: ref[vec.Vec[string.String]],
    platform: resolver.Platform,
    remaining_files: ptr_uint
) -> int:
    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, roots, ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        entry_path_owner.release()
        source_root_owner.release()
        return 1
    if not fs.exists(effective):
        var missing_abs = loader.absolute_path(path)
        defer: missing_abs.release()
        var missing = string.String.create()
        defer: missing.release()
        missing.append("source file not found: ")
        missing.append(missing_abs.as_str())
        eprint_line(missing.as_str())
        entry_path_owner.release()
        source_root_owner.release()
        return 1

    # Per-file region (see `FileRegion`): a multi-operand `emit-c` otherwise
    # retains every file's AST, analyses and C source until process exit.
    var file_region = zero[FileRegion]
    begin_file_region(ref_of(file_region), should_scope_file(remaining_files))
    defer: end_file_region(ref_of(file_region))

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

    let lowering_outcome = lowering.lower_checked(program)
    if lowering_outcome.failed:
        lowering.print_lowering_error(lowering_outcome.error)
        entry_path_owner.release()
        source_root_owner.release()
        return 1
    let ir_program = lowering_outcome.program
    var c_source = c_backend.generate_c(ir_program, false, false, false)
    defer: c_source.release()
    let text = c_source.as_str()
    stdio.print_format(c"%.*s", int<-(text.len), text.data)
    entry_path_owner.release()
    source_root_owner.release()
    return 0


## `mtc emit-c PATH|DIR [PATH|DIR ...] [--locked|--frozen] [-I PATH]`.
function emit_c_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer: roots.release()
    var no_includes = vec.Vec[str].create()
    defer: no_includes.release()
    split_include_pairs(unsafe: span[str](data = args.data + 1, len = args.len - 1), ref_of(roots), ref_of(no_includes))
    if no_includes.is_empty():
        eprint_line("missing source file path")
        cli_help.print_usage(true)
        return 1

    var inputs = vec.Vec[str].create()
    defer: inputs.release()
    let resolution = extract_resolution_flags_span(no_includes.as_span(), ref_of(inputs))
    analyzer.set_strict_assignability(resolution.strict_types)
    if validate_source_operands("emit-c", inputs.as_span()) != 0:
        return 1

    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var program_paths = vec.Vec[str].create()
    defer: program_paths.release()
    var resolved_owner = vec.Vec[string.String].create()
    defer: resolved_owner.release()
    var ii: ptr_uint = 0
    while ii < inputs.len():
        let raw_ptr = inputs.get(ii) else:
            break
        let raw = unsafe: read(raw_ptr)
        if not resolve_emit_c_operand(
            raw,
            ref_of(roots),
            ref_of(owned_roots),
            ref_of(program_paths),
            ref_of(resolved_owner)
        ):
            return 1
        ii += 1

    # The host checks the lock for the raw operands after resolving package
    # directories to their entry.
    if resolution.frozen:
        var fi: ptr_uint = 0
        while fi < inputs.len():
            let fp = inputs.get(fi) else:
                break
            if ensure_current_lockfile_at(unsafe: read(fp)) != 0:
                return 1
            fi += 1

    let platform = resolver.Platform.linux
    let multiple = program_paths.len() > 1
    var pi: ptr_uint = 0
    while pi < program_paths.len():
        let path_ptr = program_paths.get(pi) else:
            break
        let path = unsafe: read(path_ptr)
        var file_roots = vec.Vec[str].create()
        defer: file_roots.release()
        copy_roots(ref_of(roots), ref_of(file_roots))
        var file_owned = vec.Vec[string.String].create()
        defer: file_owned.release()
        if apply_locked_resolution(path, resolution, ref_of(file_roots), ref_of(file_owned)) != 0:
            return 1
        if multiple:
            stdio.print_format(c"/* --- %.*s --- */\n", int<-(path.len), path.data)
        let rc = emit_c_one_path(path, ref_of(file_roots), ref_of(file_owned), platform, program_paths.len() - (pi + 1))
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
function resolve_package_entry(
    dir: str,
    roots: ref[vec.Vec[str]],
    entry_owner: ref[string.String],
    source_root_owner: ref[string.String]
) -> Option[str]:
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
public function effective_source_path(
    raw_path: str,
    roots: ref[vec.Vec[str]],
    entry_owner: ref[string.String],
    source_root_owner: ref[string.String]
) -> Option[str]:
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
public function add_module_roots(
    source_path: str,
    roots: ref[vec.Vec[str]],
    owned: ref[vec.Vec[string.String]]
) -> void:
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


## Apply `--locked`/`--frozen` for an operand: a frozen build first requires a
## current package.lock; a locked build loads the graph from the lockfile and
## otherwise the live graph.  Either way the graph's source roots join the
## module roots, mirroring the host's `module_roots_for` + `package_graph_for`.
## Returns 0 on success, 1 after printing the error.
public function apply_package_resolution(
    path: str,
    locked: bool,
    frozen: bool,
    roots: ref[vec.Vec[str]],
    owned_roots: ref[vec.Vec[string.String]],
) -> int:
    match apply_package_resolution_result(path, locked, frozen, roots, owned_roots):
        Result.failure as resolution_failure:
            var message = resolution_failure.error
            eprint_line(message.as_str())
            message.release()
            return 1
        Result.success:
            return 0


## The quiet form: errors are returned to the caller.  `mtc test` resolves a
## package per test file, where the host reports the failure as that file's
## build error rather than a command-level message.
public function apply_package_resolution_result(
    path: str,
    locked: bool,
    frozen: bool,
    roots: ref[vec.Vec[str]],
    owned_roots: ref[vec.Vec[string.String]],
) -> Result[bool, string.String]:
    if frozen:
        match package_lock.ensure_current(path, true):
            Result.failure as check_failure:
                return Result[bool, string.String].failure(error = check_failure.error)
            Result.success:
                pass

    if not manifest.manifest_exists_for(path):
        return Result[bool, string.String].success(value = true)

    var package_resolver = pkg_source.create_resolver(
        if locked: pkg_source.ResolutionMode.reject else: pkg_source.ResolutionMode.materialize
    )
    defer: package_resolver.release()

    var loaded = graph.PackageGraph(nodes = vec.Vec[graph.GraphNode].create(), root_index = 0)
    var loaded_ok = false
    if locked:
        match package_lock.load_graph(path, ref_of(package_resolver)):
            Result.failure as load_failure:
                return Result[bool, string.String].failure(error = load_failure.error)
            Result.success as graph_payload:
                loaded = graph_payload.value
                loaded_ok = true
    else:
        match graph.load(path, ref_of(package_resolver)):
            Result.failure as load_failure:
                return Result[bool, string.String].failure(error = load_failure.error)
            Result.success as graph_payload:
                loaded = graph_payload.value
                loaded_ok = true
    if not loaded_ok:
        return Result[bool, string.String].success(value = true)
    defer: loaded.release()

    var graph_roots = graph.source_roots(ref_of(loaded))
    defer: pkg_source.release_strings(ref_of(graph_roots))
    var i: ptr_uint = 0
    while i < graph_roots.len():
        let root_entry = graph_roots.get(i) else:
            break
        let root = unsafe: read(root_entry).as_str()
        if not contains_root(roots, root):
            owned_roots.push(string.String.from_str(root))
            let stored = owned_roots.get(owned_roots.len() - 1) else:
                break
            roots.push(unsafe: read(stored).as_str())
        i += 1
    return Result[bool, string.String].success(value = true)


function contains_root(roots: ref[vec.Vec[str]], candidate: str) -> bool:
    var i: ptr_uint = 0
    while i < roots.len():
        let root = roots.get(i) else:
            return false
        if unsafe: read(root).equal(candidate):
            return true
        i += 1
    return false


## Scaffold a new application package (`mtc new my-project`): package.toml with
## a snake_case package name derived from the directory basename, plus an
## `src/main.mt` entry — mirroring Ruby's ProjectScaffold.
function scaffold_command(args: span[str]) -> int:
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

    var manifest_text = string.String.create()
    defer: manifest_text.release()
    manifest_text.append("[package]\nname = \"")
    manifest_text.append(package_name.as_str())
    manifest_text.append("\"\nversion = \"0.1.0\"\nsource_root = \"src\"\n\n[build]\nentry = \"src/main.mt\"\n")

    var manifest_path = path_ops.join(abs_path, "package.toml")
    defer: manifest_path.release()
    match fs.write_text(manifest_path.as_str(), manifest_text.as_str()):
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
        stdio.print_line("    COMPREPLY=( $(compgen -W \"check build run run-module test new format lint lex parse lower emit-c debug deps toolchain bindgen cache docs std snapshot lsp dap completions help version\" -- \"${cur}\") )")
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
            stdio.print_format(
                c"    '%.*s:%.*s'\n",
                int<-(entry.name.len),
                entry.name.data,
                int<-(entry.summary.len),
                entry.summary.data
            )
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
        eprint_line("missing cache subcommand")
        let _ = cli_help.print_command_help("cache", true)
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


function toolchain_command(args: span[str]) -> int:
    return toolchain_cli.run(args)

struct CommandSummary:
    name: str
    summary: str


## The self-host's command set with Ruby's `CLI::COMMANDS` order and summaries
## (used by the bash/zsh/fish completion scripts).
function command_summary_count() -> ptr_uint:
    return 23


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
        return CommandSummary(name = "lex", summary = "Print the lexer token stream")
    if index == 9:
        return CommandSummary(name = "parse", summary = "Parse source and print the AST")
    if index == 10:
        return CommandSummary(name = "lower", summary = "Lower source to IR and print it")
    if index == 11:
        return CommandSummary(name = "emit-c", summary = "Compile source to C and print it")
    if index == 12:
        return CommandSummary(name = "debug", summary = "Print tokens, AST, facts, and diagnostics")
    if index == 13:
        return CommandSummary(name = "deps", summary = "Manage package dependencies")
    if index == 14:
        return CommandSummary(name = "toolchain", summary = "Manage the native toolchain")
    if index == 15:
        return CommandSummary(name = "bindgen", summary = "Generate a binding module from a C header")
    if index == 16:
        return CommandSummary(name = "cache", summary = "Inspect and manage the build cache")
    if index == 17:
        return CommandSummary(name = "docs", summary = "Serve the local documentation site")
    if index == 18:
        return CommandSummary(name = "std", summary = "List standard library modules and print their source")
    if index == 19:
        return CommandSummary(name = "snapshot", summary = "Render a highlighted HTML snapshot")
    if index == 20:
        return CommandSummary(name = "lsp", summary = "Start the Language Server Protocol server")
    if index == 21:
        return CommandSummary(name = "dap", summary = "Start the Debug Adapter Protocol server")
    return CommandSummary(name = "completions", summary = "Print a shell completion script")


## One linted file's `--timings` profile (the host's `lint_profiles` entry):
## its path, the per-rule phase profile (heap-allocated; the entry owns it),
## the scan's total milliseconds, and which scan produced it.
struct LintTimingEntry:
    path: string.String
    profile: ptr[profile_mod.Profile]
    total_ms: double
    pre_fix: bool


## A heap profile for one linted file.
##
## The three phase vectors are pre-reserved here so they own libc storage from
## the start: the caller may create this profile outside a per-file heap region
## and keep recording phases inside it, and a vector that already owns libc
## memory grows through `libc.realloc` instead of capturing region memory that
## dies with the file.  Phase names are literals, so a shallow copy of them
## never dangles.
function create_heap_profile() -> ptr[profile_mod.Profile]:
    let memory = unsafe: ptr[profile_mod.Profile]<-heap.must_alloc[profile_mod.Profile](1)
    unsafe:
        read(memory) = profile_mod.create()
        read(memory).names.reserve(32)
        read(memory).totals.reserve(32)
        read(memory).counts.reserve(32)
    return memory


## Release a heap profile and its storage.
function release_heap_profile(profile: ptr[profile_mod.Profile]) -> void:
    unsafe:
        var value = read(profile)
        profile_mod.release(ref_of(value))
    heap.release(profile)


## Move one file's profile into the timing entries (a no-op without a profile).
function push_lint_timing(
    entries: ref[vec.Vec[LintTimingEntry]],
    path: str,
    profile: ptr[profile_mod.Profile]?,
    total_ms: double,
    pre_fix: bool
) -> void:
    let p = profile else:
        return
    entries.push(LintTimingEntry(
        path = string.String.from_str(path),
        profile = p,
        total_ms = total_ms,
        pre_fix = pre_fix
    ))


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


public function j2_path(a: str, b: str) -> string.String:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf


## Parse a decimal string into a positive `ptr_uint`.  Returns none when the
## text is empty, contains a non-digit, or evaluates to zero.
public function parse_positive_int(text: str) -> Option[ptr_uint]:
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


public function ptr_uint_to_str(value: ptr_uint) -> str:
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


function lex_command(file_path: str, sexpr: bool) -> int:
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
            var tokens = lexer_mod.lex_reporting(source, ref_of(diags))

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
