import std.fs as fs
import std.terminal as terminal


function write_out(text_value: str) -> void:
    match terminal.write_stdout(text_value):
        Result.failure as payload:
            var write_error = payload.error
            write_error.release()
        Result.success:
            pass


function write_err(text_value: str) -> void:
    match terminal.write_stderr(text_value):
        Result.failure as payload:
            var write_error = payload.error
            write_error.release()
        Result.success:
            pass


function usage_text() -> str:
    return <<-USAGE
        mtc - Milk Tea compiler (self-hosted)

        usage:
            mtc lex <file> [--json | --format json] [--emit-tokens-json <file>]
            mtc --help
        USAGE


function show_usage(to_stderr: bool) -> void:
    let usage = usage_text()
    if to_stderr:
        write_err(usage)
    else:
        write_out(usage)


function report_pending(path_value: str, byte_count: ptr_uint, emit_json: bool, output_path: Option[str]) -> void:
    var sink = "stdout"
    match output_path:
        Option.some as path_payload:
            sink = path_payload.value
        Option.none:
            pass

    let mode = if emit_json: "json" else: "pp"
    write_out(f"lex: #{path_value} (#{byte_count} bytes) format=#{mode} sink=#{sink} - tokenizer pending\n")


function lex_command(args: span[str], start: ptr_uint) -> int:
    var emit_json = false
    var output_path = Option[str].none
    var source_path = Option[str].none

    var index = start
    while index < args.len:
        let arg = args[index]
        if arg == "--json" or arg == "--format=json":
            emit_json = true
        else if arg == "--format":
            if index + 1 < args.len:
                index += 1
                if args[index] == "json":
                    emit_json = true
        else if arg == "--emit-tokens-json":
            if index + 1 >= args.len:
                write_err("missing file path for --emit-tokens-json\n")
                return 1
            index += 1
            output_path = Option[str].some(value= args[index])
            emit_json = true
        else:
            match source_path:
                Option.some:
                    write_err(f"unknown option: #{arg}\n")
                    return 1
                Option.none:
                    source_path = Option[str].some(value= arg)

        index += 1

    let path_value = source_path else:
        write_err("missing source file path\n")
        return 1

    match fs.read_text(path_value):
        Result.failure as failure_payload:
            var read_error = failure_payload.error
            read_error.message.release()
            write_err(f"could not read source file: #{path_value}\n")
            return 1
        Result.success as success_payload:
            var source = success_payload.value
            defer source.release()
            report_pending(path_value, source.len(), emit_json, output_path)
            return 0


public function run(args: span[str]) -> int:
    if args.len == 0:
        show_usage(false)
        return 0

    let command = args[0]
    if command == "--help" or command == "-h":
        show_usage(false)
        return 0

    if command == "lex":
        return lex_command(args, 1)

    write_err(f"unknown command: #{command}\n")
    show_usage(true)
    return 1
