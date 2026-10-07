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


## Create a temp directory, write `source` as `main.mt`, check + lower it, and
## return the generated C.  The temp tree is removed before returning.
function compile_to_c(source: str) -> string.String:
    var root = fs.create_temporary_directory_in_system_temp("mtc_cb_") else:
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
    return c_backend.generate_c(ir_program, false, false)


## Assert `text` contains `needle`; the failure message names the missing text.
function expect_contains(text: str, needle: str) -> void:
    expect(text.contains_substring(needle), needle)


# =============================================================================
#  Preamble
# =============================================================================

@[test]
function test_emits_c_stdint_header() -> void:
    var source = <<-SRC
        function main() -> int:
            return 0
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    expect_contains(text, "#include <stdint.h>")
    expect_contains(text, "#include <stdbool.h>")
    return


# =============================================================================
#  Structs
# =============================================================================

@[test]
function test_struct_typedef_and_definition() -> void:
    var source = <<-SRC
        struct Point:
            x: int
            y: int

        function main() -> int:
            let p = Point(x = 1, y = 2)
            return p.x + p.y
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    expect_contains(text, "typedef struct main_Point main_Point;")
    expect_contains(text, "struct main_Point {")
    expect_contains(text, "int32_t x;")
    expect_contains(text, "int32_t y;")
    return


@[test]
function test_struct_aggregate_initializer() -> void:
    var source = <<-SRC
        struct Point:
            x: int
            y: int

        function main() -> int:
            let p = Point(x = 1, y = 2)
            return p.x + p.y
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    ## Designated-initializer form for the struct literal.
    expect_contains(text, ".x = 1")
    expect_contains(text, ".y = 2")
    return


# =============================================================================
#  Enums
# =============================================================================

@[test]
function test_enum_typedef_and_constants() -> void:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1

        function main() -> int:
            let c = Color.green
            return int<-c
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    expect_contains(text, "typedef uint8_t main_Color;")
    expect_contains(text, "main_Color_red = 0")
    expect_contains(text, "main_Color_green = 1")
    return


# =============================================================================
#  Functions and the real main entrypoint
# =============================================================================

@[test]
function test_function_signature_and_body() -> void:
    var source = <<-SRC
        function add(a: int, b: int) -> int:
            return a + b

        function main() -> int:
            return add(2, 3)
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    ## User functions are `static` and carry the module prefix.
    expect_contains(text, "static int32_t main_add(int32_t a, int32_t b)")
    expect_contains(text, "return a + b;")
    return


@[test]
function test_real_main_entrypoint_wraps_user_main() -> void:
    var source = <<-SRC
        function main() -> int:
            return 7
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    ## A bare C `int32_t main(void)` calls the prefixed user main.
    expect_contains(text, "int32_t main(void)")
    expect_contains(text, "main_main()")
    return


@[test]
function test_dead_function_is_not_emitted() -> void:
    var source = <<-SRC
        function unused_helper() -> int:
            return 99

        function main() -> int:
            return 0
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    ## Reachability-based emission drops functions not reached from main.
    expect(not text.contains_substring("main_unused_helper"))


# =============================================================================
#  Match -> switch
# =============================================================================

@[test]
function test_enum_match_lowers_to_switch() -> void:
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
    defer: c.release()
    let text = c.as_str()
    expect_contains(text, "switch (c)")
    expect_contains(text, "case main_Color_red:")
    expect_contains(text, "case main_Color_green:")
    return


# =============================================================================
#  Variants -> tagged unions
# =============================================================================

@[test]
function test_variant_lowers_to_tagged_union() -> void:
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
    defer: c.release()
    let text = c.as_str()
    ## A tag enum, a payload union, and a struct carrying both.
    expect_contains(text, "main_Shape_kind")
    expect_contains(text, "union main_Shape__data")
    expect_contains(text, "struct main_Shape {")
    return


# =============================================================================
#  Generic monomorphization
# =============================================================================

@[test]
function test_generic_function_is_monomorphized() -> void:
    var source = <<-SRC
        function identity[T](x: T) -> T:
            return x

        function main() -> int:
            return identity[int](7)
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    ## The `int` specialization is emitted with a type-suffixed C name
    ## (host scheme: a double underscore before the arguments).
    expect_contains(text, "main_identity__int(int32_t x)")
    return


# =============================================================================
#  Inline-while compile-time unrolling
# =============================================================================

@[test]
function test_inline_while_literal_unrolled_no_c_while() -> void:
    var source = <<-SRC
        function main() -> int:
            inline while 5 > 0:
                return 42
            return 0
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    # Unrolled: no C while loop keyword in the output.
    if text.contains_substring("while") or text.contains_substring("While"):
        expect(false, "inline while should be unrolled, but C output contains 'while'")
    expect_contains(text, "return 42")
    return


@[test]
function test_inline_while_const_condition_unrolled() -> void:
    var source = <<-SRC
        const N: int = 3
        function main() -> int:
            var total: int = 0
            inline while N > 0:
                return 10
            return 0
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    if text.contains_substring("while") or text.contains_substring("While"):
        expect(false, "inline while with const condition should be unrolled")
    return


# =============================================================================
#  Stateful event emit — state pointer must be passed to listener
# =============================================================================

@[test]
function test_stateful_event_listener_receives_state_pointer() -> void:
    var source = <<-SRC
        event stateful_probe[4]

        struct Counter:
            count: int

        function on_tick(state: ptr[Counter]) -> void:
            unsafe:
                state.count += 1

        function main() -> int:
            var c = Counter(count = 0)
            match stateful_probe.subscribe(ptr_of(c), on_tick):
                Result.success:
                    stateful_probe.emit()
                    return c.count
                Result.failure:
                    return -1
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    # The emit dispatch for stateful slots must include the state argument.
    # Self-host emits: ((void (*)(void*)) event->slots[i].listener)(event->slots[i].state)
    expect_contains(text, "listener)(event->slots")
    return


# =============================================================================
#  Opaque values are pointers; recursive arm payloads dereference
# =============================================================================

@[test]
function test_opaque_value_renders_as_pointer() -> void:
    # A re-exported opaque's C type is its backing name, forward-declared as a
    # struct, and a value of the type is a pointer to it (host parity) that
    # zeroes to NULL.
    var source = <<-SRC
        opaque Handle = c"HANDLE"

        function main() -> int:
            var h: Handle = zero[Handle]
            return 0
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    expect_contains(text, "typedef struct HANDLE HANDLE;")
    expect_contains(text, "HANDLE* h = NULL;")
    return


@[test]
function test_ptr_of_raw_pointer_takes_address() -> void:
    # `ptr_of(p)` on a raw-pointer variable is the address of the slot (`&p`),
    # not the pointer value itself, matching the host's lower_addr_expression.
    var source = <<-SRC
        function main() -> int:
            var p: ptr[int] = null
            let pp = ptr_of(p)
            return 0
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    expect_contains(text, "*pp = &p;")
    return


@[test]
function test_recursive_variant_field_dereferences_on_read() -> void:
    # An arm payload that embeds the enclosing variant (`Expr.bin(left: Expr)`)
    # is stored as a pointer; reading the field dereferences it.
    var source = <<-SRC
        variant Expr:
            num(value: int)
            bin(left: Expr, right: Expr)

        function eval_expr(expr: Expr) -> int:
            match expr:
                Expr.num as n:
                    return n.value
                Expr.bin as b:
                    return eval_expr(b.left) + eval_expr(b.right)

        function main() -> int:
            let a = Expr.num(value = 1)
            let tree = Expr.bin(left = a, right = a)
            return eval_expr(tree)
    SRC
    var c = compile_to_c(source)
    defer: c.release()
    let text = c.as_str()
    expect_contains(text, ".left = &a")
    expect_contains(text, "eval_expr(*b.left)")
    expect_contains(text, "eval_expr(*b.right)")
    return


# =============================================================================
#  Generic extending blocks keep the block's type parameters
# =============================================================================

struct Box[T]:
    value: T


function peek[T](slot: ref[Box[T]]) -> T:
    return slot.value


extending Box[T]:
    public function round_trip() -> T:
        # An inferred generic call (`peek`) whose argument is a `ref_of(this)`
        # builtin: the specialization must be created from the substituted
        # receiver type.  (The equivalent regression for an extending block on
        # an *imported* generic type is the fsm/htn/goap family in `test/mt`.)
        return peek(ref_of(this))


@[test]
function test_generic_extending_block_type_parameters() -> void:
    let boxed = Box[int](value = 7)
    expect_eq(boxed.round_trip(), 7)
    let text = Box[str](value = "milk")
    expect_eq(text.round_trip(), "milk")


# =============================================================================
#  External-struct equality helpers
# =============================================================================

@[test]
function test_external_struct_equality_helper_is_synthesized() -> void:
    # A raw-module struct comparison reaches the backend as an `IR::Binary`; the
    # `mt_struct_eq_<T>` helper is synthesized from the layout the lowering
    # registered in `Program.external_structs` — the forward declaration, the
    # field guards and the (negated) call site (session 43, item 3r).
    var root = fs.create_temporary_directory_in_system_temp("mtc_cbeq_") else:
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

    var raw_path = path_ops.join(raw_dir.as_str(), "lib.mt")
    defer: raw_path.release()
    var raw_source = <<-SRC
        external

        struct Part:
            index: int
            generation: uint
    SRC
    match fs.write_text(raw_path.as_str(), raw_source):
        Result.failure as f:
            var e = f.error
            e.release()
            return
        Result.success:
            pass

    var source = <<-SRC
        import std.c.raw.lib as raw

        function differs(a: raw.Part, b: raw.Part) -> bool:
            return a != b
    SRC
    if not write_main_file(root.as_str(), source):
        return

    var main_path = path_ops.join(root.as_str(), "main.mt")
    defer: main_path.release()
    var roots = array[str, 1](root.as_str())
    var program = loader.check_program(main_path.as_str(), roots.as_span(), resolver.Platform.linux)
    defer: program.release()

    let ir_program = lowering.lower(program)
    var c = c_backend.generate_c(ir_program, false, false)
    defer: c.release()
    let text = c.as_str()
    expect_contains(text, "static bool mt_struct_eq_Part(struct Part left, struct Part right);")
    expect_contains(text, "static bool mt_struct_eq_Part(struct Part left, struct Part right) {")
    expect_contains(text, "if (left.index != right.index) return false;")
    expect_contains(text, "if (left.generation != right.generation) return false;")
    expect_contains(text, "!mt_struct_eq_Part(a, b)")

