import std.fs as fs
import std.stdio as stdio


function argument(args: span[str], index: ptr_uint) -> Option[str]:
    if index >= args.len:
        return Option[str].none

    return Option[str].some(value = unsafe: read(args.data + index))


function print_usage() -> void:
    stdio.print("usage: read_lines_tool <path>\n")
    return


function print_fs_error(prefix: str, error: fs.Error) -> void:
    stdio.print("%s: %s\n", prefix, error.message.as_str())
    return


function main(args: span[str]) -> int:
    if args.len != 1:
        print_usage()
        return 64

    let path = argument(args, 0) else:
        print_usage()
        return 64

    match fs.read_lines(path):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            print_fs_error("failed to read lines", error)
            return 1
        Result.success as payload:
            var lines = payload.value
            defer lines.release()

            var index: ptr_uint = 0
            while index < lines.len():
                match lines.get(index):
                    Option.none:
                        stdio.print("read_lines helper encountered missing entry\n")
                        return 1
                    Option.some as line_payload:
                        let line = line_payload.value
                        stdio.print("%.*s\n", int<-line.len, line.data)

                index += 1

            return 0
