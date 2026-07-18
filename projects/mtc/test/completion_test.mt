import std.testing as t
import std.vec as vec
import std.str as str_ops
import std.string as string_mod

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.lsp.completion as comp


@[test]
function test_receiver_type_resolution() -> t.Check:
    var source = <<-SRC
        struct Vec:
            x: float
        extending Vec:
            function length() -> float:
                return 0.0
    SRC
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)
    let name = comp.resolve_receiver_type_name(ref_of(analysis), "Vec")
    if not name.equal("Vec"):
        return t.fail("Vec type not resolved")
    return t.ok()
