## In-language tests for the compiler-provided module roots.
## Run with: `mtc test projects/mtc`.
##
## A project outside the compiler's own tree must still resolve `std.*`
## (the compiler's own root, `$MILK_TEA_MODULE_ROOT` / `$MILK_TEA_STD_ROOT`)
## and its own modules (the enclosing `package.toml`'s `source_root`), which is
## what `ModuleRoots.roots_for_path` gives the Ruby host.

import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec

import mtc.loader.package_manifest as package_manifest
import mtc.loader.path_resolver as resolver
import mtc.lsp.workspace as workspace
import mtc.lsp.workspace_index as idx


## Write `content` to `dir/relative`, creating parent directories as needed.
function write_file(dir: str, relative: str, content: str) -> bool:
    var full = path_ops.join(dir, relative)
    defer: full.release()

    match fs.create_directories(path_ops.dirname(full.as_str())):
        Result.failure as f:
            var e = f.error
            e.release()
            return false
        Result.success:
            pass

    match fs.write_text(full.as_str(), content):
        Result.success:
            return true
        Result.failure as f:
            var e = f.error
            e.release()
            return false


function cleanup_dir(dir: ref[string.String]) -> void:
    match fs.remove_tree(dir.as_str()):
        Result.success:
            pass
        Result.failure as f:
            var e = f.error
            e.release()
    dir.release()

# =============================================================================
#  Compiler roots
# =============================================================================


@[test]
function test_compiler_roots_include_the_running_binary_std() -> void:
    ## The test binary lives under `<repo>/build/...`, so the root containing
    ## `std/` next to it must be among the candidates — this is what lets a
    ## project elsewhere in the filesystem resolve `std.*`.
    var candidates = resolver.compiler_root_candidates()
    defer: candidates.release()

    expect(candidates.len() > 0, "expected at least one compiler root")

    var found_std = false
    var i: ptr_uint = 0
    while i < candidates.len():
        let entry = candidates.get(i) else:
            break
        var joined = path_ops.join(unsafe: read(entry).as_str(), "std")
        if fs.is_directory(joined.as_str()):
            found_std = true
        joined.release()
        i += 1

    expect(found_std, "no compiler root contains a std/ directory")


@[test]
function test_module_resolution_from_std_root() -> void:
    ## `std.vec` resolves against the compiler's own root.
    var candidates = resolver.compiler_root_candidates()
    defer: candidates.release()

    var roots = vec.Vec[str].create()
    defer: roots.release()
    var i: ptr_uint = 0
    while i < candidates.len():
        let entry = candidates.get(i) else:
            break
        roots.push(unsafe: read(entry).as_str())
        i += 1

    let resolved = resolver.resolve_module_path("std.vec", roots.as_span(), resolver.Platform.linux)
    match resolved:
        Result.success as path:
            var owned = path.value
            defer: owned.release()
            expect(owned.as_str().ends_with("std/vec.mt"), owned.as_str())
        Result.failure:
            expect(false, "std.vec did not resolve against the compiler roots")

# =============================================================================
#  Package roots
# =============================================================================


@[test]
function test_package_source_root_from_manifest() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_roots_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "package.toml", "[package]\nname = \"demo\"\nsource_root = \"lib\"\n"):
        expect(false, "could not write package.toml")
    if not write_file(root.as_str(), "lib/mod.mt", "public function f() -> int:\n    return 1\n"):
        expect(false, "could not write lib/mod.mt")

    var entry = path_ops.join(root.as_str(), "lib/mod.mt")
    defer: entry.release()

    let source_root = package_manifest.package_source_root_for_path(entry.as_str()) else:
        expect(false, "no package source root found")
        return
    var owned = source_root
    defer: owned.release()

    var expected = path_ops.join(root.as_str(), "lib")
    defer: expected.release()
    expect_eq(owned.as_str(), expected.as_str())


@[test]
function test_package_source_root_defaults_to_src() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_roots_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "package.toml", "[package]\nname = \"demo\"\n"):
        expect(false, "could not write package.toml")
    if not write_file(root.as_str(), "src/main.mt", "function main() -> int:\n    return 0\n"):
        expect(false, "could not write src/main.mt")

    var entry = path_ops.join(root.as_str(), "src/main.mt")
    defer: entry.release()

    let source_root = package_manifest.package_source_root_for_path(entry.as_str()) else:
        expect(false, "no package source root found")
        return
    var owned = source_root
    defer: owned.release()

    var expected = path_ops.join(root.as_str(), "src")
    defer: expected.release()
    expect_eq(owned.as_str(), expected.as_str())


@[test]
function test_package_source_root_absent_without_manifest() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_roots_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "src/main.mt", "function main() -> int:\n    return 0\n"):
        expect(false, "could not write src/main.mt")

    var entry = path_ops.join(root.as_str(), "src/main.mt")
    defer: entry.release()

    expect(package_manifest.package_source_root_for_path(entry.as_str()).is_none(), "unexpected package root")

# =============================================================================
#  Per-file effective roots (the LSP workspace)
# =============================================================================


@[test]
function test_effective_roots_include_enclosing_package_for_file() -> void:
    ## A workspace opened at a monorepo root must still add the *file's*
    ## enclosing package source root, as the host's
    ## `ModuleRoots.roots_for_path(path)` does.  Without it, every
    ## `import pkg.module` in a nested package is reported as missing.
    var root = fs.create_temporary_directory_in_system_temp("mtc_roots_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_file(
        root.as_str(),
        "workspace/pkg/package.toml",
        "[package]\nname = \"pkg\"\nsource_root = \"src\"\n"
    ):
        expect(false, "could not write package.toml")
    if not write_file(root.as_str(), "workspace/pkg/src/mod.mt", "public function f() -> int:\n    return 1\n"):
        expect(false, "could not write mod.mt")

    var ws = workspace.Workspace.create(root.as_str())
    defer: ws.release()

    var entry = path_ops.join(root.as_str(), "workspace/pkg/src/mod.mt")
    defer: entry.release()

    var roots = ws.effective_module_roots_for(entry.as_str())
    defer: roots.release()

    var expected = path_ops.join(root.as_str(), "workspace/pkg/src")
    defer: expected.release()

    var found = false
    var i: ptr_uint = 0
    while i < roots.len():
        let root_ptr = roots.get(i) else:
            break
        if unsafe: read(root_ptr).equal(expected.as_str()):
            found = true
        i += 1

    expect(found, "effective module roots omit the file's package source root")

# =============================================================================
#  Per-file roots in the workspace symbol index
# =============================================================================

function release_owned_paths(paths: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < paths.len():
        let p = paths.get(i) else:
            break
        unsafe: read(p).release()
        i += 1
    paths.release()


@[test]
function test_workspace_index_resolves_nested_package_imports() -> void:
    ## The index's import graph must use each file's package source root, or a
    ## declaration inside a nested package has no dependents and cross-file
    ## references (and the reference-count code lens) stay empty.
    var root = fs.create_temporary_directory_in_system_temp("mtc_roots_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "demo/package.toml", "[package]\nname = \"demo\"\nsource_root = \"src\"\n"):
        expect(false, "could not write package.toml")
    if not write_file(root.as_str(), "demo/src/demo/util.mt", "public function helper() -> int:\n    return 1\n"):
        expect(false, "could not write util.mt")
    if not write_file(
        root.as_str(),
        "demo/src/demo/main.mt",
        "import demo.util\n\npublic function run() -> int:\n    return util.helper()\n"
    ):
        expect(false, "could not write main.mt")

    var walk_roots = vec.Vec[string.String].create()
    defer: release_owned_paths(ref_of(walk_roots))
    walk_roots.push(string.String.from_str(root.as_str()))
    var module_roots = vec.Vec[string.String].create()
    defer: release_owned_paths(ref_of(module_roots))
    module_roots.push(string.String.from_str(root.as_str()))

    var index = idx.build_index(ref_of(walk_roots), ref_of(module_roots))
    defer: idx.release_index(ref_of(index))

    var util_path = path_ops.join(root.as_str(), "demo/src/demo/util.mt")
    defer: util_path.release()
    var deps = idx.dependents_of(ref_of(index), util_path.as_str())
    defer: release_owned_paths(ref_of(deps))

    expect_eq(int<-deps.len(), 1)
    let only = deps.get(0) else:
        expect(false, "missing dependent")
        return
    expect(unsafe: read(only).as_str().ends_with("/demo/src/demo/main.mt"), unsafe: read(only).as_str())
