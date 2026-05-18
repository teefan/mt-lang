import std.fmt as fmt
import std.fs as fs
import std.stdio as stdio
import std.string as string


function argument(args: span[str], index: ptr_uint) -> Option[str]:
    if index >= args.len:
        return Option[str].none

    return Option[str].some(value = unsafe: read(args.data + index))


function print_usage() -> void:
    stdio.print("usage: mtime_tool <path>\n")
    return


function print_fs_error(prefix: str, error: fs.Error) -> void:
    stdio.print("%s: %s\n", prefix, error.message.as_str())
    return


function print_stamp(seconds: ptr_int, nanoseconds: ptr_int) -> void:
    var output = string.String.create()
    defer output.release()

    fmt.append_long(ref_of(output), long<-seconds)
    output.append(":")
    fmt.append_long(ref_of(output), long<-nanoseconds)

    stdio.print("%s\n", output.as_str())
    return


function main(args: span[str]) -> int:
    if args.len != 1:
        print_usage()
        return 64

    let path = argument(args, 0) else:
        print_usage()
        return 64

    match fs.metadata(path):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            print_fs_error("failed to read metadata", error)
            return 1
        Result.success as payload:
            let metadata = payload.value
            print_stamp(metadata.modified_seconds, metadata.modified_nanoseconds)
            return 0
