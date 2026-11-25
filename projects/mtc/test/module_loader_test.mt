# In-language tests for the multi-file program loader of the self-hosted mtc
# compiler.  Run with: mtc test projects/mtc/test/module_loader_test.mt

import std.fs as fs
import std.map as map_mod
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
    defer: full.release()

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

# =============================================================================
#  Shared source strings — every inline module source is a heredoc so tests
#  are readable and maintainable without embedded \n escapes.
# =============================================================================

# --- single-module helpers (lines 47–180) ---

const S_MOD_MAIN_IMPORT_FOO: str = <<-SRC
import foo

function run() -> int:
    return 0
SRC

const S_MOD_HELPER: str = <<-SRC
function helper() -> int:
    return 1
SRC

const S_MOD_MAIN_IMPORT_A_B: str = <<-SRC
import a
import b

function run() -> int:
    return 0
SRC

const S_MOD_A_IMPORT_C: str = <<-SRC
import c

function fa() -> int:
    return 1
SRC

const S_MOD_B_IMPORT_C: str = <<-SRC
import c

function fb() -> int:
    return 2
SRC

const S_MOD_C: str = <<-SRC
function fc() -> int:
    return 3
SRC

const S_MOD_A_IMPORT_B: str = <<-SRC
import b

function fa() -> int:
    return 1
SRC

const S_MOD_B_IMPORT_A: str = <<-SRC
import a

function fb() -> int:
    return 2
SRC

const S_MOD_MAIN_IMPORT_GHOST: str = <<-SRC
import ghost

function run() -> int:
    return 0
SRC

const S_MOD_MAIN_BOOL_RETURN: str = <<-SRC
function f() -> int:
    return true
SRC

const S_MOD_MAIN_CLEAN: str = <<-SRC
function f() -> int:
    return 0
SRC

# --- cross-module lib sources (load_lib_and_main) ---

const LIB_ADD: str = <<-SRC
public function add(a: int, b: int) -> int:
    return a + b
SRC

const LIB_FLAG: str = <<-SRC
public function flag() -> bool:
    return true
SRC

const LIB_SECRET: str = <<-SRC
function secret(a: int) -> int:
    return a
SRC

const LIB_POINT: str = <<-SRC
public struct Point:
    x: int
    y: int
SRC

const LIB_POINT_EXTENDED: str = <<-SRC
public struct Point:
    x: int
    y: int

extending Point:
    public function magnitude() -> int:
        return this.x + this.y
SRC

const LIB_POINT_PRIVATE_METHOD: str = <<-SRC
public struct Point:
    x: int

extending Point:
    function secret() -> int:
        return this.x
SRC

const LIB_LIMIT: str = <<-SRC
public const LIMIT: int = 10
SRC

const LIB_SECRET_CONST: str = <<-SRC
const SECRET: int = 42
SRC

const LIB_COLOR: str = <<-SRC
public enum Color: ubyte
    red = 0
    green = 1
SRC

const LIB_COLOR_PRIVATE: str = <<-SRC
enum Color: ubyte
    red = 0
SRC

const LIB_TOKEN: str = <<-SRC
public variant Token:
    ident(name: str)
    eof
SRC

const LIB_ADDER: str = <<-SRC
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

const LIB_THING: str = <<-SRC
public struct Thing:
    n: int
SRC

const LIB_UNUSED: str = <<-SRC
public function unused() -> int:
    return 0
SRC

const LIB_UNUSED_STR_FIRST_BYTE: str = <<-SRC
public function unused() -> int:
    return 0

extending str:
    public function first_byte() -> ubyte:
        return 0
SRC

const LIB_DRAWABLE_INTERFACE: str = <<-SRC
public interface Drawable:
    function draw() -> int
SRC

const LIB_DRAWABLE_WIDGET_PLAIN: str = <<-SRC
public interface Drawable:
    function draw() -> int

public struct Widget implements Drawable:
    w: int

extending Widget:
    public function draw() -> int:
        return this.w

public struct Plain:
    p: int
SRC

const LIB_DRAWABLE_PLAIN: str = <<-SRC
public interface Drawable:
    function draw() -> int

public struct Plain:
    p: int
SRC

const LIB_WIDGET: str = <<-SRC
public struct Widget:
    w: int

extending Widget:
    public function draw() -> int:
        return this.w
SRC

const LIB_HOLDER_GENERIC: str = <<-SRC
public struct Holder[T]:
    value: T

extending Holder[T]:
    public function get() -> T:
        return this.value
SRC

const LIB_CONTAINER_STATIC: str = <<-SRC
public struct Container:
    value: int

extending Container:
    public static function make(v: int) -> Container:
        return Container(value = v)
SRC

const LIB_DAMAGEABLE: str = <<-SRC
public interface Damageable:
    function is_alive() -> bool
SRC

# --- cross-module main sources (load_lib_and_main) ---

const MAIN_ADD_ARITY: str = <<-SRC
import lib

function run() -> int:
    return lib.add(1)
SRC

const MAIN_ADD_CORRECT: str = <<-SRC
import lib

function run() -> int:
    return lib.add(1, 2)
SRC

const MAIN_ADD_TYPE: str = <<-SRC
import lib

function run() -> int:
    return lib.add(true, 2)
SRC

const MAIN_FLAG_RETURN: str = <<-SRC
import lib

function run() -> int:
    return lib.flag()
SRC

const MAIN_SECRET_ARITY: str = <<-SRC
import lib

function run() -> int:
    return lib.secret(1, 2, 3)
SRC

const MAIN_POINT_BAD_FIELD: str = <<-SRC
import lib

function make() -> int:
    let p = lib.Point(x = 1, z = 2)
    return 0
SRC

const MAIN_POINT_CORRECT: str = <<-SRC
import lib

function make() -> int:
    let p = lib.Point(x = 1, y = 2)
    return 0
SRC

const MAIN_LIMIT_BOOL: str = <<-SRC
import lib

function f() -> void:
    let flag: bool = lib.LIMIT
SRC

const MAIN_LIMIT_INT: str = <<-SRC
import lib

function f() -> void:
    let n: int = lib.LIMIT
SRC

const MAIN_SECRET_CONST_BOOL: str = <<-SRC
import lib

function f() -> void:
    let flag: bool = lib.SECRET
SRC

const MAIN_COLOR_VALID: str = <<-SRC
import lib

function f() -> void:
    let c = lib.Color.green
SRC

const MAIN_COLOR_BAD: str = <<-SRC
import lib

function f() -> void:
    let c = lib.Color.purple
SRC

const MAIN_TOKEN_VALID: str = <<-SRC
import lib

function f() -> void:
    let t = lib.Token.ident(name = "x")
SRC

const MAIN_TOKEN_BAD: str = <<-SRC
import lib

function f() -> void:
    let t = lib.Token.bad
SRC

const MAIN_POINT_MAGNITUDE: str = <<-SRC
import lib

function f() -> int:
    let p = lib.Point(x = 1, y = 2)
    return p.magnitude()
SRC

const MAIN_POINT_BOGUS: str = <<-SRC
import lib

function f() -> int:
    let p = lib.Point(x = 1, y = 2)
    return p.bogus()
SRC

const MAIN_POINT_FIELD_X: str = <<-SRC
import lib

function f() -> int:
    let p = lib.Point(x = 1, y = 2)
    return p.x
SRC

const MAIN_POINT_FIELD_X_BOOL: str = <<-SRC
import lib

function f() -> bool:
    let p = lib.Point(x = 1, y = 2)
    return p.x
SRC

const MAIN_POINT_FIELD_Z: str = <<-SRC
import lib

function f() -> int:
    let p = lib.Point(x = 1, y = 2)
    return p.z
SRC

const MAIN_POINT_SECRET: str = <<-SRC
import lib

function f() -> int:
    let p = lib.Point(x = 1)
    return p.secret()
SRC

const MAIN_ADDER_ADD_ARITY: str = <<-SRC
import lib

function f() -> int:
    let x = lib.Adder(base = 0)
    return x.add(1)
SRC

const MAIN_ADDER_ADD_TYPE: str = <<-SRC
import lib

function f() -> int:
    let x = lib.Adder(base = 0)
    return x.add(true, 2)
SRC

const MAIN_ADDER_ADD_CORRECT: str = <<-SRC
import lib

function f() -> int:
    let x = lib.Adder(base = 0)
    return x.add(1, 2)
SRC

const MAIN_ADDER_TOTAL_BOOL: str = <<-SRC
import lib

function f() -> bool:
    let x = lib.Adder(base = 0)
    return x.total()
SRC

const MAIN_ADDER_MAKE_VALID: str = <<-SRC
import lib

function f() -> int:
    let a = lib.Adder.make(5)
    return 0
SRC

const MAIN_ADDER_MAKE_ARITY: str = <<-SRC
import lib

function f() -> int:
    let a = lib.Adder.make()
    return 0
SRC

const MAIN_ADDER_BOGUS: str = <<-SRC
import lib

function f() -> int:
    let a = lib.Adder.bogus()
    return 0
SRC

const MAIN_THING_SHADOW: str = <<-SRC
import lib

function f() -> int:
    var i: int = 0
    while i < 3:
        let lib = lib.Thing(n = i)
        i += 1
    let after = lib.Thing(n = 9)
    return 0
SRC

const MAIN_DRAWABLE_SPRITE: str = <<-SRC
import lib

struct Sprite implements lib.Drawable:
    x: int

extending Sprite:
    function draw() -> int:
        return this.x
SRC

const MAIN_DRAWABLE_MISSING: str = <<-SRC
import lib

struct Sprite implements lib.Drawable:
    x: int

extending Sprite:
    function other() -> int:
        return this.x
SRC

const MAIN_STR_FIRST_BYTE_BOOL: str = <<-SRC
import lib

function f(s: str) -> bool:
    return s.first_byte()
SRC

const MAIN_STR_MYSTERY: str = <<-SRC
import lib

function f(s: str) -> void:
    s.mystery()
SRC

const MAIN_DAMAGEABLE_LOCAL: str = <<-SRC
import lib

struct NPC implements lib.Damageable:
    hp: int

extending NPC:
    function is_alive() -> bool:
        return this.hp > 0

function hurt[T implements lib.Damageable](target: ref[T]) -> void:
    pass

function f() -> void:
    var n: NPC
    hurt(n)
SRC

const MAIN_DAMAGEABLE_ROCK: str = <<-SRC
import lib

struct Rock:
    weight: int

function hurt[T implements lib.Damageable](target: ref[T]) -> void:
    pass

function f() -> void:
    var r: Rock
    hurt(r)
SRC

const MAIN_DRAWABLE_WIDGET_VALID: str = <<-SRC
import lib

function render[T implements lib.Drawable](x: ref[T]) -> void:
    pass

function f() -> void:
    var widget = lib.Widget(w = 0)
    render(widget)
SRC

const MAIN_DRAWABLE_PLAIN_FLAGGED: str = <<-SRC
import lib

function render[T implements lib.Drawable](x: ref[T]) -> void:
    pass

function f() -> void:
    var plain = lib.Plain(p = 0)
    render(plain)
SRC

const MAIN_DRAWABLE_EXPLICIT: str = <<-SRC
import lib

function render[T implements lib.Drawable](x: ref[T]) -> void:
    pass

function f() -> void:
    var plain = lib.Plain(p = 0)
    render[lib.Plain](ref_of(plain))
SRC

const MAIN_WIDGET_BOGUS: str = <<-SRC
import lib

function use(w: lib.Widget) -> int:
    return w.no_such_method()
SRC

const MAIN_WIDGET_DRAW: str = <<-SRC
import lib

function use(w: lib.Widget) -> int:
    return w.draw()
SRC

const MAIN_COLOR_MISSING_GREEN: str = <<-SRC
import lib

function f(c: lib.Color) -> int:
    match c:
        lib.Color.red:
            return 1
SRC

const MAIN_COLOR_EXHAUSTIVE: str = <<-SRC
import lib

function f(c: lib.Color) -> int:
    match c:
        lib.Color.red:
            return 1
        lib.Color.green:
            return 2
SRC

const MAIN_HOLDER_GET: str = <<-SRC
import lib

function run(val: lib.Holder[int]) -> int:
    return val.get()
SRC

const MAIN_CONTAINER_MAKE: str = <<-SRC
import lib

function run() -> lib.Container:
    return lib.Container.make(42)
SRC


@[test]
function test_loads_root_and_dependency() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l2_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "main.mt", S_MOD_MAIN_IMPORT_FOO):
        expect(false, "could not write main")
    if not write_file(root.as_str(), "foo.mt", S_MOD_HELPER):
        expect(false, "could not write foo")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    if program.module_count() != 2:
        expect(false, "expected 2 modules")
    if program.diagnostic_count() != 0:
        expect(false, "expected no diagnostics")

    # dependency-first order: foo is checked before main
    match program.ordered_name(0):
        Option.some as first:
            if not first.value.equal("foo"):
                expect(false, "expected foo first in dependency order")
        Option.none:
            expect(false, "missing order position 0")
    return


@[test]
function test_diamond_dependency_loaded_once() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l2_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "main.mt", S_MOD_MAIN_IMPORT_A_B):
        expect(false, "could not write main")
    if not write_file(root.as_str(), "a.mt", S_MOD_A_IMPORT_C):
        expect(false, "could not write a")
    if not write_file(root.as_str(), "b.mt", S_MOD_B_IMPORT_C):
        expect(false, "could not write b")
    if not write_file(root.as_str(), "c.mt", S_MOD_C):
        expect(false, "could not write c")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    if program.diagnostic_count() != 0:
        expect(false, "expected no diagnostics")
    expect_eq(int<-program.module_count(), 4)


@[test]
function test_import_cycle_is_loaded() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l2_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "a.mt", S_MOD_A_IMPORT_B):
        expect(false, "could not write a")
    if not write_file(root.as_str(), "b.mt", S_MOD_B_IMPORT_A):
        expect(false, "could not write b")

    var root_path = path_ops.join(root.as_str(), "a.mt")
    defer: root_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(root_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    if program.diagnostic_count() != 0:
        expect(false, "expected no diagnostics for a resolvable cycle")
    expect_eq(int<-program.module_count(), 2)
    expect_eq(int<-program.analyses.len(), 2)


@[test]
function test_missing_import_is_reported() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l2_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "main.mt", S_MOD_MAIN_IMPORT_GHOST):
        expect(false, "could not write main")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    if program.module_count() != 1:
        expect(false, "expected only the root module to load")
    expect(program.has_diagnostic_containing("not found"))


@[test]
function test_semantic_error_is_surfaced() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l2_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "main.mt", S_MOD_MAIN_BOOL_RETURN):
        expect(false, "could not write main")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    expect(program.has_diagnostic_containing("mismatch"))


@[test]
function test_clean_program_has_no_diagnostics() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l2_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_file(root.as_str(), "main.mt", S_MOD_MAIN_CLEAN):
        expect(false, "could not write main")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    if program.module_count() != 1:
        expect(false, "expected 1 module")
    expect_eq(int<-program.diagnostic_count(), 0)

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
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    return Option[loader.Program].some(value= loader.check_program(
        main_path.as_str(),
        roots.as_span(),
        resolver.Platform.linux
    ))


@[test]
function test_cross_module_call_arity_mismatch_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_ADD, MAIN_ADD_ARITY) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("expects"))


@[test]
function test_cross_module_call_correct_arity_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_ADD, MAIN_ADD_CORRECT) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_argument_type_mismatch_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_ADD, MAIN_ADD_TYPE) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("got bool"))


@[test]
function test_cross_module_return_type_flows_to_caller() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    # lib.flag() returns bool; returning it from an int function must be flagged.
    var program = load_lib_and_main(ref_of(root), LIB_FLAG, MAIN_FLAG_RETURN) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("mismatch"))


@[test]
function test_cross_module_call_to_private_is_permissive() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    # `secret` is not public, so it is not exported: the mismatched-arity call
    # must stay permissive rather than be flagged.
    var program = load_lib_and_main(ref_of(root), LIB_SECRET, MAIN_SECRET_ARITY) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_construction_unknown_field_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_POINT, MAIN_POINT_BAD_FIELD) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("unknown field"))


@[test]
function test_cross_module_construction_valid_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_POINT, MAIN_POINT_CORRECT) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_value_type_mismatch_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_LIMIT, MAIN_LIMIT_BOOL) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("cannot assign"))


@[test]
function test_cross_module_value_correct_type_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_LIMIT, MAIN_LIMIT_INT) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_private_value_is_permissive() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    # SECRET is not public, so it is not exported: a mismatched assignment from
    # it must stay permissive rather than be flagged.
    var program = load_lib_and_main(ref_of(root), LIB_SECRET_CONST, MAIN_SECRET_CONST_BOOL) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_enum_member_valid_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_COLOR, MAIN_COLOR_VALID) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_enum_unknown_member_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_COLOR, MAIN_COLOR_BAD) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("unknown member"))


@[test]
function test_cross_module_variant_arm_valid_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_TOKEN, MAIN_TOKEN_VALID) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_variant_unknown_arm_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_TOKEN, MAIN_TOKEN_BAD) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("unknown member"))


@[test]
function test_cross_module_private_enum_member_is_permissive() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    # Color is not public, so its members are not exported: unknown-member access
    # must stay permissive rather than be flagged.
    var program = load_lib_and_main(ref_of(root), LIB_COLOR_PRIVATE, MAIN_COLOR_BAD) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)

# =============================================================================
#  Imported methods and imported-typed field access
# =============================================================================


@[test]
function test_cross_module_method_call_valid_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_POINT_EXTENDED, MAIN_POINT_MAGNITUDE) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_unknown_method_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_POINT_EXTENDED, MAIN_POINT_BOGUS) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("unknown method"))


@[test]
function test_cross_module_field_access_valid_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_POINT_EXTENDED, MAIN_POINT_FIELD_X) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_field_type_flows_to_caller() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    # p.x is int; returning it from a bool function must be flagged.
    var program = load_lib_and_main(ref_of(root), LIB_POINT_EXTENDED, MAIN_POINT_FIELD_X_BOOL) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("mismatch"))


@[test]
function test_cross_module_unknown_field_access_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_POINT_EXTENDED, MAIN_POINT_FIELD_Z) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("unknown field"))


@[test]
function test_cross_module_private_method_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    # `secret` is not public, so it is not exported and cannot be called from
    # another module: the call must be flagged as an unknown method.
    var program = load_lib_and_main(ref_of(root), LIB_POINT_PRIVATE_METHOD, MAIN_POINT_SECRET) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("unknown method"))


@[test]
function test_cross_module_method_arity_mismatch_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_ADDER, MAIN_ADDER_ADD_ARITY) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("expects"))


@[test]
function test_cross_module_method_arg_type_mismatch_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_ADDER, MAIN_ADDER_ADD_TYPE) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("got bool"))


@[test]
function test_cross_module_method_correct_call_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_ADDER, MAIN_ADDER_ADD_CORRECT) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_method_return_type_flows() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    # total() returns int; returning it from a bool function must be flagged.
    var program = load_lib_and_main(ref_of(root), LIB_ADDER, MAIN_ADDER_TOTAL_BOOL) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("mismatch"))


@[test]
function test_cross_module_static_method_valid_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_ADDER, MAIN_ADDER_MAKE_VALID) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_static_method_arity_mismatch_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_ADDER, MAIN_ADDER_MAKE_ARITY) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("expects"))


@[test]
function test_cross_module_unknown_static_method_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_ADDER, MAIN_ADDER_BOGUS) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("unknown method"))


@[test]
function test_loop_local_shadowing_import_alias_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    # A loop-local `lib` shadows the import alias inside the loop; after the loop
    # the alias must be visible again so lib.Thing(...) is a construction, not a
    # method call on a leaked Thing value. Regression test for block scoping.
    var program = load_lib_and_main(ref_of(root), LIB_THING, MAIN_THING_SHADOW) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_interface_conformance_valid_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_DRAWABLE_INTERFACE, MAIN_DRAWABLE_SPRITE) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_interface_missing_method_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_DRAWABLE_INTERFACE, MAIN_DRAWABLE_MISSING) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("does not implement"))

# =============================================================================
#  S3b-1: str / primitive method resolution across all reachable bindings.
#  A str method lives in whichever module extended str; it is found only by the
#  whole-program binding search, so its argument types and return type flow.
# =============================================================================


@[test]
function test_str_method_return_type_flows_cross_module() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    # `strext` extends str with first_byte() -> ubyte; main misuses that ubyte
    # result as a bool. Resolving first_byte requires searching strext's binding.
    var program = load_lib_and_main(ref_of(root), LIB_UNUSED_STR_FIRST_BYTE, MAIN_STR_FIRST_BYTE_BOOL) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("got ubyte"))


@[test]
function test_unknown_str_method_is_permissive() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    # No module provides str.mystery, and str's method set is not fully owned, so
    # the call stays permissive rather than being flagged.
    var program = load_lib_and_main(ref_of(root), LIB_UNUSED, MAIN_STR_MYSTERY) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)

# =============================================================================
#  S3b-4: cross-module generic constraint satisfaction. A constraint interface
#  imported as lib.Iface is matched by identity; a local struct implementing it
#  (Case A) and an imported struct argument (Case B) are both checkable.
# =============================================================================


@[test]
function test_cross_module_constraint_satisfied_local_struct_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_DAMAGEABLE, MAIN_DAMAGEABLE_LOCAL) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_cross_module_constraint_unsatisfied_local_struct_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_DAMAGEABLE, MAIN_DAMAGEABLE_ROCK) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("does not implement"))


@[test]
function test_imported_struct_arg_unsatisfied_constraint_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_DRAWABLE_WIDGET_PLAIN, MAIN_DRAWABLE_PLAIN_FLAGGED) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("does not implement"))


@[test]
function test_imported_struct_arg_satisfied_constraint_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_WIDGET, MAIN_DRAWABLE_WIDGET_VALID) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)

# =============================================================================
#  Phase 1 item A: cross-module type-position resolution. `lib.Type` in a type
#  annotation or explicit type argument resolves to the concrete imported type,
#  so its members are checkable and explicit-arg constraints apply.
# =============================================================================


@[test]
function test_explicit_imported_type_arg_constraint_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    # render[lib.Plain] resolves the type argument; Plain does not implement
    # lib.Drawable, so the explicit constraint is flagged.
    var program = load_lib_and_main(ref_of(root), LIB_DRAWABLE_PLAIN, MAIN_DRAWABLE_EXPLICIT) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("does not implement"))


@[test]
function test_annotated_imported_type_unknown_member_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_WIDGET, MAIN_WIDGET_BOGUS) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("unknown method"))


@[test]
function test_annotated_imported_type_valid_member_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_WIDGET, MAIN_WIDGET_DRAW) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)

# =============================================================================
#  Phase 1 item G: imported enum/variant match exhaustiveness. The binding now
#  exports match_case_names; the checker imports them and checks exhaustiveness
#  when the scrutinee is an imported ty_imported enum/variant.
# =============================================================================


@[test]
function test_imported_enum_match_missing_case_is_flagged() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_COLOR, MAIN_COLOR_MISSING_GREEN) else:
        expect(false, "could not load program")
    defer: program.release()

    expect(program.has_diagnostic_containing("missing cases"))


@[test]
function test_imported_enum_match_exhaustive_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_COLOR, MAIN_COLOR_EXHAUSTIVE) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)

# =============================================================================
#  Regression: imported generic return types must not produce false-positive
#  type mismatches (contains_error + nominal_definitely_different fixes).
# =============================================================================


@[test]
function test_imported_generic_method_return_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_HOLDER_GENERIC, MAIN_HOLDER_GET) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)


@[test]
function test_imported_struct_static_return_is_clean() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))

    var program = load_lib_and_main(ref_of(root), LIB_CONTAINER_STATIC, MAIN_CONTAINER_MAKE) else:
        expect(false, "could not load program")
    defer: program.release()

    expect_eq(int<-program.diagnostic_count(), 0)

# =============================================================================
#  Module cache: closure reuse, the dependency-version cascade, created
#  imports and open-buffer overrides.
# =============================================================================

const LIB_ADD_MIXED: str = <<-SRC
public function add(a: int, b: str) -> int:
    return a
SRC

const GHOST_MODULE: str = <<-SRC
public function ghost() -> int:
    return 0
SRC

const CYCLE_A: str = <<-SRC
import b

public struct AData:
    value: int

public function fa(d: AData) -> int:
    return d.value + b.fb()
SRC

const CYCLE_B: str = <<-SRC
import a

public function fb() -> int:
    let d = a.AData(value = 1)
    return d.value
SRC

const CYCLE_B_BAD: str = <<-SRC
import a

public function fb() -> str:
    let d = a.AData(value = 1)
    return "x"
SRC

const CYCLE_MAIN: str = <<-SRC
import a

function main() -> int:
    return a.fa(a.AData(value = 2))
SRC


## Load main.mt through the module cache (and optional open-buffer overrides).
function load_main_with_cache(
    root: ref[string.String],
    cache: ptr[loader.ModuleCache]?,
    open_docs: ptr[map_mod.Map[string.String, string.String]]?
) -> loader.Program:
    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    return loader.check_program_with_source(
        main_path.as_str(),
        roots.as_span(),
        resolver.Platform.linux,
        "",
        false,
        cache,
        open_docs
    )


@[test]
function test_module_cache_reuses_an_unchanged_closure() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))
    expect(write_file(root.as_str(), "lib.mt", LIB_ADD), "could not write lib.mt")
    expect(write_file(root.as_str(), "main.mt", MAIN_ADD_CORRECT), "could not write main.mt")

    var cache = loader.create_module_cache()
    defer: loader.release_module_cache(ref_of(cache))

    var first = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect_eq(int<-first.diagnostic_count(), 0)
    expect_eq(int<-cache.parse_count, 2)
    expect_eq(int<-cache.analysis_count, 2)
    first.release()

    # Nothing changed: both modules reuse their parse and their analysis.
    var second = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect_eq(int<-second.diagnostic_count(), 0)
    expect_eq(int<-cache.parse_count, 2)
    expect_eq(int<-cache.analysis_count, 2)
    second.release()


@[test]
function test_module_cache_reanalyzes_only_the_changed_root() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))
    expect(write_file(root.as_str(), "lib.mt", LIB_ADD), "could not write lib.mt")
    expect(write_file(root.as_str(), "main.mt", MAIN_ADD_CORRECT), "could not write main.mt")

    var cache = loader.create_module_cache()
    defer: loader.release_module_cache(ref_of(cache))

    var first = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect_eq(int<-first.diagnostic_count(), 0)
    first.release()

    expect(write_file(root.as_str(), "main.mt", MAIN_ADD_ARITY), "could not rewrite main.mt")
    var second = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect(second.has_diagnostic_containing("expects"))
    expect_eq(int<-cache.parse_count, 3)
    expect_eq(int<-cache.analysis_count, 3)
    second.release()


@[test]
function test_module_cache_cascades_to_dependents() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))
    expect(write_file(root.as_str(), "lib.mt", LIB_ADD), "could not write lib.mt")
    expect(write_file(root.as_str(), "main.mt", MAIN_ADD_CORRECT), "could not write main.mt")

    var cache = loader.create_module_cache()
    defer: loader.release_module_cache(ref_of(cache))

    var first = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect_eq(int<-first.diagnostic_count(), 0)
    first.release()

    # The dependency changes: it re-parses, and both it and its dependent
    # re-analyze, so the dependent's diagnostics reflect the new signature.
    expect(write_file(root.as_str(), "lib.mt", LIB_ADD_MIXED), "could not rewrite lib.mt")
    var second = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect(second.has_diagnostic_containing("expects str"))
    expect_eq(int<-cache.parse_count, 3)
    expect_eq(int<-cache.analysis_count, 4)
    second.release()


@[test]
function test_module_cache_reuses_a_cycle() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))
    expect(write_file(root.as_str(), "a.mt", CYCLE_A), "could not write a.mt")
    expect(write_file(root.as_str(), "b.mt", CYCLE_B), "could not write b.mt")
    expect(write_file(root.as_str(), "main.mt", CYCLE_MAIN), "could not write main.mt")

    var cache = loader.create_module_cache()
    defer: loader.release_module_cache(ref_of(cache))

    var first = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect_eq(int<-first.diagnostic_count(), 0)
    expect_eq(int<-first.module_count(), 3)
    expect_eq(int<-cache.parse_count, 3)
    expect_eq(int<-cache.analysis_count, 3)
    first.release()

    # Nothing changed: the cycle's members reuse their analyses and the
    # dependent keeps its cache entry.
    var second = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect_eq(int<-second.diagnostic_count(), 0)
    expect_eq(int<-cache.parse_count, 3)
    expect_eq(int<-cache.analysis_count, 3)
    second.release()

    # A changed cycle member invalidates the whole cycle and its dependents.
    expect(write_file(root.as_str(), "b.mt", CYCLE_B_BAD), "could not rewrite b.mt")
    var third = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect_eq(int<-cache.parse_count, 4)
    expect(cache.analysis_count > 3)
    third.release()


@[test]
function test_cycle_regions_survive_the_request_boundary() -> void:
    ## A cycle's pass-1 analyses are referenced by pass-2 types, so their
    ## region is owned by the cache entry, not retired at the request
    ## boundary.  A fresh cyclic program must therefore retire nothing.
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))
    expect(write_file(root.as_str(), "a.mt", CYCLE_A), "could not write a.mt")
    expect(write_file(root.as_str(), "b.mt", CYCLE_B), "could not write b.mt")
    expect(write_file(root.as_str(), "main.mt", CYCLE_MAIN), "could not write main.mt")

    var cache = loader.create_module_cache()
    defer: loader.release_module_cache(ref_of(cache))

    var program = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect_eq(int<-program.diagnostic_count(), 0)
    expect(program.cycle_module_names.len() > 0, "expected a detected import cycle")

    expect_eq(int<-cache.retired_regions.len(), 0)
    loader.drain_retired_regions(ref_of(cache))
    expect_eq(int<-cache.retired_regions.len(), 0)
    program.release()


@[test]
function test_module_cache_retires_and_drains_superseded_regions() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))
    expect(write_file(root.as_str(), "lib.mt", LIB_ADD), "could not write lib.mt")
    expect(write_file(root.as_str(), "main.mt", MAIN_ADD_CORRECT), "could not write main.mt")

    var cache = loader.create_module_cache()
    defer: loader.release_module_cache(ref_of(cache))

    var first = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect_eq(int<-first.diagnostic_count(), 0)
    first.release()
    expect_eq(int<-cache.retired_regions.len(), 0)

    # Replacing the edited entry's parse and analysis quarantines the old
    # regions: they stay alive until the request boundary, then the drain frees
    # them.
    expect(write_file(root.as_str(), "main.mt", MAIN_ADD_ARITY), "could not rewrite main.mt")
    var second = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect(second.has_diagnostic_containing("expects"))
    expect(cache.retired_regions.len() > 0)
    loader.drain_retired_regions(ref_of(cache))
    expect_eq(int<-cache.retired_regions.len(), 0)
    second.release()


@[test]
function test_module_cache_picks_up_a_created_import() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))
    expect(write_file(root.as_str(), "main.mt", S_MOD_MAIN_IMPORT_GHOST), "could not write main.mt")

    var cache = loader.create_module_cache()
    defer: loader.release_module_cache(ref_of(cache))

    var first = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect(first.has_diagnostic_containing("module not found"))
    expect_eq(int<-cache.parse_count, 1)

    # The missing module appears on disk: the next run parses and checks it and
    # re-analyzes the importer, whose resolved-import set changed.
    expect(write_file(root.as_str(), "ghost.mt", GHOST_MODULE), "could not write ghost.mt")
    var second = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect_eq(int<-second.diagnostic_count(), 0)
    expect_eq(int<-cache.parse_count, 2)
    expect_eq(int<-cache.analysis_count, 3)
    second.release()


@[test]
function test_module_cache_uses_open_buffers_for_imports() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))
    expect(write_file(root.as_str(), "lib.mt", LIB_ADD), "could not write lib.mt")
    expect(write_file(root.as_str(), "main.mt", MAIN_ADD_CORRECT), "could not write main.mt")

    var cache = loader.create_module_cache()
    defer: loader.release_module_cache(ref_of(cache))

    var first = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    expect_eq(int<-first.diagnostic_count(), 0)
    first.release()

    # An open, unsaved buffer overrides the dependency's disk content (the
    # host's source_overrides): the importer's diagnostics reflect it.
    var open_docs = map_mod.Map[string.String, string.String].create()
    defer: open_docs.release()
    var lib_path = path_ops.join(root.as_str(), "lib.mt")
    defer: lib_path.release()
    open_docs.set(string.String.from_str(lib_path.as_str()), string.String.from_str(LIB_ADD_MIXED))

    var second = load_main_with_cache(ref_of(root), ptr_of(cache), ptr_of(open_docs))
    expect(second.has_diagnostic_containing("expects str"))
    expect_eq(int<-cache.parse_count, 3)
    expect_eq(int<-cache.analysis_count, 4)
    second.release()


@[test]
function test_module_cache_surface_follows_a_cached_check() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_l3_") else:
        expect(false, "could not create temp dir")
    defer: cleanup_dir(ref_of(root))
    expect(write_file(root.as_str(), "lib.mt", LIB_ADD), "could not write lib.mt")
    expect(write_file(root.as_str(), "main.mt", MAIN_ADD_CORRECT), "could not write main.mt")

    var cache = loader.create_module_cache()
    defer: loader.release_module_cache(ref_of(cache))
    var lib_path = path_ops.join(root.as_str(), "lib.mt")
    defer: lib_path.release()

    # Cold: the import has no surface yet.
    match loader.cached_module_surface(ptr_of(cache), lib_path.as_str()):
        Option.some:
            expect(false, "surface before any load")
        Option.none:
            pass

    var program = load_main_with_cache(ref_of(root), ptr_of(cache), null)
    defer: program.release()

    # After a cached check the import's analysis is served by value.
    match loader.cached_module_surface(ptr_of(cache), lib_path.as_str()):
        Option.some as surface:
            expect(surface.value.analysis.functions.contains("add"))
        Option.none:
            expect(false, "missing surface after a cached check")
