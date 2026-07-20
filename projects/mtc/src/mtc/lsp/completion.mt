## Completion — keyword, symbol, module-member, and method-receiver completion
## at cursor.
##
## Returns Milk Tea keywords plus function/type/value names from the semantic
## Analysis maps.  In a dot-member context after an import alias (`vec.|`),
## returns the public declarations of the imported module.  In a dot-member
## context after a typed value (`s.|`), returns the methods declared on the
## value's type.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.mem.heap as heap
import std.str
import std.string as string
import std.vec as vec
import std.log as log

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.loader.path_resolver as resolver
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.scope as scope
import mtc.lsp.uri as uri_ops
import mtc.lsp.utils as utils
import mtc.lsp.workspace as workspace
import mtc.lsp.workspace_index as workspace_index


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
    var prefix = utils.current_word_prefix(source, line, character)

    # Import context: filesystem-based module path completion before parsing.
    var import_items = import_completions(ws, source, line, character, prefix)
    if import_items != null:
        proto.write_response_raw(id, unsafe: read(import_items).as_str())
        unsafe: read(import_items).release()
        heap.release(import_items)
        return

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
                var items = module_member_completions(ws, ref_of(analysis), recv.value, prefix)
                defer items.release()
                proto.write_response_raw(id, items.as_str())
                return

            # Not an import alias — try method completions.
            var methods = type_method_completions(ref_of(analysis), recv.value, prefix)
            if methods != null:
                proto.write_response_raw(id, unsafe: read(methods).as_str())
                unsafe: read(methods).release()
                heap.release(methods)
                return

            # Try enum/variant member completions.
            var members = enum_member_completions(ref_of(analysis), recv.value, prefix)
            if members != null:
                proto.write_response_raw(id, unsafe: read(members).as_str())
                unsafe: read(members).release()
                heap.release(members)
                return
        Option.none:
            pass

    # Call context: suggest parameter names for the innermost call.
    match cursor.call_name_at(source, line, character):
        Option.some as callee:
            var named = named_argument_completions(ref_of(analysis), callee.value, prefix)
            if named != null:
                proto.write_response_raw(id, unsafe: read(named).as_str())
                unsafe: read(named).release()
                heap.release(named)
                return
        Option.none:
            pass

    # Scope/local context: local variables and parameters visible at cursor.
    var scope_items = scope_completions(source, line + 1, prefix)
    if scope_items != null:
        proto.write_response_raw(id, unsafe: read(scope_items).as_str())
        unsafe: read(scope_items).release()
        heap.release(scope_items)
        return

    var items_json = build_completions_json(ref_of(analysis), prefix)
    proto.write_response_raw(id, items_json.as_str())
    items_json.release()


## Handle completionItem/resolve.  When the editor resolves a completion
## item, look up the symbol name in the workspace index, find its
## declaration file, extract ## doc comments above it, and add
## `documentation` markdown to the item.
public function handle_completion_resolve(
    ws: ref[workspace.Workspace],
    params: json.Value,
    id: json.Value,
) -> void:
    let label = extract_string_field(params, "label")
    if label.len == 0:
        proto.write_response(id, params)
        return

    # Look up the label in the workspace symbol index.
    let ws_root = ws.root_path.as_str()
    ws.build_index_if_needed()
    var match_indices = workspace_index.query_index(ref_of(ws.index), label, 1)
    defer match_indices.release()
    if match_indices.len() == 0:
        proto.write_response(id, params)
        return

    let ei = match_indices.get(0) else:
        proto.write_response(id, params)
        return
    let entry = unsafe: workspace_index.read_entry(ref_of(ws.index), read(ei))
    let path = unsafe: read(entry).path.as_str()
    log.info(f"resolve: resolving label=#{label} in path=#{path}")

    # Read doc comments from the target file above the declaration.
    var doc_text = collect_doc_text(path, label)
    defer doc_text.release()
    if doc_text.len() == 0:
        proto.write_response(id, params)
        return

    # Build response JSON with documentation injected.
    var result_json = string.String.create()
    defer result_json.release()
    result_json.append("{\"label\":\"")
    proto.append_escaped(ref_of(result_json), label)
    result_json.append("\",\"documentation\":{\"kind\":\"markdown\",\"value\":\"")
    proto.append_escaped(ref_of(result_json), doc_text.as_str())
    result_json.append("\"}}")

    proto.write_response_raw(id, result_json.as_str())


## Extract a string field from a JSON Value.  Returns "" when absent.
function extract_string_field(value: json.Value, field: str) -> str:
    let obj_ptr = value.as_object()
    if obj_ptr == null:
        return ""
    unsafe:
        let field_ptr = read(obj_ptr).get(field)
        if field_ptr == null:
            return ""
        let field_str = read(field_ptr).as_string() else:
            return ""
        return field_str


## Collect ## documentation comment lines above a named declaration.
function collect_doc_text(path: str, name: str) -> string.String:
    var result = string.String.create()

    log.info(f"collect_doc_text: path=#{path} name=#{name}")
    match fs_mod.read_text(path):
        Result.success as payload:
            var source = payload.value
            defer source.release()

            # Find the declaration line — scan line by line, checking
            # whether each line starts with the target name followed by
            # a non-word character.  Byte-counter `li` stays at valid
            # UTF-8 boundaries (start of file, after each LF).
            var target_line: ptr_uint = 0
            var current_line: ptr_uint = 1
            var li: ptr_uint = 0
            while li < source.as_str().len:
                let remaining = source.as_str().slice(li, source.as_str().len - li)
                match remaining.find_byte(10):
                    Option.some as nl_pos:
                        let nl_end = nl_pos.value + li
                        if nl_end - li >= name.len:
                            let line_start_text = source.as_str().slice(li, name.len)
                            if line_start_text.equal(name):
                                let after = li + name.len
                                var is_decl = false
                                if after >= source.as_str().len:
                                    is_decl = true
                                else:
                                    let c = source.as_str().byte_at(after)
                                    is_decl = c == '(' or c == ':' or c == '<' or
                                        c == ' ' or c == '\n' or c == '{'
                                if is_decl:
                                    target_line = current_line
                        li = nl_end + 1
                        current_line += 1
                    Option.none:
                        if source.as_str().len - li >= name.len:
                            let last_line = source.as_str().slice(li, name.len)
                            if last_line.equal(name):
                                target_line = current_line
                        li = source.as_str().len

            if target_line == 0:
                return result

            # Walk backward from the target line, collecting ## lines.
            var doc_lines = vec.Vec[str].create()
            defer doc_lines.release()
            current_line = 1
            li = 0
            while li < source.as_str().len and current_line < target_line:
                let remaining = source.as_str().slice(li, source.as_str().len - li)
                match remaining.find_byte(10):
                    Option.some as nl_pos:
                        let nl_end = nl_pos.value + li
                        let line_text = source.as_str().slice(li, nl_end - li)
                        if line_text.len >= 2 and line_text.starts_with("##"):
                            var doc_content = line_text.slice(2, line_text.len - 2)
                            var trimmed = trim_left(doc_content)
                            doc_lines.push(trimmed)
                        else:
                            doc_lines.clear()
                        li = nl_end + 1
                    Option.none:
                        break
                current_line += 1

            var di: ptr_uint = 0
            while di < doc_lines.len():
                let dp = doc_lines.get(di) else:
                    break
                if di > 0:
                    result.append("\n")
                unsafe:
                    result.append(read(dp))
                di += 1

        Result.failure:
            pass

    return result


## Strip leading whitespace from the start of a string.
function trim_left(text: str) -> str:
    var start: ptr_uint = 0
    while start < text.len:
        let b = text.byte_at(start)
        if b != ' ':
            break
        start += 1
    if start >= text.len:
        return ""
    return text.slice(start, text.len - start)


## Completions for `import ` — walk the filesystem under module roots to
## find .mt files and sub-directories matching the typed path prefix.
## Returns a heap-allocated JSON completion result, or null when the cursor
## is not inside an import statement.
function import_completions(
    ws: ref[workspace.Workspace],
    source: str,
    line: ptr_uint,
    character: ptr_uint,
    prefix: str,
) -> ptr[string.String]?:
    let line_text = utils.source_line(source, line + 1)
    let trimmed = line_text.trim_ascii_whitespace()
    if not trimmed.starts_with("import "):
        return null

    let import_pos = line_text.find_substring("import ") else:
        return null
    let after_import = import_pos + 7

    if character < after_import:
        return null

    # Cursor must be before ` as ` if present.
    match line_text.slice(after_import, line_text.len - after_import).find_substring(" as "):
        Option.some as as_pos:
            if character >= after_import + as_pos.value:
                return null
        Option.none:
            pass

    # Split path typed so far by '.' into dir-segments + final filter segment.
    var path_typed = line_text.slice(after_import, character - after_import)
    var segments = vec.Vec[str].create()
    defer segments.release()
    var seg_start: ptr_uint = 0
    var si: ptr_uint = 0
    while si <= path_typed.len:
        if si == path_typed.len or path_typed.byte_at(si) == '.':
            segments.push(path_typed.slice(seg_start, si - seg_start))
            seg_start = si + 1
        si += 1

    var filter: str = ""
    if segments.len() > 0:
        let last_ptr = segments.get(segments.len() - 1) else:
            return null
        filter = unsafe: read(last_ptr)

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    var roots = ws.effective_module_roots_for("")
    defer roots.release()
    var ri: ptr_uint = 0
    while ri < roots.len():
        let rp = roots.get(ri) else:
            break
        let root = unsafe: read(rp)

        # Build search directory: root/seg0/seg1/.../ (all except filter segment)
        var search_dir = string.String.create()
        search_dir.append(root)
        var seg_i: ptr_uint = 0
        while seg_i + 1 < segments.len():
            let sp = segments.get(seg_i) else:
                break
            search_dir.push_byte(47)
            search_dir.append(unsafe: read(sp))
            seg_i += 1

        if not fs_mod.is_directory(search_dir.as_str()):
            search_dir.release()
            ri += 1
            continue

        match fs_mod.list_entries(search_dir.as_str()):
            Result.success as dir_entries:
                let entries_count = dir_entries.value.len()
                var ci: ptr_uint = 0
                while ci < entries_count and count < MAX_COMPLETION_ITEMS:
                    match dir_entries.value.get(ci):
                        Option.some as entry_payload:
                            let entry_name = entry_payload.value
                            if entry_name.starts_with("."):
                                ci += 1
                                continue
                            if not prefix_matches(entry_name, prefix) and not prefix_matches(entry_name, filter):
                                ci += 1
                                continue

                            var full_path = string.String.create()
                            defer full_path.release()
                            full_path.append(search_dir.as_str())
                            full_path.push_byte(47)
                            full_path.append(entry_name)

                            if fs_mod.is_directory(full_path.as_str()):
                                if dir_contains_mt(full_path.as_str()):
                                    append_item(ref_of(items_json), entry_name, KIND_MODULE, "module", entry_name, ref_of(first))
                                    count += 1
                            else if entry_name.ends_with(".mt"):
                                let mod_name = entry_name.slice(0, entry_name.len - 3)
                                if mod_name.len > 0 and (filter.len == 0 or mod_name.starts_with(filter)):
                                    append_item(ref_of(items_json), mod_name, KIND_MODULE, "module", mod_name, ref_of(first))
                                    count += 1
                        Option.none:
                            pass
                    ci += 1
            Result.failure as failure_payload:
                var err = failure_payload.error
                err.release()

        search_dir.release()
        ri += 1
    items_json.append("]")

    if count == 0:
        items_json.release()
        return null

    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc


## Completions for local variables and parameters visible at the cursor.
## Collects all scoped bindings via scope.collect_bindings and filters to
## those whose line range covers the cursor line and whose name matches the
## prefix.  Only activates when the user has typed at least one character.
function scope_completions(
    source: str,
    target_line: ptr_uint,
    prefix: str,
) -> ptr[string.String]?:
    if prefix.len == 0:
        return null

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var bindings = scope.collect_bindings(source, ast_file)
    defer bindings.release()

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    var bi: ptr_uint = 0
    while bi < bindings.len() and count < MAX_COMPLETION_ITEMS:
        let bp = bindings.get(bi) else:
            break
        let b = unsafe: read(bp)
        if b.name.len > 0 and b.name != "_" and not b.name.starts_with("_") and b.name.starts_with(prefix):
            if target_line >= b.line and target_line <= b.scope_end:
                append_item(ref_of(items_json), b.name, KIND_VARIABLE, b.name, b.name, ref_of(first))
                count += 1
        bi += 1

    items_json.append("]")

    if count == 0:
        items_json.release()
        return null

    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc


## True when `dir_path` is a directory and contains at least one `.mt` file.
function dir_contains_mt(dir_path: str) -> bool:
    match fs_mod.list_entries(dir_path):
        Result.success as dir_entries:
            let entries_count = dir_entries.value.len()
            var ci: ptr_uint = 0
            while ci < entries_count:
                match dir_entries.value.get(ci):
                    Option.some as entry_payload:
                        if entry_payload.value.ends_with(".mt"):
                            return true
                    Option.none:
                        pass
                ci += 1
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
    return false


## Completions for `alias.` — the public declarations of the module the
## import alias resolves to.  Returns "[]" when the receiver is not a known
## import alias or the module cannot be resolved.
function module_member_completions(
    ws: ref[workspace.Workspace],
    analysis: ref[analyzer.Analysis],
    alias_name: str,
    prefix: str,
) -> string.String:
    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    let module_ptr = unsafe: read(analysis).imports.get(alias_name)
    if module_ptr == null:
        items_json.append("]")
        return wrap_completion_result(ref_of(items_json), false)
    let module_name = unsafe: read(module_ptr)

    var roots = ws.effective_module_roots_for("")
    defer roots.release()
    match resolver.resolve_module_path(module_name, roots.as_span(), resolver.Platform.linux):
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            items_json.append("]")
            return wrap_completion_result(ref_of(items_json), false)
        Result.success as path_payload:
            var module_path = path_payload.value
            defer module_path.release()

            var module_source = ws.document_source(module_path.as_str()) else:
                items_json.append("]")
                return wrap_completion_result(ref_of(items_json), false)
            defer module_source.release()

            var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer parse_diags.release()
            var module_file = parser.parse_source(module_source.as_str(), ref_of(parse_diags))

            let exports_all = module_file.module_kind == ast.ModuleKind.module_raw
            var di: ptr_uint = 0
            while di < module_file.declarations.len and count < MAX_COMPLETION_ITEMS:
                var d: ast.Decl
                unsafe:
                    d = read(module_file.declarations.data + di)
                match d:
                    ast.Decl.decl_function as f:
                        if (exports_all or f.visibility) and prefix_matches(f.name, prefix):
                            append_item(ref_of(items_json), f.name, KIND_FUNCTION, f.name, f.name, ref_of(first))
                            count += 1
                    ast.Decl.decl_foreign_function as ff:
                        if (exports_all or ff.visibility) and prefix_matches(ff.name, prefix):
                            append_item(ref_of(items_json), ff.name, KIND_FUNCTION, ff.name, ff.name, ref_of(first))
                            count += 1
                    ast.Decl.decl_extern_function as ef:
                        if prefix_matches(ef.name, prefix):
                            append_item(ref_of(items_json), ef.name, KIND_FUNCTION, ef.name, ef.name, ref_of(first))
                            count += 1
                    ast.Decl.decl_struct as s:
                        if (exports_all or s.visibility) and prefix_matches(s.name, prefix):
                            append_item(ref_of(items_json), s.name, KIND_CLASS, "type", s.name, ref_of(first))
                            count += 1
                    ast.Decl.decl_union as u:
                        if (exports_all or u.visibility) and prefix_matches(u.name, prefix):
                            append_item(ref_of(items_json), u.name, KIND_CLASS, "type", u.name, ref_of(first))
                            count += 1
                    ast.Decl.decl_enum as e:
                        if (exports_all or e.visibility) and prefix_matches(e.name, prefix):
                            append_item(ref_of(items_json), e.name, KIND_ENUM, "enum", e.name, ref_of(first))
                            count += 1
                    ast.Decl.decl_flags as fl:
                        if (exports_all or fl.visibility) and prefix_matches(fl.name, prefix):
                            append_item(ref_of(items_json), fl.name, KIND_ENUM, "flags", fl.name, ref_of(first))
                            count += 1
                    ast.Decl.decl_variant as vr:
                        if (exports_all or vr.visibility) and prefix_matches(vr.name, prefix):
                            append_item(ref_of(items_json), vr.name, KIND_ENUM, "variant", vr.name, ref_of(first))
                            count += 1
                    ast.Decl.decl_interface as iface:
                        if (exports_all or iface.visibility) and prefix_matches(iface.name, prefix):
                            append_item(ref_of(items_json), iface.name, KIND_INTERFACE, "interface", iface.name, ref_of(first))
                            count += 1
                    ast.Decl.decl_type_alias as ta:
                        if (exports_all or ta.visibility) and prefix_matches(ta.name, prefix):
                            append_item(ref_of(items_json), ta.name, KIND_CLASS, "type", ta.name, ref_of(first))
                            count += 1
                    ast.Decl.decl_opaque as op:
                        if (exports_all or op.visibility) and prefix_matches(op.name, prefix):
                            append_item(ref_of(items_json), op.name, KIND_CLASS, "opaque", op.name, ref_of(first))
                            count += 1
                    ast.Decl.decl_const as c:
                        if (exports_all or c.visibility) and prefix_matches(c.name, prefix):
                            append_item(ref_of(items_json), c.name, KIND_CONSTANT, c.name, c.name, ref_of(first))
                            count += 1
                    ast.Decl.decl_var as v:
                        if (exports_all or v.visibility) and prefix_matches(v.name, prefix):
                            append_item(ref_of(items_json), v.name, KIND_VARIABLE, v.name, v.name, ref_of(first))
                            count += 1
                    _:
                        pass
                di += 1

            items_json.append("]")
            return wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)


## Build a JSON array of CompletionItem objects for the general (non-dot)
## context: keywords plus the current module's own symbols.
const MAX_COMPLETION_ITEMS: ptr_uint = 200


## Build a JSON array of completion items from the analysis data.
## Capped at MAX_COMPLETION_ITEMS; returns an empty array when nothing matches.
function build_completions_json(analysis: ref[analyzer.Analysis], prefix: str) -> string.String:
    var first = true
    var count: ptr_uint = 0
    var truncated = false

    var items_json = string.String.create()
    items_json.append("[")

    var keywords = collect_keywords()
    var ki: ptr_uint = 0
    while ki < keywords.len() and count < MAX_COMPLETION_ITEMS:
        let kw = keywords.get(ki) else:
            break
        let name = unsafe: read(kw)
        if prefix_matches(name, prefix):
            append_item(ref_of(items_json), name, KIND_KEYWORD, "keyword", name, ref_of(first))
            count += 1
        ki += 1
    keywords.release()

    unsafe:
        # Functions
        var fn_keys = read(analysis).functions.keys()
        while count < MAX_COMPLETION_ITEMS:
            let kp = fn_keys.next() else:
                break
            let name = read(kp)
            if prefix_matches(name, prefix):
                var detail = string.String.create()
                detail.append("function ")
                detail.append(name)
                let sig_ptr = read(analysis).functions.get(name)
                if sig_ptr != null:
                    let sig = read(sig_ptr)
                    detail.append("(")
                    var pi: ptr_uint = 0
                    while pi < sig.params.len:
                        let param = read(sig.params.data + pi)
                        if pi > 0:
                            detail.append(", ")
                        detail.append(param.name)
                        detail.append(": ")
                        detail.append(types.type_to_string(param.ty))
                        pi += 1
                    if sig.is_variadic:
                        if sig.params.len > 0:
                            detail.append(", ")
                        detail.append("...")
                    detail.append(")")
                    if sig.has_return_type:
                        detail.append(" -> ")
                        detail.append(types.type_to_string(sig.return_type))
                append_item(ref_of(items_json), name, KIND_FUNCTION, detail.as_str(), name, ref_of(first))
                detail.release()
                count += 1
                if count >= MAX_COMPLETION_ITEMS:
                    truncated = true

        # Structs
        var struct_keys = read(analysis).structs.keys()
        while count < MAX_COMPLETION_ITEMS:
            let kp = struct_keys.next() else:
                break
            let name = read(kp)
            if prefix_matches(name, prefix):
                append_item(ref_of(items_json), name, KIND_CLASS, "type", name, ref_of(first))
                count += 1
                if count >= MAX_COMPLETION_ITEMS:
                    truncated = true

        # Enums, flags, and variants
        var static_keys = read(analysis).static_member_types.keys()
        while count < MAX_COMPLETION_ITEMS:
            let kp = static_keys.next() else:
                break
            let name = read(kp)
            if prefix_matches(name, prefix):
                append_item(ref_of(items_json), name, KIND_ENUM, "type", name, ref_of(first))
                count += 1
                if count >= MAX_COMPLETION_ITEMS:
                    truncated = true

        # Interfaces
        var iface_keys = read(analysis).interfaces.keys()
        while count < MAX_COMPLETION_ITEMS:
            let kp = iface_keys.next() else:
                break
            let name = read(kp)
            if prefix_matches(name, prefix):
                append_item(ref_of(items_json), name, KIND_INTERFACE, "interface", name, ref_of(first))
                count += 1
                if count >= MAX_COMPLETION_ITEMS:
                    truncated = true

        # Module-level consts and vars
        var value_keys = read(analysis).value_types.keys()
        while count < MAX_COMPLETION_ITEMS:
            let kp = value_keys.next() else:
                break
            let name = read(kp)
            if prefix_matches(name, prefix):
                let tp = read(analysis).value_types.get(name)
                if tp == null:
                    append_item(ref_of(items_json), name, KIND_CONSTANT, name, name, ref_of(first))
                else:
                    var detail = string.String.create()
                    detail.append(name)
                    detail.append(": ")
                    detail.append(types.type_to_string(read(tp)))
                    append_item(ref_of(items_json), name, KIND_CONSTANT, detail.as_str(), name, ref_of(first))
                    detail.release()
                count += 1
                if count >= MAX_COMPLETION_ITEMS:
                    truncated = true

        # Import aliases
        var import_keys = read(analysis).imports.keys()
        while count < MAX_COMPLETION_ITEMS:
            let kp = import_keys.next() else:
                break
            let name = read(kp)
            if prefix_matches(name, prefix):
                var detail = string.String.create()
                detail.append("module ")
                let mod_ptr = read(analysis).imports.get(name)
                if mod_ptr != null:
                    detail.append(read(mod_ptr))
                append_item(ref_of(items_json), name, KIND_MODULE, detail.as_str(), name, ref_of(first))
                detail.release()
                count += 1
                if count >= MAX_COMPLETION_ITEMS:
                    truncated = true

    items_json.append("]")
    return wrap_completion_result(ref_of(items_json), truncated)


## True when `name` starts with `prefix`, or when prefix is empty.
function prefix_matches(name: str, prefix: str) -> bool:
    if prefix.len == 0:
        return true
    return name.starts_with(prefix)


## Append one CompletionItem with label, kind, detail, insertText, and sortText.
function append_item(json_out: ref[string.String], label: str, kind: int, detail: str, insert: str, first_var: ref[bool]) -> void:
    if label.len == 0:
        return
    if not unsafe: read(first_var):
        json_out.append(",")
    unsafe: read(first_var) = false
    json_out.append("{\"label\":\"")
    proto.append_escaped(json_out, label)
    json_out.append("\",\"kind\":")
    json_out.append_format(f"#{kind}")
    json_out.append(",\"detail\":\"")
    proto.append_escaped(json_out, detail)
    json_out.append("\",\"insertText\":\"")
    proto.append_escaped(json_out, insert)
    json_out.append("\",\"sortText\":\"")
    proto.append_escaped(json_out, label)
    json_out.append("\"}")



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


## Wrap a JSON items array in the LSP completion result object.
function wrap_completion_result(items_json: ref[string.String], truncated: bool) -> string.String:
    var result = string.String.create()
    result.append("{\"isIncomplete\":")
    if truncated:
        result.append("true")
    else:
        result.append("false")
    result.append(",\"items\":")
    result.append(items_json.as_str())
    result.append("}")
    items_json.release()
    return result


## Completions for `receiver.` when the receiver is a value or type name.
## Resolves the receiver name via analysis.types and analysis.type_names,
## then looks up methods declared for that type in analysis.method_keys.
## Returns a heap-allocated string.String on success, null otherwise.
function type_method_completions(
    analysis: ref[analyzer.Analysis],
    receiver_name: str,
    prefix: str,
) -> ptr[string.String]?:
    let type_name = resolve_receiver_type_name(analysis, receiver_name)
    if type_name.len == 0:
        return null

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    var prefix_buf = string.String.create()
    prefix_buf.append(type_name)
    prefix_buf.append(".")
    let type_prefix = prefix_buf.as_str()
    let type_prefix_len = type_prefix.len

    var method_entries = unsafe: read(analysis).method_keys.entries()
    while method_entries.next() and count < MAX_COMPLETION_ITEMS:
        let entry = method_entries.current()
        let whole_key = unsafe: read(entry.key)
        if whole_key.starts_with(type_prefix):
            let method_name = whole_key.slice(type_prefix_len, whole_key.len - type_prefix_len)
            if method_name.len > 0 and prefix_matches(method_name, prefix):
                append_item(ref_of(items_json), method_name, KIND_FUNCTION, method_name, method_name, ref_of(first))
                count += 1

    items_json.append("]")
    prefix_buf.release()

    if count == 0:
        items_json.release()
        return null

    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc



## Complete enum/variant member names after a dot receiver.
## When the cursor is after `EnumType.`, return the enum's member names.
function enum_member_completions(
    analysis: ref[analyzer.Analysis],
    name: str,
    prefix: str,
) -> ptr[string.String]?:
    let type_name = resolve_receiver_type_name(analysis, name)
    if type_name.len == 0:
        return null

    let members_ptr = unsafe: read(analysis).match_case_names.get(type_name)
    if members_ptr == null:
        return null

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0
    unsafe:
        let members = read(members_ptr)
        var mi: ptr_uint = 0
        while mi < members.len and count < MAX_COMPLETION_ITEMS:
            let mname = read(members.data + mi)
            if mname.len > 0 and prefix_matches(mname, prefix):
                append_item(ref_of(items_json), mname, KIND_ENUM, mname, mname, ref_of(first))
                count += 1
            mi += 1

    items_json.append("]")

    if count == 0:
        items_json.release()
        return null

    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
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


## Completions for `func(|)` or `func(pos = |)` inside a call's argument
## list.  Returns parameter names (as "name " label) for the callee, or
## null when the callee is not found or has no params.
function named_argument_completions(
    analysis: ref[analyzer.Analysis],
    callee_name: str,
    prefix: str,
) -> ptr[string.String]?:
    let sig_ptr = unsafe: read(analysis).functions.get(callee_name)
    if sig_ptr == null:
        return null

    let sig = unsafe: read(sig_ptr)
    if sig.params.len == 0:
        return null

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    var pi: ptr_uint = 0
    while pi < sig.params.len and count < MAX_COMPLETION_ITEMS:
        let param = unsafe: read(sig.params.data + pi)
        if param.name != "_" and prefix_matches(param.name, prefix):
            var detail = string.String.create()
            detail.append(param.name)
            detail.append(": ")
            detail.append(types.type_to_string(param.ty))
            append_item(ref_of(items_json), param.name, KIND_VARIABLE, detail.as_str(), param.name, ref_of(first))
            detail.release()
            count += 1
        pi += 1

    items_json.append("]")

    if count == 0:
        items_json.release()
        return null

    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc
