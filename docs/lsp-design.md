# Self-Host LSP Architecture

Status: **Proposal.** Last updated: 2026-07-17 (audited — see §7 for risk register).

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

  lsp/              ← new
    protocol.mt     ← JSON-RPC transport (Content-Length framing)
    server.mt       ← message loop, handler dispatch
    workspace.mt    ← document state, module roots, caches
    diagnostics.mt  ← error → LSP diagnostic conversion
    lifecycle.mt    ← initialize, shutdown, configure
    text_docs.mt    ← didOpen, didChange, didClose, didSave

    # Tier 2 (future)
    definition.mt   ← go-to-definition
    hover.mt        ← type info on hover
    references.mt   ← find-all-references
    formatting.mt   ← format document
    symbols.mt      ← document symbols

    # Tier 3 (future)
    completion.mt   ← code completion
    semantic_tokens.mt ← syntax highlighting
    code_actions.mt ← quick fixes
    signature_help.mt ← parameter hints
    rename.mt       ← rename symbol
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

```mt
# protocol.mt
function read_message() -> Option[Message]:
    # Read Content-Length: N\r\n\r\n header
    # Read N bytes of JSON body
    # Parse JSON into {jsonrpc, method, params, id}

function write_response(id: Value, result: Value) -> void:
    # Build JSON response
    # Write Content-Length header + body to stdout
```

The `Content-Length` header is the only framing we need. No HTTP, no
WebSockets, no TCP. This is the standard LSP transport and matches the
Ruby compiler's implementation exactly.

The `std.c.stdio.fread` approach (verified working) reads raw bytes from
stdin. JSON bodies are typically 200-2000 bytes — well within a single
`fread` call.

### 4.2 Workspace — owned document state

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

The existing `check_program()` function already produces diagnostics
(module errors, parse errors, semantic errors, lint warnings). The LSP
diagnostics module converts these to the LSP format:

```mt
# diagnostics.mt
public struct Diag:
    range: Range        # {start: {line,character}, end: {line,character}}
    severity: ubyte     # 1=Error, 2=Warning, 3=Info, 4=Hint
    code: str           # e.g. "sema/error", "self-assignment"
    message: str        # human-readable
    source: str         # "milk-tea"

function collect(uri: str, content: str) -> vec.Vec[Diag]:
    # 1. Parse source
    # 2. Load program (module resolution)
    # 3. Check (semantic analysis)
    # 4. Lint
    # 5. Convert each error/warning to LSP diagnostic
    # 6. Filter to diagnostics belonging to `uri` only
    #    (check_program returns errors for all transitive imports;
    #     each diagnostic carries a `module_name` for filtering)
```

Note: `check_program()` returns diagnostics for ALL transitively-loaded
modules (imports, prelude, etc.). The `LoadDiagnostic.module_name` field
maps to the source file path via `LoadedModule.path`. The LSP publishes
diagnostics per-URI, so we filter to the root module before publishing.
Linter warnings already carry `path` and are filtered the same way.
```

### 4.4 Handler dispatch — table-driven

The handler table maps method names to function pointers. Each handler
receives access to the workspace and the protocol writer so it can send
notifications (like `textDocument/publishDiagnostics`) in addition to
returning a response:

```mt
# server.mt — conceptual signature
type Handler = fn(ws: ref[Workspace], proto: ref[Protocol], params: json.Value) -> Option[json.Value]

function register(handlers: ref[map_mod.Map[str, Handler]]) -> void:
    handlers.set("initialize", lifecycle.handle_initialize)
    handlers.set("textDocument/didOpen", text_docs.handle_did_open)
    # ... more registrations

function run() -> int:
    var ws = Workspace.create(...)
    defer ws.release()
    register(...)
    while true:
        let msg = protocol.read_message()
        match resolve(msg.method):
            Option.some as handler:
                let result = handler(ref_of(ws), ref_of(proto), msg.params)
                protocol.write_response(msg.id, result)
            Option.none:
                protocol.write_error(msg.id, "method not found")
```

**Risk note:** The `fn(...)` type is supported by the Milk Tea language but
has never been used in the self-host compiler's own source code. All
existing delegation uses `ref`-based dispatch (e.g., the linter's
`dispatch_cfg_rule` which is an `if`/`else if` chain, not a function
pointer table). If `fn` types prove problematic during bootstrap, the
fallback is the same `if`/`else if` pattern used throughout the compiler:

```mt
function dispatch(method: str, ...):
    if method == "initialize":
        lifecycle.handle_initialize(...)
    else if method == "textDocument/didOpen":
        text_docs.handle_did_open(...)
    else if ...
```

The table approach is cleaner but the chain approach works identically
and is proven in the existing codebase. Either way, the design is sound.

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

### 7.1 Map key lifetime (mitigated)

**Risk:** Using `str` (borrowed view) as Map keys for URI→content would create
dangling references when the JSON parse buffer is freed after message dispatch.

**Mitigation:** Use `string.String` (owned) for all map keys in the workspace.
`string.String` supports `hash`/`equal` hooks via `std.string` + `std.hash`
and owns its heap storage independently of the JSON message lifetime.
(Design updated in §4.2.)

### 7.2 `fn` type compatibility (low risk, fallback exists)

**Risk:** No self-host compiler code currently uses `fn(...)` function pointer
types. If C codegen for `fn` types has edge cases not covered by existing
tests, the handler dispatch table would fail at bootstrap.

**Mitigation:** The fallback is the proven `if`/`else if` chain pattern used
by `dispatch_cfg_rule` in the linter. The table-based dispatch is a clean
design target; if it fails, the chain approach costs ~20 lines and works
identically. The table approach can be attempted first and reverted if
bootstrap fails.

### 7.3 Content-Length header parsing (need to verify end-to-end)

**Risk:** Header parsing has been verified at the component level (`fread`
on stdin works) but not as an integrated flow (read header, extract
byte count, read body, parse JSON). Edge cases like chunked delivery or
partial reads are untested.

**Mitigation:** The LSP protocol guarantees that the `Content-Length` header
and body arrive atomically over a pipe (editor writes both in one `write()`).
The Go and Rust LSP implementations all use simple `read(header) + read(N
bytes)` without buffering. This is standard and low-risk.

### 7.4 Module loading latency (acceptable)

**Risk:** The existing `check_program()` function loads the full transitive
import closure for every diagnostics request. For large projects with deep
import trees, this could cause latency on every keystroke.

**Mitigation:** Tier 1 diagnostics run on `didSave` (not `didChange`), so
they are triggered only on explicit saves. `didChange` updates just emit
`textDocument/publishDiagnostics` with an empty array (clearing old
diagnostics). This matches how `rust-analyzer` and `gopls` handle the
trade-off between latency and correctness. Tier 2 can add incremental
re-checking using the existing module loader's dependency graph.

### 7.5 std.json render performance (acceptable)

**Risk:** `std.json.render` allocates a new `string.String` for every
diagnostic notification. For files with hundreds of diagnostics, this
could be expensive.

**Mitigation:** Diagnostic counts are typically < 20 per file (the
`language_baseline.mt` has 184 warnings across 1736 lines with ALL rules
enabled). The JSON render is amortized over the full check + lint pipeline
cost, which dominates. If profiling shows JSON as a bottleneck, `std.json`
can be extended with a builder API.

### 7.6 `defer` inside infinite loops (need explicit cleanup)

**Risk:** The server `run()` function contains an infinite `while true` loop
reading messages. Resources allocated inside the loop body (JSON values,
diagnostic vectors, workspace updates) must be released manually — `defer`
inside an infinite loop triggers only on function exit, which never happens.

**Mitigation:** All per-message allocations use explicit `release()` at the
end of each loop iteration. The `Workspace` struct is the only long-lived
allocation and is released via `defer` before `run()` returns on `exit`.


## 8. Comparison: Ruby LSP vs Self-Host LSP

| Aspect | Ruby LSP | Self-Host LSP (proposed) |
|--------|----------|--------------------------|
| Lines | ~11,900 | ~500 (tier 1) / ~2350 (all tiers) |
| Threads | Worker pool (8 threads) | Single-threaded |
| Dispatch | 22 mixin modules | Table of fn pointers (or if/else chain) |
| JSON | `JSON.parse` / `JSON.dump` | `std.json.parse` / `std.json.render` |
| Transport | Stdio `Content-Length` framing | Same |
| Caches | Multi-layer (tokens, AST, facts, semantic tokens) | Single document cache |
| Module resolution | `ModuleLoader` (shared) | Same `module_loader.mt` |
| Linter | Ruby `Linter.lint_source` | Same `linter.lint_source` |

The self-host LSP's simplicity is deliberate. Milk Tea's compilation
pipeline makes sophisticated caching strategies unnecessary for tier 1.
Features that benefit from caching (completions, hover) are deferred to
tier 2/3 where they can be added with the same module pattern.
