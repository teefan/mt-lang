# In-language semantic analyzer tests for the self-hosted mtc compiler.
# Run with: mtc test projects/mtc

import std.testing as t
import std.vec as vec

import mtc.parser.parser as parser
import mtc.semantic.analyzer as analyzer


## Parse then semantically analyze `source`, returning the diagnostic count.
## The source is expected to parse cleanly; only semantic diagnostics count.
function diagnostic_count(source: str) -> ptr_uint:
    var pdiags = vec.Vec[parser.ParseDiagnostic].create()
    defer pdiags.release()
    let file = parser.parse_source(source, ref_of(pdiags))
    if pdiags.len() > 0:
        return pdiags.len()
    var analysis = analyzer.check_source_file(file)
    defer analysis.diagnostics.release()
    return analysis.diagnostics.len()


function expect_clean(source: str) -> t.Check:
    return t.expect_equal_int(int<-diagnostic_count(source), 0)


function expect_flagged(source: str) -> t.Check:
    return t.expect_true(diagnostic_count(source) > 0)


@[test]
function test_valid_function_is_clean() -> t.Check:
    var source = <<-SRC
        function add(a: int, b: int) -> int:
            return a + b
    SRC
    return expect_clean(source)


@[test]
function test_return_type_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            return true
    SRC
    return expect_flagged(source)


@[test]
function test_return_bool_from_bool_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> bool:
            return true
    SRC
    return expect_clean(source)


@[test]
function test_duplicate_function_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            return 1
        function f() -> int:
            return 2
    SRC
    return expect_flagged(source)


@[test]
function test_duplicate_type_is_flagged() -> t.Check:
    var source = <<-SRC
        struct Point:
            x: int
        struct Point:
            y: int
    SRC
    return expect_flagged(source)


@[test]
function test_distinct_type_and_value_names_are_clean() -> t.Check:
    var source = <<-SRC
        struct Point:
            x: int
        function make() -> int:
            return 0
    SRC
    return expect_clean(source)


@[test]
function test_let_type_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            let x: int = true
    SRC
    return expect_flagged(source)


@[test]
function test_let_numeric_literal_is_clean() -> t.Check:
    # Integer literals coerce across numeric types; must not be flagged.
    var source = <<-SRC
        function f() -> void:
            let x: ptr_uint = 0
    SRC
    return expect_clean(source)


@[test]
function test_unknown_types_are_permissive() -> t.Check:
    # Imported / unresolved types degrade to the permissive error type and must
    # never produce a false positive.
    var source = <<-SRC
        function f(v: SomeImported) -> OtherImported:
            let x: Widget = make_widget()
            return convert(x)
    SRC
    return expect_clean(source)


@[test]
function test_return_local_variable_is_checked() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            let flag = true
            return flag
    SRC
    return expect_flagged(source)


@[test]
function test_non_bool_if_condition_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            if 5:
                pass
    SRC
    return expect_flagged(source)


@[test]
function test_non_bool_while_condition_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            while 3:
                pass
    SRC
    return expect_flagged(source)


@[test]
function test_comparison_condition_is_clean() -> t.Check:
    var source = <<-SRC
        function f(n: int) -> void:
            if n > 0:
                pass
            while n < 10:
                pass
    SRC
    return expect_clean(source)


@[test]
function test_call_arity_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        function add(a: int, b: int) -> int:
            return a + b
        function g() -> int:
            return add(1)
    SRC
    return expect_flagged(source)


@[test]
function test_call_correct_arity_is_clean() -> t.Check:
    var source = <<-SRC
        function add(a: int, b: int) -> int:
            return a + b
        function g() -> int:
            return add(1, 2)
    SRC
    return expect_clean(source)


@[test]
function test_call_argument_type_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        function add(a: int, b: int) -> int:
            return a + b
        function g() -> int:
            return add(true, 1)
    SRC
    return expect_flagged(source)


@[test]
function test_call_to_unknown_function_is_permissive() -> t.Check:
    var source = <<-SRC
        function g(w: Widget) -> int:
            return w.compute(1, 2, 3)
    SRC
    return expect_clean(source)


@[test]
function test_named_arguments_call_is_clean() -> t.Check:
    var source = <<-SRC
        function configure(host: str, port: int) -> void:
            pass
        function g() -> void:
            configure(host = "localhost", port = 8080)
    SRC
    return expect_clean(source)


@[test]
function test_unknown_field_in_construction_is_flagged() -> t.Check:
    var source = <<-SRC
        struct Point:
            x: int
            y: int
        function make() -> Point:
            return Point(x = 1, z = 2)
    SRC
    return expect_flagged(source)


@[test]
function test_valid_construction_is_clean() -> t.Check:
    var source = <<-SRC
        struct Point:
            x: int
            y: int
        function make() -> Point:
            return Point(x = 1, y = 2)
    SRC
    return expect_clean(source)


@[test]
function test_field_access_type_is_inferred() -> t.Check:
    var source = <<-SRC
        struct Box:
            flag: bool
        function f(b: Box) -> int:
            return b.flag
    SRC
    return expect_flagged(source)


@[test]
function test_field_access_correct_type_is_clean() -> t.Check:
    var source = <<-SRC
        struct Box:
            count: int
        function f(b: Box) -> int:
            return b.count
    SRC
    return expect_clean(source)


@[test]
function test_type_alias_resolves_to_target() -> t.Check:
    var source = <<-SRC
        type Meters = int
        function f() -> Meters:
            return true
    SRC
    return expect_flagged(source)


@[test]
function test_unknown_method_call_is_flagged() -> t.Check:
    var source = <<-SRC
        struct Box:
            x: int
        extending Box:
            function get() -> int:
                return this.x
        function f(b: Box) -> int:
            return b.missing()
    SRC
    return expect_flagged(source)


@[test]
function test_valid_extending_method_call_is_clean() -> t.Check:
    var source = <<-SRC
        struct Box:
            x: int
        extending Box:
            function get() -> int:
                return this.x
        function f(b: Box) -> int:
            return b.get()
    SRC
    return expect_clean(source)


@[test]
function test_unknown_field_read_is_flagged() -> t.Check:
    var source = <<-SRC
        struct Box:
            x: int
        function f(b: Box) -> int:
            return b.nope
    SRC
    return expect_flagged(source)


@[test]
function test_member_on_non_local_type_is_permissive() -> t.Check:
    # Receivers of imported / ref-wrapped / generic types are not locally-known
    # structs, so their member accesses must never be flagged.
    var source = <<-SRC
        function f(w: Widget, p: ref[Gadget]) -> int:
            let a = w.anything()
            return p.whatever + a
    SRC
    return expect_clean(source)


@[test]
function test_builtin_with_on_struct_is_clean() -> t.Check:
    var source = <<-SRC
        struct Point:
            x: int
            y: int
        function shift(p: Point) -> Point:
            return p.with(x = 9)
    SRC
    return expect_clean(source)


@[test]
function test_method_body_return_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function bad() -> bool:
                return this.value
    SRC
    return expect_flagged(source)


@[test]
function test_method_body_unknown_field_is_flagged() -> t.Check:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function read() -> int:
                return this.nope
    SRC
    return expect_flagged(source)


@[test]
function test_valid_method_body_is_clean() -> t.Check:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function read() -> int:
                return this.value
            editable function bump() -> void:
                this.value = this.value + 1
    SRC
    return expect_clean(source)


@[test]
function test_static_method_body_is_clean() -> t.Check:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            static function zero() -> Counter:
                return Counter(value = 0)
    SRC
    return expect_clean(source)


@[test]
function test_method_calls_sibling_method_is_clean() -> t.Check:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function read() -> int:
                return this.value
            function double() -> int:
                return this.read() + this.read()
    SRC
    return expect_clean(source)


@[test]
function test_unknown_enum_member_is_flagged() -> t.Check:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
        function f() -> Color:
            return Color.purple
    SRC
    return expect_flagged(source)


@[test]
function test_valid_enum_member_is_clean() -> t.Check:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
        function f() -> Color:
            return Color.green
    SRC
    return expect_clean(source)


@[test]
function test_unknown_variant_arm_is_flagged() -> t.Check:
    var source = <<-SRC
        variant Token:
            ident(name: str)
            eof
        function f() -> Token:
            return Token.bad
    SRC
    return expect_flagged(source)


@[test]
function test_valid_variant_arm_construction_is_clean() -> t.Check:
    var source = <<-SRC
        variant Token:
            ident(name: str)
            eof
        function f() -> Token:
            return Token.ident(name = "x")
    SRC
    return expect_clean(source)


@[test]
function test_prelude_option_member_is_permissive() -> t.Check:
    # Option/Result are prelude types, not locally declared, so their member
    # access must never be flagged.
    var source = <<-SRC
        function f() -> Option[int]:
            return Option[int].some(value = 5)
    SRC
    return expect_clean(source)


@[test]
function test_missing_return_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            let x = 5
    SRC
    return expect_flagged(source)


@[test]
function test_if_without_else_missing_return_is_flagged() -> t.Check:
    var source = <<-SRC
        function f(n: int) -> int:
            if n > 0:
                return 1
    SRC
    return expect_flagged(source)


@[test]
function test_if_else_both_return_is_clean() -> t.Check:
    var source = <<-SRC
        function f(n: int) -> int:
            if n > 0:
                return 1
            else:
                return 2
    SRC
    return expect_clean(source)


@[test]
function test_fatal_ending_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            fatal(c"boom")
    SRC
    return expect_clean(source)


@[test]
function test_while_true_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            while true:
                pass
    SRC
    return expect_clean(source)


@[test]
function test_void_function_needs_no_return() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            let x = 5
    SRC
    return expect_clean(source)


@[test]
function test_static_assert_false_terminator_is_clean() -> t.Check:
    var source = <<-SRC
        function f(n: int) -> int:
            if n == 8:
                return 1
            static_assert(false, "unsupported")
    SRC
    return expect_clean(source)


@[test]
function test_method_missing_return_is_flagged() -> t.Check:
    var source = <<-SRC
        struct C:
            v: int
        extending C:
            function read() -> int:
                let x = this.v
    SRC
    return expect_flagged(source)


@[test]
function test_assignment_type_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            var x: int = 0
            x = true
    SRC
    return expect_flagged(source)


@[test]
function test_assignment_compatible_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            var x: int = 0
            x = 5
    SRC
    return expect_clean(source)


@[test]
function test_break_outside_loop_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            break
    SRC
    return expect_flagged(source)


@[test]
function test_continue_outside_loop_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            continue
    SRC
    return expect_flagged(source)


@[test]
function test_break_inside_loop_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            while true:
                break
    SRC
    return expect_clean(source)


@[test]
function test_break_in_nested_if_in_loop_is_clean() -> t.Check:
    var source = <<-SRC
        function f(n: int) -> void:
            for i in 0..n:
                if i > 2:
                    break
    SRC
    return expect_clean(source)


@[test]
function test_non_exhaustive_enum_match_is_flagged() -> t.Check:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
            blue = 2
        function f(c: Color) -> int:
            match c:
                Color.red:
                    return 1
                Color.green:
                    return 2
    SRC
    return expect_flagged(source)


@[test]
function test_exhaustive_enum_match_is_clean() -> t.Check:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
        function f(c: Color) -> int:
            match c:
                Color.red:
                    return 1
                Color.green:
                    return 2
    SRC
    return expect_clean(source)


@[test]
function test_enum_match_with_wildcard_is_clean() -> t.Check:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
            blue = 2
        function f(c: Color) -> int:
            match c:
                Color.red:
                    return 1
                _:
                    return 0
    SRC
    return expect_clean(source)


@[test]
function test_integer_match_without_wildcard_is_flagged() -> t.Check:
    var source = <<-SRC
        function f(n: int) -> int:
            match n:
                1:
                    return 1
                2:
                    return 2
    SRC
    return expect_flagged(source)


@[test]
function test_integer_match_with_wildcard_is_clean() -> t.Check:
    var source = <<-SRC
        function f(n: int) -> int:
            match n:
                1:
                    return 1
                _:
                    return 0
    SRC
    return expect_clean(source)


@[test]
function test_str_match_without_wildcard_is_flagged() -> t.Check:
    var source = <<-SRC
        function f(s: str) -> int:
            match s:
                "a":
                    return 1
    SRC
    return expect_flagged(source)


@[test]
function test_duplicate_integer_arm_is_flagged() -> t.Check:
    var source = <<-SRC
        function f(n: int) -> int:
            match n:
                1:
                    return 1
                1:
                    return 2
                _:
                    return 0
    SRC
    return expect_flagged(source)


@[test]
function test_duplicate_enum_arm_is_flagged() -> t.Check:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
        function f(c: Color) -> int:
            match c:
                Color.red:
                    return 1
                Color.red:
                    return 2
                _:
                    return 0
    SRC
    return expect_flagged(source)


@[test]
function test_variant_match_non_exhaustive_is_flagged() -> t.Check:
    var source = <<-SRC
        variant Tok:
            a
            b
            c
        function f(t: Tok) -> int:
            match t:
                Tok.a:
                    return 1
                Tok.b:
                    return 2
    SRC
    return expect_flagged(source)


@[test]
function test_variant_match_exhaustive_is_clean() -> t.Check:
    var source = <<-SRC
        variant Tok:
            a
            b
        function f(t: Tok) -> int:
            match t:
                Tok.a:
                    return 1
                Tok.b:
                    return 2
    SRC
    return expect_clean(source)


@[test]
function test_variant_match_with_payload_pattern_is_permissive() -> t.Check:
    # Payload destructuring patterns are not classified, so exhaustiveness is
    # skipped (permissive) rather than risk a false positive.
    var source = <<-SRC
        variant Tok:
            ident(name: str)
            eof
        function f(t: Tok) -> int:
            match t:
                Tok.ident(name):
                    return 1
    SRC
    return expect_clean(source)


@[test]
function test_method_call_arity_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function add(a: int, b: int) -> int:
                return this.value + a + b
        function f(c: Counter) -> int:
            return c.add(1)
    SRC
    return expect_flagged(source)


@[test]
function test_method_call_correct_arity_is_clean() -> t.Check:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function add(a: int, b: int) -> int:
                return this.value + a + b
        function f(c: Counter) -> int:
            return c.add(1, 2)
    SRC
    return expect_clean(source)


@[test]
function test_method_call_argument_type_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            function add(a: int, b: int) -> int:
                return this.value + a + b
        function f(c: Counter) -> int:
            return c.add(true, 2)
    SRC
    return expect_flagged(source)


@[test]
function test_method_return_type_flows_to_caller() -> t.Check:
    # count() returns int; returning it from a bool function must be flagged.
    var source = <<-SRC
        struct Box:
            n: int
        extending Box:
            function count() -> int:
                return this.n
        function f(b: Box) -> bool:
            return b.count()
    SRC
    return expect_flagged(source)


@[test]
function test_static_method_call_correct_is_clean() -> t.Check:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            static function make(start: int) -> Counter:
                return Counter(value = start)
        function f() -> int:
            let c = Counter.make(5)
            return 0
    SRC
    return expect_clean(source)


@[test]
function test_static_method_call_arity_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            static function make(start: int) -> Counter:
                return Counter(value = start)
        function f() -> int:
            let c = Counter.make()
            return 0
    SRC
    return expect_flagged(source)


@[test]
function test_unknown_static_method_is_flagged() -> t.Check:
    var source = <<-SRC
        struct Counter:
            value: int
        extending Counter:
            static function make(start: int) -> Counter:
                return Counter(value = start)
        function f() -> int:
            let c = Counter.bogus()
            return 0
    SRC
    return expect_flagged(source)


@[test]
function test_block_local_does_not_leak_past_loop() -> t.Check:
    # A loop-local shadowing a parameter must not leak: after the loop, `flag`
    # is the bool parameter again, so returning it from a bool function is clean.
    var source = <<-SRC
        function f(flag: bool) -> bool:
            var i: int = 0
            while i < 3:
                let flag = i
                i += 1
            return flag
    SRC
    return expect_clean(source)


@[test]
function test_interface_conformance_valid_is_clean() -> t.Check:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
            editable function take_damage(amount: int) -> void
        struct NPC implements Damageable:
            hp: int
        extending NPC:
            function is_alive() -> bool:
                return this.hp > 0
            editable function take_damage(amount: int) -> void:
                this.hp = this.hp - amount
    SRC
    return expect_clean(source)


@[test]
function test_interface_missing_method_is_flagged() -> t.Check:
    var source = <<-SRC
        interface Named:
            function name() -> str
        struct Widget implements Named:
            id: int
        extending Widget:
            function other() -> int:
                return this.id
    SRC
    return expect_flagged(source)


@[test]
function test_interface_arity_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        interface Bumper:
            function bump(amount: int) -> int
        struct C implements Bumper:
            n: int
        extending C:
            function bump() -> int:
                return this.n
    SRC
    return expect_flagged(source)


@[test]
function test_interface_return_type_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        interface Producer:
            function produce() -> int
        struct P implements Producer:
            v: int
        extending P:
            function produce() -> bool:
                return true
    SRC
    return expect_flagged(source)


@[test]
function test_opaque_interface_conformance_is_clean() -> t.Check:
    var source = <<-SRC
        interface Closable:
            function close() -> void
        opaque Handle implements Closable
        extending Handle:
            function close() -> void:
                pass
    SRC
    return expect_clean(source)


@[test]
function test_generic_interface_conformance_is_permissive() -> t.Check:
    # Substituted type parameters resolve permissively, so a correct generic
    # implementation is clean (method exists, arity matches).
    var source = <<-SRC
        interface Converter[T, U]:
            function convert(x: T) -> U
        struct Doubler implements Converter[int, int]:
            value: int
        extending Doubler:
            function convert(x: int) -> int:
                return x * 2
    SRC
    return expect_clean(source)


# =============================================================================
#  Generics — handled permissively (type parameters resolve to the error type),
#  so generic bodies never false-positive, while concrete errors inside them are
#  still caught. Deep generic checking (constraints, specialization) is future.
# =============================================================================

@[test]
function test_generic_function_call_is_permissive() -> t.Check:
    var source = <<-SRC
        function id[T](x: T) -> T:
            return x
        function f() -> int:
            return id(5)
    SRC
    return expect_clean(source)


@[test]
function test_generic_struct_declaration_is_clean() -> t.Check:
    var source = <<-SRC
        struct Box[T]:
            value: T
        function f() -> int:
            return 0
    SRC
    return expect_clean(source)


@[test]
function test_constrained_generic_function_is_clean() -> t.Check:
    var source = <<-SRC
        interface Named:
            function name() -> str
        function label[T implements Named](target: ref[T]) -> str:
            return target.name()
    SRC
    return expect_clean(source)


@[test]
function test_concrete_error_in_generic_body_is_flagged() -> t.Check:
    # A generic body is not blanket-permissive: a concrete-typed mismatch (bool
    # returned from an int function) is still flagged.
    var source = <<-SRC
        function wrong[T](x: T) -> int:
            return true
    SRC
    return expect_flagged(source)


# =============================================================================
#  Generic constraint checking — a `[T implements I]` type parameter is a type
#  variable whose only members are its constraint interfaces' methods, checked
#  with full signatures (arity, args, return-type flow). Unconstrained type
#  parameters stay permissive.
# =============================================================================

@[test]
function test_generic_constraint_method_call_is_clean() -> t.Check:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
            editable function take_damage(amount: int) -> void
        function hurt[T implements Damageable](target: ref[T], amount: int) -> void:
            target.take_damage(amount)
    SRC
    return expect_clean(source)


@[test]
function test_generic_constraint_unknown_method_is_flagged() -> t.Check:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
            editable function take_damage(amount: int) -> void
        function hurt[T implements Damageable](target: ref[T]) -> void:
            target.bogus()
    SRC
    return expect_flagged(source)


@[test]
function test_generic_constraint_argument_type_is_flagged() -> t.Check:
    var source = <<-SRC
        interface Damageable:
            editable function take_damage(amount: int) -> void
        function hurt[T implements Damageable](target: ref[T]) -> void:
            target.take_damage(true)
    SRC
    return expect_flagged(source)


@[test]
function test_generic_constraint_return_type_flows() -> t.Check:
    var source = <<-SRC
        interface Named:
            function name() -> str
        function label[T implements Named](target: ref[T]) -> int:
            return target.name()
    SRC
    return expect_flagged(source)


@[test]
function test_generic_multi_constraint_is_clean() -> t.Check:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
        interface Named:
            function name() -> str
        function describe[T implements Damageable and Named](target: ref[T]) -> str:
            if target.is_alive():
                return target.name()
            return "dead"
    SRC
    return expect_clean(source)


@[test]
function test_unconstrained_generic_member_is_permissive() -> t.Check:
    var source = <<-SRC
        function use[T](x: T) -> void:
            x.anything()
    SRC
    return expect_clean(source)
