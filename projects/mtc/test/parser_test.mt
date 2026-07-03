# In-language parser tests for the self-hosted mtc compiler.
# Run with: mtc test projects/mtc

import std.testing as t
import std.vec as vec
import mtc.parser.parser as parser


function check_parse(source: str) -> t.Check:
    var diags = vec.Vec[parser.ParseDiagnostic].create()
    defer diags.release()
    let ok = parser.parse_reporting(source, ref_of(diags))
    if not ok:
        return t.fail("parse errors")
    return t.ok()


@[test]
function test_parses_function() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_block_const() -> t.Check:
    var source = <<-SRC
        const VAL -> int:
            return 42
    SRC
    return check_parse(source)


@[test]
function test_parses_const_equal() -> t.Check:
    var source = <<-SRC
        const WIDTH: int = 42
    SRC
    return check_parse(source)


@[test]
function test_parses_var() -> t.Check:
    var source = <<-SRC
        var counter: int = 0
    SRC
    return check_parse(source)


@[test]
function test_parses_if_else() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            if true:
                return 1
            else:
                return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_while() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            var i: int = 0
            while i < 10:
                i += 1
            return i
    SRC
    return check_parse(source)


@[test]
function test_parses_match_int() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            match 0:
                0:
                    return 42
                _:
                    return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_struct() -> t.Check:
    var source = <<-SRC
        struct Vec2:
            x: float
            y: float
    SRC
    return check_parse(source)


@[test]
function test_parses_for_range() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            var total: int = 0
            for i in 0..4:
                total += i
            return total
    SRC
    return check_parse(source)


@[test]
function test_parses_let_else() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            let x: ptr[int]? = null
            let val = x else:
                return 1
            return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_defer() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            defer:
                var x: int = 1
            return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_unsafe_block() -> t.Check:
    var source = <<-SRC
        function main() -> int:
            unsafe:
                return 0
    SRC
    return check_parse(source)


@[test]
function test_parses_import_as() -> t.Check:
    var source = <<-SRC
        import std.vec as vec
    SRC
    return check_parse(source)
