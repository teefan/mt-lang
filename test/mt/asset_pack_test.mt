# In-language tests for the MTAP asset pack reader.

import std.asset_pack as pack
import std.fs as fs
import std.path as path_ops
import std.string as string
import std.vec as vec

function cleanup_dir(dir: ref[string.String]) -> void:
    match fs.remove_tree(dir.as_str()):
        Result.failure as failure:
            var error = failure.error
            error.release()
        Result.success:
            pass
    dir.release()


function write_text_file(path: str, content: str) -> bool:
    match fs.write_text(path, content):
        Result.failure as failure:
            var error = failure.error
            error.release()
            return false
        Result.success:
            return true


function release_sources(sources: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < sources.len():
        let source = sources.get(i) else:
            break
        unsafe:
            read(source).release()
        i += 1
    sources.release()


@[test]
function test_pack_round_trip_and_missing_entry() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_ap_") else:
        expect(false, "temporary directory")
        return
    defer: cleanup_dir(ref_of(root))

    var assets = path_ops.join(root.as_str(), "assets")
    defer: assets.release()
    match fs.create_directories(assets.as_str()):
        Result.failure as failure:
            var error = failure.error
            error.release()
            expect(false, "create assets directory")
            return
        Result.success:
            pass

    var hello = path_ops.join(assets.as_str(), "hello.txt")
    defer: hello.release()
    expect(write_text_file(hello.as_str(), "hello"), "write hello.txt")

    var sources = vec.Vec[string.String].create()
    defer: release_sources(ref_of(sources))
    sources.push(string.String.from_str(assets.as_str()))

    var pack_path = path_ops.join(root.as_str(), "assets.mtpack")
    defer: pack_path.release()
    let published = pack.write(pack_path.as_str(), sources.as_span()).unwrap()
    expect(published, "pack written")

    var reader = pack.open(pack_path.as_str()).unwrap()
    defer: reader.close()

    var data = reader.read_bytes("assets/hello.txt").unwrap()
    defer: data.release()
    expect_eq(data.as_span().len, 5)
    expect_eq(data.as_str().unwrap(), "hello")
    expect(reader.read_bytes("assets/missing.txt").is_failure(), "missing entry fails")


@[test]
function test_truncated_pack_is_rejected() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_ap_") else:
        expect(false, "temporary directory")
        return
    defer: cleanup_dir(ref_of(root))

    var short_path = path_ops.join(root.as_str(), "short.mtpack")
    defer: short_path.release()
    var short_bytes: array[ubyte, 10]
    match fs.write_bytes(short_path.as_str(), short_bytes.as_span()):
        Result.failure as failure:
            var error = failure.error
            error.release()
            expect(false, "write truncated pack")
            return
        Result.success:
            pass

    expect(pack.open(short_path.as_str()).is_failure(), "a truncated header is rejected")
