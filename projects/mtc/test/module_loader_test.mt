# In-language tests for the multi-file program loader of the self-hosted mtc
# compiler.  Run with: mtc test projects/mtc/test/module_loader_test.mt

import std.testing as t
import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string

import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver


## Remove a temp directory tree and release its owned path string.
function cleanup_dir(dir: ref[string.String]) -> void:
    match fs.remove_tree(dir.as_str()):
        Result.success:
            pass
        Result.failure as f:
            var e = f.error
            e.release()
    dir.release()


## Write `content` to `dir/relative`, creating parent directories as needed.
function write_file(dir: str, relative: str, content: str) -> bool:
    var full = path_ops.join(dir, relative)
    defer full.release()

    match fs.create_directories(path_ops.dirname(full.as_str())):
        Result.failure as f:
            var e = f.error
            e.release()
            return false
        Result.success:
            pass

    match fs.write_text(full.as_str(), content):
        Result.failure as f:
            var e = f.error
            e.release()
            return false
        Result.success:
            return true


@[test]
function test_loads_root_and_dependency() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l2_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "main.mt", "import foo\n\nfunction run() -> int:\n    return 0\n"):
        return t.fail("could not write main")
    if not write_file(root.as_str(), "foo.mt", "function helper() -> int:\n    return 1\n"):
        return t.fail("could not write foo")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer program.release()

    if program.module_count() != 2:
        return t.fail("expected 2 modules")
    if program.diagnostic_count() != 0:
        return t.fail("expected no diagnostics")

    # dependency-first order: foo is checked before main
    match program.ordered_name(0):
        Option.some as first:
            if not first.value.equal("foo"):
                return t.fail("expected foo first in dependency order")
        Option.none:
            return t.fail("missing order position 0")
    return t.ok()


@[test]
function test_diamond_dependency_loaded_once() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l2_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "main.mt", "import a\nimport b\n\nfunction run() -> int:\n    return 0\n"):
        return t.fail("could not write main")
    if not write_file(root.as_str(), "a.mt", "import c\n\nfunction fa() -> int:\n    return 1\n"):
        return t.fail("could not write a")
    if not write_file(root.as_str(), "b.mt", "import c\n\nfunction fb() -> int:\n    return 2\n"):
        return t.fail("could not write b")
    if not write_file(root.as_str(), "c.mt", "function fc() -> int:\n    return 3\n"):
        return t.fail("could not write c")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer program.release()

    if program.diagnostic_count() != 0:
        return t.fail("expected no diagnostics")
    return t.expect_equal_int(int<-program.module_count(), 4)


@[test]
function test_import_cycle_is_detected() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l2_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "a.mt", "import b\n\nfunction fa() -> int:\n    return 1\n"):
        return t.fail("could not write a")
    if not write_file(root.as_str(), "b.mt", "import a\n\nfunction fb() -> int:\n    return 2\n"):
        return t.fail("could not write b")

    var root_path = path_ops.join(root.as_str(), "a.mt")
    defer root_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(root_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("cyclic"))


@[test]
function test_missing_import_is_reported() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l2_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "main.mt", "import ghost\n\nfunction run() -> int:\n    return 0\n"):
        return t.fail("could not write main")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer program.release()

    if program.module_count() != 1:
        return t.fail("expected only the root module to load")
    return t.expect_true(program.has_diagnostic_containing("not found"))


@[test]
function test_semantic_error_is_surfaced() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l2_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "main.mt", "function f() -> int:\n    return true\n"):
        return t.fail("could not write main")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("mismatch"))


@[test]
function test_clean_program_has_no_diagnostics() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l2_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "main.mt", "function f() -> int:\n    return 0\n"):
        return t.fail("could not write main")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer program.release()

    if program.module_count() != 1:
        return t.fail("expected 1 module")
    return t.expect_equal_int(int<-program.diagnostic_count(), 0)
