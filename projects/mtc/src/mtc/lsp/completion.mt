## Completion — keyword, symbol, module-member, and method-receiver completion
## at cursor.
##
## Returns Milk Tea keywords plus function/type/value names from the semantic
## Analysis maps.  In a dot-member context after an import alias (`vec.|`),
## returns the public declarations of the imported module.  In a dot-member
## context after a typed value (`s.|`), returns the methods declared on the
## value's type.

import std.fmt
import std.json as json
import std.mem.heap as heap
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.loader.path_resolver as resolver
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## LSP CompletionItemKind values.
const KIND_FUNCTION:  int = 3
const KIND_VARIABLE:  int = 6
const KIND_CLASS:     int = 7
const KIND_INTERFACE: int = 8
const KIND_MODULE:    int = 9
const KIND_ENUM:      int = 13
const KIND_KEYWORD:   int = 14
const KIND_CONSTANT:  int = 21


## Handle textDocument/completion.
public function handle_completion(
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
    var analysis = analyzer.check_source_file(ast_file)

    # Dot-member context after an import alias: complete the module's exports.
    match cursor.dot_receiver_at(source, line, character):
        Option.some as recv:
            # Import alias: complete the module's exports.
            let module_ptr = analysis.imports.get(recv.value)
            if module_ptr != null:
                var items = module_member_completions(ws, ref_of(analysis), recv.value)
                defer items.release()
                proto.write_response_raw(id, items.as_str())
                return

            # Not an import alias — try method completions.
            var methods = type_method_completions(ref_of(analysis), recv.value)
            if methods != null:
                proto.write_response_raw(id, unsafe: read(methods).as_str())
                unsafe: read(methods).release()
                heap.release(methods)
                return
        Option.none:
            pass

    # Call context: suggest parameter names for the innermost call.
    match cursor.call_name_at(source, line, character):
        Option.some as callee:
            var named = named_argument_completions(ref_of(analysis), callee.value)
            if named != null:
                proto.write_response_raw(id, unsafe: read(named).as_str())
                unsafe: read(named).release()
                heap.release(named)
                return
        Option.none:
            pass

    var items_json = build_completions_json(ref_of(analysis))
    proto.write_response_raw(id, items_json.as_str())
    items_json.release()


## Completions for `alias.` — the public declarations of the module the
## import alias resolves to.  Returns "[]" when the receiver is not a known
## import alias or the module cannot be resolved.
function module_member_completions(
    ws: ref[workspace.Workspace],
    analysis: ref[analyzer.Analysis],
    alias_name: str,
) -> string.String:
    var result = string.String.create()
    result.append("[")

    let module_ptr = unsafe: read(analysis).imports.get(alias_name)
    if module_ptr == null:
        result.append("]")
        return result
    let module_name = unsafe: read(module_ptr)

    var roots = ws.effective_module_roots_for("")
    defer roots.release()
    match resolver.resolve_module_path(module_name, roots.as_span(), resolver.Platform.linux):
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            result.append("]")
            return result
        Result.success as path_payload:
            var module_path = path_payload.value
            defer module_path.release()

            var module_source = ws.document_source(module_path.as_str()) else:
                result.append("]")
                return result
            defer module_source.release()

            var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer parse_diags.release()
            var module_file = parser.parse_source(module_source.as_str(), ref_of(parse_diags))

            let exports_all = module_file.module_kind == ast.ModuleKind.module_raw
            var first = true
            var di: ptr_uint = 0
            while di < module_file.declarations.len:
                var d: ast.Decl
                unsafe:
                    d = read(module_file.declarations.data + di)
                match d:
                    ast.Decl.decl_function as f:
                        if exports_all or f.visibility:
                            append_item(ref_of(result), f.name, KIND_FUNCTION, ref_of(first))
                    ast.Decl.decl_foreign_function as ff:
                        if exports_all or ff.visibility:
                            append_item(ref_of(result), ff.name, KIND_FUNCTION, ref_of(first))
                    ast.Decl.decl_extern_function as ef:
                        append_item(ref_of(result), ef.name, KIND_FUNCTION, ref_of(first))
                    ast.Decl.decl_struct as s:
                        if exports_all or s.visibility:
                            append_item(ref_of(result), s.name, KIND_CLASS, ref_of(first))
                    ast.Decl.decl_union as u:
                        if exports_all or u.visibility:
                            append_item(ref_of(result), u.name, KIND_CLASS, ref_of(first))
                    ast.Decl.decl_enum as e:
                        if exports_all or e.visibility:
                            append_item(ref_of(result), e.name, KIND_ENUM, ref_of(first))
                    ast.Decl.decl_flags as fl:
                        if exports_all or fl.visibility:
                            append_item(ref_of(result), fl.name, KIND_ENUM, ref_of(first))
                    ast.Decl.decl_variant as vr:
                        if exports_all or vr.visibility:
                            append_item(ref_of(result), vr.name, KIND_ENUM, ref_of(first))
                    ast.Decl.decl_interface as iface:
                        if exports_all or iface.visibility:
                            append_item(ref_of(result), iface.name, KIND_INTERFACE, ref_of(first))
                    ast.Decl.decl_type_alias as ta:
                        if exports_all or ta.visibility:
                            append_item(ref_of(result), ta.name, KIND_CLASS, ref_of(first))
                    ast.Decl.decl_opaque as op:
                        if exports_all or op.visibility:
                            append_item(ref_of(result), op.name, KIND_CLASS, ref_of(first))
                    ast.Decl.decl_const as c:
                        if exports_all or c.visibility:
                            append_item(ref_of(result), c.name, KIND_CONSTANT, ref_of(first))
                    ast.Decl.decl_var as v:
                        if exports_all or v.visibility:
                            append_item(ref_of(result), v.name, KIND_VARIABLE, ref_of(first))
                    _:
                        pass
                di += 1

            result.append("]")
            return result


## Build a JSON array of CompletionItem objects for the general (non-dot)
## context: keywords plus the current module's own symbols.
function build_completions_json(analysis: ref[analyzer.Analysis]) -> string.String:
    var result = string.String.create()
    result.append("[")
    var first = true

    var keywords = collect_keywords()
    var ki: ptr_uint = 0
    while ki < keywords.len():
        let kw = keywords.get(ki) else:
            break
        unsafe:
            append_item(ref_of(result), read(kw), KIND_KEYWORD, ref_of(first))
        ki += 1
    keywords.release()

    unsafe:
        # Functions
        var fn_keys = read(analysis).functions.keys()
        while true:
            let kp = fn_keys.next() else:
                break
            append_item(ref_of(result), read(kp), KIND_FUNCTION, ref_of(first))

        # Structs
        var struct_keys = read(analysis).structs.keys()
        while true:
            let kp = struct_keys.next() else:
                break
            append_item(ref_of(result), read(kp), KIND_CLASS, ref_of(first))

        # Enums, flags, and variants
        var static_keys = read(analysis).static_member_types.keys()
        while true:
            let kp = static_keys.next() else:
                break
            append_item(ref_of(result), read(kp), KIND_ENUM, ref_of(first))

        # Interfaces
        var iface_keys = read(analysis).interfaces.keys()
        while true:
            let kp = iface_keys.next() else:
                break
            append_item(ref_of(result), read(kp), KIND_INTERFACE, ref_of(first))

        # Module-level consts and vars
        var value_keys = read(analysis).value_types.keys()
        while true:
            let kp = value_keys.next() else:
                break
            append_item(ref_of(result), read(kp), KIND_CONSTANT, ref_of(first))

        # Import aliases
        var import_keys = read(analysis).imports.keys()
        while true:
            let kp = import_keys.next() else:
                break
            append_item(ref_of(result), read(kp), KIND_MODULE, ref_of(first))

    result.append("]")
    return result


## Append one CompletionItem `{"label":"<name>","kind":<kind>}`.
function append_item(json_out: ref[string.String], label: str, kind: int, first_var: ref[bool]) -> void:
    if label.len == 0:
        return
    if not unsafe: read(first_var):
        json_out.append(",")
    unsafe: read(first_var) = false
    json_out.append("{\"label\":\"")
    proto.append_escaped(json_out, label)
    json_out.append("\",\"kind\":")
    json_out.append_format(f"#{kind}")
    json_out.append("}")


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


## Completions for `receiver.` when the receiver is a value or type name.
## Resolves the receiver name via analysis.types and analysis.type_names,
## then looks up methods declared for that type in analysis.method_keys.
## Returns a heap-allocated string.String on success, null otherwise.
function type_method_completions(
    analysis: ref[analyzer.Analysis],
    receiver_name: str,
) -> ptr[string.String]?:
    let type_name = resolve_receiver_type_name(analysis, receiver_name)
    if type_name.len == 0:
        return null

    var result = string.String.create()
    result.append("[")

    var prefix_buf = string.String.create()
    prefix_buf.append(type_name)
    prefix_buf.append(".")
    let prefix = prefix_buf.as_str()
    let prefix_len = prefix.len
    var first = true

    var method_entries = unsafe: read(analysis).method_keys.entries()
    while method_entries.next():
        let entry = method_entries.current()
        let whole_key = unsafe: read(entry.key)
        if whole_key.starts_with(prefix):
            let method_name = whole_key.slice(prefix_len, whole_key.len - prefix_len)
            if method_name.len > 0:
                append_item(ref_of(result), method_name, method_kind_for(analysis, type_name, method_name), ref_of(first))
                first = false

    result.append("]")

    if first:
        result.release()
        return null

    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = result
    return alloc


## Resolve a receiver name to its Milk Tea type name (e.g. "v" → "Vec").
public function resolve_receiver_type_name(analysis: ref[analyzer.Analysis], name: str) -> str:
    unsafe:
        let a = read(analysis)

        let tp = a.types.get(name)
        if tp != null:
            let t = read(tp)
            return type_to_key_name(t)

        if a.type_names.contains(name):
            return name

        return ""


## Extract the key name from a Type (e.g. Vec[int] → "Vec").
function type_to_key_name(t: types.Type) -> str:
    match t:
        types.Type.ty_generic as g:
            return g.name
        types.Type.ty_named as n:
            return n.name
        types.Type.ty_imported as im:
            return im.name
        types.Type.ty_opaque as op:
            return op.name
        types.Type.ty_primitive as p:
            return p.name
        _:
            return ""


## LSP CompletionItemKind for a method on `type_name`.
function method_kind_for(analysis: ref[analyzer.Analysis], type_name: str, method_name: str) -> int:
    let key = analyzer.method_key(type_name, method_name)
    let sig_ptr = unsafe: read(analysis).method_sigs.get(key)
    if sig_ptr == null:
        return KIND_FUNCTION
    return KIND_FUNCTION


## Completions for `func(|)` or `func(pos = |)` inside a call's argument
## list.  Returns parameter names (as "name " label) for the callee, or
## null when the callee is not found or has no params.
function named_argument_completions(
    analysis: ref[analyzer.Analysis],
    callee_name: str,
) -> ptr[string.String]?:
    let sig_ptr = unsafe: read(analysis).functions.get(callee_name)
    if sig_ptr == null:
        return null

    let sig = unsafe: read(sig_ptr)
    if sig.params.len == 0:
        return null

    var result = string.String.create()
    result.append("[")

    var first = true
    var pi: ptr_uint = 0
    while pi < sig.params.len:
        let param = unsafe: read(sig.params.data + pi)
        if param.name != "_":
            append_item(ref_of(result), param.name, KIND_VARIABLE, ref_of(first))
            first = false
        pi += 1

    result.append("]")

    if first:
        result.release()
        return null

    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = result
    return alloc
