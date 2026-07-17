## Diagnostics collection — runs the full check pipeline on a source file and
## converts errors/warnings into LSP Diagnostic JSON.  Reuses check_program()
## from the module loader, mirroring the CLI's `mtc check` path.

import std.json as json
import std.string as string
import std.vec as vec

import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver
import mtc.linter.linter as linter_mod
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
    # Only lint when the root module parsed and checked successfully.
    if program.analyses.len() > 0 and program.modules.len() > 0:
        let last_analysis_ptr = program.analyses.last() else:
            program.release()
            return diag_array
        let last_module_ptr = program.modules.last() else:
            program.release()
            return diag_array
        unsafe:
            lint_warnings = linter_mod.lint_source(
                read(last_analysis_ptr).source_file,
                read(last_module_ptr).source.as_str(),
                root_path,
                program.owning_type_span()
            )

    var wi: ptr_uint = 0
    while wi < lint_warnings.len():
        let w_ptr = lint_warnings.get(wi) else:
            break
        unsafe:
            let w = read(w_ptr)
            let diag = diagnostic_from_warning(w)
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


## Convert a LoadDiagnostic to an LSP Diagnostic JSON Value.
function diagnostic_from_load_diagnostic(d: loader.LoadDiagnostic) -> json.Value:
    var diag = json.create_object_value()
    let diag_obj = diag.as_object() else:
        return json.null_value()

    let line_zero = if d.line > 0: ptr_uint<-(int<-(d.line) - 1) else: 0z

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
        read(start_obj).set("character", json.number_value(0.0))
        read(end_obj).set("line", json.number_value(double<-line_zero))
        read(end_obj).set("character", json.number_value(1000.0))

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


## Convert a linter Warning to an LSP Diagnostic JSON Value.
## Warnings only carry line numbers (no column info) — use line-granular ranges.
function diagnostic_from_warning(w: linter_mod.Warning) -> json.Value:
    var diag = json.create_object_value()
    let diag_obj = diag.as_object() else:
        return json.null_value()

    let line_zero = if w.line > 0: ptr_uint<-(int<-(w.line) - 1) else: 0z

    var range = json.create_object_value()
    let range_obj = range.as_object() else:
        json.release_value(diag)
        return json.null_value()

    var start_pos = json.create_object_value()
    var end_pos = json.create_object_value()

    unsafe:
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
