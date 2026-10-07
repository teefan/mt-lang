## In-language lowering tests for the self-hosted mtc compiler.
## Run with: mtc test projects/mtc
##
## Covers the exact correctness bugs fixed in Phase 9 (defer ordering,
## string-match-expr else-if chain, return-value hoisting, aggregate-literal
## source-module resolution).  Each test writes a temporary source file, parses
## and checks it through the module loader, lowers to IR, formats the IR, and
## asserts on the formatted output.

import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string

import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver
import mtc.lowering.lowering as lowering
import mtc.pretty_printer.ir_formatter as irfmt
import mtc.sexpr as sexpr


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


## Create a temp directory, write `source` as `main.mt` inside it, check the
## program, lower it, format the IR, and return the formatted IR string.  The
## temp directory tree is removed before returning.
function lower_source(source: str) -> string.String:
    var root = fs.create_temporary_directory_in_system_temp("mtc_lo_") else:
        return string.String.from_str("FAIL: temp dir")
    defer: cleanup_dir(ref_of(root))

    if not write_main_file(root.as_str(), source):
        return string.String.from_str("FAIL: write main")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()

    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    var ir_program = lowering.lower(program)
    return irfmt.format_program(ir_program)


## Write `content` to `dir/name` (the directory must exist).
function write_source_file(dir: str, name: str, content: str) -> bool:
    var file_path = path_ops.join(dir, name)
    defer: file_path.release()

    match fs.write_text(file_path.as_str(), content):
        Result.failure as f:
            var e = f.error
            e.release()
            return false
        Result.success:
            return true


# =============================================================================
#  Defer ordering — the cleanup must appear at scope-exit and before each
#  return, NOT at the declaration site.  (Phase 9 defer lowering fix.)
# =============================================================================

@[test]
function test_defer_cleanup_not_at_declaration_site() -> void:
    ## The defer cleanup must appear at scope exit — AFTER later statements —
    ## not immediately after the defer declaration.  Using two distinct module
    ## vars lets us assert the exact emission order in the IR.
    var source = <<-SRC
        var first: int = 0
        var second: int = 0

        function f() -> void:
            let x = 1
            defer:
                first = x
            let y = 2
            second = y
            return
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    ## `second = y` (the last real statement) must be emitted BEFORE the
    ## deferred `first = x`, proving the defer runs at scope exit rather than
    ## at its declaration site.
    let second_pos = text.find_substring("second = y") else:
        expect(false, "missing 'second = y' assignment in IR")
    let first_pos = text.find_substring("first = x") else:
        expect(false, "missing deferred 'first = x' assignment in IR")
    expect(first_pos > second_pos)


@[test]
function test_defer_cleanup_before_return() -> void:
    ## When a defer is active and a function has multiple return paths, the
    ## defer cleanup must be duplicated before EACH return.
    var source2 = <<-SRC
        var counter: int = 0

        function g(cond: bool) -> int:
            defer:
                counter = counter + 1
            if cond:
                return 1
            return 2
    SRC
    var ir = lower_source(source2)
    defer: ir.release()
    let text = ir.as_str()
    ## The `counter = counter + 1` cleanup must appear before both `return 1`
    ## and `return 2`.  Verify at least the first occurrence precedes `return 1`.
    let cleanup_pos = text.find_substring("counter + 1") else:
        expect(false, "missing deferred counter increment")
    let return1_pos = text.find_substring("return 1") else:
        expect(false, "missing return 1")
    expect(cleanup_pos < return1_pos)


@[test]
function test_defer_with_block_body_form() -> void:
    ## A `defer:` block must be lowered as well.
    var source = <<-SRC
        var counter: int = 0

        function f() -> void:
            defer:
                counter = counter + 1
            return
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    ## counter must appear in the IR (defer body was lowered).
    expect(text.contains_substring("counter"))


# =============================================================================
#  String-match expression — must produce a proper else-if chain where exactly
#  one arm runs, not independent if-thens that clobber each other.  (Phase 9
#  string-match-expr fix.)
# =============================================================================

@[test]
function test_string_match_expr_has_else_if_chain() -> void:
    ## The expression-form `return match lexeme:` must lower to a nested
    ## else-if chain where each subsequent comparison lives inside the preceding
    ## `else:` branch, so exactly one arm runs.  The pre-fix bug emitted
    ## independent if-thens where the last arm's else clobbered earlier matches.
    var source = <<-SRC
        enum Kind: ubyte
            a = 1
            b = 2

        function classify(lexeme: str) -> Kind:
            return match lexeme:
                "a": Kind.a
                "b": Kind.b
                _: Kind.a
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    ## The first comparison must precede an `else:` which precedes the second
    ## comparison (nested chain), and the wildcard default comes last.
    let first_cmp = text.find_substring("lexeme == \"a\"") else:
        expect(false, "missing first arm comparison")
    let else_pos = text.find_substring("else:") else:
        expect(false, "missing else branch (chain not nested)")
    let second_cmp = text.find_substring("lexeme == \"b\"") else:
        expect(false, "missing second arm comparison")
    ## Nested chain order: first == "a", then else:, then == "b".
    expect(first_cmp < else_pos)
    expect(else_pos < second_cmp)


@[test]
function test_string_match_expr_with_only_wildcard() -> void:
    ## A match expr with ONLY a wildcard arm must still lower correctly
    ## (edge case: the old code was buggy for the no-pattern-arms case).
    var source = <<-SRC
        function always() -> str:
            return match 1:
                _: "default"
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    expect(text.contains_substring("default"))


# =============================================================================
#  Return-value hoisting — when defers are active, a non-trivial return
#  expression must be hoisted into a temp before the cleanup preamble, so
#  that running the defers does not invalidate it.  (Phase 9 defer fix.)
# =============================================================================

@[test]
function test_return_with_active_defer_lowers_cleanly() -> void:
    ## A return expression that is NOT a trivial literal, in the presence of
    ## an active defer, must be lowered without error (no value clobber).
    var source = <<-SRC
        function calc() -> int:
            var x: ptr[int]? = null
            defer:
                x = null
            return 42
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    expect(text.contains_substring("return"))


# =============================================================================
#  Aggregate-literal source-module resolution — struct constructors for
#  imported types must use the correct module prefix.  (Phase 9
#  break-in-match-in-while fix #2.)
# =============================================================================

@[test]
function test_struct_aggregate_lowering_does_not_crash() -> void:
    ## Constructing a struct that is defined in an imported module must work.
    ## A minimal test: Vec[int].create() in a function body exercises the
    ## aggregate literal path.
    var source = <<-SRC
        import std.vec as vec

        function make_vec() -> vec.Vec[int]:
            return vec.Vec[int].create()
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    # Concrete instances print as the generic form with their arguments
    # (`Vec[int]`), not a mangled `Vec_int` C name.
    expect(text.contains_substring("Vec[int]"))


# =============================================================================
#  Constant aggregates of a re-exported type alias — the SimpleGame shape.
# =============================================================================

@[test]
function test_const_aggregate_through_imported_type_alias() -> void:
    ## `public const MIDNIGHT: rl.Color = rl.Color.from_hex_str("#10121c")` with
    ## `type Color = c.Color` re-exported by the binding module must fold to the
    ## aggregate literal of the *declaring* module's struct (a call cannot
    ## initialize a C constant), with each field typed by the field's own type.
    var root = fs.create_temporary_directory_in_system_temp("mtc_alias_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var main_source = <<-SRC
        import lib as lib


        extending lib.Color:
            static const function hex_digit(c: ubyte) -> ubyte:
                return c - '0'


            static const function from_hex_str(color: str) -> lib.Color:
                return lib.Color(
                    r = lib.Color.hex_digit(color[1]) * 16 + lib.Color.hex_digit(color[2]),
                    g = 3,
                    b = 4,
                    a = 255
                )

        public const LITERAL: lib.Color = lib.Color(r = 1, g = 2, b = 3, a = 4)
        public const PARSED: lib.Color = lib.Color.from_hex_str("#12")
    SRC
    if not write_main_file(root.as_str(), main_source):
        return

    var raw_source = <<-SRC
        public struct Color:
            r: ubyte
            g: ubyte
            b: ubyte
            a: ubyte
    SRC
    if not write_source_file(root.as_str(), "raw.mt", raw_source):
        return

    var lib_source = <<-SRC
        import raw as raw

        public type Color = raw.Color
    SRC
    if not write_source_file(root.as_str(), "lib.mt", lib_source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var text = irfmt.format_program(ir_program)
    defer: text.release()
    let formatted = text.as_str()
    expect(formatted.contains_substring("const LITERAL as main_LITERAL: Color = Color(r = 1, g = 2, b = 3, a = 4)"))
    expect(formatted.contains_substring("const PARSED as main_PARSED: Color = Color(r = 18, g = 3, b = 4, a = 255)"))

    # The aggregate's type is the alias chain's end (raw.mt's Color), not the
    # naming module, and the interpreted values are typed by the field's type.
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    expect(dumped.contains_substring(":value (IR::AggregateLiteral :type (Types::Struct :name \"Color\" :module_name \"raw\")"))
    expect(dumped.contains_substring("(IR::AggregateField :name \"r\" :value (IR::IntegerLiteral :value 18 :type (Types::Primitive :name \"ubyte\")))"))


@[test]
function test_opaque_decls_keep_declared_name_and_backing() -> void:
    ## Every non-raw module's `opaque` declaration keeps its declared name and
    ## its C backing is the explicit `= c"..."` name when present, else the
    ## module-qualified name.  Only a backing that is a plain C identifier is
    ## forward-declarable (host `opaque_forward_declarable?`).
    var source = <<-SRC
        public opaque Handle = c"HANDLE"
        public opaque Sync = c"struct __GLsync"
        public opaque Widget
    SRC
    var root = fs.create_temporary_directory_in_system_temp("mtc_op_") else:
        return
    defer: cleanup_dir(ref_of(root))
    if not write_main_file(root.as_str(), source):
        return
    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    expect(dumped.contains_substring("(IR::OpaqueDecl :name \"Handle\" :linkage_name \"HANDLE\" :forward_declarable true"))
    expect(dumped.contains_substring("(IR::OpaqueDecl :name \"Sync\" :linkage_name \"struct __GLsync\" :forward_declarable false"))
    expect(dumped.contains_substring("(IR::OpaqueDecl :name \"Widget\" :linkage_name \"main_Widget\" :forward_declarable true"))


@[test]
function test_null_literal_takes_context_type() -> void:
    ## A bare `null` initializer takes the context type (the host's
    ## `infer_null_literal_type`: `expected_type || null_type`): a local or
    ## global declared `ptr[T]?`/`S?` types the literal `Types::Nullable …`,
    ## not `void`.
    var source = <<-SRC
        struct S:
            x: int

        var g: ptr[int]? = null

        function f() -> int:
            var p: ptr[int]? = null
            var q: S? = null
            return 0
    SRC
    var root = fs.create_temporary_directory_in_system_temp("mtc_null_") else:
        return
    defer: cleanup_dir(ref_of(root))
    if not write_main_file(root.as_str(), source):
        return
    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    expect(dumped.contains_substring(":name \"g\" :linkage_name \"main_g\" :type (Types::Nullable :base (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"int\")))) :value (IR::NullLiteral :type (Types::Nullable :base (Types::Generic :name \"ptr\""))
    expect(dumped.contains_substring(":name \"p\" :linkage_name \"p\" :type (Types::Nullable :base (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"int\")))) :value (IR::NullLiteral :type (Types::Nullable :base (Types::Generic :name \"ptr\""))
    expect(dumped.contains_substring(":name \"q\" :linkage_name \"q\" :type (Types::Nullable :base (Types::Struct :name \"S\" :module_name \"main\")) :value (IR::NullLiteral :type (Types::Nullable :base (Types::Struct :name \"S\" :module_name \"main\"))"))


# =============================================================================
#  A global initialized from an imported constant — the initializer folds to
#  the constant's aggregate value, not a name reference to it.
# =============================================================================

@[test]
function test_global_initialized_from_imported_const() -> void:
    ## `var g_origin: lib.Vec2 = lib.ORIGIN` with `lib.ORIGIN` re-exporting a
    ## raw module's struct constant must fold to the aggregate literal of the
    ## *declaring* module's struct, as the host's
    ## `lower_static_storage_initializer` does (before the fix the global held
    ## an `IR::Name` typed `Types::Error` referencing the constant's linkage
    ## name, so the emitted C was not a constant initializer).
    var root = fs.create_temporary_directory_in_system_temp("mtc_gconst_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var main_source = <<-SRC
        import lib as lib

        var g_origin: lib.Vec2 = lib.ORIGIN
    SRC
    if not write_main_file(root.as_str(), main_source):
        return

    var raw_source = <<-SRC
        public struct Vec2:
            x: int
            y: int

        public const ZERO: Vec2 = Vec2(x = 0, y = 0)
    SRC
    if not write_source_file(root.as_str(), "raw.mt", raw_source):
        return

    var lib_source = <<-SRC
        import raw as raw

        public type Vec2 = raw.Vec2
        public const ORIGIN: Vec2 = raw.ZERO
    SRC
    if not write_source_file(root.as_str(), "lib.mt", lib_source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    expect(dumped.contains_substring(":name \"g_origin\" :linkage_name \"main_g_origin\" :type (Types::Struct :name \"Vec2\" :module_name \"raw\") :value (IR::AggregateLiteral :type (Types::Struct :name \"Vec2\" :module_name \"raw\")"))
    expect(dumped.contains_substring("(IR::AggregateField :name \"x\" :value (IR::IntegerLiteral :value 0 :type (Types::Primitive :name \"int\")))"))


@[test]
function test_function_reference_carries_declared_name() -> void:
    ## A bare function name in a value position is typed with the function
    ## binding's own type — the declared name carried in `Types::Function#name`
    ## and the variadic flag — as the host's `infer_expression_type` returns it
    ## (`function_type_for_name` -> `binding.type`); the fallback used to
    ## rebuild the type from the `FnSig` with an empty name.
    var root = fs.create_temporary_directory_in_system_temp("mtc_fref_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        function noop_scene_draw() -> void:
            pass

        var s_scene_draw: fn() -> void = noop_scene_draw
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    expect(dumped.contains_substring(":value (IR::Name :name \"main_noop_scene_draw\" :type (Types::Function :name \"noop_scene_draw\" :params () :return_type (Types::Primitive :name \"void\")"))


# =============================================================================
#  Tuple value structs — the host's `ensure_tuple_struct` registers an
#  `mt_tuple_*` struct for a tuple literal and for a tuple in a const/global
#  storage type.
# =============================================================================

@[test]
function test_tuple_literal_registers_value_struct() -> void:
    ## A tuple literal registers its value struct: the declared name is the
    ## host's qualified `Tuple#to_s` (`(main.P, int)`) and the linkage name is
    ## the sanitized `mt_tuple_<elements>`.
    var root = fs.create_temporary_directory_in_system_temp("mtc_tup_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        struct P:
            x: int

        function f() -> (P, int):
            return (P(x = 1), 2)
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    expect(dumped.contains_substring("(IR::StructDecl :name \"(main.P, int)\" :linkage_name \"mt_tuple_main_P_int\" :fields ((IR::Field :name \"_0\" :type (Types::Struct :name \"P\" :module_name \"main\")) (IR::Field :name \"_1\" :type (Types::Primitive :name \"int\")))"))


@[test]
function test_storage_tuple_registers_value_struct() -> void:
    ## A tuple that appears only in a const/global *declared* type — the
    ## initializer is another module's constant, so no tuple literal is
    ## lowered — still registers its value struct (the host's
    ## `ensure_registered_storage_type_types`).
    var root = fs.create_temporary_directory_in_system_temp("mtc_tups_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var lib_source = <<-SRC
        public const ZERO: (int, int) = (0, 0)
    SRC
    if not write_source_file(root.as_str(), "libx.mt", lib_source):
        return

    var main_source = <<-SRC
        import libx as libx

        var g_pair: (int, int) = libx.ZERO
    SRC
    if not write_main_file(root.as_str(), main_source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    expect(dumped.contains_substring(":name \"g_pair\" :linkage_name \"main_g_pair\""))
    expect(dumped.contains_substring("(IR::StructDecl :name \"(int, int)\" :linkage_name \"mt_tuple_int_int\" :fields ((IR::Field :name \"_0\" :type (Types::Primitive :name \"int\")) (IR::Field :name \"_1\" :type (Types::Primitive :name \"int\")))"))


@[test]
function test_synthetic_structs_follow_creation_order() -> void:
    ## Synthetic value structs land after the module declarations in creation
    ## order, as the host's single `synthetic_structs` list does: a tuple
    ## literal lowered before a dyn use puts the tuple struct before the
    ## vtable struct.
    var root = fs.create_temporary_directory_in_system_temp("mtc_synth_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        interface Shape:
            function area() -> float

        struct Circle implements Shape:
            r: float

        extending Circle:
            function area() -> float:
                return 3.14

        function pair() -> (int, int):
            return (1, 2)

        function use_dyn() -> float:
            var c = Circle(r = 5.0)
            var s: dyn[Shape] = adapt[Shape](ref_of(c))
            return s.area()
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    let circle_pos = dumped.find_substring("(IR::StructDecl :name \"Circle\"") else:
        expect(false, "missing Circle struct decl")
    let tuple_pos = dumped.find_substring("(IR::StructDecl :name \"(int, int)\"") else:
        expect(false, "missing tuple struct decl")
    let vtable_pos = dumped.find_substring("(IR::StructDecl :name \"vtable_Shape\"") else:
        expect(false, "missing vtable struct decl")
    expect(circle_pos < tuple_pos)
    expect(tuple_pos < vtable_pos)


@[test]
function test_anonymous_tuple_renders_default_field_names() -> void:
    ## The host's `Types::Tuple#field_names` always carries the default
    ## positional names, so an anonymous tuple literal's type renders
    ## `:field_names ("_0" "_1")` rather than `nil`.
    var root = fs.create_temporary_directory_in_system_temp("mtc_tupnames_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        struct P:
            x: int

        function f() -> (P, int):
            return (P(x = 1), 2)
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    expect(dumped.contains_substring("(Types::Tuple :element_types ((Types::Struct :name \"P\" :module_name \"main\") (Types::Primitive :name \"int\")) :field_names (\"_0\" \"_1\"))"))


@[test]
function test_tuple_constant_lowers_to_array_literal() -> void:
    ## A constant whose declared type is a tuple and whose value is an
    ## expression list takes the host's `lower_const_value_literal` shape: an
    ## `IR::ArrayLiteral` whose element literals are all typed `int` — the
    ## host's fallback element type, since `Types::Tuple` has no `arguments`.
    var root = fs.create_temporary_directory_in_system_temp("mtc_tupconst_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        const PAIR: (int, int) = (1, 2)
        const MIX: (int, bool) = (1, true)
        const BINT: (bool, int) = (true, 1)

        function main() -> int:
            return 0
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    expect(dumped.contains_substring(":name \"PAIR\" :linkage_name \"main_PAIR\" :type (Types::Tuple :element_types ((Types::Primitive :name \"int\") (Types::Primitive :name \"int\")) :field_names (\"_0\" \"_1\")) :value (IR::ArrayLiteral :type (Types::Tuple :element_types ((Types::Primitive :name \"int\") (Types::Primitive :name \"int\")) :field_names (\"_0\" \"_1\")) :elements ((IR::IntegerLiteral :value 1 :type (Types::Primitive :name \"int\")) (IR::IntegerLiteral :value 2 :type (Types::Primitive :name \"int\"))))"))
    expect(dumped.contains_substring(":name \"MIX\" :linkage_name \"main_MIX\" :type (Types::Tuple :element_types ((Types::Primitive :name \"int\") (Types::Primitive :name \"bool\")) :field_names (\"_0\" \"_1\")) :value (IR::ArrayLiteral :type (Types::Tuple :element_types ((Types::Primitive :name \"int\") (Types::Primitive :name \"bool\")) :field_names (\"_0\" \"_1\")) :elements ((IR::IntegerLiteral :value 1 :type (Types::Primitive :name \"int\")) (IR::BooleanLiteral :value true :type (Types::Primitive :name \"int\"))))"))
    expect(dumped.contains_substring(":name \"BINT\" :linkage_name \"main_BINT\" :type (Types::Tuple :element_types ((Types::Primitive :name \"bool\") (Types::Primitive :name \"int\")) :field_names (\"_0\" \"_1\")) :value (IR::ArrayLiteral :type (Types::Tuple :element_types ((Types::Primitive :name \"bool\") (Types::Primitive :name \"int\")) :field_names (\"_0\" \"_1\")) :elements ((IR::BooleanLiteral :value true :type (Types::Primitive :name \"int\")) (IR::IntegerLiteral :value 1 :type (Types::Primitive :name \"int\"))))"))


@[test]
function test_event_fields_use_hidden_name_and_event_type() -> void:
    ## A struct-declared event is stored under its hidden C name
    ## (`__event_<name>`) with the event type (`Types::Event`), and every
    ## member access is routed through the hidden name — the host's
    ## `lower_struct_decl` and `member_c_name` shapes.
    var root = fs.create_temporary_directory_in_system_temp("mtc_event_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        struct Window:
            title: str
            event closed[4]

        function ping(w: ref[Window]) -> void:
            w.closed.emit()
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    expect(dumped.contains_substring("(IR::Field :name \"__event_closed\" :type (Types::Event :name \"closed\" :capacity 4 :payload_type nil))"))
    expect(dumped.contains_substring(":member \"__event_closed\" :type (Types::Event :name \"closed\" :capacity 4 :payload_type nil)"))


@[test]
function test_reinterpret_always_reinterprets_with_refined_source() -> void:
    ## `reinterpret[T](x)` always lowers to `IR::ReinterpretExpr` (the host's
    ## shape; the C backend copies the bits), and an identifier argument
    ## carries the flow-refined local type — `ptr[void]` after
    ## `if p == null: return`, the declared `ptr[void]?` without a guard —
    ## including inside a method body (the nullability pre-pass now runs
    ## there too).
    var root = fs.create_temporary_directory_in_system_temp("mtc_reint_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        struct R:
            x: int

        extending R:
            function method_guard(address: ptr[void]?) -> bool:
                if address == null:
                    return false
                unsafe:
                    let t = reinterpret[ptr_uint](address)
                    return t != 0

        function checked(p: ptr[void]?) -> ptr_uint:
            if p == null:
                return 0
            return unsafe: reinterpret[ptr_uint](p)

        function unchecked(p: ptr[void]?) -> ptr_uint:
            return unsafe: reinterpret[ptr_uint](p)
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    expect(not dumped.contains_substring("IR::Cast :target_type (Types::Primitive :name \"ptr_uint\")"))
    expect(dumped.contains_substring("(IR::ReinterpretExpr :target_type (Types::Primitive :name \"ptr_uint\") :source_type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"void\"))) :expression (IR::Name :name \"p\" :type (Types::Nullable"))
    expect(dumped.contains_substring("(IR::ReinterpretExpr :target_type (Types::Primitive :name \"ptr_uint\") :source_type (Types::Nullable :base (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"void\")))) :expression (IR::Name :name \"p\" :type (Types::Nullable"))
    expect(dumped.contains_substring("(IR::ReinterpretExpr :target_type (Types::Primitive :name \"ptr_uint\") :source_type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"void\"))) :expression (IR::Name :name \"address\" :type (Types::Nullable"))


@[test]
function test_guards_inside_statements_keep_their_refinement() -> void:
    ## A guard *inside* a compound statement still answers `reinterpret`'s
    ## source type with its refined pointer: the refinement record's
    ## post-statement snapshot sits at the statement's end (the host's
    ## `check_block` tail), so neither a `while` body's guard nor a terminating
    ## `if p == null: return` arm's `null` is shadowed by the enclosing
    ## statement's post-record.  Session 43 fixed the record's positions
    ## (`std/mem/heap.mt`'s `contains`, item 3k).
    var root = fs.create_temporary_directory_in_system_temp("mtc_guardstmt_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        struct Block:
            data: ptr[ubyte]?

        public function after_if(address: ptr[void]?) -> ptr_uint:
            if address == null:
                return 0
            return unsafe: reinterpret[ptr_uint](address)

        public function in_loop(b: Block?) -> ptr_uint:
            let block = b else:
                return 0
            var i: ptr_uint = 0
            while i < 1:
                let data = block.data else:
                    i += 1
                    continue
                return unsafe: reinterpret[ptr_uint](data)
            return 0
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    expect(dumped.contains_substring(":source_type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"void\"))) :expression (IR::Name :name \"address\" :type (Types::Nullable"))
    expect(dumped.contains_substring(":source_type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"ubyte\"))) :expression (IR::Name :name \"data\" :type (Types::Nullable"))
    expect(not dumped.contains_substring(":source_type (Types::Null"))


@[test]
function test_includes_follow_the_hosts_dfs_post_order() -> void:
    ## Raw-binding include directives are appended in the host's analysis-cache
    ## insertion order — a DFS post-order from the root with each module's
    ## imports visited in declaration order — not the canonical module order:
    ## with `main` importing `mid` (which imports `zz_raw`) before `aa_raw`,
    ## `zz.h` precedes `aa.h` even though `aa_raw` sorts first.
    var root = fs.create_temporary_directory_in_system_temp("mtc_inc_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var zz_source = <<-SRC
        external

        include "zz.h"

        external function zz_fn() -> void
    SRC
    if not write_source_file(root.as_str(), "zz_raw.mt", zz_source):
        return

    var aa_source = <<-SRC
        external

        include "aa.h"

        external function aa_fn() -> void
    SRC
    if not write_source_file(root.as_str(), "aa_raw.mt", aa_source):
        return

    var mid_source = <<-SRC
        import zz_raw as z
    SRC
    if not write_source_file(root.as_str(), "mid.mt", mid_source):
        return

    var main_source = <<-SRC
        import mid as m
        import aa_raw as a

        function main() -> int:
            return 0
    SRC
    if not write_main_file(root.as_str(), main_source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()
    let zz_pos = dumped.find_substring("zz.h") else:
        expect(false, "missing zz.h include")
    let aa_pos = dumped.find_substring("aa.h") else:
        expect(false, "missing aa.h include")
    expect(zz_pos < aa_pos)


# =============================================================================
#  Overall pipeline stability — lowering must not crash on common constructs.
# =============================================================================

@[test]
function test_lower_function_with_defer_and_while_and_match() -> void:
    ## A realistic function that combines defer, while loop (not break-in-
    ## match), and a match expression.  Exercises the full defer stack model.
    var source = <<-SRC
        import std.vec as vec
        import std.string as string

        var counter: int = 0

        function process_items(items: vec.Vec[int]) -> void:
            defer:
                counter = counter + 1
            var i: ptr_uint = 0
            let count = items.len()
            while i < count:
                let val_ptr = items.get(i) else:
                    return
                i += 1
            return
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    expect(text.contains_substring("while"))
    expect(text.contains_substring("return"))
    return


@[test]
function test_lower_match_with_variant_arms() -> void:
    ## A match over a variant with payload arms must lower.
    var source = <<-SRC
        variant Token:
            ident(name: str)
            eof

        function check(tok: Token) -> bool:
            match tok:
                Token.ident:
                    return true
                Token.eof:
                    return false
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    return


# =============================================================================
#  atomic[T] — the builtin methods lower to GCC/Clang __atomic_* builtins with
#  the sequential-consistency memory order (5).  (Phase A atomic parity.)
# =============================================================================

@[test]
function test_atomic_methods_lower_to_builtins() -> void:
    ## load/store/add must lower to __atomic_load_n / __atomic_store_n /
    ## __atomic_fetch_add, each threading the receiver address and the seq-cst
    ## memory-order constant (5).  store returns void; add/load return the
    ## element type (int here).
    var source = <<-SRC
        function counter_demo() -> int:
            var counter: atomic[int]
            counter.store(0)
            let prev = counter.add(1)
            let value = counter.load()
            return prev + value
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    expect(text.contains_substring("__atomic_store_n(&counter, 0, 5)"))
    expect(text.contains_substring("__atomic_fetch_add(&counter, 1, 5)"))
    expect(text.contains_substring("__atomic_load_n(&counter, 5)"))
    ## add/load must be typed as the element type, not void.
    expect(text.contains_substring("let prev: int ="))
    expect(text.contains_substring("let value: int ="))


@[test]
function test_atomic_sub_and_exchange_lower_to_builtins() -> void:
    ## sub and exchange round out the read-modify-write surface.
    var source = <<-SRC
        function rmw_demo() -> int:
            var counter: atomic[int]
            let a = counter.sub(2)
            let b = counter.exchange(9)
            return a + b
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    expect(text.contains_substring("__atomic_fetch_sub(&counter, 2, 5)"))
    expect(text.contains_substring("__atomic_exchange_n(&counter, 9, 5)"))


# =============================================================================
#  Binary operand widening — mixed-width integer / int+float arithmetic casts
#  the narrower operand up to the common type, matching Ruby's usual-arithmetic
#  conversions.  Same-type operands are not cast.
# =============================================================================

@[test]
function test_mixed_width_integer_arithmetic_widens_narrow_operand() -> void:
    ## `int + long` casts the int operand to long; the long operand is left
    ## alone, and the result type is long.
    var source = <<-SRC
        function f(a: int, b: long) -> long:
            return a + b
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    expect(text.contains_substring("long<-a + b"))


@[test]
function test_same_type_arithmetic_is_not_cast() -> void:
    ## Two operands of the same type need no balancing cast.
    var source = <<-SRC
        function f(a: int, b: int) -> int:
            return a + b
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    expect(text.contains_substring("return a + b"))
    expect(not text.contains_substring("int<-a"))


@[test]
function test_comparison_widens_operand_but_yields_bool() -> void:
    ## A comparison across widths still balances the operands, but the binary's
    ## own result type stays bool (so the arithmetic-result-type widening does
    ## not apply to comparisons).
    var source = <<-SRC
        function f(a: int, b: long) -> bool:
            return a < b
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    expect(text.contains_substring("long<-a < b"))


# =============================================================================
#  Enum / flags backing-cast — comparisons unwrap the operands to their integer
#  backing type and cast to it, matching Ruby's EnumBase unwrap.
# =============================================================================

@[test]
function test_enum_comparison_casts_to_backing() -> void:
    ## `State.running > State.idle` casts both enum operands to the ubyte
    ## backing type before comparing.
    var source = <<-SRC
        enum State: ubyte
            idle = 0
            running = 1

        function cmp() -> bool:
            return State.running > State.idle
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    expect(text.contains_substring("ubyte<-"))
    expect(text.contains_substring("> ubyte<-"))


@[test]
function test_flags_comparison_casts_but_bitwise_does_not() -> void:
    ## A flags comparison casts to the uint backing; a bitwise `|` does not
    ## balance (so no cast is inserted around its operands).
    var source = <<-SRC
        flags Mask: uint
            a = 1
            b = 2

        function cmp(m: Mask) -> bool:
            return m == Mask.a

        function bits() -> Mask:
            return Mask.a | Mask.b
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    expect(text.contains_substring("uint<-m == uint<-"))
    ## The bitwise-or operands are left un-cast.
    expect(text.contains_substring("Mask_a | "))


# =============================================================================
#  emit — compile-time code generation.  `emit function ...` inside a const
#  function body is spliced into the module as an ordinary top-level function.
# =============================================================================

@[test]
function test_emit_function_becomes_top_level() -> void:
    ## The emitted functions appear as top-level `fn`s (so they are declared,
    ## checked, and lowered like any other), and a normal function can call one.
    var source = <<-SRC
        const function generate_helpers() -> void:
            emit function zero_meaning() -> int:
                return 0
            emit function hex_prefix() -> str:
                return "0x"

        function use_it() -> int:
            return zero_meaning()
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    ## Both emitted functions are spliced in as top-level declarations.
    expect(text.contains_substring("fn zero_meaning"))
    expect(text.contains_substring("fn hex_prefix"))
    ## The call resolves to the emitted function's linkage name.
    expect(text.contains_substring("return main_zero_meaning()"))


# =============================================================================
#  Format-string locals — the declared local must be visible to later
#  interpolations (a missing binding made `f"#{s}"` format a str as an int).
# =============================================================================

@[test]
function test_format_string_local_is_interpolated_as_str() -> void:
    var source = <<-SRC
        function render() -> str:
            let hex = f"n=#{1:x}"
            let combined = f"#{hex}"
            return combined
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    ## The `str` local interpolates through the str append, not the int one.
    expect(text.contains_substring("mt_format_append_str"))
    expect(not text.contains_substring("mt_format_append_int"))


# =============================================================================
#  Statement-position foreign-call hoisting — a statement-lowered foreign call
#  (a `str as cstr` argument needs a temporary) hoists its setup into the
#  statement stream instead of wrapping it in a StmtExpr, with the host's
#  per-statement shapes: a result temp before a return, the call itself for a
#  local/assignment, and a nil-line/path statement for a discarded call.
# =============================================================================

@[test]
function test_foreign_call_setup_hoists_at_statement_position() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_fhoist_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var raw_source = <<-SRC
        external

        struct Image:
            width: int

        external function ImageText(text: cstr, size: int) -> Image
    SRC
    if not write_source_file(root.as_str(), "raw.mt", raw_source):
        return

    var source = <<-SRC
        import raw

        public foreign function image_text(text: str as cstr, size: int) -> raw.Image = raw.ImageText

        function wrap_text(text: str) -> raw.Image:
            return image_text(text, 1)

        function feed(text: str) -> void:
            image_text(text, 2)

        function keep(text: str) -> void:
            var img = image_text(text, 3)
            img.width = 1
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()

    ## No statement-expression wrapper remains.
    expect(not dumped.contains_substring("IR::StmtExpr"))
    ## `return image_text(text, 1)`: the argument temp is declared, the call is
    ## materialized into `__mt_foreign_result_2`, the temp is freed, and the
    ## return uses the result temp.
    expect(dumped.contains_substring("(IR::LocalDecl :name \"__mt_foreign_arg_1\" :linkage_name \"__mt_foreign_arg_1\" :type (Types::Primitive :name \"cstr\") :value (IR::Call :callee \"mt_foreign_str_to_cstr_temp\""))
    expect(dumped.contains_substring("(IR::LocalDecl :name \"__mt_foreign_result_2\" :linkage_name \"__mt_foreign_result_2\" :type (Types::Struct :name \"Image\" :module_name \"raw\") :value (IR::Call :callee \"ImageText\" :arguments ((IR::Name :name \"__mt_foreign_arg_1\""))
    expect(dumped.contains_substring("(IR::ReturnStmt :value (IR::Name :name \"__mt_foreign_result_2\" :type (Types::Struct :name \"Image\" :module_name \"raw\") :pointer false)"))
    ## A discarded call is emitted by the foreign lowering itself, without the
    ## statement's line/path, and the free follows it.
    expect(dumped.contains_substring(":value 2 :type (Types::Primitive :name \"int\"))) :type (Types::Struct :name \"Image\" :module_name \"raw\")) :line nil :path nil) (IR::ExpressionStmt :expression (IR::Call :callee \"mt_free_foreign_cstr_temp\""))
    ## A local initializer takes the call as the declaration's value.
    expect(dumped.contains_substring("(IR::LocalDecl :name \"img\" :linkage_name \"img\" :type (Types::Struct :name \"Image\" :module_name \"raw\") :value (IR::Call :callee \"ImageText\""))


# =============================================================================
#  Pointer-like foreign arguments — an `inout`/`out` argument that already is a
#  C pointer (an editable method's `this` receiver) is cast to the boundary's
#  pointer type instead of being addressed again, and a statement-position
#  foreign call is emitted by the lowering itself (nil line/path).
# =============================================================================

@[test]
function test_pointer_receiver_foreign_argument_is_cast_not_addressed() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_ptrarg_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var raw_source = <<-SRC
        external

        struct Image:
            width: int

        external function ImageFormat(image: ptr[Image], newFormat: int) -> void
        external function RawPlain(x: int) -> void
    SRC
    if not write_source_file(root.as_str(), "raw.mt", raw_source):
        return

    var source = <<-SRC
        import raw

        public foreign function image_format(inout image: raw.Image, new_format: int) -> void = raw.ImageFormat
        public foreign function raw_plain(x: int) -> void = raw.RawPlain

        extending raw.Image:
            public editable function format(new_format: int) -> void:
                image_format(this, new_format)

        function poke(n: int) -> void:
            raw_plain(n)
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()

    ## `this` (already `Image*`) is cast to the boundary pointer, not `&this`.
    expect(dumped.contains_substring("(IR::Cast :target_type (Types::Generic :name \"ptr\" :arguments ((Types::Struct :name \"Image\" :module_name \"raw\"))) :expression (IR::Name :name \"this\" :type (Types::Struct :name \"Image\""))
    expect(not dumped.contains_substring("(IR::AddressOf :expression (IR::Name :name \"this\""))
    ## A plain statement-position foreign call is emitted by the lowering with
    ## nil line/path, like every discarded foreign call (the host's
    ## `discard_result`).
    expect(dumped.contains_substring("(IR::Call :callee \"RawPlain\" :arguments ((IR::Name :name \"n\" :type (Types::Primitive :name \"int\") :pointer false)) :type (Types::Primitive :name \"void\")) :line nil :path nil)"))


# =============================================================================
#  Inline foreign mappings — a referenced parameter is temporary-bound only
#  where the host binds one (`reference_count > 1 && !duplicable || !inlineable`);
#  every other argument value is substituted into the mapping instead.
# =============================================================================

@[test]
function test_mapping_arguments_are_substituted_not_tempped() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_maparg_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var raw_source = <<-SRC
        external

        struct Image:
            width: int

        external function ImageKernelConvolution(image: ptr[Image], kernel: ptr[float], kernelSize: int) -> void
    SRC
    if not write_source_file(root.as_str(), "raw.mt", raw_source):
        return

    var source = <<-SRC
        import raw

        public foreign function image_kernel_convolution(inout image: raw.Image, kernel: span[float]) -> void = raw.ImageKernelConvolution(image, kernel.data, int<-kernel.len)

        extending raw.Image:
            public editable function kernel_convolution(kernel: span[float]) -> void:
                image_kernel_convolution(this, kernel)
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()

    ## No mapping argument needed a temporary here: `this`'s cast and the
    ## `kernel` span are both inlineable (the host's substitution).
    expect(not dumped.contains_substring("__mt_foreign_arg"))
    ## The call's first argument is the receiver's cast, inlined.
    expect(dumped.contains_substring("(IR::Call :callee \"ImageKernelConvolution\" :arguments ((IR::Cast"))
    ## The mapping's `kernel.data` / `kernel.len` lower on the substituted name.
    expect(dumped.contains_substring("(IR::Member :receiver (IR::Name :name \"kernel\" :type (Types::Span :element_type (Types::Primitive :name \"float\")) :pointer false) :member \"data\""))
    expect(dumped.contains_substring("(IR::Cast :target_type (Types::Primitive :name \"int\") :expression (IR::Member :receiver (IR::Name :name \"kernel\""))


# =============================================================================
#  Inline mapping external calls — the embedded call is typed with the raw C
#  function's declared return type (the host's `owner_analysis` shape), not the
#  mapping's own return type; the member carries the mapping's type.
# =============================================================================

@[test]
function test_mapping_external_call_takes_the_declared_return_type() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_callty_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var raw_source = <<-SRC
        external

        struct Holder:
            values: array[int, 2]

        external function Fetch() -> Holder
    SRC
    if not write_source_file(root.as_str(), "raw.mt", raw_source):
        return

    var source = <<-SRC
        import raw

        public foreign function fetch_values() -> array[int, 2] = raw.Fetch().values

        function use() -> array[int, 2]:
            return fetch_values()
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()

    ## The `Fetch()` call carries the raw declaration's return type.
    expect(dumped.contains_substring("(IR::Call :callee \"Fetch\" :arguments () :type (Types::Struct :name \"Holder\" :module_name \"raw\"))"))
    ## The `.values` member carries the mapping's own return type.
    expect(dumped.contains_substring(":member \"values\" :type (Types::Generic :name \"array\" :arguments ((Types::Primitive :name \"int\") (Types::LiteralTypeArg :value 2)))"))


@[test]
function test_simple_mapping_call_takes_the_declared_return_type() -> void:
    ## A *simple* mapping's emitted C call carries the raw declaration's return
    ## type too (the 3f rule, on the simple path): `= c.getenv` with a
    ## `ptr[char]` declaration and a `cstr?` wrapper types the call
    ## `ptr[char]`, while the surrounding temp keeps the wrapper's `cstr?`.
    var root = fs.create_temporary_directory_in_system_temp("mtc_simplety_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var raw_source = <<-SRC
        external

        external function getenv(name: cstr) -> ptr[char]
    SRC
    if not write_source_file(root.as_str(), "raw.mt", raw_source):
        return

    var source = <<-SRC
        import raw as c

        public foreign function env(name: str as cstr) -> cstr? = c.getenv

        public function probe(name: str) -> cstr?:
            return env(name)
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()

    ## The `getenv` call carries the raw `ptr[char]` declaration's return type.
    expect(dumped.contains_substring("(IR::Call :callee \"getenv\" :arguments ((IR::Name :name \"__mt_foreign_arg_1\" :type (Types::Primitive :name \"cstr\") :pointer false)) :type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"char\"))))"))
    ## The result temp keeps the wrapper's `cstr?`.
    expect(dumped.contains_substring("LocalDecl :name \"__mt_foreign_result_2\" :linkage_name \"__mt_foreign_result_2\" :type (Types::Nullable :base (Types::Primitive :name \"cstr\"))"))


# =============================================================================
#  Guard-bound nullable pointer arithmetic — the binary's type is the unwrapped
#  pointer (the host's flow-refined operand type), not the storage `Nullable`.
# =============================================================================

@[test]
function test_guard_bound_nullable_pointer_arithmetic_is_unwrapped() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_ptradd_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        struct Block:
            data: ptr[ubyte]

        struct Region:
            blocks: ptr[Block]?
            count: ptr_uint

        extending Region:
            public function scan() -> bool:
                let blocks = this.blocks else:
                    return false
                unsafe:
                    var i: ptr_uint = 0
                    while i < this.count:
                        let b = read(blocks + i)
                        i += 1
                return false

            public function first() -> bool:
                let blocks = this.blocks else:
                    return false
                unsafe:
                    let b = read(blocks + 1)
                    return true
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let dumped = dump.as_str()

    ## The subtraction/additive result carries the pointer, not the `Nullable`
    ## storage — in the loop body and straight-line after the guard.
    expect(dumped.contains_substring(":right (IR::Name :name \"i\" :type (Types::Primitive :name \"ptr_uint\") :pointer false) :type (Types::Generic :name \"ptr\" :arguments ((Types::Struct :name \"Block\" :module_name \"main\")))"))
    expect(dumped.contains_substring(":right (IR::IntegerLiteral :value 1 :type (Types::Primitive :name \"int\")) :type (Types::Generic :name \"ptr\" :arguments ((Types::Struct :name \"Block\" :module_name \"main\")))"))
    expect(not dumped.contains_substring(":right (IR::Name :name \"i\" :type (Types::Primitive :name \"ptr_uint\") :pointer false) :type (Types::Nullable"))


# =============================================================================
#  Assignment literals take the target's type — `i = 1` / `i += 2` on a
#  `ptr_uint` target emit `ptr_uint` literals (the host's contextual conversion
#  at the assignment), not `int` ones.
# =============================================================================

@[test]
function test_assignment_literals_take_the_target_type() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_asglit_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        function f() -> ptr_uint:
            var i: ptr_uint = 0
            i = 1
            i += 2
            i -= 3
            return i
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("IR::IntegerLiteral :value 1 :type (Types::Primitive :name \"ptr_uint\")"))
    expect(text.contains_substring("IR::IntegerLiteral :value 2 :type (Types::Primitive :name \"ptr_uint\")"))
    expect(text.contains_substring("IR::IntegerLiteral :value 3 :type (Types::Primitive :name \"ptr_uint\")"))
    expect(not text.contains_substring("IR::IntegerLiteral :value 1 :type (Types::Primitive :name \"int\")"))


@[test]
function test_read_target_literals_take_the_pointee_type() -> void:
    ## `read(p) = 0` is the deref lvalue: the value literal takes the
    ## *pointee's* type (the host's `lower_contextual_expression` with the
    ## target's type), so a `ptr_uint` element gets a `ptr_uint` literal —
    ## `std/mem/heap.mt`'s `read(header - 1) = 0` (session 43, item 3l).
    var root = fs.create_temporary_directory_in_system_temp("mtc_readlit_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        function f(header: ptr[ptr_uint]) -> void:
            unsafe:
                read(header - 1) = 0
                read(header - 2) = 7
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::Unary :operator \"*\" :operand (IR::Binary :operator \"-\" :left (IR::Name :name \"header\""))
    expect(text.contains_substring("IR::IntegerLiteral :value 0 :type (Types::Primitive :name \"ptr_uint\")"))
    expect(text.contains_substring("IR::IntegerLiteral :value 7 :type (Types::Primitive :name \"ptr_uint\")"))
    expect(not text.contains_substring("IR::IntegerLiteral :value 0 :type (Types::Primitive :name \"int\")"))


@[test]
function test_call_argument_literals_take_the_parameter_type() -> void:
    ## The host lowers every call argument with the parameter as the expected
    ## type, so bare literals take the parameter's type: a plain call
    ## (`take(3)`), a method call (`a.add(1, 2)` — the monomorphized path) and
    ## a variant arm's field value (`V.a(x = 4)`) all emit `ptr_uint` literals
    ## for `ptr_uint` parameters (session 43, item 3m).
    var root = fs.create_temporary_directory_in_system_temp("mtc_arglit_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        struct A:
            x: ptr_uint

        extending A:
            public function add(a: ptr_uint, b: ptr_uint) -> ptr_uint:
                return a + b

        variant V:
            a(x: ptr_uint)
            b

        function take(n: ptr_uint) -> ptr_uint:
            return n

        function use(a: A) -> ptr_uint:
            let m = a.add(1, 2)
            if m > 0:
                return take(3)
            return m

        function mk() -> V:
            return V.a(x = 4)
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("IR::IntegerLiteral :value 1 :type (Types::Primitive :name \"ptr_uint\")"))
    expect(text.contains_substring("IR::IntegerLiteral :value 2 :type (Types::Primitive :name \"ptr_uint\")"))
    expect(text.contains_substring("IR::IntegerLiteral :value 3 :type (Types::Primitive :name \"ptr_uint\")"))
    expect(text.contains_substring("IR::IntegerLiteral :value 4 :type (Types::Primitive :name \"ptr_uint\")"))
    expect(not text.contains_substring("IR::IntegerLiteral :value 3 :type (Types::Primitive :name \"int\")"))
    expect(not text.contains_substring("IR::IntegerLiteral :value 4 :type (Types::Primitive :name \"int\")"))


@[test]
function test_generic_variant_arm_field_takes_the_instance_type() -> void:
    ## A *prelude* generic variant's arm field type is specialized on demand at
    ## a construction site: `Option[ptr_uint].some(value = 0)` (std/str.mt:220)
    ## must resolve `value` to the instance's `ptr_uint`, not leave the literal
    ## at its `int` default (session 43, item 3o).
    var root = fs.create_temporary_directory_in_system_temp("mtc_gvarlit_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        function f() -> Option[ptr_uint]:
            return Option[ptr_uint].some(value = 0)

        function g(x: ptr_uint) -> Option[ptr_uint]:
            if x == 0:
                return Option[ptr_uint].none
            return Option[ptr_uint].some(value = x)
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring(":arm_name \"some\" :fields ((IR::AggregateField :name \"value\" :value (IR::IntegerLiteral :value 0 :type (Types::Primitive :name \"ptr_uint\")))"))
    expect(not text.contains_substring(":arm_name \"some\" :fields ((IR::AggregateField :name \"value\" :value (IR::IntegerLiteral :value 0 :type (Types::Primitive :name \"int\")))"))


# =============================================================================
#  A `continue` in a plain `while` body lowers to a native `continue` (the
#  host's `loop_exit_continue` kind) — no goto label, since the loop's
#  condition is the continue point.
# =============================================================================

@[test]
function test_continue_in_a_plain_while_is_native() -> void:
    var source = <<-SRC
        function f() -> ptr_uint:
            var i: ptr_uint = 0
            while i < 10:
                i += 1
                if i == 3:
                    continue
            return i
    SRC
    var ir = lower_source(source)
    defer: ir.release()
    let text = ir.as_str()
    expect(text.contains_substring("continue"))
    expect(not text.contains_substring("goto"))
    expect(not text.contains_substring("__mt_loop_continue"))


@[test]
function test_break_in_a_plain_while_is_native() -> void:
    ## A `break` in a plain `while` lowers to a native `IR::BreakStmt` (the
    ## host's `loop_exit_statement` `:break` kind) — but a `break` inside a
    ## match's `switch` keeps the label/goto form, since C's `break` would exit
    ## the switch, not the loop (the host's `switch_loop_flow`; session 43,
    ## item 3i-b).
    var plain_source = <<-SRC
        function plain(x: int) -> int:
            var i: int = 0
            while i < 10:
                if i == x:
                    break
                i += 1
            return i
    SRC
    var plain_ir = lower_source(plain_source)
    defer: plain_ir.release()
    let plain_text = plain_ir.as_str()
    expect(plain_text.contains_substring("break"))
    expect(not plain_text.contains_substring("goto __mt_loop_break"))

    var switch_source = <<-SRC
        function switched(x: int) -> int:
            var i: int = 0
            while i < 10:
                match x:
                    1:
                        break
                    _:
                        i += 1
                i += 1
            return i
    SRC
    var switch_ir = lower_source(switch_source)
    defer: switch_ir.release()
    let switch_text = switch_ir.as_str()
    ## The switch arm's break keeps the labeled goto — the invalidation.
    expect(switch_text.contains_substring("goto __mt_loop_break"))
    expect(switch_text.contains_substring("label __mt_loop_break"))


@[test]
function test_raw_module_declaration_kinds_render_in_the_dump() -> void:
    ## A raw (`external`) module's enum/flags/opaque declarations are not in the
    ## IR (the module emits only includes), so the dumper classifies an imported
    ## nominal through the loaded modules' analyses: `c.Color` renders
    ## `Types::Enum`, `c.CameraProjection` `Types::Flags` and `c.Handle`
    ## `Types::Opaque` — where a bare fallback would say `Types::Struct`
    ## (session 43, item 3g).
    var root = fs.create_temporary_directory_in_system_temp("mtc_kinds_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var raw_source = <<-SRC
        external

        flags CameraProjection: int
            CAMERA_PERSPECTIVE = 0

        enum Color: int
            red = 1

        opaque Handle

        external function draw(color: Color) -> void
    SRC
    if not write_source_file(root.as_str(), "raw.mt", raw_source):
        return

    var source = <<-SRC
        import raw as c

        public type MyColor = c.Color

        function f(x: MyColor, h: c.Handle) -> int:
            let cam = c.CameraProjection.CAMERA_PERSPECTIVE
            return int<-x + int<-cam
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir_with_analyses(ir_program, program.analyses.as_span())
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(Types::Enum :name \"Color\" :module_name \"raw\")"))
    expect(text.contains_substring("(Types::Flags :name \"CameraProjection\" :module_name \"raw\")"))
    expect(text.contains_substring("(Types::Opaque :name \"Handle\" :module_name \"raw\")"))
    expect(not text.contains_substring("(Types::Struct :name \"Color\" :module_name \"raw\")"))


@[test]
function test_foreign_in_argument_addresses_the_resolved_boundary_type() -> void:
    ## An `in` foreign argument's address-of is typed with the host's
    ## `const_pointer_to(parameter.type)` — the *resolved* declared type (the
    ## wrapper alias `MyDef = c.Def` deepens to the raw `Def`), not a
    ## `ptr[void]` placeholder nor the alias name (session 43, item 3q).
    var root = fs.create_temporary_directory_in_system_temp("mtc_cptr_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var raw_dir = path_ops.join(root.as_str(), "std/c/raw")
    defer: raw_dir.release()
    match fs.create_directories(raw_dir.as_str()):
        Result.failure as f:
            var e = f.error
            e.release()
            return
        Result.success:
            pass

    var raw_source = <<-SRC
        external

        struct Def:
            x: int

        external function create(def: const_ptr[Def]) -> int
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public type MyDef = c.Def

        public foreign function create_it(in def: MyDef) -> int = c.create
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import wrap

        function use(d: wrap.MyDef) -> int:
            return wrap.create_it(d)
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::AddressOf :expression (IR::Name :name \"d\" :type (Types::Struct :name \"Def\" :module_name \"std.c.raw.lib\") :pointer false) :type (Types::Generic :name \"const_ptr\" :arguments ((Types::Struct :name \"Def\" :module_name \"std.c.raw.lib\")))"))
    expect(not text.contains_substring("const_ptr\" :arguments ((Types::Struct :name \"MyDef\""))


@[test]
function test_external_struct_equality_keeps_the_binary_and_registers_the_layout() -> void:
    ## `a == b` on a raw-module struct stays an `IR::Binary` — the host's IR
    ## shape — and the type's field layout is registered in
    ## `Program.external_structs` for the C backend's `mt_struct_eq_<T>`
    ## synthesis (session 43, item 3r).  The registration covers nested
    ## external structs, and no helper function appears in the IR.
    var root = fs.create_temporary_directory_in_system_temp("mtc_exteq_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var raw_dir = path_ops.join(root.as_str(), "std/c/raw")
    defer: raw_dir.release()
    match fs.create_directories(raw_dir.as_str()):
        Result.failure as f:
            var e = f.error
            e.release()
            return
        Result.success:
            pass

    var raw_source = <<-SRC
        external

        struct Part:
            index: int
            generation: uint

        struct Assembly:
            part: Part
            tag: int
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var source = <<-SRC
        import std.c.raw.lib as raw

        function same_part(a: raw.Part, b: raw.Part) -> bool:
            return a == b

        function differs(asm: raw.Assembly, other: raw.Assembly) -> bool:
            return asm != other
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var dump = sexpr.dump_ir(ir_program)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::Binary :operator \"==\" :left (IR::Name :name \"a\" :type (Types::Struct :name \"Part\" :module_name \"std.c.raw.lib\") :pointer false) :right (IR::Name :name \"b\" :type (Types::Struct :name \"Part\" :module_name \"std.c.raw.lib\") :pointer false) :type (Types::Primitive :name \"bool\"))"))
    expect(text.contains_substring("(IR::Binary :operator \"!=\" :left (IR::Name :name \"asm\" :type (Types::Struct :name \"Assembly\" :module_name \"std.c.raw.lib\") :pointer false)"))
    expect(not text.contains_substring("mt_struct_eq"))
    var has_part = false
    var has_assembly = false
    var li: ptr_uint = 0
    while li < ir_program.external_structs.len:
        let layout = unsafe: read(ir_program.external_structs.data + li)
        if layout.key == "std_c_raw_lib_Part":
            has_part = true
            expect(layout.fields.len == 2)
        if layout.key == "std_c_raw_lib_Assembly":
            has_assembly = true
            expect(layout.fields.len == 2)
        li += 1
    expect(has_part)
    expect(has_assembly)
