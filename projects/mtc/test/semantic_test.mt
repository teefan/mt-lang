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
function test_unknown_field_read_is_permissive() -> t.Check:
    # A member that is not a field may be an `extending` method; reads must not
    # be flagged in phase 3.
    var source = <<-SRC
        struct Box:
            x: int
        function f(b: Box) -> int:
            return b.compute()
    SRC
    return expect_clean(source)
