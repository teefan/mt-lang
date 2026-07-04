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
    var sdiags = analyzer.check_source_file(file)
    defer sdiags.release()
    return sdiags.len()


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
