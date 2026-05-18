import std.fs as fs
import std.stdio as stdio
import std.str as text
import std.tar as tar


function argument(args: span[str], index: ptr_uint) -> Option[str]:
    if index >= args.len:
        return Option[str].none

    return Option[str].some(value = unsafe: read(args.data + index))


function print_usage() -> void:
    stdio.print("usage: archive <source_root> <archive_path> <archive_root_name> <include_hidden> | extract <archive_path> <destination_root>\n")
    return


function print_fs_error(prefix: str, error: fs.Error) -> void:
    stdio.print("%s: %s\n", prefix, error.message.as_str())
    return


function print_tar_error(prefix: str, error: tar.Error) -> void:
    stdio.print("%s: %s\n", prefix, error.message.as_str())
    return


function parse_bool_flag(value: str) -> Option[bool]:
    if value.equal("1") or value.equal("true"):
        return Option[bool].some(value = true)

    if value.equal("0") or value.equal("false"):
        return Option[bool].some(value = false)

    return Option[bool].none


function run_archive(args: span[str]) -> int:
    if args.len != 5:
        print_usage()
        return 64

    let source_root = argument(args, 1) else:
        print_usage()
        return 64

    let archive_path = argument(args, 2) else:
        print_usage()
        return 64

    let archive_root_name = argument(args, 3) else:
        print_usage()
        return 64

    let include_hidden_text = argument(args, 4) else:
        print_usage()
        return 64

    let include_hidden = parse_bool_flag(include_hidden_text) else:
        stdio.print("invalid include_hidden flag: %s\n", include_hidden_text)
        return 64

    match tar.archive_directory_gzip(source_root, archive_root_name, include_hidden):
        Result.failure as archive_error_payload:
            var error = archive_error_payload.error
            defer error.release()
            print_tar_error("failed to archive directory", error)
            return 1
        Result.success as archive_payload:
            var archive = archive_payload.value
            defer archive.release()

            match fs.write_bytes(archive_path, archive.as_span()):
                Result.failure as archive_write_error_payload:
                    var error = archive_write_error_payload.error
                    defer error.release()
                    print_fs_error("failed to write archive", error)
                    return 1
                Result.success as _:
                    return 0


function run_extract(args: span[str]) -> int:
    if args.len != 3:
        print_usage()
        return 64

    let archive_path = argument(args, 1) else:
        print_usage()
        return 64

    let destination_root = argument(args, 2) else:
        print_usage()
        return 64

    match fs.read_bytes(archive_path):
        Result.failure as archive_read_error_payload:
            var error = archive_read_error_payload.error
            defer error.release()
            print_fs_error("failed to read archive", error)
            return 1
        Result.success as archive_payload:
            var archive = archive_payload.value
            defer archive.release()

            match tar.extract_gzip(archive.as_span(), destination_root):
                Result.failure as extract_error_payload:
                    var error = extract_error_payload.error
                    defer error.release()
                    print_tar_error("failed to extract archive", error)
                    return 1
                Result.success as _:
                    return 0


function main(args: span[str]) -> int:
    let command = argument(args, 0) else:
        print_usage()
        return 64

    if command.equal("archive"):
        return run_archive(args)

    if command.equal("extract"):
        return run_extract(args)

    stdio.print("unknown archive helper command: %s\n", command)
    print_usage()
    return 64
