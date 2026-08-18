# In-language tests for std.path (migrated from
# test/std/std_path_test.rb, run by `mtc test`).

import std.path as path
import std.str as str

@[test]
function test_path_predicates() -> void:
    expect(path.is_absolute("/tmp/project"))
    expect(path.is_absolute("C:/tmp/project"))
    expect(not path.is_absolute("tmp/project"))


@[test]
function test_path_join_and_normalize() -> void:
    var joined = path.join("tmp", "milk/program.mt")
    defer: joined.release()
    expect(joined.as_str().equal("tmp/milk/program.mt"))

    var absolute_join = path.join("tmp", "/etc/passwd")
    defer: absolute_join.release()
    expect(absolute_join.as_str().equal("/etc/passwd"))

    var normalized = path.normalize_separators("C:\\milk\\tea\\main.mt")
    defer: normalized.release()
    expect(normalized.as_str().equal("C:/milk/tea/main.mt"))


@[test]
function test_path_basename_and_dirname() -> void:
    expect(path.basename("src/main.mt").equal("main.mt"))
    expect(path.basename("C:/milk/tea/").equal("tea"))
    expect(path.dirname("src/main.mt").equal("src"))
    expect(path.dirname("main.mt").equal("."))
    expect(path.dirname("/main.mt").equal("/"))
    expect(path.dirname("C:/milk/tea/main.mt").equal("C:/milk/tea"))


@[test]
function test_path_extension_and_stem() -> void:
    var ext_ok = false
    match path.extension("archive.tar.gz"):
        Option.some as payload:
            ext_ok = payload.value.equal(".gz")
        Option.none:
            expect(false, "extension none for archive.tar.gz")
    expect(ext_ok)

    match path.extension(".gitignore"):
        Option.none:
            pass
        Option.some as ignored_payload:
            expect(false, "extension some for .gitignore")

    expect(path.stem("archive.tar.gz").equal("archive.tar"))
    expect(path.stem(".gitignore").equal(".gitignore"))


@[test]
function test_path_relative_path() -> void:
    match path.relative_path("/tmp/project/src/main.mt", "/tmp/project"):
        Option.some as payload:
            var relative = payload.value
            defer: relative.release()
            expect(relative.as_str().equal("src/main.mt"))
        Option.none:
            expect(false, "relative_path within tree none")

    match path.relative_path("/tmp/project", "/tmp/project"):
        Option.some as payload:
            var relative = payload.value
            defer: relative.release()
            expect(relative.as_str().equal("."))
        Option.none:
            expect(false, "relative_path identity none")

    match path.relative_path("src/lib/../main.mt", "src/docs"):
        Option.some as payload:
            var relative = payload.value
            defer: relative.release()
            expect(relative.as_str().equal("../main.mt"))
        Option.none:
            expect(false, "relative_path sibling none")

    match path.relative_path("c:/milk/tea/main.mt", "C:/milk"):
        Option.some as payload:
            var relative = payload.value
            defer: relative.release()
            expect(relative.as_str().equal("tea/main.mt"))
        Option.none:
            expect(false, "relative_path windows none")

    match path.relative_path("D:/milk/tea/main.mt", "C:/milk"):
        Option.none:
            pass
        Option.some as payload:
            var relative = payload.value
            relative.release()
            expect(false, "relative_path across drives should be none")



@[test]
function test_path_is_within_root() -> void:
    expect(path.is_within_root("/tmp/project/src/main.mt", "/tmp/project"))
    expect(path.is_within_root("/tmp/project", "/tmp/project"))
    expect(not path.is_within_root("/tmp/project-other/main.mt", "/tmp/project"))
    expect(path.is_within_root("src/lib/main.mt", "src"))
    expect(not path.is_within_root("src/../other/main.mt", "src"))
    expect(path.is_within_root("C:/milk/tea/main.mt", "c:/milk"))
    expect(not path.is_within_root("D:/milk/tea/main.mt", "C:/milk"))
