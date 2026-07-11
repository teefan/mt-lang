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
import mtc.build as build_driver
import mtc.pretty_printer.ast_formatter as fmt


function main(args: span[str]) -> int:
    if args.len < 1:
        print_help()
        return 1

    let cmd = args[0]

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

    if cmd == "test":
        return test_command(args)

    if cmd == "format":
        return format_command(args)

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
    stdio.print_line("  lex   <file>  print the lexer token stream")
    stdio.print_line("  parse <file>  parse source and print AST")
    stdio.print_line("  check <file|dir> [--root DIR]...  type-check a file/package and its imports")
    stdio.print_line("  lower <file|dir> [--root DIR]...  lower to IR and print it")
    stdio.print_line("  emit-c <file|dir> [--root DIR]...  compile to C and print it")
    stdio.print_line("  build <file|dir> [--root DIR]... [-o OUTPUT] [--cc CC] [--keep-c PATH] [--profile debug|release] [--platform linux|windows|wasm] [--debug-guards|--no-debug-guards]")
    stdio.print_line("  run   <file|dir> [--root DIR]... [-o OUTPUT] [--cc CC] [--profile debug|release] [--platform linux|windows|wasm] [--debug-guards|--no-debug-guards]")
    stdio.print_line("  test  <dir>                                       discover and run @[test] functions")
    stdio.print_line("  format <file> [--check|--write]                  format source and print, check, or write back")
    stdio.print_line("  help          print this help")


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


## Type-check a source file and its transitive imports.  Imports are resolved
## against `--root DIR` module roots (repeatable); when none are given the root
## defaults to the entry file's directory.  Supports both `.mt` files and
## package directory targets (reads package.toml for the entry point).
function check_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer roots.release()
    var file_path: Option[str] = Option[str].none

    var i: ptr_uint = 1
    while i < args.len:
        let arg = args[i]
        if arg == "--root":
            if i + 1 >= args.len:
                stdio.print_line("error: --root requires a directory")
                return 1
            roots.push(args[i + 1])
            i += 2
            continue
        match file_path:
            Option.some:
                stdio.print_line("error: check accepts a single source path")
                return 1
            Option.none:
                file_path = Option[str].some(value = arg)
        i += 1

    let path = file_path else:
        print_help()
        return 1

    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1

    if roots.is_empty():
        roots.push(path_ops.dirname(effective))

    var program = loader.check_program(effective, roots.as_span(), resolver.Platform.linux)
    defer program.release()

    if program.diagnostic_count() == 0:
        stdio.print_format(c"checked %.*s: ok\n", int<-(effective.len), effective.data)
        entry_path_owner.release()
        source_root_owner.release()
        return 0

    print_program_diagnostics(ref_of(program))
    report_check_summary(program.diagnostic_count())
    return 1


function print_program_diagnostics(program: ref[loader.Program]) -> void:
    var i: ptr_uint = 0
    while i < program.diagnostics.len():
        let d = program.diagnostics.get(i) else:
            break
        unsafe:
            let rd = read(d)
            let message = rd.message.as_str()
            let location = rd.path.as_str()
            stdio.print_format(
                c"error[sema/error]: %.*s\n  --> %.*s:%d:%d\n",
                int<-(message.len), message.data,
                int<-(location.len), location.data,
                int<-(rd.line), int<-(rd.column),
            )
        i += 1


function report_check_summary(count: ptr_uint) -> void:
    stdio.print_line("")
    if count == 1:
        stdio.print_line("error: could not check due to 1 error")
    else:
        stdio.print_format(c"error: could not check due to %d errors\n", int<-(count))


## Parse the `[--root DIR]... <source>` argument tail shared by the lower,
## emit-c, and build commands.  Fills `roots` (defaulting to the source
## directory when none is given) and returns the source path, or none after
## printing an error / usage.
function parse_source_operand(args: span[str], roots: ref[vec.Vec[str]]) -> Option[str]:
    var file_path: Option[str] = Option[str].none
    var i: ptr_uint = 1
    while i < args.len:
        let arg = args[i]
        if arg == "--root":
            if i + 1 >= args.len:
                stdio.print_line("error: --root requires a directory")
                return Option[str].none
            roots.push(args[i + 1])
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
            return Option[str].some(value = p.value)
        Option.none:
            print_help()
            return Option[str].none


## Lower a checked program to IR and print it (`mtc lower`).
## Supports both `.mt` files and package directory targets.
function lower_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer roots.release()
    let path = parse_source_operand(args, ref_of(roots)) else:
        return 1

    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1

    var program = loader.check_program(effective, roots.as_span(), resolver.Platform.linux)
    defer program.release()

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
    let path = parse_source_operand(args, ref_of(roots)) else:
        return 1

    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1

    var program = loader.check_program(effective, roots.as_span(), resolver.Platform.linux)
    defer program.release()

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
                if sec.value.equal(section):
                    let eq = find_byte(source, pos, ubyte<-91, ubyte<-61) else:
                        pos = skip_line(source, pos)
                        continue
                    let key_end = trim_right(source, pos, eq)
                    let line_key = source.slice(pos, key_end - pos)
                    if line_key.equal(key):
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


## Build a program (`mtc build`).  Supports both single `.mt` files and package
## directory targets (reads package.toml for the entry point).
function build_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer roots.release()
    var output_override: Option[str] = Option[str].none
    var keep_c_path: Option[str] = Option[str].none
    var c_compiler = "cc"
    var debug_guards = true
    var profile_name = "debug"
    var platform = resolver.Platform.linux
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
        if arg == "--debug-guards":
            debug_guards = true
            ai += 1
            continue
        if arg == "--no-debug-guards":
            debug_guards = false
            ai += 1
            continue
        if arg == "--profile":
            if ai + 1 >= args.len:
                stdio.print_line("error: --profile requires a profile name (debug or release)")
                return 1
            profile_name = args[ai + 1]
            if not profile_name.equal("debug") and not profile_name.equal("release"):
                stdio.print_line("error: --profile must be debug or release")
                return 1
            if profile_name.equal("release"):
                debug_guards = false
            ai += 2
            continue
        if arg == "--platform":
            if ai + 1 >= args.len:
                stdio.print_line("error: --platform requires linux, windows, or wasm")
                return 1
            let plat = args[ai + 1]
            if plat.equal("linux"):
                platform = resolver.Platform.linux
            else if plat.equal("windows"):
                platform = resolver.Platform.windows
            else if plat.equal("wasm"):
                platform = resolver.Platform.wasm
            else:
                stdio.print_line("error: --platform must be linux, windows, or wasm")
                return 1
            ai += 2
            continue
        filtered.push(arg)
        ai += 1
    let path = parse_source_operand(filtered.as_span(), ref_of(roots)) else:
        return 1

    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1

    var program = loader.check_program(effective, roots.as_span(), platform)
    defer program.release()

    if keep_c_path.is_some():
        keep_c_to_file(program, keep_c_path.unwrap())

    var output_path: string.String
    if output_override.is_some():
        output_path = string.String.from_str(output_override.unwrap())
    else:
        output_path = default_output_path(effective)

    match build_driver.build(program, output_path.as_str(), c_compiler, roots.as_span()):
        Result.success as built:
            var output = built.value
            defer output.release()
            output_path.release()
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
    var debug_guards = true
    var profile_name = "debug"
    var platform = resolver.Platform.linux
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
        if arg == "-o":
            if ai + 1 >= args.len:
                stdio.print_line("error: -o requires an output path")
                return 1
            output_override = Option[str].some(value= args[ai + 1])
            ai += 2
            continue
        if arg == "--cc":
            if ai + 1 >= args.len:
                stdio.print_line("error: --cc requires a compiler name")
                return 1
            c_compiler = args[ai + 1]
            ai += 2
            continue
        if arg == "--debug-guards":
            debug_guards = true
            ai += 1
            continue
        if arg == "--no-debug-guards":
            debug_guards = false
            ai += 1
            continue
        if arg == "--profile":
            if ai + 1 >= args.len:
                stdio.print_line("error: --profile requires a profile name (debug or release)")
                return 1
            profile_name = args[ai + 1]
            if not profile_name.equal("debug") and not profile_name.equal("release"):
                stdio.print_line("error: --profile must be debug or release")
                return 1
            if profile_name.equal("release"):
                debug_guards = false
            ai += 2
            continue
        if arg == "--platform":
            if ai + 1 >= args.len:
                stdio.print_line("error: --platform requires linux, windows, or wasm")
                return 1
            let plat = args[ai + 1]
            if plat.equal("linux"):
                platform = resolver.Platform.linux
            else if plat.equal("windows"):
                platform = resolver.Platform.windows
            else if plat.equal("wasm"):
                platform = resolver.Platform.wasm
            else:
                stdio.print_line("error: --platform must be linux, windows, or wasm")
                return 1
            ai += 2
            continue
        filtered.push(arg)
        ai += 1
    let path = parse_source_operand(filtered.as_span(), ref_of(roots)) else:
        return 1

    var entry_path_owner = string.String.create()
    var source_root_owner = string.String.create()
    let effective = effective_source_path(path, ref_of(roots), ref_of(entry_path_owner), ref_of(source_root_owner)) else:
        return 1
    var program = loader.check_program(effective, roots.as_span(), platform)
    defer program.release()

    var output_path: string.String
    if output_override.is_some():
        output_path = string.String.from_str(output_override.unwrap())
    else:
        output_path = default_output_path(effective)

    match build_driver.build(program, output_path.as_str(), c_compiler, roots.as_span()):
        Result.success as built:
            var built_path = built.value
            defer built_path.release()
            var owned_output = string.String.from_str(output_path.as_str())
            output_path.release()
            defer owned_output.release()
            entry_path_owner.release()
            source_root_owner.release()

            var cmd = vec.Vec[str].create()
            defer cmd.release()
            cmd.push(owned_output.as_str())
            var pai: ptr_uint = 0
            while pai < program_args.len():
                let pa_ptr = program_args.get(pai) else:
                    break
                unsafe:
                    cmd.push(read(pa_ptr))
                pai += 1

            match process.capture(cmd.as_span()):
                Result.success as captured:
                    let stdout_text_opt = captured.value.stdout_text()
                    if stdout_text_opt.is_some():
                        let stdout_text = stdout_text_opt.unwrap()
                        stdio.print_format(c"%.*s", int<-(stdout_text.len), stdout_text.data)
                    let stderr_text_opt = captured.value.stderr_text()
                    if stderr_text_opt.is_some():
                        let stderr_text = stderr_text_opt.unwrap()
                        stdio.print_format(c"%.*s", int<-(stderr_text.len), stderr_text.data)
                    return 0
                Result.failure:
                    stdio.print_format(c"error: cannot execute '%.*s'\n", int<-(owned_output.as_str().len), owned_output.as_str().data)
                    return 1
        Result.failure as failure:
            var message = failure.error
            defer message.release()
            let text = message.as_str()
            stdio.print_format(c"error: %.*s\n", int<-(text.len), text.data)
            output_path.release()
            entry_path_owner.release()
            source_root_owner.release()
            return 1


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
            return 1


## The default output path for a source build: the source path with its `.mt`
## extension removed (matching the Ruby CLI's direct-source-build behaviour).
function default_output_path(path: str) -> string.String:
    if path.ends_with(".mt"):
        return string.String.from_str(path.slice(0, path.len - 3))
    return j2_path(path, ".out")


function keep_c_to_file(program: loader.Program, output_path_str: str) -> void:
    let ir_program = lowering.lower(program)
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


## Discover and report @[test] functions in a directory.  Scans all .mt files,
## parses each to find @[test] annotations, and prints a summary.  Full test
## execution (build runner + run) requires the std.testing runtime which is
## not yet linked in self-host builds.
function test_command(args: span[str]) -> int:
    var roots = vec.Vec[str].create()
    defer roots.release()
    var test_dir = "."
    var ai: ptr_uint = 1
    while ai < args.len:
        let arg = args[ai]
        if arg == "--root":
            if ai + 1 >= args.len:
                stdio.print_line("error: --root requires a directory")
                return 1
            roots.push(args[ai + 1])
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
            var plain_count: ptr_uint = 0
            var total_tests: ptr_uint = 0
            var index: ptr_uint = 0
            while index < entries.len():
                match entries.get(index):
                    Option.some as name_payload:
                        let entry_name = name_payload.value
                        if entry_name.ends_with(".mt"):
                            let test_count = count_tests_in_file(entry_name)
                            if test_count > 0:
                                stdio.print_format(
                                    c"  %.*s (%d test(s))\n",
                                    int<-(entry_name.len), entry_name.data,
                                    int<-test_count,
                                )
                                total_tests += ptr_uint<-test_count
                            else:
                                plain_count += 1
                    Option.none:
                        pass
                index += 1

            if total_tests == 0:
                stdio.print_line("no @[test] functions found")
            else:
                stdio.print_format(
                    c"found %d @[test] function(s)\n",
                    int<-total_tests,
                )
            return 0
        Result.failure as failure_payload:
            var err = failure_payload.error
            defer err.release()
            stdio.print_format(
                c"error: cannot list directory %.*s\n",
                int<-(test_dir.len), test_dir.data,
            )
            return 1


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
                var d: ast.Decl
                unsafe:
                    d = read(file.declarations.data + di)
                match d:
                    ast.Decl.decl_function as fun:
                        var ai: ptr_uint = 0
                        while ai < fun.attributes.len:
                            unsafe:
                                let attr = read(fun.attributes.data + ai)
                                if attr.name.parts.len == 1:
                                    let an = read(attr.name.parts.data + 0)
                                    if an.equal("test") or an.equal("expect_fatal"):
                                        count += 1
                                        break
                            ai += 1
                    _:
                        pass
                di += 1
            return count
        Result.failure:
            return 0
