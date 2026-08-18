# In-language tests for std.uri (migrated from
# test/std/std_uri_test.rb, run by `mtc test`).

import std.uri as uri
import std.str as str

@[test]
function test_uri_file_uri_from_path() -> void:
    var posix_uri = uri.file_uri_from_path("/tmp/milk tea/main.mt")
    defer: posix_uri.release()
    expect(posix_uri.as_str().equal("file:///tmp/milk%20tea/main.mt"))

    var windows_uri = uri.file_uri_from_path("C:\\milk tea\\main.mt")
    defer: windows_uri.release()
    expect(windows_uri.as_str().equal("file://C%3A/milk%20tea/main.mt"))


@[test]
function test_uri_path_from_file_uri_valid() -> void:
    match uri.path_from_file_uri("file:///tmp/milk%20tea/main.mt"):
        Option.none:
            expect(false, "decode posix uri none")
        Option.some as payload:
            var decoded = payload.value
            defer: decoded.release()
            expect(decoded.as_str().equal("/tmp/milk tea/main.mt"))

    match uri.path_from_file_uri("file://C%3A/milk%20tea/main.mt"):
        Option.none:
            expect(false, "decode windows authority uri none")
        Option.some as payload:
            var decoded = payload.value
            defer: decoded.release()
            expect(decoded.as_str().equal("C:/milk tea/main.mt"))

    match uri.path_from_file_uri("file:///C:/milk%20tea/main.mt"):
        Option.none:
            expect(false, "decode windows path uri none")
        Option.some as payload:
            var decoded = payload.value
            defer: decoded.release()
            expect(decoded.as_str().equal("C:/milk tea/main.mt"))



@[test]
function test_uri_path_from_file_uri_invalid() -> void:
    match uri.path_from_file_uri("https://example.invalid/tmp/main.mt"):
        Option.none:
            pass
        Option.some as payload:
            var decoded = payload.value
            decoded.release()
            expect(false, "non-file scheme should be none")

    match uri.path_from_file_uri("file:///tmp/%ZZ"):
        Option.none:
            pass
        Option.some as payload:
            var decoded = payload.value
            decoded.release()
            expect(false, "invalid percent escape should be none")

    match uri.path_from_file_uri("file:///tmp/%F0%28%8C%28"):
        Option.none:
            pass
        Option.some as payload:
            var decoded = payload.value
            decoded.release()
            expect(false, "invalid utf-8 should be none")

