## Multi-file program loader — resolves a root source file and its transitive
## imports into an ordered set of parsed, semantically-checked modules.
##
## Mirrors the orchestration of Ruby's ModuleLoader (module_loader.rb): a
## transitive parse pass with cycle detection, a dependency-first ordering, and
## per-module semantic checking.  Each module is wrapped in a LoadedModule that
## retains its source text so the AST's borrowed slices stay valid for the
## lifetime of the Program (the self-host has no GC).
##
## Scope for L2: single-root path resolution, DFS-based dependency ordering, and
## independent per-module analysis.  Cross-module binding (feeding a module's
## exported Analysis into its importers) is L3 and not yet threaded here.

import std.fs as fs
import std.map as map_mod
import std.str as text
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
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
    parse_diagnostics: vec.Vec[parser.ParseDiagnostic]


## A diagnostic aggregated across the whole program, tagged with the owning
## module so parse, load, and semantic errors can be reported uniformly.
public struct LoadDiagnostic:
    module_name: string.String
    line: ptr_uint
    column: ptr_uint
    message: string.String


## The result of loading and checking a program: every parsed module, a
## dependency-first ordering (indices into `modules`), and all diagnostics.
public struct Program:
    modules: vec.Vec[LoadedModule]
    order: vec.Vec[ptr_uint]
    diagnostics: vec.Vec[LoadDiagnostic]


extending LoadedModule:
    public editable function release() -> void:
        this.module_name.release()
        this.path.release()
        this.source.release()
        this.parse_diagnostics.release()


extending LoadDiagnostic:
    public editable function release() -> void:
        this.module_name.release()
        this.message.release()


extending Program:
    public function module_count() -> ptr_uint:
        return this.modules.len()


    public function diagnostic_count() -> ptr_uint:
        return this.diagnostics.len()


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
    # so a module's imports are already bound before it is checked.
    var bindings = map_mod.Map[str, analyzer.ModuleBinding].create()
    let bindings_ptr = ptr_of(bindings)

    var oi: ptr_uint = 0
    while oi < order.len():
        let index_ptr = order.get(oi) else:
            break
        let index = unsafe: read(index_ptr)
        let module_ptr = modules.get(index) else:
            break
        check_and_bind_module(module_ptr, bindings_ptr, ref_of(diagnostics))
        oi += 1

    return Program(modules = modules, order = order, diagnostics = diagnostics)


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
            module_name = string.String.from_str(key),
            line = 0,
            column = 0,
            message = string.String.from_str("cyclic import detected"),
        ))
        owned_path.release()
        return

    match fs.read_text(key):
        Result.failure as failure:
            var error = failure.error
            diagnostics.push(LoadDiagnostic(
                module_name = string.String.from_str(key),
                line = 0,
                column = 0,
                message = string.String.from_str("source file not found"),
            ))
            error.release()
            owned_path.release()
            return
        Result.success as payload:
            var source = payload.value
            var parse_diagnostics = vec.Vec[parser.ParseDiagnostic].create()
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

            recurse_imports(source_file, roots, platform, modules, visited, on_stack, order, diagnostics)

            let _dropped = on_stack.remove(key)
            visited.set(key, index)
            order.push(index)


## Resolve and recursively parse each `import` of a parsed module.  An import
## that cannot be resolved is recorded as a diagnostic rather than aborting.
function recurse_imports(
    source_file: ast.SourceFile,
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
                var module_name = qname_to_module_name(imported.path)
                match resolver.resolve_module_path(module_name.as_str(), roots, platform):
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
                        diagnostics.push(LoadDiagnostic(
                            module_name = string.String.from_str(module_name.as_str()),
                            line = imported.line,
                            column = imported.column,
                            message = string.String.from_str("module not found"),
                        ))
                        error.release()
                module_name.release()
            _:
                pass
        i += 1


## Semantically check one parsed module against the accumulated import bindings,
## append its parse and semantic diagnostics (as owned copies) to the
## program-wide list, and register the module's own export binding.  Parse errors
## block semantic analysis, mirroring the CLI's single-file behaviour.
function check_and_bind_module(
    module_ptr: ptr[LoadedModule],
    bindings_ptr: ptr[map_mod.Map[str, analyzer.ModuleBinding]],
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
                module_name = string.String.from_str(loaded.module_name.as_str()),
                line = parse_diag.line,
                column = parse_diag.column,
                message = string.String.from_str(text.cstr_as_str(parse_diag.message)),
            ))
            pi += 1

        if loaded.parse_diagnostics.len() > 0:
            return

        var analysis = analyzer.check_module(loaded.source_file, bindings_ptr)
        var si: ptr_uint = 0
        while si < analysis.diagnostics.len():
            let sema_ptr = analysis.diagnostics.get(si) else:
                break
            let sema_diag = read(sema_ptr)
            diagnostics.push(LoadDiagnostic(
                module_name = string.String.from_str(loaded.module_name.as_str()),
                line = sema_diag.line,
                column = sema_diag.column,
                message = string.String.from_str(sema_diag.message),
            ))
            si += 1
        analysis.diagnostics.release()

        read(bindings_ptr).set(loaded.module_name.as_str(), binder.bind_module(analysis))


function qname_to_module_name(name: ast.QualifiedName) -> string.String:
    var result = string.String.create()
    var i: ptr_uint = 0
    while i < name.parts.len:
        if i > 0:
            result.append(".")
        unsafe:
            result.append(read(name.parts.data + i))
        i += 1
    return result
