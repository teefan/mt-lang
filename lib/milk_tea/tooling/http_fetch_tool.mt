import std.fmt as fmt
import std.fs as fs
import std.http as http
import std.stdio as stdio
import std.string as string


function argument(args: span[str], index: ptr_uint) -> Option[str]:
    if index >= args.len:
        return Option[str].none

    return Option[str].some(value = unsafe: read(args.data + index))


function print_usage() -> void:
    stdio.print("usage: http_fetch_tool <url> <body_path> <meta_path>\n")
    return


function print_fs_error(prefix: str, error: fs.Error) -> void:
    stdio.print("%s: %s\n", prefix, error.message.as_str())
    return


function print_http_error(prefix: str, error: http.Error) -> void:
    stdio.print("%s: %s\n", prefix, error.message.as_str())
    return


function write_metadata(meta_path: str, response: http.Response) -> Result[bool, fs.Error]:
    var text_value = string.String.create()
    defer text_value.release()

    var status_code = fmt.to_string_int(response.status_code)
    defer status_code.release()

    text_value.append("status_code=")
    text_value.append(status_code.as_str())
    text_value.append("\nreason=")
    text_value.append(response.reason.as_str())
    text_value.append("\nlocation=")

    match response.header("location"):
        Option.none:
            pass
        Option.some as payload:
            text_value.append(payload.value)

    text_value.append("\n")
    return fs.write_text(meta_path, text_value.as_str())


async function main(args: span[str]) -> int:
    if args.len != 3:
        print_usage()
        return 64

    let url = argument(args, 0) else:
        print_usage()
        return 64

    let body_path = argument(args, 1) else:
        print_usage()
        return 64

    let meta_path = argument(args, 2) else:
        print_usage()
        return 64

    let response_result = await http.get(url)
    match response_result:
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            print_http_error("http fetch failed", error)
            return 1
        Result.success as payload:
            var response = payload.value
            defer response.release()

            match fs.write_bytes(body_path, response.body.as_span()):
                Result.failure as body_error_payload:
                    var error = body_error_payload.error
                    defer error.release()
                    print_fs_error("failed to write downloaded body", error)
                    return 1
                Result.success as _:
                    pass

            match write_metadata(meta_path, response):
                Result.failure as metadata_error_payload:
                    var error = metadata_error_payload.error
                    defer error.release()
                    print_fs_error("failed to write download metadata", error)
                    return 1
                Result.success as _:
                    return 0
