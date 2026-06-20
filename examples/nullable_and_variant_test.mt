# examples/nullable_and_variant_regression.mt
#
# Comprehensive regression suite covering all compiler fixes related to
# nullable types, self-referencing variants, let/var-else, and C keyword
# sanitization (Bugs 1–11 in docs/selfhost-plan.md).

import std.string as string

# ============================================================
# Section 1 — Self-referencing variants (Bugs 1, 2, 4)
#   - construct trees and trees-of-trees
#   - match on self-ref arms (Bug 7: else: wildcard)
#   - C keyword arm name sanitization (Bug 11)
# ============================================================

variant Expr:
    integer_literal(value: int)
    binary_op(operator: str, left: Expr, right: Expr)
    unary_op(operator: str, operand: Expr)
    sizeof(byte_size: int)          ## C keyword arm → sanitized
    switch(val: int)                ## C keyword arm → sanitized

struct Tree:
    label: string.String
    count: int

variant Forest:
    empty
    node(tree: Tree, left: Forest, right: Forest)


function build_ast() -> Expr:
    var a = Expr.integer_literal(value = 1)
    var b = Expr.integer_literal(value = 2)
    return Expr.binary_op(operator = "+", left = a, right = b)


function build_tree() -> Forest:
    var left = Forest.empty
    var right = Forest.empty
    var t = Tree(label = string.String.from_str("root"), count = 0)
    return Forest.node(tree = t, left = left, right = right)


function eval_expr(expr: Expr) -> int:
    match expr:
        Expr.integer_literal as lit:
            return lit.value
        Expr.binary_op as bin:
            var l = eval_expr(bin.left)
            var r = eval_expr(bin.right)
            return l + r
        Expr.unary_op as u:
            return 0 - eval_expr(u.operand)
        Expr.sizeof as s:
            return s.byte_size
        Expr.switch as sw:
            return sw.val
        else:
            return 0


function forest_depth(f: Forest) -> int:
    match f:
        Forest.empty:
            return 0
        Forest.node as n:
            var ld = forest_depth(n.left)
            var rd = forest_depth(n.right)
            if ld > rd:
                return ld + 1
            return rd + 1


# ============================================================
# Section 2 — Nullable struct fields (Bugs 5, 6, 10)
#   - assign value to var x: T? = null
#   - construct struct with nullable fields from locals
#   - construct struct with nullable fields from rvalue (func call)
# ============================================================

struct Config:
    port: int?
    label: string.String?
    meta: Meta?

struct Meta:
    version: int
    debug: bool


function make_port() -> int:
    return 8080


function make_version() -> int:
    return 3


function exercise_nullable_struct_fields() -> int:
    # Bug 5: assign non-null to var T? = null
    var port: int? = null
    port = 8080

    # Bug 10: nullable struct field from rvalue (func call)
    var cfg1 = Config(
        port = make_port(),
        label = null,
        meta = Meta(version = make_version(), debug = true))

    # Bug 6: nullable struct field from addressable local
    var version_local: int = 5
    var meta2 = Meta(version = version_local, debug = false)
    var cfg2 = Config(port = port, label = string.String.from_str("hello"), meta = meta2)

    return 0


# ============================================================
# Section 3 — let-else and var-else with nullable primitives (Bug 8)
#   - int?, str?, bool? unwrapping via let-else
#   - passing unwrapped values to functions (not pointers)
# ============================================================

function consume_int(val: int) -> int:
    return val + 1

function consume_bool(val: bool) -> bool:
    return not val


function exercise_let_else_primitive() -> int:
    # let-else on int? (non-null case — should unwrap)
    var a: int? = 42
    let a_val = a else:
        return 1
    var a_result = consume_int(a_val)       ## must pass value, not pointer

    # let-else on int? (also non-null)
    var b: int? = 99
    let b_val = b else:
        return 2
    var b_result = consume_int(b_val)

    # var-else on bool?
    var c: bool? = true
    var c_val = c else:
        return 3
    var c_result = consume_bool(c_val)

    return a_result


# ============================================================
# Section 4 — let-else and var-else with nullable structs (Bug 8)
#   - struct? unwrapping produces value, not pointer
# ============================================================

function consume_config(cfg: Config) -> int:
    return 0


function consume_tree(t: Forest) -> int:
    return forest_depth(t)


function exercise_let_else_struct() -> int:
    # let-else on struct?
    var cfg: Config? = Config(
        port = 3000,
        label = string.String.from_str("config"),
        meta = Meta(version = 1, debug = true))
    let cfg_val = cfg else:
        return 10
    var cfg_result = consume_config(cfg_val)  ## must pass value, not pointer

    # let-else on variant?
    var tree: Forest? = Forest.empty
    let tree_val = tree else:
        return 11
    var tree_result = consume_tree(tree_val)  ## must pass value, not pointer

    return cfg_result + tree_result


# ============================================================
# Section 5 — Multiple let-else chains (nested unwrap)
# ============================================================

function make_value() -> int?:
    var result: int? = 7
    return result

function double_make(val: int?) -> int?:
    return val


function exercise_chained_let_else() -> int:
    var x: int? = 10
    var y: int? = 20

    let x_val = x else:
        return 100
    let y_val = y else:
        return 200

    return x_val + y_val


# ============================================================
# Section 6 — Nullable assignment to variant field (Bug 6)
#   - Variant constructor with nullable fields
#   - Already-nullable pass-through (no double wrapping)
# ============================================================

variant NullableFields:
    with_values(port: int?, name: string.String?)
    empty


function build_nullable_variant(raw: int) -> NullableFields:
    # non-nullable local → nullable field (needs wrapping)
    return NullableFields.with_values(port = raw, name = string.String.from_str("test"))


function build_with_nullable() -> NullableFields:
    # already-nullable local → nullable field (no double wrapping)
    var opt: int? = null
    opt = 99
    return NullableFields.with_values(port = opt, name = null)


# ============================================================
# Section 7 — Edge cases
# ============================================================

function nullable_from_func() -> int:
    # chained: function returns nullable, unwrapped by let-else
    var result: int = 0
    let val1 = make_value() else:
        return 500
    result = result + val1

    let val2 = double_make(make_value()) else:
        return 501
    result = result + val2

    return result


# ============================================================
# main — run all sections and verify
# ============================================================

function main() -> int:
    var failures: int = 0

    # Section 1 — self-referencing variants: build and eval in same scope
    # (local variables must outlive the variant's pointer fields)
    var a = Expr.integer_literal(value = 1)
    var b = Expr.integer_literal(value = 2)
    var ast = Expr.binary_op(operator = "+", left = a, right = b)
    if eval_expr(ast) != 3:
        failures = failures + 1

    var t = Tree(label = string.String.from_str("root"), count = 0)
    var left_f = Forest.empty
    var right_f = Forest.empty
    var forest = Forest.node(tree = t, left = left_f, right = right_f)
    if forest_depth(forest) != 1:
        failures = failures + 1

    # Section 2
    exercise_nullable_struct_fields()

    # Section 3
    var s3 = exercise_let_else_primitive()
    if s3 != 43:
        failures = failures + 1

    # Section 4
    var s4 = exercise_let_else_struct()
    if s4 != 0:
        failures = failures + 1

    # Section 5
    var s5 = exercise_chained_let_else()
    if s5 != 30:
        failures = failures + 1

    # Section 6
    build_nullable_variant(5)
    build_with_nullable()

    # Section 7
    var s7 = nullable_from_func()
    if s7 != 14:
        failures = failures + 1

    return failures
