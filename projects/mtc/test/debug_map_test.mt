## In-language tests for the debug-map sidecar (`<binary>.mtdbg.json`).
## Run with: mtc test projects/mtc

import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec

import mtc.debug_map as debug_map
import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver
import mtc.lowering.lowering as lowering


## Remove a temp directory tree and release its owned path string.
function cleanup_dir(dir: ref[string.String]) -> void:
    match fs.remove_tree(dir.as_str()):
        Result.success:
            pass
        Result.failure as f:
            var e = f.error
            e.release()
    dir.release()


## Write `content` to `dir/main.mt`, creating parent directories as needed.
function write_main_file(dir: str, content: str) -> bool:
    var main_path = path_ops.join(dir, "main.mt")
    defer: main_path.release()

    match fs.create_directories(path_ops.dirname(main_path.as_str())):
        Result.failure as f:
            var e = f.error
            e.release()
            return false
        Result.success:
            pass

    match fs.write_text(main_path.as_str(), content):
        Result.failure as f:
            var e = f.error
            e.release()
            return false
        Result.success:
            return true


## Find a function entry by its Milk Tea name.
function find_by_name(map: ref[debug_map.DebugMap], name: str) -> ptr[debug_map.DebugFunction]?:
    var i: ptr_uint = 0
    while i < map.functions.len():
        unsafe:
            let entry_fn = map.functions.get(i)
            if entry_fn != null and read(entry_fn).name.as_str().equal(name):
                return entry_fn
        i += 1
    return null


## Find an entry by name in a function's params/locals vector.
function find_entry(entries: vec.Vec[debug_map.DebugEntry], name: str) -> ptr[debug_map.DebugEntry]?:
    var i: ptr_uint = 0
    while i < entries.len():
        unsafe:
            let entry = entries.get(i)
            if entry != null and read(entry).name.as_str().equal(name):
                return entry
        i += 1
    return null

const SOURCE: str = <<-SRC
    function add(a: int, b: int) -> int:
        let x = a + b
        return x

    function main() -> int:
        return add(1, 2)
    SRC


## Lower SOURCE from a temp directory; the caller owns the returned strings
## (dir, main_path) and must keep them alive while the IR is in use.
function make_program(dir: ref[string.String], main_path: ref[string.String]) -> bool:
    match fs.create_temporary_directory_in_system_temp("mtc_dm_"):
        Result.success as created:
            dir.assign(created.value.as_str())
            created.value.release()
        Result.failure as f:
            var e = f.error
            e.release()
            return false

    if not write_main_file(dir.as_str(), SOURCE):
        return false

    var joined = path_ops.join(dir.as_str(), "main.mt")
    defer: joined.release()
    main_path.assign(joined.as_str())
    return true


@[test]
function test_from_ir_records_params_locals_and_path() -> void:
    var root = string.String.create()
    defer: cleanup_dir(ref_of(root))
    var main_path = string.String.create()
    defer: main_path.release()
    if not make_program(ref_of(root), ref_of(main_path)):
        expect(false, "could not create fixture")
        return

    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()
    var ir_program = lowering.lower(program)

    var binary_path = path_ops.join(root.as_str(), "out/add")
    defer: binary_path.release()
    var map = debug_map.from_ir(ref_of(ir_program), binary_path.as_str())
    defer: debug_map.release(ref_of(map))

    let add_fn = find_by_name(ref_of(map), "add")
    if add_fn == null:
        expect(false, "add missing from map")
        return

    unsafe:
        expect_eq(read(add_fn).params.len(), 2)
        let param_a = read(add_fn).params.get(0) else:
            expect(false, "param a missing")
            return
        let param_b = read(add_fn).params.get(1) else:
            expect(false, "param b missing")
            return
        expect_eq(read(param_a).name.as_str(), "a")
        expect_eq(read(param_b).name.as_str(), "b")
        expect(read(add_fn).path.as_str().ends_with("main.mt"))

        let local_x = find_entry(read(add_fn).locals, "x")
        if local_x == null:
            expect(false, "local x missing from map")
            return
        expect(read(local_x).has_line)

        # The lookup helpers must find the same entries.
        expect(debug_map.function_for_c_name(ref_of(map), read(add_fn).linkage_name.as_str()) == add_fn)
        expect(debug_map.variable_for(
            ref_of(map),
            read(add_fn).linkage_name.as_str(),
            read(local_x).linkage_name.as_str()
        ) == local_x)
        expect(debug_map.source_variable_for(ref_of(map), read(add_fn).linkage_name.as_str(), "x") == local_x)

    # `add` and `main` plus the synthesized C entry wrapper.
    expect(map.functions.len() >= 2)
    expect(map.program_source_path.as_str().ends_with("main.mt"))

    # The synthesized C entry (`cName "main"`) has no source line, like the host.
    let wrapper = debug_map.function_for_c_name(ref_of(map), "main")
    if wrapper == null:
        expect(false, "synthesized main wrapper missing")
        return
    unsafe:
        expect(not read(wrapper).has_line)


@[test]
function test_sidecar_round_trip() -> void:
    var root = string.String.create()
    defer: cleanup_dir(ref_of(root))
    var main_path = string.String.create()
    defer: main_path.release()
    if not make_program(ref_of(root), ref_of(main_path)):
        expect(false, "could not create fixture")
        return

    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()
    var ir_program = lowering.lower(program)

    var binary_path = path_ops.join(root.as_str(), "out/add")
    defer: binary_path.release()
    var map = debug_map.from_ir(ref_of(ir_program), binary_path.as_str())
    defer: debug_map.release(ref_of(map))

    var sidecar = debug_map.sidecar_path_for(binary_path.as_str())
    defer: sidecar.release()
    match debug_map.write(ref_of(map), sidecar.as_str()):
        Result.success:
            pass
        Result.failure as f:
            var e = f.error
            e.release()
            expect(false, "sidecar write failed")
            return

    expect(fs.is_file(sidecar.as_str()))

    match debug_map.load_for_binary(binary_path.as_str()):
        Option.some as loaded_map:
            defer: debug_map.release(ref_of(loaded_map.value))
            expect_eq(loaded_map.value.functions.len(), map.functions.len())

            let add_fn = find_by_name(ref_of(loaded_map.value), "add")
            if add_fn == null:
                expect(false, "add missing after load")
                return
            unsafe:
                expect_eq(read(add_fn).params.len(), 2)
                expect_eq(read(add_fn).locals.len(), 1)
                expect(read(add_fn).path.as_str().ends_with("main.mt"))
                expect(read(add_fn).has_line)
            expect(loaded_map.value.program_source_path.as_str().ends_with("main.mt"))
        Option.none:
            expect(false, "sidecar did not load")

    # A malformed sidecar loads as none instead of failing.
    let _bad = fs.write_text(sidecar.as_str(), "not json")
    expect(debug_map.load_for_binary(binary_path.as_str()).is_none())


@[test]
function test_load_for_missing_binary_is_none() -> void:
    expect(debug_map.load_for_binary("/nonexistent/mtc_debug_map_probe").is_none())
