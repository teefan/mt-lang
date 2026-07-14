# In-language semantic analyzer tests for the self-hosted mtc compiler.
# Run with: mtc test projects/mtc

import std.testing as t
import std.vec as vec

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer


## Parse then semantically analyze `source`, returning the diagnostic count.
## The source is expected to parse cleanly; only semantic diagnostics count.
function diagnostic_count(source: str) -> ptr_uint:
    var pdiags = vec.Vec[pstate.ParseDiagnostic].create()
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
function test_unknown_bare_type_is_flagged() -> t.Check:
    # A bare, unresolved type name is a typo or missing import — always an error.
    # (Cross-module types are qualified `alias.Type`, never bare, so a bare
    # unknown name can never be a legitimate imported type.)
    var source = <<-SRC
        function f(v: SomeUnknownType) -> int:
            return 0
    SRC
    return expect_flagged(source)


@[test]
function test_qualified_unresolved_type_is_permissive() -> t.Check:
    # A qualified `alias.Type` whose binding is unavailable degrades to the
    # permissive error type and must never produce a false positive.
    var source = <<-SRC
        import ext.widgets as ext

        function f(v: ext.SomeImported) -> ext.OtherImported:
            let x: ext.Widget = make_widget()
            return x
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
    # A method call on a value of an unresolved (qualified) type is permissive.
    var source = <<-SRC
        import ext.widgets as ext

        function g(w: ext.Widget) -> int:
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
    # Receivers of imported / ref-wrapped types are not locally-known structs,
    # so their member accesses must never be flagged.
    var source = <<-SRC
        import ext.widgets as ext

        function f(w: ext.Widget, p: ref[ext.Gadget]) -> int:
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


# =============================================================================
#  Associated-function hook checking (S3b-2). hash/equal/order/default require
#  the type argument to provide the hook. Flagged only for a fully-known local
#  struct; primitives, imports, and abstract type parameters stay permissive.
# =============================================================================

@[test]
function test_hook_missing_on_local_struct_is_flagged() -> t.Check:
    var source = <<-SRC
        struct Widget:
            id: int
        function f() -> uint:
            var w: Widget
            return hash[Widget](ref_of(w))
    SRC
    return expect_flagged(source)


@[test]
function test_bare_default_hook_missing_is_flagged() -> t.Check:
    var source = <<-SRC
        struct Widget:
            id: int
        function f() -> Widget:
            return default[Widget]
    SRC
    return expect_flagged(source)


@[test]
function test_hook_present_on_local_struct_is_clean() -> t.Check:
    var source = <<-SRC
        struct Widget:
            id: int
        extending Widget:
            static function hash(value: const_ptr[Widget]) -> uint:
                return 0
        function f() -> uint:
            var w: Widget
            return hash[Widget](ref_of(w))
    SRC
    return expect_clean(source)


@[test]
function test_default_hook_present_is_clean() -> t.Check:
    var source = <<-SRC
        struct Widget:
            id: int
        extending Widget:
            static function default() -> Widget:
                return Widget(id = 0)
        function f() -> Widget:
            return default[Widget]
    SRC
    return expect_clean(source)


@[test]
function test_hook_on_primitive_is_permissive() -> t.Check:
    var source = <<-SRC
        function f() -> uint:
            var n: int = 5
            return hash[int](ref_of(n))
    SRC
    return expect_clean(source)


@[test]
function test_hook_on_type_parameter_is_permissive() -> t.Check:
    var source = <<-SRC
        function keyed[T](value: ref[T]) -> uint:
            return hash[T](value)
    SRC
    return expect_clean(source)


# =============================================================================
#  Generic constraint satisfaction (S3b-3). A concrete local-struct type
#  argument to a generic function must satisfy the parameter's local-interface
#  constraint, whether given explicitly (foo[T]) or inferred from the arguments.
# =============================================================================

@[test]
function test_explicit_type_arg_unsatisfied_constraint_is_flagged() -> t.Check:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
        struct Rock:
            weight: int
        function hurt[T implements Damageable](target: ref[T]) -> void:
            pass
        function f() -> void:
            var r: Rock
            hurt[Rock](ref_of(r))
    SRC
    return expect_flagged(source)


@[test]
function test_explicit_type_arg_satisfied_constraint_is_clean() -> t.Check:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
        struct NPC implements Damageable:
            hp: int
        extending NPC:
            function is_alive() -> bool:
                return this.hp > 0
        function hurt[T implements Damageable](target: ref[T]) -> void:
            pass
        function f() -> void:
            var n: NPC
            hurt[NPC](ref_of(n))
    SRC
    return expect_clean(source)


@[test]
function test_inferred_type_arg_unsatisfied_constraint_is_flagged() -> t.Check:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
        struct Rock:
            weight: int
        function hurt[T implements Damageable](target: ref[T]) -> void:
            pass
        function f() -> void:
            var r: Rock
            hurt(r)
    SRC
    return expect_flagged(source)


@[test]
function test_inferred_type_arg_satisfied_constraint_is_clean() -> t.Check:
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
        struct NPC implements Damageable:
            hp: int
        extending NPC:
            function is_alive() -> bool:
                return this.hp > 0
        function hurt[T implements Damageable](target: ref[T]) -> void:
            pass
        function f() -> void:
            var n: NPC
            hurt(n)
    SRC
    return expect_clean(source)


@[test]
function test_abstract_type_arg_constraint_is_permissive() -> t.Check:
    # Forwarding an abstract U to a constrained parameter cannot be checked, so
    # it stays permissive rather than being flagged.
    var source = <<-SRC
        interface Damageable:
            function is_alive() -> bool
        function hurt[T implements Damageable](target: ref[T]) -> void:
            pass
        function forward[U](thing: ref[U]) -> void:
            hurt(thing)
    SRC
    return expect_clean(source)


# =============================================================================
#  Phase 1 item B: generic-call return-type substitution. Explicit and inferred
#  type arguments are substituted into the generic function's return type, so
#  chained member access on the result is checkable.
# =============================================================================

@[test]
function test_generic_explicit_return_type_is_substituted() -> t.Check:
    var source = <<-SRC
        struct Widget:
            w: int
        function make[T](x: T) -> T:
            return x
        function f() -> int:
            let w = Widget(w = 7)
            let copy = make[Widget](w)
            return copy.w
    SRC
    return expect_clean(source)


@[test]
function test_generic_inferred_return_type_is_substituted() -> t.Check:
    var source = <<-SRC
        struct Widget:
            w: int
        function id[T](x: T) -> T:
            return x
        function f() -> int:
            var w = Widget(w = 7)
            let copy = id(w)
            return copy.w
    SRC
    return expect_clean(source)


@[test]
function test_generic_return_type_mismatch_still_flagged() -> t.Check:
    var source = <<-SRC
        function id[T](x: T) -> T:
            return x
        function f() -> bool:
            var n: int = 3
            return id(n)
    SRC
    return expect_flagged(source)


@[test]
function test_method_kind_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        interface I:
            editable function bump() -> void
        struct S implements I:
            x: int
        extending S:
            function bump() -> void:
                this.x += 1
    SRC
    return expect_flagged(source)


@[test]
function test_method_kind_match_is_clean() -> t.Check:
    var source = <<-SRC
        interface I:
            editable function bump() -> void
        struct S implements I:
            x: int
        extending S:
            editable function bump() -> void:
                this.x += 1
    SRC
    return expect_clean(source)


@[test]
function test_assign_to_let_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            let x = 5
            x = 10
            return x
    SRC
    return expect_flagged(source)


@[test]
function test_compound_assign_to_let_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            let x = 5
            x += 1
            return x
    SRC
    return expect_flagged(source)


@[test]
function test_assign_to_var_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            var x = 5
            x = 10
            return x
    SRC
    return expect_clean(source)


@[test]
function test_let_binding_stays_immutable_after_guard() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            let v = Option[int].some(value = 5) else:
                return 0
            v = 10
            return v
    SRC
    return expect_flagged(source)


@[test]
function test_guard_unnarrows_nullable_value_type() -> t.Check:
    var source = <<-SRC
        function f(m: int?) -> int:
            let val = m else:
                return 0
            return val * 2
    SRC
    return expect_clean(source)


@[test]
function test_guard_unnarrows_pointer_nullable() -> t.Check:
    var source = <<-SRC
        function f(p: ptr[int]?) -> int:
            let safe = p else:
                return 0
            unsafe:
                var x: ptr[int] = safe
                return read(x)
    SRC
    return expect_clean(source)


@[test]
function test_editable_on_let_is_flagged() -> t.Check:
    var source = <<-SRC
        struct C:
            x: int
        extending C:
            editable function bump() -> void:
                this.x += 1
        function f() -> void:
            let c = C(x = 0)
            c.bump()
    SRC
    return expect_flagged(source)


@[test]
function test_editable_on_var_is_clean() -> t.Check:
    var source = <<-SRC
        struct C:
            x: int
        extending C:
            editable function bump() -> void:
                this.x += 1
        function f() -> void:
            var c = C(x = 0)
            c.bump()
    SRC
    return expect_clean(source)


@[test]
function test_adapt_returns_dyn_type() -> t.Check:
    var source = <<-SRC
        interface Shape:
            function area() -> float
        struct C implements Shape:
            r: float
        extending C:
            function area() -> float:
                return this.r * 3.14
        function f() -> dyn[Shape]:
            var c = C(r = 1.0)
            return adapt[Shape](ref_of(c))
    SRC
    return expect_clean(source)


# =============================================================================
#  Integer type compatibility (lossless widening / narrowing detection)
# =============================================================================

@[test]
function test_int_narrowing_to_byte_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> byte:
            var x: int = 999
            return x
    SRC
    return expect_flagged(source)


@[test]
function test_int_widening_to_long_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> long:
            var x: int = 999
            return int<-x
    SRC
    return expect_clean(source)


@[test]
function test_int_to_int_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            var x: int = 999
            return x
    SRC
    return expect_clean(source)


@[test]
function test_uint_narrowing_to_ushort_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> ushort:
            var x: uint = 999
            return x
    SRC
    return expect_flagged(source)


@[test]
function test_numeric_literal_assign_to_byte_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> byte:
            return 42
    SRC
    return expect_clean(source)


@[test]
function test_numeric_literal_assign_to_ushort_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> ushort:
            return 100
    SRC
    return expect_clean(source)


@[test]
function test_float_literal_assign_to_double_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> double:
            return 3.14
    SRC
    return expect_clean(source)


@[test]
function test_int_literal_arg_to_byte_param_is_clean() -> t.Check:
    var source = <<-SRC
        function use(b: byte) -> void:
            pass
        function f() -> void:
            use(65)
    SRC
    return expect_clean(source)


@[test]
function test_int_variable_arg_to_byte_param_is_flagged() -> t.Check:
    var source = <<-SRC
        function use(b: byte) -> void:
            pass
        function f() -> void:
            var x: int = 65
            use(x)
    SRC
    return expect_flagged(source)


# =============================================================================
#  Integer ↔ char compatibility (chars are integer-compatible)
# =============================================================================

@[test]
function test_char_cast_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> char:
            return char<-65
    SRC
    return expect_clean(source)


@[test]
function test_char_to_int_cast_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            var c: char = 'A'
            return int<-(c)
    SRC
    return expect_clean(source)


# =============================================================================
#  Same-width sign changes require a cast (Ruby-faithful)
# =============================================================================

@[test]
function test_int_literal_return_to_uint_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> uint:
            return 0
    SRC
    return expect_clean(source)


@[test]
function test_int_variable_return_to_uint_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> uint:
            var n: int = 0
            return n
    SRC
    return expect_flagged(source)


@[test]
function test_int_cast_return_to_uint_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> uint:
            var n: int = 0
            return uint<-(n)
    SRC
    return expect_clean(source)


@[test]
function test_uint_cast_return_to_int_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            var n: uint = 0
            return int<-(n)
    SRC
    return expect_clean(source)


@[test]
function test_float_to_int_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            var x: float = 1.0
            return x
    SRC
    return expect_flagged(source)


@[test]
function test_int_to_float_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> float:
            var x: int = 1
            return x
    SRC
    return expect_clean(source)


# =============================================================================
#  Nominal type mismatch (distinct structs / enums)
# =============================================================================

@[test]
function test_distinct_struct_assignment_is_flagged() -> t.Check:
    var source = <<-SRC
        struct A:
            x: int
        struct B:
            y: int
        function f() -> A:
            var b = B(y = 1)
            return b
    SRC
    return expect_flagged(source)


@[test]
function test_same_struct_assignment_is_clean() -> t.Check:
    var source = <<-SRC
        struct A:
            x: int
        function f() -> A:
            var a = A(x = 1)
            return a
    SRC
    return expect_clean(source)


@[test]
function test_struct_returned_as_int_is_flagged() -> t.Check:
    var source = <<-SRC
        struct A:
            x: int
        function f() -> int:
            var a = A(x = 1)
            return a
    SRC
    return expect_flagged(source)


@[test]
function test_struct_arg_to_int_param_is_flagged() -> t.Check:
    var source = <<-SRC
        struct A:
            x: int
        function use(n: int) -> void:
            pass
        function f() -> void:
            var a = A(x = 1)
            use(a)
    SRC
    return expect_flagged(source)


@[test]
function test_ref_param_accepts_struct_arg_is_clean() -> t.Check:
    var source = <<-SRC
        struct A:
            x: int
        function use(a: ref[A]) -> void:
            pass
        function f() -> void:
            var a = A(x = 1)
            use(a)
    SRC
    return expect_clean(source)


# =============================================================================
#  Nullable base compatibility
# =============================================================================

@[test]
function test_nullable_target_accepts_base_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            var x: int? = 5
    SRC
    return expect_clean(source)


@[test]
function test_nullable_byte_accepts_literal_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            var x: byte? = 42
    SRC
    return expect_clean(source)


@[test]
function test_nullable_int_rejects_str_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            var s: str = "hi"
            var x: int? = s
    SRC
    return expect_flagged(source)


@[test]
function test_nullable_narrowing_int_variable_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            var n: int = 5
            var x: byte? = n
    SRC
    return expect_flagged(source)


# =============================================================================
#  Aggregate construction completeness
# =============================================================================

@[test]
function test_construction_duplicate_field_is_flagged() -> t.Check:
    var source = <<-SRC
        struct A:
            x: int
        function f() -> A:
            return A(x = 1, x = 2)
    SRC
    return expect_flagged(source)


@[test]
function test_construction_field_type_mismatch_is_flagged() -> t.Check:
    var source = <<-SRC
        struct A:
            x: int
        function f() -> A:
            return A(x = true)
    SRC
    return expect_flagged(source)


@[test]
function test_construction_unnamed_arg_is_flagged() -> t.Check:
    var source = <<-SRC
        struct A:
            x: int
        function f() -> A:
            return A(1)
    SRC
    return expect_flagged(source)


@[test]
function test_construction_narrowing_int_field_is_flagged() -> t.Check:
    var source = <<-SRC
        struct A:
            x: byte
        function f() -> A:
            var n: int = 99
            return A(x = n)
    SRC
    return expect_flagged(source)


@[test]
function test_construction_literal_to_byte_field_is_clean() -> t.Check:
    var source = <<-SRC
        struct A:
            x: byte
        function f() -> A:
            return A(x = 42)
    SRC
    return expect_clean(source)


# =============================================================================
#  Statement body-restriction checks
# =============================================================================

@[test]
function test_return_in_defer_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            defer:
                return 1
            return 2
    SRC
    return expect_flagged(source)


@[test]
function test_void_return_value_is_flagged() -> t.Check:
    var source = <<-SRC
        function f():
            return 1
    SRC
    return expect_flagged(source)


@[test]
function test_parallel_forbids_return_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            parallel for i in 0..4:
                if i > 2:
                    return
    SRC
    return expect_flagged(source)


@[test]
function test_parallel_forbids_break_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            parallel for i in 0..4:
                if i > 2:
                    break
    SRC
    return expect_flagged(source)


@[test]
function test_parallel_forbids_continue_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            parallel for i in 0..4:
                if i == 2:
                    continue
    SRC
    return expect_flagged(source)


@[test]
function test_parallel_block_accepts_two_stmts_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            var a: int = 0
            var b: int = 0
            parallel:
                a = 1
                b = 2
    SRC
    return expect_clean(source)


# =============================================================================
#  Unsafe context enforcement
# =============================================================================

@[test]
function test_read_ptr_without_unsafe_is_flagged() -> t.Check:
    var source = <<-SRC
        function f(p: ptr[int]) -> int:
            return read(p)
    SRC
    return expect_flagged(source)


@[test]
function test_read_ptr_inside_unsafe_is_clean() -> t.Check:
    var source = <<-SRC
        function f(p: ptr[int]) -> int:
            unsafe:
                return read(p)
    SRC
    return expect_clean(source)


@[test]
function test_pointer_arithmetic_without_unsafe_is_flagged() -> t.Check:
    var source = <<-SRC
        function f(p: ptr[int]) -> ptr[int]:
            return p + 1
    SRC
    return expect_flagged(source)


@[test]
function test_pointer_cast_without_unsafe_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> ptr[int]:
            return ptr[int]<-0
    SRC
    return expect_flagged(source)


@[test]
function test_pointer_cast_inside_unsafe_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> ptr[int]:
            unsafe:
                return ptr[int]<-0
    SRC
    return expect_clean(source)


@[test]
function test_reinterpret_without_unsafe_is_flagged() -> t.Check:
    var source = <<-SRC
        function f(x: float) -> uint:
            return reinterpret[uint](x)
    SRC
    return expect_flagged(source)


@[test]
function test_reinterpret_inside_unsafe_is_clean() -> t.Check:
    var source = <<-SRC
        function f(x: float) -> uint:
            unsafe:
                return reinterpret[uint](x)
    SRC
    return expect_clean(source)


@[test]
function test_ptr_of_without_unsafe_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> ptr[int]:
            var x: int = 5
            return ptr_of(x)
    SRC
    return expect_clean(source)


# =============================================================================
#  Builtin call result types
# =============================================================================

@[test]
function test_zero_returns_specified_type_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            return zero[int]
    SRC
    return expect_clean(source)


@[test]
function test_size_of_returns_ptr_uint_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> ptr_uint:
            return size_of(int)
    SRC
    return expect_clean(source)


@[test]
function test_read_ptr_returns_element_type_is_clean() -> t.Check:
    var source = <<-SRC
        function f(p: ptr[int]) -> int:
            unsafe:
                return read(p)
    SRC
    return expect_clean(source)


# =============================================================================
#  Duplicate parameter names
# =============================================================================

@[test]
function test_duplicate_param_is_flagged() -> t.Check:
    var source = <<-SRC
        function f(a: int, a: int) -> int:
            return a
    SRC
    return expect_flagged(source)


@[test]
function test_unique_params_is_clean() -> t.Check:
    var source = <<-SRC
        function f(a: int, b: int) -> int:
            return a + b
    SRC
    return expect_clean(source)


# =============================================================================
#  Await outside async
# =============================================================================

@[test]
function test_await_outside_async_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            return await f()
    SRC
    return expect_flagged(source)


# =============================================================================
#  Primitive / reserved name reuse
# =============================================================================

@[test]
function test_param_named_int_is_flagged() -> t.Check:
    var source = <<-SRC
        function f(int: int) -> int:
            return int
    SRC
    return expect_flagged(source)


@[test]
function test_local_named_str_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            let str = 5
            return str
    SRC
    return expect_flagged(source)


# =============================================================================
#  Review-pass fixes: defer-in-parallel, negative-literal gate
# =============================================================================

@[test]
function test_defer_in_parallel_block_is_flagged() -> t.Check:
    var source = <<-SRC
        function f() -> void:
            var a: int = 0
            var b: int = 0
            parallel:
                defer a += 1
                b = 2
    SRC
    return expect_flagged(source)


@[test]
function test_negative_literal_return_to_byte_is_clean() -> t.Check:
    var source = <<-SRC
        function f() -> byte:
            return -42
    SRC
    return expect_clean(source)


# =============================================================================
#  == null narrowing (else-body)
# =============================================================================

@[test]
function test_not_equal_null_narrows_if_body_is_clean() -> t.Check:
    var source = <<-SRC
        function f(p: ptr[int]?) -> int:
            if p != null:
                return unsafe: read(p)
            return 0
    SRC
    return expect_clean(source)


@[test]
function test_equal_null_narrows_else_body_is_clean() -> t.Check:
    var source = <<-SRC
        function f(p: ptr[int]?) -> int:
            if p == null:
                return 0
            return unsafe: read(p)
    SRC
    return expect_clean(source)


# =============================================================================
#  Attribute target validation
# =============================================================================

@[test]
function test_packed_on_struct_is_clean() -> t.Check:
    var source = <<-SRC
        @[packed]
        struct A:
            x: int
    SRC
    return expect_clean(source)


@[test]
function test_packed_on_function_is_flagged() -> t.Check:
    var source = <<-SRC
        @[packed]
        function f() -> int:
            return 0
    SRC
    return expect_flagged(source)


# =============================================================================
#  Phase 1: resolved_expr_types and resolved_call_kinds tables
# =============================================================================

@[test]
function test_resolved_types_recording_does_not_crash() -> t.Check:
    var source = <<-SRC
        function f() -> int:
            let x = 42
            let y = x + 1
            return y
    SRC
    return expect_clean(source)
