## Linked editing range handler.  When the user renames a local binding,
## the editor highlights all occurrences of that binding so they can be
## edited simultaneously.  Uses the scope module to find scoped occurrences.

import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.scope as scope_mod
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/linkedEditingRange.  Finds the binding at the
## cursor position and returns all occurrences that share the same scope_mod.
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
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer: content.release()

    let source = content.as_str()
    let doc = workspace.document_analysis_for(ws, file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    var ast_file = doc.ast_file

    let token_opt = cursor.identifier_at(source, line, character)
    match token_opt:
        Option.none:
            proto.write_response(id, json.null_value())
            return
        Option.some as token_payload:
            let name = token_payload.value.text
            var bindings = scope_mod.collect_bindings(source, ast_file)
            defer: bindings.release()

            # Find the target line (1-based from AST/cursor)
            let target_line = token_payload.value.line

            # The host gates linked editing on a *local* binding: a token that
            # does not resolve to a parameter, local, `for` binding or match-arm
            # binding answers null, and so does an empty range set.
            match scope_mod.local_binding_line(bindings, name, target_line):
                Option.none:
                    proto.write_response(id, json.null_value())
                    return
                Option.some:
                    pass

            var occurrences = cursor.identifier_occurrences(source, name)
            defer: occurrences.release()

            # Build the ranges array, filtering by scope_mod.
            var ranges_json = string.String.create()
            defer: ranges_json.release()
            ranges_json.append("[")
            var first = true
            var oi: ptr_uint = 0
            while oi < occurrences.len():
                let oc = occurrences.get(oi) else:
                    break
                let occ = unsafe: read(oc)
                if scope_mod.is_in_same_scope(bindings, name, target_line, occ.line):
                    if not first:
                        ranges_json.append(",")
                    first = false
                    append_range_json(ref_of(ranges_json), occ.line, occ.column, occ.length)
                oi += 1

            if first:
                proto.write_response(id, json.null_value())
                return

            ranges_json.append("]")

            var result_json = string.String.create()
            defer: result_json.release()
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
