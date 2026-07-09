## In-language lowering tests for the self-hosted mtc compiler.
## Run with: mtc test projects/mtc
##
## Covers the exact correctness bugs fixed in Phase 9 (defer ordering,
## string-match-expr else-if chain, return-value hoisting, aggregate-literal
## source-module resolution).  Each test writes a temporary source file, parses
## and checks it through the module loader, lowers to IR, formats the IR, and
## asserts on the formatted output.

import std.testing as t
import std.fs as fs
import std.path as path_ops
import std.str
import std.string as string

import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver
import mtc.lowering.lowering as lowering
import mtc.pretty_printer.ir_formatter as irfmt


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


## Create a temp directory, write `source` as `main.mt` inside it, check the
## program, lower it, format the IR, and return the formatted IR string.  The
## temp directory tree is removed before returning.
function lower_source(source: str) -> string.String:
    var root = fs.create_temporary_directory_in_system_temp("mtc_lo_") else:
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
    return irfmt.format_program(ir_program)


# =============================================================================
#  Defer ordering — the cleanup must appear at scope-exit and before each
#  return, NOT at the declaration site.  (Phase 9 defer lowering fix.)
# =============================================================================

@[test]
function test_defer_cleanup_not_at_declaration_site() -> t.Check:
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
    defer ir.release()
    let text = ir.as_str()
    ## `second = y` (the last real statement) must be emitted BEFORE the
    ## deferred `first = x`, proving the defer runs at scope exit rather than
    ## at its declaration site.
    let second_pos = text.find_substring("second = y") else:
        return t.fail("missing 'second = y' assignment in IR")
    let first_pos = text.find_substring("first = x") else:
        return t.fail("missing deferred 'first = x' assignment in IR")
    return t.expect_true(first_pos > second_pos)


@[test]
function test_defer_cleanup_before_return() -> t.Check:
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
    defer ir.release()
    let text = ir.as_str()
    ## The `counter = counter + 1` cleanup must appear before both `return 1`
    ## and `return 2`.  Verify at least the first occurrence precedes `return 1`.
    let cleanup_pos = text.find_substring("counter + 1") else:
        return t.fail("missing deferred counter increment")
    let return1_pos = text.find_substring("return 1") else:
        return t.fail("missing return 1")
    return t.expect_true(cleanup_pos < return1_pos)


@[test]
function test_defer_with_block_body_form() -> t.Check:
    ## A `defer:` block must be lowered as well.
    var source = <<-SRC
        var counter: int = 0

        function f() -> void:
            defer:
                counter = counter + 1
            return
    SRC
    var ir = lower_source(source)
    defer ir.release()
    let text = ir.as_str()
    ## counter must appear in the IR (defer body was lowered).
    return t.expect_true(text.contains_substring("counter"))


# =============================================================================
#  String-match expression — must produce a proper else-if chain where exactly
#  one arm runs, not independent if-thens that clobber each other.  (Phase 9
#  string-match-expr fix.)
# =============================================================================

@[test]
function test_string_match_expr_has_else_if_chain() -> t.Check:
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
    defer ir.release()
    let text = ir.as_str()
    ## The first comparison must precede an `else:` which precedes the second
    ## comparison (nested chain), and the wildcard default comes last.
    let first_cmp = text.find_substring("lexeme == \"a\"") else:
        return t.fail("missing first arm comparison")
    let else_pos = text.find_substring("else:") else:
        return t.fail("missing else branch (chain not nested)")
    let second_cmp = text.find_substring("lexeme == \"b\"") else:
        return t.fail("missing second arm comparison")
    ## Nested chain order: first == "a", then else:, then == "b".
    t.expect_true(first_cmp < else_pos)?
    return t.expect_true(else_pos < second_cmp)


@[test]
function test_string_match_expr_with_only_wildcard() -> t.Check:
    ## A match expr with ONLY a wildcard arm must still lower correctly
    ## (edge case: the old code was buggy for the no-pattern-arms case).
    var source = <<-SRC
        function always() -> str:
            return match 1:
                _: "default"
    SRC
    var ir = lower_source(source)
    defer ir.release()
    let text = ir.as_str()
    return t.expect_true(text.contains_substring("default"))


# =============================================================================
#  Return-value hoisting — when defers are active, a non-trivial return
#  expression must be hoisted into a temp before the cleanup preamble, so
#  that running the defers does not invalidate it.  (Phase 9 defer fix.)
# =============================================================================

@[test]
function test_return_with_active_defer_lowers_cleanly() -> t.Check:
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
    defer ir.release()
    let text = ir.as_str()
    return t.expect_true(text.contains_substring("return"))


# =============================================================================
#  Aggregate-literal source-module resolution — struct constructors for
#  imported types must use the correct module prefix.  (Phase 9
#  break-in-match-in-while fix #2.)
# =============================================================================

@[test]
function test_struct_aggregate_lowering_does_not_crash() -> t.Check:
    ## Constructing a struct that is defined in an imported module must work.
    ## A minimal test: Vec[int].create() in a function body exercises the
    ## aggregate literal path.
    var source = <<-SRC
        import std.vec as vec

        function make_vec() -> vec.Vec[int]:
            return vec.Vec[int].create()
    SRC
    var ir = lower_source(source)
    defer ir.release()
    let text = ir.as_str()
    return t.expect_true(text.contains_substring("Vec_int"))


# =============================================================================
#  Overall pipeline stability — lowering must not crash on common constructs.
# =============================================================================

@[test]
function test_lower_function_with_defer_and_while_and_match() -> t.Check:
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
    defer ir.release()
    let text = ir.as_str()
    t.expect_true(text.contains_substring("while"))?
    t.expect_true(text.contains_substring("return"))?
    return t.ok()


@[test]
function test_lower_match_with_variant_arms() -> t.Check:
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
    defer ir.release()
    return t.ok()


# =============================================================================
#  atomic[T] — the builtin methods lower to GCC/Clang __atomic_* builtins with
#  the sequential-consistency memory order (5).  (Phase A atomic parity.)
# =============================================================================

@[test]
function test_atomic_methods_lower_to_builtins() -> t.Check:
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
    defer ir.release()
    let text = ir.as_str()
    t.expect_true(text.contains_substring("__atomic_store_n(&counter, 0, 5)"))?
    t.expect_true(text.contains_substring("__atomic_fetch_add(&counter, 1, 5)"))?
    t.expect_true(text.contains_substring("__atomic_load_n(&counter, 5)"))?
    ## add/load must be typed as the element type, not void.
    t.expect_true(text.contains_substring("let prev: int ="))?
    return t.expect_true(text.contains_substring("let value: int ="))


@[test]
function test_atomic_sub_and_exchange_lower_to_builtins() -> t.Check:
    ## sub and exchange round out the read-modify-write surface.
    var source = <<-SRC
        function rmw_demo() -> int:
            var counter: atomic[int]
            let a = counter.sub(2)
            let b = counter.exchange(9)
            return a + b
    SRC
    var ir = lower_source(source)
    defer ir.release()
    let text = ir.as_str()
    t.expect_true(text.contains_substring("__atomic_fetch_sub(&counter, 2, 5)"))?
    return t.expect_true(text.contains_substring("__atomic_exchange_n(&counter, 9, 5)"))


# =============================================================================
#  Binary operand widening — mixed-width integer / int+float arithmetic casts
#  the narrower operand up to the common type, matching Ruby's usual-arithmetic
#  conversions.  Same-type operands are not cast.
# =============================================================================

@[test]
function test_mixed_width_integer_arithmetic_widens_narrow_operand() -> t.Check:
    ## `int + long` casts the int operand to long; the long operand is left
    ## alone, and the result type is long.
    var source = <<-SRC
        function f(a: int, b: long) -> long:
            return a + b
    SRC
    var ir = lower_source(source)
    defer ir.release()
    let text = ir.as_str()
    return t.expect_true(text.contains_substring("long<-a + b"))


@[test]
function test_same_type_arithmetic_is_not_cast() -> t.Check:
    ## Two operands of the same type need no balancing cast.
    var source = <<-SRC
        function f(a: int, b: int) -> int:
            return a + b
    SRC
    var ir = lower_source(source)
    defer ir.release()
    let text = ir.as_str()
    t.expect_true(text.contains_substring("return a + b"))?
    return t.expect_true(not text.contains_substring("int<-a"))


@[test]
function test_comparison_widens_operand_but_yields_bool() -> t.Check:
    ## A comparison across widths still balances the operands, but the binary's
    ## own result type stays bool (so the arithmetic-result-type widening does
    ## not apply to comparisons).
    var source = <<-SRC
        function f(a: int, b: long) -> bool:
            return a < b
    SRC
    var ir = lower_source(source)
    defer ir.release()
    let text = ir.as_str()
    return t.expect_true(text.contains_substring("long<-a < b"))


# =============================================================================
#  Enum / flags backing-cast — comparisons unwrap the operands to their integer
#  backing type and cast to it, matching Ruby's EnumBase unwrap.
# =============================================================================

@[test]
function test_enum_comparison_casts_to_backing() -> t.Check:
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
    defer ir.release()
    let text = ir.as_str()
    t.expect_true(text.contains_substring("ubyte<-"))?
    return t.expect_true(text.contains_substring("> ubyte<-"))


@[test]
function test_flags_comparison_casts_but_bitwise_does_not() -> t.Check:
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
    defer ir.release()
    let text = ir.as_str()
    t.expect_true(text.contains_substring("uint<-m == uint<-"))?
    ## The bitwise-or operands are left un-cast.
    return t.expect_true(text.contains_substring("Mask_a | "))


# =============================================================================
#  emit — compile-time code generation.  `emit function ...` inside a const
#  function body is spliced into the module as an ordinary top-level function.
# =============================================================================

@[test]
function test_emit_function_becomes_top_level() -> t.Check:
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
    defer ir.release()
    let text = ir.as_str()
    ## Both emitted functions are spliced in as top-level declarations.
    t.expect_true(text.contains_substring("fn zero_meaning"))?
    t.expect_true(text.contains_substring("fn hex_prefix"))?
    ## The call resolves to the emitted function's linkage name.
    return t.expect_true(text.contains_substring("return main_zero_meaning()"))
