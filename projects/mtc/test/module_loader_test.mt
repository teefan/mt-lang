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


# =============================================================================
#  Cross-module resolution (L3 + S1)
# =============================================================================

## Build a two-module program (lib + main importing it) and return its Program.
## The caller owns the returned Program and the temp dir handle.
function load_lib_and_main(root: ref[string.String], lib_src: str, main_src: str) -> Option[loader.Program]:
    if not write_file(root.as_str(), "lib.mt", lib_src):
        return Option[loader.Program].none
    if not write_file(root.as_str(), "main.mt", main_src):
        return Option[loader.Program].none

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer main_path.release()
    var roots = array[str, 1](root.as_str())
    return Option[loader.Program].some(value= loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux))


@[test]
function test_cross_module_call_arity_mismatch_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        "public function add(a: int, b: int) -> int:\n    return a + b\n",
        "import lib\n\nfunction run() -> int:\n    return lib.add(1)\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("expects"))


@[test]
function test_cross_module_call_correct_arity_is_clean() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        "public function add(a: int, b: int) -> int:\n    return a + b\n",
        "import lib\n\nfunction run() -> int:\n    return lib.add(1, 2)\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_argument_type_mismatch_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        "public function add(a: int, b: int) -> int:\n    return a + b\n",
        "import lib\n\nfunction run() -> int:\n    return lib.add(true, 2)\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("got bool"))


@[test]
function test_cross_module_return_type_flows_to_caller() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    # lib.flag() returns bool; returning it from an int function must be flagged.
    var program = load_lib_and_main(
        ref_of(root),
        "public function flag() -> bool:\n    return true\n",
        "import lib\n\nfunction run() -> int:\n    return lib.flag()\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("mismatch"))


@[test]
function test_cross_module_call_to_private_is_permissive() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    # `secret` is not public, so it is not exported: the mismatched-arity call
    # must stay permissive rather than be flagged.
    var program = load_lib_and_main(
        ref_of(root),
        "function secret(a: int) -> int:\n    return a\n",
        "import lib\n\nfunction run() -> int:\n    return lib.secret(1, 2, 3)\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_construction_unknown_field_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        "public struct Point:\n    x: int\n    y: int\n",
        "import lib\n\nfunction make() -> int:\n    let p = lib.Point(x = 1, z = 2)\n    return 0\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("unknown field"))


@[test]
function test_cross_module_construction_valid_is_clean() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        "public struct Point:\n    x: int\n    y: int\n",
        "import lib\n\nfunction make() -> int:\n    let p = lib.Point(x = 1, y = 2)\n    return 0\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_value_type_mismatch_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        "public const LIMIT: int = 10\n",
        "import lib\n\nfunction f() -> void:\n    let flag: bool = lib.LIMIT\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("cannot assign"))


@[test]
function test_cross_module_value_correct_type_is_clean() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        "public const LIMIT: int = 10\n",
        "import lib\n\nfunction f() -> void:\n    let n: int = lib.LIMIT\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_private_value_is_permissive() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    # SECRET is not public, so it is not exported: a mismatched assignment from
    # it must stay permissive rather than be flagged.
    var program = load_lib_and_main(
        ref_of(root),
        "const SECRET: int = 42\n",
        "import lib\n\nfunction f() -> void:\n    let flag: bool = lib.SECRET\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_enum_member_valid_is_clean() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        "public enum Color: ubyte\n    red = 0\n    green = 1\n",
        "import lib\n\nfunction f() -> void:\n    let c = lib.Color.green\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_enum_unknown_member_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        "public enum Color: ubyte\n    red = 0\n    green = 1\n",
        "import lib\n\nfunction f() -> void:\n    let c = lib.Color.purple\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("unknown member"))


@[test]
function test_cross_module_variant_arm_valid_is_clean() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        "public variant Token:\n    ident(name: str)\n    eof\n",
        "import lib\n\nfunction f() -> void:\n    let t = lib.Token.ident(name = \"x\")\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_variant_unknown_arm_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        "public variant Token:\n    ident(name: str)\n    eof\n",
        "import lib\n\nfunction f() -> void:\n    let t = lib.Token.bad\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("unknown member"))


@[test]
function test_cross_module_private_enum_member_is_permissive() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    # Color is not public, so its members are not exported: unknown-member access
    # must stay permissive rather than be flagged.
    var program = load_lib_and_main(
        ref_of(root),
        "enum Color: ubyte\n    red = 0\n",
        "import lib\n\nfunction f() -> void:\n    let c = lib.Color.purple\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)


# =============================================================================
#  Imported methods and imported-typed field access
# =============================================================================

const POINT_LIB: str = <<-SRC
public struct Point:
    x: int
    y: int

extending Point:
    public function magnitude() -> int:
        return this.x + this.y
SRC


@[test]
function test_cross_module_method_call_valid_is_clean() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        POINT_LIB,
        "import lib\n\nfunction f() -> int:\n    let p = lib.Point(x = 1, y = 2)\n    return p.magnitude()\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_unknown_method_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        POINT_LIB,
        "import lib\n\nfunction f() -> int:\n    let p = lib.Point(x = 1, y = 2)\n    return p.bogus()\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("unknown method"))


@[test]
function test_cross_module_field_access_valid_is_clean() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        POINT_LIB,
        "import lib\n\nfunction f() -> int:\n    let p = lib.Point(x = 1, y = 2)\n    return p.x\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_field_type_flows_to_caller() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    # p.x is int; returning it from a bool function must be flagged.
    var program = load_lib_and_main(
        ref_of(root),
        POINT_LIB,
        "import lib\n\nfunction f() -> bool:\n    let p = lib.Point(x = 1, y = 2)\n    return p.x\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("mismatch"))


@[test]
function test_cross_module_unknown_field_access_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        POINT_LIB,
        "import lib\n\nfunction f() -> int:\n    let p = lib.Point(x = 1, y = 2)\n    return p.z\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("unknown field"))


@[test]
function test_cross_module_private_method_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    # `secret` is not public, so it is not exported and cannot be called from
    # another module: the call must be flagged as an unknown method.
    var program = load_lib_and_main(
        ref_of(root),
        "public struct Point:\n    x: int\n\nextending Point:\n    function secret() -> int:\n        return this.x\n",
        "import lib\n\nfunction f() -> int:\n    let p = lib.Point(x = 1)\n    return p.secret()\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("unknown method"))


const ADDER_LIB: str = <<-SRC
public struct Adder:
    base: int

extending Adder:
    public static function make(start: int) -> Adder:
        return Adder(base = start)

    public function add(a: int, b: int) -> int:
        return this.base + a + b

    public function total() -> int:
        return this.base
SRC


@[test]
function test_cross_module_method_arity_mismatch_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        ADDER_LIB,
        "import lib\n\nfunction f() -> int:\n    let x = lib.Adder(base = 0)\n    return x.add(1)\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("expects"))


@[test]
function test_cross_module_method_arg_type_mismatch_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        ADDER_LIB,
        "import lib\n\nfunction f() -> int:\n    let x = lib.Adder(base = 0)\n    return x.add(true, 2)\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("got bool"))


@[test]
function test_cross_module_method_correct_call_is_clean() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        ADDER_LIB,
        "import lib\n\nfunction f() -> int:\n    let x = lib.Adder(base = 0)\n    return x.add(1, 2)\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_method_return_type_flows() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    # total() returns int; returning it from a bool function must be flagged.
    var program = load_lib_and_main(
        ref_of(root),
        ADDER_LIB,
        "import lib\n\nfunction f() -> bool:\n    let x = lib.Adder(base = 0)\n    return x.total()\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("mismatch"))


@[test]
function test_cross_module_static_method_valid_is_clean() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        ADDER_LIB,
        "import lib\n\nfunction f() -> int:\n    let a = lib.Adder.make(5)\n    return 0\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_static_method_arity_mismatch_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        ADDER_LIB,
        "import lib\n\nfunction f() -> int:\n    let a = lib.Adder.make()\n    return 0\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("expects"))


@[test]
function test_cross_module_unknown_static_method_is_flagged() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    var program = load_lib_and_main(
        ref_of(root),
        ADDER_LIB,
        "import lib\n\nfunction f() -> int:\n    let a = lib.Adder.bogus()\n    return 0\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_true(program.has_diagnostic_containing("unknown method"))


@[test]
function test_loop_local_shadowing_import_alias_is_clean() -> t.Check:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        return t.fail("could not create temp dir")
    defer cleanup_dir(ref_of(root))

    # A loop-local `lib` shadows the import alias inside the loop; after the loop
    # the alias must be visible again so lib.Thing(...) is a construction, not a
    # method call on a leaked Thing value. Regression test for block scoping.
    var program = load_lib_and_main(
        ref_of(root),
        "public struct Thing:\n    n: int\n",
        "import lib\n\nfunction f() -> int:\n    var i: int = 0\n    while i < 3:\n        let lib = lib.Thing(n = i)\n        i += 1\n    let after = lib.Thing(n = 9)\n    return 0\n",
    ) else:
        return t.fail("could not load program")
    defer program.release()

    return t.expect_equal_int(int<-program.diagnostic_count(), 0)
