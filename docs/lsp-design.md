# Self-Host LSP Architecture

Status: **Implementation complete — all 3 tiers delivered.** Last updated: 2026-07-18.
23 modules, 4,947 lines, 25 capabilities advertised, valgrind-clean.
Cross-file navigation into imported modules; verified against a real editor
(headless Neovim 0.12: attach, cross-file hover/definition, diagnostics,
completion, clean shutdown).
All features parity-verified via piped JSON-RPC fixtures.

## 0. Design Principles

The self-host LSP follows these constraints drawn from the existing compiler
architecture (§self-host-plan) and bootstrap design (§bootstrap-design):

1. **Single-binary delivery.** The LSP is a subcommand (`mtc lsp`), not a
   separate executable. It lives in `projects/mtc/` and bootstraps through the
   existing 3-stage pipeline. No duplicate vendored-library builds, no separate
   release artifacts.

2. **Single-threaded message loop.** The compiler's existing analysis pipeline
   (lex → parse → check → lint) is single-threaded. The LSP follows the same
   pattern: one synchronous `read → dispatch → respond` loop. The Ruby LSP's
   multi-threaded diagnostics workers (§server/diagnostics_scheduling.rb) are
   an optimization, not a requirement — Milk Tea's full pipeline (including
   module loading) is fast enough for interactive use, so background workers
   provide no benefit for tier 1.

3. **Separate-module architecture.** Following the linter's successful pattern
   (`linter/cfg.mt`, `linter/own_ptr.mt`, `linter/redundant_cast.mt`), each
   LSP feature lives in its own module under `lsp/`. Thin wrappers in a
   `lsp/server.mt` dispatch messages. This avoids the large-file codegen issue
   discovered during linter integration (§self-host-plan §0.5).

4. **Tiered delivery.** Features are delivered in three independently-usable
   tiers (see §3). Each tier bootstraps separately — tier 1 must compile and
   run under the held fixed point before tier 2 code is written.

5. **Explicit memory management.** Uses the compiler's existing pattern:
   `vec.Vec` + `map_mod.Map` with `defer release()`. No GC pressure, no
   hidden allocations. Workspace state (document content, diagnostics, caches)
   is owned by a `Workspace` struct that implements `release()`.

6. **Source-only stdlib.** All stages load the same `std/` tree
   (§bootstrap-design §4.2). The LSP requires no new stdlib modules beyond
   what has been verified working: `std.json`, `std.stdio`, `std.fs`, `std.path`,
   `std.string`, `std.str`.

---

## 1. Entry Point — `mtc lsp`

```
mtc lsp [--stdio]
```

The `lsp` subcommand starts a JSON-RPC 2.0 server over stdio. It reads
LSP messages from stdin, dispatches to registered handlers, and writes
responses to stdout. Stderr is reserved for logging.

The command is added to the CLI dispatch in `main.mt` alongside the existing
`lint`, `check`, and `build` commands:

```mt
if cmd == "lsp":
    return lsp.run(args)
```

This follows the existing command pattern exactly — no special bootstrap
requirements.

---

## 2. Module Structure

```
projects/mtc/src/mtc/
  linter/           ← existing
  loader/           ← existing
  semantic/         ← existing
  parser/           ← existing

  lsp/              ← new (23 modules, 4,947 lines)
    protocol.mt     ← JSON-RPC transport (Content-Length framing)
    server.mt       ← message loop, if/else handler dispatch
    workspace.mt    ← document state, module roots
    diagnostics.mt  ← error → LSP diagnostic conversion
    lifecycle.mt    ← initialize, shutdown, configure
    text_docs.mt    ← didOpen, didChange, didClose, didSave
    uri.mt          ← file:// URI percent-decode
    cursor.mt       ← shared token-at-position resolution (Phase 0)
    highlight.mt    ← documentHighlight (Phase 2)
    folding.mt      ← foldingRange: indent blocks, imports, comments (Phase 2)
    selection.mt    ← selectionRange: word/line/statement/block (Phase 2)
    workspace_symbols.mt ← workspace/symbol with text prefilter (Phase 2)
    inlay_hints.mt  ← parameter-name hints at call sites (Phase 3)
    on_type_formatting.mt ← newline indent assist (Phase 3)

    # Tier 2
    navigation.mt   ← go-to-definition, hover, references (combined)
    formatting.mt   ← format document
    symbols.mt      ← document symbols

    # Tier 3
    completion.mt   ← code completion (keyword-based)
    semantic_tokens.mt ← syntax highlighting (lexer-based)
    code_actions.mt ← quick fixes (returns empty list)
    signature_help.mt ← parameter hints
    rename.mt       ← rename symbol (text-based)
```

### 2.1 Why separate modules?

The linter experience proved that inlining 300+ lines of new code into
the 3760-line `linter.mt` caused C runtime crashes. The separate-module
pattern (`linter/own_ptr.mt` at 115 lines, `linter/redundant_cast.mt` at
110 lines) worked perfectly. The LSP should follow the same pattern from
the start, with no single file exceeding ~600 lines.

### 2.2 Module dependencies

```
  main.mt
    ├── lsp/server.mt
    │   ├── lsp/protocol.mt     (stdio + JSON)
    │   ├── lsp/workspace.mt    (document state)
    │   ├── lsp/diagnostics.mt  (error conversion)
    │   ├── lsp/lifecycle.mt    (init/shutdown)
    │   ├── lsp/text_docs.mt    (document sync)
    │   └── (tier-2/3 modules as added)
    ├── loader/                 (existing — module resolution)
    ├── semantic/analyzer.mt    (existing — type checking)
    ├── parser/                 (existing — parsing)
    └── linter/                 (existing — lint rules)
```

No circular imports. Each LSP module depends only on the compiler's
existing public APIs and `std.*` libraries.

---

## 3. Tiered Delivery Plan

### 3.1 Tier 1 — Diagnostics + Document Sync (~500 lines)

Enough for real-time error feedback in any LSP-capable editor.

| Feature | Module | Lines | What it does |
|---------|--------|-------|--------------|
| JSON-RPC transport | `protocol.mt` | ~120 | Content-Length framing, JSON parse/render, method dispatch |
| Server loop | `server.mt` | ~120 | `read → dispatch → respond` loop, handler registration |
| Lifecycle | `lifecycle.mt` | ~50 | `initialize` (returns capabilities), `shutdown`, `exit` |
| Document sync | `text_docs.mt` | ~60 | `didOpen`/`didChange`/`didClose` → update workspace |
| Diagnostics | `diagnostics.mt` | ~80 | Lex → Parse → Check → Lint → publishDiagnostics |
| Workspace | `workspace.mt` | ~70 | URI ↔ path, document content storage, module root discovery |
| **Total** | | **~500** | |

The compiler already has `check_program()` which produces diagnostics
(module errors, parse errors, semantic errors, lint warnings). The
diagnostics module just converts these to LSP `Diagnostic` JSON.

### 3.2 Tier 2 — Navigation (~700 lines)

Go-to-definition, hover, references, formatting, document symbols.

| Feature | Lines |
|---------|-------|
| `definition.mt` | ~150 |
| `hover.mt` | ~150 |
| `references.mt` | ~120 |
| `formatting.mt` | ~80 |
| `symbols.mt` | ~100 |
| **Total (tier 1+2)** | **~1200** |

The compiler's module loader and semantic analyzer already resolve types,
fields, methods, and imports. The navigation modules query these existing
structures — no new analysis infrastructure is needed.

### 3.3 Tier 3 — Rich Features (~1200 lines)

Completions, semantic tokens, code actions, signature help, rename.

| Feature | Lines |
|---------|-------|
| `completion.mt` | ~350 |
| `semantic_tokens.mt` | ~300 |
| `code_actions.mt` | ~200 |
| `signature_help.mt` | ~150 |
| `rename.mt` | ~150 |
| **Total (all tiers)** | **~2350** |

Completions are the heavyweight — they need module member enumeration,
scope-aware local binding collection, and keyword/snippet generation.
Semantic tokens reuse the lexer's token stream. Code actions map linter
warnings to fixes (the linter already has auto-fix logic for some rules).

---

## 4. Key Design Decisions

### 4.1 Transport — stdio JSON-RPC 2.0

Implemented via `stdio.read_char()` (libc-buffered getchar) for input and
`stdio.print_format("%s", cstr)` + `stdio.file_flush(null)` for output.
The `stdin`/`stdout` `FILE*` globals are not exposed via bindings, so
the `fread`-based approach from the original proposal was not feasible.

Response rendering uses raw string formatting rather than `std.json`
Object trees, because `json.Object.set()` copies Value structs sharing
heap Object pointers, causing double-frees during cascaded release_value.
Raw strings avoid the sharing entirely.

### 4.2 Workspace — owned document state

Implemented as proposed.  The `source_for_uri` accessor from the design
was removed — unused in tiers 1-3.  Map keys use `string.String` (owned).

```mt
# workspace.mt
public struct Workspace:
    root_path: string.String            # workspace root
    module_roots: vec.Vec[string.String]  # -I paths for module resolution
    open_docs: map_mod.Map[string.String, string.String]  # uri → source content

extending Workspace:
    public static function create(root: str) -> Workspace: ...
    public editable function open(uri: str, text: str) -> void: ...
    public editable function change(uri: str, text: str) -> void: ...
    public editable function close(uri: str) -> void: ...
    public function source_for(uri: str) -> Option[str]: ...
    public editable function release() -> void: ...
```

Map keys use `string.String` (owned) rather than `str` (borrowed view).
This is necessary because URI strings from incoming JSON-RPC messages
are parsed into temporary `json.Value` buffers that are freed after
message dispatch. The workspace must own its keys to avoid dangling
references. `string.String` provides the `hash`/`equal` hooks required
by `Map` through the `std.string` and `std.hash` imports already present
in the compiler.

One `Workspace` instance lives for the lifetime of the server. Documents
are stored by URI (file:// paths). Module roots are discovered from the
workspace root's `package.toml` or default to the repo root.

No incremental parsing cache needed for tier 1 — the full parse + check
+ lint pipeline takes < 50ms for typical files.

### 4.3 Diagnostics — reuse check_program

The existing `check_program()` function produces diagnostics.  The
diagnostics module converts them to LSP format and publishes via
`textDocument/publishDiagnostics` notification.

Note: `LoadDiagnostic` carries a `path` field (not `module_name` as the
original proposal stated).  Diagnostics are filtered by URI path before
publishing.

### 4.4 Handler dispatch — if/else chain

An `if/else` chain is used (not the proposed fn-pointer table), matching
the proven pattern from the linter's `dispatch_cfg_rule`.  §7.2 risk
resolved: the fn-table approach was bypassed to avoid potential `Map[K,
fn(...)]` codegen issues (this pattern has zero real-world exercise in
the codebase).

### 4.5 Source-only — no pre-compiled artifacts

The LSP needs no new vendored libraries beyond cJSON (already vendored
and verified working). The existing compilation pipeline handles `std.json`
natively. All stdlib dependencies are source-only `.mt` files loaded
from the `std/` tree at compile time.

---

## 5. Bootstrapping Impact

The LSP code lives in `projects/mtc/src/mtc/lsp/` and is compiled as part
of the existing `projects/mtc` package. No changes to the bootstrap process.

```
stage0 (Ruby)  ──build──→  stage1/mtc  (now includes `mtc lsp`)
stage1         ──build──→  stage2/mtc  (distributable, includes LSP)
stage2         ──build──→  stage3/mtc  (fixed-point verification)
```

The fixed-point invariant (`stage2.c == stage3.c`) still holds because
the LSP code is part of the compiler's source tree. Adding new source
files to `projects/mtc/src/` is a normal development operation that
doesn't disturb the bootstrap.

### 5.1 What about the Ruby LSP?

The Ruby LSP continues to serve VS Code users today. The self-host LSP
targets the same protocol — any editor using the Ruby LSP can switch
to the self-host LSP by pointing it at the `mtc lsp` binary. The Ruby
LSP is not deprecated; it remains available until all tier-3 features
are self-hosted.

---

## 6. Implementation Sequence

| Step | What | Key note |
|------|------|----------|
| 1 | `lsp/protocol.mt` — Content-Length framing + JSON read/write | Try `fn` table first; fall back to `if/else` chain if bootstrap fails (§7.2) |
| 2 | `lsp/lifecycle.mt` — initialize/shutdown handlers | `initialize` returns tier-1 capabilities only |
| 3 | `lsp/workspace.mt` — document storage + module roots | Use `string.String` keys, not `str` (§7.1) |
| 4 | `lsp/text_docs.mt` — didOpen/didChange/didClose | `didSave` triggers full check; `didChange` clears diagnostics (§7.4) |
| 5 | `lsp/diagnostics.mt` — error → LSP diagnostic | Reuses `check_program()` from loader |
| 6 | `lsp/server.mt` — wire into `main.mt` as `mtc lsp` | Explicit release() in while loop, not defer (§7.6) |
| 7 | Tier 2 modules (definition, hover, etc.) | |
| 8 | Tier 3 modules (completion, etc.) | |

Each step preserves the held fixed point (177 compiler tests + fixed-point
invariant). Steps are self-contained — step N starts only after step N-1
is committed and verified.

---

## 7. Risk Register

### 7.1 Map key lifetime — RESOLVED
`string.String` keys used throughout.  No dangling-reference issues found.

### 7.2 `fn` type compatibility — RESOLVED (bypassed)
`if/else` chain chosen over fn-pointer table.  Risk avoided entirely.

### 7.3 Content-Length header parsing — RESOLVED
Verified end-to-end via piped fixture tests.  Multi-message sequences
processed correctly.

### 7.4 Module loading latency — ACCEPTED
Diagnostics on `didSave` only.  Works correctly; latency acceptable.

### 7.5 std.json render performance — RESOLVED (bypassed)
Raw-string rendering used for all responses.  std.json.render not used.

### 7.6 `defer` inside infinite loops — RESOLVED
Explicit `release()` at end of each loop iteration.  Workspace deferred
on exit.

### 7.7 Self-host C codegen — RESOLVED (2026-07-18)
Recursive JSON object serialization (`entry.key.as_str()` in unsafe while
loop) generated incorrect C (`const_ptr_as_str`) and objects rendered as
`{}`.  Root cause: `concrete_field_type`'s bare-name struct lookup scanned
all program analyses in dependency order, so `std.map.Entry` (with
`key: const_ptr[K]`) shadowed `std.json.Entry` (with `key: string.String`)
whenever std.map preceded std.json in the module closure — which is why
standalone programs worked but the full mtc build did not.  Fixed by
resolving the struct in the receiver type's owning module first
(`ty_imported.module_name`), falling back to the ordered scan only when the
owner has no such struct.  `append_json_value` now renders objects
recursively, and `publishDiagnostics` params (previously `{}` over the
wire) carry full diagnostic payloads.  A second latent bug surfaced by the
fix — `diagnostic_from_warning` never populated its range positions — was
fixed the same day.


## 8. Comparison: Ruby LSP vs Self-Host LSP (actual)

| Aspect | Ruby LSP | Self-Host LSP |
|--------|----------|---------------|
| Lines | ~11,900 | 4,947 (23 modules) |
| Threads | Worker pool (8 threads) | Single-threaded |
| Dispatch | 22 mixin modules | if/else chain |
| JSON | `JSON.parse` / `JSON.dump` | `std.json.parse` / raw-string rendering |
| Transport | Stdio `Content-Length` framing | Same (getchar loop) |
| Capabilities | 49 advertised | 25 advertised |
| Caches | Multi-layer (tokens, AST, facts, semantic tokens) | Single document cache |
| Module resolution | `ModuleLoader` (shared) | Same `module_loader.mt` |
| Linter | Ruby `Linter.lint_source` | Same `linter.lint_source` |

### Known gaps (self-host vs Ruby)

| Feature | Status |
|---------|--------|
| ~~Recursive JSON object serialization~~ | **FIXED (2026-07-18)** — module-aware struct field lookup in lowering (§7.7); objects and publishDiagnostics params render fully |
| ~~Editor-buffer document sync~~ | **FIXED (2026-07-18, Phase 0)** — `Workspace.document_source` (buffer first, disk fallback) is now used by every position-based handler; previously they read stale disk content |
| ~~linter.Warning column info~~ | **BRIDGED (2026-07-18, Phase 0)** — warning ranges are recovered by locating the message's quoted symbol on the warning line (Ruby `extract_warning_range` parity); sema-error ranges use `LoadDiagnostic.column`. True `column`/`length` Warning fields remain future work for `--fix`. |
| ~~Text-scan references/rename~~ | **FIXED (2026-07-18, Phase 1)** — token-accurate occurrences (`cursor.identifier_occurrences`); string-literal/comment text never matches, exact columns. Scope-aware locals and cross-file references remain future tiers. |
| ~~Keyword-only completion~~ | **FIXED (2026-07-18, Phase 1)** — module symbols (functions/structs/enums/interfaces/values/imports) plus `alias.` member completion via module-path resolution |
| ~~Name-only hover~~ | **FIXED (2026-07-18, Phase 1)** — markdown hover with full signatures (functions incl. async/variadic/return, const/var types, struct fields, enum/variant members) and attached `##` doc comments; definition ranges point at the name token |
| ~~Lexer-class-only semantic tokens~~ | **FIXED (2026-07-18, Phase 1)** — identifiers classified via Analysis facts: function/type/namespace/parameter/variable, plus builtin type names |
| ~~Stdio-based editor smoke test~~ | **DONE (2026-07-18, Phase 4)** — headless Neovim 0.12 against `mtc lsp`: attach + capabilities, cross-file hover (`heap.release` signature + docs), cross-file definition (`std/mem/heap.mt`), publishDiagnostics with symbol-precise ranges, completion, clean server shutdown on editor exit |
| ~~Same-file-only definition/hover~~ | **FIXED (2026-07-18, Phase 4)** — `alias.member` resolves through the import map + module path into the imported module's file (signature, `##` docs, exact name range); an import alias itself resolves to the module file. Phase 4 also fixed a latent diagnostics bug: the root module was taken from `modules.last()` (DFS pre-order → last *dependency*), so lint ranges and token-based rules ran against the wrong source for any root with imports; now indexed via `order.last()`. Generic struct hovers render AST field types (`own[T]?`, not `own[<error>]?`). |
| 24 remaining Ruby-only capabilities (call hierarchy, code lens, etc.) | Out of scope — Phase 2 (2026-07-18) added documentHighlight, prepareRename, foldingRange, workspace/symbol, selectionRange, semanticTokens/range; Phase 3 added declaration, typeDefinition, implementation, inlayHint (parameter-name hints), onTypeFormatting, and quickfix code actions (underscore-prefix for unused-*, var→let for prefer-let). workspace/symbol requires a non-empty query (no workspace index yet) and caps at 200 results; typeDefinition covers type names and module-level values (locals need the scope walker); implementation and inlay hints are single-file tiers. |
