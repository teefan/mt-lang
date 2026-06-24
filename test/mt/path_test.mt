# In-language tests for std.path (migrated from
# test/std/std_path_test.rb, run by `mtc test`).

import std.testing as t
import std.path as path
import std.str as str

@[test]
function test_path_predicates() -> t.Check:
    t.expect_true(path.is_absolute("/tmp/project"))?
    t.expect_true(path.is_absolute("C:/tmp/project"))?
    return t.expect_false(path.is_absolute("tmp/project"))


@[test]
function test_path_join_and_normalize() -> t.Check:
    var joined = path.join("tmp", "milk/program.mt")
    defer joined.release()
    t.expect_true(joined.as_str().equal("tmp/milk/program.mt"))?

    var absolute_join = path.join("tmp", "/etc/passwd")
    defer absolute_join.release()
    t.expect_true(absolute_join.as_str().equal("/etc/passwd"))?

    var normalized = path.normalize_separators("C:\\milk\\tea\\main.mt")
    defer normalized.release()
    return t.expect_true(normalized.as_str().equal("C:/milk/tea/main.mt"))


@[test]
function test_path_basename_and_dirname() -> t.Check:
    t.expect_true(path.basename("src/main.mt").equal("main.mt"))?
    t.expect_true(path.basename("C:/milk/tea/").equal("tea"))?
    t.expect_true(path.dirname("src/main.mt").equal("src"))?
    t.expect_true(path.dirname("main.mt").equal("."))?
    t.expect_true(path.dirname("/main.mt").equal("/"))?
    return t.expect_true(path.dirname("C:/milk/tea/main.mt").equal("C:/milk/tea"))


@[test]
function test_path_extension_and_stem() -> t.Check:
    var ext_ok = false
    match path.extension("archive.tar.gz"):
        Option.some as payload:
            ext_ok = payload.value.equal(".gz")
        Option.none:
            return t.fail("extension none for archive.tar.gz")
    t.expect_true(ext_ok)?

    match path.extension(".gitignore"):
        Option.none:
            pass
        Option.some as ignored_payload:
            return t.fail("extension some for .gitignore")

    t.expect_true(path.stem("archive.tar.gz").equal("archive.tar"))?
    return t.expect_true(path.stem(".gitignore").equal(".gitignore"))


@[test]
function test_path_relative_path() -> t.Check:
    match path.relative_path("/tmp/project/src/main.mt", "/tmp/project"):
        Option.some as payload:
            var relative = payload.value
            defer relative.release()
            t.expect_true(relative.as_str().equal("src/main.mt"))?
        Option.none:
            return t.fail("relative_path within tree none")

    match path.relative_path("/tmp/project", "/tmp/project"):
        Option.some as payload:
            var relative = payload.value
            defer relative.release()
            t.expect_true(relative.as_str().equal("."))?
        Option.none:
            return t.fail("relative_path identity none")

    match path.relative_path("src/lib/../main.mt", "src/docs"):
        Option.some as payload:
            var relative = payload.value
            defer relative.release()
            t.expect_true(relative.as_str().equal("../main.mt"))?
        Option.none:
            return t.fail("relative_path sibling none")

    match path.relative_path("c:/milk/tea/main.mt", "C:/milk"):
        Option.some as payload:
            var relative = payload.value
            defer relative.release()
            t.expect_true(relative.as_str().equal("tea/main.mt"))?
        Option.none:
            return t.fail("relative_path windows none")

    match path.relative_path("D:/milk/tea/main.mt", "C:/milk"):
        Option.none:
            pass
        Option.some as payload:
            var relative = payload.value
            relative.release()
            return t.fail("relative_path across drives should be none")

    return t.ok()


@[test]
function test_path_is_within_root() -> t.Check:
    t.expect_true(path.is_within_root("/tmp/project/src/main.mt", "/tmp/project"))?
    t.expect_true(path.is_within_root("/tmp/project", "/tmp/project"))?
    t.expect_false(path.is_within_root("/tmp/project-other/main.mt", "/tmp/project"))?
    t.expect_true(path.is_within_root("src/lib/main.mt", "src"))?
    t.expect_false(path.is_within_root("src/../other/main.mt", "src"))?
    t.expect_true(path.is_within_root("C:/milk/tea/main.mt", "c:/milk"))?
    return t.expect_false(path.is_within_root("D:/milk/tea/main.mt", "C:/milk"))
