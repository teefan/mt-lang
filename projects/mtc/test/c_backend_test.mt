## In-language C-backend tests for the self-hosted mtc compiler.
## Run with: mtc test projects/mtc
##
## The C backend (src/mtc/c_backend/c_backend.mt, ~6k LOC) was previously only
## validated end-to-end by the bootstrap fixed point.  These tests assert on the
## generated C for representative constructs: structs, enums, tagged-union
## variants, function signatures, the real `main` entrypoint, match->switch
## lowering, generic monomorphization, and aggregate initializers.
##
## Each test writes a temp `main.mt`, checks it through the module loader, lowers
## to IR, generates C, and asserts on the C text.  The module name inferred for
## `main.mt` is `main`, so user symbols carry the `main_` C prefix and the C
## entrypoint is the bare `int32_t main(void)`.

import std.testing as t
import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string

import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver
import mtc.lowering.lowering as lowering
import mtc.c_backend.c_backend as c_backend


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
    defer main_path.release()

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


## Create a temp directory, write `source` as `main.mt`, check + lower it, and
## return the generated C.  The temp tree is removed before returning.
function compile_to_c(source: str) -> string.String:
    var root = fs.create_temporary_directory_in_system_temp("mtc_cb_") else:
        return string.String.from_str("FAIL: temp dir")
    defer cleanup_dir(ref_of(root))

    if not write_main_file(root.as_str(), source):
        return string.String.from_str("FAIL: write main")

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer main_path.release()

    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer program.release()

    var ir_program = lowering.lower(program)
    return c_backend.generate_c(ir_program)


## Assert `text` contains `needle`; the failure message names the missing text.
function expect_contains(text: str, needle: str) -> t.Check:
    return t.expect(text.contains_substring(needle), needle)


# =============================================================================
#  Preamble
# =============================================================================

@[test]
function test_emits_c_stdint_header() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            return 0
    SRC
    var c = compile_to_c(source)
    defer c.release()
    let text = c.as_str()
    expect_contains(text, "#include <stdint.h>")?
    expect_contains(text, "#include <stdbool.h>")?
    return t.ok()


# =============================================================================
#  Structs
# =============================================================================

@[test]
function test_struct_typedef_and_definition() -> t.Check:
    var source = <<-SRC
        struct Point:
            x: int
            y: int

        function main() -> int:
            let p = Point(x = 1, y = 2)
            return p.x + p.y
    SRC
    var c = compile_to_c(source)
    defer c.release()
    let text = c.as_str()
    expect_contains(text, "typedef struct main_Point main_Point;")?
    expect_contains(text, "struct main_Point {")?
    expect_contains(text, "int32_t x;")?
    expect_contains(text, "int32_t y;")?
    return t.ok()


@[test]
function test_struct_aggregate_initializer() -> t.Check:
    var source = <<-SRC
        struct Point:
            x: int
            y: int

        function main() -> int:
            let p = Point(x = 1, y = 2)
            return p.x + p.y
    SRC
    var c = compile_to_c(source)
    defer c.release()
    let text = c.as_str()
    ## Designated-initializer form for the struct literal.
    expect_contains(text, ".x = 1")?
    expect_contains(text, ".y = 2")?
    return t.ok()


# =============================================================================
#  Enums
# =============================================================================

@[test]
function test_enum_typedef_and_constants() -> t.Check:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1

        function main() -> int:
            let c = Color.green
            return int<-c
    SRC
    var c = compile_to_c(source)
    defer c.release()
    let text = c.as_str()
    expect_contains(text, "typedef uint8_t main_Color;")?
    expect_contains(text, "main_Color_red = 0")?
    expect_contains(text, "main_Color_green = 1")?
    return t.ok()


# =============================================================================
#  Functions and the real main entrypoint
# =============================================================================

@[test]
function test_function_signature_and_body() -> t.Check:
    var source = <<-SRC
        function add(a: int, b: int) -> int:
            return a + b

        function main() -> int:
            return add(2, 3)
    SRC
    var c = compile_to_c(source)
    defer c.release()
    let text = c.as_str()
    ## User functions are `static` and carry the module prefix.
    expect_contains(text, "static int32_t main_add(int32_t a, int32_t b)")?
    expect_contains(text, "return a + b;")?
    return t.ok()


@[test]
function test_real_main_entrypoint_wraps_user_main() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            return 7
    SRC
    var c = compile_to_c(source)
    defer c.release()
    let text = c.as_str()
    ## A bare C `int32_t main(void)` calls the prefixed user main.
    expect_contains(text, "int32_t main(void)")?
    expect_contains(text, "main_main()")?
    return t.ok()


@[test]
function test_dead_function_is_not_emitted() -> t.Check:
    var source = <<-SRC
        function unused_helper() -> int:
            return 99

        function main() -> int:
            return 0
    SRC
    var c = compile_to_c(source)
    defer c.release()
    let text = c.as_str()
    ## Reachability-based emission drops functions not reached from main.
    return t.expect_false(text.contains_substring("main_unused_helper"))


# =============================================================================
#  Match -> switch
# =============================================================================

@[test]
function test_enum_match_lowers_to_switch() -> t.Check:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1

        function classify(c: Color) -> int:
            match c:
                Color.red:
                    return 1
                Color.green:
                    return 2

        function main() -> int:
            return classify(Color.red)
    SRC
    var c = compile_to_c(source)
    defer c.release()
    let text = c.as_str()
    expect_contains(text, "switch (c)")?
    expect_contains(text, "case main_Color_red:")?
    expect_contains(text, "case main_Color_green:")?
    return t.ok()


# =============================================================================
#  Variants -> tagged unions
# =============================================================================

@[test]
function test_variant_lowers_to_tagged_union() -> t.Check:
    var source = <<-SRC
        variant Shape:
            circle(radius: int)
            empty

        function main() -> int:
            let s = Shape.circle(radius = 5)
            match s:
                Shape.circle as payload:
                    return payload.radius
                Shape.empty:
                    return 0
    SRC
    var c = compile_to_c(source)
    defer c.release()
    let text = c.as_str()
    ## A tag enum, a payload union, and a struct carrying both.
    expect_contains(text, "main_Shape_kind")?
    expect_contains(text, "union main_Shape__data")?
    expect_contains(text, "struct main_Shape {")?
    return t.ok()


# =============================================================================
#  Generic monomorphization
# =============================================================================

@[test]
function test_generic_function_is_monomorphized() -> t.Check:
    var source = <<-SRC
        function identity[T](x: T) -> T:
            return x

        function main() -> int:
            return identity[int](7)
    SRC
    var c = compile_to_c(source)
    defer c.release()
    let text = c.as_str()
    ## The `int` specialization is emitted with a type-suffixed C name.
    expect_contains(text, "main_identity_int(int32_t x)")?
    return t.ok()
