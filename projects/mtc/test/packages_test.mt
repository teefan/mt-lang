# In-language tests for the package subsystem (`lib/milk_tea/packages/*`):
# manifest parsing, the dependency graph, and deterministic lockfiles.
# Run with: mtc test projects/mtc/test/packages_test.mt

import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string

import mtc.packages.graph as graph
import mtc.packages.lock as lock
import mtc.packages.manifest as manifest
import mtc.packages.source as source


function make_temp(prefix: str) -> string.String:
    return fs.create_temporary_directory_in_system_temp(prefix).expect("temp directory")


function write_file(path: str, content: str) -> void:
    fs.write_text(path, content).expect("write fixture")


function remove_temp(dir: ref[string.String]) -> void:
    match fs.remove_tree(dir.as_str()):
        Result.success:
            pass
        Result.failure as failure:
            var error = failure.error
            error.release()
    dir.release()


@[test]
function test_manifest_default_name_and_source_root() -> void:
    var dir = make_temp("mt-pkg-manifest-")
    defer: remove_temp(ref_of(dir))
    var src = path_ops.join(dir.as_str(), "src")
    fs.create_directories(src.as_str()).expect("src")
    src.release()
    var main_file = path_ops.join(dir.as_str(), "src/main.mt")
    write_file(main_file.as_str(), "function main() -> int:\n    return 0\n")
    main_file.release()
    var toml = path_ops.join(dir.as_str(), "package.toml")
    write_file(toml.as_str(), "[package]\nversion = \"0.1.0\"\n\n[build]\nentry = \"src/main.mt\"\n")
    toml.release()

    var loaded = manifest.load(dir.as_str()).expect("manifest")
    defer: loaded.release()
    expect(loaded.package_kind == manifest.PackageKind.application)
    expect(loaded.package_version.is_some())
    var source_root = loaded.source_root.as_str()
    var expected = path_ops.join(dir.as_str(), "src")
    defer: expected.release()
    expect(source_root.equal(expected.as_str()))


@[test]
function test_manifest_parses_registry_and_path_dependencies() -> void:
    var dir = make_temp("mt-pkg-deps-")
    defer: remove_temp(ref_of(dir))
    var src = path_ops.join(dir.as_str(), "src")
    fs.create_directories(src.as_str()).expect("src")
    src.release()
    var main_file = path_ops.join(dir.as_str(), "src/main.mt")
    write_file(main_file.as_str(), "function main() -> int:\n    return 0\n")
    main_file.release()
    var lib = path_ops.join(dir.as_str(), "../lib")
    fs.create_directories(lib.as_str()).expect("lib")
    lib.release()

    var toml = path_ops.join(dir.as_str(), "package.toml")
    write_file(
        toml.as_str(),
        "[package]\nname = \"demo\"\nsource_root = \"src\"\n\n[dependencies]\n\"ui\" = \"1.2.3\"\nlib = { path = \"../lib\", version = \">=1.0.0\" }\n"
    )
    toml.release()

    var loaded = manifest.load(dir.as_str()).expect("manifest")
    defer: loaded.release()
    expect(loaded.dependencies.len() == 2)
    let first = loaded.dependencies.get(0) else:
        expect(false, "first dependency")
        return
    expect(unsafe: read(first).registry())
    expect(unsafe: read(first).exact_registry_version())
    let second = loaded.dependencies.get(1) else:
        expect(false, "second dependency")
        return
    expect(unsafe: read(second).path_dependency())
    expect(not unsafe: read(second).registry())


@[test]
function test_manifest_rejects_conflicting_git_and_version() -> void:
    var dir = make_temp("mt-pkg-bad-")
    defer: remove_temp(ref_of(dir))
    var toml = path_ops.join(dir.as_str(), "package.toml")
    write_file(
        toml.as_str(),
        "[package]\nname = \"demo\"\nsource_root = \".\"\n\n[dependencies]\nlib = { git = \"https://example.com/lib.git\", rev = \"deadbeef\", version = \"1.0.0\" }\n"
    )
    toml.release()

    match manifest.load(dir.as_str()):
        Result.failure as failure:
            var message = failure.error
            defer: message.release()
            expect(message.as_str().contains_substring("cannot combine version with git resolution"))
        Result.success as payload:
            var loaded = payload.value
            loaded.release()
            expect(false, "conflicting dependency should fail")


@[test]
function test_graph_tree_and_source_roots() -> void:
    var dir = make_temp("mt-pkg-graph-")
    defer: remove_temp(ref_of(dir))

    var lib = path_ops.join(dir.as_str(), "lib")
    var lib_src = path_ops.join(lib.as_str(), "src")
    fs.create_directories(lib_src.as_str()).expect("lib src")
    lib_src.release()
    var lib_main = path_ops.join(lib.as_str(), "src/lib.mt")
    write_file(lib_main.as_str(), "public function twice(x: int) -> int:\n    return x * 2\n")
    lib_main.release()
    var lib_toml = path_ops.join(lib.as_str(), "package.toml")
    write_file(lib_toml.as_str(), "[package]\nname = \"demo.lib\"\nversion = \"1.0.0\"\nkind = \"library\"\nsource_root = \"src\"\n")
    lib_toml.release()
    lib.release()

    var app = path_ops.join(dir.as_str(), "app")
    var app_src = path_ops.join(app.as_str(), "src")
    fs.create_directories(app_src.as_str()).expect("app src")
    app_src.release()
    var app_main = path_ops.join(app.as_str(), "src/main.mt")
    write_file(app_main.as_str(), "function main() -> int:\n    return 0\n")
    app_main.release()
    var app_toml = path_ops.join(app.as_str(), "package.toml")
    write_file(
        app_toml.as_str(),
        "[package]\nname = \"demo.app\"\nversion = \"0.1.0\"\nsource_root = \"src\"\n\n[build]\nentry = \"src/main.mt\"\n\n[dependencies]\n\"demo.lib\" = { path = \"../lib\" }\n"
    )
    app_toml.release()

    var resolver = source.create_resolver(source.ResolutionMode.materialize)
    defer: resolver.release()
    var loaded = graph.load(app.as_str(), ref_of(resolver)).expect("graph")
    defer: loaded.release()

    var tree = graph.tree_text(ref_of(loaded))
    defer: tree.release()
    expect(tree.as_str().starts_with("demo.app"))
    expect(tree.as_str().contains_substring("demo.lib"))

    var roots = graph.source_roots(ref_of(loaded))
    defer: source.release_strings(ref_of(roots))
    expect(roots.len() == 2)
    app.release()


@[test]
function test_lock_round_trip_and_check() -> void:
    var dir = make_temp("mt-pkg-lock-")
    defer: remove_temp(ref_of(dir))
    var src = path_ops.join(dir.as_str(), "src")
    fs.create_directories(src.as_str()).expect("src")
    src.release()
    var main_file = path_ops.join(dir.as_str(), "src/main.mt")
    write_file(main_file.as_str(), "function main() -> int:\n    return 0\n")
    main_file.release()
    var toml = path_ops.join(dir.as_str(), "package.toml")
    write_file(toml.as_str(), "[package]\nname = \"demo\"\nversion = \"0.1.0\"\nsource_root = \"src\"\n\n[build]\nentry = \"src/main.mt\"\n")
    toml.release()

    var resolver = source.create_resolver(source.ResolutionMode.materialize)
    defer: resolver.release()
    var lock_path = lock.write(dir.as_str(), ref_of(resolver)).expect("write lock")
    defer: lock_path.release()

    var first_content = fs.read_text(lock_path.as_str()).expect("read lock")
    defer: first_content.release()
    expect(first_content.as_str().starts_with("schema_version = 2\nroot_package = \"demo\"\n"))

    var check = lock.check(dir.as_str(), ref_of(resolver)).expect("check lock")
    defer: check.release()
    expect(check.current())

    var locked_graph = lock.load_graph(dir.as_str(), ref_of(resolver)).expect("locked graph")
    defer: locked_graph.release()
    expect(graph.node_count(ref_of(locked_graph)) == 1)
