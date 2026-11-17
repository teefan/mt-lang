import std.fs as fs
import std.mem.heap as heap
import std.path as path_ops
import std.vec as vec
import std.str as str_ops
import std.string as string_mod

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.lsp.completion as comp


## Remove a temp directory tree and release its owned path string.
function cleanup_dir(dir: ref[string_mod.String]) -> void:
    match fs.remove_tree(dir.as_str()):
        Result.success:
            pass
        Result.failure as f:
            var e = f.error
            e.release()
    dir.release()


@[test]
function test_doc_text_does_not_slice_through_multibyte_text() -> void:
    ## The declaration scan compared every line prefix by slicing `name.len`
    ## bytes, which aborts when that window splits a code point.  Resolving any
    ## completion item documented in such a file killed the server.
    var root = fs.create_temporary_directory_in_system_temp("mtc_doc_") else:
        expect(false, "could not create temp dir")
        return
    defer: cleanup_dir(ref_of(root))

    var file_path = path_ops.join(root.as_str(), "doc.mt")
    defer: file_path.release()
    # 10 ASCII bytes then a two-byte `é`: an 11-byte window splits it.
    let content = "0123456789é\n## field doc\ntarget_name: int\n"
    match fs.write_text(file_path.as_str(), content):
        Result.success:
            pass
        Result.failure as f:
            var e = f.error
            e.release()
            expect(false, "could not write doc.mt")
            return

    var docs = comp.collect_doc_text(file_path.as_str(), "target_name")
    defer: docs.release()
    expect(docs.as_str().equal("field doc"), docs.as_str())


## Parse and analyze a standalone test source.
function analyze_source(source: str) -> analyzer.Analysis:
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    return analyzer.check_source_file(ast_file)


@[test]
function test_attribute_completion_lists_builtins_and_declared() -> void:
    var source = <<-SRC
        attribute[callable] traced(tag: str)

        function demo() -> int:
            return 0
    SRC
    var analysis = analyze_source(source)

    var items = comp.attribute_completion_items(ref_of(analysis), "@[", "file:///probe.mt")
    if items == null:
        expect(false, "no attribute completions")
        return
    var text = unsafe: read(items)
    expect(text.as_str().contains_substring("\"packed\""), text.as_str())
    expect(text.as_str().contains_substring("\"align\""), text.as_str())
    expect(text.as_str().contains_substring("\"deprecated\""), text.as_str())
    expect(text.as_str().contains_substring("\"traced\""), text.as_str())
    text.release()
    heap.release(items)


@[test]
function test_named_argument_completion_covers_fields_and_parameters() -> void:
    var source = <<-SRC
        struct Point:
            x: float
            y: float

        function make(x: int, y: int) -> int:
            return x + y
    SRC
    var analysis = analyze_source(source)

    var fields = comp.named_argument_completion_items(ref_of(analysis), "Point(", "", "file:///probe.mt")
    if fields == null:
        expect(false, "no constructor argument completions")
        return
    var field_text = unsafe: read(fields)
    expect(field_text.as_str().contains_substring("\"x = \""), field_text.as_str())
    expect(field_text.as_str().contains_substring("\"y = \""), field_text.as_str())
    expect(field_text.as_str().contains_substring("\"kind\":8"), field_text.as_str())
    field_text.release()
    heap.release(fields)

    # `x` is already provided, so only `y` remains.
    var params = comp.named_argument_completion_items(ref_of(analysis), "make(x = 1, ", "", "file:///probe.mt")
    if params == null:
        expect(false, "no named parameter completions")
        return
    var param_text = unsafe: read(params)
    expect(param_text.as_str().contains_substring("\"y = \""), param_text.as_str())
    expect(not param_text.as_str().contains_substring("\"x = \""), param_text.as_str())
    param_text.release()
    heap.release(params)


@[test]
function test_specialization_completion_lists_types() -> void:
    var source = <<-SRC
        struct Point:
            x: float

        function demo() -> int:
            return 0
    SRC
    var analysis = analyze_source(source)

    var items = comp.specialization_completion_items(ref_of(analysis), "array[", "file:///probe.mt")
    if items == null:
        expect(false, "no specialization completions")
        return
    var text = unsafe: read(items)
    expect(text.as_str().contains_substring("\"Point\""), text.as_str())
    expect(text.as_str().contains_substring("\"int\""), text.as_str())
    expect(text.as_str().contains_substring("\"kind\":5"), text.as_str())
    text.release()
    heap.release(items)


@[test]
function test_receiver_type_resolution() -> void:
    var source = <<-SRC
        struct Vec:
            x: float
        extending Vec:
            function length() -> float:
                return 0.0
    SRC
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)
    let name = comp.resolve_receiver_type_name(ref_of(analysis), "Vec")
    if not name.equal("Vec"):
        expect(false, "Vec type not resolved")
    return
