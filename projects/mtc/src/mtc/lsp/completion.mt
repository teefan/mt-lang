## Completion — mirrors the host's `lib/milk_tea/lsp/server/completion.rb`:
## the import context, the dot-receiver chain (module members, type members,
## enum/variant members, value members, then the file's method list) and the
## global bucket list (functions, types, imports, values, locals, type
## constructors, keywords) with the host's kinds, `sortText` keys and `data`
## payloads.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.map as map_mod
import std.mem.heap as heap
import std.str
import std.string as string
import std.vec as vec
import std.log as log

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.pretty_printer.ast_formatter as ast_formatter
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.loader.path_resolver as resolver
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.type_render as type_render
import mtc.lsp.uri as uri_ops
import mtc.lsp.utils as utils
import mtc.lsp.workspace as workspace
import mtc.lsp.workspace_index as workspace_index


## LSP CompletionItemKind values, matching the host's numbering.
const KIND_MODULE:      int = 2
const KIND_MODULE_TYPE: int = 5
const KIND_METHOD:      int = 6
const KIND_CLASS:       int = 7
const KIND_FIELD:       int = 8
const KIND_FUNCTION:    int = 12
const KIND_VARIABLE:    int = 13
const KIND_ENUM:        int = 13
const KIND_KEYWORD:     int = 14
const KIND_ENUM_MEMBER: int = 22

const MAX_COMPLETION_ITEMS: ptr_uint = 200


## The host's `COMPLETION_KEYWORDS`, in its order.
const COMPLETION_KEYWORDS: array[str, 47] = array[str, 47](
    "let", "var", "const", "function", "async", "struct", "enum", "flags", "variant", "union",
    "type", "interface", "opaque", "if", "while", "for", "match", "return", "import", "public",
    "static", "extending", "external", "fn", "event", "attribute", "defer", "break", "continue", "pass",
    "unsafe", "consuming", "implements", "include", "link", "foreign", "proc", "editable", "in", "out",
    "inout", "as", "when", "inline", "await", "static_assert", "emit",
)


## The host's `TYPE_CONSTRUCTOR_KEYWORDS`, in its order.
const TYPE_CONSTRUCTOR_KEYWORDS: array[str, 12] = array[str, 12](
    "ptr", "ref", "span", "array", "dyn", "Option", "Result", "Task", "SoA", "str_buffer", "const_ptr", "simd",
)


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
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer: content.release()

    let source = content.as_str()
    var prefix = utils.current_word_prefix(source, line, character)

    # Import context: filesystem-based module path completion before parsing.
    var import_items = import_completions(ws, source, line, character, prefix, uri)
    if import_items != null:
        proto.write_response_raw(id, unsafe: read(import_items).as_str())
        unsafe: read(import_items).release()
        heap.release(import_items)
        return

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    # The loader-backed analysis binds the imported modules, so a value's
    # imported type resolves (`var n = node.Node.create(…)`); the single-file
    # analysis is the fallback when the document cannot be loaded.
    var maybe_analysis = workspace.analysis_for(ws, file_path.as_str())
    var analysis = if maybe_analysis.is_some(): maybe_analysis.unwrap() else: analyzer.check_source_file(ast_file)
    if maybe_analysis.is_some():
        ast_file = analysis.source_file

    # Dot-receiver context.  The host answers every dot receiver from the
    # receiver chain — and, failing that, from the file's method list — so the
    # keyword list is never a dot-receiver answer.
    var type_alias: str = ""
    match cursor.type_receiver_at(source, line, character):
        Option.some as trecv:
            type_alias = trecv.value.module_alias
        Option.none:
            pass
    match cursor.member_receiver_at(source, line, character):
        Option.some as recv:
            var dot_items = dot_receiver_completions(
                ws, ref_of(analysis), ast_file, file_path.as_str(), uri, recv.value, type_alias, prefix, line)
            proto.write_response_raw(id, dot_items.as_str())
            dot_items.release()
            return
        Option.none:
            pass

    # Call context: suggest parameter names for the innermost call.
    match cursor.call_name_at(source, line, character):
        Option.some as callee:
            var named = named_argument_completions(ref_of(analysis), callee.value, prefix, uri)
            if named != null:
                proto.write_response_raw(id, unsafe: read(named).as_str())
                unsafe: read(named).release()
                heap.release(named)
                return
        Option.none:
            pass

    var items_json = build_completions_json(
        ws, ref_of(analysis), ast_file, file_path.as_str(), uri, line, prefix)
    proto.write_response_raw(id, items_json.as_str())
    items_json.release()


## The host's dot-receiver chain.  A resolved import alias answers with module
## members; a type name with its members and methods; a value with fields then
## methods; anything else with the file's method list.
function dot_receiver_completions(
    ws: ref[workspace.Workspace],
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    file_path: str,
    uri: str,
    receiver: str,
    type_alias: str,
    prefix: str,
    line: ptr_uint,
) -> string.String:
    var current_module = module_name_for(ws, file_path)
    defer: current_module.release()
    let module_text = current_module.as_str()
    # 1. Import alias that resolves to a loadable module.
    if unsafe: read(analysis).imports.contains(receiver):
        var module_items = module_member_completions(ws, analysis, receiver, prefix, uri, module_text)
        if module_items != null:
            let result = unsafe: read(module_items)
            heap.release(module_items)
            return result
        # A failed import has no facts binding, so the host falls through.

    # 2. Type receiver: enum/variant members, then the type's methods.
    var type_items = type_receiver_completions(analysis, ast_file, receiver, type_alias, module_text, prefix, uri)
    if type_items != null:
        let result = unsafe: read(type_items)
        heap.release(type_items)
        return result

    # 3. Value receiver: fields then methods of the receiver's type.  An
    # imported type's members come from the analysis's `imported_type_members`
    # record, since the current module's tables do not carry them.
    match receiver_value_type(analysis, ast_file, receiver, line + 1):
        Option.some as ty:
            var imported_items = imported_value_receiver_completions(analysis, ast_file, ty.value, prefix, uri)
            if imported_items != null:
                let result = unsafe: read(imported_items)
                heap.release(imported_items)
                return result
            var value_items = value_receiver_completions(
                analysis, ast_file, ty.value, prefix, uri, module_text)
            if value_items != null:
                let result = unsafe: read(value_items)
                heap.release(value_items)
                return result
        Option.none:
            pass

    # 4. The file's method list.
    return method_fallback_completions(analysis, ast_file, prefix, uri)


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
    ws.build_index_if_needed()
    var match_indices = workspace_index.query_index(ref_of(ws.index), label, 1)
    defer: match_indices.release()
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
    defer: doc_text.release()
    if doc_text.len() == 0:
        proto.write_response(id, params)
        return

    # Build response JSON with documentation injected.
    var result_json = string.String.create()
    defer: result_json.release()
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
            defer: source.release()

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
            defer: doc_lines.release()
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
    uri: str,
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
    defer: segments.release()
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

    var seen = map_mod.Map[str, bool].create()
    defer: seen.release()

    var roots = ws.effective_module_roots_for("")
    defer: roots.release()
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
                while ci < entries_count:
                    match dir_entries.value.get(ci):
                        Option.some as entry_payload:
                            let entry_name = entry_payload.value
                            if entry_name.starts_with("."):
                                ci += 1
                                continue

                            # Filter by current word prefix (if non-empty) or by path segment
                            if prefix.len > 0:
                                if not entry_name.starts_with(prefix):
                                    ci += 1
                                    continue
                            else if filter.len > 0:
                                if not entry_name.starts_with(filter):
                                    ci += 1
                                    continue

                            var full_path = string.String.create()
                            defer: full_path.release()
                            full_path.append(search_dir.as_str())
                            full_path.push_byte(47)
                            full_path.append(entry_name)

                            if fs_mod.is_directory(full_path.as_str()):
                                if dir_contains_mt(full_path.as_str()):
                                    add_import_item(ref_of(items_json), entry_name, uri, ref_of(seen), ref_of(count), ref_of(first))
                            else if entry_name.ends_with(".mt"):
                                let mod_name = entry_name.slice(0, entry_name.len - 3)
                                if mod_name.len > 0:
                                    add_import_item(ref_of(items_json), mod_name, uri, ref_of(seen), ref_of(count), ref_of(first))
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
    # The host's import path is uncapped.
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), false)
    return alloc


## Add a deduplicated import completion item.
function add_import_item(
    json_out: ref[string.String],
    name: str,
    uri: str,
    seen: ref[map_mod.Map[str, bool]],
    count: ref[ptr_uint],
    first: ref[bool],
) -> void:
    if seen.contains(name):
        return
    seen.set(name, true)
    var detail = string.String.create()
    defer: detail.release()
    detail.append("module ")
    detail.append(name)
    append_plain_item(json_out, name, KIND_MODULE, detail.as_str(), name, uri, first)
    unsafe:
        read(count) = read(count) + 1


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


## Completions for `alias.` — the host's module-member shape: functions
## (kind 12, `0_`), values (kind 13, `1_`) and types (kind 5, `2_`).  Returns
## null when the alias's module cannot be resolved, so the caller falls
## through to the rest of the receiver chain.
function module_member_completions(
    ws: ref[workspace.Workspace],
    analysis: ref[analyzer.Analysis],
    alias_name: str,
    prefix: str,
    uri: str,
    current_module: str,
) -> ptr[string.String]?:
    let module_ptr = unsafe: read(analysis).imports.get(alias_name)
    if module_ptr == null:
        return null
    let module_name = unsafe: read(module_ptr)

    # The host renders member signatures from the import's *binding* (resolved
    # types, module-qualified); the same data is the loaded program's analysis
    # of the target module, cached on the current document's analysis entry.
    let target = target_module_analysis(ws, unsafe: read(analysis).source_path, module_name)

    var roots = ws.effective_module_roots_for("")
    defer: roots.release()
    match resolver.resolve_module_path(module_name, roots.as_span(), resolver.Platform.linux):
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            return null
        Result.success as path_payload:
            var module_path = path_payload.value
            defer: module_path.release()
            var module_source = ws.document_source(module_path.as_str()) else:
                return null
            defer: module_source.release()
            var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer: parse_diags.release()
            var module_file = parser.parse_source(module_source.as_str(), ref_of(parse_diags))
            var items_json = string.String.create()
            items_json.append("[")
            var first = true
            var count: ptr_uint = 0

            let exports_all = module_file.module_kind == ast.ModuleKind.module_raw
            # Three passes in the host's bucket order: functions, then values,
            # then types (each in declaration order).  Clients sort by sortText,
            # but the host's array order is what it advertises.
            emit_module_members(ref_of(items_json), module_file, module_name, prefix, uri, 0, exports_all, target, current_module, ref_of(first), ref_of(count))
            emit_module_members(ref_of(items_json), module_file, module_name, prefix, uri, 1, exports_all, target, current_module, ref_of(first), ref_of(count))
            emit_module_members(ref_of(items_json), module_file, module_name, prefix, uri, 2, exports_all, target, current_module, ref_of(first), ref_of(count))

            items_json.append("]")
            let alloc = heap.must_alloc[string.String](1)
            # The host's module path is uncapped (its 200-item cap applies to the
            # global and method-fallback paths only).
            unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), false)
            return alloc


## The loaded analysis of the module `module_name`, from the current document's
## program (the host's `facts.imports[alias]` binding data — resolved, fully
## qualified signatures).
function target_module_analysis(
    ws: ref[workspace.Workspace],
    current_path: str,
    module_name: str,
) -> Option[analyzer.Analysis]:
    let entry_ptr = workspace.analysis_entry_for(ws, current_path) else:
        return Option[analyzer.Analysis].none
    let program = unsafe: read(entry_ptr).program
    var i: ptr_uint = 0
    while i < program.analyses.len():
        let ap = program.analyses.get(i) else:
            break
        let a = unsafe: read(ap)
        if a.module_name.equal(module_name):
            return Option[analyzer.Analysis].some(value = a)
        i += 1
    return Option[analyzer.Analysis].none


## One pass over a module's declarations, emitting the members of one bucket.
## The host lists a module's members as functions, then values, then types (its
## fact buckets); clients sort by `sortText`, but its array order is the one the
## module advertises, so the three passes mirror it.
function emit_module_members(
    items_json: ref[string.String],
    module_file: ast.SourceFile,
    module_name: str,
    prefix: str,
    uri: str,
    bucket: ptr_uint,
    exports_all: bool,
    target: Option[analyzer.Analysis],
    current_module: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var di: ptr_uint = 0
    while di < module_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(module_file.declarations.data + di)
        match d:
            ast.Decl.decl_function as f:
                if bucket == 0 and (exports_all or f.visibility) and prefix_matches(f.name, prefix):
                    emit_module_function(
                        items_json, f.name, f.method_params, f.return_type,
                        module_name, uri, target, current_module, first, count)
            ast.Decl.decl_foreign_function as ff:
                # A raw/binding module (`std.stdio`) declares its API as foreign
                # functions; without this arm `io.` listed only its types.
                if bucket == 0 and (exports_all or ff.visibility) and prefix_matches(ff.name, prefix):
                    emit_module_foreign_function(
                        items_json, ff.name, ff.foreign_params, ff.return_type,
                        module_name, uri, target, current_module, first, count)
            ast.Decl.decl_const as c:
                if bucket == 1 and (exports_all or c.visibility) and prefix_matches(c.name, prefix):
                    emit_module_value(items_json, c.name, c.const_type, uri, target, current_module, first, count)
            ast.Decl.decl_var as v:
                if bucket == 1 and (exports_all or v.visibility) and prefix_matches(v.name, prefix):
                    emit_module_value(items_json, v.name, v.var_type, uri, target, current_module, first, count)
            ast.Decl.decl_struct as s:
                if bucket == 2 and (exports_all or s.visibility) and prefix_matches(s.name, prefix):
                    emit_module_type(items_json, s.name, uri, first, count)
            ast.Decl.decl_union as u:
                if bucket == 2 and (exports_all or u.visibility) and prefix_matches(u.name, prefix):
                    emit_module_type(items_json, u.name, uri, first, count)
            ast.Decl.decl_enum as e:
                if bucket == 2 and (exports_all or e.visibility) and prefix_matches(e.name, prefix):
                    emit_module_type(items_json, e.name, uri, first, count)
            ast.Decl.decl_flags as fl:
                if bucket == 2 and (exports_all or fl.visibility) and prefix_matches(fl.name, prefix):
                    emit_module_type(items_json, fl.name, uri, first, count)
            ast.Decl.decl_variant as vr:
                if bucket == 2 and (exports_all or vr.visibility) and prefix_matches(vr.name, prefix):
                    emit_module_type(items_json, vr.name, uri, first, count)
            ast.Decl.decl_type_alias as ta:
                if bucket == 2 and (exports_all or ta.visibility) and prefix_matches(ta.name, prefix):
                    emit_module_type(items_json, ta.name, uri, first, count)
            ast.Decl.decl_opaque as op:
                if bucket == 2 and (exports_all or op.visibility) and prefix_matches(op.name, prefix):
                    emit_module_type(items_json, op.name, uri, first, count)
            ast.Decl.decl_interface as iface:
                if bucket == 2 and (exports_all or iface.visibility) and prefix_matches(iface.name, prefix):
                    emit_module_type(items_json, iface.name, uri, first, count)
            _:
                pass
        di += 1


## Emit one exported module function in the host's shape.  The host renders the
## import binding's resolved signature (`function f(a: std.vec.Vec[T]) -> …`);
## the target module's loaded analysis carries the same FnSig, so prefer it and
## keep the AST rendering as the fallback for an unloaded module.
function emit_module_function(
    items_json: ref[string.String],
    name: str,
    params: span[ast.Param],
    return_type: ptr[ast.TypeRef]?,
    module_name: str,
    uri: str,
    target: Option[analyzer.Analysis],
    current_module: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    match target:
        Option.some as ta:
            let sig_ptr = ta.value.functions.get(name)
            if sig_ptr != null:
                emit_semantic_module_callable(
                    items_json, name, unsafe: read(sig_ptr), module_name, uri,
                    current_module, first, count)
                return
        Option.none:
            pass

    var params_text = string.String.create()
    defer: params_text.release()
    append_ast_params(ref_of(params_text), params)

    var snippet = string.String.create()
    defer: snippet.release()
    let has_snippet = append_ast_snippet(ref_of(snippet), name, params)
    let insert_text = if has_snippet: snippet.as_str() else: name

    var return_text = string.String.create()
    defer: return_text.release()
    append_ast_type(ref_of(return_text), return_type, "void")

    emit_module_callable_item(
        items_json, name, params_text.as_str(), return_text.as_str(), insert_text,
        if has_snippet: 2 else: 0,
        module_name, uri, first, count)


## A module callable item rendered from its resolved signature.
function emit_semantic_module_callable(
    items_json: ref[string.String],
    name: str,
    sig: analyzer.FnSig,
    module_name: str,
    uri: str,
    current_module: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var params_text = string.String.create()
    defer: params_text.release()
    append_semantic_params(ref_of(params_text), sig.params, current_module)

    var snippet = string.String.create()
    defer: snippet.release()
    let has_snippet = append_semantic_snippet(ref_of(snippet), name, sig.params)

    var returns_text = type_render.qualified_name(sig.return_type, current_module)
    defer: returns_text.release()

    emit_module_callable_item(
        items_json, name, params_text.as_str(), returns_text.as_str(),
        if has_snippet: snippet.as_str() else: name,
        if has_snippet: 2 else: 0,
        module_name, uri, first, count)


## The shared item for an exported module function — local or foreign: detail
## `function name(params) -> ret`, sort group `0_`, label details with the
## parameter list and the module as the description.  `insert_format` is 2 only
## when `insert_text` is a snippet (the host omits `insertTextFormat` otherwise).
function emit_module_callable_item(
    items_json: ref[string.String],
    name: str,
    params_text: str,
    return_text: str,
    insert_text: str,
    insert_format: int,
    module_name: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var detail = string.String.create()
    defer: detail.release()
    detail.append("function ")
    detail.append(name)
    detail.append("(")
    detail.append(params_text)
    detail.append(") -> ")
    detail.append(return_text)

    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append("0_")
    sort_text.append(name)
    var label_details = string.String.create()
    defer: label_details.release()
    if params_text.len > 0:
        label_details.append(" (")
        label_details.append(params_text)
        label_details.append(")")

    append_item_ext(
        items_json, name, KIND_FUNCTION, detail.as_str(), insert_text,
        sort_text.as_str(), name, uri, insert_format, label_details.as_str(), module_name, first)
    unsafe:
        read(count) = read(count) + 1


## A foreign function's completion item.  The resolved signature is preferred,
## as for a local function; the AST rendering (`path: str as cstr`) is the
## fallback for a module whose analysis is not loaded.
function emit_module_foreign_function(
    items_json: ref[string.String],
    name: str,
    foreign_params: span[ast.ForeignParam],
    return_type: ptr[ast.TypeRef],
    module_name: str,
    uri: str,
    target: Option[analyzer.Analysis],
    current_module: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    match target:
        Option.some as ta:
            let sig_ptr = ta.value.functions.get(name)
            if sig_ptr != null:
                emit_semantic_module_callable(
                    items_json, name, unsafe: read(sig_ptr), module_name, uri,
                    current_module, first, count)
                return
        Option.none:
            pass

    var params_text = string.String.create()
    defer: params_text.release()
    var snippet = string.String.create()
    defer: snippet.release()
    snippet.append(name)
    snippet.append("(")
    var pi: ptr_uint = 0
    while pi < foreign_params.len:
        let param = unsafe: read(foreign_params.data + pi)
        if pi > 0:
            params_text.append(", ")
            snippet.append(", ")
        params_text.append(param.name)
        params_text.append(": ")
        params_text.append(ast_formatter.render_type(param.param_type))
        snippet.append("${")
        snippet.append_format(f"#{pi + 1}:")
        snippet.append(param.name)
        snippet.append("}")
        pi += 1
    snippet.append(")")

    var return_text = string.String.create()
    defer: return_text.release()
    return_text.append(ast_formatter.render_type(unsafe: read(return_type)))

    emit_module_callable_item(
        items_json, name, params_text.as_str(), return_text.as_str(),
        snippet.as_str(), 2, module_name, uri, first, count)


function emit_module_value(
    items_json: ref[string.String],
    name: str,
    declared: ptr[ast.TypeRef]?,
    uri: str,
    target: Option[analyzer.Analysis],
    current_module: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var detail = string.String.create()
    defer: detail.release()
    detail.append(name)
    detail.append(": ")
    var rendered_semantic = false
    match target:
        Option.some as ta:
            let ty_ptr = ta.value.value_types.get(name)
            if ty_ptr != null:
                var rendered = type_render.qualified_name(unsafe: read(ty_ptr), current_module)
                defer: rendered.release()
                detail.append(rendered.as_str())
                rendered_semantic = true
        Option.none:
            pass
    if not rendered_semantic:
        append_ast_type(ref_of(detail), declared, "void")

    var value_sort = string.String.create()
    defer: value_sort.release()
    value_sort.append("1_")
    value_sort.append(name)
    append_item_ext(
        items_json, name, KIND_VARIABLE, detail.as_str(), name, value_sort.as_str(), name, uri,
        0, "", "", first)
    unsafe:
        read(count) = read(count) + 1


## Emit one exported module type in the host's shape.
function emit_module_type(
    items_json: ref[string.String],
    name: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var detail = string.String.create()
    defer: detail.release()
    detail.append("type ")
    detail.append(name)

    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append("2_")
    sort_text.append(name)
    append_item_ext(items_json, name, KIND_MODULE_TYPE, detail.as_str(), name, sort_text.as_str(), name, uri, 0, "", "", first)
    unsafe:
        read(count) = read(count) + 1


## One entry of the host's merged `methods_for_receiver_type` table: the method
## key as the analyzer registered it (`static:` prefixed for a static method),
## the module that declared it, and its resolved signature.
struct ReceiverMethod:
    key: str
    module_name: str
    sig: analyzer.FnSig


## The host's `methods_for_receiver_type`: the current module's methods for
## `type_name` in registration order, then every import's (in the file's import
## order), deduped by key (first wins).  The host renders these items with
## absolute type names, so callers render with an empty current module.
function merged_receiver_methods(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    type_name: str,
    sink: ref[vec.Vec[ReceiverMethod]],
    seen: ref[map_mod.Map[str, bool]],
) -> void:
    var prefix = string.String.create()
    defer: prefix.release()
    prefix.append(type_name)
    prefix.append(".")

    var entries = unsafe: read(analysis).method_sigs.entries()
    while entries.next():
        let entry = entries.current()
        let key = unsafe: read(entry.key)
        if key.starts_with(prefix.as_str()):
            let member = key.slice(prefix.len(), key.len - prefix.len())
            if not seen.contains(member):
                seen.set(member, true)
                sink.push(ReceiverMethod(
                    key = member, module_name = unsafe: read(analysis).module_name,
                    sig = unsafe: read(entry.value)))

    var ii: ptr_uint = 0
    while ii < ast_file.imports.len:
        var d: ast.Decl
        unsafe:
            d = read(ast_file.imports.data + ii)
        match d:
            ast.Decl.decl_import as imp:
                var alias = ""
                match imp.alias_name:
                    Option.some as a:
                        alias = a.value
                    Option.none:
                        # The implicit alias is the path's last segment.
                        if imp.path.parts.len > 0:
                            alias = unsafe: read(imp.path.parts.data + imp.path.parts.len - 1)
                if alias.len > 0:
                    let module_ptr = unsafe: read(analysis).imports.get(alias)
                    if module_ptr != null:
                        let module_name = unsafe: read(module_ptr)
                        var key = string.String.create()
                        defer: key.release()
                        key.append(module_name)
                        key.append(".")
                        key.append(type_name)
                        let member_ptr = unsafe: read(analysis).imported_type_members.get(key.as_str())
                        if member_ptr != null:
                            let methods = unsafe: read(member_ptr).methods
                            var me = methods.entries()
                            while me.next():
                                let e = me.current()
                                let member = unsafe: read(e.key)
                                if not seen.contains(member):
                                    seen.set(member, true)
                                    sink.push(ReceiverMethod(
                                        key = member, module_name = module_name,
                                        sig = unsafe: read(e.value)))
            _:
                pass
        ii += 1


## Emit one merged receiver method in the host's shape.  `static_only` is the
## type-receiver path, which emits static methods alone and strips the
## `static:` marker from the label; a value receiver keeps the registered key
## as its label (the host labels a value receiver's static methods
## `static:create`).
function emit_receiver_method(
    entry: ReceiverMethod,
    static_only: bool,
    prefix: str,
    sort_prefix: str,
    uri: str,
    items_json: ref[string.String],
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    let is_static = entry.sig.method_kind == ast.MethodKind.mk_static
    if static_only and not is_static:
        return
    var label = string.String.create()
    defer: label.release()
    # The self's method tables key methods by their bare name (`method_kind`
    # carries staticness); the host's labels, which these mirror, carry the
    # `static:` prefix on a value receiver and strip it on a type receiver.
    if is_static and not static_only:
        label.append("static:")
    label.append(entry.key)
    if not prefix_matches(label.as_str(), prefix):
        return

    var params_text = imported_params_text(entry.sig.params, "")
    defer: params_text.release()
    var detail = string.String.create()
    defer: detail.release()
    detail.append(label.as_str())
    detail.append("(")
    detail.append(params_text.as_str())
    detail.append(") -> ")
    var rendered_return = type_render.qualified_name(entry.sig.return_type, "")
    defer: rendered_return.release()
    detail.append(rendered_return.as_str())

    var insert = string.String.create()
    var insert_format: int = 0
    if entry.sig.params.len <= 5:
        append_param_snippet(ref_of(insert), label.as_str(), entry.sig.params)
        insert_format = 2
    else:
        insert.append(label.as_str())
    defer: insert.release()

    var label_details = string.String.create()
    defer: label_details.release()
    if params_text.len() > 0:
        label_details.append(" (")
        label_details.append(params_text.as_str())
        label_details.append(")")

    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append(sort_prefix)
    sort_text.append(label.as_str())

    append_item_ext(
        items_json, label.as_str(), KIND_METHOD, detail.as_str(), insert.as_str(),
        sort_text.as_str(), label.as_str(), uri, insert_format, label_details.as_str(), "", first)
    unsafe:
        read(count) = read(count) + 1


## Completions for a type-name receiver: enum/variant members (kind 22) first,
## then the type's methods (kind 6).  Returns null when the receiver is not a
## known type name.
function type_receiver_completions(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    receiver: str,
    alias_name: str,
    module_name: str,
    prefix: str,
    uri: str,
) -> ptr[string.String]?:
    var type_name = resolve_receiver_type_name(analysis, receiver)
    if type_name.len == 0 and alias_name.len > 0:
        # `alias.Type`: the receiver segment names the type; it is known when the
        # alias's module carries it (the host's `resolve_type_receiver_info`
        # falls through to the module binding's type table).
        type_name = receiver
    if type_name.len == 0:
        return null
    if not type_receiver_known(analysis, type_name, alias_name):
        return null

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    # Enum/flags/variant members.
    let members_ptr = unsafe: read(analysis).match_case_names.get(type_name)
    if members_ptr != null:
        unsafe:
            let members = read(members_ptr)
            var mi: ptr_uint = 0
            while mi < members.len and count < MAX_COMPLETION_ITEMS:
                let mname = read(members.data + mi)
                if mname.len > 0 and prefix_matches(mname, prefix):
                    var detail = string.String.create()
                    detail.append(type_name)
                    detail.append(".")
                    detail.append(mname)
                    var member_sort = string.String.create()
                    member_sort.append("0_")
                    member_sort.append(mname)
                    append_item_ext(
                        ref_of(items_json), mname, KIND_ENUM_MEMBER, detail.as_str(), mname,
                        member_sort.as_str(), mname, uri, 0, "", "", ref_of(first))
                    detail.release()
                    member_sort.release()
                    count += 1
                mi += 1

    # Methods declared on the type — merged across the current module and every
    # import, static only, with the `static:` marker stripped (the host's
    # `completion_items_for_type_receiver`).
    var methods = vec.Vec[ReceiverMethod].create()
    defer: methods.release()
    var method_seen = map_mod.Map[str, bool].create()
    defer: method_seen.release()
    merged_receiver_methods(analysis, ast_file, type_name, ref_of(methods), ref_of(method_seen))
    var mi2: ptr_uint = 0
    while mi2 < methods.len() and count < MAX_COMPLETION_ITEMS:
        let mp = methods.get(mi2) else:
            break
        unsafe:
            emit_receiver_method(read(mp), true, prefix, "0_", uri, ref_of(items_json), ref_of(first), ref_of(count))
        mi2 += 1

    items_json.append("]")
    if count == 0:
        items_json.release()
        return null

    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc


## Completions for a value receiver: the type's fields (kind 8, `0_`) then its
## methods (kind 6, `1_`).  Returns null when the type has neither.
function value_receiver_completions(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    receiver_ty: types.Type,
    prefix: str,
    uri: str,
    current_module: str,
) -> ptr[string.String]?:
    let type_name = type_to_key_name(receiver_ty)
    if type_name.len == 0:
        return null

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    let fields_ptr = unsafe: read(analysis).structs.get(type_name)
    if fields_ptr != null:
        let fields = unsafe: read(fields_ptr)
        var fi: ptr_uint = 0
        while fi < fields.len and count < MAX_COMPLETION_ITEMS:
            let field = unsafe: read(fields.data + fi)
            if prefix_matches(field.name, prefix):
                var detail = string.String.create()
                detail.append(field.name)
                detail.append(": ")
                detail.append(field_type_text(ast_file, type_name, field.name))
                var sort_text = string.String.create()
                sort_text.append("0_")
                sort_text.append(field.name)
                append_item_ext(
                    ref_of(items_json), field.name, KIND_FIELD, detail.as_str(), field.name,
                    sort_text.as_str(), field.name, uri, 0, "", "", ref_of(first))
                sort_text.release()
                detail.release()
                count += 1
            fi += 1

    var methods = vec.Vec[ReceiverMethod].create()
    defer: methods.release()
    var method_seen = map_mod.Map[str, bool].create()
    defer: method_seen.release()
    merged_receiver_methods(analysis, ast_file, type_name, ref_of(methods), ref_of(method_seen))
    var mi: ptr_uint = 0
    while mi < methods.len() and count < MAX_COMPLETION_ITEMS:
        let mp = methods.get(mi) else:
            break
        unsafe:
            emit_receiver_method(read(mp), false, prefix, "1_", uri, ref_of(items_json), ref_of(first), ref_of(count))
        mi += 1

    items_json.append("]")
    if count == 0:
        items_json.release()
        return null

    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc


## The `(module, type)` an imported type reference names.  The analyzer produces
## two shapes for one: `ty_imported` for a specialized or imported nominal
## (`node.Node`, `Vec[int]`) and a `ty_named` whose `module_name` is set for a
## plain imported name.
public struct ImportedTypeRef:
    module_name: str
    name: str


function imported_type_reference(ty: types.Type) -> Option[ImportedTypeRef]:
    match ty:
        types.Type.ty_imported as im:
            if im.module_name.len > 0:
                return Option[ImportedTypeRef].some(value = ImportedTypeRef(module_name = im.module_name, name = im.name))
            return Option[ImportedTypeRef].none
        types.Type.ty_named as n:
            if n.module_name.len > 0:
                return Option[ImportedTypeRef].some(value = ImportedTypeRef(module_name = n.module_name, name = n.name))
            return Option[ImportedTypeRef].none
        _:
            return Option[ImportedTypeRef].none


## An *imported* type's members for a value receiver (`var n = node.Node.create(…)`
## then `n.`): the analysis's `imported_type_members` record carries the declaring
## module's fields and method signatures, and the host renders both with that
## module's qualification (`parent: ptr[node.Node]?`).  None when the receiver is
## not an imported type or the record has no entry for it, so the caller keeps its
## local-type path and the method fallback.
function imported_value_receiver_completions(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    receiver_ty: types.Type,
    prefix: str,
    uri: str,
) -> ptr[string.String]?:
    let reference = imported_type_reference(receiver_ty) else:
        return null
    let module_name = reference.module_name
    let im_name = reference.name
    var key = string.String.create()
    key.append(module_name)
    key.append(".")
    key.append(im_name)
    defer: key.release()
    let member_ptr = unsafe: read(analysis).imported_type_members.get(key.as_str()) else:
        return null
    let members = unsafe: read(member_ptr)

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    var fi: ptr_uint = 0
    while fi < members.fields.len and count < MAX_COMPLETION_ITEMS:
        let field = unsafe: read(members.fields.data + fi)
        if prefix_matches(field.name, prefix):
            var detail = string.String.create()
            detail.append(field.name)
            detail.append(": ")
            var rendered = type_render.qualified_name(field.ty, module_name)
            detail.append(rendered.as_str())
            rendered.release()
            var sort_text = string.String.create()
            sort_text.append("0_")
            sort_text.append(field.name)
            append_item_ext(
                ref_of(items_json), field.name, KIND_FIELD, detail.as_str(), field.name,
                sort_text.as_str(), field.name, uri, 0, "", "", ref_of(first))
            sort_text.release()
            detail.release()
            count += 1
        fi += 1

    var methods = vec.Vec[ReceiverMethod].create()
    defer: methods.release()
    var method_seen = map_mod.Map[str, bool].create()
    defer: method_seen.release()
    merged_receiver_methods(analysis, ast_file, im_name, ref_of(methods), ref_of(method_seen))
    var mi: ptr_uint = 0
    while mi < methods.len() and count < MAX_COMPLETION_ITEMS:
        let mp = methods.get(mi) else:
            break
        unsafe:
            emit_receiver_method(read(mp), false, prefix, "1_", uri, ref_of(items_json), ref_of(first), ref_of(count))
        mi += 1

    items_json.append("]")
    if count == 0:
        items_json.release()
        return null
    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc


## `name: type, …` for a resolved signature's parameters — the host's
## `format_params`, each type rendered with the declaring module's qualification.
function imported_params_text(params: span[analyzer.ParamEntry], module_name: str) -> string.String:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < params.len:
        if i > 0:
            buf.append(", ")
        let pa = unsafe: read(params.data + i)
        buf.append(pa.name)
        buf.append(": ")
        var rendered = type_render.qualified_name(pa.ty, module_name)
        buf.append(rendered.as_str())
        rendered.release()
        i += 1
    return buf


## The host's `snippet_for_callable`: one placeholder per parameter
## (`create(${1:name})`), the bare call when there are none.
function append_param_snippet(target: ref[string.String], label: str, params: span[analyzer.ParamEntry]) -> void:
    target.append(label)
    target.append("(")
    var i: ptr_uint = 0
    while i < params.len:
        if i > 0:
            target.append(", ")
        target.append("${")
        target.append_format(f"#{i + 1}")
        target.append(":")
        target.append(unsafe: read(params.data + i).name)
        target.append("}")
        i += 1
    target.append(")")


## Render a struct/union field's declared type from the AST.  The semantic
## `FieldEntry.ty` names are resolution-time views, so the AST TypeRef is the
## safe source (the host reads its own binding's type here).
function field_type_text(ast_file: ast.SourceFile, type_name: str, field_name: str) -> str:
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_struct as s:
                if s.name.equal(type_name):
                    var fi: ptr_uint = 0
                    while fi < s.struct_fields.len:
                        let f = unsafe: read(s.struct_fields.data + fi)
                        if f.name.equal(field_name):
                            return ast_formatter.render_type(f.field_type)
                        fi += 1
            ast.Decl.decl_union as u:
                if u.name.equal(type_name):
                    var ui: ptr_uint = 0
                    while ui < u.union_fields.len:
                        let f = unsafe: read(u.union_fields.data + ui)
                        if f.name.equal(field_name):
                            return ast_formatter.render_type(f.field_type)
                        ui += 1
            _:
                pass
        di += 1
    return ""


## The file's method list — the host's `method-fallback` answer for a receiver
## it cannot resolve.  The host iterates its method table by receiver type in
## first-registration order, which is this file's declaration order (inline
## methods are desugared into `extending` blocks by the parser); each method
## carries the resolved signature and the `static:` label a value receiver gets.
function method_fallback_completions(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    prefix: str,
    uri: str,
) -> string.String:
    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    var di: ptr_uint = 0
    while di < ast_file.declarations.len and count < MAX_COMPLETION_ITEMS:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_extending_block as ext:
                let type_name = extending_base_name(ext.type_name)
                if type_name.len > 0:
                    var key_prefix = string.String.create()
                    defer: key_prefix.release()
                    key_prefix.append(type_name)
                    key_prefix.append(".")
                    var mi: ptr_uint = 0
                    while mi < ext.methods.len and count < MAX_COMPLETION_ITEMS:
                        let mfn = unsafe: read(ext.methods.data + mi)
                        var key = string.String.create()
                        defer: key.release()
                        key.append(key_prefix.as_str())
                        key.append(mfn.name)
                        let sig_ptr = unsafe: read(analysis).method_sigs.get(key.as_str())
                        if sig_ptr != null:
                            emit_receiver_method(
                                ReceiverMethod(key = mfn.name, module_name = "", sig = unsafe: read(sig_ptr)),
                                false, prefix, "0_", uri, ref_of(items_json), ref_of(first), ref_of(count))
                        mi += 1
            _:
                pass
        di += 1

    items_json.append("]")
    return wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)


## The base type name an `extending` block targets (`extending a.B:` → `B`).
function extending_base_name(type_name: ptr[ast.TypeRef]?) -> str:
    let tp = type_name else:
        return ""
    let t = unsafe: read(tp)
    if t.name.parts.len == 0:
        return ""
    return unsafe: read(t.name.parts.data + t.name.parts.len - 1)


## Resolve a receiver name to the value's type: the innermost local or
## parameter of that name visible at `cursor_line`, else a module-level value.
function receiver_value_type(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    name: str,
    cursor_line: ptr_uint,
) -> Option[types.Type]:
    # Locals and parameters of the enclosing function.
    var best_line: ptr_uint = 0
    var body: ptr[ast.Stmt]? = null
    var params: span[ast.Param] = span[ast.Param]()
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                if fun.line <= cursor_line and fun.line >= best_line:
                    best_line = fun.line
                    body = fun.body
                    params = fun.method_params
            _:
                pass
        di += 1

    var pi: ptr_uint = 0
    while pi < params.len:
        let p = unsafe: read(params.data + pi)
        if p.name.equal(name):
            # `Param.param_type` is a value, so resolve the TypeRef by name.
            if p.param_type.name.parts.len == 0:
                return Option[types.Type].none
            let type_name = unsafe: read(p.param_type.name.parts.data + p.param_type.name.parts.len - 1)
            return type_by_name(analysis, type_name)
        pi += 1

    if body != null:
        match find_local_type(analysis, unsafe: read(ptr[ast.Stmt]<-body), name, cursor_line):
            Option.some as ty:
                return Option[types.Type].some(value = ty.value)
            Option.none:
                pass

    # Module-level values.
    di = 0
    while di < ast_file.declarations.len:
        var decl2: ast.Decl
        unsafe:
            decl2 = read(ast_file.declarations.data + di)
        match decl2:
            ast.Decl.decl_const as c:
                if c.name.equal(name):
                    return type_ref_to_type(analysis, c.const_type)
            ast.Decl.decl_var as v:
                if v.name.equal(name):
                    return type_ref_to_type(analysis, v.var_type)
            _:
                pass
        di += 1

    return Option[types.Type].none


## The type of the local `name` declared in `stmt` at or before
## `cursor_line`, preferring the analyzer's inferred initializer type.
function find_local_type(
    analysis: ref[analyzer.Analysis],
    stmt: ast.Stmt,
    name: str,
    cursor_line: ptr_uint,
) -> Option[types.Type]:
    match stmt:
        ast.Stmt.stmt_local as loc:
            if loc.name.equal(name) and loc.line <= cursor_line:
                match type_render.initializer_type(analysis, loc.value):
                    Option.some as ty:
                        return Option[types.Type].some(value = ty.value)
                    Option.none:
                        return type_ref_to_type(analysis, loc.stmt_type)
        ast.Stmt.stmt_block as blk:
            var si: ptr_uint = 0
            while si < blk.statements.len:
                match find_local_type(analysis, unsafe: read(blk.statements.data + si), name, cursor_line):
                    Option.some as ty:
                        return Option[types.Type].some(value = ty.value)
                    Option.none:
                        pass
                si += 1
        ast.Stmt.stmt_if as iff:
            var ib: ptr_uint = 0
            while ib < iff.branches.len:
                let branch = unsafe: read(iff.branches.data + ib)
                match find_local_type(analysis, unsafe: read(branch.body), name, cursor_line):
                    Option.some as ty:
                        return Option[types.Type].some(value = ty.value)
                    Option.none:
                        pass
                ib += 1
            if iff.else_body != null:
                return find_local_type(analysis, unsafe: read(ptr[ast.Stmt]<-iff.else_body), name, cursor_line)
        ast.Stmt.stmt_while as w:
            if w.body != null:
                return find_local_type(analysis, unsafe: read(ptr[ast.Stmt]<-w.body), name, cursor_line)
        ast.Stmt.stmt_for as f:
            if f.body != null:
                return find_local_type(analysis, unsafe: read(ptr[ast.Stmt]<-f.body), name, cursor_line)
        ast.Stmt.stmt_match as m:
            var ai: ptr_uint = 0
            while ai < m.arms.len:
                let arm = unsafe: read(m.arms.data + ai)
                if arm.body != null:
                    match find_local_type(analysis, unsafe: read(ptr[ast.Stmt]<-arm.body), name, cursor_line):
                        Option.some as ty:
                            return Option[types.Type].some(value = ty.value)
                        Option.none:
                            pass
                ai += 1
        _:
            pass
    return Option[types.Type].none


## Resolve a declared `TypeRef` to a `types.Type` through the analyzer's type
## table (`int` → primitive, `Sample` → the local struct).
function type_ref_to_type(analysis: ref[analyzer.Analysis], type_ref: ptr[ast.TypeRef]?) -> Option[types.Type]:
    let tp = type_ref else:
        return Option[types.Type].none
    let t = unsafe: read(tp)
    if t.name.parts.len == 0:
        return Option[types.Type].none
    return type_by_name(analysis, unsafe: read(t.name.parts.data + t.name.parts.len - 1))


## The analyzer's `types.Type` for a declared type name.
function type_by_name(analysis: ref[analyzer.Analysis], type_name: str) -> Option[types.Type]:
    let ty_ptr = unsafe: read(analysis).types.get(type_name)
    if ty_ptr == null:
        return Option[types.Type].none
    return Option[types.Type].some(value = unsafe: read(ty_ptr))


## The host's global bucket list: functions, types, imports, values, locals,
## type constructors, keywords — each with its `sortText` bucket and `data`.
function build_completions_json(
    ws: ref[workspace.Workspace],
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    file_path: str,
    uri: str,
    line: ptr_uint,
    prefix: str,
) -> string.String:
    var current_module = module_name_for(ws, file_path)
    defer: current_module.release()
    let module_text = current_module.as_str()

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    # Functions, in declaration order.
    var di: ptr_uint = 0
    while di < ast_file.declarations.len and count < MAX_COMPLETION_ITEMS:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                if prefix_matches(fun.name, prefix):
                    emit_function_item(
                        ref_of(items_json), analysis, fun.name, fun.method_params, fun.return_type,
                        module_text, uri, ref_of(first), ref_of(count))
            _:
                pass
        di += 1

    # Types: the prelude's and the resolved imports' first, then the file's.
    emit_import_type_items(
        ws, ref_of(items_json), analysis, uri, prefix, ref_of(first), ref_of(count))
    di = 0
    while di < ast_file.declarations.len and count < MAX_COMPLETION_ITEMS:
        var decl2: ast.Decl
        unsafe:
            decl2 = read(ast_file.declarations.data + di)
        emit_declared_type_item(ref_of(items_json), decl2, uri, prefix, ref_of(first), ref_of(count))
        di += 1

    # Imports (resolved only), the prelude pair first.  The file's own roots are
    # what resolve a project-local import (`import node` under `src/` with the
    # package's `source_root`), so the bucket must not use the bare workspace
    # root — without it `n`/`no`/`node` offered the local only and never the
    # module alias.
    emit_import_items(
        ws, analysis, ast_file, file_path, ref_of(items_json), uri, prefix, ref_of(first), ref_of(count))

    # Module-level values.
    di = 0
    while di < ast_file.declarations.len and count < MAX_COMPLETION_ITEMS:
        var decl3: ast.Decl
        unsafe:
            decl3 = read(ast_file.declarations.data + di)
        match decl3:
            ast.Decl.decl_const as c:
                if prefix_matches(c.name, prefix):
                    emit_value_item(
                        ref_of(items_json), analysis, c.name, c.const_type,
                        module_text, uri, ref_of(first), ref_of(count))
            ast.Decl.decl_var as v:
                if prefix_matches(v.name, prefix):
                    emit_value_item(
                        ref_of(items_json), analysis, v.name, v.var_type,
                        module_text, uri, ref_of(first), ref_of(count))
            _:
                pass
        di += 1

    # Locals visible at the cursor.
    emit_local_binding_items(
        analysis, ast_file, line + 1, prefix, uri, module_text,
        ref_of(items_json), ref_of(first), ref_of(count))

    # Type-constructor keywords.
    var tci: ptr_uint = 0
    while tci < 12 and count < MAX_COMPLETION_ITEMS:
        let tc = TYPE_CONSTRUCTOR_KEYWORDS[tci]
        if prefix_matches(tc, prefix):
            var detail = string.String.create()
            defer: detail.release()
            detail.append("type constructor ")
            detail.append(tc)
            var sort_text = string.String.create()
            defer: sort_text.release()
            sort_text.append("8_")
            sort_text.append(tc)
            append_item_ext(
                ref_of(items_json), tc, KIND_KEYWORD, detail.as_str(), tc,
                sort_text.as_str(), tc, uri, 0, "", "", ref_of(first))
            count += 1
        tci += 1

    # Keywords.
    var ki: ptr_uint = 0
    while ki < 47 and count < MAX_COMPLETION_ITEMS:
        let kw = COMPLETION_KEYWORDS[ki]
        if prefix_matches(kw, prefix):
            var detail = string.String.create()
            defer: detail.release()
            detail.append("keyword ")
            detail.append(kw)
            var sort_text = string.String.create()
            defer: sort_text.release()
            sort_text.append("9_")
            sort_text.append(kw)
            append_item_ext(
                ref_of(items_json), kw, KIND_KEYWORD, detail.as_str(), kw,
                sort_text.as_str(), kw, uri, 0, "", "", ref_of(first))
            count += 1
        ki += 1

    items_json.append("]")
    return wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)


## Emit one global-path function item.
function emit_function_item(
    items_json: ref[string.String],
    analysis: ref[analyzer.Analysis],
    name: str,
    params: span[ast.Param],
    return_type: ptr[ast.TypeRef]?,
    current_module: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var params_text = string.String.create()
    defer: params_text.release()
    var detail = string.String.create()
    defer: detail.release()
    var snippet = string.String.create()
    defer: snippet.release()
    var has_snippet = false

    let sig_ptr = unsafe: read(analysis).functions.get(name)
    if sig_ptr != null:
        let sig = unsafe: read(sig_ptr)
        append_semantic_params(ref_of(params_text), sig.params, current_module)
        has_snippet = append_semantic_snippet(ref_of(snippet), name, sig.params)
        detail.append("function ")
        detail.append(name)
        detail.append("(")
        detail.append(params_text.as_str())
        if sig.is_variadic:
            if params_text.len() > 0:
                detail.append(", ")
            detail.append("...")
        detail.append(") -> ")
        var returns_text = type_render.qualified_name(sig.return_type, current_module)
        detail.append(returns_text.as_str())
        returns_text.release()
    else:
        append_ast_params(ref_of(params_text), params)
        has_snippet = append_ast_snippet(ref_of(snippet), name, params)
        detail.append("function ")
        detail.append(name)
        detail.append("(")
        detail.append(params_text.as_str())
        detail.append(") -> ")
        append_ast_type(ref_of(detail), return_type, "void")

    let insert_text = if has_snippet: snippet.as_str() else: name
    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append("0_")
    sort_text.append(name)
    var label_details = string.String.create()
    defer: label_details.release()
    if params_text.len() > 0:
        label_details.append(" (")
        label_details.append(params_text.as_str())
        label_details.append(")")
    append_item_ext(
        items_json, name, KIND_FUNCTION, detail.as_str(), insert_text,
        sort_text.as_str(), name, uri, 2, label_details.as_str(), "", first)
    unsafe:
        read(count) = read(count) + 1


## Emit one type item for a declaration, in the host's kind mapping:
## non-generic enums/flags/variants are kind 13, everything else kind 7.
function emit_declared_type_item(
    items_json: ref[string.String],
    decl: ast.Decl,
    uri: str,
    prefix: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    match decl:
        ast.Decl.decl_struct as s:
            emit_type_item(items_json, s.name, KIND_CLASS, uri, prefix, first, count)
        ast.Decl.decl_union as u:
            emit_type_item(items_json, u.name, KIND_CLASS, uri, prefix, first, count)
        ast.Decl.decl_enum as e:
            emit_type_item(items_json, e.name, KIND_ENUM, uri, prefix, first, count)
        ast.Decl.decl_flags as fl:
            emit_type_item(items_json, fl.name, KIND_ENUM, uri, prefix, first, count)
        ast.Decl.decl_variant as vr:
            if vr.type_params.len == 0:
                emit_type_item(items_json, vr.name, KIND_ENUM, uri, prefix, first, count)
            else:
                emit_type_item(items_json, vr.name, KIND_CLASS, uri, prefix, first, count)
        ast.Decl.decl_type_alias as ta:
            emit_type_item(items_json, ta.name, KIND_CLASS, uri, prefix, first, count)
        ast.Decl.decl_opaque as op:
            emit_type_item(items_json, op.name, KIND_CLASS, uri, prefix, first, count)
        _:
            pass


## Emit one type item, skipping the host's hidden built-in names.
function emit_type_item(
    items_json: ref[string.String],
    name: str,
    kind: int,
    uri: str,
    prefix: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    if name.len == 0 or analyzer.is_builtin_completion_type(name) or not prefix_matches(name, prefix):
        return
    var detail = string.String.create()
    defer: detail.release()
    detail.append("type ")
    detail.append(name)
    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append("1_")
    sort_text.append(name)
    append_item_ext(items_json, name, kind, detail.as_str(), name, sort_text.as_str(), name, uri, 0, "", "", first)
    unsafe:
        read(count) = read(count) + 1


## Emit the types the resolved imports bring in — the prelude pair first.
function emit_import_type_items(
    ws: ref[workspace.Workspace],
    items_json: ref[string.String],
    analysis: ref[analyzer.Analysis],
    uri: str,
    prefix: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    if unsafe: read(analysis).imports.contains("std.option"):
        emit_module_type_items(ws, items_json, "std.option", uri, prefix, first, count)
    if unsafe: read(analysis).imports.contains("std.result"):
        emit_module_type_items(ws, items_json, "std.result", uri, prefix, first, count)


## Emit the type declarations a resolved module exports, in declaration order.
function emit_module_type_items(
    ws: ref[workspace.Workspace],
    items_json: ref[string.String],
    module_name: str,
    uri: str,
    prefix: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var roots = ws.effective_module_roots_for("")
    defer: roots.release()
    match resolver.resolve_module_path(module_name, roots.as_span(), resolver.Platform.linux):
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            return
        Result.success as path_payload:
            var module_path = path_payload.value
            defer: module_path.release()
            var module_source = ws.document_source(module_path.as_str()) else:
                return
            defer: module_source.release()
            var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer: parse_diags.release()
            var module_file = parser.parse_source(module_source.as_str(), ref_of(parse_diags))
            let exports_all = module_file.module_kind == ast.ModuleKind.module_raw
            var di: ptr_uint = 0
            while di < module_file.declarations.len and unsafe: read(count) < MAX_COMPLETION_ITEMS:
                var decl: ast.Decl
                unsafe:
                    decl = read(module_file.declarations.data + di)
                if decl_is_public_type(decl, exports_all):
                    emit_declared_type_item(items_json, decl, uri, prefix, first, count)
                di += 1


## True when a declaration is an exported type declaration.
function decl_is_public_type(decl: ast.Decl, exports_all: bool) -> bool:
    match decl:
        ast.Decl.decl_struct as s:
            return exports_all or s.visibility
        ast.Decl.decl_union as u:
            return exports_all or u.visibility
        ast.Decl.decl_enum as e:
            return exports_all or e.visibility
        ast.Decl.decl_flags as fl:
            return exports_all or fl.visibility
        ast.Decl.decl_variant as vr:
            return exports_all or vr.visibility
        ast.Decl.decl_type_alias as ta:
            return exports_all or ta.visibility
        ast.Decl.decl_opaque as op:
            return exports_all or op.visibility
        _:
            return false


## Emit the resolved imports (kind 2) in order: the prelude pair, then each
## import statement whose module resolves.
function emit_import_items(
    ws: ref[workspace.Workspace],
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    file_path: str,
    items_json: ref[string.String],
    uri: str,
    prefix: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var roots = ws.effective_module_roots_for(file_path)
    defer: roots.release()

    if unsafe: read(analysis).imports.contains("std.option"):
        emit_import_item(items_json, "std.option", "std.option", uri, prefix, first, count)
    if unsafe: read(analysis).imports.contains("std.result"):
        emit_import_item(items_json, "std.result", "std.result", uri, prefix, first, count)

    # Import declarations live in `ast_file.imports`, not in the declaration
    # list; iterating the wrong span is why no alias was ever offered.
    var ii: ptr_uint = 0
    while ii < ast_file.imports.len and unsafe: read(count) < MAX_COMPLETION_ITEMS:
        var imp: ast.Decl
        unsafe:
            imp = read(ast_file.imports.data + ii)
        match imp:
            ast.Decl.decl_import as import_decl:
                let module_name = analyzer.qname_to_str(import_decl.path)
                if module_resolves(module_name, roots.as_span()):
                    var label = module_name
                    match import_decl.alias_name:
                        Option.some as alias:
                            label = alias.value
                        Option.none:
                            pass
                    emit_import_item(items_json, label, module_name, uri, prefix, first, count)
            _:
                pass
        ii += 1


## True when the module resolves under the workspace's roots.
function module_resolves(module_name: str, roots: span[str]) -> bool:
    match resolver.resolve_module_path(module_name, roots, resolver.Platform.linux):
        Result.success as path_payload:
            var path = path_payload.value
            path.release()
            return true
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            return false


## Emit one import item.
function emit_import_item(
    items_json: ref[string.String],
    label: str,
    module_name: str,
    uri: str,
    prefix: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    if not prefix_matches(label, prefix):
        return
    var detail = string.String.create()
    defer: detail.release()
    detail.append("module ")
    detail.append(module_name)
    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append("2_")
    sort_text.append(label)
    append_item_ext(
        items_json, label, KIND_MODULE, detail.as_str(), label, sort_text.as_str(), label, uri,
        0, "", "", first)
    unsafe:
        read(count) = read(count) + 1


## Emit one module-level value item.
function emit_value_item(
    items_json: ref[string.String],
    analysis: ref[analyzer.Analysis],
    name: str,
    declared: ptr[ast.TypeRef]?,
    current_module: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var detail = string.String.create()
    defer: detail.release()
    detail.append(name)
    detail.append(": ")
    let ty_ptr = unsafe: read(analysis).value_types.get(name)
    if ty_ptr != null:
        var rendered = type_render.qualified_name(unsafe: read(ty_ptr), current_module)
        detail.append(rendered.as_str())
        rendered.release()
    else:
        append_ast_type(ref_of(detail), declared, "void")
    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append("3_")
    sort_text.append(name)
    append_item_ext(
        items_json, name, KIND_VARIABLE, detail.as_str(), name, sort_text.as_str(), name, uri,
        0, "", "", first)
    unsafe:
        read(count) = read(count) + 1


## Emit the locals visible at `cursor_line`: the enclosing function's
## parameters and every `let`/`var` declared at or before the cursor, in
## declaration order.
function emit_local_binding_items(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    cursor_line: ptr_uint,
    prefix: str,
    uri: str,
    current_module: str,
    items_json: ref[string.String],
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    # The enclosing function is the last one declared at or before the cursor.
    var best_line: ptr_uint = 0
    var body: ptr[ast.Stmt]? = null
    var params: span[ast.Param] = span[ast.Param]()
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                if fun.line <= cursor_line and fun.line >= best_line:
                    best_line = fun.line
                    body = fun.body
                    params = fun.method_params
            _:
                pass
        di += 1

    var pi: ptr_uint = 0
    while pi < params.len and unsafe: read(count) < MAX_COMPLETION_ITEMS:
        let p = unsafe: read(params.data + pi)
        if p.name.len > 0 and p.name != "_" and prefix_matches(p.name, prefix):
            emit_local_item(items_json, p.name, ast_formatter.render_type(p.param_type), uri, first, count)
        pi += 1

    if body != null:
        emit_stmt_locals(
            analysis, unsafe: read(ptr[ast.Stmt]<-body), cursor_line, prefix, uri,
            current_module, items_json, first, count)


## Emit one local binding item.
function emit_local_item(
    items_json: ref[string.String],
    name: str,
    type_text: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    if type_text.len == 0:
        return
    var detail = string.String.create()
    defer: detail.release()
    detail.append(name)
    detail.append(": ")
    detail.append(type_text)
    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append("3_")
    sort_text.append(name)
    append_item_ext(
        items_json, name, KIND_VARIABLE, detail.as_str(), name, sort_text.as_str(), name, uri,
        0, "", "", first)
    unsafe:
        read(count) = read(count) + 1


## Walk statements in order, emitting every local visible at the cursor.
function emit_stmt_locals(
    analysis: ref[analyzer.Analysis],
    stmt: ast.Stmt,
    cursor_line: ptr_uint,
    prefix: str,
    uri: str,
    current_module: str,
    items_json: ref[string.String],
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    match stmt:
        ast.Stmt.stmt_block as blk:
            var si: ptr_uint = 0
            while si < blk.statements.len and unsafe: read(count) < MAX_COMPLETION_ITEMS:
                emit_stmt_locals(
                    analysis, unsafe: read(blk.statements.data + si), cursor_line, prefix, uri,
                    current_module, items_json, first, count)
                si += 1
        ast.Stmt.stmt_local as loc:
            if loc.name.len > 0 and loc.name != "_" and loc.line <= cursor_line and
                    prefix_matches(loc.name, prefix):
                if loc.stmt_type != null:
                    var type_text = string.String.create()
                    defer: type_text.release()
                    append_ast_type(ref_of(type_text), loc.stmt_type, "")
                    emit_local_item(items_json, loc.name, type_text.as_str(), uri, first, count)
                else:
                    match type_render.initializer_type(analysis, loc.value):
                        Option.some as ty:
                            var type_text = type_render.qualified_name(ty.value, current_module)
                            defer: type_text.release()
                            emit_local_item(items_json, loc.name, type_text.as_str(), uri, first, count)
                        Option.none:
                            pass
        ast.Stmt.stmt_if as iff:
            var ib: ptr_uint = 0
            while ib < iff.branches.len:
                let branch = unsafe: read(iff.branches.data + ib)
                emit_stmt_locals(
                    analysis, unsafe: read(branch.body), cursor_line, prefix, uri,
                    current_module, items_json, first, count)
                ib += 1
            if iff.else_body != null:
                emit_stmt_locals(
                    analysis, unsafe: read(ptr[ast.Stmt]<-iff.else_body), cursor_line, prefix, uri,
                    current_module, items_json, first, count)
        ast.Stmt.stmt_while as w:
            if w.body != null:
                emit_stmt_locals(
                    analysis, unsafe: read(ptr[ast.Stmt]<-w.body), cursor_line, prefix, uri,
                    current_module, items_json, first, count)
        ast.Stmt.stmt_for as f:
            if f.body != null:
                emit_stmt_locals(
                    analysis, unsafe: read(ptr[ast.Stmt]<-f.body), cursor_line, prefix, uri,
                    current_module, items_json, first, count)
        ast.Stmt.stmt_match as m:
            var ai: ptr_uint = 0
            while ai < m.arms.len:
                let arm = unsafe: read(m.arms.data + ai)
                if arm.body != null:
                    emit_stmt_locals(
                        analysis, unsafe: read(ptr[ast.Stmt]<-arm.body), cursor_line, prefix, uri,
                        current_module, items_json, first, count)
                ai += 1
        _:
            pass


## Completions for `func(|)` inside a call's argument list — the host's
## named-argument shape (`name = `, kind 14, `0_`).
function named_argument_completions(
    analysis: ref[analyzer.Analysis],
    callee_name: str,
    prefix: str,
    uri: str,
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
            var label = string.String.create()
            defer: label.release()
            label.append(param.name)
            label.append(" = ")
            var detail = string.String.create()
            defer: detail.release()
            detail.append(param.name)
            detail.append(": ")
            detail.append(types.type_to_string(param.ty))
            var sort_text = string.String.create()
            defer: sort_text.release()
            sort_text.append("0_")
            sort_text.append(param.name)
            append_item_ext(
                ref_of(items_json), label.as_str(), KIND_KEYWORD, detail.as_str(), label.as_str(),
                sort_text.as_str(), param.name, uri, 0, "", "", ref_of(first))
            count += 1
        pi += 1

    items_json.append("]")

    if count == 0:
        items_json.release()
        return null

    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc


## Whether a type receiver names a known type: a locally visible name, or a
## type the receiver alias's module carries (the host's
## `resolve_type_receiver_info` falls through to the module binding's table).
function type_receiver_known(analysis: ref[analyzer.Analysis], type_name: str, alias_name: str) -> bool:
    let a = unsafe: read(analysis)
    if a.type_names.contains(type_name):
        return true
    if alias_name.len == 0:
        return false
    let module_ptr = a.imports.get(alias_name) else:
        return false
    var key = string.String.create()
    defer: key.release()
    key.append(unsafe: read(module_ptr))
    key.append(".")
    key.append(type_name)
    if a.imported_type_members.contains(key.as_str()):
        return true
    # An imported enum/flags/variant's members are merged into
    # `match_case_names` under the bare name.
    return a.match_case_names.contains(type_name)


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


## The file's module name, as the host infers it from the module roots.
function module_name_for(ws: ref[workspace.Workspace], file_path: str) -> string.String:
    var roots = ws.effective_module_roots_for(file_path)
    defer: roots.release()
    return resolver.infer_module_name(file_path, roots.as_span())


## Render `a: int, b: int` from semantic parameters.
function append_semantic_params(target: ref[string.String], params: span[analyzer.ParamEntry], current_module: str) -> void:
    var pi: ptr_uint = 0
    while pi < params.len:
        let param = unsafe: read(params.data + pi)
        if pi > 0:
            target.append(", ")
        target.append(param.name)
        target.append(": ")
        var rendered = type_render.qualified_name(param.ty, current_module)
        target.append(rendered.as_str())
        rendered.release()
        pi += 1


## Render `a: int, b: int` from AST parameters.
function append_ast_params(target: ref[string.String], params: span[ast.Param]) -> void:
    var pi: ptr_uint = 0
    while pi < params.len:
        let param = unsafe: read(params.data + pi)
        if pi > 0:
            target.append(", ")
        target.append(param.name)
        target.append(": ")
        target.append(ast_formatter.render_type(param.param_type))
        pi += 1


## Append a rendered type from an optional TypeRef, or `fallback`.
function append_ast_type(target: ref[string.String], type_ref: ptr[ast.TypeRef]?, fallback: str) -> void:
    let tp = type_ref else:
        target.append(fallback)
        return
    target.append(ast_formatter.render_type(unsafe: read(tp)))


## The host's `snippet_for_callable` over semantic parameters: `name()` for
## zero params, `${n:param}` stops for one to five, nothing beyond five.
function append_semantic_snippet(target: ref[string.String], name: str, params: span[analyzer.ParamEntry]) -> bool:
    if params.len > 5:
        return false
    target.append(name)
    target.append("(")
    var pi: ptr_uint = 0
    while pi < params.len:
        let param = unsafe: read(params.data + pi)
        if pi > 0:
            target.append(", ")
        target.append("${")
        target.append_format(f"#{pi + 1}")
        target.append(":")
        target.append(param.name)
        target.append("}")
        pi += 1
    target.append(")")
    return true


## The host's `snippet_for_callable` over AST parameters.
function append_ast_snippet(target: ref[string.String], name: str, params: span[ast.Param]) -> bool:
    if params.len > 5:
        return false
    target.append(name)
    target.append("(")
    var pi: ptr_uint = 0
    while pi < params.len:
        let param = unsafe: read(params.data + pi)
        if pi > 0:
            target.append(", ")
        target.append("${")
        target.append_format(f"#{pi + 1}")
        target.append(":")
        target.append(param.name)
        target.append("}")
        pi += 1
    target.append(")")
    return true


## True when `name` starts with `prefix`, or when prefix is empty.
function prefix_matches(name: str, prefix: str) -> bool:
    if prefix.len == 0:
        return true
    return name.starts_with(prefix)


## Append one CompletionItem in the host's shape.  `uri` non-empty adds the
## host's `data {uri,name}` payload; `label_details` (with an optional
## description) renders the host's `labelDetails` object.
function append_item_ext(
    json_out: ref[string.String],
    label: str,
    kind: int,
    detail: str,
    insert: str,
    sort_text: str,
    data_name: str,
    uri: str,
    insert_format: int,
    label_details: str,
    label_details_description: str,
    first_var: ref[bool],
) -> void:
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
    json_out.append("\"")
    json_out.append(",\"sortText\":\"")
    proto.append_escaped(json_out, sort_text)
    json_out.append("\"")
    if uri.len > 0:
        json_out.append(",\"data\":{\"uri\":\"")
        proto.append_escaped(json_out, uri)
        json_out.append("\",\"name\":\"")
        proto.append_escaped(json_out, data_name)
        json_out.append("\"}")
    if label_details.len > 0 or label_details_description.len > 0:
        json_out.append(",\"labelDetails\":{")
        if label_details.len > 0:
            json_out.append("\"detail\":\"")
            proto.append_escaped(json_out, label_details)
            json_out.append("\"")
            if label_details_description.len > 0:
                json_out.append(",")
        if label_details_description.len > 0:
            json_out.append("\"description\":\"")
            proto.append_escaped(json_out, label_details_description)
            json_out.append("\"")
        json_out.append("}")
    # The host sets `insertTextFormat` after the snippet *and* the label details,
    # so it is the item's last key.
    if insert_format == 2:
        json_out.append(",\"insertTextFormat\":2")
    json_out.append("}")


## Append one import-context CompletionItem in the host's shape (kind Module,
## `module <name>` detail, `0_` sort group, the current document's `data`).
function append_plain_item(
    json_out: ref[string.String],
    label: str,
    kind: int,
    detail: str,
    insert: str,
    uri: str,
    first_var: ref[bool],
) -> void:
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
    json_out.append("\",\"sortText\":\"0_")
    proto.append_escaped(json_out, label)
    json_out.append("\"")
    if uri.len > 0:
        json_out.append(",\"data\":{\"uri\":\"")
        proto.append_escaped(json_out, uri)
        json_out.append("\",\"name\":\"")
        proto.append_escaped(json_out, label)
        json_out.append("\"}")
    json_out.append("}")


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
