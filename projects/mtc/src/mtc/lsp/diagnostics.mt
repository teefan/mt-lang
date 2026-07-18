## Diagnostics collection — runs the full check pipeline on a source file and
## converts errors/warnings into LSP Diagnostic JSON.  Reuses check_program()
## from the module loader, mirroring the CLI's `mtc check` path.

import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver
import mtc.linter.linter as linter_mod
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto


## LSP Diagnostic severity values.
const SEVERITY_ERROR:   double = 1.0
const SEVERITY_WARNING: double = 2.0
const SEVERITY_INFO:    double = 3.0
const SEVERITY_HINT:    double = 4.0

## LSP TextDocumentSyncKind: Full = 1.
const SYNC_FULL: double = 1.0


## Build a JSON Array of LSP Diagnostic objects from a loaded and checked Program.
## Filters diagnostics to only those that belong to `root_path`.
public function collect_diagnostics(root_path: str, roots: span[str]) -> json.Value:
    var platform = default_platform()
    var program = loader.check_program(root_path, roots, platform)

    var diag_array = json.create_array_value()
    let array_ptr = diag_array.as_array() else:
        program.release()
        return diag_array

    var i: ptr_uint = 0
    while i < program.diagnostics.len():
        let d_ptr = program.diagnostics.get(i) else:
            break
        unsafe:
            let d = read(d_ptr)
            let diag = diagnostic_from_load_diagnostic(d)
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
        let last_analysis_ptr = program.analyses.last() else:
            program.release()
            return diag_array
        let root_index_ptr = program.order.last() else:
            program.release()
            return diag_array
        let root_module_ptr = program.modules.get(unsafe: read(root_index_ptr)) else:
            program.release()
            return diag_array
        unsafe:
            root_source = read(root_module_ptr).source.as_str()
            lint_warnings = linter_mod.lint_source(
                read(last_analysis_ptr).source_file,
                root_source,
                root_path,
                program.owning_type_span()
            )

    var wi: ptr_uint = 0
    while wi < lint_warnings.len():
        let w_ptr = lint_warnings.get(wi) else:
            break
        unsafe:
            let w = read(w_ptr)
            let diag = diagnostic_from_warning(w, root_source)
            if not diag.is_null():
                read(array_ptr).push(diag)

        wi += 1

    lint_warnings.release()
    program.release()
    return diag_array


## Publish diagnostics for a file via an LSP notification.
## Uses the textDocument/publishDiagnostics notification.
public function publish_for_uri(uri: str, root_path: str, roots: span[str]) -> void:
    var diagnostics = collect_diagnostics(root_path, roots)

    var params = json.create_object_value()
    let params_obj = params.as_object() else:
        json.release_value(diagnostics)
        return

    unsafe:
        read(params_obj).set("uri", json.string_from_str(uri))
        read(params_obj).set("diagnostics", diagnostics)

    proto.write_notification("textDocument/publishDiagnostics", params)


## Publish an empty diagnostics array for `uri` (clear diagnostics on close).
public function publish_empty_for_uri(uri: str) -> void:
    var params = json.create_object_value()
    defer json.release_value(params)

    let params_obj = params.as_object() else:
        return

    var empty_diag = json.create_array_value()
    unsafe:
        read(params_obj).set("uri", json.string_from_str(uri))
        read(params_obj).set("diagnostics", empty_diag)

    proto.write_notification("textDocument/publishDiagnostics", params)


## Convert a LoadDiagnostic to an LSP Diagnostic JSON Value.  The range starts
## at the diagnostic's column and spans one character, mirroring the Ruby
## LSP's `format_error`.
function diagnostic_from_load_diagnostic(d: loader.LoadDiagnostic) -> json.Value:
    var diag = json.create_object_value()
    let diag_obj = diag.as_object() else:
        return json.null_value()

    let line_zero = if d.line > 0: ptr_uint<-(int<-(d.line) - 1) else: 0z
    let start_char = if d.column > 0: ptr_uint<-(int<-(d.column) - 1) else: 0z

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
        read(end_obj).set("character", json.number_value(double<-(start_char + 1)))

        read(range_obj).set("start", start_pos)
        read(range_obj).set("end", end_pos)

        read(diag_obj).set("range", range)

        var severity = SEVERITY_ERROR
        if d.severity == "warning":
            severity = SEVERITY_WARNING
        else if d.severity == "info" or d.severity == "hint":
            severity = SEVERITY_INFO

        read(diag_obj).set("severity", json.number_value(severity))
        read(diag_obj).set("source", json.string_from_str("milk-tea"))

        if d.code.len > 0:
            read(diag_obj).set("code", json.string_from_str(d.code))

        if d.message.len() > 0:
            read(diag_obj).set("message", json.string_from_str(d.message.as_str()))

    return diag


## Convert a linter Warning to an LSP Diagnostic JSON Value.  Warnings carry
## line numbers only, so the character range is recovered by locating the
## message's quoted symbol on that line — mirroring the Ruby LSP's
## `extract_warning_range` fallback.  When no symbol is found, the range is
## [0, 1] like Ruby's.
function diagnostic_from_warning(w: linter_mod.Warning, source: str) -> json.Value:
    var diag = json.create_object_value()
    let diag_obj = diag.as_object() else:
        return json.null_value()

    let line_zero = if w.line > 0: ptr_uint<-(int<-(w.line) - 1) else: 0z

    var start_char: ptr_uint = 0
    var end_char: ptr_uint = 1
    let name = extract_quoted_name(w.message)
    if name.len > 0 and source.len > 0:
        let line_text = cursor.source_line(source, w.line)
        match cursor.token_start_in_line(line_text, name):
            Option.some as pos:
                start_char = pos.value
                end_char = pos.value + name.len
            Option.none:
                pass

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
        if message.byte_at(i) == 39:
            var j = i + 1
            while j < message.len and message.byte_at(j) != 39:
                j += 1
            if j < message.len and j > i + 1:
                return message.slice(i + 1, j - i - 1)
            return ""
        i += 1
    return ""
