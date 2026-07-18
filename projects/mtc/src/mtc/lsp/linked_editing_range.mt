## Linked editing range handler.  When the user renames a local binding,
## the editor highlights all occurrences of that binding so they can be
## edited simultaneously.  Uses the scope module to find scoped occurrences.

import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.scope as scope
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/linkedEditingRange.  Finds the binding at the
## cursor position and returns all occurrences that share the same scope.
public function handle_linked_editing_range(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    id: json.Value,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer content.release()

    let source = content.as_str()
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))

    let token_opt = cursor.identifier_at(source, line, character)
    match token_opt:
        Option.none:
            proto.write_response(id, json.null_value())
            return
        Option.some as token_payload:
            let name = token_payload.value.text
            var bindings = scope.collect_bindings(source, ast_file)
            defer bindings.release()

            var occurrences = cursor.identifier_occurrences(source, name)
            defer occurrences.release()

            # Find the target line (1-based from AST/cursor)
            let target_line = token_payload.value.line

            # Build the ranges array, filtering by scope.
            var ranges_json = string.String.create()
            defer ranges_json.release()
            ranges_json.append("[")
            var first = true
            var oi: ptr_uint = 0
            while oi < occurrences.len():
                let oc = occurrences.get(oi) else:
                    break
                let occ = unsafe: read(oc)
                if scope.is_in_same_scope(bindings, name, target_line, occ.line):
                    if not first:
                        ranges_json.append(",")
                    first = false
                    append_range_json(ref_of(ranges_json), occ.line, occ.column, occ.length)
                oi += 1

            ranges_json.append("]")

            var result_json = string.String.create()
            defer result_json.release()
            result_json.append("{\"ranges\":")
            result_json.append(ranges_json.as_str())
            result_json.append("}")

            proto.write_response_raw(id, result_json.as_str())


## Append a single range object `{"start":{"line":...,"character":...},"end":...}`.
function append_range_json(output: ref[string.String], line: ptr_uint, column: ptr_uint, length: ptr_uint) -> void:
    output.append("{\"start\":{\"line\":")
    output.append_format(f"#{line - 1}")
    output.append(",\"character\":")
    output.append_format(f"#{column - 1}")
    output.append("},\"end\":{\"line\":")
    output.append_format(f"#{line - 1}")
    output.append(",\"character\":")
    output.append_format(f"#{(column - 1) + length}")
    output.append("}}")
