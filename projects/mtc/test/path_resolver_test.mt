# In-language tests for the module path resolver of the self-hosted mtc compiler.
# Run with: mtc test projects/mtc/test/path_resolver_test.mt

import std.testing as t
import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string

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


# =============================================================================
#  platform_suffix / platform_suffix_for_path
# =============================================================================

@[test]
function test_platform_suffix_names() -> t.Check:
    if not resolver.platform_suffix(resolver.Platform.linux).equal("linux"):
        return t.fail("linux suffix")
    if not resolver.platform_suffix(resolver.Platform.windows).equal("windows"):
        return t.fail("windows suffix")
    return t.expect_true(resolver.platform_suffix(resolver.Platform.wasm).equal("wasm"))


@[test]
function test_platform_suffix_for_linux_file() -> t.Check:
    match resolver.platform_suffix_for_path("src/mtc/fs.linux.mt"):
        Option.some as p:
            return t.expect_true(p.value == resolver.Platform.linux)
        Option.none:
            return t.fail("expected linux suffix")


@[test]
function test_platform_suffix_for_wasm_file() -> t.Check:
    match resolver.platform_suffix_for_path("a/b/render.wasm.mt"):
        Option.some as p:
            return t.expect_true(p.value == resolver.Platform.wasm)
        Option.none:
            return t.fail("expected wasm suffix")


@[test]
function test_platform_suffix_for_plain_file_is_none() -> t.Check:
    return t.expect_true(resolver.platform_suffix_for_path("a/b/c.mt").is_none())


# =============================================================================
#  infer_module_name
# =============================================================================

@[test]
function test_infer_module_name_under_root() -> t.Check:
    var roots = array[str, 1]("/proj/src")
    var name = resolver.infer_module_name("/proj/src/mtc/lexer/lexer.mt", roots.as_span())
    defer name.release()
    return t.expect_equal_str(name.as_str(), "mtc.lexer.lexer")


@[test]
function test_infer_module_name_strips_platform_suffix() -> t.Check:
    var roots = array[str, 1]("/proj/src")
    var name = resolver.infer_module_name("/proj/src/mtc/fs.linux.mt", roots.as_span())
    defer name.release()
    return t.expect_equal_str(name.as_str(), "mtc.fs")


@[test]
function test_infer_module_name_prefers_longest_root() -> t.Check:
    var roots = array[str, 2]("/proj", "/proj/src")
    var name = resolver.infer_module_name("/proj/src/a/b.mt", roots.as_span())
    defer name.release()
    return t.expect_equal_str(name.as_str(), "a.b")


@[test]
function test_infer_module_name_without_root_uses_stem() -> t.Check:
    var roots = array[str, 1]("/proj/src")
    var name = resolver.infer_module_name("/elsewhere/widget.mt", roots.as_span())
    defer name.release()
    return t.expect_equal_str(name.as_str(), "widget")


# =============================================================================
#  resolve_module_path — failure path (no filesystem needed)
# =============================================================================

@[test]
function test_resolve_module_path_missing_is_error() -> t.Check:
    var roots = array[str, 1]("/nonexistent_root_for_mtc_l1")
    match resolver.resolve_module_path("no.such.module", roots.as_span(), resolver.Platform.linux):
        Result.success as found:
            var resolved = found.value
            resolved.release()
            return t.fail("expected resolution to fail")
        Result.failure as ferr:
            var e = ferr.error
            e.release()
            return t.ok()


# =============================================================================
#  resolve_module_path / resolve_source_path — filesystem integration
# =============================================================================

@[test]
function test_resolve_module_path_finds_existing_file() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l1_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var pkg_dir = path_ops.join(root.as_str(), "a/b")
    defer pkg_dir.release()
    let _mk = fs.create_directories(pkg_dir.as_str()) else:
        return t.fail("could not create dirs")

    var file = path_ops.join(root.as_str(), "a/b/c.mt")
    defer file.release()
    let _wr = fs.write_text(file.as_str(), "pass\n") else:
        return t.fail("could not write file")

    var roots = array[str, 1](root.as_str())
    match resolver.resolve_module_path("a.b.c", roots.as_span(), resolver.Platform.linux):
        Result.success as found:
            var resolved = found.value
            defer resolved.release()
            return t.expect_true(resolved.as_str().ends_with("a/b/c.mt"))
        Result.failure as ferr:
            var e = ferr.error
            e.release()
            return t.fail("expected to resolve a.b.c")


@[test]
function test_resolve_source_path_prefers_platform_variant() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l1_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var base = path_ops.join(root.as_str(), "m.mt")
    defer base.release()
    var linux_file = path_ops.join(root.as_str(), "m.linux.mt")
    defer linux_file.release()
    let _b = fs.write_text(base.as_str(), "pass\n") else:
        return t.fail("could not write base")
    let _v = fs.write_text(linux_file.as_str(), "pass\n") else:
        return t.fail("could not write variant")

    var resolved = resolver.resolve_source_path(base.as_str(), resolver.Platform.linux)
    defer resolved.release()
    return t.expect_true(resolved.as_str().ends_with("m.linux.mt"))


@[test]
function test_resolve_source_path_falls_back_to_plain() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l1_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var base = path_ops.join(root.as_str(), "m.mt")
    defer base.release()
    let _b = fs.write_text(base.as_str(), "pass\n") else:
        return t.fail("could not write base")

    var resolved = resolver.resolve_source_path(base.as_str(), resolver.Platform.linux)
    defer resolved.release()
    return t.expect_true(resolved.as_str().ends_with("m.mt") and not resolved.as_str().ends_with("m.linux.mt"))
