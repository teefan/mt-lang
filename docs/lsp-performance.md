# LSP Performance Research

Research into how to drastically improve Milk Tea LSP performance, especially
`textDocument/completion`, grounded in the profile from
`test/tooling/lsp/server/all_endpoints_benchmark.rb` and the industry-standard
techniques used by clangd, SourceKit-LSP, Deno's LSP, Shopify's ruby-lsp,
typescript-language-server, and Roslyn.

## 1. Profile snapshot (current state)

Measured on Ruby 4.0.3 + YJIT (via `RUBY_YJIT_ENABLE=1`) against a synthetic
multi-module workspace (10 iterations per endpoint, facts pre-warmed). The
`didOpen`/`didChange` rows use the benchmark's tiny scratch file; all other
rows use the 3-module main file. `didOpen`/`didChange` cost grows with module
complexity, so the real-world figures for large modules will be higher than
the scratch-file numbers shown here:

| endpoint | avg ms (run-to-run range) | dominant stage |
|---|---|---|
| `textDocument/completion` (import line) | 130–200 | `import_context` |
| `textDocument/didOpen` (scratch file) | 15–30 | eager facts + diagnostics enqueue |
| `milkTea/debugInfo` | 10–20 | re-parse + semantic tokens rebuild |
| `textDocument/didChange` (scratch file) | 9–14 | eager facts + dependency refresh |
| `textDocument/documentSymbol` | 5–18 (max 41–63) | symbols + AST enrichment |
| `textDocument/formatting` | 3–7 | full-file formatter |
| `textDocument/completion` (body) | 0.5–0.9 | facts-driven, cached |
| all other request endpoints | < 4 | mostly cached |

Numbers vary run-to-run (the benchmark's diagnostic workers are stopped for
measurement, but GC and filesystem cache warm-up still add noise), so ranges
are shown rather than single values. The one pathological hotspot is completion
on an `import` line; everything else is healthy once facts are warm.

## 2. The completion hotspot: `import_completions`

`lib/milk_tea/lsp/server/completion.rb:837` runs **on every keystroke** when the
current line starts with `import `. For each module root it:

1. walks the full directory tree recursively via `module_dir_contains_mt?`
   (`completion.rb:907`) to decide whether a subdirectory is importable, and
2. stat's every entry.

Measured cost against this repo's tree: **4,720 directories and 573 `.mt`
files, ~130–220 ms, zero caching, every keystroke**. The same scan is repeated
for each module root returned by `roots_for_path` (for a `/tmp` path this
resolves to the single repo root; a package workspace with `std` and project
roots would repeat the scan per root). There is no persistent module index.

## 3. Ruby constraints that shape the solution

- **GVL means threads don't parallelize Ruby CPU work.** The LSP already spawns
  diagnostics workers and a definition-warmup thread, but CPU-heavy sema
  (`SemanticAnalyzer`) is serialized on the GVL. Background threads help only
  for I/O-bound work and debouncing, not for raw parallelism.
- **`Dir.glob`/`Dir.children` release the GVL frequently.** Since Ruby 3.4
  (`ruby/ruby#20587`, `#21119`) directory iteration releases the GVL per entry;
  when *another* thread is CPU-heavy, `Dir.glob` gets dramatically slower
  (reported up to 50×). The LSP's own background threads can therefore make an
  uncached directory walk *worse* — another reason to stop walking the
  filesystem on the hot path.
- **mtime-based cache invalidation is a common Ruby approach** (Bootsnap's
  load-path cache), but it is **not** a single `stat` per root: directory mtime
  only changes for files added/removed in that exact directory, so Bootsnap
  records and re-validates the mtime of *every* scanned directory (its author
  estimates "thousands of stat(2) syscalls" on large repos). For this LSP the
  cleaner invalidation source is the existing `didChangeWatchedFiles` events;
  see §4.1.
- **YJIT helps.** Hot Ruby loops (token classification, AST walks, prefix
  filtering) benefit measurably; the server should be launched with YJIT
  enabled (the launcher at `lib/milk_tea/tooling/cli/commands/lsp.rb` currently
  does not force it, but inherits the process default).
- **Bounded, lazy per-item work.** Fetching documentation and resolving
  definition tokens *for every candidate on every request* multiplies the cost
  by the candidate count (see §4.4).

## 4. Industry-standard techniques, mapped to this codebase

### 4.1 Build a persistent module index (highest impact)

All serious LSPs index the workspace once and serve queries from memory:

- **clangd** maintains a `SymbolIndex` (file index + background index) layered
  behind a `MergedIndex`; completion for global symbols reads the index, not
  the AST.
- **SourceKit-LSP** maintains an index store for cross-file queries (definitions,
  references, call hierarchy). Notably, completion does **not** use the index
  store — it operates on the current file's AST plus its prepared target — which
  keeps completion latency independent of index staleness.
- **Shopify ruby-lsp** builds a `RubyIndexer` — a prefix tree of all indexed
  constants/methods, populated once at `initialized`, invalidated by file
  watching, and reused by completion, definition, hover, and workspace symbol.
  They specifically replaced a recursive visitor with a queue-based collector
  for a ~25% indexing speedup (`ruby-lsp#1171`) and replaced prefix-tree
  recursion with an explicit queue (`ruby-lsp#3401`).

**Recommendation:** add a `ModuleIndex` to the LSP `Workspace` that, on
`initialized` and on `workspace/didChangeWatchedFiles`, scans each module root
once and records the importable module names (`{root => {name => [path]}}`).
`import_completions` then filters the in-memory index by the typed prefix —
reducing the ~130–220 ms filesystem walk to a sub-millisecond hash lookup. This
also feeds `workspace/symbol` and global completion candidates.

On invalidation, prefer the LSP's existing `didChangeWatchedFiles` events (the
server already registers for them) over directory-mtime revalidation. A single
root-directory mtime `stat` is **not** sufficient: directory mtime only bumps
when a file is added/removed in *that* directory — a nested change such as
adding `std/sub/new/lib.mt` leaves the root directory's mtime unchanged.
Bootsnap's load-path cache handles this by recording and re-validating the
mtime of *every* scanned directory (still potentially thousands of `stat`
calls, per its author's analysis); the cheaper correct contract here is
event-driven invalidation via `didChangeWatchedFiles`, with mtime checks as a
fallback only for roots the editor is not watching.

### 4.2 Completion sessions + server-side re-filtering (SourceKit-LSP pattern)

SourceKit-LSP holds a **completion session** per (file, location): the full
candidate list is computed once, and subsequent requests with
`triggerKind == triggerFromIncompleteCompletions` re-filter the cached list by
the (longer) typed prefix instead of recomputing. Results carry
`isIncomplete: true` so the editor keeps re-querying cheaply while typing. It
also caps results (`completion-max-results=200`) to bound serialization cost.

**Recommendation:** key a completion-candidate cache by
`[uri, position.line, content.hash, completion_branch]`. On
`triggerFromIncompleteCompletions` with an unchanged line/context, filter the
cached candidate pool by the new prefix instead of rebuilding from `facts`.
`MAX_COMPLETION_ITEMS` (200) already exists and should be honored before
serialization (it currently is). This collapses N keystroke re-computations
into one compute + N cheap filters.

### 4.3 Cache completion item data; keep `resolve` cheap (Deno / tls / Roslyn)

- Deno added a short-lived `HashMap` cache for completion-item resolution:
  1200 ms → 75 ms (`denoland/deno#27831`).
- typescript-language-server sends a small `cacheId` per item and resolves
  `completionItem/resolve` against a server-side map, cutting response size
  from 620 KB to 200 KB (`tls#768`).
- Roslyn's optimized completion list reduced serialization ~1.8× by not
  round-tripping large `data` payloads.

**Recommendation:** the global branch already builds `data: {uri, name}` and
`handle_completion_resolve` does a `find_definition_token_global` per item —
fine for small modules, but it multiplies with candidate count. Cache resolved
documentation per `[uri, name]` (see §4.4) and avoid re-resolving definitions
already in the workspace definition index.

### 4.4 Stop fetching docs per candidate per keystroke

`handle_completion` (`completion.rb:330`) calls
`completion_function_documentation` (→ `find_definition_token_global` +
`doc_comment_data_for_definition`) for **every function** on **every request**
(`hover.rb:858`). The definition index makes each lookup fast, but it is
O(candidates) work repeated per keystroke and it forces definition-index
lookups even for items the user will never expand.

**Recommendation:** (a) memoize documentation per `[uri, name]` across requests
(a request-scoped cache already exists inside the branch, but it resets every
keystroke — promote it to a server-level cache invalidated by document change);
(b) only resolve docs for items the client actually resolves via
`completionItem/resolve`, leaving `documentation` out of the initial list.
This mirrors how ruby-lsp makes comment/doc collection lazy (`ruby-lsp#2547`)
and how Roslyn keeps large per-item payloads out of the initial completion list
(`dotnet/roslyn#52123`).

### 4.5 Defer heavy per-edit analysis off the request thread

`didOpen`/`didChange` (`store.rb:38`, `store.rb:82`) synchronously call
`warm_document_facts` → `get_facts` on the request thread: ~9–30 ms per edit
as measured on a tiny scratch file, and the cost grows with module complexity.
Note the eager warm is **not** duplicating the diagnostics sema pass:
`collect_diagnostics` reads `@tooling_snapshot_cache` and hands the cached
snapshot to `Diagnostics.collect` (`collection.rb:21,35,53`), which reuses it
via `sema_snapshot ||= ...` (`diagnostics.rb:88`) instead of re-running the
analysis. The eager warm is what *populates* that cache; the diagnostics
workers then collect lint/parse errors off the request thread using it.

**Recommendation:** keep the *fast* parts of `didChange` synchronous (content
apply, cache invalidation, dependency fingerprint check) but move the eager
facts analysis to the debounced background path, serving `last_good_facts`
until the background pass completes. This shifts the ~10 ms sema cost from the
keystroke-critical request thread onto the debounce timer. It does **not** make
`didChange` "microseconds": applying the edit, invalidating the cache, and
refreshing the dependency index remain synchronous — measured at ~3.8 ms on a
tiny file with `warm_document_facts` disabled. The win is moving the dominant
sema/import-resolution cost (which dominates on real modules) out of the
request thread, not eliminating the synchronous floor.

Requests that need fresh facts (hover/definition/completion) today already fall
back to `last_good_facts` when a recompute is in flight
(`workspace/caches.rb` `get_tooling_snapshot`, `try_lock` + last-good
fallback), which is the standard "index is eventually consistent" model used by
clangd and SourceKit-LSP. Moving the eager warm to the same background path
keeps that behavior while making the per-keystroke cost the synchronous floor
rather than full sema.

### 4.6 `milkTea/debugInfo` and `documentSymbol`

- `debugInfo` re-parses and rebuilds full semantic tokens every call
  (`debug_info.rb`). It is a debugging endpoint, not hot-path; optionally reuse
  `@semantic_tokens_cache` instead of `build_semantic_token_entries`.
- `documentSymbol` shows a wide latency spread (avg 5–18 ms, occasional 41–63 ms
  spikes). The flat symbol list is cached (`get_symbols`), but
  `enrich_with_children` (`formatting.rb`) walks the AST and rebuilds child
  symbols on every request, so the spikes are consistent with enrichment
  dominating the tail. Cache the enriched outline keyed by `content.hash` and
  only re-enrich when content changes.

## 5. Recommended priority order

1. **Module index for `import_completions`** — removes the only >100 ms
   endpoint; ~130–220 ms → sub-ms on the worst case. (§4.1)
2. **Completion session re-filtering + `isIncomplete`** — turns per-keystroke
   recomputation into per-keystroke filtering. (§4.2)
3. **Promote per-function doc cache to server scope** and make doc loading
   lazy via `completionItem/resolve`. (§4.4)
4. **Defer eager facts in `didChange`/`didOpen` to the background debounce.**
   (§4.5)
5. **Cache the enriched `documentSymbol` outline.** (§4.6)
6. **Cache completion item data / keep resolve cheap.** (§4.3)

## 6. Testing strategy

- Extend `all_endpoints_benchmark.rb` (already committed) with:
  - a large synthetic module root (e.g. 50 dirs × 30 modules) to exercise the
    module index;
  - a `triggerFromIncompleteCompletions` sequence measuring per-keystroke
    filtering vs. full recompute;
  - an edit-loop benchmark (didChange + follow-up hover) to validate the
    deferred-facts change.
- Add regression tests asserting `import_completions` returns stable results
  before/after module creation/deletion (the invalidation contract).
- Reuse the existing `MILK_TEA_LSP_PERF` stage breakdowns to confirm the
  `import_context` and `facts` stages collapse after each change.

## 7. Non-goals / rejected alternatives

- **Ractor-based parallelism**: the sema pipeline shares mutable state
  (`Types::Registry`, `@shared_module_cache`); wrapping it in `Ractor` is a
  rewrite, not an optimization, and GVL-bound Ruby makes it premature.
- **Persistent on-disk index (clangd `.idx`, SourceKit index store)**: the
  index formats here are memory-only today; on-disk persistence adds a cache-
  invalidation protocol for little gain until workspace sizes demand it.
- **Replacing `Dir.children` recursion with `Dir.glob("**/*.mt")`**: faster per
  scan but still a full-tree walk per keystroke; the module index makes it
  unnecessary. `Dir.scan` (Ruby 4.1, `ruby/ruby#16153`, yields the child type
  via `dirent.d_type` without N+1 `stat`s, ~2× faster scans) is a future
  accelerator for the index build itself, not a hot-path fix.
