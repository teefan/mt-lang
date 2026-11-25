## Diagnostics collection — runs the full check pipeline on a source file and
## converts errors/warnings into LSP Diagnostic JSON.  Reuses check_program()
## from the module loader, mirroring the CLI's `mtc check` path.

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver
import mtc.linter.linter as linter_mod
import mtc.linter.scope_tracking as scope_tracking
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.utils as utils
import mtc.lsp.workspace as workspace

## LSP Diagnostic severity values.
const SEVERITY_ERROR: double = 1.0
const SEVERITY_WARNING: double = 2.0
const SEVERITY_INFO: double = 3.0
const SEVERITY_HINT: double = 4.0

## LSP TextDocumentSyncKind: Full = 1.
const SYNC_FULL: double = 1.0


## Build a JSON Array of LSP Diagnostic objects from a loaded and checked Program.
## Only diagnostics that belong to `root_path` are returned (the loader also
## reports on imported modules and the prelude), matching the Ruby LSP's
## per-document pull.  `uri` is the document's client URI — parse/lex messages
## embed it in their location suffix.  `source` is the document's text — passed
## to the loader so an unsaved editor buffer is analyzed instead of the file on
## disk.
public function collect_diagnostics(ws: ref[workspace.Workspace], uri: str, root_path: str, source: str) -> json.Value:
    # Reuse the workspace's loader-backed analysis: it is the same program the
    # other requests see, built once per content version instead of once per
    # request (a large file's import closure costs ~70 ms).
    let entry_ptr = workspace.analysis_entry_for(ws, root_path) else:
        return json.create_array_value()
    var program = unsafe: read(entry_ptr).program

    var diag_array = json.create_array_value()
    let array_ptr = diag_array.as_array() else:
        return diag_array

    var i: ptr_uint = 0
    while i < program.diagnostics.len():
        let d_ptr = program.diagnostics.get(i) else:
            break
        unsafe:
            let d = read(d_ptr)
            if d.path.as_str().equal(root_path):
                let diag = diagnostic_from_load_diagnostic(ws, d, source, uri)
                if not diag.is_null():
                    read(array_ptr).push(diag)

        i += 1

    # Lint the root module's source file.
    var lint_warnings = vec.Vec[linter_mod.Warning].create()
    var root_source: str = ""
    # Only lint when the root module parsed and checked successfully.  The
    # root's ANALYSIS is last in dependency order, but `modules` is filled in
    # DFS pre-order, so the root MODULE is found through the order vector
    # (order.last() indexes the root), not modules.last().
    if program.analyses.len() > 0 and program.modules.len() > 0 and program.order.len() > 0:
        let last_analysis_ptr = program.analyses.get(program.root_index) else:
            return diag_array
        let root_index_ptr = program.order.last() else:
            return diag_array
        let root_module_ptr = program.modules.get(unsafe: read(root_index_ptr)) else:
            return diag_array
        unsafe:
            root_source = read(root_module_ptr).source.as_str()
            var unresolved = vec.Vec[str].create()
            defer: unresolved.release()
            var ui: ptr_uint = 0
            while ui < program.unresolved_import_paths.len():
                let up = program.unresolved_import_paths.get(ui) else:
                    break
                unresolved.push(read(up).as_str())
                ui += 1
            var options = linter_mod.default_lint_options()
            options.owning_type_names = program.owning_type_span()
            options.unresolved_import_paths = unresolved.as_span()
            options.editable_sites = read(last_analysis_ptr).editable_receiver_sites.as_span()
            options.mutating_sites = read(last_analysis_ptr).mutating_argument_sites.as_span()
            options.mutable_lvalue_sites = read(last_analysis_ptr).mutable_lvalue_sites.as_span()
            options.directional_ffi_sites = read(last_analysis_ptr).directional_ffi_sites.as_span()
            options.analysis = last_analysis_ptr
            var providers = scope_tracking.build_import_method_providers(
                read(last_analysis_ptr).source_file,
                program.analyses.as_span()
            )
            defer: providers.release()
            options.method_providers = providers.as_span()
            lint_warnings = linter_mod.lint_source_with(
                read(last_analysis_ptr).source_file,
                root_source,
                root_path,
                options,
            )

    var wi: ptr_uint = 0
    while wi < lint_warnings.len():
        let w_ptr = lint_warnings.get(wi) else:
            break
        unsafe:
            let w = read(w_ptr)
            let diag = diagnostic_from_warning(ws, w, root_source)
            if not diag.is_null():
                read(array_ptr).push(diag)

        wi += 1

    lint_warnings.release()
    return diag_array


## Publish diagnostics for a file via an LSP notification.
## Uses the textDocument/publishDiagnostics notification.
public function publish_for_uri(ws: ref[workspace.Workspace], uri: str, root_path: str, source: str) -> void:
    if ws.pull_diagnostics_active:
        return
    var diagnostics = collect_diagnostics(ws, uri, root_path, source)

    var params = json.create_object_value()
    defer: json.release_value(params)
    let params_obj = params.as_object() else:
        json.release_value(diagnostics)
        return

    unsafe:
        read(params_obj).set("uri", json.string_from_str(uri))
        read(params_obj).set("diagnostics", diagnostics)
        match ws.document_version(root_path):
            Option.some as version:
                read(params_obj).set("version", json.number_value(double<-version.value))
            Option.none:
                pass

    proto.write_notification("textDocument/publishDiagnostics", params)


## Publish an empty diagnostics array for `uri` (clear diagnostics on close).
public function publish_empty_for_uri(ws: ref[workspace.Workspace], uri: str) -> void:
    if ws.pull_diagnostics_active:
        return
    var params = json.create_object_value()
    defer: json.release_value(params)

    let params_obj = params.as_object() else:
        return

    var empty_diag = json.create_array_value()
    unsafe:
        read(params_obj).set("uri", json.string_from_str(uri))
        read(params_obj).set("diagnostics", empty_diag)
        match uri_ops.file_uri_to_path(uri):
            Option.some as path:
                match ws.document_version(path.value.as_str()):
                    Option.some as version:
                        read(params_obj).set("version", json.number_value(double<-version.value))
                    Option.none:
                        pass
                path.value.release()
            Option.none:
                pass

    proto.write_notification("textDocument/publishDiagnostics", params)


## Convert a LoadDiagnostic to an LSP Diagnostic JSON Value, mirroring the Ruby
## LSP's shape (`lib/milk_tea/lsp/diagnostics.rb`): the code is re-derived for the
## client (`module/error` -> `import/load-error`), `data.stage` carries the
## pipeline stage, the range spans the offending token, import failures anchor at
## the module path text, parse/lex messages carry the error's own location
## suffix, and sema messages that quote identifiers become MarkupContent.
function diagnostic_from_load_diagnostic(
    ws: ref[workspace.Workspace],
    d: loader.LoadDiagnostic,
    source: str,
    uri: str
) -> json.Value:
    var diag = json.create_object_value()
    let diag_obj = diag.as_object() else:
        return json.null_value()

    let line_zero = if d.line > 0: ptr_uint<-(int<-(d.line) - 1) else: 0z
    var start_char = if d.column > 0: ptr_uint<-(int<-(d.column) - 1) else: 0z
    var length = d.length
    if d.code.equal("module/error") and d.symbol_name.len() > 0:
        start_char = import_path_start(d, source)
        length = d.symbol_name.len()
    if length == 0:
        length = 1
    if ws.position_encoding_utf16:
        let line_text = utils.source_line(source, line_zero + 1)
        let end_byte = start_char + length
        start_char = utils.byte_to_utf16_column(line_text, start_char)
        length = utils.byte_to_utf16_column(line_text, end_byte) - start_char

    let lsp_code = lsp_code_for(d.code)
    let stage = stage_for(d.code)

    var range = json.create_object_value()
    let range_obj = range.as_object() else:
        json.release_value(diag)
        return json.null_value()

    var start_pos = json.create_object_value()
    let start_obj = start_pos.as_object() else:
        json.release_value(range)
        json.release_value(diag)
        return json.null_value()

    var end_pos = json.create_object_value()
    let end_obj = end_pos.as_object() else:
        json.release_value(start_pos)
        json.release_value(range)
        json.release_value(diag)
        return json.null_value()

    unsafe:
        read(start_obj).set("line", json.number_value(double<-line_zero))
        read(start_obj).set("character", json.number_value(double<-start_char))
        read(end_obj).set("line", json.number_value(double<-line_zero))
        read(end_obj).set("character", json.number_value(double<-(start_char + length)))

        read(range_obj).set("start", start_pos)
        read(range_obj).set("end", end_pos)

        read(diag_obj).set("range", range)

        var severity = SEVERITY_ERROR
        if d.severity == "warning":
            severity = SEVERITY_WARNING
        else if d.severity == "info":
            severity = SEVERITY_INFO
        else if d.severity == "hint":
            severity = SEVERITY_HINT

        read(diag_obj).set("severity", json.number_value(severity))
        read(diag_obj).set("source", json.string_from_str("milk-tea"))

        if lsp_code.len > 0:
            read(diag_obj).set("code", json.string_from_str(lsp_code))

        if d.message.len() > 0:
            read(diag_obj).set("message", client_message_value(d.message.as_str(), lsp_code, uri, d.line, d.column))

        var data = json.create_object_value()
        let data_obj = data.as_object() else:
            return diag
        read(data_obj).set("stage", json.string_from_str(stage))
        read(diag_obj).set("data", data)

    return diag


## The client-facing diagnostic code for a loader code: the host re-derives
## `import/load-error` for load failures; everything else passes through.
function lsp_code_for(code: str) -> str:
    if code.equal("module/error"):
        return "import/load-error"
    return code


## The pipeline stage for a loader code (host `diagnostic_stage`), surfaced as
## `data.stage`.
function stage_for(code: str) -> str:
    if code.equal("lex/error"):
        return "lex"
    if code.equal("parse/error"):
        return "parse"
    if code.equal("module/error"):
        return "import"
    if code.equal("sema/error"):
        return "sema"
    return "tooling"


## The client-facing `message` value.  A parse/lex message keeps its plain text
## plus the host's ` at <uri>:<line>:<col>` suffix (its error constructors embed
## the path they were built with — the document URI under the LSP).  A sema
## message that quotes identifiers with backticks or single quotes becomes a
## MarkupContent object, mirroring the host's `diagnostic_message_to_client`;
## every other message stays a string.
function client_message_value(message: str, lsp_code: str, uri: str, line: ptr_uint, column: ptr_uint) -> json.Value:
    if lsp_code.equal("parse/error") or lsp_code.equal("lex/error"):
        var suffixed = with_location_suffix(message, uri, line, column)
        defer: suffixed.release()
        return json.string_from_str(suffixed.as_str())

    if not lsp_code.starts_with("sema") or not message_has_identifier_span(message):
        return json.string_from_str(message)

    var markup = json.create_object_value()
    let markup_obj = markup.as_object() else:
        return json.string_from_str(message)
    unsafe:
        read(markup_obj).set("kind", json.string_from_str("markdown"))
        read(markup_obj).set("value", json.string_from_str(message))
    return markup


## `<message> at <uri>:<line>:<column>` — the host builds this in `ParseError`
## and `LexError` from the path and 1-based token position.
function with_location_suffix(message: str, uri: str, line: ptr_uint, column: ptr_uint) -> string.String:
    var buf = string.String.create()
    buf.append(message)
    buf.append(" at ")
    buf.append(uri)
    buf.append_format(f":#{line}:#{column}")
    return buf


## True when the message contains a backticked span or a quoted identifier
## (host `diagnostic_message_to_client`'s two scans).
function message_has_identifier_span(message: str) -> bool:
    if message.find_substring("`").is_some():
        return true
    var i: ptr_uint = 0
    while i < message.len:
        if message.byte_at(i) == 39:
            var j = i + 1
            if j < message.len and is_ascii_name_start(message.byte_at(j)):
                j += 1
                while j < message.len and is_ascii_name_or_dot(message.byte_at(j)):
                    j += 1
                if j < message.len and message.byte_at(j) == 39:
                    return true
            i = j
        else:
            i += 1
    return false


function is_ascii_name_start(b: ubyte) -> bool:
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or b == '_'


function is_ascii_name_or_dot(b: ubyte) -> bool:
    return is_ascii_name_start(b) or (b >= '0' and b <= '9') or b == 46


## 0-based character column where an import's module path text starts on the
## diagnostic's line (`import_path_span`); the diagnostic's own column when the
## line or the text cannot be found.
function import_path_start(d: loader.LoadDiagnostic, source: str) -> ptr_uint:
    let fallback = if d.column > 0: ptr_uint<-(int<-(d.column) - 1) else: 0z
    if d.symbol_name.len() == 0 or source.len == 0 or d.line == 0:
        return fallback

    var line_start: ptr_uint = 0
    var line_no: ptr_uint = 1
    var i: ptr_uint = 0
    while i <= source.len:
        if i == source.len or source.byte_at(i) == 10:
            if line_no == d.line:
                let line_text = source.slice(line_start, i - line_start)
                match line_text.find_substring(d.symbol_name.as_str()):
                    Option.some as idx:
                        return idx.value
                    Option.none:
                        return fallback
            line_start = i + 1
            line_no += 1
        i += 1
    return fallback


## Convert a linter Warning to an LSP Diagnostic JSON Value.  Warnings carry
## line numbers only, so the character range is recovered by locating the
## message's quoted symbol on that line — mirroring the Ruby LSP's
## `extract_warning_range` fallback.  When no symbol is found, the range is
## [0, 1] like Ruby's.
function diagnostic_from_warning(ws: ref[workspace.Workspace], w: linter_mod.Warning, source: str) -> json.Value:
    var diag = json.create_object_value()
    let diag_obj = diag.as_object() else:
        return json.null_value()

    let line_zero = if w.line > 0: ptr_uint<-(int<-(w.line) - 1) else: 0z

    var start_char: ptr_uint = 0
    var end_char: ptr_uint = 1
    if w.column > 0:
        # The host's `extract_warning_range`: a tracked column with no length
        # spans one character (`len = 1 if len <= 0`); the quoted-symbol search
        # below is only for warnings that carry no column at all.
        start_char = w.column - 1
        end_char = start_char + (if w.length > 0: w.length else: 1z)
    else:
        let name = extract_quoted_name(w.message)
        if name.len > 0 and source.len > 0:
            let search_line = if w.line > 0: w.line else: ptr_uint<-1
            var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
            defer: lex_diags.release()
            var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
            defer: tokens.release()
            var ti: ptr_uint = 0
            while ti < tokens.len:
                let tp = tokens.get(ti) else:
                    break
                let tok = unsafe: read(tp)
                if tok.line > search_line:
                    break
                if tok.line == search_line:
                    let lexeme = unsafe: token_mod.token_lexeme(tok, source)
                    if lexeme.equal(name):
                        start_char = tok.column - 1
                        end_char = start_char + (tok.end_offset - tok.start_offset)
                        break
                ti += 1
    if ws.position_encoding_utf16:
        let line_text = utils.source_line(source, line_zero + 1)
        start_char = utils.byte_to_utf16_column(line_text, start_char)
        end_char = utils.byte_to_utf16_column(line_text, end_char)

    var range = json.create_object_value()
    let range_obj = range.as_object() else:
        json.release_value(diag)
        return json.null_value()

    var start_pos = json.create_object_value()
    let start_obj = start_pos.as_object() else:
        json.release_value(range)
        json.release_value(diag)
        return json.null_value()

    var end_pos = json.create_object_value()
    let end_obj = end_pos.as_object() else:
        json.release_value(start_pos)
        json.release_value(range)
        json.release_value(diag)
        return json.null_value()

    unsafe:
        read(start_obj).set("line", json.number_value(double<-line_zero))
        read(start_obj).set("character", json.number_value(double<-start_char))
        read(end_obj).set("line", json.number_value(double<-line_zero))
        read(end_obj).set("character", json.number_value(double<-end_char))

        read(range_obj).set("start", start_pos)
        read(range_obj).set("end", end_pos)

        read(diag_obj).set("range", range)

        var severity = SEVERITY_WARNING
        if w.severity == "error":
            severity = SEVERITY_ERROR
        else if w.severity == "info":
            severity = SEVERITY_INFO
        else if w.severity == "hint":
            severity = SEVERITY_HINT

        read(diag_obj).set("severity", json.number_value(severity))
        read(diag_obj).set("source", json.string_from_str("milk-tea"))

        if w.code.len > 0:
            read(diag_obj).set("code", json.string_from_str(w.code))

        if w.message.len > 0:
            read(diag_obj).set("message", json.string_from_str(w.message))

        var data = json.create_object_value()
        let data_obj = data.as_object() else:
            return diag
        read(data_obj).set("stage", json.string_from_str("lint"))
        read(diag_obj).set("data", data)

    return diag


## The default host platform for module resolution (Linux on the current host).
function default_platform() -> resolver.Platform:
    return resolver.Platform.linux


## The first single-quoted 'name' in a warning message, or "" when absent.
## Linter messages consistently quote the symbol they refer to, e.g.
## "unused local 'x'" or "assigned value 'total' is never read".
function extract_quoted_name(message: str) -> str:
    var i: ptr_uint = 0
    while i < message.len:
        if message.byte_at(i) == '\'':
            var j = i + 1
            while j < message.len and message.byte_at(j) != '\'':
                j += 1
            if j < message.len and j > i + 1:
                return message.slice(i + 1, j - i - 1)
            return ""
        i += 1
    return ""
