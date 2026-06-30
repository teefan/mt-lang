import std.fs as fs
import std.stdio as stdio
import std.str as text
import std.string as string
import std.terminal as terminal
import std.vec as vec

struct CliOptions:
    module_roots: vec.Vec[string.String]
    positional: vec.Vec[string.String]


extending CliOptions:
    public editable function release() -> void:
        release_string_vec(ref_of(this.module_roots))
        release_string_vec(ref_of(this.positional))


function main(args: span[str]) -> int:
    var options = parse_args(args)
    defer options.release()

    if options.positional.is_empty():
        print_usage()
        return 1

    let command = options.positional.get(0) else:
        fatal("mtc: missing positional argument after parse")
    let command_text = unsafe: read(ptr[string.String]<-command).as_str()

    if command_text.equal("lex"):
        return cmd_read_source("lex", ref_of(options))
    else if command_text.equal("parse"):
        return cmd_read_source("parse", ref_of(options))
    else if command_text.equal("check"):
        return cmd_read_source("check", ref_of(options))
    else if command_text.equal("lower"):
        return cmd_read_source("lower", ref_of(options))
    else if command_text.equal("emit-c"):
        return cmd_read_source("emit-c", ref_of(options))
    else if command_text.equal("build"):
        return cmd_read_source("build", ref_of(options))
    else if command_text.equal("run"):
        return cmd_read_source("run", ref_of(options))
    else if command_text.equal("test"):
        return cmd_read_source("test", ref_of(options))
    else if command_text.equal("format"):
        return cmd_read_source("format", ref_of(options))
    else if command_text.equal("lint"):
        return cmd_read_source("lint", ref_of(options))
    else if command_text.equal("new"):
        terminal.write_stderr("not yet implemented: new")
        return 1
    else if command_text.equal("help") or command_text.equal("--help") or command_text.equal("-h"):
        print_usage()
        return 0
    else if command_text.equal("version") or command_text.equal("--version") or command_text.equal("-V"):
        stdio.print_line("mtc 0.1.0 (self-host)")
        return 0
    var msg = string.String.from_str("unknown command: ")
    msg.append(command_text)
    terminal.write_stderr(msg.as_str())
    msg.release()
    return 1


function parse_args(args: span[str]) -> CliOptions:
    var result = CliOptions(
        module_roots = vec.Vec[string.String].create(),
        positional = vec.Vec[string.String].create()
    )

    var index: ptr_uint = 0
    var stop_flags = false

    while index < args.len:
        let arg = args[index]

        if stop_flags:
            result.positional.push(string.String.from_str(arg))
            index += 1
            continue

        if arg.equal("--"):
            stop_flags = true
            index += 1
            continue

        if arg.equal("-I") or arg.equal("--include-path"):
            index += 1
            if index < args.len:
                let value = args[index]
                if value.starts_with("-"):
                    terminal.write_stderr("mtc: missing value for include path")
                else:
                    result.module_roots.push(string.String.from_str(value))
                    index += 1
            else:
                terminal.write_stderr("mtc: missing value for include path")
                index += 1
            continue

        result.positional.push(string.String.from_str(arg))
        index += 1

    return result


function print_usage() -> void:
    stdio.print_line("mtc 0.1.0 (self-host) — the Milk Tea compiler")
    stdio.print_line("")
    stdio.print_line("Usage: mtc <command> [options] [path]")
    stdio.print_line("       mtc [-I PATH]... <command> [args...]")
    stdio.print_line("")
    stdio.print_line("Commands:")
    stdio.print_line("  lex       Tokenize a source file")
    stdio.print_line("  parse     Parse a source file to AST")
    stdio.print_line("  check     Type-check a source file")
    stdio.print_line("  lower     Lower to IR")
    stdio.print_line("  emit-c    Emit C code")
    stdio.print_line("  build     Compile a source file or package")
    stdio.print_line("  run       Build and execute")
    stdio.print_line("  test      Discover and run @[test] functions")
    stdio.print_line("  format    Format source files")
    stdio.print_line("  lint      Lint source files")
    stdio.print_line("  new       Scaffold a new package")


function cmd_read_source(command_name: str, options: ref[CliOptions]) -> int:
    if options.positional.len() < 2:
        var msg = string.String.from_str("mtc ")
        msg.append(command_name)
        msg.append(": missing source file path")
        terminal.write_stderr(msg.as_str())
        msg.release()
        return 1

    let path_ptr = options.positional.get(1) else:
        fatal("mtc: missing path in positional arguments")
    let path = unsafe: read(ptr[string.String]<-path_ptr).as_str()

    match fs.read_text(path):
        Result.failure as payload:
            stamp_source_error(path, payload.error)
            payload.error.release()
            return 1
        Result.success as payload:
            var content = payload.value
            defer content.release()
            stdio.print_line(content.as_str())
            return 0


function stamp_source_error(path: str, error: fs.Error) -> void:
    var msg = string.String.from_str(path)
    msg.append(": ")
    msg.append(error.message.as_str())
    terminal.write_stderr(msg.as_str())
    msg.release()


function release_string_vec(values: ref[vec.Vec[string.String]]) -> void:
    var index: ptr_uint = 0
    while index < values.len():
        let value_ptr = values.get(index) else:
            fatal("mtc: missing value in string vec")
        unsafe:
            read(ptr[string.String]<-value_ptr).release()
        index += 1
    values.release()
