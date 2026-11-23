## In-language tests for the LSP cursor helpers.
## Run with: `mtc test projects/mtc/test/cursor_test.mt`

import std.str

import mtc.lsp.cursor as cursor


@[test]
function test_call_context_counts_top_level_commas() -> void:
    let source = "function main() -> int:\n    add(1, 2)\n    return 0\n"
    # Line 1 is `    add(1, 2)`; byte 10 is between the comma and `2`.
    let ctx = cursor.call_context_at(source, 1z, 10z) else:
        expect(false, "no call context")
        return
    expect(ctx.name.equal("add"), ctx.name)
    expect_eq(int<-ctx.active_parameter, 1)


@[test]
function test_call_context_uses_the_innermost_call() -> void:
    let source = "function main() -> int:\n    outer(inner(1, 2), 3)\n    return 0\n"
    # Inside `inner` after its comma.
    let inner = cursor.call_context_at(source, 1z, 18z) else:
        expect(false, "no inner call context")
        return
    expect(inner.name.equal("inner"), inner.name)
    expect_eq(int<-inner.active_parameter, 1)

    # Inside `outer` after the nested call.
    let outer = cursor.call_context_at(source, 1z, 22z) else:
        expect(false, "no outer call context")
        return
    expect(outer.name.equal("outer"), outer.name)
    expect_eq(int<-outer.active_parameter, 1)


@[test]
function test_call_context_ignores_commas_in_brackets() -> void:
    let source = "function main() -> int:\n    f([1, 2], 3)\n    return 0\n"
    # After the bracketed argument's comma, before `3`.
    let ctx = cursor.call_context_at(source, 1z, 13z) else:
        expect(false, "no call context")
        return
    expect(ctx.name.equal("f"), ctx.name)
    expect_eq(int<-ctx.active_parameter, 1)


@[test]
function test_call_context_absent_outside_a_call() -> void:
    let source = "function main() -> int:\n    return 0\n"
    expect(cursor.call_context_at(source, 1z, 4z).is_none(), "unexpected call context")
