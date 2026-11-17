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
import std.mem.heap as heap
import std.path as path_ops
import std.str as text
import std.string as string
import std.vec as vec

import mtc.lexer.token as token_mod
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
    lex_diagnostics: vec.Vec[token_mod.LexDiagnostic]


## A diagnostic aggregated across the whole program, tagged with the source-file
## path it occurs in so parse, load, and semantic errors can be reported
## uniformly.  `length` is the offending token's character length (0 when the
## emitter has none) and `symbol_name` the module path text for import failures;
## both mirror the Ruby `Diagnostic` fields the LSP range logic reads.
public struct LoadDiagnostic:
    path: string.String
    line: ptr_uint
    column: ptr_uint
    length: ptr_uint
    message: string.String
    severity: str
    code: str
    symbol_name: string.String


## A Program that carries only a whole-file load failure (the platform guard):
## no modules, no analyses, one diagnostic.  The caller returns it directly so
## the CLI reports the failure the way the host's raised `ModuleLoadError`
## propagates out of `check_program`.
function empty_program_with_diagnostics(path: str, message: string.String) -> Program:
    var diagnostics = vec.Vec[LoadDiagnostic].create()
    diagnostics.push(LoadDiagnostic(
        path = string.String.from_str(path),
        line = 0,
        column = 0,
        length = 0,
        message = message,
        severity = "error",
        code = "load/error",
        symbol_name = string.String.from_str(""),
    ))
    return Program(
        modules = vec.Vec[LoadedModule].create(),
        order = vec.Vec[ptr_uint].create(),
        analyses = vec.Vec[analyzer.Analysis].create(),
        diagnostics = diagnostics,
        owning_type_names = vec.Vec[str].create(),
        root_index = 0,
        unresolved_import_paths = vec.Vec[string.String].create(),
        modules_owned = true,
        cycle_module_names = vec.Vec[str].create(),
    )


## The result of loading and checking a program: every parsed module, a
## dependency-first ordering (indices into `modules`), the per-module semantic
## `Analysis` values (retained in canonical lowering order — see
## `canonical_analysis_order`), and all diagnostics.  `root_index` locates the
## requested root module inside `analyses` (it is not necessarily the last
## entry; the canonical order follows the Ruby host).
public struct Program:
    modules: vec.Vec[LoadedModule]
    order: vec.Vec[ptr_uint]
    analyses: vec.Vec[analyzer.Analysis]
    diagnostics: vec.Vec[LoadDiagnostic]
    owning_type_names: vec.Vec[str]
    root_index: ptr_uint
    ## Module paths that failed to resolve (mirrors the Ruby loader's
    ## `unresolved_import_paths`): the linter skips `unused-import` for them.
    unresolved_import_paths: vec.Vec[string.String]
    ## True when the Program owns its `modules`.  A cache-built Program (see
    ## `ModuleCache`) holds shallow copies of the cache's modules — the cache
    ## owns their storage — so `release` frees only the modules vector itself.
    modules_owned: bool
    ## Module names that participate in an import cycle, in parse order (the
    ## host's graph-key order).  Empty for an acyclic program.  Lowering uses
    ## this to reproduce the host's analysis-cache insertion order when it
    ## collects raw-module includes.
    cycle_module_names: vec.Vec[str]


extending LoadedModule:
    public editable function release() -> void:
        this.module_name.release()
        this.path.release()
        this.source.release()
        this.parse_diagnostics.release()
        this.lex_diagnostics.release()


extending LoadDiagnostic:
    public editable function release() -> void:
        this.path.release()
        this.message.release()
        this.symbol_name.release()


extending Program:
    public function module_count() -> ptr_uint:
        return this.modules.len()


    ## Owning type names: types with a `.release()` method in any loaded module.
    public function owning_type_span() -> span[str]:
        return this.owning_type_names.as_span()


    public function diagnostic_count() -> ptr_uint:
        return this.diagnostics.len()


    ## The module name of the root program (`root_index` into the canonical
    ## analysis order), or "" when there are no analyses.
    public function root_module_name() -> str:
        let root = this.analyses.get(this.root_index) else:
            return ""
        return unsafe: read(root).module_name


    ## True when the root program is a raw `external` file.  The C backend cannot
    ## emit a translation unit for a raw ABI-binding file (it has no ordinary
    ## module logic), so build/lower/emit-c reject it — mirroring Ruby's
    ## LoweringError for `:raw_module`.
    public function root_is_raw_module() -> bool:
        let root = this.analyses.get(this.root_index) else:
            return false
        return unsafe: read(root).module_kind == ast.ModuleKind.module_raw


    ## True when the root program declares a `main` function (regardless of
    ## signature validity).  Distinguishes "no main at all" from "main with an
    ## unsupported signature" when reporting a missing executable entrypoint.
    public function root_has_main() -> bool:
        let root = this.analyses.get(this.root_index) else:
            return false
        return unsafe: read(root).functions.contains("main")


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


    ## Count only loader-level errors (module/error code prefix) — source file
    ## not found, import failures, etc.  These are hard failures that prevent
    ## lowering and must abort the build; semantic errors are excluded because
    ## the self-host analyzer has known false-positive patterns on valid code.
    public function diagnostic_module_error_count() -> ptr_uint:
        var count: ptr_uint = 0
        var i: ptr_uint = 0
        while i < this.diagnostics.len():
            let d = this.diagnostics.get(i) else:
                break
            unsafe:
                if read(d).severity == "error" and read(d).code.starts_with("module"):
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
        if this.modules_owned:
            var i: ptr_uint = 0
            while i < this.modules.len():
                let module_ptr = this.modules.get(i) else:
                    break
                unsafe:
                    read(module_ptr).release()
                i += 1
        this.modules.release()
        this.order.release()
        this.analyses.release()
        this.owning_type_names.release()
        this.cycle_module_names.release()

        var d: ptr_uint = 0
        while d < this.diagnostics.len():
            let diag_ptr = this.diagnostics.get(d) else:
                break
            unsafe:
                read(diag_ptr).release()
            d += 1
        this.diagnostics.release()
        var u: ptr_uint = 0
        while u < this.unresolved_import_paths.len():
            let up = this.unresolved_import_paths.get(u) else:
                break
            unsafe:
                read(up).release()
            u += 1
        this.unresolved_import_paths.release()


## One module's cached parse state plus — once the module has been checked in
## some run — its analysis and export binding.  Owned by a `ModuleCache`; the
## parse and analysis allocations live in the entry's regions and are released
## (or retired to the cache's quarantine) when the entry or its analysis is
## replaced.
public struct ModuleCacheEntry:
    content_hash: uint
    module: LoadedModule
    ## Analysis identity, assigned from the cache's counter on every parse or
    ## re-analysis.  Dependents snapshot it and re-analyze when it moves.
    version: ptr_uint
    ## The resolved direct-import paths recorded when `analysis_ptr` was last
    ## built, and those imports' `version` values at that moment.  A different
    ## path set — an import added, removed, created or deleted — or a moved
    ## import version forces the module's re-analysis.
    import_paths: vec.Vec[string.String]
    dep_versions: vec.Vec[ptr_uint]
    ## Null between the parse phase and the module's first check in a run; set
    ## once the module has been analyzed and replaced on every re-analysis.
    analysis_ptr: ptr[analyzer.Analysis]?
    binding_ptr: ptr[analyzer.ModuleBinding]?
    ## The regions that own this version's parse (AST, token buffers, spans,
    ## synthesized strings, the diagnostics vectors' buffers) and analysis
    ## (the analyzer context's maps/vecs, types, diagnostics) allocations.
    ## Both are freed when the entry is replaced; the modules' own String
    ## fields, `import_paths` and `dep_versions` are ordinary heap.
    parse_region: heap.Region
    analysis_region: heap.Region


## The workspace-owned cross-program module cache: one entry per resolved module
## path, shared by every Program the workspace builds, so an edit re-parses and
## re-analyzes only the edited module and its dependents instead of the whole
## import closure.  `generation` moves whenever any entry's parse or analysis
## identity changes (and on document edits, where the cache has not yet seen the
## new content); a Program cached at an older generation is rebuilt before use.
## `parse_count`/`analysis_count` are verification counters.
public struct ModuleCache:
    entries: map_mod.Map[string.String, ModuleCacheEntry]
    generation: ptr_uint
    version_counter: ptr_uint
    parse_count: ptr_uint
    analysis_count: ptr_uint
    ## Superseded entries' regions, kept alive until the request boundary
    ## (`drain_retired_regions`): a request may still hold borrowed views into
    ## a region it replaced mid-request (the token scanner's module surfaces),
    ## so freeing at replacement would be a use-after-free.
    retired_regions: vec.Vec[heap.Region]


## Per-run state threaded through the loader: each module's resolved
## direct-import paths (index-aligned with the run's module list) and the open
## editor buffers that override a module's disk content (the host's
## `source_overrides`).  The vectors stay empty and unread when the run has no
## cache.
struct LoadRun:
    cache: ptr[ModuleCache]?
    open_docs: ptr[map_mod.Map[string.String, string.String]]?
    dep_paths: vec.Vec[vec.Vec[string.String]]


public function create_module_cache() -> ModuleCache:
    return ModuleCache(
        entries = map_mod.Map[string.String, ModuleCacheEntry].create(),
        generation = 0,
        version_counter = 0,
        parse_count = 0,
        analysis_count = 0,
        retired_regions = vec.Vec[heap.Region].create(),
    )


## Force every Program cached against this cache to rebuild on its next lookup.
## Called on document edits, whose content the cache has not seen yet.
public function invalidate_module_cache(cache: ref[ModuleCache]) -> void:
    cache.generation += 1


public function release_module_cache(cache: ref[ModuleCache]) -> void:
    drain_retired_regions(cache)
    var entries_iter = cache.entries.entries()
    while entries_iter.next():
        let entry = entries_iter.current()
        unsafe:
            var entry_value = read(entry.value)
            release_module_cache_entry(ref_of(entry_value), null)
    cache.entries.release()


## Free the regions of entries superseded since the last drain.  Called at the
## request boundary, when no request-local value can still borrow them.
public function drain_retired_regions(cache: ref[ModuleCache]) -> void:
    var i: ptr_uint = 0
    while i < cache.retired_regions.len():
        let region_ptr = cache.retired_regions.get(i) else:
            break
        unsafe:
            read(region_ptr).release_all()
        i += 1
    cache.retired_regions.clear()


## Move a superseded region to the cache's quarantine instead of freeing it: a
## request may still hold borrowed views into it (see `retired_regions`).
function retire_region(cache: ptr[ModuleCache]?, region: heap.Region) -> void:
    if cache == null or region.block_count == 0:
        return
    unsafe:
        read(cache).retired_regions.push(region)


## Release an entry's heap fields and its regions.  With `cache` non-null the
## regions are quarantined; teardown callers pass null and free immediately.
## The module's name/path/source Strings and `import_paths`/`dep_versions` are
## ordinary heap (allocated outside the parse/analysis scopes); the AST and the
## parse/lex diagnostics vectors' buffers are region-owned, so
## `LoadedModule.release`'s vector releases are deliberately not run here.
function release_module_cache_entry(entry: ref[ModuleCacheEntry], cache: ptr[ModuleCache]?) -> void:
    entry.module.module_name.release()
    entry.module.path.release()
    entry.module.source.release()
    if cache != null:
        retire_region(cache, entry.parse_region)
        retire_region(cache, entry.analysis_region)
    else:
        entry.parse_region.release_all()
        entry.analysis_region.release_all()
    release_paths_vec(entry.import_paths)
    var versions = entry.dep_versions
    versions.release()
    release_entry_nodes(entry)


## Release a replaced entry's heap analysis and binding structs.  Their
## internals live in the entry's analysis region, which the caller releases or
## quarantines.  The old analysis may still be shallow-copied inside stale
## Programs, but those are never read: a replaced entry always moves the
## cache's generation, and every Program is validated against it before use.
function release_entry_nodes(entry: ref[ModuleCacheEntry]) -> void:
    let analysis_mem = entry.analysis_ptr
    if analysis_mem != null:
        heap.release(analysis_mem)
        entry.analysis_ptr = null
    let binding_mem = entry.binding_ptr
    if binding_mem != null:
        heap.release(binding_mem)
        entry.binding_ptr = null


## A cached module's parse and analysis, handed out by value for consumers that
## only need the surface (the semantic-token scanner's import aliases).
public struct CachedModuleSurface:
    source_file: ast.SourceFile
    analysis: analyzer.Analysis


## The cached parsed module and analysis for `path`, when the cache holds both.
## None means the module has not been loaded through the cache yet — callers
## fall back to their own load (and the workspace's loader-backed analysis
## warms the cache for the next request).
public function cached_module_surface(cache: ptr[ModuleCache]?, path: str) -> Option[CachedModuleSurface]:
    let entry_ptr = module_cache_entry(cache, path) else:
        return Option[CachedModuleSurface].none
    var entry: ModuleCacheEntry
    unsafe:
        entry = read(entry_ptr)
    let analysis_mem = entry.analysis_ptr
    if analysis_mem == null:
        return Option[CachedModuleSurface].none
    return Option[CachedModuleSurface].some(value = CachedModuleSurface(
        source_file = entry.module.source_file,
        analysis = unsafe: read(analysis_mem),
    ))


## Look up an entry by resolved path.  The returned pointer addresses the map's
## storage; it stays valid until the map is mutated.
function module_cache_entry(cache: ptr[ModuleCache]?, path: str) -> ptr[ModuleCacheEntry]?:
    if cache == null:
        return null
    var key = string.String.from_str(path)
    defer: key.release()
    return unsafe: read(cache).entries.get(key)


## Store a freshly parsed module, replacing (and releasing) any previous entry
## for `path`.  A changed content hash invalidates the old analysis, so it is
## dropped with the module.
function module_cache_store_module(
    cache: ptr[ModuleCache]?,
    path: str,
    content_hash: uint,
    module_value: LoadedModule,
    parse_region: heap.Region,
) -> void:
    if cache == null:
        return
    var lookup = string.String.from_str(path)
    defer: lookup.release()
    var next_version: ptr_uint = 0
    unsafe:
        next_version = read(cache).version_counter + 1
        read(cache).version_counter = next_version
    unsafe:
        match read(cache).entries.remove_entry(lookup):
            Option.some as removed:
                var removed_entry = removed.value
                removed_entry.key.release()
                var old_entry = removed_entry.value
                release_module_cache_entry(ref_of(old_entry), cache)
            Option.none:
                pass
        read(cache).entries.set(string.String.from_str(path), ModuleCacheEntry(
            content_hash = content_hash,
            module = module_value,
            version = next_version,
            import_paths = vec.Vec[string.String].create(),
            dep_versions = vec.Vec[ptr_uint].create(),
            analysis_ptr = null,
            binding_ptr = null,
            parse_region = parse_region,
            analysis_region = heap.create_region(),
        ))
        read(cache).parse_count = read(cache).parse_count + 1
        read(cache).generation = read(cache).generation + 1


## Record the analysis and export binding just built for the module at `path`,
## replacing any previous ones, and take ownership of the run's resolved import
## paths for the module, snapshotting their current versions.  The diagnostics
## vector is retained — entry teardown owns it — because a reused module
## re-emits its sema diagnostics from here.
function module_cache_store_analysis(
    cache: ptr[ModuleCache]?,
    path: str,
    module_index: ptr_uint,
    run: ref[LoadRun],
    analysis_value: analyzer.Analysis,
    binding_value: analyzer.ModuleBinding,
    analysis_region: heap.Region,
) -> void:
    if cache == null:
        return
    let entry_ptr = module_cache_entry(cache, path) else:
        return
    var next_version: ptr_uint = 0
    unsafe:
        next_version = read(cache).version_counter + 1
        read(cache).version_counter = next_version
    unsafe:
        let old_analysis = read(entry_ptr).analysis_ptr
        if old_analysis != null:
            heap.release(old_analysis)
        let old_binding = read(entry_ptr).binding_ptr
        if old_binding != null:
            heap.release(old_binding)
        retire_region(cache, read(entry_ptr).analysis_region)
        read(entry_ptr).analysis_region = heap.create_region()
        release_paths_vec(read(entry_ptr).import_paths)
        var old_versions = read(entry_ptr).dep_versions
        old_versions.release()
        let analysis_mem = ptr[analyzer.Analysis]<-heap.must_alloc[analyzer.Analysis](1)
        read(analysis_mem) = analysis_value
        read(entry_ptr).analysis_ptr = analysis_mem
        let binding_mem = ptr[analyzer.ModuleBinding]<-heap.must_alloc[analyzer.ModuleBinding](1)
        read(binding_mem) = binding_value
        read(entry_ptr).binding_ptr = binding_mem
        read(entry_ptr).analysis_region = analysis_region
        read(entry_ptr).version = next_version
        let slot = run.dep_paths.get(module_index)
        if slot != null:
            var versions = vec.Vec[ptr_uint].create()
            var dep_list = read(slot)
            var di: ptr_uint = 0
            while di < dep_list.len():
                let dep_path_ptr = dep_list.get(di) else:
                    break
                let dep_entry_ptr = module_cache_entry(cache, read(dep_path_ptr).as_str())
                if dep_entry_ptr != null:
                    versions.push(read(dep_entry_ptr).version)
                else:
                    versions.push(0)
                di += 1
            read(entry_ptr).import_paths = read(slot)
            read(entry_ptr).dep_versions = versions
            read(slot) = vec.Vec[string.String].create()
        read(cache).analysis_count = read(cache).analysis_count + 1
        read(cache).generation = read(cache).generation + 1


## Release a run's bookkeeping vectors.  Slots whose paths were moved into
## cache entries are empty by then, so this frees only what the run still owns.
function release_load_run(run: ref[LoadRun]) -> void:
    var i: ptr_uint = 0
    while i < run.dep_paths.len():
        let slot = run.dep_paths.get(i) else:
            break
        unsafe:
            release_paths_vec(read(slot))
        i += 1
    run.dep_paths.release()


## Release an owned path vector: each element String, then the vector itself.
## The caller passes the vector by value, so the (shared) backing storage is
## freed exactly once; a container that keeps using its slot must replace it.
function release_paths_vec(paths: vec.Vec[string.String]) -> void:
    var owned = paths
    var i: ptr_uint = 0
    while i < owned.len():
        let path_ptr = owned.get(i) else:
            break
        unsafe:
            read(path_ptr).release()
        i += 1
    owned.release()


## A content fingerprint for the module cache.
function fnv1a_hash(content: str) -> uint:
    var hash: uint = 2166136261
    var i: ptr_uint = 0
    while i < content.len:
        hash = (hash ^ uint<-content.byte_at(i)) * 16777619
        i += 1
    return hash


## True when two resolved-import-path lists are element-wise equal.
function import_paths_equal(left: span[string.String], right: span[string.String]) -> bool:
    if left.len != right.len:
        return false
    var i: ptr_uint = 0
    while i < left.len:
        unsafe:
            if not read(left.data + i).as_str().equal(read(right.data + i).as_str()):
                return false
        i += 1
    return true


## True when a module's cached analysis cannot be reused: it has no analysis
## yet (its content was re-parsed or the entry is new), its resolved direct
## import set changed, or a direct import it was analyzed against has moved to
## a new analysis version.  A cycle's back-edge — a dependency checked after
## this module — is skipped: the module's check could not see that dependency's
## binding, so its result is independent of it.  A dependency that resolved but
## produced no module (a read failure) is treated conservatively as changed.
function module_needs_rebuild(cache: ptr[ModuleCache]?, run: ref[LoadRun], module_index: ptr_uint, modules: ref[vec.Vec[LoadedModule]], visited: ref[map_mod.Map[str, ptr_uint]], order_positions: ref[vec.Vec[ptr_uint]]) -> bool:
    let module_ptr = modules.get(module_index) else:
        return true
    var module_value: LoadedModule
    unsafe:
        module_value = read(module_ptr)

    let entry_ptr = module_cache_entry(cache, module_value.path.as_str()) else:
        return true
    var entry: ModuleCacheEntry
    unsafe:
        entry = read(entry_ptr)
    if entry.analysis_ptr == null:
        return true

    let dep_list_ptr = run.dep_paths.get(module_index) else:
        return true
    var dep_list: vec.Vec[string.String]
    unsafe:
        dep_list = read(dep_list_ptr)
    if not import_paths_equal(entry.import_paths.as_span(), dep_list.as_span()):
        return true

    let this_pos_ptr = order_positions.get(module_index) else:
        return true
    var this_pos: ptr_uint
    unsafe:
        this_pos = read(this_pos_ptr)

    var di: ptr_uint = 0
    while di < dep_list.len():
        let dep_path_ptr = dep_list.get(di) else:
            break
        var dep_path: str
        unsafe:
            dep_path = read(dep_path_ptr).as_str()
        let dep_index_ptr = visited.get(dep_path) else:
            return true
        var dep_index: ptr_uint
        unsafe:
            dep_index = read(dep_index_ptr)
        let dep_pos_ptr = order_positions.get(dep_index) else:
            return true
        var dep_pos: ptr_uint
        unsafe:
            dep_pos = read(dep_pos_ptr)
        if dep_pos < this_pos:
            let dep_entry_ptr = module_cache_entry(cache, dep_path) else:
                return true
            let snapshot_ptr = entry.dep_versions.get(di) else:
                return true
            var dep_version: ptr_uint
            var snapshot_version: ptr_uint
            unsafe:
                dep_version = read(dep_entry_ptr).version
                snapshot_version = read(snapshot_ptr)
            if dep_version != snapshot_version:
                return true
        di += 1
    return false


## The cycle members' module names in parse order (the host's graph-key order).
## Lowering uses this to reproduce the host's analysis insertion order.
function collect_cycle_module_names(modules: ref[vec.Vec[LoadedModule]], cycle_members: ref[map_mod.Map[ptr_uint, bool]]) -> vec.Vec[str]:
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < modules.len():
        if cycle_members.contains(i):
            let module_ptr = modules.get(i) else:
                break
            names.push(unsafe: read(module_ptr).module_name.as_str())
        i += 1
    return names


## Cycle members from the resolved dependency paths recorded by the parse walk:
## a module is on a cycle when it can reach itself through the import graph.
## Mirrors the host's `check_program_parallel` cycle-member selection, using the
## `run.dep_paths` graph instead of a separate parse-cache graph.
function detect_cycle_members(run: ref[LoadRun], visited: ref[map_mod.Map[str, ptr_uint]], module_count: ptr_uint) -> map_mod.Map[ptr_uint, bool]:
    var members = map_mod.Map[ptr_uint, bool].create()
    var i: ptr_uint = 0
    while i < module_count:
        if module_reaches_itself(i, run, visited):
            members.set(i, true)
        i += 1
    return members


function module_reaches_itself(start: ptr_uint, run: ref[LoadRun], visited: ref[map_mod.Map[str, ptr_uint]]) -> bool:
    let slot = run.dep_paths.get(start) else:
        return false
    var deps: vec.Vec[string.String]
    unsafe:
        deps = read(slot)
    var i: ptr_uint = 0
    while i < deps.len():
        let dep_path_ptr = deps.get(i) else:
            break
        let dep_index_ptr = visited.get(unsafe: read(dep_path_ptr).as_str()) else:
            i += 1
            continue
        let dep_index = unsafe: read(dep_index_ptr)
        if dep_index == start:
            return true
        var seen = map_mod.Map[ptr_uint, bool].create()
        if reachable_from(dep_index, start, run, visited, ref_of(seen)):
            return true
        i += 1
    return false


function reachable_from(current: ptr_uint, target: ptr_uint, run: ref[LoadRun], visited: ref[map_mod.Map[str, ptr_uint]], seen: ref[map_mod.Map[ptr_uint, bool]]) -> bool:
    if current == target:
        return true
    if seen.contains(current):
        return false
    seen.set(current, true)
    let slot = run.dep_paths.get(current) else:
        return false
    var deps: vec.Vec[string.String]
    unsafe:
        deps = read(slot)
    var i: ptr_uint = 0
    while i < deps.len():
        let dep_path_ptr = deps.get(i) else:
            break
        let dep_index_ptr = visited.get(unsafe: read(dep_path_ptr).as_str()) else:
            i += 1
            continue
        let dep_index = unsafe: read(dep_index_ptr)
        if reachable_from(dep_index, target, run, visited, seen):
            return true
        i += 1
    return false


## The non-cycle modules a cycle's first pass needs: every transitive dependency
## of a cycle member that is not itself on a cycle.  They are analysed before the
## cycle passes (with the forward type bindings) so the cycle members see their
## complete export surfaces, then re-analysed after the cycle bindings are final.
function collect_cycle_dependencies(cycle_members: ref[map_mod.Map[ptr_uint, bool]], run: ref[LoadRun], visited: ref[map_mod.Map[str, ptr_uint]]) -> map_mod.Map[ptr_uint, bool]:
    var needed = map_mod.Map[ptr_uint, bool].create()
    var stack = vec.Vec[ptr_uint].create()
    var i: ptr_uint = 0
    while i < run.dep_paths.len():
        if cycle_members.contains(i):
            push_non_cycle_deps(i, cycle_members, run, visited, ref_of(needed), ref_of(stack))
        i += 1
    while true:
        let current = stack.pop() else:
            break
        push_non_cycle_deps(current, cycle_members, run, visited, ref_of(needed), ref_of(stack))
    return needed


function push_non_cycle_deps(index: ptr_uint, cycle_members: ref[map_mod.Map[ptr_uint, bool]], run: ref[LoadRun], visited: ref[map_mod.Map[str, ptr_uint]], needed: ref[map_mod.Map[ptr_uint, bool]], stack: ref[vec.Vec[ptr_uint]]) -> void:
    let slot = run.dep_paths.get(index) else:
        return
    var deps: vec.Vec[string.String]
    unsafe:
        deps = read(slot)
    var i: ptr_uint = 0
    while i < deps.len():
        let dep_path_ptr = deps.get(i) else:
            break
        let dep_index_ptr = visited.get(unsafe: read(dep_path_ptr).as_str()) else:
            i += 1
            continue
        let dep_index = unsafe: read(dep_index_ptr)
        if not cycle_members.contains(dep_index) and not needed.contains(dep_index):
            needed.set(dep_index, true)
            stack.push(dep_index)
        i += 1


## Analyse a module and build its export binding inside `region_ptr` (or on the
## ordinary heap when it is null), without emitting diagnostics or registering
## the binding.  Cycle passes use this for their provisional and final analyses.
function analyze_and_bind_in_region(module_ptr: ptr[LoadedModule], bindings_ptr: ptr[map_mod.Map[str, analyzer.ModuleBinding]], require_resolved_imports: bool, region_ptr: ptr[heap.Region]?) -> (analyzer.Analysis, analyzer.ModuleBinding):
    var previous: ptr[heap.Region]? = null
    if region_ptr != null:
        previous = heap.begin_region(region_ptr)
    let loaded = unsafe: read(module_ptr)
    var analysis: analyzer.Analysis
    if require_resolved_imports:
        analysis = analyzer.check_module_requiring_resolved_imports(loaded.source_file, bindings_ptr, loaded.module_name.as_str(), loaded.path.as_str())
    else:
        analysis = analyzer.check_module(loaded.source_file, bindings_ptr, loaded.module_name.as_str(), loaded.path.as_str())
    let binding = binder.bind_module(analysis)
    if region_ptr != null:
        heap.end_region(previous)
    return (analysis, binding)


## Check a program whose import graph has cycles: pre-register forward type
## bindings, analyse the cycle members twice (the first pass with the forward
## bindings, the second with the full bindings from the first), then analyse the
## acyclic modules against the final cycle bindings.  Mirrors the host's
## `check_program_parallel` phases 3-5.
function check_cyclic_program(
    modules: ref[vec.Vec[LoadedModule]],
    visited: ref[map_mod.Map[str, ptr_uint]],
    order: ref[vec.Vec[ptr_uint]],
    run: ref[LoadRun],
    cache: ptr[ModuleCache]?,
    cycle_members: ref[map_mod.Map[ptr_uint, bool]],
    bindings_ptr: ptr[map_mod.Map[str, analyzer.ModuleBinding]],
    analyses: ref[vec.Vec[analyzer.Analysis]],
    diagnostics: ref[vec.Vec[LoadDiagnostic]],
    require_resolved_imports: bool,
    order_positions: ref[vec.Vec[ptr_uint]],
) -> void:
    var cycle_rebuild = true
    if cache != null:
        cycle_rebuild = false
        var ci: ptr_uint = 0
        while ci < order.len():
            let index_ptr = order.get(ci) else:
                break
            let index = unsafe: read(index_ptr)
            if cycle_members.contains(index):
                if module_needs_rebuild(cache, run, index, modules, visited, order_positions):
                    cycle_rebuild = true
            ci += 1

    var final_analyses = map_mod.Map[ptr_uint, analyzer.Analysis].create()
    var pass2_bindings = map_mod.Map[str, analyzer.ModuleBinding].create()

    if cycle_rebuild:
        # Provisional analyses and their bindings stay alive until the second
        # pass has consumed them.  With a cache they live in the region that
        # later owns the member's final analysis: pass-2 type values can point
        # into pass-1 data, so tying the provisional region to the request
        # boundary dangled them once the program was cached past that request.
        var cyclic_regions = map_mod.Map[ptr_uint, heap.Region].create()
        defer: cyclic_regions.release()

        # Pre-register forward type bindings for every cycle member.
        var fi: ptr_uint = 0
        while fi < order.len():
            let index_ptr = order.get(fi) else:
                break
            let index = unsafe: read(index_ptr)
            if cycle_members.contains(index):
                let module_ptr = modules.get(index) else:
                    fi += 1
                    continue
                let loaded = unsafe: read(module_ptr)
                unsafe:
                    read(bindings_ptr).set(loaded.module_name.as_str(), binder.bind_forward_module(loaded.source_file))
            fi += 1

        # First analyse the cycle members' acyclic dependencies, so the first
        # cycle pass sees their export surfaces.
        var needed = collect_cycle_dependencies(cycle_members, run, visited)
        var pi: ptr_uint = 0
        while pi < order.len():
            let index_ptr = order.get(pi) else:
                break
            let index = unsafe: read(index_ptr)
            if not cycle_members.contains(index) and needed.contains(index):
                let module_ptr = modules.get(index) else:
                    pi += 1
                    continue
                let loaded = unsafe: read(module_ptr)
                var binding_found = false
                if cache != null:
                    if not module_needs_rebuild(cache, run, index, modules, visited, order_positions):
                        let entry_ptr = module_cache_entry(cache, loaded.path.as_str())
                        if entry_ptr != null:
                            let binding_mem = unsafe: read(entry_ptr).binding_ptr
                            if binding_mem != null:
                                unsafe:
                                    read(bindings_ptr).set(loaded.module_name.as_str(), read(binding_mem))
                                binding_found = true
                if not binding_found:
                    let (_, binding) = analyze_and_bind_in_region(module_ptr, bindings_ptr, require_resolved_imports, null)
                    unsafe:
                        read(bindings_ptr).set(loaded.module_name.as_str(), binding)
            pi += 1

        # Pass 1: cycle members against the forward type bindings.  Each
        # member's provisional analysis is allocated in the region that will
        # own its final analysis, so pass-2 types borrowing from it stay valid
        # for the cache entry's lifetime.
        var p1: ptr_uint = 0
        while p1 < order.len():
            let index_ptr = order.get(p1) else:
                break
            let index = unsafe: read(index_ptr)
            if cycle_members.contains(index):
                let module_ptr = modules.get(index) else:
                    p1 += 1
                    continue
                let loaded = unsafe: read(module_ptr)
                let region_ptr = cycle_pass1_region(cache, ref_of(cyclic_regions), index)
                let (_, binding) = analyze_and_bind_in_region(module_ptr, bindings_ptr, require_resolved_imports, region_ptr)
                unsafe:
                    read(bindings_ptr).set(loaded.module_name.as_str(), binding)
            p1 += 1

        # Pass 2: cycle members against the full bindings from pass 1.  The
        # pass-2 bindings are installed only after every member has been
        # analysed, so all members see the pass-1 surfaces.
        var p2: ptr_uint = 0
        while p2 < order.len():
            let index_ptr = order.get(p2) else:
                break
            let index = unsafe: read(index_ptr)
            if cycle_members.contains(index):
                let module_ptr = modules.get(index) else:
                    p2 += 1
                    continue
                let loaded = unsafe: read(module_ptr)
                if cache != null:
                    let region_ptr = cyclic_regions.get(index) else:
                        p2 += 1
                        continue
                    let (analysis, binding) = analyze_and_bind_in_region(module_ptr, bindings_ptr, require_resolved_imports, region_ptr)
                    let analysis_region = unsafe: read(region_ptr)
                    module_cache_store_analysis(cache, loaded.path.as_str(), index, run, analysis, binding, analysis_region)
                    pass2_bindings.set(loaded.module_name.as_str(), binding)
                    final_analyses.set(index, analysis)
                else:
                    let (analysis, binding) = analyze_and_bind_in_region(module_ptr, bindings_ptr, require_resolved_imports, null)
                    pass2_bindings.set(loaded.module_name.as_str(), binding)
                    final_analyses.set(index, analysis)
            p2 += 1

        var ib: ptr_uint = 0
        while ib < order.len():
            let index_ptr = order.get(ib) else:
                break
            let index = unsafe: read(index_ptr)
            if cycle_members.contains(index):
                let module_ptr = modules.get(index) else:
                    ib += 1
                    continue
                let loaded = unsafe: read(module_ptr)
                let binding_ptr = pass2_bindings.get(loaded.module_name.as_str()) else:
                    ib += 1
                    continue
                unsafe:
                    read(bindings_ptr).set(loaded.module_name.as_str(), read(binding_ptr))
            ib += 1
    else:
        # Every cycle member's cached analysis is still current: reuse it and
        # keep the dependents' cache entries valid.
        var ci: ptr_uint = 0
        while ci < order.len():
            let index_ptr = order.get(ci) else:
                break
            let index = unsafe: read(index_ptr)
            if cycle_members.contains(index):
                let module_ptr = modules.get(index) else:
                    ci += 1
                    continue
                let loaded = unsafe: read(module_ptr)
                let entry_ptr = module_cache_entry(cache, loaded.path.as_str())
                if entry_ptr != null:
                    let binding_mem = unsafe: read(entry_ptr).binding_ptr
                    if binding_mem != null:
                        unsafe:
                            read(bindings_ptr).set(loaded.module_name.as_str(), read(binding_mem))
                    let analysis_mem = unsafe: read(entry_ptr).analysis_ptr
                    if analysis_mem != null:
                        final_analyses.set(index, unsafe: read(analysis_mem))
            ci += 1

    # Final pass in dependency-first order: emit the cycle members' pass-2
    # analyses at their positions and let the acyclic modules see the final
    # cycle bindings.
    var oi: ptr_uint = 0
    while oi < order.len():
        let index_ptr = order.get(oi) else:
            break
        let index = unsafe: read(index_ptr)
        let module_ptr = modules.get(index) else:
            break
        let loaded = unsafe: read(module_ptr)
        if cycle_members.contains(index):
            let analysis_ptr = final_analyses.get(index)
            if analysis_ptr != null:
                var analysis = unsafe: read(analysis_ptr)
                emit_module_diagnostics(loaded, analysis.diagnostics.as_span(), diagnostics)
                if cache == null:
                    analysis.diagnostics.release()
                analyses.push(analysis)
        else:
            var rebuilt = true
            if cache != null:
                rebuilt = module_needs_rebuild(cache, run, index, modules, visited, order_positions)
            if rebuilt:
                check_and_bind_module(module_ptr, index, bindings_ptr, analyses, diagnostics, require_resolved_imports, run)
            else:
                reuse_cached_module(module_ptr, cache, bindings_ptr, analyses, diagnostics)
        oi += 1


## Pass 1's analysis region for a cycle member: created once per member when a
## cache will carry it past the request boundary, so pass-2 type values that
## borrow pass-1 data stay valid for the cache entry's lifetime.  The map's copy
## is returned so the entry later receives the same region.
function cycle_pass1_region(cache: ptr[ModuleCache]?, regions: ref[map_mod.Map[ptr_uint, heap.Region]], index: ptr_uint) -> ptr[heap.Region]?:
    if cache == null:
        return null
    var region = heap.create_region()
    regions.set(index, region)
    return regions.get(index)


## Load and check the program rooted at `root_path`, resolving imports against
## `roots` for the active `platform`.
## Absolute, normalized form of `path` (mirrors Ruby's File.expand_path):
## relative paths resolve against the current directory and `.`/`..` segments
## collapse.  Module paths feed diagnostics, `#line` directives, and `--sexpr`
## dumps, all of which the Ruby compiler renders absolute.
public function absolute_path(path: str) -> string.String:
    var full = string.String.create()
    defer: full.release()
    if path_ops.is_absolute(path):
        full.append(path)
    else:
        match fs.current_directory():
            Result.success as cwd_payload:
                var cwd = cwd_payload.value
                defer: cwd.release()
                full.append(cwd.as_str())
                full.push_byte('/')
                full.append(path)
            Result.failure:
                full.append(path)
    var segments = vec.Vec[string.String].create()
    defer: segments.release()
    let text_path = full.as_str()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= text_path.len:
        if i == text_path.len or text_path.byte_at(i) == 47:
            if i > start:
                let seg = text_path.slice(start, i - start)
                if seg == "..":
                    match segments.pop():
                        Option.some as p:
                            var owned = p.value
                            owned.release()
                        Option.none:
                            pass
                else if seg != ".":
                    segments.push(string.String.from_str(seg))
            start = i + 1
        i += 1
    var result = string.String.create()
    result.push_byte('/')
    var si: ptr_uint = 0
    while si < segments.len():
        if si > 0:
            result.push_byte('/')
        let sp = segments.get(si) else:
            break
        result.append(unsafe: read(sp).as_str())
        si += 1
    return result


public function check_program(root_path: str, roots: span[str], platform: resolver.Platform) -> Program:
    return check_program_with_source(root_path, roots, platform, "", false, null, null)


## check_program with an explicit root-module source override.  When
## `root_source` is non-empty it is parsed as the root module's text instead of
## reading the file from disk — the LSP analyses unsaved editor buffers.
## `open_docs` maps absolute paths to open editor buffers; a module with a
## buffer is parsed from it, otherwise from disk (the host's
## `source_overrides`).  `require_resolved_imports` selects the LSP's
## unresolved-import handling (aliases stay unbound).  A non-null `cache`
## reuses already parsed modules and — when a module's own content and every
## direct import's analysis are unchanged — the module's analysis and export
## binding, so an edit only re-parses and re-analyzes the edited module and its
## dependents instead of the whole import closure.
public function check_program_with_source(root_path: str, roots: span[str], platform: resolver.Platform, root_source: str, require_resolved_imports: bool, cache: ptr[ModuleCache]?, open_docs: ptr[map_mod.Map[string.String, string.String]]?) -> Program:
    # Normalize the module roots to absolute paths once so every resolved
    # module path is absolute and consistent with the Ruby loader.
    var owned_roots = vec.Vec[string.String].create()
    defer: owned_roots.release()
    var abs_roots = vec.Vec[str].create()
    defer: abs_roots.release()
    var ri: ptr_uint = 0
    while ri < roots.len:
        var abs = absolute_path(unsafe: read(roots.data + ri))
        abs_roots.push(abs.as_str())
        owned_roots.push(abs)
        ri += 1
    let norm_roots = abs_roots.as_span()

    var modules = vec.Vec[LoadedModule].create()
    var visited = map_mod.Map[str, ptr_uint].create()
    var on_stack = map_mod.Map[str, bool].create()
    var order = vec.Vec[ptr_uint].create()
    var diagnostics = vec.Vec[LoadDiagnostic].create()
    var unresolved_import_paths = vec.Vec[string.String].create()

    # Per-run bookkeeping: each module's resolved import paths and the open
    # editor buffers.  The vectors stay empty and unread when `cache` is null.
    var run = LoadRun(
        cache = cache,
        open_docs = open_docs,
        dep_paths = vec.Vec[vec.Vec[string.String]].create(),
    )
    defer: release_load_run(ref_of(run))

    # Absolutize the root path so module-name inference can match it against
    # the normalized (absolute) roots, like Ruby's File.expand_path in load_file.
    var root_abs = absolute_path(root_path)
    defer: root_abs.release()
    var root_resolved = resolver.resolve_source_path(root_abs.as_str(), platform)
    # The host's `resolve_source_path` raises when a file pinned to one platform
    # (`name.windows.mt`) is loaded for another — the platform guard that keeps
    # `std/fs.windows.mt` out of a linux analysis.  Report it as a load failure
    # so `check`/`build` reject the file exactly as the host does.
    match resolver.platform_suffix_for_path(root_abs.as_str()):
        Option.some as pinned:
            if pinned.value != platform:
                var message = string.String.create()
                message.append("source file targets platform ")
                message.append(resolver.platform_suffix(pinned.value))
                message.append("; active platform is ")
                message.append(resolver.platform_suffix(platform))
                return empty_program_with_diagnostics(root_abs.as_str(), message)
        Option.none:
            pass
    var root_name_owner = resolver.infer_module_name(root_resolved.as_str(), norm_roots)
    defer: root_name_owner.release()

    # Seed the language prelude modules (std.option, std.result) so their real
    # `extending Option[T]:` / `extending Result[T,E]:` method bodies are parsed,
    # checked, and available for monomorphization — mirroring Ruby's
    # PreludeInstaller.  Parsing them first also makes them dependency-first in
    # `order`, so they are checked before any consumer.  A prelude that cannot be
    # resolved is skipped silently (the analyzer still synthesizes the types).
    seed_prelude_module("std.option", norm_roots, platform, root_name_owner.as_str(), "", ref_of(modules), ref_of(visited), ref_of(on_stack), ref_of(order), ref_of(diagnostics), ref_of(unresolved_import_paths), ref_of(run))
    seed_prelude_module("std.result", norm_roots, platform, root_name_owner.as_str(), "", ref_of(modules), ref_of(visited), ref_of(on_stack), ref_of(order), ref_of(diagnostics), ref_of(unresolved_import_paths), ref_of(run))

    # `parse_all` takes ownership of the resolved path, so keep a copy for the
    # post-parse root reordering below.
    var root_key_owner = string.String.from_str(root_resolved.as_str())
    defer: root_key_owner.release()

    parse_all(
        root_resolved,
        norm_roots,
        platform,
        root_key_owner.as_str(),
        root_source,
        ref_of(modules),
        ref_of(visited),
        ref_of(on_stack),
        ref_of(order),
        ref_of(diagnostics),
        ref_of(unresolved_import_paths),
        ref_of(run),
    )

    # When the requested root was already parsed as a prelude dependency
    # (e.g. lowering std/option.mt), move it to the end of `order` so it is
    # still the program root — the last analysis.
    let root_index_ptr = visited.get(root_key_owner.as_str())
    if root_index_ptr != null:
        let root_index = unsafe: read(ptr[ptr_uint]<-root_index_ptr)
        var root_is_last = false
        let last_ptr = order.last()
        if last_ptr != null:
            unsafe:
                root_is_last = read(last_ptr) == root_index
        if not root_is_last:
            var reordered = vec.Vec[ptr_uint].create()
            var ri: ptr_uint = 0
            while ri < order.len():
                let vp = order.get(ri) else:
                    break
                unsafe:
                    if read(vp) != root_index:
                        reordered.push(read(vp))
                ri += 1
            reordered.push(root_index)
            order.release()
            order = reordered

    on_stack.release()

    # Each module's position in the check order, so the reuse decision can tell
    # a cycle's back-edge (checked after the module) from a forward dependency.
    # `visited` maps a module's direct imports to their module indices, so it
    # stays alive through the check loop.
    var order_positions = vec.Vec[ptr_uint].create()
    defer: order_positions.release()
    if cache != null:
        var init_i: ptr_uint = 0
        while init_i < modules.len():
            order_positions.push(modules.len())
            init_i += 1
        var pos_i: ptr_uint = 0
        while pos_i < order.len():
            let module_index_ptr = order.get(pos_i) else:
                break
            var module_index: ptr_uint
            unsafe:
                module_index = read(module_index_ptr)
            let position_ptr = order_positions.get(module_index) else:
                break
            unsafe:
                read(position_ptr) = pos_i
            pos_i += 1

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

    var cycle_members = detect_cycle_members(ref_of(run), ref_of(visited), modules.len())
    var cycle_module_names = collect_cycle_module_names(ref_of(modules), ref_of(cycle_members))
    if cycle_members.len() > 0:
        check_cyclic_program(ref_of(modules), ref_of(visited), ref_of(order), ref_of(run), cache, ref_of(cycle_members), bindings_ptr, ref_of(analyses), ref_of(diagnostics), require_resolved_imports, ref_of(order_positions))
    else:
        var oi: ptr_uint = 0
        while oi < order.len():
            let index_ptr = order.get(oi) else:
                break
            let index = unsafe: read(index_ptr)
            let module_ptr = modules.get(index) else:
                break
            var rebuilt = true
            if cache != null:
                rebuilt = module_needs_rebuild(cache, ref_of(run), index, ref_of(modules), ref_of(visited), ref_of(order_positions))
            if rebuilt:
                check_and_bind_module(module_ptr, index, bindings_ptr, ref_of(analyses), ref_of(diagnostics), require_resolved_imports, ref_of(run))
            else:
                reuse_cached_module(module_ptr, cache, bindings_ptr, ref_of(analyses), ref_of(diagnostics))
            oi += 1
    visited.release()
    # `bindings` must outlive the analyses: each Analysis keeps a stable handle
    # to this map for later re-analysis (the fix engine).  Leaked at program end
    # like the retained analyses, per the analyzer's arena convention.

    var owning_type_names = build_owning_type_names(ref_of(analyses))

    # Reorder the analyses into the canonical module order the Ruby host uses
    # for lowering (`Lowering#compute_ordered_analysis_pairs`): depth-first
    # post-order over module names sorted lexicographically, with each module's
    # imported module names sorted lexicographically as well.  The IR fragment
    # order — and therefore the emitted C — depends on this order.
    var canonical_analyses = canonical_analysis_order(analyses.as_span())
    var root_index: ptr_uint = 0
    if canonical_analyses.len() > 0:
        root_index = canonical_analyses.len() - 1
    var ci: ptr_uint = 0
    while ci < canonical_analyses.len():
        let cap = canonical_analyses.get(ci) else:
            break
        unsafe:
            if read(cap).module_name == root_name_owner.as_str():
                root_index = ci
        ci += 1
    analyses.release()

    return Program(modules = modules, order = order, analyses = canonical_analyses, diagnostics = diagnostics, owning_type_names = owning_type_names, root_index = root_index, unresolved_import_paths = unresolved_import_paths, modules_owned = cache == null, cycle_module_names = cycle_module_names)


## Canonical module order: depth-first post-order over the module names sorted
## lexicographically, visiting each module's imported module names in
## lexicographic order (host `canonical_module_names`).  A module already on the
## current DFS path is skipped, which breaks import cycles like
## `std.option` <-> `std.result`.
function canonical_analysis_order(analyses: span[analyzer.Analysis]) -> vec.Vec[analyzer.Analysis]:
    var by_name = map_mod.Map[str, ptr_uint].create()
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(analyses.data + i)
        if not by_name.contains(a.module_name):
            by_name.set(a.module_name, i)
            names.push(a.module_name)
        i += 1
    sort_module_names(ref_of(names))
    var visited = map_mod.Map[str, bool].create()
    var on_stack = map_mod.Map[str, bool].create()
    var ordered_names = vec.Vec[str].create()
    var ni: ptr_uint = 0
    while ni < names.len():
        let name_ptr = names.get(ni) else:
            break
        visit_analysis_name(analyses, ref_of(by_name), ref_of(visited), ref_of(on_stack), ref_of(ordered_names), unsafe: read(name_ptr))
        ni += 1
    var result = vec.Vec[analyzer.Analysis].create()
    var oi: ptr_uint = 0
    while oi < ordered_names.len():
        let name_ptr = ordered_names.get(oi) else:
            break
        let name = unsafe: read(name_ptr)
        let idx_ptr = by_name.get(name) else:
            oi += 1
            continue
        let idx = unsafe: read(idx_ptr)
        result.push(unsafe: read(analyses.data + idx))
        oi += 1
    by_name.release()
    names.release()
    visited.release()
    on_stack.release()
    ordered_names.release()
    return result


function visit_analysis_name(analyses: span[analyzer.Analysis], by_name: ref[map_mod.Map[str, ptr_uint]], visited: ref[map_mod.Map[str, bool]], on_stack: ref[map_mod.Map[str, bool]], ordered: ref[vec.Vec[str]], name: str) -> void:
    if visited.contains(name) or on_stack.contains(name):
        return
    let idx_ptr = by_name.get(name) else:
        return
    let idx = unsafe: read(idx_ptr)
    on_stack.set(name, true)
    var deps = vec.Vec[str].create()
    var imports_iter = unsafe: read(analyses.data + idx).imports.values()
    while true:
        let dep_ptr = imports_iter.next() else:
            break
        var dep: str
        unsafe:
            dep = read(dep_ptr)
        if dep != name and by_name.contains(dep) and not str_vec_contains(deps.as_span(), dep):
            deps.push(dep)
    sort_module_names(ref_of(deps))
    var di: ptr_uint = 0
    while di < deps.len():
        let dep_ptr = deps.get(di) else:
            break
        visit_analysis_name(analyses, by_name, visited, on_stack, ordered, unsafe: read(dep_ptr))
        di += 1
    on_stack.set(name, false)
    visited.set(name, true)
    ordered.push(name)
    deps.release()


function str_vec_contains(items: span[str], value: str) -> bool:
    var i: ptr_uint = 0
    while i < items.len:
        unsafe:
            if read(items.data + i) == value:
                return true
        i += 1
    return false


## Insertion sort in byte order (host sorts module names lexicographically).
function sort_module_names(items: ref[vec.Vec[str]]) -> void:
    var i: ptr_uint = 1
    while i < items.len():
        var j = i
        while j > 0:
            let a_ptr = items.get(j - 1) else:
                break
            let b_ptr = items.get(j) else:
                break
            var a: str
            var b: str
            unsafe:
                a = read(a_ptr)
                b = read(b_ptr)
            if module_name_less(a, b):
                break
            items.swap(j - 1, j)
            j -= 1
        i += 1


function module_name_less(left: str, right: str) -> bool:
    var index: ptr_uint = 0
    let shared = if left.len < right.len: left.len else: right.len
    while index < shared:
        let lb = left.byte_at(index)
        let rb = right.byte_at(index)
        if lb < rb:
            return true
        if lb > rb:
            return false
        index += 1
    return left.len < right.len


## Scan all loaded module analyses' method_keys for entries ending with ".release"
## and extract the type name part.  Types with a `release()` method are "owning"
## types — bindings of these types should trigger an owning-release-leak warning
## when they are never released.
function build_owning_type_names(analyses: ref[vec.Vec[analyzer.Analysis]]) -> vec.Vec[str]:
    var seen = map_mod.Map[str, bool].create()
    var names = vec.Vec[str].create()
    var ai: ptr_uint = 0
    while ai < analyses.len():
        let analysis_ptr = analyses.get(ai) else:
            break
        unsafe:
            var keys = read(analysis_ptr).method_keys.keys()
            while true:
                let key_ptr = keys.next() else:
                    break
                var key = read(key_ptr)
                let dot = key.find_byte('.')
                if dot.is_some():
                    let dot_pos = dot.unwrap()
                    if dot_pos + 1 < key.len:
                        let suffix = key.slice(dot_pos + 1, key.len - dot_pos - 1)
                        if suffix.equal("release"):
                            let base = key.slice(0, dot_pos)
                            if not seen.contains(base):
                                seen.set(base, true)
                                names.push(base)
        ai += 1
    seen.release()
    return names


## Resolve and parse a prelude module (e.g. std.option) into the module set so
## its declarations — in particular the `extending` method bodies — are checked
## and available to lowering.  Unresolvable prelude modules are skipped silently
## because the analyzer synthesizes the prelude types regardless.
function seed_prelude_module(
    module_name: str,
    roots: span[str],
    platform: resolver.Platform,
    skip_path: str,
    root_source: str,
    modules: ref[vec.Vec[LoadedModule]],
    visited: ref[map_mod.Map[str, ptr_uint]],
    on_stack: ref[map_mod.Map[str, bool]],
    order: ref[vec.Vec[ptr_uint]],
    diagnostics: ref[vec.Vec[LoadDiagnostic]],
    unresolved_import_paths: ref[vec.Vec[string.String]],
    run: ref[LoadRun],
) -> void:
    match resolver.resolve_module_path(module_name, roots, platform):
        Result.success as resolved_ok:
            # When the requested root *is* the prelude module, leave it to
            # parse_all so it stays the program root (last in `order`).  The
            # module name is compared because the resolved paths can differ in
            # composition (variant/platform forms).
            if module_name == skip_path:
                resolved_ok.value.release()
                return
            parse_all(resolved_ok.value, roots, platform, "", root_source, modules, visited, on_stack, order, diagnostics, unresolved_import_paths, run)
        Result.failure as failure:
            var error = failure.error
            error.release()


## The open editor buffer for a module path, when the client has the document
## open — the host's `source_overrides`.  The returned String is an owned copy
## the caller (the parsed module) keeps; None when the module reads from disk.
function module_buffer_source(run: ref[LoadRun], key: str) -> Option[string.String]:
    let open_docs = run.open_docs
    if open_docs == null:
        return Option[string.String].none
    var buffer_key = string.String.from_str(key)
    defer: buffer_key.release()
    let buffer_ptr = unsafe: read(open_docs).get(buffer_key)
    if buffer_ptr == null:
        return Option[string.String].none
    return Option[string.String].some(value = string.String.from_str(unsafe: read(buffer_ptr).as_str()))


## Depth-first transitive parse.  Uses three-colour marking: `on_stack` (gray,
## in progress) detects import cycles, `visited` (black, fully parsed) dedups
## shared dependencies.  A module is appended to `order` in post-order, yielding
## a dependency-first ordering.  Takes ownership of `resolved`.
function parse_all(
    resolved: string.String,
    roots: span[str],
    platform: resolver.Platform,
    root_key: str,
    root_source: str,
    modules: ref[vec.Vec[LoadedModule]],
    visited: ref[map_mod.Map[str, ptr_uint]],
    on_stack: ref[map_mod.Map[str, bool]],
    order: ref[vec.Vec[ptr_uint]],
    diagnostics: ref[vec.Vec[LoadDiagnostic]],
    unresolved_import_paths: ref[vec.Vec[string.String]],
    run: ref[LoadRun],
) -> void:
    var owned_path = resolved
    let key = owned_path.as_str()

    if visited.contains(key):
        owned_path.release()
        return

    if on_stack.contains(key):
        # A back-edge closes an import cycle.  The host treats cycles as legal
        # and analyses their members with pre-registered forward bindings; the
        # check phase detects the cycle members from the recorded dependency
        # paths and runs the two-pass analysis.  The edge itself was recorded by
        # the importer before this recursive parse, so the graph stays complete.
        owned_path.release()
        return

    var source: string.String
    if root_source.len > 0 and key.equal(root_key):
        source = string.String.from_str(root_source)
    else:
        match module_buffer_source(run, key):
            Option.some as buffered_source:
                source = buffered_source.value
            Option.none:
                match fs.read_text(key):
                    Result.failure as failure:
                        var error = failure.error
                        diagnostics.push(LoadDiagnostic(
                            path = string.String.from_str(key),
                            line = 0,
                            column = 0,
                            length = 0,
                            message = string.String.from_str("source file not found"),
                            severity = "error",
                            code = "module/error",
                            symbol_name = string.String.from_str(""),
                        ))
                        error.release()
                        owned_path.release()
                        return
                    Result.success as payload:
                        source = payload.value

    # Cache reuse: identical content means the cached parse — its owned source,
    # the AST, and the captured lex/parse diagnostics — is still current.  The
    # freshly read copy (or the root-source copy) is dropped.  The module's
    # cached path is what the walk's maps key on, because the released
    # `owned_path` would dangle as a map key.
    if run.cache != null:
        let entry_ptr = module_cache_entry(run.cache, key)
        if entry_ptr != null:
            var reused = false
            unsafe:
                reused = read(entry_ptr).content_hash == fnv1a_hash(source.as_str())
            if reused:
                source.release()
                owned_path.release()
                var cached: LoadedModule
                unsafe:
                    cached = read(entry_ptr).module
                let cached_key = cached.path.as_str()
                modules.push(cached)
                let index = modules.len() - 1
                run.dep_paths.push(vec.Vec[string.String].create())
                on_stack.set(cached_key, true)
                recurse_imports(cached.source_file, cached_key, index, roots, platform, root_key, root_source, modules, visited, on_stack, order, diagnostics, unresolved_import_paths, run)
                let _dropped = on_stack.remove(cached_key)
                visited.set(cached_key, index)
                order.push(index)
                return

    var parse_diagnostics = vec.Vec[pstate.ParseDiagnostic].create()
    var lex_diagnostics = vec.Vec[token_mod.LexDiagnostic].create()
    # With a cache in use the parse's allocations — token buffers, AST nodes and
    # vectors, synthesized strings, the two diagnostics vectors' buffers — belong
    # to this region, which the module's cache entry owns and releases when the
    # entry is replaced.  Everything around the parse call (the read source, the
    # module name, the walk's maps and vectors, the cache store) stays ordinary
    # heap, so it must not run while the region is active.
    var parse_region = heap.create_region()
    var previous_region: ptr[heap.Region]? = null
    if run.cache != null:
        previous_region = heap.begin_region(ptr_of(parse_region))
    let source_file = parser.parse_source_reporting(source.as_str(), ref_of(parse_diagnostics), ref_of(lex_diagnostics))
    if run.cache != null:
        heap.end_region(previous_region)
    let module_name = resolver.infer_module_name(key, roots)

    on_stack.set(key, true)
    let loaded = LoadedModule(
        module_name = module_name,
        path = owned_path,
        source = source,
        source_file = source_file,
        parse_diagnostics = parse_diagnostics,
        lex_diagnostics = lex_diagnostics,
    )
    modules.push(loaded)
    let index = modules.len() - 1
    if run.cache != null:
        module_cache_store_module(run.cache, key, fnv1a_hash(source.as_str()), loaded, parse_region)
    run.dep_paths.push(vec.Vec[string.String].create())

    recurse_imports(source_file, key, index, roots, platform, root_key, root_source, modules, visited, on_stack, order, diagnostics, unresolved_import_paths, run)

    let _dropped = on_stack.remove(key)
    visited.set(key, index)
    order.push(index)


## Resolve and recursively parse each `import` of a parsed module.  An import
## that cannot be resolved is recorded as a diagnostic rather than aborting.
function recurse_imports(
    source_file: ast.SourceFile,
    importer_path: str,
    importer_index: ptr_uint,
    roots: span[str],
    platform: resolver.Platform,
    root_key: str,
    root_source: str,
    modules: ref[vec.Vec[LoadedModule]],
    visited: ref[map_mod.Map[str, ptr_uint]],
    on_stack: ref[map_mod.Map[str, bool]],
    order: ref[vec.Vec[ptr_uint]],
    diagnostics: ref[vec.Vec[LoadDiagnostic]],
    unresolved_import_paths: ref[vec.Vec[string.String]],
    run: ref[LoadRun],
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
                        let slot = run.dep_paths.get(importer_index)
                        if slot != null:
                            unsafe:
                                read(slot).push(string.String.from_str(resolved_ok.value.as_str()))
                        parse_all(
                            resolved_ok.value,
                            roots,
                            platform,
                            root_key,
                            root_source,
                            modules,
                            visited,
                            on_stack,
                            order,
                            diagnostics,
                            unresolved_import_paths,
                            run,
                        )
                    Result.failure as resolve_failure:
                        var error = resolve_failure.error
                        var message = string.String.from_str("module not found: ")
                        message.append(module_name)
                        unresolved_import_paths.push(string.String.from_str(module_name))
                        diagnostics.push(LoadDiagnostic(
                            path = string.String.from_str(importer_path),
                            line = imported.line,
                            column = imported.column,
                            length = module_name.len,
                            message = message,
                            severity = "error",
                            code = "module/error",
                            symbol_name = string.String.from_str(module_name),
                        ))
                        error.release()
            _:
                pass
        i += 1


## Semantically check one parsed module against the accumulated import bindings,
## append its parse and semantic diagnostics (as owned copies) to the
## program-wide list, register the module's own export binding, and retain its
## `Analysis` for the Lowering stage.  Parse and lex diagnostics are reported
## first; semantic analysis still runs on the recovered AST, mirroring the
## host's LSP pipeline.  With a cache in use the analysis (and its retained
## diagnostics) is also stored back into the module's entry.
function check_and_bind_module(
    module_ptr: ptr[LoadedModule],
    module_index: ptr_uint,
    bindings_ptr: ptr[map_mod.Map[str, analyzer.ModuleBinding]],
    analyses: ref[vec.Vec[analyzer.Analysis]],
    diagnostics: ref[vec.Vec[LoadDiagnostic]],
    require_resolved_imports: bool,
    run: ref[LoadRun],
) -> void:
    let loaded = unsafe: read(module_ptr)

    # Semantic analysis runs even when the parser reported errors: the
    # recovered AST still yields facts and diagnostics, matching the host's
    # LSP pipeline (which continues past parse errors).  With a cache in use
    # the analyzer's and binder's allocations — the context's maps and vectors,
    # the types it allocates, the binding's tables, the retained diagnostics
    # vector — belong to the analysis region, which the entry owns and releases
    # (or quarantines) when the analysis is replaced.  The emitted diagnostic
    # copies and the `analyses` vector are ordinary heap: they run outside.
    var analysis_region = heap.create_region()
    var previous_region: ptr[heap.Region]? = null
    if run.cache != null:
        previous_region = heap.begin_region(ptr_of(analysis_region))
    var analysis: analyzer.Analysis
    if require_resolved_imports:
        analysis = analyzer.check_module_requiring_resolved_imports(loaded.source_file, bindings_ptr, loaded.module_name.as_str(), loaded.path.as_str())
    else:
        analysis = analyzer.check_module(loaded.source_file, bindings_ptr, loaded.module_name.as_str(), loaded.path.as_str())
    if run.cache != null:
        let binding = binder.bind_module(analysis)
        heap.end_region(previous_region)
        emit_module_diagnostics(loaded, analysis.diagnostics.as_span(), diagnostics)
        # Keep the analysis' diagnostics: the entry owns them and a later run
        # that reuses this module re-emits them from there.
        module_cache_store_analysis(run.cache, loaded.path.as_str(), module_index, run, analysis, binding, analysis_region)
        unsafe:
            read(bindings_ptr).set(loaded.module_name.as_str(), binding)
    else:
        emit_module_diagnostics(loaded, analysis.diagnostics.as_span(), diagnostics)
        analysis.diagnostics.release()
        unsafe:
            read(bindings_ptr).set(loaded.module_name.as_str(), binder.bind_module(analysis))
    analyses.push(analysis)


## Append a loaded module's lexer, parser and semantic diagnostics (as owned
## LoadDiagnostic copies) to the program-wide list, in pipeline order.
function emit_module_diagnostics(loaded: LoadedModule, sema: span[analyzer.SemanticDiagnostic], diagnostics: ref[vec.Vec[LoadDiagnostic]]) -> void:
    unsafe:
        # Lexer diagnostics come first and are always reported (the host emits
        # `lex/error` items alongside the parser's recovered errors).
        var li: ptr_uint = 0
        while li < loaded.lex_diagnostics.len():
            let lex_ptr = loaded.lex_diagnostics.get(li) else:
                break
            let lex_diag = read(lex_ptr)
            diagnostics.push(LoadDiagnostic(
                path = string.String.from_str(loaded.path.as_str()),
                line = lex_diag.line,
                column = lex_diag.column,
                length = 1,
                message = string.String.from_str(text.cstr_as_str(lex_diag.message)),
                severity = "error",
                code = "lex/error",
                symbol_name = string.String.from_str(""),
            ))
            li += 1

        var pi: ptr_uint = 0
        while pi < loaded.parse_diagnostics.len():
            let parse_ptr = loaded.parse_diagnostics.get(pi) else:
                break
            let parse_diag = read(parse_ptr)
            diagnostics.push(LoadDiagnostic(
                path = string.String.from_str(loaded.path.as_str()),
                line = parse_diag.line,
                column = parse_diag.column,
                length = parse_diag.lexeme.len,
                message = string.String.from_str(text.cstr_as_str(parse_diag.message)),
                severity = "error",
                code = "parse/error",
                symbol_name = string.String.from_str(""),
            ))
            pi += 1

        var si: ptr_uint = 0
        while si < sema.len:
            var sema_diag: analyzer.SemanticDiagnostic
            unsafe:
                sema_diag = read(sema.data + si)
            diagnostics.push(LoadDiagnostic(
                path = string.String.from_str(loaded.path.as_str()),
                line = sema_diag.line,
                column = sema_diag.column,
                length = sema_diag.length,
                message = string.String.from_str(sema_diag.message),
                severity = "error",
                code = "sema/error",
                symbol_name = string.String.from_str(""),
            ))
            si += 1


## Reuse a cached module's analysis: re-emit its diagnostics (the entry retains
## them) and re-register its export binding, without re-analyzing it.
function reuse_cached_module(
    module_ptr: ptr[LoadedModule],
    cache: ptr[ModuleCache]?,
    bindings_ptr: ptr[map_mod.Map[str, analyzer.ModuleBinding]],
    analyses: ref[vec.Vec[analyzer.Analysis]],
    diagnostics: ref[vec.Vec[LoadDiagnostic]],
) -> void:
    let loaded = unsafe: read(module_ptr)
    let entry_ptr = module_cache_entry(cache, loaded.path.as_str()) else:
        return
    var analysis_mem: ptr[analyzer.Analysis]?
    var binding_mem: ptr[analyzer.ModuleBinding]?
    unsafe:
        analysis_mem = read(entry_ptr).analysis_ptr
        binding_mem = read(entry_ptr).binding_ptr
    if analysis_mem != null:
        let analysis_value = unsafe: read(analysis_mem)
        emit_module_diagnostics(loaded, analysis_value.diagnostics.as_span(), diagnostics)
        analyses.push(analysis_value)
    if binding_mem != null:
        unsafe:
            read(bindings_ptr).set(loaded.module_name.as_str(), read(binding_mem))
