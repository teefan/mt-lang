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
import mtc.pretty_printer.ast_formatter as ast_formatter
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.loader.path_resolver as resolver
import mtc.lsp.cursor as cursor
import mtc.lsp.navigation as navigation
import mtc.lsp.protocol as proto
import mtc.lsp.scope as scope_mod
import mtc.lsp.type_render as type_render
import mtc.lsp.uri as uri_ops
import mtc.lsp.utils as utils
import mtc.lsp.workspace as workspace
import mtc.lsp.workspace_index as idx


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

    # The AST and analysis come from the shared caches — the loader-backed entry
    # when the document loads (imports bound, so a value's imported type
    # resolves: `var n = node.Node.create(…)`), else the single-file pair.
    let doc = workspace.document_analysis_for(ws, file_path.as_str()) else:
        proto.write_response_raw(id, "[]")
        return
    var ast_file = doc.ast_file
    var analysis = doc.analysis

    let text_before = line_prefix(source, line, character)

    # Attribute context: complete inside `@[...`.
    var attribute_items = attribute_completion_items(ref_of(analysis), text_before, uri)
    if attribute_items != null:
        proto.write_response_raw(id, unsafe: read(attribute_items).as_str())
        unsafe: read(attribute_items).release()
        heap.release(attribute_items)
        return

    # Format-string interpolation: complete inside `f"...#{|}`.  The host
    # answers only values, functions and the visible locals here, never the
    # global bucket, and falls through when the interpolation is closed.
    var format_items = format_string_completion_items(
        ref_of(analysis), ast_file, text_before, line, uri)
    if format_items != null:
        proto.write_response_raw(id, unsafe: read(format_items).as_str())
        unsafe: read(format_items).release()
        heap.release(format_items)
        return

    # Named argument completions: inside a function/struct call, e.g.
    # `Point(x = 1, |)`.
    var named_items = named_argument_completion_items(ref_of(analysis), text_before, prefix, uri)
    if named_items != null:
        proto.write_response_raw(id, unsafe: read(named_items).as_str())
        unsafe: read(named_items).release()
        heap.release(named_items)
        return

    # Specialization context: complete inside `name[...`.
    var specialization_items = specialization_completion_items(ref_of(analysis), text_before, uri)
    if specialization_items != null:
        proto.write_response_raw(id, unsafe: read(specialization_items).as_str())
        unsafe: read(specialization_items).release()
        heap.release(specialization_items)
        return

    # Dot-receiver context.  The host answers every dot receiver from the
    # receiver chain — and, failing that, from the file's method list — so the
    # keyword list is never a dot-receiver answer.
    var type_alias: str = ""
    match cursor.type_receiver_at(source, line, character):
        Option.some as trecv:
            type_alias = trecv.value.module_alias
        Option.none:
            pass
    # A receiver the text chain cannot resolve (a call, index or cast, or a
    # trailing dot) has its inferred type recorded by the analyzer at the
    # member token — the dot itself when no member name is typed yet.
    var has_recorded_type = false
    var recorded_type: types.Type = types.Type.ty_error
    let member_column = dot_member_column(source, line, character)
    if member_column > 0:
        match analyzer.member_receiver_type_at(ref_of(analysis), line + 1, member_column):
            Option.some as recorded_ty:
                recorded_type = recorded_ty.value
                has_recorded_type = true
            Option.none:
                pass

    match cursor.member_receiver_path_at(source, line, character):
        Option.some as path_payload:
            let receiver_path = path_payload.value
            # The receiver is the path's last segment (the host's
            # `find_dot_receiver`).
            var segment_start: ptr_uint = 0
            var pi: ptr_uint = 0
            while pi < receiver_path.len:
                if receiver_path.byte_at(pi) == '.':
                    segment_start = pi + 1
                pi += 1
            let receiver = receiver_path.slice(segment_start, receiver_path.len - segment_start)
            # A type receiver (`Type[...]`, `alias.Type`) keeps its static
            # member path: the analyzer also records an instance type for a
            # specialization, but static members are the useful answer here.
            let type_context = type_receiver_known(ref_of(analysis), receiver, type_alias)
            if has_recorded_type and not type_context:
                var recorded_items = typed_receiver_completions(
                    ref_of(analysis), ast_file, recorded_type, prefix, uri)
                proto.write_response_raw(id, recorded_items.as_str())
                recorded_items.release()
                return
            var dot_items = dot_receiver_completions(
                ws, ref_of(analysis), ast_file, file_path.as_str(), uri, receiver, receiver_path,
                type_alias, prefix, line)
            proto.write_response_raw(id, dot_items.as_str())
            dot_items.release()
            return
        Option.none:
            if has_recorded_type:
                var recorded_items = typed_receiver_completions(
                    ref_of(analysis), ast_file, recorded_type, prefix, uri)
                proto.write_response_raw(id, recorded_items.as_str())
                recorded_items.release()
                return

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
    receiver_path: str,
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

    # 3. A multi-segment path (`m.col0.`, `r.top_edge.`): the host walks the
    # intermediate segments through fields before answering.
    if receiver_path.len > receiver.len:
        var chain_items = value_chain_completions(analysis, ast_file, receiver_path, line + 1, prefix, uri)
        if chain_items != null:
            let result = unsafe: read(chain_items)
            heap.release(chain_items)
            return result

    # 4. Value receiver: fields then methods of the receiver's type.  An
    # imported type's members come from the analysis's `imported_type_members`
    # record, since the current module's tables do not carry them.
    match receiver_value_type(analysis, ast_file, receiver, line + 1):
        Option.some as ty:
            return typed_receiver_completions(analysis, ast_file, ty.value, prefix, uri)
        Option.none:
            pass

    # 4. The file's method list.
    return method_fallback_completions(analysis, ast_file, prefix, uri)


## The 1-based byte column of the member token before the cursor: the dot
## itself when no member name is typed yet (`read(p).|`), else the member's
## first byte.  0 when the cursor is not in a dot context.
function dot_member_column(source: str, line: ptr_uint, character: ptr_uint) -> ptr_uint:
    let line_text = utils.source_line(source, line + 1)
    var pos = character
    if pos > line_text.len:
        pos = line_text.len
    while pos > 0 and utils.is_word_byte(line_text.byte_at(pos - 1)):
        pos -= 1
    if pos == 0 or line_text.byte_at(pos - 1) != 46:
        return 0
    if pos == character:
        return pos
    return pos + 1


## Complete a receiver whose type is already known: imported members first,
## then the local value's fields and methods, then the file's method list.
function typed_receiver_completions(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    receiver_ty: types.Type,
    prefix: str,
    uri: str,
) -> string.String:
    var imported_items = imported_value_receiver_completions(analysis, receiver_ty, prefix, uri)
    if imported_items != null:
        let result = unsafe: read(imported_items)
        heap.release(imported_items)
        return result
    var value_items = value_receiver_completions(analysis, receiver_ty, prefix, uri)
    if value_items != null:
        let result = unsafe: read(value_items)
        heap.release(value_items)
        return result
    return method_fallback_completions(analysis, ast_file, prefix, uri)


## Handle completionItem/resolve.  The item's `data.uri`/`data.name` identify
## its declaration file when the item belongs to the current document; imported
## items fall back to the workspace index by name.  `##` docs above the
## declaration become Markdown `documentation`, and the resolved item is the
## original item with that field added (never a rebuilt label-only object).
public function handle_completion_resolve(
    ws: ref[workspace.Workspace],
    params: json.Value,
    id: json.Value,
) -> void:
    let label = extract_string_field(params, "label")
    let data_name = extract_item_data_field(params, "name")
    let name = if data_name.len > 0: data_name else: label
    if name.len == 0:
        proto.write_response(id, params)
        return
    let data_uri = extract_item_data_field(params, "uri")
    log.info(f"resolve: name=#{name} uri=#{data_uri}")

    var doc_text = resolve_completion_docs(ws, name, data_uri, extract_item_kind(params))
    defer: doc_text.release()
    if doc_text.len() == 0:
        proto.write_response(id, params)
        return

    let obj_ptr = params.as_object() else:
        proto.write_response(id, params)
        return
    var documentation = json.create_object_value()
    let doc_obj = documentation.as_object() else:
        proto.write_response(id, params)
        return
    unsafe:
        read(doc_obj).set("kind", json.string_from_str("markdown"))
        read(doc_obj).set("value", json.string_from_str(doc_text.as_str()))
        read(obj_ptr).set("documentation", documentation)
    proto.write_response(id, params)


## The declaration file's doc text for a completion item.  The current
## document is tried first (its `data.uri`); imported items then consult the
## workspace index by exact name.  A local/parameter item never falls back to a
## same-named global.
function resolve_completion_docs(
    ws: ref[workspace.Workspace],
    name: str,
    data_uri: str,
    kind: int,
) -> string.String:
    if data_uri.len > 0:
        match uri_ops.file_uri_to_path(data_uri):
            Option.some as path:
                var docs = collect_doc_text(path.value.as_str(), name)
                path.value.release()
                if docs.len() > 0:
                    return docs
                docs.release()
            Option.none:
                pass

    if kind == KIND_VARIABLE:
        return string.String.create()

    ws.build_index_if_needed()
    var match_indices = idx.query_index(ref_of(ws.index), name, 8)
    defer: match_indices.release()
    var i: ptr_uint = 0
    while i < match_indices.len():
        let ei = match_indices.get(i) else:
            break
        i += 1
        let entry = unsafe: idx.read_entry(ref_of(ws.index), read(ei))
        if not unsafe: read(entry).name.as_str().equal(name):
            continue
        var docs = collect_doc_text(unsafe: read(entry).path.as_str(), name)
        if docs.len() > 0:
            return docs
        docs.release()
    return string.String.create()


## Read a `data.<field>` string from a completion item.
function extract_item_data_field(value: json.Value, field: str) -> str:
    let obj_ptr = value.as_object() else:
        return ""
    unsafe:
        let data_ptr = read(obj_ptr).get("data")
        if data_ptr == null:
            return ""
        let data_obj = read(data_ptr).as_object() else:
            return ""
        let field_ptr = read(data_obj).get(field)
        if field_ptr == null:
            return ""
        let field_str = read(field_ptr).as_string() else:
            return ""
        return field_str


## The item's numeric `kind`, or 0 when absent.
function extract_item_kind(value: json.Value) -> int:
    let obj_ptr = value.as_object() else:
        return 0
    unsafe:
        let kind_ptr = read(obj_ptr).get("kind")
        if kind_ptr == null:
            return 0
        let kind = read(kind_ptr).as_number() else:
            return 0
        return int<-kind


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


## Collect the contiguous `##` documentation lines above a named declaration.
## Declarations may be indented (methods, fields, enum/variant members) and may
## be preceded by modifiers and a declaration keyword (`public static function
## foo`, `const NAME`, `red`), which the old bare-name scan never matched.
public function collect_doc_text(path: str, name: str) -> string.String:
    var result = string.String.create()
    if name.len == 0:
        return result

    log.info(f"collect_doc_text: path=#{path} name=#{name}")
    match fs_mod.read_text(path):
        Result.success as payload:
            var source = payload.value
            defer: source.release()
            var lines = utils.split_lines(source.as_str())
            defer: lines.release()

            var target_line: ptr_uint = 0
            var found = false
            var li: ptr_uint = 0
            while li < lines.len() and not found:
                let line_text = utils.line_at(ref_of(lines), li)
                if declaration_line_has_name(line_text, name):
                    target_line = li
                    found = true
                li += 1
            if not found:
                return result

            var doc_lines = vec.Vec[str].create()
            defer: doc_lines.release()
            var di = target_line
            while di > 0:
                di -= 1
                let line_text = utils.line_at(ref_of(lines), di)
                let trimmed = trim_left(line_text)
                if trimmed.len >= 2 and trimmed.starts_with("##"):
                    let content = trimmed.slice(2, trimmed.len - 2)
                    doc_lines.push(trim_left(content))
                else:
                    break

            var ordered = vec.Vec[str].create()
            defer: ordered.release()
            var oi = doc_lines.len()
            while oi > 0:
                oi -= 1
                let dp = doc_lines.get(oi) else:
                    break
                ordered.push(unsafe: read(dp))
            var xi: ptr_uint = 0
            while xi < ordered.len():
                let xp = ordered.get(xi) else:
                    break
                if xi > 0:
                    result.append("\n")
                result.append(unsafe: read(xp))
                xi += 1

        Result.failure:
            pass

    return result


## True when `line_text` declares `name`.  Leading modifiers are skipped, a
## declaration keyword is followed by the name, and a field/member/arm line
## starts with its own name.  The terminator check keeps a call or an
## expression from being mistaken for a declaration where the name is first.
function declaration_line_has_name(line_text: str, name: str) -> bool:
    let trimmed = trim_left(line_text)
    if trimmed.len == 0:
        return false
    var i: ptr_uint = 0
    while i < trimmed.len:
        let word_start = i
        while i < trimmed.len and utils.is_word_byte(trimmed.byte_at(i)):
            i += 1
        if i == word_start:
            return false
        let word = trimmed.slice(word_start, i - word_start)
        while i < trimmed.len and trimmed.byte_at(i) == ' ':
            i += 1
        if is_declaration_modifier(word):
            continue
        if is_declaration_keyword(word):
            let name_start = i
            while i < trimmed.len and utils.is_word_byte(trimmed.byte_at(i)):
                i += 1
            if i == name_start:
                return false
            if not trimmed.slice(name_start, i - name_start).equal(name):
                return false
            return declaration_terminator_ok(trimmed, i)
        if not word.equal(name):
            return false
        return declaration_terminator_ok(trimmed, i)
    return false


function is_declaration_modifier(word: str) -> bool:
    return word.equal("public") or word.equal("private") or word.equal("static") or
        word.equal("async") or word.equal("editable") or word.equal("final") or
        word.equal("readonly") or word.equal("inline") or word.equal("local") or
        word.equal("unsafe")


function is_declaration_keyword(word: str) -> bool:
    return word.equal("function") or word.equal("struct") or word.equal("enum") or
        word.equal("variant") or word.equal("flags") or word.equal("interface") or
        word.equal("union") or word.equal("event") or word.equal("opaque") or
        word.equal("type") or word.equal("const") or word.equal("var") or
        word.equal("let") or word.equal("attribute")


## The byte after a declared name must start a declaration shape: a parameter
## list, a type/field colon, a generic clause, an initializer, or end of line.
function declaration_terminator_ok(line_text: str, index: ptr_uint) -> bool:
    var i = index
    while i < line_text.len and line_text.byte_at(i) == ' ':
        i += 1
    if i >= line_text.len:
        return true
    let b = line_text.byte_at(i)
    return b == '(' or b == ':' or b == '<' or b == '='


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
            let module_doc = workspace.document_analysis_for(ws, module_path.as_str()) else:
                return null
            var module_file = module_doc.ast_file
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
## `type_name` in registration order, then every import's (the host's
## `facts.imports` key order), deduped by key (first wins).  The host renders
## these items with absolute type names, so callers render with an empty
## current module.
function merged_receiver_methods(
    analysis: ref[analyzer.Analysis],
    type_name: str,
    sink: ref[vec.Vec[ReceiverMethod]],
    seen: ref[map_mod.Map[str, bool]],
) -> void:
    var prefix = string.String.create()
    defer: prefix.release()
    prefix.append(type_name)
    prefix.append(".")

    let order = unsafe: read(analysis).method_order
    var oi: ptr_uint = 0
    while oi < order.len():
        let key_ptr = order.get(oi) else:
            break
        let key = unsafe: read(key_ptr)
        if key.starts_with(prefix.as_str()):
            let member = key.slice(prefix.len(), key.len - prefix.len())
            if not seen.contains(member):
                let sig_ptr = unsafe: read(analysis).method_sigs.get(key)
                if sig_ptr != null:
                    seen.set(member, true)
                    sink.push(ReceiverMethod(
                        key = member, module_name = unsafe: read(analysis).module_name,
                        sig = unsafe: read(sig_ptr)))
        oi += 1

    # Then each imported module's table, in the host's `facts.imports` key
    # order (the file's imports, then the prelude modules).
    let import_order = unsafe: read(analysis).import_order
    var ii: ptr_uint = 0
    while ii < import_order.len():
        let module_ptr = import_order.get(ii) else:
            break
        let module_name = unsafe: read(module_ptr)
        var key = string.String.create()
        defer: key.release()
        key.append(module_name)
        key.append(".")
        key.append(type_name)
        let member_ptr = unsafe: read(analysis).imported_type_members.get(key.as_str())
        if member_ptr != null:
            let members = unsafe: read(member_ptr)
            var moi: ptr_uint = 0
            while moi < members.method_order.len():
                let member_ptr2 = members.method_order.get(moi) else:
                    break
                let member = unsafe: read(member_ptr2)
                if not seen.contains(member):
                    let sig_ptr = members.methods.get(member)
                    if sig_ptr != null:
                        seen.set(member, true)
                        sink.push(ReceiverMethod(
                            key = member, module_name = module_name,
                            sig = unsafe: read(sig_ptr)))
                moi += 1
        ii += 1


## The method kinds a receiver completion emits.  The host's branches: a
## *type* receiver takes static methods alone (`Player.` → `zero`), a *value*
## receiver the instance members — a static method belongs to the type, not the
## value — and the unresolved-receiver fallback everything (its labels are
## still the bare names: a static method's table key is `static:<name>`, which
## must never reach the wire).
enum ReceiverMethodScope: ubyte
    statics_only = 0
    instances_only = 1
    all = 2


## Emit one merged receiver method in the host's shape, for the method kinds
## `scope` selects; every path labels and inserts the method's bare name.
function emit_receiver_method(
    entry: ReceiverMethod,
    scope: ReceiverMethodScope,
    prefix: str,
    sort_prefix: str,
    uri: str,
    items_json: ref[string.String],
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    let is_static = entry.sig.method_kind == ast.MethodKind.mk_static
    if scope == ReceiverMethodScope.statics_only and not is_static:
        return
    if scope == ReceiverMethodScope.instances_only and is_static:
        return
    var label = string.String.create()
    defer: label.release()
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


## The nested types of a struct type receiver (`Rectangle.` → `Edge`), the
## host's nested-types branch: kind 5, the child's bare name as the label and
## `Parent.Child` as the detail.  None when the type declares no nested types.
function nested_type_receiver_items(
    ast_file: ast.SourceFile,
    type_name: str,
    prefix: str,
    uri: str,
) -> ptr[string.String]?:
    # The declaration's own list is the ordered source (the host iterates
    # `type.nested_types`).
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_struct as s:
                if s.name.equal(type_name):
                    return emit_nested_child_items(s.nested_types, type_name, prefix, uri)
            _:
                pass
        di += 1
    return null


## Emit one level of a struct's nested type declarations as completion items.
function emit_nested_child_items(
    nested: span[ast.Decl],
    parent_name: str,
    prefix: str,
    uri: str,
) -> ptr[string.String]?:
    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < nested.len and count < MAX_COMPLETION_ITEMS:
        var d: ast.Decl
        unsafe:
            d = read(nested.data + i)
        match d:
            ast.Decl.decl_struct as s:
                if prefix_matches(s.name, prefix):
                    var detail = string.String.create()
                    defer: detail.release()
                    detail.append(parent_name)
                    detail.append(".")
                    detail.append(s.name)
                    var sort_text = string.String.create()
                    defer: sort_text.release()
                    sort_text.append("1_")
                    sort_text.append(s.name)
                    append_item_ext(
                        ref_of(items_json), s.name, KIND_MODULE_TYPE, detail.as_str(), s.name,
                        sort_text.as_str(), s.name, uri, 0, "", "", ref_of(first))
                    count += 1
            _:
                pass
        i += 1
    items_json.append("]")
    if count == 0:
        items_json.release()
        return null
    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), false)
    return alloc


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

    # Enum/flags/variant members (the host's `type.members`).
    let members_ptr = unsafe: read(analysis).member_names.get(type_name)
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

    # Nested types (`Rectangle.` → `Edge`): the host answers with them alone
    # when they exist.
    var nested_items = nested_type_receiver_items(ast_file, type_name, prefix, uri)
    if nested_items != null:
        items_json.release()
        return nested_items

    # Methods declared on the type — merged across the current module and every
    # import, static only, with the `static:` marker stripped (the host's
    # `completion_items_for_type_receiver`).
    var methods = vec.Vec[ReceiverMethod].create()
    defer: methods.release()
    var method_seen = map_mod.Map[str, bool].create()
    defer: method_seen.release()
    merged_receiver_methods(analysis, type_name, ref_of(methods), ref_of(method_seen))
    var mi2: ptr_uint = 0
    while mi2 < methods.len() and count < MAX_COMPLETION_ITEMS:
        let mp = methods.get(mi2) else:
            break
        unsafe:
            emit_receiver_method(read(mp), ReceiverMethodScope.statics_only, prefix, "0_", uri, ref_of(items_json), ref_of(first), ref_of(count))
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
    receiver_ty: types.Type,
    prefix: str,
    uri: str,
) -> ptr[string.String]?:
    # The host's `project_field_receiver_type_for_completion`: the fields come
    # from the type with a nullable unwrapped and `ref`/`ptr` projected; the
    # methods project through `ref`/`ptr` alone.
    let field_ty = navigation.project_value_receiver_type(types.unwrap_nullable(receiver_ty))
    let type_name = navigation.type_to_key_name(field_ty)

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    let fields_ptr = if type_name.len > 0: unsafe: read(analysis).structs.get(type_name) else: null
    if fields_ptr != null:
        let fields = unsafe: read(fields_ptr)
        var fi: ptr_uint = 0
        while fi < fields.len and count < MAX_COMPLETION_ITEMS:
            let field = unsafe: read(fields.data + fi)
            if prefix_matches(field.name, prefix):
                var detail = string.String.create()
                defer: detail.release()
                detail.append(field.name)
                detail.append(": ")
                var rendered_field = field_type_detail(fields, field.name)
                detail.append(rendered_field.as_str())
                rendered_field.release()
                var sort_text = string.String.create()
                defer: sort_text.release()
                sort_text.append("0_")
                sort_text.append(field.name)
                append_item_ext(
                    ref_of(items_json), field.name, KIND_FIELD, detail.as_str(), field.name,
                    sort_text.as_str(), field.name, uri, 0, "", "", ref_of(first))
                count += 1
            fi += 1
    else:
        match field_ty:
            # A match-arm payload binding's type: the arm's declared fields.
            types.Type.ty_variant_arm_payload as payload:
                emit_payload_field_items(ref_of(items_json), payload.fields, prefix, uri, ref_of(first), ref_of(count))
            # A tuple's positional or named fields.
            types.Type.ty_tuple as tup:
                emit_tuple_field_items(ref_of(items_json), tup.elements, tup.field_names, prefix, uri, ref_of(first), ref_of(count))
            _:
                if type_name.len > 0:
                    emit_builtin_fields(ref_of(items_json), analysis, field_ty, prefix, uri, ref_of(first), ref_of(count))

    let method_ty = navigation.project_value_receiver_type(receiver_ty)
    let method_name = navigation.type_to_key_name(method_ty)
    var methods = vec.Vec[ReceiverMethod].create()
    defer: methods.release()
    var method_seen = map_mod.Map[str, bool].create()
    defer: method_seen.release()
    if method_name.len > 0:
        merged_receiver_methods(analysis, method_name, ref_of(methods), ref_of(method_seen))
        var mi: ptr_uint = 0
        while mi < methods.len() and count < MAX_COMPLETION_ITEMS:
            let mp = methods.get(mi) else:
                break
            unsafe:
                emit_receiver_method(read(mp), ReceiverMethodScope.instances_only, prefix, "1_", uri, ref_of(items_json), ref_of(first), ref_of(count))
            mi += 1

    items_json.append("]")
    if count == 0:
        items_json.release()
        return null

    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc


const VECTOR_COMPONENT_NAMES: array[str, 4] = array[str, 4]("x", "y", "z", "w")
const MATRIX_COLUMN_NAMES: array[str, 4] = array[str, 4]("col0", "col1", "col2", "col3")


## Emit the host's builtin field tables — a vector's `x`/`y`/`z`/`w`, a matrix's
## columns, a quaternion's components, a `span`'s `data`/`len` and an `SoA`'s
## per-field arrays (the host's `Types::Vector`/`Matrix`/`Quaternion`/`Span`/
## `SoA` `fields`).
function emit_builtin_fields(
    items_json: ref[string.String],
    analysis: ref[analyzer.Analysis],
    receiver_ty: types.Type,
    prefix: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    let name = navigation.type_to_key_name(receiver_ty)
    if name.equal("vec2") or name.equal("vec3") or name.equal("vec4") or
       name.equal("ivec2") or name.equal("ivec3") or name.equal("ivec4") or name.equal("quat"):
        let width = vector_field_width(name)
        let element = if name.starts_with("ivec"): "int" else: "float"
        var i: ptr_uint = 0
        while i < width and unsafe: read(count) < MAX_COMPLETION_ITEMS:
            emit_builtin_field(items_json, VECTOR_COMPONENT_NAMES[i], element, prefix, uri, first, count)
            i += 1
        return
    if name.equal("mat3") or name.equal("mat4"):
        let dim: ptr_uint = if name.equal("mat3"): 3 else: 4
        let column = if dim == 3: "vec3" else: "vec4"
        var i: ptr_uint = 0
        while i < dim and unsafe: read(count) < MAX_COMPLETION_ITEMS:
            emit_builtin_field(items_json, MATRIX_COLUMN_NAMES[i], column, prefix, uri, first, count)
            i += 1
        return
    if name.equal("span"):
        var data_text = string.String.create()
        defer: data_text.release()
        data_text.append("ptr[")
        var element = type_render.qualified_name(types.pointer_element(receiver_ty), "")
        data_text.append(element.as_str())
        element.release()
        data_text.append("]")
        emit_builtin_field(items_json, "data", data_text.as_str(), prefix, uri, first, count)
        emit_builtin_field(items_json, "len", "ptr_uint", prefix, uri, first, count)
        return
    if name.equal("SoA"):
        emit_soa_fields(items_json, analysis, receiver_ty, prefix, uri, first, count)


## The number of named components a vector type's fields carry (`vec3.x` …).
function vector_field_width(name: str) -> ptr_uint:
    if name.equal("vec2") or name.equal("ivec2"):
        return 2
    if name.equal("vec3") or name.equal("ivec3"):
        return 3
    return 4


## An `SoA[T, N]`'s fields: `T`'s own fields, each joined into
## `array[<field type>, N]` (the host's `Types::SoA#fields`).
function emit_soa_fields(
    items_json: ref[string.String],
    analysis: ref[analyzer.Analysis],
    receiver_ty: types.Type,
    prefix: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    match receiver_ty:
        types.Type.ty_generic as g:
            if g.args.len < 2:
                return
            let element_name = navigation.type_to_key_name(unsafe: read(g.args.data + 0))
            let fields_ptr = unsafe: read(analysis).structs.get(element_name) else:
                return
            var count_text = type_render.qualified_name(unsafe: read(g.args.data + 1), "")
            defer: count_text.release()
            let fields = unsafe: read(fields_ptr)
            var fi: ptr_uint = 0
            while fi < fields.len and unsafe: read(count) < MAX_COMPLETION_ITEMS:
                let field = unsafe: read(fields.data + fi)
                var field_ty = string.String.create()
                defer: field_ty.release()
                field_ty.append("array[")
                var rendered_field = field_type_detail(fields, field.name)
                field_ty.append(rendered_field.as_str())
                rendered_field.release()
                field_ty.append(", ")
                field_ty.append(count_text.as_str())
                field_ty.append("]")
                emit_builtin_field(items_json, field.name, field_ty.as_str(), prefix, uri, first, count)
                fi += 1
        _:
            pass


## Emit one builtin field item, with a pre-rendered type text.
function emit_builtin_field(
    items_json: ref[string.String],
    name: str,
    type_text: str,
    prefix: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    if not prefix_matches(name, prefix):
        return
    var detail = string.String.create()
    defer: detail.release()
    detail.append(name)
    detail.append(": ")
    detail.append(type_text)
    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append("0_")
    sort_text.append(name)
    append_item_ext(
        items_json, name, KIND_FIELD, detail.as_str(), name, sort_text.as_str(), name, uri,
        0, "", "", first)
    unsafe:
        read(count) = read(count) + 1


## Emit a tuple receiver's fields — `_0`, `_1`, … for a positional tuple, or the
## declared names for a named one (the host's `Types::Tuple#fields`).
function emit_tuple_field_items(
    items_json: ref[string.String],
    elements: span[types.Type],
    field_names: Option[span[str]],
    prefix: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var i: ptr_uint = 0
    while i < elements.len and unsafe: read(count) < MAX_COMPLETION_ITEMS:
        var label = string.String.create()
        defer: label.release()
        match field_names:
            Option.some as names:
                if i < names.value.len:
                    label.append(unsafe: read(names.value.data + i))
            Option.none:
                pass
        if label.len() == 0:
            label.append("_")
            if i >= 100:
                label.push_byte(ubyte<-(48 + (i / 100) % 10))
            if i >= 10:
                label.push_byte(ubyte<-(48 + (i / 10) % 10))
            label.push_byte(ubyte<-(48 + i % 10))
        if prefix_matches(label.as_str(), prefix):
            var detail = string.String.create()
            defer: detail.release()
            detail.append(label.as_str())
            detail.append(": ")
            var rendered = type_render.qualified_name(unsafe: read(elements.data + i), "")
            detail.append(rendered.as_str())
            rendered.release()
            var sort_text = string.String.create()
            defer: sort_text.release()
            sort_text.append("0_")
            sort_text.append(label.as_str())
            append_item_ext(
                items_json, label.as_str(), KIND_FIELD, detail.as_str(), label.as_str(),
                sort_text.as_str(), label.as_str(), uri, 0, "", "", first)
            unsafe:
                read(count) = read(count) + 1
        i += 1


## Emit a variant arm payload's fields (`Option_some{value: int}` — the host's
## `Types::VariantArmPayload#fields`), as field items.
function emit_payload_field_items(
    items_json: ref[string.String],
    fields: span[types.PayloadField],
    prefix: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var fi: ptr_uint = 0
    while fi < fields.len and unsafe: read(count) < MAX_COMPLETION_ITEMS:
        let field = unsafe: read(fields.data + fi)
        if prefix_matches(field.name, prefix):
            var detail = string.String.create()
            defer: detail.release()
            detail.append(field.name)
            detail.append(": ")
            var rendered = type_render.qualified_name(field.ty, "")
            detail.append(rendered.as_str())
            rendered.release()
            var sort_text = string.String.create()
            defer: sort_text.release()
            sort_text.append("0_")
            sort_text.append(field.name)
            append_item_ext(
                items_json, field.name, KIND_FIELD, detail.as_str(), field.name,
                sort_text.as_str(), field.name, uri, 0, "", "", first)
            unsafe:
                read(count) = read(count) + 1
        fi += 1


## An *imported* type's members for a value receiver (`var n = node.Node.create(…)`
## then `n.`): the analysis's `imported_type_members` record carries the declaring
## module's fields and method signatures, and the host renders both with that
## module's qualification (`parent: ptr[node.Node]?`).  None when the receiver is
## not an imported type or the record has no entry for it, so the caller keeps its
## local-type path and the method fallback.
function imported_value_receiver_completions(
    analysis: ref[analyzer.Analysis],
    receiver_ty: types.Type,
    prefix: str,
    uri: str,
) -> ptr[string.String]?:
    # The host's `project_field_receiver_type_for_completion` unwraps a nullable
    # and projects `ref`/`ptr` before it looks the type up, so a
    # `ref[ImportedStruct]` receiver answers the struct's fields.
    let projected_ty = navigation.project_value_receiver_type(types.unwrap_nullable(receiver_ty))
    let reference = navigation.imported_type_reference(projected_ty) else:
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
    merged_receiver_methods(analysis, im_name, ref_of(methods), ref_of(method_seen))
    var mi: ptr_uint = 0
    while mi < methods.len() and count < MAX_COMPLETION_ITEMS:
        let mp = methods.get(mi) else:
            break
        unsafe:
            emit_receiver_method(read(mp), ReceiverMethodScope.instances_only, prefix, "1_", uri, ref_of(items_json), ref_of(first), ref_of(count))
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


## Render a struct/union field's resolved type the way the host renders a
## completion field's `ftype` (its `Types::Base#to_s`): the analyzer's field
## type, fully qualified.
function field_type_detail(fields: span[analyzer.FieldEntry], field_name: str) -> string.String:
    var i: ptr_uint = 0
    while i < fields.len:
        let f = unsafe: read(fields.data + i)
        if f.name.equal(field_name):
            return type_render.qualified_name(f.ty, "")
        i += 1
    return string.String.create()


## The file's method list — the host's `method-fallback` answer for a receiver
## it cannot resolve.  The host iterates its method table by receiver type in
## first-registration order, which is this file's declaration order (inline
## methods are desugared into `extending` blocks by the parser); each method
## carries the resolved signature and is labeled by its bare name.
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
                                ReceiverMethodScope.all, prefix, "0_", uri, ref_of(items_json), ref_of(first), ref_of(count))
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


## The host's `value_chain_completions`: a multi-segment receiver path
## (`mscaled.col0.`, `r.top_edge.`) resolves its first segment as a value, walks
## the remaining segments through fields, and answers the final type's members.
## None when a segment does not resolve or the final type has no members.
function value_chain_completions(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    path: str,
    cursor_line: ptr_uint,
    prefix: str,
    uri: str,
) -> ptr[string.String]?:
    var segments = vec.Vec[str].create()
    defer: segments.release()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= path.len:
        if i == path.len or path.byte_at(i) == '.':
            segments.push(path.slice(start, i - start))
            start = i + 1
        i += 1
    if segments.len() < 2:
        return null

    let first_ptr = segments.get(0) else:
        return null
    var current_ty = receiver_value_type(analysis, ast_file, unsafe: read(first_ptr), cursor_line) else:
        return null
    var si: ptr_uint = 1
    while si < segments.len():
        let seg_ptr = segments.get(si) else:
            break
        let seg = unsafe: read(seg_ptr)
        match navigation.field_of_type(analysis, current_ty, seg):
            Option.some as ft:
                current_ty = ft.value
            Option.none:
                return null
        si += 1

    var imported_items = imported_value_receiver_completions(analysis, current_ty, prefix, uri)
    if imported_items != null:
        return imported_items
    return value_receiver_completions(analysis, current_ty, prefix, uri)


## Resolve a receiver name to the value's type: the innermost local or
## parameter of that name visible at `cursor_line`, else a module-level value.
## `this` resolves to the enclosing `extending` method's receiver type (the
## host's implicit scope binding).
function receiver_value_type(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    name: str,
    cursor_line: ptr_uint,
) -> Option[types.Type]:
    if name.equal("this"):
        return enclosing_this_type(analysis, ast_file, cursor_line)

    # Locals and parameters of the enclosing function.
    var best_line: ptr_uint = 0
    var body: ptr[ast.Stmt]? = null
    var params: span[ast.Param] = span[ast.Param]()
    var enclosing_name: str = ""
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
                    enclosing_name = fun.name
            _:
                pass
        di += 1

    # A match-arm payload binding (`Option.some as s`) declared inside the
    # enclosing function carries the arm's payload type — the host's scope
    # binding for the arm name.  Bindings of the same name in other functions
    # are out of scope.
    if best_line > 0:
        match arm_binding_type_for(analysis, name, best_line, cursor_line):
            Option.some as arm_ty:
                return Option[types.Type].some(value = arm_ty.value)
            Option.none:
                pass

    var pi: ptr_uint = 0
    while pi < params.len:
        let p = unsafe: read(params.data + pi)
        if p.name.equal(name):
            # A parameter's type is the enclosing function's resolved signature
            # type (the host's scope binding), so a generic parameter
            # (`ref[NPC]`) projects like a declared local.  The AST TypeRef is
            # the fallback for a signature the analysis does not carry.
            let sig_ptr = unsafe: read(analysis).functions.get(enclosing_name)
            if sig_ptr != null:
                let sig = unsafe: read(sig_ptr)
                if pi < sig.params.len:
                    return Option[types.Type].some(value = unsafe: read(sig.params.data + pi).ty)
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


## The recorded match-arm payload binding for `name` declared in
## `[lower_bound, cursor_line]`: the binding with the greatest declaration line.
function arm_binding_type_for(
    analysis: ref[analyzer.Analysis],
    name: str,
    lower_bound: ptr_uint,
    cursor_line: ptr_uint,
) -> Option[types.Type]:
    var best_line: ptr_uint = 0
    var found = false
    var best_ty: types.Type = types.Type.ty_error
    let entries = unsafe: read(analysis).arm_binding_types
    var i: ptr_uint = 0
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        let entry = unsafe: read(ep)
        if entry.name.equal(name) and entry.line >= lower_bound and entry.line <= cursor_line and entry.line >= best_line:
            best_line = entry.line
            found = true
            best_ty = entry.ty
        i += 1
    if not found:
        return Option[types.Type].none
    return Option[types.Type].some(value = best_ty)


## The receiver type of `this` at `cursor_line`: the recorded `this` type of the
## nearest `extending` method declared at or before the cursor, when no function
## intervenes.  None when the cursor is not inside a non-static method.
function enclosing_this_type(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    cursor_line: ptr_uint,
) -> Option[types.Type]:
    var best_line: ptr_uint = 0
    var found = false
    var best_ty: types.Type = types.Type.ty_error
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                if fun.line <= cursor_line and fun.line >= best_line:
                    best_line = fun.line
                    found = false
            ast.Decl.decl_extending_block as ex:
                var mi: ptr_uint = 0
                while mi < ex.methods.len:
                    let m = unsafe: read(ex.methods.data + mi)
                    if m.line <= cursor_line and m.line >= best_line:
                        best_line = m.line
                        match this_type_for_line(analysis, m.line):
                            Option.some as tt:
                                found = true
                                best_ty = tt.value
                            Option.none:
                                found = false
                    mi += 1
            _:
                pass
        di += 1
    if not found:
        return Option[types.Type].none
    return Option[types.Type].some(value = best_ty)


## The recorded `this` type of the `extending` method declared on `line`.
function this_type_for_line(analysis: ref[analyzer.Analysis], line: ptr_uint) -> Option[types.Type]:
    var i: ptr_uint = 0
    let entries = unsafe: read(analysis).this_types
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        let entry = unsafe: read(ep)
        if entry.line == line:
            return Option[types.Type].some(value = entry.ty)
        i += 1
    return Option[types.Type].none


## The type of the local `name` declared in `stmt` at or before `cursor_line`:
## the recorded destructuring type, the analyzer's resolved declared type, or
## the inferred type of the initializer.
function find_local_type(
    analysis: ref[analyzer.Analysis],
    stmt: ast.Stmt,
    name: str,
    cursor_line: ptr_uint,
) -> Option[types.Type]:
    match stmt:
        ast.Stmt.stmt_local as loc:
            var binds_name = loc.name.equal(name)
            if not binds_name:
                match loc.destructure_bindings:
                    Option.some as names:
                        var ni: ptr_uint = 0
                        while ni < names.value.len:
                            if unsafe: read(names.value.data + ni).equal(name):
                                binds_name = true
                            ni += 1
                    Option.none:
                        pass
            if binds_name and loc.line <= cursor_line:
                # A destructuring binding carries its own per-name type.
                var di2: ptr_uint = 0
                let destructures = unsafe: read(analysis).destructure_types
                while di2 < destructures.len():
                    let ep = destructures.get(di2) else:
                        break
                    let entry = unsafe: read(ep)
                    if entry.line == loc.line and entry.name.equal(name):
                        return Option[types.Type].some(value = entry.ty)
                    di2 += 1
                return type_render.local_binding_type(analysis, stmt)
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


## The declarations in the host's AST order: the file's own list with the
## selected `when` branches' expanded declarations merged in by line (the host
## expands them in place, so `module_when_func` sits at its branch's position).
function merged_declarations(ast_file: ast.SourceFile, analysis: ref[analyzer.Analysis]) -> vec.Vec[ast.Decl]:
    var merged = vec.Vec[ast.Decl].create()
    let when_decls = unsafe: read(analysis).when_declarations
    var i: ptr_uint = 0
    var j: ptr_uint = 0
    while i < ast_file.declarations.len or j < when_decls.len:
        var take_when = false
        if i >= ast_file.declarations.len:
            take_when = true
        else if j < when_decls.len:
            let base_line = scope_mod.decl_start_line(unsafe: read(ast_file.declarations.data + i))
            let when_line = scope_mod.decl_start_line(unsafe: read(when_decls.data + j))
            take_when = when_line < base_line
        if take_when:
            unsafe:
                merged.push(read(when_decls.data + j))
            j += 1
        else:
            unsafe:
                merged.push(read(ast_file.declarations.data + i))
            i += 1
    return merged


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

    # The host's AST order: the file's declarations with the selected `when`
    # branches' expanded declarations merged in by line.
    var declarations = merged_declarations(ast_file, analysis)
    defer: declarations.release()

    # Functions, in declaration order.
    var di: ptr_uint = 0
    while di < declarations.len() and count < MAX_COMPLETION_ITEMS:
        let dp = declarations.get(di) else:
            break
        let decl = unsafe: read(dp)
        match decl:
            ast.Decl.decl_function as fun:
                if prefix_matches(fun.name, prefix):
                    emit_function_item(
                        ref_of(items_json), analysis, fun.name, fun.method_params, fun.return_type,
                        false, module_text, uri, ref_of(first), ref_of(count))
            # The host's `facts.functions` carries foreign/extern declarations
            # too; their signatures come from the analysis.
            ast.Decl.decl_extern_function as ef:
                if prefix_matches(ef.name, prefix):
                    emit_function_item(
                        ref_of(items_json), analysis, ef.name, span[ast.Param](), null,
                        ef.variadic, module_text, uri, ref_of(first), ref_of(count))
            ast.Decl.decl_foreign_function as ff:
                if prefix_matches(ff.name, prefix):
                    emit_function_item(
                        ref_of(items_json), analysis, ff.name, span[ast.Param](), null,
                        ff.variadic, module_text, uri, ref_of(first), ref_of(count))
            _:
                pass
        di += 1

    # Types: the prelude's and the resolved imports' first, then the file's.
    emit_import_type_items(
        ws, ref_of(items_json), analysis, uri, prefix, ref_of(first), ref_of(count))
    # The host registers the declared types first and the type aliases after
    # them, each in source order.
    di = 0
    while di < declarations.len() and count < MAX_COMPLETION_ITEMS:
        let dp2 = declarations.get(di) else:
            break
        emit_declared_type_item(ref_of(items_json), unsafe: read(dp2), false, uri, prefix, ref_of(first), ref_of(count))
        di += 1
    di = 0
    while di < declarations.len() and count < MAX_COMPLETION_ITEMS:
        let dp3 = declarations.get(di) else:
            break
        emit_declared_type_item(ref_of(items_json), unsafe: read(dp3), true, uri, prefix, ref_of(first), ref_of(count))
        di += 1

    # Imports (resolved only), the prelude pair first.  The file's own roots are
    # what resolve a project-local import (`import node` under `src/` with the
    # package's `source_root`), so the bucket must not use the bare workspace
    # root — without it `n`/`no`/`node` offered the local only and never the
    # module alias.
    emit_import_items(
        ws, analysis, ast_file, file_path, ref_of(items_json), uri, prefix, ref_of(first), ref_of(count))

    # Module-level values.  The host registers consts first, then vars — two
    # passes, each in source order.
    emit_module_value_items(
        ref_of(items_json), analysis, declarations.as_span(), true, "3_", module_text, uri, prefix, ref_of(first), ref_of(count))
    emit_module_value_items(
        ref_of(items_json), analysis, declarations.as_span(), false, "3_", module_text, uri, prefix, ref_of(first), ref_of(count))

    # Locals visible at the cursor.
    emit_local_binding_items(
        analysis, declarations.as_span(), line + 1, prefix, uri, module_text,
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
    variadic: bool,
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
        # The declared variadic flag: the analysis marks every foreign
        # signature variadic for argument checking, but the host renders only
        # the declaration's own `...`.
        if variadic:
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


## Emit the module-level `const` (`consts`) or `var` declarations, in source
## order — the host's `facts.values` registration order.
function emit_module_value_items(
    items_json: ref[string.String],
    analysis: ref[analyzer.Analysis],
    declarations: span[ast.Decl],
    consts: bool,
    sort_prefix: str,
    current_module: str,
    uri: str,
    prefix: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var di: ptr_uint = 0
    while di < declarations.len and unsafe: read(count) < MAX_COMPLETION_ITEMS:
        var decl: ast.Decl
        unsafe:
            decl = read(declarations.data + di)
        match decl:
            ast.Decl.decl_const as c:
                if consts and prefix_matches(c.name, prefix):
                    emit_value_item(
                        items_json, analysis, c.name, c.const_type, sort_prefix,
                        current_module, uri, first, count)
            ast.Decl.decl_var as v:
                if not consts and prefix_matches(v.name, prefix):
                    emit_value_item(
                        items_json, analysis, v.name, v.var_type, sort_prefix,
                        current_module, uri, first, count)
            _:
                pass
        di += 1


## Emit one type item for a declaration, in the host's kind mapping:
## non-generic enums/flags/variants are kind 13, everything else kind 7.
## `aliases` selects which pass the declaration belongs to: the host registers
## the declared types first and the type aliases after them.
function emit_declared_type_item(
    items_json: ref[string.String],
    decl: ast.Decl,
    aliases: bool,
    uri: str,
    prefix: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    match decl:
        ast.Decl.decl_struct as s:
            if aliases:
                return
            emit_type_item(items_json, s.name, KIND_CLASS, uri, prefix, first, count)
            emit_nested_type_items(items_json, s.nested_types, s.name, uri, prefix, first, count)
        ast.Decl.decl_union as u:
            if aliases:
                return
            emit_type_item(items_json, u.name, KIND_CLASS, uri, prefix, first, count)
        ast.Decl.decl_enum as e:
            if aliases:
                return
            emit_type_item(items_json, e.name, KIND_ENUM, uri, prefix, first, count)
        ast.Decl.decl_flags as fl:
            if aliases:
                return
            emit_type_item(items_json, fl.name, KIND_ENUM, uri, prefix, first, count)
        ast.Decl.decl_variant as vr:
            if aliases:
                return
            if vr.type_params.len == 0:
                emit_type_item(items_json, vr.name, KIND_ENUM, uri, prefix, first, count)
            else:
                emit_type_item(items_json, vr.name, KIND_CLASS, uri, prefix, first, count)
        ast.Decl.decl_type_alias as ta:
            if not aliases:
                return
            emit_type_item(items_json, ta.name, KIND_CLASS, uri, prefix, first, count)
        ast.Decl.decl_opaque as op:
            if aliases:
                return
            emit_type_item(items_json, op.name, KIND_CLASS, uri, prefix, first, count)
        _:
            pass


## Emit a struct's nested type declarations as `Parent.Child` (the host's
## `facts.types` keys them the same way), directly after the parent.
function emit_nested_type_items(
    items_json: ref[string.String],
    nested: span[ast.Decl],
    parent_name: str,
    uri: str,
    prefix: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var i: ptr_uint = 0
    while i < nested.len and unsafe: read(count) < MAX_COMPLETION_ITEMS:
        var d: ast.Decl
        unsafe:
            d = read(nested.data + i)
        match d:
            ast.Decl.decl_struct as s:
                var qualified = string.String.create()
                defer: qualified.release()
                qualified.append(parent_name)
                qualified.append(".")
                qualified.append(s.name)
                emit_type_item(items_json, qualified.as_str(), KIND_CLASS, uri, prefix, first, count)
                emit_nested_type_items(items_json, s.nested_types, qualified.as_str(), uri, prefix, first, count)
            _:
                pass
        i += 1


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
            let module_doc = workspace.document_analysis_for(ws, module_path.as_str()) else:
                return
            var module_file = module_doc.ast_file
            let exports_all = module_file.module_kind == ast.ModuleKind.module_raw
            var di: ptr_uint = 0
            while di < module_file.declarations.len and unsafe: read(count) < MAX_COMPLETION_ITEMS:
                var decl: ast.Decl
                unsafe:
                    decl = read(module_file.declarations.data + di)
                if decl_is_public_type(decl, exports_all):
                    emit_declared_type_item(items_json, decl, false, uri, prefix, first, count)
                di += 1
            di = 0
            while di < module_file.declarations.len and unsafe: read(count) < MAX_COMPLETION_ITEMS:
                var decl2: ast.Decl
                unsafe:
                    decl2 = read(module_file.declarations.data + di)
                if decl_is_public_type(decl2, exports_all):
                    emit_declared_type_item(items_json, decl2, true, uri, prefix, first, count)
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

    # Import declarations live in `ast_file.imports`, not in the declaration
    # list; iterating the wrong span is why no alias was ever offered.  The
    # label is the import's alias, or the path's last segment when none was
    # given (`import std.hash` binds `hash`).
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
                            if import_decl.path.parts.len > 0:
                                label = unsafe: read(import_decl.path.parts.data + import_decl.path.parts.len - 1)
                    emit_import_item(items_json, label, module_name, uri, prefix, first, count)
            _:
                pass
        ii += 1

    # The seeded prelude modules follow the walked imports, as the host's
    # `facts.imports` keys do.
    if unsafe: read(analysis).imports.contains("std.option"):
        emit_import_item(items_json, "std.option", "std.option", uri, prefix, first, count)
    if unsafe: read(analysis).imports.contains("std.result"):
        emit_import_item(items_json, "std.result", "std.result", uri, prefix, first, count)


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
    sort_prefix: str,
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
    sort_text.append(sort_prefix)
    sort_text.append(name)
    append_item_ext(
        items_json, name, KIND_VARIABLE, detail.as_str(), name, sort_text.as_str(), name, uri,
        0, "", "", first)
    unsafe:
        read(count) = read(count) + 1


## The function declaration enclosing a cursor line: the last one declared at
## or before it, with its body and AST parameters.
struct EnclosingFunction:
    line: ptr_uint
    name: str
    body: ptr[ast.Stmt]?
    params: span[ast.Param]


function enclosing_function_for(declarations: span[ast.Decl], cursor_line: ptr_uint) -> EnclosingFunction:
    var found = EnclosingFunction(
        line = 0, name = "", body = null, params = span[ast.Param]())
    var di: ptr_uint = 0
    while di < declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                if fun.line <= cursor_line and fun.line >= found.line:
                    found = EnclosingFunction(
                        line = fun.line, name = fun.name, body = fun.body,
                        params = fun.method_params)
            _:
                pass
        di += 1
    return found


## Emit the locals visible at `cursor_line`: the enclosing function's
## parameters and every `let`/`var` declared at or before the cursor, in
## declaration order.
function emit_local_binding_items(
    analysis: ref[analyzer.Analysis],
    declarations: span[ast.Decl],
    cursor_line: ptr_uint,
    prefix: str,
    uri: str,
    current_module: str,
    items_json: ref[string.String],
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    let enclosing = enclosing_function_for(declarations, cursor_line)
    var params = enclosing.params
    var pi: ptr_uint = 0
    while pi < params.len and unsafe: read(count) < MAX_COMPLETION_ITEMS:
        let p = unsafe: read(params.data + pi)
        if p.name.len > 0 and p.name != "_" and prefix_matches(p.name, prefix):
            emit_local_item(items_json, p.name, ast_formatter.render_type(p.param_type), "parameter ", "3_", uri, first, count)
        pi += 1

    if enclosing.body != null:
        emit_stmt_locals(
            analysis, unsafe: read(ptr[ast.Stmt]<-enclosing.body), cursor_line, prefix, uri,
            current_module, items_json, first, count)


## Emit one local binding item.
function emit_local_item(
    items_json: ref[string.String],
    name: str,
    type_text: str,
    detail_prefix: str,
    sort_prefix: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    if type_text.len == 0:
        return
    var detail = string.String.create()
    defer: detail.release()
    detail.append(detail_prefix)
    detail.append(name)
    detail.append(": ")
    detail.append(type_text)
    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append(sort_prefix)
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
                    emit_local_item(items_json, loc.name, type_text.as_str(), "", "3_", uri, first, count)
                else:
                    match type_render.initializer_type(analysis, loc.value):
                        Option.some as ty:
                            var type_text = type_render.qualified_name(ty.value, current_module)
                            defer: type_text.release()
                            emit_local_item(items_json, loc.name, type_text.as_str(), "", "3_", uri, first, count)
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


## The cursor line's text before byte column `character` (the host's
## `line_text[0...char]`).
function line_prefix(source: str, line: ptr_uint, character: ptr_uint) -> str:
    let line_text = cursor.source_line(source, line + 1)
    var pos = character
    if pos > line_text.len:
        pos = line_text.len
    return line_text.slice(0, pos)


## The built-in attributes the host lists before the file's declared ones.
const BUILTIN_ATTRIBUTES: array[str, 3] = array[str, 3]("packed", "align", "deprecated")


## Completions inside `@[...` — the host's `attribute_completions`: the three
## built-ins (sort `0_`), then every declared attribute (sort `1_`).
public function attribute_completion_items(
    analysis: ref[analyzer.Analysis],
    text: str,
    uri: str,
) -> ptr[string.String]?:
    var end = text.len
    var start = end
    while start > 0 and utils.is_word_byte(text.byte_at(start - 1)):
        start -= 1
    if start < 2:
        return null
    if text.byte_at(start - 2) != '@' or text.byte_at(start - 1) != '[':
        return null
    let prefix = text.slice(start, end - start)

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    var bi: ptr_uint = 0
    while bi < 3 and count < MAX_COMPLETION_ITEMS:
        let name = BUILTIN_ATTRIBUTES[bi]
        if prefix_matches(name, prefix):
            var detail = string.String.create()
            defer: detail.release()
            detail.append("built-in attribute ")
            detail.append(name)
            var sort_text = string.String.create()
            defer: sort_text.release()
            sort_text.append("0_")
            sort_text.append(name)
            append_item_ext(
                ref_of(items_json), name, KIND_KEYWORD, detail.as_str(), name,
                sort_text.as_str(), name, uri, 0, "", "", ref_of(first))
            count += 1
        bi += 1

    var entries = unsafe: read(analysis).declared_attributes.entries()
    while entries.next() and count < MAX_COMPLETION_ITEMS:
        let entry = entries.current()
        let name = unsafe: read(entry.key)
        if prefix_matches(name, prefix):
            var detail = string.String.create()
            defer: detail.release()
            detail.append("attribute ")
            detail.append(name)
            var sort_text = string.String.create()
            defer: sort_text.release()
            sort_text.append("1_")
            sort_text.append(name)
            append_item_ext(
                ref_of(items_json), name, KIND_KEYWORD, detail.as_str(), name,
                sort_text.as_str(), name, uri, 0, "", "", ref_of(first))
            count += 1

    items_json.append("]")
    if count == 0:
        items_json.release()
        return null
    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc


## The host's `format_string_completions`: inside a format-string interpolation
## (`f"...#{|}`) the host answers only the module values (sort `0_`), the module
## functions (sort `1_`) and the locals visible at the cursor (sort `2_`) — never
## the global bucket.  A `}` after the opener means the cursor is past the
## interpolation, so the branch declines.  `text` is the line prefix before the
## cursor.
public function format_string_completion_items(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    text: str,
    line: ptr_uint,
    uri: str,
) -> ptr[string.String]?:
    var open_pos: ptr_uint = 0
    var opened = false
    var i: ptr_uint = 0
    while i + 1 < text.len:
        if text.byte_at(i) == '#' and text.byte_at(i + 1) == '{':
            open_pos = i
            opened = true
        i += 1
    if not opened:
        return null
    var close = open_pos + 2
    while close < text.len:
        if text.byte_at(close) == '}':
            return null
        close += 1
    let prefix = text.slice(open_pos + 2, text.len - open_pos - 2)
    let current_module = unsafe: read(analysis).module_name

    var declarations = merged_declarations(ast_file, analysis)
    defer: declarations.release()

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    # The host's `facts.values` registration order: consts, then vars.
    emit_module_value_items(
        ref_of(items_json), analysis, declarations.as_span(), true, "0_",
        current_module, uri, prefix, ref_of(first), ref_of(count))
    emit_module_value_items(
        ref_of(items_json), analysis, declarations.as_span(), false, "0_",
        current_module, uri, prefix, ref_of(first), ref_of(count))

    # Functions, in declaration order.
    var di: ptr_uint = 0
    while di < declarations.len():
        let dp = declarations.get(di) else:
            break
        var decl: ast.Decl
        unsafe:
            decl = read(dp)
        match decl:
            ast.Decl.decl_function as fun:
                emit_format_function_item(
                    ref_of(items_json), fun.name, prefix, uri, ref_of(first), ref_of(count))
            ast.Decl.decl_extern_function as ef:
                emit_format_function_item(
                    ref_of(items_json), ef.name, prefix, uri, ref_of(first), ref_of(count))
            ast.Decl.decl_foreign_function as ff:
                emit_format_function_item(
                    ref_of(items_json), ff.name, prefix, uri, ref_of(first), ref_of(count))
            _:
                pass
        di += 1

    # The host's completion snapshot carries the enclosing function's
    # parameters and its function-level locals declared before the cursor; a
    # nested block's binding is not in it.
    emit_format_local_items(
        analysis, declarations.as_span(), line + 1, prefix, uri, current_module,
        ref_of(items_json), ref_of(first), ref_of(count))

    items_json.append("]")
    if count == 0:
        items_json.release()
        return null
    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc


## Emit one format-string function item: the host's `function <name>` detail
## with a plain name insert and the `1_` sort group (no signature or snippet).
function emit_format_function_item(
    items_json: ref[string.String],
    name: str,
    prefix: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    if not prefix_matches(name, prefix):
        return
    var detail = string.String.create()
    defer: detail.release()
    detail.append("function ")
    detail.append(name)
    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append("1_")
    sort_text.append(name)
    append_item_ext(
        items_json, name, KIND_FUNCTION, detail.as_str(), name, sort_text.as_str(), name, uri,
        0, "", "", first)
    unsafe:
        read(count) = read(count) + 1


## Emit the format-string locals in the host's snapshot order: the enclosing
## function's parameters, then its function-level `let`/`var` statements
## declared before the cursor (destructured names included).
function emit_format_local_items(
    analysis: ref[analyzer.Analysis],
    declarations: span[ast.Decl],
    cursor_line: ptr_uint,
    prefix: str,
    uri: str,
    current_module: str,
    items_json: ref[string.String],
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    let enclosing = enclosing_function_for(declarations, cursor_line)
    var params = enclosing.params
    let fn_name = enclosing.name

    # Parameters carry the analyzer's semantic types (the host snapshot's
    # binding type), so an imported or local struct type renders qualified.
    let sig_ptr = unsafe: read(analysis).functions.get(fn_name)
    if sig_ptr != null:
        let sig = unsafe: read(sig_ptr)
        var pi: ptr_uint = 0
        while pi < sig.params.len:
            let param = unsafe: read(sig.params.data + pi)
            if param.name.len > 0 and param.name != "_" and prefix_matches(param.name, prefix):
                var type_text = type_render.qualified_name(param.ty, current_module)
                emit_local_item(
                    items_json, param.name, type_text.as_str(), "", "2_", uri, first, count)
                type_text.release()
            pi += 1
    else:
        var pi: ptr_uint = 0
        while pi < params.len:
            let param = unsafe: read(params.data + pi)
            if param.name.len > 0 and param.name != "_" and prefix_matches(param.name, prefix):
                emit_local_item(
                    items_json, param.name, ast_formatter.render_type(param.param_type), "",
                    "2_", uri, first, count)
            pi += 1

    if enclosing.body == null:
        return
    match unsafe: read(ptr[ast.Stmt]<-enclosing.body):
        ast.Stmt.stmt_block as blk:
            var si: ptr_uint = 0
            while si < blk.statements.len:
                let stmt = unsafe: read(blk.statements.data + si)
                match stmt:
                    ast.Stmt.stmt_local as loc:
                        if loc.line < cursor_line:
                            match loc.destructure_bindings:
                                Option.some as names:
                                    var ni: ptr_uint = 0
                                    while ni < names.value.len:
                                        emit_format_local_binding(
                                            analysis, stmt, unsafe: read(names.value.data + ni),
                                            loc.stmt_type, loc.value, cursor_line, prefix, uri,
                                            current_module, items_json, first, count)
                                        ni += 1
                                Option.none:
                                    emit_format_local_binding(
                                        analysis, stmt, loc.name, loc.stmt_type, loc.value,
                                        cursor_line, prefix, uri, current_module,
                                        items_json, first, count)
                    _:
                        pass
                si += 1
        _:
            pass


## Emit one function-level local with the semantic type at the cursor; a
## destructured name resolves through the analysis' destructure record.
function emit_format_local_binding(
    analysis: ref[analyzer.Analysis],
    stmt: ast.Stmt,
    name: str,
    stmt_type: ptr[ast.TypeRef]?,
    value: ptr[ast.Expr]?,
    cursor_line: ptr_uint,
    prefix: str,
    uri: str,
    current_module: str,
    items_json: ref[string.String],
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    if name.len == 0 or name == "_" or not prefix_matches(name, prefix):
        return
    var type_text = string.String.create()
    defer: type_text.release()
    match find_local_type(analysis, stmt, name, cursor_line):
        Option.some as ty:
            var rendered = type_render.qualified_name(ty.value, current_module)
            type_text.append(rendered.as_str())
            rendered.release()
        Option.none:
            if stmt_type != null:
                append_ast_type(ref_of(type_text), stmt_type, "")
            else:
                match type_render.initializer_type(analysis, value):
                    Option.some as inited:
                        var inferred = type_render.qualified_name(inited.value, current_module)
                        type_text.append(inferred.as_str())
                        inferred.release()
                    Option.none:
                        return
    emit_local_item(items_json, name, type_text.as_str(), "", "2_", uri, first, count)


## True when `name` appears before an `=` or `:` in `text` — the host's
## `already_provided` scan in `named_argument_completions`.
function name_already_provided(text: str, name: str) -> bool:
    var i: ptr_uint = 0
    while i < text.len:
        if utils.is_word_byte(text.byte_at(i)):
            let start = i
            while i < text.len and utils.is_word_byte(text.byte_at(i)):
                i += 1
            let end = i
            var after = end
            while after < text.len and (text.byte_at(after) == ' ' or text.byte_at(after) == '\t'):
                after += 1
            if after < text.len and (text.byte_at(after) == '=' or text.byte_at(after) == ':'):
                if text.slice(start, end - start).equal(name):
                    return true
        else:
            i += 1
    return false


## Emit one named-argument item: label and insert `name = `, `0_` sort.
function emit_named_argument_item(
    items_json: ref[string.String],
    name: str,
    kind: int,
    type_text: str,
    uri: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    var label = string.String.create()
    defer: label.release()
    label.append(name)
    label.append(" = ")
    var detail = string.String.create()
    defer: detail.release()
    detail.append(name)
    detail.append(": ")
    detail.append(type_text)
    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append("0_")
    sort_text.append(name)
    append_item_ext(
        items_json, label.as_str(), kind, detail.as_str(), label.as_str(),
        sort_text.as_str(), name, uri, 0, "", "", first)
    unsafe:
        read(count) = read(count) + 1


## Completions for a call's argument list — the host's
## `named_argument_completions`: `name = ` labels for the callee's parameters
## (kind 14) or, for a type constructor, its fields (kind 8), skipping names
## already provided.  The callee is the innermost unclosed call's name.
public function named_argument_completion_items(
    analysis: ref[analyzer.Analysis],
    text: str,
    prefix: str,
    uri: str,
) -> ptr[string.String]?:
    var paren: ptr_uint = 0
    var found = false
    var i: ptr_uint = 0
    while i < text.len:
        if text.byte_at(i) == '(':
            var j = i + 1
            var closed = false
            while j < text.len:
                if text.byte_at(j) == ')':
                    closed = true
                    break
                j += 1
            if not closed:
                paren = i
                found = true
        i += 1
    if not found:
        return null

    # The host answers only a fresh call or one ending in a comma.
    var tail = text.len
    while tail > paren + 1 and (text.byte_at(tail - 1) == ' ' or text.byte_at(tail - 1) == '\t'):
        tail -= 1
    if tail > paren + 1 and text.byte_at(tail - 1) != ',':
        return null

    var end = paren
    while end > 0 and (text.byte_at(end - 1) == ' ' or text.byte_at(end - 1) == '\t'):
        end -= 1
    var start = end
    while start > 0 and (utils.is_word_byte(text.byte_at(start - 1)) or text.byte_at(start - 1) == '.'):
        start -= 1
    if start == end:
        return null
    let callee = text.slice(start, end - start)

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0

    let sig_ptr = unsafe: read(analysis).functions.get(callee)
    if sig_ptr != null:
        let sig = unsafe: read(sig_ptr)
        var pi: ptr_uint = 0
        while pi < sig.params.len and count < MAX_COMPLETION_ITEMS:
            let param = unsafe: read(sig.params.data + pi)
            if prefix_matches(param.name, prefix) and not name_already_provided(text, param.name):
                emit_named_argument_item(
                    ref_of(items_json), param.name, KIND_KEYWORD,
                    types.type_to_string(param.ty), uri, ref_of(first), ref_of(count))
            pi += 1

    var fields: span[analyzer.FieldEntry] = span[analyzer.FieldEntry]()
    let ty_ptr = unsafe: read(analysis).types.get(callee)
    if ty_ptr != null:
        let type_name = navigation.type_to_key_name(unsafe: read(ty_ptr))
        let struct_fields = unsafe: read(analysis).structs.get(type_name)
        if struct_fields != null:
            fields = unsafe: read(struct_fields)
        else:
            let union_fields = unsafe: read(analysis).unions.get(type_name)
            if union_fields != null:
                fields = unsafe: read(union_fields)
    else:
        # A module-qualified type constructor (`node.Node(`).
        let dot = callee.find_byte('.')
        match dot:
            Option.some as dot_pos:
                let alias = callee.slice(0, dot_pos.value)
                let type_name = callee.slice(dot_pos.value + 1, callee.len - dot_pos.value - 1)
                let module_ptr = unsafe: read(analysis).imports.get(alias)
                if module_ptr != null:
                    var key = string.String.create()
                    defer: key.release()
                    key.append(unsafe: read(module_ptr))
                    key.append(".")
                    key.append(type_name)
                    let members_ptr = unsafe: read(analysis).imported_type_members.get(key.as_str())
                    if members_ptr != null:
                        fields = unsafe: read(members_ptr).fields
            Option.none:
                pass

    var fi: ptr_uint = 0
    while fi < fields.len and count < MAX_COMPLETION_ITEMS:
        let field = unsafe: read(fields.data + fi)
        if prefix_matches(field.name, prefix) and not name_already_provided(text, field.name):
            emit_named_argument_item(
                ref_of(items_json), field.name, KIND_FIELD,
                types.type_to_string(field.ty), uri, ref_of(first), ref_of(count))
        fi += 1

    items_json.append("]")
    if count == 0:
        items_json.release()
        return null
    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc


## Completions inside `name[...` — the host's `specialization_completions`:
## every visible type as a `0_` type item.
## The host's `facts.types` registration order: the built-in primitives, the
## vector and matrix families, the event types, the handle types, the type meta
## type and the prelude variants, then the module's own declarations.
const SPECIALIZATION_TYPE_ORDER: array[str, 36] = array[str, 36](
    "bool", "byte", "ubyte", "char", "short", "ushort",
    "int", "uint", "long", "ulong", "ptr_int", "ptr_uint",
    "float", "double", "void", "str", "cstr",
    "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4",
    "mat3", "mat4", "quat",
    "Subscription", "EventError",
    "struct_handle", "field_handle", "callable_handle", "attribute_handle",
    "member_handle", "type",
    "Option", "Result",
)


public function specialization_completion_items(
    analysis: ref[analyzer.Analysis],
    text: str,
    uri: str,
) -> ptr[string.String]?:
    var bracket: ptr_uint = 0
    var found = false
    var i: ptr_uint = 0
    while i < text.len:
        if text.byte_at(i) == '[':
            if i > 0 and (utils.is_word_byte(text.byte_at(i - 1)) or text.byte_at(i - 1) == '.'):
                bracket = i
                found = true
        i += 1
    if not found:
        return null
    let prefix = text.slice(bracket + 1, text.len - bracket - 1)

    var items_json = string.String.create()
    items_json.append("[")
    var first = true
    var count: ptr_uint = 0
    var emitted = map_mod.Map[str, bool].create()
    defer: emitted.release()

    # The host's registration order: the built-ins and the prelude first, then
    # the module's declared types in declaration order, then any remaining
    # entry the analysis carries (map bucket order).
    var bi: ptr_uint = 0
    while bi < 36 and count < MAX_COMPLETION_ITEMS:
        let name = SPECIALIZATION_TYPE_ORDER[bi]
        if unsafe: read(analysis).types.contains(name) and not emitted.contains(name):
            emit_specialization_type_item(ref_of(items_json), name, uri, prefix, ref_of(first), ref_of(count))
            emitted.set(name, true)
        bi += 1
    let module_types = unsafe: read(analysis).module_type_order
    var mi: ptr_uint = 0
    while mi < module_types.len() and count < MAX_COMPLETION_ITEMS:
        let entry = module_types.get(mi) else:
            break
        let name = unsafe: read(entry)
        if not emitted.contains(name):
            emit_specialization_type_item(ref_of(items_json), name, uri, prefix, ref_of(first), ref_of(count))
            emitted.set(name, true)
        mi += 1
    var entries = unsafe: read(analysis).types.entries()
    while entries.next() and count < MAX_COMPLETION_ITEMS:
        let entry = entries.current()
        let name = unsafe: read(entry.key)
        if not emitted.contains(name):
            emit_specialization_type_item(ref_of(items_json), name, uri, prefix, ref_of(first), ref_of(count))
            emitted.set(name, true)

    items_json.append("]")
    if count == 0:
        items_json.release()
        return null
    let alloc = heap.must_alloc[string.String](1)
    unsafe: read(alloc) = wrap_completion_result(ref_of(items_json), count >= MAX_COMPLETION_ITEMS)
    return alloc


## Emit one specialization type item (`type <name>`, sort `0_`).
function emit_specialization_type_item(
    items_json: ref[string.String],
    name: str,
    uri: str,
    prefix: str,
    first: ref[bool],
    count: ref[ptr_uint],
) -> void:
    if not prefix_matches(name, prefix):
        return
    var detail = string.String.create()
    defer: detail.release()
    detail.append("type ")
    detail.append(name)
    var sort_text = string.String.create()
    defer: sort_text.release()
    sort_text.append("0_")
    sort_text.append(name)
    append_item_ext(
        items_json, name, KIND_MODULE_TYPE, detail.as_str(), name,
        sort_text.as_str(), name, uri, 0, "", "", first)
    unsafe:
        read(count) = read(count) + 1


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
    # A method-only entry (the module extends but does not declare the type) is
    # not a type receiver the host resolves from `module_binding.types`.
    let member_ptr = a.imported_type_members.get(key.as_str())
    if member_ptr != null and unsafe: read(member_ptr).declared:
        return true
    # An imported enum/flags/variant's members are merged into `member_names`
    # under the bare name.
    return a.member_names.contains(type_name)


## Resolve a receiver name to its Milk Tea type name (e.g. "v" → "Vec").
public function resolve_receiver_type_name(analysis: ref[analyzer.Analysis], name: str) -> str:
    unsafe:
        let a = read(analysis)

        let tp = a.types.get(name)
        if tp != null:
            let t = read(tp)
            return navigation.type_to_key_name(t)

        if a.type_names.contains(name):
            return name

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
