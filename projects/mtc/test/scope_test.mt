import std.testing as t
import std.vec as vec

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.lsp.scope as scope_mod


@[test]
function test_scope_shadow_separate_functions() -> t.Check:
    var source = "function foo() -> int:\n    var x: int = 1\n    return x\n\nfunction bar() -> int:\n    var x: int = 2\n    return x\n"
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var bindings = scope_mod.collect_bindings(source, ast_file)
    defer bindings.release()

    if scope_mod.is_in_same_scope(ref_of(bindings), "x", 2z, 6z):
        return t.fail("foo.x (line 2) should not rename bar.x (line 6)")

    if not scope_mod.is_in_same_scope(ref_of(bindings), "x", 2z, 2z):
        return t.fail("foo.x should rename its own occurrence")

    if not scope_mod.is_in_same_scope(ref_of(bindings), "x", 2z, 4z):
        return t.fail("x at line 4 should be in foo.x scope")

    if not scope_mod.is_in_same_scope(ref_of(bindings), "foo", 1z, 1z):
        return t.fail("module-level foo should rename globally")

    return t.ok()


@[test]
function test_scope_nested_shadow() -> t.Check:
    var source = "function main() -> int:\n    var x: int = 10\n    if true:\n        var x: int = 20\n        return x\n    return x\n"
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var bindings = scope_mod.collect_bindings(source, ast_file)
    defer bindings.release()

    if not scope_mod.is_in_same_scope(ref_of(bindings), "x", 2z, 6z):
        return t.fail("outer x should match return at line 6")

    if scope_mod.is_in_same_scope(ref_of(bindings), "x", 2z, 4z):
        return t.fail("outer x should NOT rename inner x (line 4)")

    if scope_mod.is_in_same_scope(ref_of(bindings), "x", 4z, 2z):
        return t.fail("inner x should NOT rename outer x (line 2)")

    if not scope_mod.is_in_same_scope(ref_of(bindings), "main", 1z, 1z):
        return t.fail("module-level main should rename globally")

    return t.ok()
