## Workspace state — open documents, module roots, and the root path.
##
## One Workspace instance lives for the lifetime of the server.  Document
## content is stored by URI using owned string.String keys (not borrowed str)
## because URI strings from incoming JSON messages are ephemeral.

import std.fs as fs_mod
import std.map as map_mod
import std.mem.heap as heap
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec
import std.log as log

import mtc.strings as strings
import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.loader.module_loader as loader
import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.loader.package_manifest as package_manifest
import mtc.loader.path_resolver as resolver
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.lsp.definition_index as defidx
import mtc.lsp.reference_index as refidx
import mtc.lsp.scope as scope_mod
import mtc.lsp.uri as uri_ops
import mtc.lsp.utils as utils
import mtc.lsp.workspace_index as idx


## One document's parse and single-file analysis, cached by content
## fingerprint.  Five features need exactly this pair for the same edit, and
## re-parsing plus re-checking a large file per request dominates their cost;
## the AST is cached with the analysis because `resolved_expr_types` is keyed by
## expression pointer.
public struct ParseCacheEntry:
    content_hash: uint
    parse_error_count: ptr_uint
    ## Owned copy of the document text: the AST's and analysis' string views
    ## point into it, so it must outlive them (the caller's buffer is released
    ## at the end of its request, and caching views into it reads freed memory).
    source: string.String
    ast_file: ast.SourceFile
    analysis: analyzer.Analysis
    ## The region that owns the AST's and the single-file analysis' internals
    ## (nodes, vectors, strings); freed when the entry is replaced.
    region: heap.Region


## A loader-backed analysis of one document: the whole import closure is
## loaded and bound, which the single-file `analyzer.check_source_file` path
## cannot do (imported generics and their members stay unresolved there).
## The owning Program is retained so the analysis' name/type views stay valid.
## `cache_generation` is the module cache's generation at build time: any edit
## or re-analysis since then makes this entry stale and it is rebuilt.
public struct AnalysisCacheEntry:
    path: string.String
    content_hash: uint
    cache_generation: ptr_uint
    program: loader.Program
    analysis: analyzer.Analysis


struct DiagnosticCacheEntry:
    source_hash: uint
    result_id: string.String
    diagnostics_json: string.String


## Workspace state for pull diagnostics.  Caches the last computed
## diagnostics per file so subsequent pulls with an unchanged source can
## return `kind: "unchanged"` without recomputing.
public struct DiagnosticCache:
    entries: map_mod.Map[string.String, DiagnosticCacheEntry]


## The one-document lex cache.  Every position lookup (identifier at, token at,
## interpolation at, the keyword/builtin arms, the import path scan) needs the
## same whole-file token stream, and the host reuses one tokenized document per
## request.  The cache holds the last document's stream, keyed by path and
## content hash; a request takes the span once per lookup and never holds it
## across a different document's fetch.
public struct TokenCacheEntry:
    path: string.String
    content_hash: uint
    tokens: vec.Vec[token_mod.Token]


## The one-document scope-binding cache.  `collect_bindings` walks the whole
## AST and every declaration's source lines; hover resolves a local through it
## on every request, so the walk is cached beside its owning source copy (the
## binding names are views into it).
public struct BindingCacheEntry:
    path: string.String
    content_hash: uint
    source: string.String
    bindings: vec.Vec[scope_mod.Binding]


## A document's current text and content fingerprint.  The `str` view is
## produced by one `String.as_str` validation per document version, so the many
## helpers one hover calls share a single UTF-8 scan instead of re-validating
## (and re-hashing) the whole file each time.
public struct DocumentText:
    text: str
    hash: uint


## One open document's client version, for `publishDiagnostics.version` and
## `workspace/diagnostic` items.  A Vec keeps the path ownership explicit (a
## string-keyed map would leak the key on replacement/removal).
struct DocumentVersionEntry:
    path: string.String
    version: ptr_int


## The per-document text cache entry.  An *open* document's `text` is a view
## into its `open_docs` buffer (nothing is copied; the entry is dropped on every
## open/change/close), while a *closed* document owns `source` and is
## revalidated by its stat stamp so an external edit is still noticed.
struct TextCacheEntry:
    source: string.String
    text: str
    hash: uint
    open: bool
    size: ptr_uint
    modified_seconds: ptr_int
    modified_nanoseconds: ptr_int
    ## Byte offset of every line start, for O(line) byte→UTF-16 conversion.
    line_starts: vec.Vec[ptr_uint]


public struct SemanticTokenCacheEntry:
    source_hash: uint
    result_id: string.String
    token_count: ptr_uint
    ## The token data that produced `result_id`, so a `full/delta` request can
    ## diff against what the client actually holds (recomputing from the new
    ## source would compare it with itself and report no edits).
    data: vec.Vec[uint]
    ## The data's column encoding; a cached UTF-8 pass must not be replayed to a
    ## UTF-16 client.
    utf16: bool


public struct Workspace:
    ## The primary root (the first workspace folder); path labels are rendered
    ## relative to it.
    root_path: string.String
    ## Every workspace folder, in client order.  A single-root client has one.
    roots: vec.Vec[string.String]
    module_roots: vec.Vec[string.String]
    open_docs: map_mod.Map[string.String, string.String]
    ## Open document paths in didOpen order: `workspace/diagnostic` reports
    ## documents in the client's open order, which a hash map cannot express.
    open_doc_order: vec.Vec[string.String]
    document_contexts: map_mod.Map[string.String, string.String]
    document_versions: vec.Vec[DocumentVersionEntry]
    ## Lifecycle state: `initialize` sets `initialize_received`, the
    ## `initialized` notification sets `initialized`, and `shutdown` sets
    ## `shutdown_received`.  The message loop gates requests on these flags.
    initialize_received: bool
    initialized: bool
    shutdown_received: bool
    diagnostic_cache: DiagnosticCache
    analysis_cache: map_mod.Map[string.String, AnalysisCacheEntry]
    parse_cache: map_mod.Map[string.String, ParseCacheEntry]
    ## The cross-program module cache: parsed modules and their analyses shared
    ## by every Program this workspace builds, so an edit re-analyzes only the
    ## edited module and its dependents (see `loader.ModuleCache`).
    module_cache: loader.ModuleCache
    ## Files whose content changed since the index was built: they are re-indexed
    ## in place on the next request that needs the index, so symbol search,
    ## completion and references see the edit without a full re-walk.
    index_dirty: vec.Vec[string.String]
    semantic_token_cache: map_mod.Map[string.String, SemanticTokenCacheEntry]
    token_cache: TokenCacheEntry
    binding_cache: BindingCacheEntry
    text_cache: map_mod.Map[string.String, TextCacheEntry]
    config_request_id: ptr_uint
    config_received: bool
    index_built: bool
    index: idx.Index
    ## The host's cross-file definition index (the last-resort definition and
    ## hover-location lookup).
    definition_index: defidx.DefinitionIndex
    ## The host's identifier index: every document whose tokens a request has
    ## asked for, with its identifier tokens.  `references` answers out of it.
    reference_index: refidx.ReferenceIndex
    format_mode: string.String
    dependency_resolution_mode: string.String
    ## The target platform the analyzer resolves platform-suffixed modules
    ## against (`foo.windows.mt`).  Defaults to linux; `milkTea.platform` sets
    ## it, and `analysis_entry_for` passes it to the loader.
    platform: resolver.Platform
    strict_current_root_diagnostics: bool
    ## True when the client advertised pull diagnostics (`textDocument.diagnostic`);
    ## the server then suppresses `publishDiagnostics`, as the host does, so the
    ## client does not show every diagnostic twice.
    pull_diagnostics_active: bool
    ## The negotiated position encoding.  UTF-16 is the LSP default for a client
    ## that advertises nothing; `initialize` switches it to UTF-8 when the
    ## client offers that encoding.  Internal columns are always byte offsets.
    position_encoding_utf16: bool
    ## True when the client advertised dynamic registration for
    ## `workspace/didChangeWatchedFiles`; `initialized` then registers it.
    client_watched_files_dynamic: bool
    watched_files_registered: bool
    ## True when the client advertised `workspace.diagnostics.refreshSupport`;
    ## dependent changes then trigger `workspace/diagnostic/refresh`.
    client_diagnostic_refresh_support: bool
    ## Per-endpoint refresh support for results that can depend on other files.
    client_code_lens_refresh_support: bool
    client_semantic_tokens_refresh_support: bool
    client_inlay_hint_refresh_support: bool
    ## Regions of replaced parse-cache entries, kept alive until the request
    ## boundary (see `drain_retired_regions`).
    retired_regions: vec.Vec[heap.Region]


## The effective module roots for one source file: borrowed workspace roots in
## `views` plus the per-file roots computed from the path, whose owning strings
## live in `owned` until `release`.
public struct EffectiveModuleRoots:
    owned: vec.Vec[string.String]
    views: vec.Vec[str]


extending EffectiveModuleRoots:
    public function as_span() -> span[str]:
        return this.views.as_span()


    public function len() -> ptr_uint:
        return this.views.len()


    public function get(index: ptr_uint) -> ptr[str]?:
        return this.views.get(index)


    public editable function release() -> void:
        var i: ptr_uint = 0
        while i < this.owned.len():
            let entry = this.owned.get(i) else:
                break
            unsafe:
                read(entry).release()
            i += 1
        this.owned.release()
        this.views.release()


extending Workspace:
    public static function create(root: str) -> Workspace:
        var roots = vec.Vec[string.String].create()
        discover_project_root(root, ref_of(roots))
        append_compiler_module_roots(root, ref_of(roots))
        return Workspace(
            root_path = string.String.from_str(root),
            roots = root_vec(root),
            module_roots = roots,
            open_docs = map_mod.Map[string.String, string.String].create(),
            open_doc_order = vec.Vec[string.String].create(),
            document_contexts = map_mod.Map[string.String, string.String].create(),
            document_versions = vec.Vec[DocumentVersionEntry].create(),
            initialize_received = false,
            initialized = false,
            shutdown_received = false,
            diagnostic_cache = DiagnosticCache(entries = map_mod.Map[string.String, DiagnosticCacheEntry].create()),
            analysis_cache = map_mod.Map[string.String, AnalysisCacheEntry].create(),
            parse_cache = map_mod.Map[string.String, ParseCacheEntry].create(),
            module_cache = loader.create_module_cache(),
            index_dirty = vec.Vec[string.String].create(),
            semantic_token_cache = map_mod.Map[string.String, SemanticTokenCacheEntry].create(),
            token_cache = TokenCacheEntry(
                path = string.String.create(),
                content_hash = 0,
                tokens = vec.Vec[token_mod.Token].create(),
            ),
            binding_cache = BindingCacheEntry(
                path = string.String.create(),
                content_hash = 0,
                source = string.String.create(),
                bindings = vec.Vec[scope_mod.Binding].create(),
            ),
            text_cache = map_mod.Map[string.String, TextCacheEntry].create(),
            config_request_id = 0,
            config_received = false,
            index_built = false,
            index = idx.Index(entries = vec.Vec[idx.Entry].create()),
            definition_index = defidx.create(),
            reference_index = refidx.create(),
            format_mode = string.String.create(),
            dependency_resolution_mode = string.String.create(),
            platform = resolver.Platform.linux,
            strict_current_root_diagnostics = false,
            pull_diagnostics_active = false,
            position_encoding_utf16 = true,
            client_watched_files_dynamic = false,
            watched_files_registered = false,
            client_diagnostic_refresh_support = false,
            client_code_lens_refresh_support = false,
            client_semantic_tokens_refresh_support = false,
            client_inlay_hint_refresh_support = false,
            retired_regions = vec.Vec[heap.Region].create(),
        )


    ## Re-root the workspace from the client's workspace folders.  Every folder
    ## is a module root (imports resolve relative to each), and the first is the
    ## primary used for path labels.  The index and all per-file caches are
    ## dropped so they rebuild against the new roots.
    public editable function set_roots(paths: span[str]) -> void:
        release_module_roots(ref_of(this.module_roots))
        this.module_roots = vec.Vec[string.String].create()
        release_module_roots(ref_of(this.roots))
        this.roots = vec.Vec[string.String].create()
        this.root_path.release()
        this.root_path = string.String.create()
        var i: ptr_uint = 0
        while i < paths.len:
            let path = unsafe: read(paths.data + i)
            if path.len > 0 and not owned_root_contains(ref_of(this.roots), path):
                if this.root_path.len() == 0:
                    this.root_path.append(path)
                this.roots.push(string.String.from_str(path))
                append_owned_root(path, ref_of(this.module_roots))
                discover_project_root(path, ref_of(this.module_roots))
                append_compiler_module_roots(path, ref_of(this.module_roots))
            i += 1
        this.reset_after_reroot()


    ## Single-root convenience path (and the pre-multi-root API).
    public editable function set_root(path: str) -> void:
        this.set_roots(array[str, 1](path).as_span())


    ## Drop every cache and index after a root change.
    public editable function reset_after_reroot() -> void:
        this.drain_retired_regions()
        this.release_token_cache()
        this.release_binding_cache()
        release_text_cache(ref_of(this.text_cache))
        this.text_cache = map_mod.Map[string.String, TextCacheEntry].create()
        release_diagnostic_cache(ref_of(this.diagnostic_cache))
        this.diagnostic_cache = DiagnosticCache(entries = map_mod.Map[string.String, DiagnosticCacheEntry].create())
        release_analysis_cache(ref_of(this.analysis_cache))
        this.analysis_cache = map_mod.Map[string.String, AnalysisCacheEntry].create()
        loader.release_module_cache(ref_of(this.module_cache))
        this.module_cache = loader.create_module_cache()
        release_parse_cache(ref_of(this.parse_cache))
        this.parse_cache = map_mod.Map[string.String, ParseCacheEntry].create()
        release_dirty_paths(ref_of(this.index_dirty))
        defidx.release(ref_of(this.definition_index))
        this.definition_index = defidx.create()
        refidx.release(ref_of(this.reference_index))
        this.reference_index = refidx.create()
        if this.index_built:
            idx.release_index(ref_of(this.index))
            this.index = idx.Index(entries = vec.Vec[idx.Entry].create())
            this.index_built = false


    public editable function open(uri: str, text: str) -> void:
        let path_result = uri_ops.file_uri_to_path(uri)
        match path_result:
            Option.some as path_payload:
                this.track_open_path(path_payload.value.as_str())
                this.set_open_doc(path_payload.value, text)
                loader.invalidate_module_cache(ref_of(this.module_cache))
                this.mark_index_dirty(path_payload.value.as_str())
                defidx.forget(ref_of(this.definition_index), path_payload.value.as_str())
                refidx.forget(ref_of(this.reference_index), path_payload.value.as_str())
                this.warm_definition_names(path_payload.value.as_str(), text)
            Option.none:
                pass


    public editable function change(uri: str, text: str) -> void:
        let path_result = uri_ops.file_uri_to_path(uri)
        match path_result:
            Option.some as path_payload:
                this.track_open_path(path_payload.value.as_str())
                this.set_open_doc(path_payload.value, text)
                loader.invalidate_module_cache(ref_of(this.module_cache))
                this.mark_index_dirty(path_payload.value.as_str())
                defidx.forget(ref_of(this.definition_index), path_payload.value.as_str())
                refidx.forget(ref_of(this.reference_index), path_payload.value.as_str())
                this.warm_definition_names(path_payload.value.as_str(), text)
            Option.none:
                pass


    public editable function close(uri: str) -> void:
        let path_result = uri_ops.file_uri_to_path(uri)
        match path_result:
            Option.some as path_payload:
                this.untrack_open_path(path_payload.value.as_str())
                this.open_docs.remove(path_payload.value)
                this.forget_document_text(path_payload.value.as_str())
                # A closed document's cached AST/analysis is keyed by its path, so
                # without this it is retained for the life of the session (the
                # cache only ever replaced an entry, never dropped one).  Both
                # entries own their storage — the parse cache its source copy and
                # region, the analysis cache its `Program` — and nothing outside
                # a request may borrow them.
                this.forget_parse_cache(path_payload.value.as_str())
                this.forget_analysis_cache(path_payload.value.as_str())
                loader.evict_module_cache_entry(ref_of(this.module_cache), path_payload.value.as_str())
                loader.invalidate_module_cache(ref_of(this.module_cache))
                # The per-file result caches are path-keyed as well; closing is
                # the only point at which a file stops being a candidate for its
                # cached diagnostics and tokens.
                this.diagnostic_cache_clear(path_payload.value.as_str())
                this.semantic_token_cache_remove(path_payload.value.as_str())
                defidx.forget(ref_of(this.definition_index), path_payload.value.as_str())
                refidx.forget(ref_of(this.reference_index), path_payload.value.as_str())
                # The buffer is gone: re-read the file (its saved content).
                this.mark_index_dirty(path_payload.value.as_str())
                match this.document_source(path_payload.value.as_str()):
                    Option.some as saved:
                        this.warm_definition_names(path_payload.value.as_str(), saved.value.as_str())
                        saved.value.release()
                    Option.none:
                        pass
            Option.none:
                pass


    ## Drop one document's cached parse, releasing its source copy and the
    ## region that owns the AST and single-file analysis.  `didClose` calls this;
    ## any other eviction must too.  `remove_entry` hands back the map-owned key
    ## as well, so it is released here.
    public editable function forget_parse_cache(path: str) -> void:
        var key = string.String.from_str(path)
        defer: key.release()
        let removed = this.parse_cache.remove_entry(key)
        match removed:
            Option.some as old:
                var entry = old.value
                entry.key.release()
                entry.value.source.release()
                entry.value.region.release_all()
            Option.none:
                pass


    ## Drop one document's cached loader-backed analysis, releasing its owned
    ## path and the `Program` (whose region-owned AST/analysis the module cache
    ## has already released or retired).
    public editable function forget_analysis_cache(path: str) -> void:
        var key = string.String.from_str(path)
        defer: key.release()
        let removed = this.analysis_cache.remove_entry(key)
        match removed:
            Option.some as old:
                var entry = old.value
                entry.key.release()
                entry.value.path.release()
                entry.value.program.release()
            Option.none:
                pass


    ## Store a document's text, releasing the buffer it replaces (`set` returns
    ## the previous value on an existing key and drops it otherwise).
    public editable function set_open_doc(path: string.String, text: str) -> void:
        this.forget_document_text(path.as_str())
        let previous = this.open_docs.set(path, string.String.from_str(text))
        match previous:
            Option.some as old:
                var old_text = old.value
                old_text.release()
            Option.none:
                pass


    ## Register a document's declaration names for the host's cross-file
    ## definition lookup (`warm_definition_candidates_for_uri`).
    public editable function warm_definition_names(path: str, source: str) -> void:
        defidx.warm_names(ref_of(this.definition_index), path, source)


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


    ## The document's current text and content hash, validated once per document
    ## version.  The returned `str` is borrowed: an open document's buffer lives
    ## in `open_docs` until the next open/change/close, a closed one's in its
    ## cache entry until the stat stamp changes.  Callers hold it for one
    ## request only.
    public editable function document_text(path: str) -> Option[DocumentText]:
        var key = string.String.from_str(path)
        defer: key.release()
        let cached_ptr = this.text_cache.get(key)
        if cached_ptr != null:
            unsafe:
                let cached = read(cached_ptr)
                if cached.open:
                    return Option[DocumentText].some(value = DocumentText(text = cached.text, hash = cached.hash))
                match fs_mod.metadata(path):
                    Result.success as meta:
                        let stamp = meta.value
                        if cached.size == stamp.size and cached.modified_seconds == stamp.modified_seconds and cached.modified_nanoseconds == stamp.modified_nanoseconds:
                            return Option[DocumentText].some(value = DocumentText(text = cached.text, hash = cached.hash))
                    Result.failure as failure_payload:
                        var err = failure_payload.error
                        err.release()

        let open_ptr = this.open_docs.get(key)
        if open_ptr != null:
            unsafe:
                let validated = read(open_ptr).as_str()
                let hash = strings.fnv1a_hash(validated)
                this.put_text_cache(path, string.String.create(), validated, hash, true, 0, 0, 0)
                return Option[DocumentText].some(value = DocumentText(text = validated, hash = hash))

        var size: ptr_uint = 0
        var modified_seconds: ptr_int = 0
        var modified_nanoseconds: ptr_int = 0
        match fs_mod.metadata(path):
            Result.success as meta:
                let stamp = meta.value
                size = stamp.size
                modified_seconds = stamp.modified_seconds
                modified_nanoseconds = stamp.modified_nanoseconds
            Result.failure as failure_payload:
                var err = failure_payload.error
                err.release()

        match fs_mod.read_text(path):
            Result.success as content:
                var source = content.value
                let validated = source.as_str()
                let hash = strings.fnv1a_hash(validated)
                this.put_text_cache(path, source, validated, hash, false, size, modified_seconds, modified_nanoseconds)
                return Option[DocumentText].some(value = DocumentText(text = validated, hash = hash))
            Result.failure as failure_payload:
                var err = failure_payload.error
                err.release()
                return Option[DocumentText].none


    ## The content hash of `source` when it is the cached text of `path` (the
    ## common case: every helper in one request passes the same validated view),
    ## else a fresh hash.  This keeps the token/binding caches' version check
    ## from re-scanning the whole document per lookup.
    public function document_hash_for(path: str, source: str) -> uint:
        var key = string.String.from_str(path)
        defer: key.release()
        let cached_ptr = this.text_cache.get(key)
        if cached_ptr != null:
            unsafe:
                let cached = read(cached_ptr)
                if cached.text.len == source.len and cached.text.data == source.data:
                    return cached.hash
        return strings.fnv1a_hash(source)


    ## Drop a document's text cache entry (open/change/close).
    public editable function forget_document_text(path: str) -> void:
        var key = string.String.from_str(path)
        defer: key.release()
        let previous = this.text_cache.remove(key)
        match previous:
            Option.some as old:
                var entry = old.value
                entry.source.release()
                entry.line_starts.release()
            Option.none:
                pass


    ## Replace a document's text cache entry, releasing the buffer it owned.
    editable function put_text_cache(
        path: str,
        source: string.String,
        text: str,
        hash: uint,
        open: bool,
        size: ptr_uint,
        modified_seconds: ptr_int,
        modified_nanoseconds: ptr_int,
    ) -> void:
        var key = string.String.from_str(path)
        defer: key.release()
        let previous = this.text_cache.remove(key)
        match previous:
            Option.some as old:
                var entry = old.value
                entry.source.release()
                entry.line_starts.release()
            Option.none:
                pass
        this.text_cache.set(string.String.from_str(path), TextCacheEntry(
            source = source,
            text = text,
            hash = hash,
            open = open,
            size = size,
            modified_seconds = modified_seconds,
            modified_nanoseconds = modified_nanoseconds,
            line_starts = utils.build_line_starts(text),
        ))


    ## The token stream of `path`'s current `source`, from the one-document lex
    ## cache.  The span points into the cache (valid until the next call for a
    ## different document), so a request takes it per lookup and never holds it
    ## across a cross-file fetch.
    public editable function document_tokens(path: str, source: str) -> span[token_mod.Token]:
        let current_hash = this.document_hash_for(path, source)
        if this.token_cache.path.as_str().equal(path) and this.token_cache.content_hash == current_hash:
            return this.token_cache.tokens.as_span()
        var previous = this.token_cache
        previous.path.release()
        previous.tokens.release()
        var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
        defer: lex_diags.release()
        this.token_cache = TokenCacheEntry(
            path = string.String.from_str(path),
            content_hash = current_hash,
            tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags)),
        )
        return this.token_cache.tokens.as_span()


    ## Drop the cached token stream (re-rooting the workspace).
    public editable function release_token_cache() -> void:
        var previous = this.token_cache
        previous.path.release()
        previous.tokens.release()
        this.token_cache = TokenCacheEntry(
            path = string.String.create(),
            content_hash = 0,
            tokens = vec.Vec[token_mod.Token].create(),
        )


    ## The scope bindings of `path`'s current `source`, cached with the source
    ## copy their name views point into.  The span is valid until the next call
    ## for a different document (the same one-entry rule as `document_tokens`).
    public editable function document_bindings(path: str, source: str, ast_file: ast.SourceFile) -> span[scope_mod.Binding]:
        let current_hash = this.document_hash_for(path, source)
        if this.binding_cache.path.as_str().equal(path) and this.binding_cache.content_hash == current_hash:
            return this.binding_cache.bindings.as_span()
        var previous = this.binding_cache
        previous.path.release()
        previous.source.release()
        previous.bindings.release()
        var stored_source = string.String.from_str(source)
        this.binding_cache = BindingCacheEntry(
            path = string.String.from_str(path),
            content_hash = current_hash,
            source = stored_source,
            bindings = scope_mod.collect_bindings(stored_source.as_str(), ast_file),
        )
        return this.binding_cache.bindings.as_span()


    public editable function release_binding_cache() -> void:
        var previous = this.binding_cache
        previous.path.release()
        previous.source.release()
        previous.bindings.release()
        this.binding_cache = BindingCacheEntry(
            path = string.String.create(),
            content_hash = 0,
            source = string.String.create(),
            bindings = vec.Vec[scope_mod.Binding].create(),
        )


    ## The byte offset of an incoming LSP position (0-based line, character in
    ## UTF-16 code units) in the document's current text.  Positions are
    ## converted once at the request boundary so the byte-based scanners see
    ## the columns a spec client means; an unknown document keeps the raw
    ## character.
    public editable function position_byte_offset(uri: str, line: ptr_uint, character: ptr_uint) -> ptr_uint:
        var path = uri_ops.file_uri_to_path(uri) else:
            return character
        defer: path.release()
        var source = this.document_text(path.as_str()) else:
            return character
        return this.position_byte_offset_in(source.text, line, character)


    ## The byte offset of an incoming position in `source` under the negotiated
    ## encoding.  `didChange` applies edits against its own in-progress buffer,
    ## so it converts against that text rather than the cached document.
    public function position_byte_offset_in(source: str, line: ptr_uint, character: ptr_uint) -> ptr_uint:
        if this.position_encoding_utf16:
            return utils.position_to_byte_utf16(source, line, character)
        return utils.position_to_byte_utf8(source, line, character)


    ## The outgoing character column for an internal byte column at `line` in
    ## `source` (a validated view of the document).  Emitters that hold the
    ## document text use this; the UTF-8 path is the identity.
    public function output_character_in(source: str, line: ptr_uint, byte_col: ptr_uint) -> ptr_uint:
        if not this.position_encoding_utf16:
            return byte_col
        return utils.byte_to_utf16_column(utils.source_line(source, line + 1), byte_col)


    ## The outgoing character column for `path`'s current text.  For a result
    ## whose document the handler did not read (cross-file navigation), this
    ## fetches the line through the document cache.
    public editable function output_character(path: str, line: ptr_uint, byte_col: ptr_uint) -> ptr_uint:
        if not this.position_encoding_utf16:
            return byte_col
        let source = this.document_text(path) else:
            return byte_col
        var key = string.String.from_str(path)
        defer: key.release()
        let cached_ptr = this.text_cache.get(key)
        if cached_ptr != null:
            unsafe:
                let cached = read(cached_ptr)
                let line_text = utils.line_at_index(cached.text, cached.line_starts.as_span(), line)
                return utils.byte_to_utf16_column(line_text, byte_col)
        return this.output_character_in(source.text, line, byte_col)


    ## Select the position encoding `initialize` negotiated.
    public editable function set_position_encoding(utf16: bool) -> void:
        this.position_encoding_utf16 = utf16


    ## The roots the workspace *symbol* index walks: the host's `index_workspace`
    ## covers the workspace root (and the enclosing package's source root) only.
    ## `module_roots` stays wider for import resolution — walking them would index
    ## the whole compiler tree for a project outside it.
    public function workspace_index_roots() -> vec.Vec[string.String]:
        var result = vec.Vec[string.String].create()
        var i: ptr_uint = 0
        while i < this.roots.len():
            let root_ptr = this.roots.get(i) else:
                break
            i += 1
            let root = unsafe: read(root_ptr).as_str()
            append_owned_root(root, ref_of(result))
            match package_manifest.package_source_root_for_path(root):
                Option.some as source_root:
                    append_owned_root(source_root.value.as_str(), ref_of(result))
                    source_root.value.release()
                Option.none:
                    pass
        return result


    ## Resolve a source file path to the effective module roots for dependency
    ## loading: the workspace roots plus the roots the host's
    ## `ModuleRoots.roots_for_path(path)` adds for the file itself — the nearest
    ## ancestor `package.toml` source root and the nearest project root (an
    ## ancestor containing `std/`).  A workspace opened at a monorepo root must
    ## still resolve a nested package's modules by their bare names.
    public function effective_module_roots_for(path: str) -> EffectiveModuleRoots:
        var owned = vec.Vec[string.String].create()
        var views = vec.Vec[str].create()

        var i: ptr_uint = 0
        while i < this.module_roots.len():
            let root_ptr = this.module_roots.get(i) else:
                break
            unsafe:
                views.push(read(root_ptr).as_str())
            i += 1

        if path.len > 0:
            match package_manifest.package_source_root_for_path(path):
                Option.some as source_root:
                    owned.push(source_root.value)
                Option.none:
                    pass

            discover_project_root(path, ref_of(owned))

            var oi: ptr_uint = 0
            while oi < owned.len():
                let root_ptr = owned.get(oi) else:
                    break
                unsafe:
                    let root = read(root_ptr).as_str()
                    if not module_root_view_contains(ref_of(views), root):
                        views.push(root)
                oi += 1

        return EffectiveModuleRoots(owned = owned, views = views)


    ## Index the document's identifier tokens from the text the caller already
    ## has — the host's `index_identifier_tokens` reached through
    ## `lex_document`.
    public editable function note_document_source(path: str, source: str) -> void:
        refidx.note(ref_of(this.reference_index), path, source)

    ## Index the document's identifier tokens, reading its current text (the
    ## open buffer or disk).  An unchanged document is a no-op: an open one by
    ## the index's content hash, a closed one by its recorded (mtime, size), so
    ## an unchanged closed document is neither re-read nor re-lexed.
    public editable function note_document_tokens(path: str) -> void:
        if path.len == 0:
            return
        # The index drops an entry on every open/change/close, so an indexed
        # document is current: skip the content hash the note would otherwise
        # compute on every hover.
        if refidx.is_indexed(ref_of(this.reference_index), path):
            return
        # An open document's buffer is its current content; index it directly
        # (no disk read, no copy: the index keeps its own stored text).
        var open_key = string.String.from_str(path)
        defer: open_key.release()
        let open_ptr = this.open_docs.get(open_key)
        if open_ptr != null:
            refidx.note(ref_of(this.reference_index), path, unsafe: read(open_ptr).as_str())
            return

        # A closed document: skip the read and the lex when the file's stat
        # matches what was indexed.
        match fs_mod.metadata(path):
            Result.success as meta:
                let stamp = meta.value
                if refidx.matches_stamp(ref_of(this.reference_index), path, stamp.size, stamp.modified_seconds, stamp.modified_nanoseconds):
                    return
                match fs_mod.read_text(path):
                    Result.success as content:
                        var source = content.value
                        defer: source.release()
                        refidx.note(ref_of(this.reference_index), path, source.as_str())
                        refidx.record_stamp(ref_of(this.reference_index), path, stamp.size, stamp.modified_seconds, stamp.modified_nanoseconds)
                    Result.failure:
                        pass
            Result.failure:
                pass


    ## Admit a document to the cross-file definition index: the host's
    ## `hover_definition_entry_from_location` reads a hover's definition file
    ## through `get_content`, which makes it a definition candidate.  Called from
    ## the hover path only, as the host's is.
    public editable function warm_definition_document(path: str) -> void:
        if path.len == 0 or defidx.knows_names(ref_of(this.definition_index), path):
            return
        var content = this.document_source(path) else:
            return
        defer: content.release()
        defidx.warm_names(ref_of(this.definition_index), path, content.as_str())


    ## True when `path` is an open document.
    public function is_open_path(path: str) -> bool:
        var key = string.String.from_str(path)
        defer: key.release()
        return this.open_docs.contains(key)

    ## Record `path` as needing re-indexing (idempotent).
    public editable function mark_index_dirty(path: str) -> void:
        if path.len == 0:
            return
        var i: ptr_uint = 0
        while i < this.index_dirty.len():
            let p = this.index_dirty.get(i) else:
                break
            if unsafe: read(p).as_str().equal(path):
                return
            i += 1
        this.index_dirty.push(string.String.from_str(path))


    ## Build the index once, then keep the changed files current: re-indexing one
    ## file is milliseconds, while re-walking the tree is seconds.
    public editable function build_index_if_needed() -> void:
        if not this.index_built:
            log.info("lsp: building workspace index")
            idx.release_index(ref_of(this.index))
            var walk_roots = this.workspace_index_roots()
            defer: walk_roots.release()
            this.index = idx.build_index(ref_of(walk_roots), ref_of(this.module_roots))
            this.index_built = true
            release_dirty_paths(ref_of(this.index_dirty))
            this.warm_indexed_definition_names()
            log.info("lsp: workspace index ready")
            return

        var di: ptr_uint = 0
        while di < this.index_dirty.len():
            let dp = this.index_dirty.get(di) else:
                break
            let path = unsafe: read(dp).as_str()
            idx.remove_file(ref_of(this.index), path)
            # The loader's cached raw tree re-indexes the edited file without a
            # second parse; a file with no loader entry falls back to reading
            # and parsing it.
            match document_raw_ast(this, path):
                Option.some as ast_payload:
                    idx.collect_file_symbols_from_ast(path, ref_of(this.index), ref_of(this.module_roots), ast_payload.value)
                Option.none:
                    match this.document_source(path):
                        Option.some as content:
                            idx.collect_file_symbols_with_source(path, ref_of(this.index), ref_of(this.module_roots), content.value.as_str())
                            content.value.release()
                        Option.none:
                            pass
            di += 1
        release_dirty_paths(ref_of(this.index_dirty))


    ## Warm every indexed file's declaration names — the host's `index_workspace`
    ## warms each file it indexes, which is what makes an unopened workspace
    ## file a definition candidate.
    public editable function warm_indexed_definition_names() -> void:
        var fi: ptr_uint = 0
        while fi < this.index.files.len():
            let fp = this.index.files.get(fi) else:
                break
            let path = unsafe: read(fp).path.as_str()
            if not defidx.knows_names(ref_of(this.definition_index), path):
                match this.document_source(path):
                    Option.some as content:
                        defidx.warm_names(ref_of(this.definition_index), path, content.value.as_str())
                        content.value.release()
                    Option.none:
                        pass
            fi += 1


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


    ## Record the client's version for an open document.
    public editable function set_document_version(path: str, version: ptr_int) -> void:
        var i: ptr_uint = 0
        while i < this.document_versions.len():
            let entry = this.document_versions.get(i) else:
                break
            if unsafe: read(entry).path.as_str().equal(path):
                unsafe: read(entry).version = version
                return
            i += 1
        this.document_versions.push(DocumentVersionEntry(
            path = string.String.from_str(path),
            version = version,
        ))


    ## The client's last version for `path`, or none when it is not open.
    public function document_version(path: str) -> Option[ptr_int]:
        var i: ptr_uint = 0
        while i < this.document_versions.len():
            let entry = this.document_versions.get(i) else:
                break
            if unsafe: read(entry).path.as_str().equal(path):
                return Option[ptr_int].some(value = unsafe: read(entry).version)
            i += 1
        return Option[ptr_int].none


    ## Drop a closed document's version.
    public editable function forget_document_version(path: str) -> void:
        var i: ptr_uint = 0
        while i < this.document_versions.len():
            let entry = this.document_versions.get(i) else:
                break
            if unsafe: read(entry).path.as_str().equal(path):
                let removed = this.document_versions.remove(i)
                match removed:
                    Option.some as old:
                        var entry_value = old.value
                        entry_value.path.release()
                    Option.none:
                        pass
                return
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
        # Replace any previous entry (releasing its strings).
        var lookup = string.String.from_str(path)
        defer: lookup.release()
        let stale_ptr = this.diagnostic_cache.entries.get(lookup)
        if stale_ptr != null:
            unsafe:
                var stale = read(stale_ptr)
                stale.result_id.release()
                stale.diagnostics_json.release()
            this.diagnostic_cache.entries.remove(lookup)
        var entry = DiagnosticCacheEntry(
            source_hash = source_hash,
            result_id = result_id,
            diagnostics_json = diagnostics_json,
        )
        this.diagnostic_cache.entries.set(key, entry)


    ## Clear the diagnostic cache entry for a single file, releasing the cached
    ## result id and JSON (`remove` drops the entry without freeing its fields).
    public editable function diagnostic_cache_clear(path: str) -> void:
        var key = string.String.from_str(path)
        defer: key.release()
        let removed = this.diagnostic_cache.entries.remove_entry(key)
        match removed:
            Option.some as old:
                var entry = old.value
                entry.key.release()
                entry.value.result_id.release()
                entry.value.diagnostics_json.release()
            Option.none:
                pass


    ## Clear the entire diagnostic cache, releasing every entry's strings.
    public editable function diagnostic_cache_clear_all() -> void:
        release_diagnostic_cache(ref_of(this.diagnostic_cache))
        this.diagnostic_cache = DiagnosticCache(entries = map_mod.Map[string.String, DiagnosticCacheEntry].create())


    ## Look up a cached semantic token entry for a file path.
    public function semantic_token_cache_get(path: str) -> ptr[SemanticTokenCacheEntry]?:
        var key = string.String.from_str(path)
        defer: key.release()
        return this.semantic_token_cache.get(key)


    ## Store a cached semantic token entry.
    public editable function semantic_token_cache_set(
        path: str,
        source_hash: uint,
        result_id: string.String,
        token_count: ptr_uint,
        data: vec.Vec[uint],
        utf16: bool,
    ) -> void:
        var key = string.String.from_str(path)
        let stale_ptr = this.semantic_token_cache.get(key)
        if stale_ptr != null:
            # Update in place: the map owns the key, and replacing the entry
            # through remove/set would leak it on every edit.
            unsafe:
                var stale = read(stale_ptr)
                stale.result_id.release()
                stale.data.release()
                read(stale_ptr).source_hash = source_hash
                read(stale_ptr).result_id = result_id
                read(stale_ptr).token_count = token_count
                read(stale_ptr).data = data
                read(stale_ptr).utf16 = utf16
            key.release()
            return
        this.semantic_token_cache.set(key, SemanticTokenCacheEntry(
            source_hash = source_hash,
            result_id = result_id,
            token_count = token_count,
            data = data,
            utf16 = utf16,
        ))


    ## Remove a specific cached semantic token entry.
    public editable function semantic_token_cache_remove(path: str) -> void:
        var key = string.String.from_str(path)
        let removed = this.semantic_token_cache.remove_entry(key)
        key.release()
        match removed:
            Option.some as payload:
                var removed_entry = payload.value
                removed_entry.key.release()
                var entry = removed_entry.value
                entry.result_id.release()
                entry.data.release()
            Option.none:
                pass


    ## Clear all cached semantic token entries.
    public editable function semantic_token_cache_remove_all() -> void:
        release_semantic_token_cache(ref_of(this.semantic_token_cache))
        this.semantic_token_cache = map_mod.Map[string.String, SemanticTokenCacheEntry].create()


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


    ## Free the regions superseded parses/analyses retired since the last call.
    ## Called at the request boundary (the server loop) and on teardown, when no
    ## request-local value can still borrow them; freeing at replacement would
    ## be a use-after-free for values a request still holds.
    public editable function drain_retired_regions() -> void:
        loader.drain_retired_regions(ref_of(this.module_cache))
        var i: ptr_uint = 0
        while i < this.retired_regions.len():
            let region_ptr = this.retired_regions.get(i) else:
                break
            unsafe:
                read(region_ptr).release_all()
            i += 1
        this.retired_regions.clear()


    public editable function release() -> void:
        this.drain_retired_regions()
        this.release_token_cache()
        this.release_binding_cache()
        release_text_cache(ref_of(this.text_cache))
        this.root_path.release()
        release_module_roots(ref_of(this.roots))
        release_module_roots(ref_of(this.module_roots))
        defidx.release(ref_of(this.definition_index))
        refidx.release(ref_of(this.reference_index))
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
        release_document_versions(ref_of(this.document_versions))
        release_diagnostic_cache(ref_of(this.diagnostic_cache))
        release_semantic_token_cache(ref_of(this.semantic_token_cache))
        release_analysis_cache(ref_of(this.analysis_cache))
        release_parse_cache(ref_of(this.parse_cache))
        loader.release_module_cache(ref_of(this.module_cache))
        if this.index_built:
            idx.release_index(ref_of(this.index))


## True when the module-root view list already contains `candidate`.
function module_root_view_contains(views: ref[vec.Vec[str]], candidate: str) -> bool:
    var i: ptr_uint = 0
    while i < views.len():
        let entry = views.get(i) else:
            break
        if unsafe: read(entry).equal(candidate):
            return true
        i += 1
    return false


function release_dirty_paths(paths: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < paths.len():
        let p = paths.get(i) else:
            break
        unsafe: read(p).release()
        i += 1
    paths.clear()


function release_document_versions(versions: ref[vec.Vec[DocumentVersionEntry]]) -> void:
    var i: ptr_uint = 0
    while i < versions.len():
        let entry = versions.get(i) else:
            break
        unsafe: read(entry).path.release()
        i += 1
    versions.release()


function release_text_cache(cache: ref[map_mod.Map[string.String, TextCacheEntry]]) -> void:
    var entries_iter = cache.entries()
    while entries_iter.next():
        let entry = entries_iter.current()
        unsafe:
            read(entry.key).release()
            var entry_value = read(entry.value)
            entry_value.source.release()
            entry_value.line_starts.release()
    cache.release()


function release_parse_cache(cache: ref[map_mod.Map[string.String, ParseCacheEntry]]) -> void:
    var entries_iter = cache.entries()
    while entries_iter.next():
        let entry = entries_iter.current()
        unsafe:
            read(entry.key).release()
            var entry_value = read(entry.value)
            entry_value.source.release()
            entry_value.region.release_all()
    cache.release()


function release_analysis_cache(cache: ref[map_mod.Map[string.String, AnalysisCacheEntry]]) -> void:
    var entries_iter = cache.entries()
    while entries_iter.next():
        let entry = entries_iter.current()
        unsafe:
            read(entry.key).release()
            var entry_value = read(entry.value)
            entry_value.path.release()
            entry_value.program.release()
    cache.release()


## The parse and single-file analysis of `source` (which must be the document's
## current text), cached by content fingerprint.
public function parsed_analysis_for(ws: ref[Workspace], path: str, source: str) -> Option[ParseCacheEntry]:
    let current_hash = strings.fnv1a_hash(source)
    var cache_key = string.String.from_str(path)
    defer: cache_key.release()

    let cached_ptr = ws.parse_cache.get(cache_key)
    if cached_ptr != null:
        unsafe:
            let cached = read(cached_ptr)
            if cached.content_hash == current_hash:
                return Option[ParseCacheEntry].some(value = cached)

    var source_owner = string.String.from_str(source)
    let owned_source = source_owner.as_str()
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    # The parse's and single-file check's allocations — AST nodes and vectors,
    # synthesized strings, the diagnostics buffer, the analysis' internals —
    # belong to this region, which the entry owns and releases (or retires) on
    # replacement.  `parse_diags`' buffer is region-owned, so it is not
    # released here.
    var region = heap.create_region()
    let previous = heap.begin_region(ptr_of(region))
    var ast_file = parser.parse_source(owned_source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)
    let parse_error_count = parse_diags.len()
    heap.end_region(previous)

    var entry = ParseCacheEntry(
        content_hash = current_hash,
        parse_error_count = parse_error_count,
        source = source_owner,
        ast_file = ast_file,
        analysis = analysis,
        region = region,
    )
    # Replace any stale entry for this path; `set` owns the key.  The stale
    # entry's region is retired to the workspace quarantine (a request may still
    # hold views into it) and freed at the request boundary.
    let stale_ptr = ws.parse_cache.get(cache_key)
    if stale_ptr != null:
        unsafe:
            var stale = read(stale_ptr)
            stale.source.release()
            if stale.region.block_count > 0:
                ws.retired_regions.push(stale.region)
        ws.parse_cache.remove(cache_key)
    ws.parse_cache.set(string.String.from_str(path), entry)
    return Option[ParseCacheEntry].some(value = entry)


## The AST and analysis for a document's current text, from one tree:
## the loader-backed pair when the file loads (imports bound, shared with every
## other request and cached per content version), else the single-file
## parse+check.  Consumers that would otherwise parse the document per request
## route through this; the AST and analysis always come from the same tree,
## because `resolved_expr_types` is keyed by expression pointer.
public struct DocumentAnalysis:
    ast_file: ast.SourceFile
    analysis: analyzer.Analysis
    ## The raw parse's declaration count (before the analyzer appends the
    ## declarations `emit` statements produce), for the outline's cutoff.
    parsed_declaration_count: ptr_uint
    ## The loader-backed program when the document loaded (the import closure's
    ## analyses), so a request can answer an imported-module question without
    ## re-fetching and re-hashing this document's cache entry.  None for the
    ## single-file fallback.
    program: Option[loader.Program]


public function document_analysis_for(ws: ref[Workspace], path: str) -> Option[DocumentAnalysis]:
    let entry_opt = analysis_entry_for(ws, path)
    match entry_opt:
        Option.some as ep:
            let entry = unsafe: read(ep.value)
            return Option[DocumentAnalysis].some(value = DocumentAnalysis(
                ast_file = entry.analysis.source_file,
                analysis = entry.analysis,
                parsed_declaration_count = root_module_declaration_count(entry.program, entry.analysis.module_name),
                program = Option[loader.Program].some(value = entry.program),
            ))
        Option.none:
            pass
    var content = ws.document_source(path) else:
        return Option[DocumentAnalysis].none
    defer: content.release()
    let parsed = parsed_analysis_for(ws, path, content.as_str()) else:
        return Option[DocumentAnalysis].none
    return Option[DocumentAnalysis].some(value = DocumentAnalysis(
        ast_file = parsed.ast_file,
        analysis = parsed.analysis,
        parsed_declaration_count = parsed.ast_file.declarations.len,
        program = Option[loader.Program].none,
    ))


## The raw parse's declaration count for the root module: the Program's
## `modules` are dependency-first while `analyses` (and `root_index`) are
## canonical, so the root is found by module name.  Falls back to the analysis'
## own tree when the module is absent.
function root_module_declaration_count(program: loader.Program, module_name: str) -> ptr_uint:
    var mi: ptr_uint = 0
    while mi < program.modules.len():
        let mp = program.modules.get(mi) else:
            break
        let m = unsafe: read(mp)
        if m.module_name.as_str().equal(module_name):
            return m.source_file.declarations.len
        mi += 1
    return 0


## The loader's raw parse tree for `path` (the module's own `source_file`, before
## the analysis appends the declarations `emit` statements produce), or none when
## the document has no loader entry.  The workspace index re-indexes an edited
## file from this tree instead of parsing it again.
public function document_raw_ast(ws: ref[Workspace], path: str) -> Option[ast.SourceFile]:
    let entry_opt = analysis_entry_for(ws, path)
    match entry_opt:
        Option.some as ep:
            let entry = unsafe: read(ep.value)
            var canonical_ok = false
            var canonical: string.String
            match fs_mod.canonicalize(path):
                Result.success as cp:
                    canonical = cp.value
                    canonical_ok = true
                Result.failure as fp:
                    var err = fp.error
                    err.release()
            var mi: ptr_uint = 0
            while mi < entry.program.modules.len():
                let mp = entry.program.modules.get(mi) else:
                    break
                let m = unsafe: read(mp)
                let matches = if canonical_ok: m.path.as_str().equal(canonical.as_str()) else: m.path.as_str().equal(path)
                if matches:
                    if canonical_ok:
                        canonical.release()
                    return Option[ast.SourceFile].some(value = m.source_file)
                mi += 1
            if canonical_ok:
                canonical.release()
        Option.none:
            pass
    return Option[ast.SourceFile].none


## The whole cache entry (loader-backed program + analysis) for `path`.  The
## pointer addresses the cache's own storage, so it stays valid for the rest of
## the request; the entry is replaced when the document's content changes.
## Sharing a single loader run across every feature that needs imports is what
## keeps a large file's requests cheap.
public function analysis_entry_for(ws: ref[Workspace], path: str) -> Option[ptr[AnalysisCacheEntry]]:
    var text = ws.document_text(path) else:
        return Option[ptr[AnalysisCacheEntry]].none
    if text.text.len == 0:
        return Option[ptr[AnalysisCacheEntry]].none

    let current_hash = text.hash
    var cache_key = string.String.from_str(path)
    defer: cache_key.release()

    let cached_ptr = ws.analysis_cache.get(cache_key)
    if cached_ptr != null:
        unsafe:
            let cached = read(cached_ptr)
            if cached.content_hash == current_hash and cached.cache_generation == ws.module_cache.generation:
                return Option[ptr[AnalysisCacheEntry]].some(value = cached_ptr)

    var roots = ws.effective_module_roots_for(path)
    defer: roots.release()
    var program = loader.check_program_with_source(path, roots.as_span(), ws.platform, text.text, true, ptr_of(ws.module_cache), ptr_of(ws.open_docs))

    if program.analyses.len() == 0:
        program.release()
        return Option[ptr[AnalysisCacheEntry]].none
    let root_entry = program.analyses.get(program.root_index) else:
        program.release()
        return Option[ptr[AnalysisCacheEntry]].none
    let analysis = unsafe: read(root_entry)

    # Replace (and release) any stale entry for this path.
    let stale_ptr = ws.analysis_cache.get(cache_key)
    if stale_ptr != null:
        unsafe:
            var stale = read(stale_ptr)
            stale.path.release()
            stale.program.release()
        ws.analysis_cache.remove(cache_key)

    # `set` takes ownership of the key, as the other caches do.
    ws.analysis_cache.set(string.String.from_str(path), AnalysisCacheEntry(
        path = string.String.from_str(path),
        content_hash = current_hash,
        cache_generation = ws.module_cache.generation,
        program = program,
        analysis = analysis,
    ))
    # Re-read through the cache so the returned pointer addresses its storage.
    var stored_key = string.String.from_str(path)
    defer: stored_key.release()
    let stored_ptr = ws.analysis_cache.get(stored_key) else:
        return Option[ptr[AnalysisCacheEntry]].none
    return Option[ptr[AnalysisCacheEntry]].some(value = stored_ptr)


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

    var compiler_roots = resolver.compiler_root_candidates()
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


## The initial single-root vector for `Workspace.create`.
function root_vec(root: str) -> vec.Vec[string.String]:
    var roots = vec.Vec[string.String].create()
    if root.len > 0:
        roots.push(string.String.from_str(root))
    return roots


## True when the owned root list already contains `path`.
function owned_root_contains(roots: ref[vec.Vec[string.String]], path: str) -> bool:
    var i: ptr_uint = 0
    while i < roots.len():
        let entry = roots.get(i) else:
            break
        if unsafe: read(entry).as_str().equal(path):
            return true
        i += 1
    return false


## Append `path` to an owned root list when it is not already present.
function append_owned_root(path: str, roots: ref[vec.Vec[string.String]]) -> void:
    if not owned_root_contains(roots, path):
        roots.push(string.String.from_str(path))


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
            read(entry.key).release()
            var entry_value = read(entry.value)
            entry_value.result_id.release()
            entry_value.diagnostics_json.release()
    cache.entries.release()


function release_semantic_token_cache(cache: ref[map_mod.Map[string.String, SemanticTokenCacheEntry]]) -> void:
    var entries_iter = cache.entries()
    while entries_iter.next():
        let entry = entries_iter.current()
        unsafe:
            read(entry.key).release()
            var entry_value = read(entry.value)
            entry_value.result_id.release()
            entry_value.data.release()
    cache.release()
