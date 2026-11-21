import std.fs as fs
import std.mem.heap as heap
import std.path as path_ops
import std.vec as vec
import std.str as str_ops
import std.string as string_mod

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
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


@[test]
function test_doc_text_finds_declarations_with_keywords_and_indentation() -> void:
    var root = fs.create_temporary_directory_in_system_temp("mtc_doc_") else:
        expect(false, "could not create temp dir")
        return
    defer: cleanup_dir(ref_of(root))

    var file_path = path_ops.join(root.as_str(), "decls.mt")
    defer: file_path.release()
    let content = <<-SRC
        ## Foo docs.
        public function foo() -> int:
            return 0

        struct S:
            ## Field docs.
            value: int

            ## Method docs.
            function method() -> int:
                return 1

        ## Enum docs.
        enum Color:
            ## Member docs.
            red
    SRC
    match fs.write_text(file_path.as_str(), content):
        Result.success:
            pass
        Result.failure as f:
            var e = f.error
            e.release()
            expect(false, "could not write decls.mt")
            return

    var foo_docs = comp.collect_doc_text(file_path.as_str(), "foo")
    defer: foo_docs.release()
    expect(foo_docs.as_str().equal("Foo docs."), foo_docs.as_str())
    var field_docs = comp.collect_doc_text(file_path.as_str(), "value")
    defer: field_docs.release()
    expect(field_docs.as_str().equal("Field docs."), field_docs.as_str())
    var method_docs = comp.collect_doc_text(file_path.as_str(), "method")
    defer: method_docs.release()
    expect(method_docs.as_str().equal("Method docs."), method_docs.as_str())
    var member_docs = comp.collect_doc_text(file_path.as_str(), "red")
    defer: member_docs.release()
    expect(member_docs.as_str().equal("Member docs."), member_docs.as_str())


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
    # The host's `facts.types` registration order: built-ins first, the
    # module's declared types last (a map's bucket order would interleave them).
    let bool_pos = text.as_str().find_substring("\"label\":\"bool\"") else:
        expect(false, "bool missing")
        text.release()
        heap.release(items)
        return
    let point_pos = text.as_str().find_substring("\"label\":\"Point\"") else:
        expect(false, "Point missing")
        text.release()
        heap.release(items)
        return
    expect(bool_pos < point_pos, "built-ins must precede module types")
    text.release()
    heap.release(items)


@[test]
function test_format_string_completion_narrows_to_values_functions_locals() -> void:
    ## Inside `f"... #{` the host answers only values (`0_`), functions (`1_`)
    ## and the enclosing function's snapshot locals (`2_`); the global bucket
    ## (types, constructors, keywords) never applies there.
    var source = <<-SRC
        const LIMIT: int = 3
        var counter: int = 0

        function helper(x: int) -> int:
            return x + 1

        function demo(a: int) -> int:
            let local_value = a + 1
            if local_value > 0:
                let nested_value = 2
                let _nested = nested_value
            let before_cursor = 1
            let here = f"v #{}
            return local_value + before_cursor
    SRC
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)

    # Cursor on the `here` line (0-based 12) after the unterminated `#{`.
    let cursor_line: ptr_uint = 12
    var items = comp.format_string_completion_items(
        ref_of(analysis), ast_file, "    let here = f\"v #{", cursor_line, "file:///probe.mt")
    if items == null:
        expect(false, "no format-string completions")
        return
    var text = unsafe: read(items)
    let rendered = text.as_str()
    # Values, functions and snapshot locals, each in its host sort bucket.
    expect(rendered.contains_substring("\"sortText\":\"0_LIMIT\""), rendered)
    expect(rendered.contains_substring("\"sortText\":\"0_counter\""), rendered)
    expect(rendered.contains_substring("\"detail\":\"function helper\""), rendered)
    expect(rendered.contains_substring("\"sortText\":\"1_helper\""), rendered)
    expect(rendered.contains_substring("\"sortText\":\"2_a\""), rendered)
    expect(rendered.contains_substring("\"sortText\":\"2_local_value\""), rendered)
    expect(rendered.contains_substring("\"sortText\":\"2_before_cursor\""), rendered)
    # Neither the global bucket nor out-of-snapshot bindings.
    expect(not rendered.contains_substring("keyword"), rendered)
    expect(not rendered.contains_substring("type constructor"), rendered)
    expect(not rendered.contains_substring("\"nested_value\""), rendered)
    expect(not rendered.contains_substring("\"_nested\""), rendered)
    expect(not rendered.contains_substring("\"here\""), rendered)
    text.release()
    heap.release(items)

    # A closed interpolation and a non-format line both decline the context.
    var closed = comp.format_string_completion_items(
        ref_of(analysis), ast_file, "    let v = f\"x #{LIMIT}\"", 11, "file:///probe.mt")
    expect(closed == null, "closed interpolation must fall through")
    var plain = comp.format_string_completion_items(
        ref_of(analysis), ast_file, "    let v = some_call(", 11, "file:///probe.mt")
    expect(plain == null, "plain call must fall through")


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


@[test]
function test_incomplete_dot_records_non_text_receiver_type() -> void:
    # A trailing dot is a parse error, but the analyzer keeps the receiver as
    # an empty-name member access and records its type at the dot.  Completion
    # falls back to that fact; the text path cannot see `make()`/`arr[0]`.
    var source = <<-SRC
        struct P:
            x: int
            y: int

        function make() -> P:
            return P(x = 1, y = 2)

        function demo() -> int:
            let q = make().
            let arr = array[P, 1](make())
            let s = arr[0].
            return 0
    SRC
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)
    expect_eq(int<-parse_diags.len(), 2)

    let make_fact = analyzer.member_receiver_type_at(ref_of(analysis), 9, 19)
    match make_fact:
        Option.some as ty:
            match ty.value:
                types.Type.ty_named as named:
                    expect_eq(named.name, "P")
                _:
                    expect(false, "make() receiver is not P")
        Option.none:
            expect(false, "make(). receiver type not recorded")

    let index_fact = analyzer.member_receiver_type_at(ref_of(analysis), 11, 19)
    match index_fact:
        Option.some as ty:
            match ty.value:
                types.Type.ty_named as named:
                    expect_eq(named.name, "P")
                    var items = comp.typed_receiver_completions(
                        ref_of(analysis), ast_file, ty.value, "", "file:///probe.mt")
                    defer: items.release()
                    let rendered = items.as_str()
                    expect(rendered.contains_substring("\"label\":\"x\""), rendered)
                    expect(rendered.contains_substring("\"label\":\"y\""), rendered)
                _:
                    expect(false, "arr[0] receiver is not P")
        Option.none:
            expect(false, "arr[0]. receiver type not recorded")
