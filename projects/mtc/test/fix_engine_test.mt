## Tests for the linter auto-fix engine (`mtc lint --fix`) and the
## `.mt-lint.yml` configuration parser.
## Run with: mtc test projects/mtc

import std.str
import std.string as string
import std.vec as vec

import mtc.linter.config as lint_config
import mtc.linter.fix_engine as fix_engine


## Run the fix engine over `source` with no select/ignore filters.
function fix_all(source: str) -> string.String:
    var select = vec.Vec[str].create()
    defer: select.release()
    var ignore = vec.Vec[str].create()
    defer: ignore.release()
    return fix_engine.fix_source(source, "test.mt", span[str](), ref_of(select), ref_of(ignore))


function expect_fixed(source: str, expected: str) -> void:
    var fixed = fix_all(source)
    defer: fixed.release()
    expect_eq(fixed.as_str(), expected)


# =============================================================================
#  prefer-let
# =============================================================================

@[test]
function test_fix_prefer_let() -> void:
    let source = <<-SRC
        function demo(a: int) -> int:
            var x = a
            return x
    SRC
    let expected = <<-SRC
        function demo(a: int) -> int:
            let x = a
            return x
    SRC
    expect_fixed(source, expected)


@[test]
function test_fix_prefer_let_keeps_reassigned_var() -> void:
    let source = <<-SRC
        function demo(a: int) -> int:
            var x = a
            x = x + 1
            return x
    SRC
    expect_fixed(source, source)


# =============================================================================
#  redundant-return
# =============================================================================

@[test]
function test_fix_redundant_return() -> void:
    let source = <<-SRC
        function demo() -> void:
            let _x = 1
            return
    SRC
    let expected = <<-SRC
        function demo() -> void:
            let _x = 1
    SRC
    expect_fixed(source, expected)


# =============================================================================
#  redundant-else
# =============================================================================

@[test]
function test_fix_redundant_else() -> void:
    let source = <<-SRC
        function demo(flag: bool) -> int:
            if flag:
                return 1
            else:
                return 2
    SRC
    let expected = <<-SRC
        function demo(flag: bool) -> int:
            if flag:
                return 1
            return 2
    SRC
    expect_fixed(source, expected)


# =============================================================================
#  trailing-list-comma
# =============================================================================

@[test]
function test_fix_trailing_comma() -> void:
    let source = <<-SRC
        function add(a: int, b: int) -> int:
            return a + b

        function demo() -> int:
            return add(1, 2,)
    SRC
    let expected = <<-SRC
        function add(a: int, b: int) -> int:
            return a + b

        function demo() -> int:
            return add(1, 2)
    SRC
    expect_fixed(source, expected)


# =============================================================================
#  redundant-cast
# =============================================================================

@[test]
function test_fix_redundant_cast() -> void:
    let source = <<-SRC
        function demo(n: int) -> int:
            var total: int = n
            total = int<-total
            return total
    SRC
    let expected = <<-SRC
        function demo(n: int) -> int:
            var total: int = n
            total = total
            return total
    SRC
    expect_fixed(source, expected)


@[test]
function test_fix_redundant_cast_unwraps_unsafe() -> void:
    let source = <<-SRC
        function demo(n: int) -> int:
            var total: int = n
            let mirrored = unsafe: int<-total
            return mirrored
    SRC
    # prefer-let also fires here: `total` is never reassigned.
    let expected = <<-SRC
        function demo(n: int) -> int:
            let total: int = n
            let mirrored = total
            return mirrored
    SRC
    expect_fixed(source, expected)


# =============================================================================
#  redundant-bool-compare
# =============================================================================

@[test]
function test_fix_bool_compare_true() -> void:
    let source = <<-SRC
        function demo(flag: bool) -> int:
            if flag == true:
                return 1
            return 0
    SRC
    let expected = <<-SRC
        function demo(flag: bool) -> int:
            if flag:
                return 1
            return 0
    SRC
    expect_fixed(source, expected)


@[test]
function test_fix_bool_compare_false_inverts() -> void:
    let source = <<-SRC
        function demo(flag: bool) -> int:
            if flag == false:
                return 1
            return 0
    SRC
    let expected = <<-SRC
        function demo(flag: bool) -> int:
            if not flag:
                return 1
            return 0
    SRC
    expect_fixed(source, expected)


@[test]
function test_fix_bool_compare_literal_first_untouched() -> void:
    let source = <<-SRC
        function demo(flag: bool) -> int:
            if true == flag:
                return 1
            return 0
    SRC
    expect_fixed(source, source)


# =============================================================================
#  redundant-type-annotation
# =============================================================================

@[test]
function test_fix_redundant_type_annotation() -> void:
    let source = <<-SRC
        function demo() -> int:
            let count: int = 5
            return count
    SRC
    let expected = <<-SRC
        function demo() -> int:
            let count = 5
            return count
    SRC
    expect_fixed(source, expected)


# =============================================================================
#  unused-import must never be auto-fixed
# =============================================================================

@[test]
function test_fix_keeps_unused_import() -> void:
    let source = <<-SRC
        import std.hash

        function demo() -> int:
            return 1
    SRC
    expect_fixed(source, source)


# =============================================================================
#  select / ignore filters
# =============================================================================

@[test]
function test_fix_respects_ignore() -> void:
    let source = <<-SRC
        function demo(a: int) -> int:
            var x = a
            return x
    SRC
    var select = vec.Vec[str].create()
    defer: select.release()
    var ignore = vec.Vec[str].create()
    defer: ignore.release()
    ignore.push("prefer-let")
    var fixed = fix_engine.fix_source(source, "test.mt", span[str](), ref_of(select), ref_of(ignore))
    defer: fixed.release()
    expect_eq(fixed.as_str(), source)


@[test]
function test_fix_respects_select() -> void:
    let source = <<-SRC
        function demo(a: int) -> void:
            var _x = a
            return
    SRC
    let expected = <<-SRC
        function demo(a: int) -> void:
            var _x = a
    SRC
    var select = vec.Vec[str].create()
    defer: select.release()
    select.push("redundant-return")
    var ignore = vec.Vec[str].create()
    defer: ignore.release()
    var fixed = fix_engine.fix_source(source, "test.mt", span[str](), ref_of(select), ref_of(ignore))
    defer: fixed.release()
    expect_eq(fixed.as_str(), expected)


# =============================================================================
#  is_fixable
# =============================================================================

@[test]
function test_is_fixable_codes() -> void:
    if not fix_engine.is_fixable("prefer-let"):
        expect(false)
    if fix_engine.is_fixable("unused-import"):
        expect(false)
    expect(fix_engine.is_fixable("trailing-list-comma"))


# =============================================================================
#  .mt-lint.yml parsing
# =============================================================================

@[test]
function test_config_block_lists() -> void:
    let source = <<-CFG
        # comment
        select:
          - prefer-let
          - redundant-else
        max_line_length: 100
    CFG
    var cfg = lint_config.parse_config(source)
    defer: cfg.release()
    if not cfg.has_select:
        expect(false)
    if cfg.select.len() != 2:
        expect_eq(int<-(cfg.select.len()), 2)
    let first = cfg.select.get(0) else:
        expect(false)
    unsafe:
        if not read(first).as_str().equal("prefer-let"):
            expect(false)
    expect_eq(int<-(cfg.max_line_length), 100)


@[test]
function test_config_inline_list() -> void:
    let source = "ignore: [line-too-long, doc-tag]\n"
    var cfg = lint_config.parse_config(source)
    defer: cfg.release()
    if not cfg.has_ignore:
        expect(false)
    if cfg.ignore.len() != 2:
        expect_eq(int<-(cfg.ignore.len()), 2)
    let second = cfg.ignore.get(1) else:
        expect(false)
    unsafe:
        expect_eq(read(second).as_str(), "doc-tag")


@[test]
function test_config_empty_when_missing_keys() -> void:
    var cfg = lint_config.parse_config("other_key: value\n")
    defer: cfg.release()
    if cfg.has_select or cfg.has_ignore:
        expect(false)
    expect_eq(int<-(cfg.max_line_length), 0)
