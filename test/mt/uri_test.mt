# In-language tests for std.uri (migrated from
# test/std/std_uri_test.rb, run by `mtc test`).

import std.testing as t
import std.uri as uri
import std.str as str

@[test]
function test_uri_file_uri_from_path() -> t.Check:
    var posix_uri = uri.file_uri_from_path("/tmp/milk tea/main.mt")
    defer posix_uri.release()
    t.expect_true(posix_uri.as_str().equal("file:///tmp/milk%20tea/main.mt"))?

    var windows_uri = uri.file_uri_from_path("C:\\milk tea\\main.mt")
    defer windows_uri.release()
    return t.expect_true(windows_uri.as_str().equal("file://C%3A/milk%20tea/main.mt"))


@[test]
function test_uri_path_from_file_uri_valid() -> t.Check:
    match uri.path_from_file_uri("file:///tmp/milk%20tea/main.mt"):
        Option.none:
            return t.fail("decode posix uri none")
        Option.some as payload:
            var decoded = payload.value
            defer decoded.release()
            t.expect_true(decoded.as_str().equal("/tmp/milk tea/main.mt"))?

    match uri.path_from_file_uri("file://C%3A/milk%20tea/main.mt"):
        Option.none:
            return t.fail("decode windows authority uri none")
        Option.some as payload:
            var decoded = payload.value
            defer decoded.release()
            t.expect_true(decoded.as_str().equal("C:/milk tea/main.mt"))?

    match uri.path_from_file_uri("file:///C:/milk%20tea/main.mt"):
        Option.none:
            return t.fail("decode windows path uri none")
        Option.some as payload:
            var decoded = payload.value
            defer decoded.release()
            t.expect_true(decoded.as_str().equal("C:/milk tea/main.mt"))?

    return t.ok()


@[test]
function test_uri_path_from_file_uri_invalid() -> t.Check:
    match uri.path_from_file_uri("https://example.invalid/tmp/main.mt"):
        Option.none:
            pass
        Option.some as payload:
            var decoded = payload.value
            decoded.release()
            return t.fail("non-file scheme should be none")

    match uri.path_from_file_uri("file:///tmp/%ZZ"):
        Option.none:
            pass
        Option.some as payload:
            var decoded = payload.value
            decoded.release()
            return t.fail("invalid percent escape should be none")

    match uri.path_from_file_uri("file:///tmp/%F0%28%8C%28"):
        Option.none:
            pass
        Option.some as payload:
            var decoded = payload.value
            decoded.release()
            return t.fail("invalid utf-8 should be none")

    return t.ok()
