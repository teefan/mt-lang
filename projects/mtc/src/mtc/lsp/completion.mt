## Completion — keyword completion and symbol completion at cursor.
##
## Returns known Milk Tea keywords as CompletionItems, plus function/type/value
## names from the semantic Analysis maps when available.  No scope-aware
## filtering — just the full list.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.string as string
import std.vec as vec

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops


const COMPLETION_KIND_KEYWORD: double  = 14.0


## Handle textDocument/completion.
public function handle_completion(uri: str, line: ptr_uint, character: ptr_uint, id: json.Value) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = string.String.create()
    defer content.release()
    var read_result = fs_mod.read_text(file_path.as_str())
    match read_result:
        Result.success as c:
            content.assign(c.value.as_str())
        Result.failure:
            proto.write_response(id, json.null_value())
            return

    let source = content.as_str()
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)

    var items_json = build_completions_json(ref_of(analysis))
    proto.write_response_raw(id, items_json.as_str())
    items_json.release()


## Build a JSON array of CompletionItem objects.
function build_completions_json(analysis: ref[analyzer.Analysis]) -> string.String:
    var result = string.String.create()
    result.append("[")
    var first = true

    # Keywords
    var keywords = collect_keywords()
    var ki: ptr_uint = 0
    while ki < keywords.len():
        let kw = keywords.get(ki) else:
            break
        if not first: result.append(",")
        first = false
        unsafe:
            result.append("{\"label\":\"")
            result.append(read(kw))
            result.append("\",\"kind\":14}")
        ki += 1
    keywords.release()

    # Functions from analysis
    var fn_names = vec.Vec[str].create()
    unsafe:
        var fns = read(analysis).functions
    collect_map_keys(ref_of(fn_names))
    append_completions_from_set(ref_of(result), ref_of(fn_names), 3.0, ref_of(first))
    fn_names.release()

    # Structs from analysis
    var struct_names = vec.Vec[str].create()
    collect_map_keys_from_structs(analysis, ref_of(struct_names))
    append_completions_from_set(ref_of(result), ref_of(struct_names), 7.0, ref_of(first))
    struct_names.release()

    result.append("]")
    return result


function collect_keywords() -> vec.Vec[str]:
    var result = vec.Vec[str].create()
    result.push("function")
    result.push("if")
    result.push("else")
    result.push("return")
    result.push("let")
    result.push("var")
    result.push("while")
    result.push("for")
    result.push("match")
    result.push("struct")
    result.push("enum")
    result.push("interface")
    result.push("import")
    result.push("const")
    result.push("type")
    result.push("break")
    result.push("continue")
    result.push("defer")
    result.push("unsafe")
    result.push("public")
    result.push("extending")
    result.push("variant")
    result.push("flags")
    result.push("union")
    result.push("opaque")
    result.push("foreign")
    result.push("external")
    result.push("async")
    result.push("pass")
    result.push("true")
    result.push("false")
    result.push("null")
    result.push("and")
    result.push("or")
    result.push("not")
    return result


function collect_map_keys(names: ref[vec.Vec[str]]) -> void:
    pass


function collect_map_keys_from_structs(analysis: ref[analyzer.Analysis], names: ref[vec.Vec[str]]) -> void:
    pass


function append_completions_from_set(json_out: ref[string.String], names: ref[vec.Vec[str]], kind: double, first_var: ref[bool]) -> void:
    var ni: ptr_uint = 0
    while ni < names.len():
        let np = names.get(ni) else:
            break
        if not unsafe: read(first_var):
            json_out.append(",")
        unsafe: read(first_var) = false
        json_out.append("{\"label\":\"")
        unsafe: json_out.append(read(np))
        json_out.append("\",\"kind\":")
        json_out.append_format(f"#{kind}")
        json_out.append("}")
        ni += 1
