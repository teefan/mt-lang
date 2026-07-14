## Multi-file program loader — resolves a root source file and its transitive
## imports into an ordered set of parsed, semantically-checked modules with
## cross-module bindings.
##
## Mirrors the orchestration of Ruby's ModuleLoader (module_loader.rb): a
## transitive parse pass with cycle detection, a dependency-first ordering, and
## per-module semantic checking with accumulated import bindings so each module's
## imports are bound before it is checked.  Each module is wrapped in a
## LoadedModule that retains its source text so the AST's borrowed slices stay
## valid for the lifetime of the Program (the self-host has no GC).

import std.fs as fs
import std.map as map_mod
import std.str as text
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.loader.binder as binder
import mtc.loader.path_resolver as resolver


## A parsed module plus the storage its AST borrows from.  `source` and the
## String fields are owned; `source_file`'s heap nodes are arena-leaked, matching
## the parser's ownership model.
public struct LoadedModule:
    module_name: string.String
    path: string.String
    source: string.String
    source_file: ast.SourceFile
    parse_diagnostics: vec.Vec[pstate.ParseDiagnostic]


## A diagnostic aggregated across the whole program, tagged with the source-file
## path it occurs in so parse, load, and semantic errors can be reported
## uniformly.
public struct LoadDiagnostic:
    path: string.String
    line: ptr_uint
    column: ptr_uint
    message: string.String
    severity: str


## The result of loading and checking a program: every parsed module, a
## dependency-first ordering (indices into `modules`), the per-module semantic
## `Analysis` values (retained in dependency-first order — the root module is the
## last entry, consumed by the Lowering stage), and all diagnostics.
public struct Program:
    modules: vec.Vec[LoadedModule]
    order: vec.Vec[ptr_uint]
    analyses: vec.Vec[analyzer.Analysis]
    diagnostics: vec.Vec[LoadDiagnostic]


extending LoadedModule:
    public editable function release() -> void:
        this.module_name.release()
        this.path.release()
        this.source.release()
        this.parse_diagnostics.release()


extending LoadDiagnostic:
    public editable function release() -> void:
        this.path.release()
        this.message.release()


extending Program:
    public function module_count() -> ptr_uint:
        return this.modules.len()


    public function diagnostic_count() -> ptr_uint:
        return this.diagnostics.len()


    public function diagnostic_error_count() -> ptr_uint:
        var count: ptr_uint = 0
        var i: ptr_uint = 0
        while i < this.diagnostics.len():
            let d = this.diagnostics.get(i) else:
                break
            if unsafe: read(d).severity == "error":
                count += 1
            i += 1
        return count


    public function diagnostic_warning_count() -> ptr_uint:
        var count: ptr_uint = 0
        var i: ptr_uint = 0
        while i < this.diagnostics.len():
            let d = this.diagnostics.get(i) else:
                break
            if unsafe: read(d).severity == "warning":
                count += 1
            i += 1
        return count


    ## The module name at the given dependency-order position, if any.
    public function ordered_name(position: ptr_uint) -> Option[str]:
        let index_ptr = this.order.get(position) else:
            return Option[str].none
        let index = unsafe: read(index_ptr)
        let module_ptr = this.modules.get(index) else:
            return Option[str].none
        unsafe:
            return Option[str].some(value= read(module_ptr).module_name.as_str())


    ## True when any diagnostic message contains `needle`.
    public function has_diagnostic_containing(needle: str) -> bool:
        var i: ptr_uint = 0
        while i < this.diagnostics.len():
            let diag_ptr = this.diagnostics.get(i) else:
                return false
            unsafe:
                if read(diag_ptr).message.as_str().contains_substring(needle):
                    return true
            i += 1
        return false


    public editable function release() -> void:
        var i: ptr_uint = 0
        while i < this.modules.len():
            let module_ptr = this.modules.get(i) else:
                break
            unsafe:
                read(module_ptr).release()
            i += 1
        this.modules.release()
        this.order.release()

        var d: ptr_uint = 0
        while d < this.diagnostics.len():
            let diag_ptr = this.diagnostics.get(d) else:
                break
            unsafe:
                read(diag_ptr).release()
            d += 1
        this.diagnostics.release()


## Load and check the program rooted at `root_path`, resolving imports against
## `roots` for the active `platform`.
public function check_program(root_path: str, roots: span[str], platform: resolver.Platform) -> Program:
    var modules = vec.Vec[LoadedModule].create()
    var visited = map_mod.Map[str, ptr_uint].create()
    var on_stack = map_mod.Map[str, bool].create()
    var order = vec.Vec[ptr_uint].create()
    var diagnostics = vec.Vec[LoadDiagnostic].create()

    var root_resolved = resolver.resolve_source_path(root_path, platform)

    # Seed the language prelude modules (std.option, std.result) so their real
    # `extending Option[T]:` / `extending Result[T,E]:` method bodies are parsed,
    # checked, and available for monomorphization — mirroring Ruby's
    # PreludeInstaller.  Parsing them first also makes them dependency-first in
    # `order`, so they are checked before any consumer.  A prelude that cannot be
    # resolved is skipped silently (the analyzer still synthesizes the types).
    seed_prelude_module("std.option", roots, platform, ref_of(modules), ref_of(visited), ref_of(on_stack), ref_of(order), ref_of(diagnostics))
    seed_prelude_module("std.result", roots, platform, ref_of(modules), ref_of(visited), ref_of(on_stack), ref_of(order), ref_of(diagnostics))

    parse_all(
        root_resolved,
        roots,
        platform,
        ref_of(modules),
        ref_of(visited),
        ref_of(on_stack),
        ref_of(order),
        ref_of(diagnostics),
    )

    on_stack.release()
    visited.release()

    # Check each module in dependency-first order, accumulating export bindings
    # so a module's imports are already bound before it is checked.  (Per the
    # analyzer's arena-leak convention, transient bindings are intentionally
    # not released at program end.)
    var bindings = map_mod.Map[str, analyzer.ModuleBinding].create()
    let bindings_ptr = ptr_of(bindings)

    # Retained per-module analyses, pushed in dependency-first order so the root
    # module is the last entry.  Consumed by the Lowering stage; intentionally
    # leaked at program end like the transient bindings above.
    var analyses = vec.Vec[analyzer.Analysis].create()

    var oi: ptr_uint = 0
    while oi < order.len():
        let index_ptr = order.get(oi) else:
            break
        let index = unsafe: read(index_ptr)
        let module_ptr = modules.get(index) else:
            break
        check_and_bind_module(module_ptr, bindings_ptr, ref_of(analyses), ref_of(diagnostics))
        oi += 1

    return Program(modules = modules, order = order, analyses = analyses, diagnostics = diagnostics)


## Resolve and parse a prelude module (e.g. std.option) into the module set so
## its declarations — in particular the `extending` method bodies — are checked
## and available to lowering.  Unresolvable prelude modules are skipped silently
## because the analyzer synthesizes the prelude types regardless.
function seed_prelude_module(
    module_name: str,
    roots: span[str],
    platform: resolver.Platform,
    modules: ref[vec.Vec[LoadedModule]],
    visited: ref[map_mod.Map[str, ptr_uint]],
    on_stack: ref[map_mod.Map[str, bool]],
    order: ref[vec.Vec[ptr_uint]],
    diagnostics: ref[vec.Vec[LoadDiagnostic]],
) -> void:
    match resolver.resolve_module_path(module_name, roots, platform):
        Result.success as resolved_ok:
            parse_all(resolved_ok.value, roots, platform, modules, visited, on_stack, order, diagnostics)
        Result.failure as failure:
            var error = failure.error
            error.release()


## Depth-first transitive parse.  Uses three-colour marking: `on_stack` (gray,
## in progress) detects import cycles, `visited` (black, fully parsed) dedups
## shared dependencies.  A module is appended to `order` in post-order, yielding
## a dependency-first ordering.  Takes ownership of `resolved`.
function parse_all(
    resolved: string.String,
    roots: span[str],
    platform: resolver.Platform,
    modules: ref[vec.Vec[LoadedModule]],
    visited: ref[map_mod.Map[str, ptr_uint]],
    on_stack: ref[map_mod.Map[str, bool]],
    order: ref[vec.Vec[ptr_uint]],
    diagnostics: ref[vec.Vec[LoadDiagnostic]],
) -> void:
    var owned_path = resolved
    let key = owned_path.as_str()

    if visited.contains(key):
        owned_path.release()
        return

    if on_stack.contains(key):
        diagnostics.push(LoadDiagnostic(
            path = string.String.from_str(key),
            line = 0,
            column = 0,
            message = string.String.from_str("cyclic import detected"),
            severity = "error",
        ))
        owned_path.release()
        return

    match fs.read_text(key):
        Result.failure as failure:
            var error = failure.error
            diagnostics.push(LoadDiagnostic(
                path = string.String.from_str(key),
                line = 0,
                column = 0,
                message = string.String.from_str("source file not found"),
                severity = "error",
            ))
            error.release()
            owned_path.release()
            return
        Result.success as payload:
            var source = payload.value
            var parse_diagnostics = vec.Vec[pstate.ParseDiagnostic].create()
            let source_file = parser.parse_source(source.as_str(), ref_of(parse_diagnostics))
            let module_name = resolver.infer_module_name(key, roots)

            on_stack.set(key, true)
            modules.push(LoadedModule(
                module_name = module_name,
                path = owned_path,
                source = source,
                source_file = source_file,
                parse_diagnostics = parse_diagnostics,
            ))
            let index = modules.len() - 1

            recurse_imports(source_file, key, roots, platform, modules, visited, on_stack, order, diagnostics)

            let _dropped = on_stack.remove(key)
            visited.set(key, index)
            order.push(index)


## Resolve and recursively parse each `import` of a parsed module.  An import
## that cannot be resolved is recorded as a diagnostic rather than aborting.
function recurse_imports(
    source_file: ast.SourceFile,
    importer_path: str,
    roots: span[str],
    platform: resolver.Platform,
    modules: ref[vec.Vec[LoadedModule]],
    visited: ref[map_mod.Map[str, ptr_uint]],
    on_stack: ref[map_mod.Map[str, bool]],
    order: ref[vec.Vec[ptr_uint]],
    diagnostics: ref[vec.Vec[LoadDiagnostic]],
) -> void:
    var i: ptr_uint = 0
    while i < source_file.imports.len:
        var import_decl: ast.Decl
        unsafe:
            import_decl = read(source_file.imports.data + i)
        match import_decl:
            ast.Decl.decl_import as imported:
                var module_name = analyzer.qname_to_str(imported.path)
                match resolver.resolve_module_path(module_name, roots, platform):
                    Result.success as resolved_ok:
                        parse_all(
                            resolved_ok.value,
                            roots,
                            platform,
                            modules,
                            visited,
                            on_stack,
                            order,
                            diagnostics,
                        )
                    Result.failure as resolve_failure:
                        var error = resolve_failure.error
                        var message = string.String.from_str("module not found: ")
                        message.append(module_name)
                        diagnostics.push(LoadDiagnostic(
                            path = string.String.from_str(importer_path),
                            line = imported.line,
                            column = imported.column,
                            message = message,
                            severity = "error",
                        ))
                        error.release()
            _:
                pass
        i += 1


## Semantically check one parsed module against the accumulated import bindings,
## append its parse and semantic diagnostics (as owned copies) to the
## program-wide list, register the module's own export binding, and retain its
## `Analysis` for the Lowering stage.  Parse errors block semantic analysis,
## mirroring the CLI's single-file behaviour.
function check_and_bind_module(
    module_ptr: ptr[LoadedModule],
    bindings_ptr: ptr[map_mod.Map[str, analyzer.ModuleBinding]],
    analyses: ref[vec.Vec[analyzer.Analysis]],
    diagnostics: ref[vec.Vec[LoadDiagnostic]],
) -> void:
    unsafe:
        let loaded = read(module_ptr)

        var pi: ptr_uint = 0
        while pi < loaded.parse_diagnostics.len():
            let parse_ptr = loaded.parse_diagnostics.get(pi) else:
                break
            let parse_diag = read(parse_ptr)
            diagnostics.push(LoadDiagnostic(
                path = string.String.from_str(loaded.path.as_str()),
                line = parse_diag.line,
                column = parse_diag.column,
                message = string.String.from_str(text.cstr_as_str(parse_diag.message)),
                severity = "error",
            ))
            pi += 1

        if loaded.parse_diagnostics.len() > 0:
            return

        var analysis = analyzer.check_module(loaded.source_file, bindings_ptr, loaded.module_name.as_str())
        var si: ptr_uint = 0
        while si < analysis.diagnostics.len():
            let sema_ptr = analysis.diagnostics.get(si) else:
                break
            let sema_diag = read(sema_ptr)
            diagnostics.push(LoadDiagnostic(
                path = string.String.from_str(loaded.path.as_str()),
                line = sema_diag.line,
                column = sema_diag.column,
                message = string.String.from_str(sema_diag.message),
                severity = "error",
            ))
            si += 1
        analysis.diagnostics.release()

        read(bindings_ptr).set(loaded.module_name.as_str(), binder.bind_module(analysis))
        analyses.push(analysis)
