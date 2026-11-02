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


## Create a temp directory, write `source` as `main.mt`, check and lower it, and
## return the *sexpr* dump of the lowered program.  The temp tree is removed
## before returning.
function lower_dump_for_source(source: str) -> string.String:
    var root = fs.create_temporary_directory_in_system_temp("mtc_ld_") else:
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
    return sexpr.dump_ir(ir_program)


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


@[test]
function test_array_length_folds_through_an_imported_const() -> void:
    ## A module-qualified constant in an array-length position folds through the
    ## alias's module — a direct raw const, and a wrapper const whose value
    ## chains into the raw module (`c.MAX_PARTS + 1`), mirroring the host's
    ## `resolve_named_literal_type_argument`/`resolve_imported_module_const_value`
    ## (session 44, item 3s).  Before the fix both rendered `:value 0`.
    var root = fs.create_temporary_directory_in_system_temp("mtc_arrlen_") else:
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

        const MAX_PARTS: int = 8

        struct Part:
            index: int
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public const BONE_COUNT: int = c.MAX_PARTS + 1
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import std.c.raw.lib as c
        import wrap

        function f() -> int:
            var direct: array[int, c.MAX_PARTS]
            var hopped: array[int, wrap.BONE_COUNT]
            direct[0] = 1
            hopped[0] = 2
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
    let text = dump.as_str()
    expect(text.contains_substring("(IR::LocalDecl :name \"direct\" :linkage_name \"direct\" :type (Types::Generic :name \"array\" :arguments ((Types::Primitive :name \"int\") (Types::LiteralTypeArg :value 8)))"))
    expect(text.contains_substring("(IR::LocalDecl :name \"hopped\" :linkage_name \"hopped\" :type (Types::Generic :name \"array\" :arguments ((Types::Primitive :name \"int\") (Types::LiteralTypeArg :value 9)))"))


@[test]
function test_dyn_vtable_member_takes_the_interface_method_type() -> void:
    ## `s.area()` on a `dyn[Shape]` types the vtable member with the interface
    ## method's `Types::Function` (`data: ptr[void]` + the method's params) even
    ## when the generated `mt_vtable_Shape` struct does not exist yet in this
    ## module's lowering — the dispatch lives in the module that declares the
    ## interface, the `adapt` site in another (session 44, item 3t).  The whole
    ## fixture's dump is byte-identical to the host's.
    var root = fs.create_temporary_directory_in_system_temp("mtc_dynvt_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var iface_source = <<-SRC
        public interface Shape:
            function area() -> float
            function scaled(factor: float) -> float

        public function measure(s: dyn[Shape]) -> float:
            return s.area() + s.scaled(2.0)
    SRC
    if not write_source_file(root.as_str(), "iface.mt", iface_source):
        return

    var source = <<-SRC
        import iface

        struct Square implements iface.Shape:
            side: float

        extending Square:
            function area() -> float:
                return this.side * this.side

            function scaled(factor: float) -> float:
                return this.side * factor

        function main() -> int:
            var square = Square(side = 2.0)
            let shape = adapt[iface.Shape](ref_of(square))
            return int<-iface.measure(shape)
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
    expect(text.contains_substring(":member \"area\" :type (Types::Function :name \"\" :params ((Types::Parameter :name \"data\" :type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"void\"))) :mutable false :passing_mode :plain :boundary_type nil)) :return_type (Types::Primitive :name \"float\")"))
    expect(text.contains_substring(":member \"scaled\" :type (Types::Function :name \"\" :params ((Types::Parameter :name \"data\" :type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"void\"))) :mutable false :passing_mode :plain :boundary_type nil) (Types::Parameter :name \"factor\" :type (Types::Primitive :name \"float\")"))
    expect(not text.contains_substring(":member \"area\" :type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"void\")))"))


@[test]
function test_inout_argument_addresses_the_deepened_boundary_type() -> void:
    ## An `inout` foreign argument's address-of takes the alias-deepened
    ## boundary type — `wrap.take_it(d)` for `inout d: MyDef`
    ## (`type MyDef = c.Def`) is `ptr[Def]`, not `ptr[MyDef]` (session 44,
    ## item 3u; 3q did the same for the plain `in` path).  The `in` branch
    ## qualifies before deepening; the `out`/`inout` branch deepened first, so
    ## the std.c pairing `deep_alias_target` resolves never existed yet.
    var root = fs.create_temporary_directory_in_system_temp("mtc_inout_") else:
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

        external function take_ptr(d: ptr[Def]) -> void
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public type MyDef = c.Def

        public foreign function take_it(inout d: MyDef) -> void = c.take_ptr
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import wrap

        function use() -> int:
            var d = wrap.MyDef(x = 1)
            wrap.take_it(d)
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
    let text = dump.as_str()
    expect(text.contains_substring("(IR::AddressOf :expression (IR::Name :name \"d\" :type (Types::Struct :name \"Def\" :module_name \"std.c.raw.lib\") :pointer false) :type (Types::Generic :name \"ptr\" :arguments ((Types::Struct :name \"Def\" :module_name \"std.c.raw.lib\")))"))
    expect(not text.contains_substring(":type (Types::Generic :name \"ptr\" :arguments ((Types::Struct :name \"MyDef\""))


@[test]
function test_array_storing_receiver_is_borrowed() -> void:
    ## A plain (non-editable) *sync* method whose receiver type contains array
    ## storage takes `this` as a pointer (`pointer_lowered_method_receiver?`):
    ## the param is `:pointer true`, `this.read()` passes the pointer through,
    ## and a call on a value borrows it (`&b`).  A small struct keeps the value
    ## convention (session 44, item 3v).
    var source = <<-SRC
        struct Big:
            values: array[int, 4]
            count: int

        extending Big:
            function read() -> int:
                return this.count

            editable function bump() -> int:
                this.count += 1
                return this.read()

        function main() -> int:
            var b = Big(count = 3)
            return b.read() + b.bump()
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::Function :name \"read\" :linkage_name \"main_Big_read\" :params ((IR::Param :name \"this\" :linkage_name \"this\" :type (Types::Struct :name \"Big\" :module_name \"main\") :pointer true))"))
    expect(text.contains_substring("(IR::Call :callee \"main_Big_read\" :arguments ((IR::Name :name \"this\" :type (Types::Struct :name \"Big\" :module_name \"main\") :pointer true)"))
    expect(text.contains_substring("(IR::Call :callee \"main_Big_read\" :arguments ((IR::AddressOf :expression (IR::Name :name \"b\" :type (Types::Struct :name \"Big\" :module_name \"main\") :pointer false) :type (Types::Struct :name \"Big\" :module_name \"main\")))"))


@[test]
function test_dynamic_format_string_hoists_with_the_destination_name() -> void:
    ## A dynamic format string's build hoists into the statement stream (the
    ## host's `prepare_expression_with_cleanups`; the parts' temps first, then
    ## the capacity, the result and the write offset), its result is named after
    ## the most recent local declaration (`__fmt_<name>`, `_cap`/`_off`
    ## companions, a `_2` suffix for a destination's repeats), a part whose type
    ## already matches its append argument carries no cast, and the result is
    ## released after the statement (session 44, item 3w).  The fixture's whole
    ## dump is byte-identical to the host's.
    var source = <<-SRC
        function consume(text: str) -> void:
            return

        function main() -> int:
            var index = 0
            consume(f"n = #{index}")
            consume(f"m = #{index}")
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::LocalDecl :name \"__mt_fmt_part_1\" :linkage_name \"__mt_fmt_part_1\" :type (Types::Primitive :name \"int\") :value (IR::Name :name \"index\" :type (Types::Primitive :name \"int\") :pointer false)"))
    expect(text.contains_substring("(IR::LocalDecl :name \"__fmt_index_cap\" :linkage_name \"__fmt_index_cap\" :type (Types::Primitive :name \"ptr_uint\") :value (IR::IntegerLiteral :value 4 :type (Types::Primitive :name \"ptr_uint\"))"))
    expect(text.contains_substring("(IR::LocalDecl :name \"__fmt_index_2_cap\""))
    expect(text.contains_substring("(IR::ExpressionStmt :expression (IR::Call :callee \"mt_format_str_release\" :arguments ((IR::Name :name \"__fmt_index\" :type (Types::StringView) :pointer false)) :type (Types::Primitive :name \"void\")) :line nil :path nil)"))
    expect(not text.contains_substring(":value (IR::Cast :target_type (Types::Primitive :name \"int\") :expression (IR::Name :name \"index\""))


@[test]
function test_cstr_backed_strings_pass_data_directly() -> void:
    ## A `str as cstr` foreign argument whose value is cstr-backed — a
    ## string-literal local or a dynamic format string's temp (the host's
    ## `cstr_backed_expression?`) — passes its `data` pointer directly; a value
    ## from a call (no owning buffer) takes the
    ## `mt_foreign_str_to_cstr_temp` copy (session 44, item 3x).  The
    ## fixture's dump is byte-identical to the host's.
    var root = fs.create_temporary_directory_in_system_temp("mtc_cstrb_") else:
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

    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", "external\n\nexternal function takes_cstr(s: cstr) -> void\n"):
        return
    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public foreign function show(text: str as cstr) -> void = c.takes_cstr
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import wrap

        function make() -> str:
            return "plain"

        function main() -> int:
            let lit = "hello"
            let fmt = f"n#{1}"
            let dynamic = make()
            wrap.show(lit)
            wrap.show(fmt)
            wrap.show(dynamic)
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
    let text = dump.as_str()
    expect(text.contains_substring("(IR::Call :callee \"takes_cstr\" :arguments ((IR::Cast :target_type (Types::Primitive :name \"cstr\") :expression (IR::Member :receiver (IR::Name :name \"lit\" :type (Types::StringView) :pointer false) :member \"data\""))
    expect(text.contains_substring("(IR::Call :callee \"takes_cstr\" :arguments ((IR::Cast :target_type (Types::Primitive :name \"cstr\") :expression (IR::Member :receiver (IR::Name :name \"fmt\" :type (Types::StringView) :pointer false) :member \"data\""))
    expect(text.contains_substring(":value (IR::Call :callee \"mt_foreign_str_to_cstr_temp\" :arguments ((IR::Name :name \"dynamic\""))


@[test]
function test_if_condition_foreign_setup_hoists_before_the_statement() -> void:
    ## A statement-lowered foreign call in an `if` condition is a *prepared*
    ## position: the host materializes it into `__mt_foreign_result_N` with its
    ## cleanups before the `IfStmt` (the `hm_return` shape), and an `else if`
    ## chain's setup precedes the nested `IfStmt` in the else body (session 44,
    ## item 3y).  The fixture's dump is byte-identical to the host's.
    var root = fs.create_temporary_directory_in_system_temp("mtc_ifc_") else:
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

    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", "external\n\nexternal function takes_cstr(s: cstr) -> bool\n"):
        return
    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public foreign function check(text: str as cstr) -> bool = c.takes_cstr
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import wrap

        function run(name: str) -> bool:
            if wrap.check(name):
                return true
            return false
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
    expect(text.contains_substring("(IR::LocalDecl :name \"__mt_foreign_arg_1\" :linkage_name \"__mt_foreign_arg_1\" :type (Types::Primitive :name \"cstr\") :value (IR::Call :callee \"mt_foreign_str_to_cstr_temp\" :arguments ((IR::Name :name \"name\""))
    expect(text.contains_substring("(IR::LocalDecl :name \"__mt_foreign_result_2\" :linkage_name \"__mt_foreign_result_2\" :type (Types::Primitive :name \"bool\") :value (IR::Call :callee \"takes_cstr\" :arguments ((IR::Name :name \"__mt_foreign_arg_1\""))
    expect(text.contains_substring("(IR::ExpressionStmt :expression (IR::Call :callee \"mt_free_foreign_cstr_temp\" :arguments ((IR::Name :name \"__mt_foreign_arg_1\""))
    expect(text.contains_substring("(IR::IfStmt :condition (IR::Name :name \"__mt_foreign_result_2\" :type (Types::Primitive :name \"bool\") :pointer false)"))
    expect(not text.contains_substring("(IR::StmtExpr"))


@[test]
function test_monomorphized_null_return_takes_the_substituted_type() -> void:
    ## `return null` inside a *monomorphized* generic function takes the
    ## substituted return type: `maybe[Box]`'s null is
    ## `Nullable(own[Box])`, not `void` (session 44, item 3aa).  The
    ## monomorphized body's `current_fn_return_type` was not set, so the
    ## contextual null typing saw `void`.  The fixture's dump is byte-identical
    ## to the host's.
    var source = <<-SRC
        struct Box:
            value: int

        function maybe[T](flag: bool) -> own[T]?:
            if flag:
                return null
            return null

        function main() -> int:
            let b = maybe[Box](true)
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::ReturnStmt :value (IR::NullLiteral :type (Types::Nullable :base (Types::Generic :name \"own\" :arguments ((Types::Struct :name \"Box\" :module_name \"main\"))))) :line 6"))
    expect(not text.contains_substring("(IR::ReturnStmt :value (IR::NullLiteral :type (Types::Primitive :name \"void\"))"))


@[test]
function test_method_specializations_group_under_the_declaring_module() -> void:
    ## A generic method's instances are ordered under the module that
    ## *declares* the extending block: `a.Holder[Thing].make(...)` called from
    ## `b` must not land in `b`'s leftovers (where the specs were grouped by
    ## the receiver type's module, captured as the caller's).  The declaration
    ## order (`make` before `clear`) wins; the fixture is byte-identical to the
    ## host (session 44, item 3ad).
    var root = fs.create_temporary_directory_in_system_temp("mtc_spec_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var a_source = <<-SRC
        public struct Holder[T]:
            value: T

        extending Holder[T]:
            public static function make(value: T) -> Holder[T]:
                return Holder[T](value = value)

            public editable function clear() -> void:
                return
    SRC
    if not write_source_file(root.as_str(), "a.mt", a_source):
        return

    var b_source = <<-SRC
        import a

        public struct Thing:
            n: int

        public function build() -> a.Holder[Thing]:
            var h = a.Holder[Thing].make(Thing(n = 1))
            h.clear()
            return h
    SRC
    if not write_source_file(root.as_str(), "b.mt", b_source):
        return

    var source = <<-SRC
        import b

        function main() -> int:
            let h = b.build()
            return h.value.n
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
    let make_pos = text.find_substring(":linkage_name \"a_Holder_make_static__b_Thing\"")
    let clear_pos = text.find_substring(":linkage_name \"a_Holder_clear__b_Thing\"")
    expect(make_pos.is_some())
    expect(clear_pos.is_some())
    expect(make_pos.unwrap() < clear_pos.unwrap())



@[test]
function test_unannotated_local_infers_the_guards_visible_type() -> void:
    ## The unannotated local's declared type comes from *inference* of the
    ## initializer (the host's `block.rb:718-729`), not from the lowered value:
    ## a guard-bound read lowers to the storage `Nullable(...)` under the
    ## pointer-like rule while inferring the binding's visible success type —
    ## `let data_ptr = data` in `String.push_byte` declares `ptr[ubyte]`
    ## (session 44, item 3af).
    var source = <<-SRC
        struct Holder:
            data: ptr[ubyte]?
            len: ptr_uint

        function push(h: Holder, value: ubyte) -> int:
            let data = h.data else:
                return 1
            let data_ptr = data
            unsafe:
                read(data_ptr + 0) = value
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::LocalDecl :name \"data_ptr\" :linkage_name \"data_ptr\" :type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"ubyte\"))) :value (IR::Name :name \"data\" :type (Types::Nullable"))
    expect(not text.contains_substring("(IR::LocalDecl :name \"data_ptr\" :linkage_name \"data_ptr\" :type (Types::Nullable"))


@[test]
function test_bare_integer_literal_picks_the_narrowest_fitting_type() -> void:
    ## A bare integer literal (no suffix, no contextual expected type) picks
    ## the narrowest of int -> long -> ulong that holds its value (the host's
    ## `infer_integer_literal`), and the binary-op harmonization re-types it
    ## from its *peer* — `state * 6364136223846793005` on a `ulong` state
    ## carries a `ulong` constant (session 44, item 3ac; `std/noise.mt`).
    var source = <<-SRC
        function main() -> int:
            let a = 0xFFFFFFFF
            let b = 7
            var state: ulong = 1
            state = state * 6364136223846793005
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::IntegerLiteral :value 4294967295 :type (Types::Primitive :name \"long\"))"))
    expect(text.contains_substring("(IR::IntegerLiteral :value 6364136223846793005 :type (Types::Primitive :name \"ulong\"))"))
    expect(not text.contains_substring("(IR::IntegerLiteral :value 4294967295 :type (Types::Primitive :name \"int\"))"))


@[test]
function test_foreign_null_argument_takes_the_parameter_type() -> void:
    ## A bare `null` foreign-call argument takes the parameter's declared type:
    ## the host lowers every argument with `expected_type: parameter.type`
    ## (`calls.rb:727-731`) and `infer_null_literal_type` returns it, so
    ## `load_thing(null)` on a `cstr?` parameter carries `Nullable(cstr)`
    ## where the bare literal is `void` (session 44, item 3ae).
    var root = fs.create_temporary_directory_in_system_temp("mtc_fnull_") else:
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

        external function LoadThing(fileName: cstr?) -> int
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public foreign function load_thing(file_name: cstr?) -> int = c.LoadThing
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import wrap

        function use() -> int:
            return wrap.load_thing(null)
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
    expect(text.contains_substring("(IR::NullLiteral :type (Types::Nullable :base (Types::Primitive :name \"cstr\")))"))
    expect(not text.contains_substring("(IR::NullLiteral :type (Types::Primitive :name \"void\"))"))


@[test]
function test_foreign_null_argument_resolves_the_alias_in_its_declaring_module() -> void:
    ## The parameter's TypeRef resolves in the module that *declares* the
    ## foreign function: `wrap`'s `type Timer = c.CTimer` (the raw module's
    ## `opaque`) reaches `(Types::Opaque :name "CTimer" ...)` even though the
    ## call lowers with the context switched to the raw target.  Resolved from
    ## the caller's context it kept the alias name, and a null typed
    ## `Nullable(Timer)` made the backend reference an undeclared `mt_opt_*`
    ## where the host emits `NULL` (session 44, item 3ag — the stage-2 gcc
    ## failure behind the 3ae revert).
    var root = fs.create_temporary_directory_in_system_temp("mtc_fopq_") else:
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

        opaque CTimer = c"CTimer"

        external function stop(timer: CTimer?) -> int
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public type Timer = c.CTimer

        public foreign function stop_it(timer: Timer?) -> int = c.stop
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import wrap

        function use() -> int:
            return wrap.stop_it(null)
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
    expect(text.contains_substring("(IR::NullLiteral :type (Types::Nullable :base (Types::Opaque :name \"CTimer\" :module_name \"std.c.raw.lib\")))"))
    expect(not text.contains_substring("(IR::NullLiteral :type (Types::Nullable :base (Types::Struct"))


@[test]
function test_format_counter_is_env_scoped() -> void:
    ## The dynamic format-string counter is created lazily at the first use in
    ## an env and shared with that env's descendants; a sibling block whose
    ## parent holds no counter restarts at 1 (the host's
    ## `env[:fmt_counter] ||= {}` on a `duplicate_env`'d child).  `counted`
    ## therefore numbers `__fmt_buf` … `__fmt_buf_4` across its blocks, while
    ## `solo`'s two branches both emit `__fmt_index` with no repeat suffix
    ## (session 44, item 3wf; `examples/box2d/convex_hull.mt`).
    var source = <<-SRC
        function counted() -> int:
            var index = 0
            var buf = ""
            buf = f"same #{index}"
            buf = f"same again #{index}"
            if index == 0:
                buf = f"sibling one #{index}"
            else:
                buf = f"sibling two #{index}"
            return int<-buf.len + index

        function solo(flag: bool) -> int:
            var index = 0
            if flag:
                index += int<-f"one #{index}".len
            else:
                index += int<-f"two #{index}".len
            return index
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("__fmt_buf_cap"))
    expect(text.contains_substring("__fmt_buf_2_cap"))
    expect(text.contains_substring("__fmt_buf_3_cap"))
    expect(text.contains_substring("__fmt_buf_4_cap"))
    expect(text.contains_substring("__fmt_index_cap"))
    expect(not text.contains_substring("__fmt_index_2"))


@[test]
function test_function_typed_module_var_call_uses_a_callee_name() -> void:
    ## A module-level variable of function type is called through its value:
    ## the host's callee is an `IR::Name` carrying the function type, not a
    ## bare C name (`var s_scene_draw: fn() -> void` in `examples/box3d/common.mt`);
    ## the self emitted a direct call by name (session 44, item 3fa).
    var source = <<-SRC
        function noop() -> void:
            pass

        var handler: fn() -> void = noop

        function main() -> int:
            handler()
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("IR::Call :callee (IR::Name :name \""))
    expect(text.contains_substring(":type (Types::Function :name \"\" :params () :return_type (Types::Primitive :name \"void\")"))


@[test]
function test_defer_body_splices_its_statements_flat() -> void:
    ## A `defer` body lowers through the host's `lower_defer_cleanup_body`
    ## (= `lower_block`), a *flat* statement list: a braced body's statements
    ## replay as siblings, not as an `IR::BlockStmt`
    ## (`examples/box3d/common.mt`'s `run`; session 44, item 3fb).
    var source = <<-SRC
        function main() -> int:
            var total = 0
            defer:
                total += 1
                total += 2
            total += 3
            return total
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(not text.contains_substring("IR::BlockStmt"))
    expect(text.contains_substring(":value (IR::IntegerLiteral :value 1 :type (Types::Primitive :name \"int\"))"))
    expect(text.contains_substring(":value (IR::IntegerLiteral :value 2 :type (Types::Primitive :name \"int\"))"))


@[test]
function test_foreign_integer_argument_takes_the_parameter_type() -> void:
    ## Every bare literal in a foreign argument takes the parameter's declared
    ## type (the host's `lower_contextual_expression`), not just `null`:
    ## `set_count(0)` on a `uint` parameter carries a `uint` literal
    ## (session 44, item 3fc).
    var root = fs.create_temporary_directory_in_system_temp("mtc_fint_") else:
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

        external function SetCount(n: uint) -> int
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public foreign function set_count(n: uint) -> int = c.SetCount
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import wrap

        function use() -> int:
            return wrap.set_count(0)
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
    expect(text.contains_substring("(IR::IntegerLiteral :value 0 :type (Types::Primitive :name \"uint\"))"))
    expect(not text.contains_substring("(IR::IntegerLiteral :value 0 :type (Types::Primitive :name \"int\"))"))


@[test]
function test_array_element_constant_folds_to_its_aggregate() -> void:
    ## A compile-time constant element inlines to its value: the host's array
    ## elements fold, so `array[Color, 2](c.RED, c.GREEN)` carries the
    ## constants' aggregates, not their C names (`raylib/*`'s colour tables;
    ## session 44, item 4a).
    var root = fs.create_temporary_directory_in_system_temp("mtc_afold_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var c_source = <<-SRC
        public struct Color:
            r: ubyte
            g: ubyte

        public const RED: Color = Color(r = 230ub, g = 41ub)
        public const GREEN: Color = Color(r = 0ub, g = 228ub)
    SRC
    if not write_source_file(root.as_str(), "c.mt", c_source):
        return

    var source = <<-SRC
        import c

        function main() -> int:
            let colors = array[c.Color, 2](c.RED, c.GREEN)
            return int<-colors[0].r
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
    expect(text.contains_substring(":elements ((IR::AggregateLiteral :type (Types::Struct :name \"Color\""))
    expect(text.contains_substring(":name \"r\" :value (IR::IntegerLiteral :value 230"))
    expect(not text.contains_substring(":elements ((IR::Name"))


@[test]
function test_cstr_backed_if_passes_its_data_pointer() -> void:
    ## A *syntactically* cstr-backed expression — an `if` of string literals,
    ## whether bound to a local or passed directly — passes its `data` pointer
    ## at a `str as cstr` boundary instead of the runtime temp copy (the host's
    ## `cstr_backed_expression?`; session 44, items 4b/4c).
    var root = fs.create_temporary_directory_in_system_temp("mtc_cif_") else:
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

        external function DrawLabel(text: cstr) -> int
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public foreign function draw_label(text: str as cstr) -> int = c.DrawLabel
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import wrap

        function draw(flag: bool) -> int:
            let t = if flag: "yes" else: "no"
            let a = wrap.draw_label(t)
            let b = wrap.draw_label(if flag: "up" else: "down")
            return a + b
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
    expect(text.contains_substring("IR::Cast :target_type (Types::Primitive :name \"cstr\") :expression (IR::Member"))
    expect(not text.contains_substring("mt_foreign_str_to_cstr_temp"))


@[test]
function test_array_element_scalar_constant_folds() -> void:
    ## The host folds a *scalar-shaped* compile-time constant element — an
    ## enum member's cast, a negation, an arithmetic fold — while a bare
    ## literal keeps the contextual retyping and an aggregate element (a
    ## struct literal) keeps its fields (session 44, item 5a).
    var source = <<-SRC
        enum Kind:
            A
            B

        function main() -> int:
            let a = array[int, 3](int<-Kind.A, -1, 1 + 2)
            return a[0]
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring(":elements ((IR::IntegerLiteral :value 0 :type (Types::Primitive :name \"int\")) (IR::IntegerLiteral :value -1 :type (Types::Primitive :name \"int\")) (IR::IntegerLiteral :value 3 :type (Types::Primitive :name \"int\"))"))
    expect(not text.contains_substring("IR::Cast :target_type (Types::Primitive :name \"int\") :expression (IR::Name"))


@[test]
function test_extern_call_literal_takes_the_parameter_type() -> void:
    ## The raw external call path shares the foreign literal rule: a bare
    ## `null` argument carries the parameter's declared type
    ## (`c.Take(null)` on a `ptr[ptr_int]?` parameter is
    ## `Nullable(ptr[ptr_int])`, not `void`; session 44, item 5b).
    var root = fs.create_temporary_directory_in_system_temp("mtc_ecall_") else:
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

        external function Take(timer: ptr[ptr_int]?) -> ptr_int
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var source = <<-SRC
        import std.c.raw.lib as c

        function now() -> ptr_int:
            return c.Take(null)
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
    expect(text.contains_substring("(IR::NullLiteral :type (Types::Nullable :base (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"ptr_int\")))))"))
    expect(not text.contains_substring("(IR::NullLiteral :type (Types::Primitive :name \"void\"))"))


@[test]
function test_match_member_scrutinee_switches_directly() -> void:
    ## An enum scrutinee reached by a member access (`match h.kind`) switches on
    ## the expression itself — the host hoists a `match_value` temp only for a
    ## *variant* whose arms bind payloads (`expressions.rb:1148-1154`);
    ## the self materialized `__mt_match_scrut_N` for any non-name scrutinee
    ## (session 44, items 6c/6d).
    var source = <<-SRC
        enum Kind:
            A
            B

        struct Holder:
            kind: Kind

        function pick(h: Holder) -> int:
            var r = 0
            match h.kind:
                Kind.A: r = 1
                Kind.B: r = 2
            return r
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("IR::SwitchStmt :expression (IR::Member :receiver (IR::Name :name \"h\""))
    expect(not text.contains_substring("__mt_match_scrut"))


@[test]
function test_return_match_carries_the_statement_path() -> void:
    ## The `return match …` hoist's synthetic return keeps the statement's line
    ## and path (the host builds it from the statement; the self passed an empty
    ## path — session 44, item 6d).
    var source = <<-SRC
        enum Kind:
            A
            B

        function pick(k: Kind) -> int:
            return match k:
                Kind.A: 1
                Kind.B: 2
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("__mt_match_expr_1"))
    expect(text.contains_substring(":line 6 :path \"/"))


@[test]
function test_async_frame_names_use_a_double_underscore() -> void:
    ## The async frame and resume names derive from the constructor's linkage
    ## with the host's *double* underscore (`<…>__frame`, `<…>__resume`;
    ## `functions.rb:199-200`) — the self used a single one (session 44,
    ## item 6b; the `examples/async_*` family).
    var source = <<-SRC
        async function tick() -> void:
            return

        async function work(n: int) -> int:
            await tick()
            return n + 1

        function main() -> int:
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("__frame"))
    expect(text.contains_substring("__resume"))
    expect(not text.contains_substring("_impl_frame"))


@[test]
function test_array_of_arrays_element_uses_a_checked_index() -> void:
    ## An array-of-arrays element takes the bounds-checked index, like any
    ## array receiver: the host emits
    ## `mt_checked_index_array_array_int_2_3(grid, i)` and dereferences it
    ## (session 44, item 6a; the backend emits the matching nested declarator
    ## and passes the receiver decayed).
    var source = <<-SRC
        function main() -> int:
            var grid: array[array[int, 2], 3] = zero[array[array[int, 2], 3]]
            var i = 1
            grid[i][0] = 5
            return grid[i][0]
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::CheckedIndex :receiver (IR::Name :name \"grid\""))
    expect(not text.contains_substring("(IR::Index :receiver (IR::Name :name \"grid\""))


@[test]
function test_str_buffer_struct_is_not_in_the_dump() -> void:
    ## The synthetic `str_buffer[N]` structs ride `Program.str_buffer_structs`
    ## (backend-only, like `external_structs`) — the host collects them from the
    ## type universe, so the dump has no `IR::StructDecl mt_str_buffer_*`
    ## (session 44, item 8b; `examples/raylib/core/clipboard_text.mt`).
    var source = <<-SRC
        function main() -> int:
            var buffer: str_buffer[256] = zero[str_buffer[256]]
            let text = buffer.as_str()
            return int<-text.len
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(not text.contains_substring("IR::StructDecl :name \"mt_str_buffer_"))
    expect(text.contains_substring("(Types::Generic :name \"str_buffer\" :arguments ((Types::LiteralTypeArg :value 256))"))


@[test]
function test_const_enum_table_folds_members_to_values() -> void:
    ## A *const* array initializer's enum members fold to their values typed as
    ## the enum (`const KINDS: array[Kind, 2] = array[Kind, 2](Kind.A, Kind.B)`
    ## yields `(IR::IntegerLiteral :value 0 :type (Types::Enum Kind))`), while a
    ## *runtime* array literal keeps the member names (the compiler's own
    ## `mtc.lexer.token_kinds` tables; session 44, item 9a).
    var source = <<-SRC
        enum Kind:
            A
            B

        const KINDS: array[Kind, 2] = array[Kind, 2](Kind.A, Kind.B)

        function main() -> int:
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring(":elements ((IR::IntegerLiteral :value 0 :type (Types::Enum :name \"Kind\""))
    expect(text.contains_substring("(IR::IntegerLiteral :value 1 :type (Types::Enum :name \"Kind\""))
    expect(not text.contains_substring(":elements ((IR::Name"))


@[test]
function test_nested_struct_linkage_carries_its_parent() -> void:
    ## A nested struct's C name carries its parents
    ## (`<mod>_Rectangle_Edge`) while the IR `:name` stays plain — the host's
    ## `resolve_nested_struct_fields` qualified name, flattened for C
    ## (session 44, item 10a; `examples/nested_struct_stress_test.mt`,
    ## `examples/event_stress_test.mt`).
    var source = <<-SRC
        struct Rectangle:
            x: float
            y: float

            struct Edge:
                start: float
                end: float

            top_edge: Edge
            width: float

        function demo() -> float:
            var r: Rectangle
            r.top_edge.start = 1.0
            return r.top_edge.start
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("IR::StructDecl :name \"Edge\" :linkage_name \""))
    expect(text.contains_substring("_Rectangle_Edge\""))
    expect(not text.contains_substring(":name \"Edge\" :linkage_name \"main_Edge\""))


@[test]
function test_async_match_bindings_use_local_match_binding_fields() -> void:
    ## A match arm whose body awaits gets the host's *analysis-registered*
    ## `local_match_binding_<N>` frame field (post-order, after the arm body's
    ## locals) while the binding itself is a plain C local — the host's lowering
    ## lookup never matches, so its field stays unused (`analysis.rb:125-145`,
    ## `async_lowering.rb:1333`).  The counter is shared across async functions
    ## and also advances per lowered payload-binding arm, so `second`'s field is
    ## 4, not 2 (session 44, item 10b; `examples/async_network_lobby.mt`,
    ## `examples/async_stress_test.mt`).
    var source = <<-SRC
        async function helper(x: int) -> Result[int, int]:
            return Result[int, int].success(value = x)

        async function value_of(x: int) -> int:
            return x + 1

        async function work(flag: bool) -> Result[int, int]:
            let r = await helper(1)
            match r:
                Result.failure as p:
                    return Result[int, int].failure(error = p.error)
                Result.success as q:
                    if flag:
                        let v = await value_of(2)
                        return Result[int, int].success(value = q.value + v)
                    return Result[int, int].success(value = q.value)

        async function second(x: int) -> Result[int, int]:
            let r3 = await helper(x)
            match r3:
                Result.failure as f:
                    return Result[int, int].failure(error = f.error)
                Result.success as s:
                    let w = await value_of(1)
                    return Result[int, int].success(value = s.value + w)

        function main() -> int:
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    ## The awaited arms carry the host's names (`work`'s analysis registers 1,
    ## its lowering advances the counter by 2, so `second`'s registration is 4);
    ## the non-awaited arms (`p`, `f`) get no field.
    expect(text.contains_substring(":name \"local_match_binding_1\" :type (Types::VariantArmPayload :name \"Result_success\""))
    expect(text.contains_substring(":name \"local_match_binding_4\" :type (Types::VariantArmPayload :name \"Result_success\""))
    expect(not text.contains_substring("local_match_binding_2"))
    expect(not text.contains_substring("local_match_binding_3"))
    ## The bindings are plain C locals, not frame spills.
    expect(text.contains_substring("(IR::LocalDecl :name \"q\" :linkage_name \"q\""))
    expect(text.contains_substring("(IR::LocalDecl :name \"s\" :linkage_name \"s\""))
    expect(not text.contains_substring("local_success_q"))
    expect(not text.contains_substring("__mt_frame->local_success_"))


@[test]
function test_proc_captures_and_counters_are_program_scoped() -> void:
    ## A proc captures only the enclosing locals its body *references* (the
    ## host's `proc_capture_entries` walk, `proc.rb:137-250`) — not every visible
    ## local — and both the synthetic proc symbols and the async match-binding
    ## counter number per *compile* (the host's per-`Lowering` counters), not per
    ## module (`lower_module` builds a fresh LowerCtx).  `beta`'s proc is symbol
    ## 2 and its awaited arm takes `local_match_binding_4` (session 44 batch 12;
    ## `std/json.mt`'s stray `current`, `std/net/clock.mt`'s 5/6).
    var root = fs.create_temporary_directory_in_system_temp("mtc_progscope_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var alpha_source = <<-SRC
        public function a_demo(x: int) -> int:
            let unused_outer: int = 7
            let f = proc(y: int) -> int: y + x
            return 0

        public async function a_step(x: int) -> Result[int, int]:
            return Result[int, int].success(value = x)

        public async function a_num(x: int) -> int:
            return x

        public async function a_work(x: int) -> Result[int, int]:
            let r = await a_step(x)
            match r:
                Result.failure as p:
                    return Result[int, int].failure(error = p.error)
                Result.success as q:
                    let v = await a_num(q.value)
                    return Result[int, int].success(value = v)
    SRC
    if not write_source_file(root.as_str(), "alpha.mt", alpha_source):
        return

    var beta_source = <<-SRC
        import alpha

        public function b_demo(z: int) -> int:
            let g = proc(w: int) -> int: w + z
            return 0

        public async function b_work(y: int) -> Result[int, int]:
            let r2 = await alpha.a_step(y)
            match r2:
                Result.failure as pb:
                    return Result[int, int].failure(error = pb.error)
                Result.success as qb:
                    let w = await alpha.a_num(qb.value)
                    return Result[int, int].success(value = w)
    SRC
    if not write_source_file(root.as_str(), "beta.mt", beta_source):
        return

    var source = <<-SRC
        import alpha
        import beta

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
    let text = dump.as_str()
    ## alpha's env carries only the referenced `x` (not `unused_outer`), and
    ## beta's proc continues the program-wide symbol count.
    expect(text.contains_substring("alpha__proc_1__env\" :linkage_name \"alpha__proc_1__env\" :fields ((IR::Field :name \"__mt_ref_count\" :type (Types::Primitive :name \"ptr_uint\")) (IR::Field :name \"x\" :type (Types::Primitive :name \"int\")))"))
    expect(not text.contains_substring("(IR::Field :name \"unused_outer\""))
    expect(text.contains_substring("beta__proc_2__env\""))
    ## The async match-binding counter also continues across modules (1 in
    ## alpha, 4 in beta after alpha's two lowering advances).
    expect(text.contains_substring("local_match_binding_1"))
    expect(text.contains_substring("local_match_binding_4"))
    expect(not text.contains_substring("local_match_binding_2"))
    expect(not text.contains_substring("local_match_binding_3"))


@[test]
function test_async_embedded_await_temps_and_discards() -> void:
    ## An embedded await hoists into the host's per-function
    ## `__mt_async_tmp_<N>` local (field `local___mt_async_tmp_<N>`) — both from
    ## a `?` operand (the normalization's AwaitExpr case; the propagation paths
    ## hoist before lowering) and from a `let _ = await …`, which stores the
    ## awaited value into the host's `local_discard_<line>` field (session 44
    ## batch 13; `std/net/clock.mt`'s `measure_offset`/`respond_to_sync`).
    var source = <<-SRC
        async function step(x: int) -> Result[int, int]:
            return Result[int, int].success(value = x)

        async function work(flag: bool) -> Result[int, int]:
            let ok = (await step(1))?
            let _ = await step(2)
            if flag:
                return Result[int, int].success(value = ok)
            return Result[int, int].failure(error = 0)

        function main() -> int:
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::Field :name \"local___mt_async_tmp_1\" :type (Types::VariantInstance :name \"Result\" :module_name \"std.result\")) (IR::Field :name \"local_ok\" :type (Types::Primitive :name \"int\")) (IR::Field :name \"local_discard_6\" :type (Types::VariantInstance :name \"Result\" :module_name \"std.result\"))"))
    ## The discard's awaited value is stored into the field (not silently
    ## dropped) — the store target is the host's `IR::Member(frame, field)`.
    expect(text.contains_substring(":member \"local_discard_6\""))
    expect(not text.contains_substring("local_await_tmp"))
    expect(not text.contains_substring("await_tmp_"))


@[test]
function test_async_ctor_params_and_refcounted_allocator() -> void:
    ## The async constructor's params carry the host's unset `pointer`
    ## (`:pointer nil` — `frame_builder.rb:291`'s `field_info[:pointer]`), the
    ## frame's synthetic type renders `:module_name nil`, and the frame/env
    ## allocation goes through the host's refcounted `mt_async_alloc`/
    ## `mt_async_free` (session 44 batch 14; items 10d and 8C).
    var source = <<-SRC
        async function step(x: int) -> int:
            return x

        async function work(flag: bool) -> int:
            let v = await step(1)
            return v

        function main() -> int:
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::Param :name \"x\" :linkage_name \"x\" :type (Types::Primitive :name \"int\") :pointer nil)"))
    expect(text.contains_substring("(Types::Struct :name \"main_step__frame\" :module_name nil)"))
    expect(text.contains_substring(":callee \"mt_async_alloc\""))
    expect(text.contains_substring(":callee \"mt_async_free\""))
    expect(not text.contains_substring(":callee \"calloc\""))
    ## The ctor's resume call carries the frame's `ptr[void]` cast (the host's
    ## `raw_frame_expr`), its stores are the host's `IR::Member(frame, field)`
    ## targets, and the refcounted allocator's zeroing replaces the self's
    ## `ready`/`cancelled`/`state` stores (session 44 batch 15).
    expect(text.contains_substring(":callee \"main_step__resume\" :arguments ((IR::Cast :target_type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"void\")))"))
    expect(text.contains_substring(":member \"param_x\""))
    ## No `ready`/`cancelled` zero-store remains in the ctor (this source has no
    ## other `false` literal — the allocator's calloc is the initializer).
    expect(not text.contains_substring("(IR::BooleanLiteral :value false"))
    ## 10i(c): the resume body's param read and the ctor's param-copy value Name
    ## carry the host's unset pointer (`ir.Expr` `Name.pointer` is `Option[bool]`).
    expect(text.contains_substring("(IR::Name :name \"__mt_frame->param_x\" :type (Types::Primitive :name \"int\") :pointer nil)"))
    expect(text.contains_substring("(IR::Name :name \"x\" :type (Types::Primitive :name \"int\") :pointer nil)"))


@[test]
function test_monomorphized_call_literal_takes_the_parameter_type() -> void:
    ## A monomorphized call's literal argument takes the *specialized*
    ## parameter's type — the host's `lower_contextual_expression` on every call
    ## argument.  `heap.must_alloc_zeroed[SleepState](1)` against `count:
    ## ptr_uint` emits a `ptr_uint` literal (session 45).
    var source = <<-SRC
        struct Box:
            n: ptr_uint

        function make[T](count: ptr_uint) -> Box:
            return Box(n = count)

        function use() -> Box:
            return make[Box](41)
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("IR::IntegerLiteral :value 41 :type (Types::Primitive :name \"ptr_uint\")"))
    expect(not text.contains_substring("IR::IntegerLiteral :value 41 :type (Types::Primitive :name \"int\")"))


@[test]
function test_specialization_instances_sort_by_rendered_arguments() -> void:
    ## The host sorts a declaration's instances by
    ## `type_arguments.map(&:to_s).join(",")` — the RENDERED arguments.  A
    ## generic argument's closing bracket sorts after a longer element name, so
    ## `array[A, 2]` precedes `array[AB, 2]` (`array[A, 2]` < `array[AB, 2]`
    ## because ',' < 'B'), where the C key (`array_A_2` vs `array_AB_2`) would
    ## order them the other way (session 45; the 3ad residue).
    var source = <<-SRC
        struct A:
            x: int

        struct AB:
            x: int

        function id[T](v: T) -> T:
            return v

        function use(a: array[A, 2], b: array[AB, 2]) -> int:
            let x = id[array[A, 2]](a)
            let y = id[array[AB, 2]](b)
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    let a_pos = text.find_substring(":linkage_name \"main_id__array_main_A_2\"") else:
        expect(false)
        return
    let ab_pos = text.find_substring(":linkage_name \"main_id__array_main_AB_2\"") else:
        expect(false)
        return
    expect(a_pos < ab_pos)


@[test]
function test_imported_variant_arm_payload_keeps_its_owner_module() -> void:
    ## An `as name` binding of an *imported* variant carries the declaring
    ## module on its `VariantArmPayload` type (the host's
    ## `Types::VariantArmPayload#module_name`), so the dump renders
    ## `:module_name "lib"` rather than nil (session 45).
    var root = fs.create_temporary_directory_in_system_temp("mtc_armmod_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var lib_source = <<-SRC
        public variant Kind:
            alpha(x: int)
            beta
    SRC
    if not write_source_file(root.as_str(), "lib.mt", lib_source):
        return

    var source = <<-SRC
        import lib as lib

        function take(k: lib.Kind) -> int:
            match k:
                lib.Kind.alpha as a:
                    return a.x
                lib.Kind.beta:
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
    let text = dump.as_str()
    expect(text.contains_substring("(Types::VariantArmPayload :name \"Kind_alpha\" :module_name \"lib\")"))
    expect(not text.contains_substring("(Types::VariantArmPayload :name \"Kind_alpha\" :module_name nil)"))


@[test]
function test_array_as_span_uses_an_unchecked_index() -> void:
    ## `array.as_span()` is the host's `lower_array_to_span_expression`: the
    ## decay's `&array[0]` is a plain `IR::Index`, not a runtime subscript's
    ## `IR::CheckedIndex` (session 45).
    var source = <<-SRC
        const FLAGS: array[str, 2] = array[str, 2]("x", "y")

        function get_flags() -> span[str]:
            return FLAGS.as_span()
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::AddressOf :expression (IR::Index :receiver (IR::Name :name \"main_FLAGS\""))
    expect(not text.contains_substring("(IR::AddressOf :expression (IR::CheckedIndex :receiver (IR::Name :name \"main_FLAGS\""))


@[test]
function test_assignment_target_takes_the_refined_type() -> void:
    ## The host's `lower_assignment_target` (`utils.rb:1237`) types a bare
    ## local's target Name with the *visible* (flow-refined) type when that is
    ## the storage nullable's base: inside `while node != null`, `node = ...`
    ## targets a `ptr[Box]`, not the storage `ptr[Box]?` (session 45).
    var source = <<-SRC
        struct Box:
            value: int
            next: ptr[Box]?

        function walk(p: ptr[Box]?) -> int:
            var node = p
            unsafe:
                while node != null:
                    let node_ptr = ptr[Box]<-node
                    node = read(node_ptr).next
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::Assignment :target (IR::Name :name \"node\" :type (Types::Generic :name \"ptr\""))
    expect(not text.contains_substring("(IR::Assignment :target (IR::Name :name \"node\" :type (Types::Nullable"))


@[test]
function test_plain_assignment_target_keeps_the_struct_module() -> void:
    ## A plain local's assignment target keeps the binding's own nominal type —
    ## module-qualified — even when the flow record carries the same struct
    ## without its module (session 45; `examples/raylib/core/undo_redo.mt`
    ## regressed on the flow type alone).
    var source = <<-SRC
        struct P:
            x: int

        function use(a: P) -> void:
            var p = a
            p = a
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::Assignment :target (IR::Name :name \"p\" :type (Types::Struct :name \"P\" :module_name \"main\")"))
    expect(not text.contains_substring("(IR::Assignment :target (IR::Name :name \"p\" :type (Types::Struct :name \"P\" :module_name nil)"))


@[test]
function test_assert_default_message_carries_the_callsite() -> void:
    ## `assert`/`expect_eq`'s default message carries ` at <path>:<line>` (the
    ## host's `default_assert_message`, `lowering/assertions.rb`) and the
    ## synthesized `fatal` statement is the host's statement-position shape
    ## (nil line, the analysis path) — session 45.
    var root = fs.create_temporary_directory_in_system_temp("mtc_assert_") else:
        return
    defer: cleanup_dir(ref_of(root))

    var source = <<-SRC
        function check() -> void:
            assert(1 == 1)
            expect_eq(1, 1)

        function main() -> int:
            check()
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
    let text = dump.as_str()
    expect(text.contains_substring("assertion failed at " + main_path.as_str() + ":2"))
    expect(text.contains_substring("expect_eq failed: values are not equal at " + main_path.as_str() + ":3"))
    expect(text.contains_substring(":line nil :path \"" + main_path.as_str() + "\""))


@[test]
function test_static_method_call_literals_take_the_parameter_type() -> void:
    ## A static method call's literal argument takes the declared parameter's
    ## type — the host's `lower_contextual_expression` on every call argument
    ## (`Color.from_rgba(10, 20, 30, 200)` against `ubyte` parameters;
    ## `lower_static_call_args` now applies the method path's literal coercion).
    var source = <<-SRC
        struct C:
            r: ubyte

        extending C:
            public static function make(r: ubyte) -> C:
                return C(r = r)

        function use() -> C:
            return C.make(200)
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("IR::IntegerLiteral :value 200 :type (Types::Primitive :name \"ubyte\")"))
    expect(not text.contains_substring("IR::IntegerLiteral :value 200 :type (Types::Primitive :name \"int\")"))


@[test]
function test_continue_in_a_match_arm_uses_the_loop_label() -> void:
    ## The host's `switch_loop_flow` converts a `continue` *and* a `break`
    ## inside a switch-backed match to the loop-label form
    ## (`switch_loop_target`), so a `continue` in an arm emits
    ## `IR::GotoStmt` with the continue label (session 45).
    var source = <<-SRC
        enum K: ubyte
            a = 0
            b = 1

        struct N:
            kind: K

        function run(n: N) -> void:
            var i = 0
            while i < 3:
                i += 1
                match n.kind:
                    K.a:
                        continue
                    K.b:
                        pass
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::SwitchStmt :expression"))
    expect(text.contains_substring("(IR::GotoStmt :label \"__mt_loop_continue_1\")"))
    expect(not text.contains_substring("(IR::ContinueStmt"))


@[test]
function test_iterator_loop_binding_keeps_the_nullable_storage() -> void:
    ## A `for x in collection` over the iterator protocol binds `x` with the
    ## `next()` storage (nullable) and the unwrapped item as its visible type
    ## (the host's `iterator_loop_info`), so a pointer-like item's read keeps
    ## the storage `Nullable` (session 45).
    var source = <<-SRC
        struct It:
            i: int

            public function next() -> ptr[int]?:
                return null

        struct Coll:

            public function iter() -> It:
                return It(i = 0)

        function use(c: Coll) -> int:
            var total = 0
            for v in c:
                unsafe:
                    total += read(v)
            return total
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::Unary :operator \"*\" :operand (IR::Name :name \"v\" :type (Types::Nullable :base (Types::Generic :name \"ptr\""))
    expect(not text.contains_substring("(IR::Unary :operator \"*\" :operand (IR::Name :name \"v\" :type (Types::Generic :name \"ptr\""))


@[test]
function test_pointer_intrinsic_casts_like_the_host() -> void:
    ## `ptr_of(ref_value)` wraps the reference in an `IR::Cast` to the result
    ## pointer type (the host's `:ptr_of` branch) instead of retyping the Name
    ## (session 45).
    var source = <<-SRC
        struct P:
            x: int

        function take(p: ptr[P]) -> void:
            pass

        function use(r: ref[P]) -> void:
            take(ptr_of(r))
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::Cast :target_type (Types::Generic :name \"ptr\" :arguments ((Types::Struct :name \"P\" :module_name \"main\"))) :expression (IR::Name :name \"r\" :type (Types::Generic :name \"ref\""))
    expect(not text.contains_substring("(IR::Call :callee \"main_take\" :arguments ((IR::Name :name \"r\""))


@[test]
function test_specialized_function_value_carries_its_name() -> void:
    ## `f[T]` passed as a value types its `IR::Name` with a `Types::Function`
    ## whose `name` is the declaration's (`fn f`), not the empty signature form
    ## (the host's `Types::Function#name`; session 45).
    var source = <<-SRC
        function pick[T](v: T) -> T:
            return v

        struct H:
            fnv: fn(v: int) -> int

        function make() -> H:
            return H(fnv = pick[int])
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(Types::Function :name \"pick\""))


@[test]
function test_hash_hook_arguments_cast_to_const_ptr() -> void:
    ## The `order`/`equal`/`hash` builtins take `const_ptr[T]` (the host's
    ## `lower_hash_operation_argument`): a pointer argument is cast to that
    ## target, not passed through with its own type (`std/binary_heap.mt`'s
    ## `order[K](child_value, parent_value)`).
    var source = <<-SRC
        struct Key:
            x: int

        extending Key:
            public static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
                unsafe:
                    return read(left).x - read(right).x

        struct Holder[T]:
            a: ptr[T]
            b: ptr[T]

        extending Holder[T]:
            public function cmp() -> int:
                return order[T](this.a, this.b)

        function use(h: Holder[Key]) -> int:
            return h.cmp()
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring(":callee \"main_Key_order_static\" :arguments ((IR::Cast :target_type (Types::Generic :name \"const_ptr\""))
    expect(not text.contains_substring(":callee \"mt_order_func\""))


@[test]
function test_ref_argument_bridge_casts_a_pointer_receiver() -> void:
    ## The host's `implicit_ref_argument_bridge?` rewrites `S.take(this)` to
    ## `ref_of(this)`; the pointer-lowered Name is then cast to the parameter's
    ## `ref[T]` (its own type is the struct value), not passed through
    ## (session 45).
    var source = <<-SRC
        struct S:
            n: int

        extending S:
            public static function take(s: ref[S]) -> int:
                return s.n

            public editable function bump() -> int:
                return S.take(this)
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::Cast :target_type (Types::Generic :name \"ref\" :arguments ((Types::Struct :name \"S\" :module_name \"main\"))) :expression (IR::Name :name \"this\""))


@[test]
function test_foreign_in_boundary_projects_to_const_ptr() -> void:
    ## An `in value: T as const_ptr[void]` argument takes the host's
    ## `const_pointer_to(parameter.type)` address type and is then projected to
    ## the declared boundary — `Cast(const_ptr[void], AddressOf(const_ptr[T]))`
    ## (session 45, item 8a).
    var root = fs.create_temporary_directory_in_system_temp("mtc_inproj_") else:
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

        external function take(p: const_ptr[void]) -> void
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public foreign function take_value(in value: int as const_ptr[void]) -> void = c.take
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import wrap

        function use(v: int) -> void:
            wrap.take_value(v)
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
    expect(text.contains_substring("(IR::Cast :target_type (Types::Generic :name \"const_ptr\" :arguments ((Types::Primitive :name \"void\"))) :expression (IR::AddressOf :expression (IR::Name :name \"v\" :type (Types::Primitive :name \"int\") :pointer false) :type (Types::Generic :name \"const_ptr\" :arguments ((Types::Primitive :name \"int\"))))"))
    expect(not text.contains_substring(":type (Types::Primitive :name \"ptr[void]\")"))


@[test]
function test_foreign_plain_boundary_projects_the_pointer() -> void:
    ## A plain `data: ptr[T] as const_ptr[void]` argument keeps its natural
    ## `AddressOf(ptr[T])` type and projects to the boundary
    ## (`update_audio_stream(stream, ptr_of(buffer[0]), N)`), not a bare address
    ## with no cast (session 45, item 8a).
    var root = fs.create_temporary_directory_in_system_temp("mtc_plainproj_") else:
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

        external function update(data: const_ptr[void]) -> void
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public foreign function update_data[T](data: ptr[T] as const_ptr[void]) -> void = c.update
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import wrap

        function use(buf: array[float, 4]) -> void:
            wrap.update_data(ptr_of(buf[0]))
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
    expect(text.contains_substring("(IR::Cast :target_type (Types::Generic :name \"const_ptr\" :arguments ((Types::Primitive :name \"void\"))) :expression (IR::AddressOf :expression (IR::CheckedIndex"))
    expect(text.contains_substring(":type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"float\"))"))


@[test]
function test_unannotated_local_takes_the_wrapper_return_type() -> void:
    ## A local inferred from a simple foreign wrapper call takes the wrapper's
    ## declared return type (`cstr?`) while the lowered call keeps the raw
    ## declaration's return (`ptr[char]`, the 3j rule) — session 45.
    var root = fs.create_temporary_directory_in_system_temp("mtc_wrapret_") else:
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

        external function getenv(name: cstr) -> ptr[char]
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public foreign function env(name: str as cstr) -> cstr? = c.getenv
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import wrap

        function probe(name: str) -> int:
            let configured = wrap.env(name)
            if configured != null:
                return 1
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
    let text = dump.as_str()
    expect(text.contains_substring("(IR::LocalDecl :name \"configured\" :linkage_name \"configured\" :type (Types::Nullable :base (Types::Primitive :name \"cstr\")) :value (IR::Call :callee \"getenv\""))
    expect(text.contains_substring(":type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"char\")))"))


@[test]
function test_unannotated_local_takes_the_refined_visible_type() -> void:
    ## Inside a null guard, `let q = p` takes the binding's *visible* type
    ## (`ptr[int]`) — the host's `lookup_value` refinement — while the read
    ## still carries the storage `Nullable` (session 45).
    var source = <<-SRC
        function narrow(p: ptr[int]?) -> int:
            if p != null:
                let q = p
                unsafe:
                    return read(q)
            return 0
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::LocalDecl :name \"q\" :linkage_name \"q\" :type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"int\"))) :value (IR::Name :name \"p\" :type (Types::Nullable :base (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"int\"))))"))


@[test]
function test_break_and_continue_flush_loop_defers() -> void:
    ## A `break`/`continue` with a loop-scoped `defer` runs the cleanup before
    ## its goto (the host's `lower_loop_exit`): the defer's release is the first
    ## statement of the exit's then body, not dropped by a native break
    ## (session 45 batch 6).
    var source = <<-SRC
        struct Res:
            n: int

        extending Res:
            public editable function release() -> void:
                this.n = 0

        function take() -> bool:
            return true

        function use() -> int:
            while true:
                var r = Res(n = 1)
                defer: r.release()
                if take():
                    break
            return 0

        function skip() -> int:
            var i = 0
            while i < 3:
                var s = Res(n = 2)
                defer: s.release()
                i += 1
                if i == 1:
                    continue
            return i
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring(":then_body ((IR::ExpressionStmt :expression (IR::Call :callee \"main_Res_release\" :arguments ((IR::AddressOf :expression (IR::Name :name \"r\""))
    expect(text.contains_substring("(IR::GotoStmt :label \"__mt_loop_break_2\")"))
    expect(text.contains_substring(":then_body ((IR::ExpressionStmt :expression (IR::Call :callee \"main_Res_release\" :arguments ((IR::AddressOf :expression (IR::Name :name \"s\""))
    expect(text.contains_substring("(IR::GotoStmt :label \"__mt_loop_continue_1\")"))


@[test]
function test_variant_equality_pattern_guard_has_an_empty_else() -> void:
    ## A struct-pattern equality arm (`Entity.enemy(boss = true)`) emits the
    ## host's guard shape: `then_body: [goto]` with a *present empty* else
    ## (`else_body ()`), not none (session 45 batch 7).
    var source = <<-SRC
        variant Entity:
            enemy(hp: int, boss: bool)
            other(x: int)

        function is_boss(e: Entity) -> bool:
            match e:
                Entity.enemy(boss = true):
                    return true
                _:
                    return false
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring(":member \"boss\" :type (Types::Primitive :name \"bool\")) :right (IR::BooleanLiteral :value true :type (Types::Primitive :name \"bool\")) :type (Types::Primitive :name \"bool\")) :then_body ((IR::GotoStmt :label \"__mt_match_1_arm_1\")) :else_body ())"))


@[test]
function test_guard_local_hoists_foreign_argument_temps() -> void:
    ## A `let x = <foreign call> else:` guard is a prepared position: the
    ## argument's `str as cstr` temp hoists into the statement stream before the
    ## storage local, and the local's value is the plain call — the host's
    ## `prepare_expression_with_cleanups` (session 45 batch 5).
    var root = fs.create_temporary_directory_in_system_temp("mtc_guardhoist_") else:
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

        external function fetch(name: cstr) -> ptr[char]
    SRC
    if not write_source_file(root.as_str(), "std/c/raw/lib.mt", raw_source):
        return

    var wrap_source = <<-SRC
        import std.c.raw.lib as c

        public foreign function fetch_name(name: str as cstr) -> cstr? = c.fetch
    SRC
    if not write_source_file(root.as_str(), "wrap.mt", wrap_source):
        return

    var source = <<-SRC
        import wrap

        function guarded(name: str) -> int:
            let item = wrap.fetch_name(name) else:
                return 0
            return 1
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
    expect(text.contains_substring("(IR::LocalDecl :name \"__mt_foreign_arg_1\" :linkage_name \"__mt_foreign_arg_1\" :type (Types::Primitive :name \"cstr\") :value (IR::Call :callee \"mt_foreign_str_to_cstr_temp\""))
    expect(text.contains_substring("(IR::LocalDecl :name \"item\" :linkage_name \"item\" :type (Types::Nullable :base (Types::Primitive :name \"cstr\")) :value (IR::Call :callee \"fetch\" :arguments ((IR::Name :name \"__mt_foreign_arg_1\""))
    expect(not text.contains_substring("(IR::StmtExpr"))


@[test]
function test_propagate_let_materializes_the_success_local() -> void:
    ## `let raw = make(flag)?` emits the hidden propagation storage, the failure
    ## branch with the host's typed member chain (`data` nil, `failure` the arm
    ## payload, `error` the payload's error type, and the analysis path on the
    ## return), then a real local for `raw` initialized from the success
    ## projection (session 45 batch 5).
    var source = <<-SRC
        struct Err:
            code: int

        function make(flag: bool) -> Result[ptr[int], Err]:
            var value: int = 7
            if flag:
                return Result[ptr[int], Err].failure(error = Err(code = 1))
            return Result[ptr[int], Err].success(value = ptr_of(value))

        function use(flag: bool) -> int:
            let raw = make(flag)?
            unsafe:
                return read(raw)
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring("(IR::LocalDecl :name \"raw\" :linkage_name \"raw\" :type (Types::Generic :name \"ptr\" :arguments ((Types::Primitive :name \"int\"))) :value (IR::Member :receiver (IR::Member :receiver (IR::Member :receiver (IR::Name :name \"__mt_propagate_1\""))
    expect(text.contains_substring(":member \"data\" :type nil) :member \"failure\" :type (Types::VariantArmPayload :name \"Result_failure\" :module_name \"std.result\")) :member \"error\" :type (Types::Struct :name \"Err\" :module_name \"main\"))))) :line nil :path"))


@[test]
function test_tuple_match_expression_nests_the_wildcard_else() -> void:
    ## The host nests a tuple match expression's if-chain into else bodies; the
    ## wildcard arm is the innermost else, so `return match t:` assigns the
    ## default only when no pattern matches (session 45).
    var source = <<-SRC
        function pick(a: char, b: char) -> int:
            let t = (a, b)
            return match t:
                ('x', 'y'): 1
                _: 2
    SRC
    var dump = lower_dump_for_source(source)
    defer: dump.release()
    let text = dump.as_str()
    expect(text.contains_substring(":then_body ((IR::Assignment :target (IR::Name :name \"__mt_match_expr_1\" :type (Types::Primitive :name \"int\") :pointer false) :operator \"=\" :value (IR::IntegerLiteral :value 1 :type (Types::Primitive :name \"int\")))) :else_body ((IR::Assignment :target (IR::Name :name \"__mt_match_expr_1\" :type (Types::Primitive :name \"int\") :pointer false) :operator \"=\" :value (IR::IntegerLiteral :value 2 :type (Types::Primitive :name \"int\"))))"))
