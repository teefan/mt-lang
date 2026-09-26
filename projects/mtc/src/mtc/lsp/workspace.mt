## Workspace state — open documents, module roots, and the root path.
##
## One Workspace instance lives for the lifetime of the server.  Document
## content is stored by URI using owned string.String keys (not borrowed str)
## because URI strings from incoming JSON messages are ephemeral.

import std.fs as fs_mod
import std.map as map_mod
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec
import std.log as log

import mtc.lexer.token as tok
import mtc.loader.package_manifest as package_manifest
import mtc.loader.path_resolver as resolver_mod
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace_index as idx


struct DiagnosticCacheEntry:
    source_hash: uint
    result_id: string.String
    diagnostics_json: string.String


## Workspace state for pull diagnostics.  Caches the last computed
## diagnostics per file so subsequent pulls with an unchanged source can
## return `kind: "unchanged"` without recomputing.
public struct DiagnosticCache:
    entries: map_mod.Map[string.String, DiagnosticCacheEntry]


struct SemanticTokenCacheEntry:
    source_hash: uint
    result_id: string.String
    token_count: ptr_uint


public struct Workspace:
    root_path: string.String
    module_roots: vec.Vec[string.String]
    open_docs: map_mod.Map[string.String, string.String]
    ## Open document paths in didOpen order: `workspace/diagnostic` reports
    ## documents in the client's open order, which a hash map cannot express.
    open_doc_order: vec.Vec[string.String]
    document_contexts: map_mod.Map[string.String, string.String]
    cancelled_ids: vec.Vec[ptr_uint]
    diagnostic_cache: DiagnosticCache
    semantic_token_cache: map_mod.Map[string.String, SemanticTokenCacheEntry]
    config_request_id: ptr_uint
    config_received: bool
    index_built: bool
    index: idx.Index
    format_mode: string.String
    dependency_resolution_mode: string.String
    platform_override: string.String
    strict_current_root_diagnostics: bool


extending Workspace:
    public static function create(root: str) -> Workspace:
        var roots = vec.Vec[string.String].create()
        discover_project_root(root, ref_of(roots))
        append_compiler_module_roots(root, ref_of(roots))
        return Workspace(
            root_path = string.String.from_str(root),
            module_roots = roots,
            open_docs = map_mod.Map[string.String, string.String].create(),
            open_doc_order = vec.Vec[string.String].create(),
            document_contexts = map_mod.Map[string.String, string.String].create(),
            cancelled_ids = vec.Vec[ptr_uint].create(),
            diagnostic_cache = DiagnosticCache(entries = map_mod.Map[string.String, DiagnosticCacheEntry].create()),
            semantic_token_cache = map_mod.Map[string.String, SemanticTokenCacheEntry].create(),
            config_request_id = 0,
            config_received = false,
            index_built = false,
            index = idx.Index(entries = vec.Vec[idx.Entry].create()),
            format_mode = string.String.create(),
            dependency_resolution_mode = string.String.create(),
            platform_override = string.String.create(),
            strict_current_root_diagnostics = false,
        )


    ## Re-root the workspace from the client's `initialize` rootUri, mirroring
    ## the host's `workspace_root_path=` assignment.  The workspace root itself
    ## is a module root (imports resolve relative to it), followed by the
    ## discovered project root (the nearest `std/` ancestor).  The index and the
    ## diagnostic cache are dropped so they rebuild against the new root.
    public editable function set_root(path: str) -> void:
        if path.len == 0:
            return
        this.root_path.release()
        this.root_path = string.String.from_str(path)
        release_module_roots(ref_of(this.module_roots))
        this.module_roots = vec.Vec[string.String].create()
        this.module_roots.push(string.String.from_str(path))
        discover_project_root(path, ref_of(this.module_roots))
        append_compiler_module_roots(path, ref_of(this.module_roots))
        release_diagnostic_cache(ref_of(this.diagnostic_cache))
        this.diagnostic_cache = DiagnosticCache(entries = map_mod.Map[string.String, DiagnosticCacheEntry].create())
        if this.index_built:
            idx.release_index(ref_of(this.index))
            this.index = idx.Index(entries = vec.Vec[idx.Entry].create())
            this.index_built = false


    public editable function open(uri: str, text: str) -> void:
        let path_result = uri_ops.file_uri_to_path(uri)
        match path_result:
            Option.some as path_payload:
                this.track_open_path(path_payload.value.as_str())
                this.open_docs.set(path_payload.value, string.String.from_str(text))
            Option.none:
                pass


    public editable function change(uri: str, text: str) -> void:
        let path_result = uri_ops.file_uri_to_path(uri)
        match path_result:
            Option.some as path_payload:
                this.track_open_path(path_payload.value.as_str())
                this.open_docs.set(path_payload.value, string.String.from_str(text))
            Option.none:
                pass


    public editable function close(uri: str) -> void:
        let path_result = uri_ops.file_uri_to_path(uri)
        match path_result:
            Option.some as path_payload:
                this.untrack_open_path(path_payload.value.as_str())
                this.open_docs.remove(path_payload.value)
            Option.none:
                pass


    ## Record `path` in didOpen order, once.
    public editable function track_open_path(path: str) -> void:
        var i: ptr_uint = 0
        while i < this.open_doc_order.len():
            let p = this.open_doc_order.get(i) else:
                break
            if unsafe: read(p).as_str().equal(path):
                return
            i += 1
        this.open_doc_order.push(string.String.from_str(path))


    ## Drop `path` from the didOpen-order list.
    public editable function untrack_open_path(path: str) -> void:
        var i: ptr_uint = 0
        while i < this.open_doc_order.len():
            let p = this.open_doc_order.get(i) else:
                break
            if unsafe: read(p).as_str().equal(path):
                match this.open_doc_order.remove(i):
                    Option.some as removed:
                        var owned = removed.value
                        owned.release()
                    Option.none:
                        pass
                return
            i += 1


    ## Source text for a file: the open editor buffer when present, else disk.
    ## Returns an owned copy the caller must release.
    public function document_source(path: str) -> Option[string.String]:
        var key = string.String.from_str(path)
        defer: key.release()
        let doc_ptr = this.open_docs.get(key)
        if doc_ptr != null:
            unsafe:
                return Option[string.String].some(value = string.String.from_str(read(doc_ptr).as_str()))

        match fs_mod.read_text(path):
            Result.success as content:
                return Option[string.String].some(value = content.value)
            Result.failure as failure_payload:
                var err = failure_payload.error
                err.release()
                return Option[string.String].none


    ## Resolve a source file path to the effective module roots for dependency
    ## loading.  Returns a span of root directory paths.
    public function effective_module_roots_for(path: str) -> vec.Vec[str]:
        var result = vec.Vec[str].create()
        var i: ptr_uint = 0
        while i < this.module_roots.len():
            let root_ptr = this.module_roots.get(i) else:
                break
            unsafe:
                result.push(read(root_ptr).as_str())
            i += 1
        return result


    public editable function build_index_if_needed() -> void:
        if not this.index_built:
            log.info("lsp: building workspace index")
            idx.release_index(ref_of(this.index))
            this.index = idx.build_index(ref_of(this.module_roots))
            this.index_built = true
            log.info("lsp: workspace index ready")


    ## Number of currently open documents.
    public function open_document_count() -> ptr_uint:
        return this.open_docs.len()


    ## Keys (file paths) of all currently open documents.  The caller must
    ## release each key and the returned Vec.
    public function open_document_keys() -> vec.Vec[string.String]:
        var result = vec.Vec[string.String].create()
        var key_iter = this.open_docs.keys()
        while true:
            let kp = key_iter.next() else:
                break
            unsafe:
                result.push(string.String.from_str(read(kp).as_str()))
        return result


    ## Open document paths in didOpen order (the client's open order, which
    ## `open_document_keys` cannot express).  Borrowed from the workspace.
    public function open_paths_in_order() -> span[string.String]:
        return this.open_doc_order.as_span()


    ## Number of entries in the workspace symbol index.
    public function index_entries() -> ptr_uint:
        return this.index.entries.len()


    ## Store the document context type (foreground / background) for a URI.
    public editable function set_document_context(uri: str, context: str) -> void:
        let path_result = uri_ops.file_uri_to_path(uri)
        match path_result:
            Option.some as path_payload:
                this.document_contexts.set(path_payload.value, string.String.from_str(context))
            Option.none:
                pass


    ## Mark a request as cancelled by its numeric id.
    public editable function cancel_request(id: ptr_uint) -> void:
        this.cancelled_ids.push(id)


    ## True when the given numeric request id was cancelled.
    public function is_request_cancelled(id: ptr_uint) -> bool:
        var i: ptr_uint = 0
        while i < this.cancelled_ids.len():
            let cid = this.cancelled_ids.get(i) else:
                break
            unsafe:
                if read(cid) == id:
                    return true
            i += 1
        return false


    ## Remove a cancelled id after the request has been processed.
    public editable function clear_cancelled(id: ptr_uint) -> void:
        var i: ptr_uint = 0
        while i < this.cancelled_ids.len():
            let cid = this.cancelled_ids.get(i) else:
                break
            unsafe:
                if read(cid) == id:
                    this.cancelled_ids.swap_remove(i)
                    break
            i += 1


    ## Look up a cached diagnostic entry for a file path.  Returns the
    ## cache entry pointer when present, or null on miss.
    public function diagnostic_cache_get(path: str) -> ptr[DiagnosticCacheEntry]?:
        var key = string.String.from_str(path)
        defer: key.release()
        return this.diagnostic_cache.entries.get(key)


    ## Store or replace a cached diagnostic entry for a file path.
    public editable function diagnostic_cache_set(
        path: str,
        source_hash: uint,
        result_id: string.String,
        diagnostics_json: string.String,
    ) -> void:
        var key = string.String.from_str(path)
        var entry = DiagnosticCacheEntry(
            source_hash = source_hash,
            result_id = result_id,
            diagnostics_json = diagnostics_json,
        )
        this.diagnostic_cache.entries.set(key, entry)


    ## Clear the diagnostic cache entry for a single file.
    public editable function diagnostic_cache_clear(path: str) -> void:
        var key = string.String.from_str(path)
        defer: key.release()
        this.diagnostic_cache.entries.remove(key)


    ## Clear the entire diagnostic cache.
    public editable function diagnostic_cache_clear_all() -> void:
        this.diagnostic_cache.entries.clear()


    ## Look up a cached semantic token entry for a file path.
    public function semantic_token_cache_get(path: str) -> ptr[SemanticTokenCacheEntry]?:
        var key = string.String.from_str(path)
        defer: key.release()
        return this.semantic_token_cache.get(key)


    ## Store a cached semantic token entry.
    public editable function semantic_token_cache_set(path: str, source_hash: uint, result_id: string.String, token_count: ptr_uint) -> void:
        var key = string.String.from_str(path)
        var entry = SemanticTokenCacheEntry(source_hash = source_hash, result_id = result_id, token_count = token_count)
        this.semantic_token_cache.set(key, entry)


    ## Remove a specific cached semantic token entry.
    public editable function semantic_token_cache_remove(path: str) -> void:
        var key = string.String.from_str(path)
        defer: key.release()
        this.semantic_token_cache.remove(key)


    ## Clear all cached semantic token entries.
    public editable function semantic_token_cache_remove_all() -> void:
        this.semantic_token_cache.clear()


    ## Force a full workspace symbol index rebuild on the next query.
    public editable function force_reindex() -> void:
        if this.index_built:
            idx.release_index(ref_of(this.index))
            this.index = idx.Index(entries = vec.Vec[idx.Entry].create())
            this.index_built = false


    ## Record the outgoing config pull request id.
    public editable function set_pending_config_request(id: ptr_uint) -> void:
        this.config_request_id = id


    ## Request a configuration pull from the client.
    public editable function request_configuration() -> void:
        this.config_received = false


    ## Clear the pending config request tracking.
    public editable function clear_pending_config_request() -> void:
        this.config_request_id = 0


    public editable function release() -> void:
        this.root_path.release()
        release_module_roots(ref_of(this.module_roots))
        this.open_docs.release()
        var oi: ptr_uint = 0
        while oi < this.open_doc_order.len():
            let op = this.open_doc_order.get(oi) else:
                break
            unsafe:
                read(op).release()
            oi += 1
        this.open_doc_order.release()
        this.document_contexts.release()
        this.cancelled_ids.release()
        release_diagnostic_cache(ref_of(this.diagnostic_cache))
        release_semantic_token_cache(ref_of(this.semantic_token_cache))
        if this.index_built:
            idx.release_index(ref_of(this.index))


## Walk upward from source_path to find the project root (the directory
## containing std/ at the top of the source tree).  Pushes discovered roots
## into `roots` as owned string.String values.
public function discover_project_root(source_path: str, roots: ref[vec.Vec[string.String]]) -> void:
    var current = if fs_mod.is_directory(source_path): source_path else: path_ops.dirname(source_path)
    while true:
        var joined = path_ops.join(current, "std")
        defer: joined.release()
        if fs_mod.is_directory(joined.as_str()):
            var i: ptr_uint = 0
            while i < roots.len():
                let ep_ptr = roots.get(i) else:
                    break
                unsafe:
                    if read(ep_ptr).as_str().equal(current):
                        return
                i += 1
            roots.push(string.String.from_str(current))
            return
        let parent = path_ops.dirname(current)
        if parent.equal(current):
            return
        current = parent


## Append the compiler's own roots (`$MILK_TEA_MODULE_ROOT` /
## `$MILK_TEA_STD_ROOT`, then the `std/` next to the running binary) and the
## enclosing package's source root to the workspace's module roots, as
## `ModuleRoots.roots_for_path` does.  This is what lets a project outside the
## compiler's own tree resolve `std.*` and its own modules by bare name.
public function append_compiler_module_roots(path: str, roots: ref[vec.Vec[string.String]]) -> void:
    var candidates = vec.Vec[string.String].create()
    defer: candidates.release()

    match package_manifest.package_source_root_for_path(path):
        Option.some as package_root:
            candidates.push(package_root.value)
        Option.none:
            pass

    var compiler_roots = resolver_mod.compiler_root_candidates()
    defer: compiler_roots.release()
    var ci: ptr_uint = 0
    while ci < compiler_roots.len():
        let entry = compiler_roots.get(ci) else:
            break
        candidates.push(string.String.from_str(unsafe: read(entry).as_str()))
        ci += 1

    var i: ptr_uint = 0
    while i < candidates.len():
        let candidate_entry = candidates.get(i) else:
            break
        let candidate = unsafe: read(candidate_entry).as_str()

        var already_present = false
        var j: ptr_uint = 0
        while j < roots.len():
            let existing = roots.get(j) else:
                break
            if unsafe: read(existing).as_str().equal(candidate):
                already_present = true
                break
            j += 1

        if not already_present:
            roots.push(string.String.from_str(candidate))
        i += 1


function release_module_roots(roots: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < roots.len():
        let ptr = roots.get(i) else:
            break
        unsafe:
            read(ptr).release()
        i += 1
    roots.release()


function release_diagnostic_cache(cache: ref[DiagnosticCache]) -> void:
    var entries_iter = cache.entries.entries()
    while entries_iter.next():
        let entry = entries_iter.current()
        unsafe:
            var entry_value = read(entry.value)
            entry_value.result_id.release()
            entry_value.diagnostics_json.release()
    cache.entries.release()


function release_semantic_token_cache(cache: ref[map_mod.Map[string.String, SemanticTokenCacheEntry]]) -> void:
    var entries_iter = cache.entries()
    while entries_iter.next():
        let entry = entries_iter.current()
        unsafe:
            var entry_value = read(entry.value)
            entry_value.result_id.release()
    cache.release()
