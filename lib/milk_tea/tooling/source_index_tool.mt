import std.fs as fs
import std.path as path_ops
import std.stdio as stdio
import std.str as text


function argument(args: span[str], index: ptr_uint) -> Option[str]:
    if index >= args.len:
        return Option[str].none

    return Option[str].some(value = unsafe: read(args.data + index))


function print_usage() -> void:
    stdio.print("usage: source_index_tool <root_path>\n")
    return


function print_fs_error(prefix: str, error: fs.Error) -> void:
    stdio.print("%s: %s\n", prefix, error.message.as_str())
    return


function has_hidden_relative_segment(path_value: str, root_path: str) -> bool:
    match path_ops.relative_path(path_value, root_path):
        Option.none:
            return false
        Option.some as payload:
            var relative = payload.value
            defer relative.release()

            let relative_path = relative.as_str()
            if relative_path.equal("."):
                return false

            var segment_start: ptr_uint = 0
            var index: ptr_uint = 0
            while index < relative_path.len:
                if relative_path.byte_at(index) == ubyte<-47:
                    let segment = relative_path.slice(segment_start, index - segment_start)
                    if segment.len != 0 and segment.starts_with("."):
                        return true

                    segment_start = index + 1

                index += 1

            let trailing = relative_path.slice(segment_start, relative_path.len - segment_start)
            return trailing.len != 0 and trailing.starts_with(".")


function main(args: span[str]) -> int:
    if args.len != 1:
        print_usage()
        return 64

    let root_path = argument(args, 0) else:
        print_usage()
        return 64

    match fs.list_files_recursive(root_path):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            print_fs_error("failed to list source files", error)
            return 1
        Result.success as payload:
            var entries = payload.value
            defer entries.release()

            var index: ptr_uint = 0
            while index < entries.len():
                match entries.get(index):
                    Option.none:
                        stdio.print("source index helper encountered missing entry\n")
                        return 1
                    Option.some as entry_payload:
                        let path_value = entry_payload.value
                        if not has_hidden_relative_segment(path_value, root_path):
                            match path_ops.extension(path_value):
                                Option.none:
                                    pass
                                Option.some as extension_payload:
                                    if extension_payload.value.equal(".mt"):
                                        stdio.print("%.*s\n", int<-path_value.len, path_value.data)

                index += 1

            return 0
