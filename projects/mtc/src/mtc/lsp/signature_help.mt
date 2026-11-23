## Signature help — parameter hints on '(' in function calls.
##
## When the cursor is inside a function call's parentheses, resolves the
## callee name token-accurately via lsp.cursor, looks up the FnSig in the
## semantic Analysis maps, and returns the parameter list as LSP
## SignatureHelp.

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/signatureHelp.
public function handle_signature_help(
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
    let call = cursor.call_context_at(source, line, character) else:
        proto.write_response(id, json.null_value())
        return
    let func_name = call.name

    let doc = workspace.document_analysis_for(ws, file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    var ast_file = doc.ast_file
    var analysis = doc.analysis

    var sig_opt: Option[analyzer.FnSig]
    unsafe:
        let sig_ptr = analysis.functions.get(func_name)
        if sig_ptr != null:
            sig_opt = Option[analyzer.FnSig].some(value = read(sig_ptr))

    # Method call on a receiver: try dot-receiver method resolution.
    if sig_opt.is_none():
        match cursor.dot_receiver_at(source, line, character):
            Option.some as recv:
                let qualified = analyzer.method_key(recv.value, func_name)
                unsafe:
                    let msig_ptr = analysis.method_sigs.get(qualified)
                    if msig_ptr != null:
                        sig_opt = Option[analyzer.FnSig].some(value = read(msig_ptr))
            Option.none:
                pass

    # Extending-block method: search method_keys for "*.name" suffix.
    if sig_opt.is_none():
        var mentries = analysis.method_keys.entries()
        var mnext = mentries.next()
        while mnext:
            let me = mentries.current()
            let mk = unsafe: read(me.key)
            if mk.ends_with(func_name) and mk.len > func_name.len:
                unsafe:
                    let msig_ptr = analysis.method_sigs.get(mk)
                    if msig_ptr != null:
                        sig_opt = Option[analyzer.FnSig].some(value = read(msig_ptr))
                        break
            mnext = mentries.next()

    match sig_opt:
        Option.some as sig_payload:
            var sig = sig_payload.value
            var json_text = build_signature_help_json(ref_of(sig), func_name, call.active_parameter)
            proto.write_response_raw(id, json_text.as_str())
            json_text.release()
        Option.none:
            proto.write_response(id, json.null_value())


## Build a SignatureHelp JSON string.
function build_signature_help_json(sig: ref[analyzer.FnSig], func_name: str, active_parameter: ptr_uint) -> string.String:
    var result = string.String.create()
    result.append("{\"signatures\":[{\"label\":\"")
    result.append(func_name)
    result.append("(")
    var first = true
    var pi: ptr_uint = 0
    unsafe:
        while pi < read(sig).params.len:
            let param = read(read(sig).params.data + pi)
            if not first:
                result.append(", ")
            first = false
            result.append(param.name)
            result.append(": ")
            var type_name = types.type_to_string(param.ty)
            result.append(type_name)
            pi += 1
    result.append(") -> ")
    var return_name = types.type_to_string(unsafe: read(sig).return_type)
    result.append(return_name)
    result.append("\",\"parameters\":[")
    pi = 0
    first = true
    unsafe:
        while pi < read(sig).params.len:
            let param = read(read(sig).params.data + pi)
            if not first:
                result.append(",")
            first = false
            result.append("{\"label\":\"")
            result.append(param.name)
            result.append(": ")
            var type_name = types.type_to_string(param.ty)
            result.append(type_name)
            result.append("\"}")
            pi += 1
    result.append("]}],\"activeSignature\":0,\"activeParameter\":")
    result.append_format(f"#{active_parameter}")
    result.append("}")
    return result
