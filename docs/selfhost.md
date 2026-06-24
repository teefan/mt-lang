# Self-Hosted Milk Tea Compiler (`projects/mtc`)

> Status: **design / not yet started** (clean restart).
> This document is the authoritative architecture and plan for the self-hosted compiler.
> It supersedes the earlier `projects/mtc` attempt, which was a 1:1 transliteration of the
> Ruby reference compiler and was removed. The lessons from that attempt are carried
> forward in §8.

---

## 1. Purpose, Goals, Non-Goals

`mtc` is the Milk Tea compiler **written in Milk Tea**. It reimplements the Ruby reference
compiler in `lib/milk_tea/core/` and emits the same readable C.

### Goals

- **Dogfooding / co-existence.** `mtc` runs *alongside* the Ruby compiler. The Ruby compiler
  remains the **canonical implementation and the executable specification**. `mtc` is both a
  second implementation and the largest real-world Milk Tea program, exercising the language.
- **Full v1 parity.** `mtc` targets the **entire frozen v1 language surface** (see §3), not a
  subset. It must accept everything the Ruby compiler accepts and reject everything it rejects.
- **Staged JSON-IR handoff.** The port proceeds front-to-back, one pipeline stage at a time. Each
  stage is completed to **100% language coverage**, emits its artifact as **JSON IR**, and hands it
  to the Ruby compiler, which ingests the JSON and performs the remaining stages (§7). The Ruby
  "back half" shrinks with every completed stage, so every milestone runs on the whole corpus and
  is independently verifiable (§9).
- **Bit-for-bit differential agreement** with the Ruby compiler on normalized C output and on
  compiled-binary behavior over a pinned corpus (§9).
- **Self-hosting fixpoint** as the *terminal* milestone, once `mtc` owns every stage (including
  codegen): `mtc` compiled by Ruby (stage1) compiles `mtc` again (stage2) and
  `stage1 C output ≡ stage2 C output` (§7).

### Non-Goals (v1)

- **Not** retiring the Ruby compiler. It stays canonical.
- **Not** a native/LLVM backend. The backend emits **C** (kept pluggable; §5). Native/LLVM/WASM
  backends are post-v1 and live behind the same IR boundary.
- **Not** a demand-driven query engine (salsa/Roslyn-style). Incrementality is **module-granular**
  (§5), matching the Ruby compiler's existing model. Finer granularity is left open by making
  artifacts serializable, but is not built in v1.
- **Not** a generated-C seed (committing `mtc.c` to drop the Ruby dependency). Because the
  end-state is co-existence, the seed is unnecessary; it remains a documented future option (§7).

---

## 2. Why a clean restart (lessons that shape this design)

The prior attempt was architecturally sound (interning, arenas, diagnostics-as-data,
`Result`/`Option`) and reached end-to-end on a subset. It was removed because the *process* was
wrong, not the architecture:

1. **It chased a moving target.** It transliterated a 47k-LoC compiler that is still actively
   changing. Without a frozen spec and a differential oracle, the port was perpetually behind
   and unverifiable.
2. **It mirrored Ruby's object graph 1:1** (heap objects, pointer-arena nodes), which fights
   Milk Tea's safety model and produced large translation friction (§8).

This design fixes both: **freeze the spec** (§3) and adopt a **data-oriented, index-based**
internal model (§4, §6) that is idiomatic-safe Milk Tea.

---

## 3. Spec Freeze & the Differential Oracle (process backbone)

Because we port the *whole* language, the v1 surface is **frozen** before porting begins:

- **Spec snapshot.** Pin `README.md`, `docs/language-manual.md`, and the Ruby compiler at a
  tagged commit (`spec/v1`). The manual wins on conflicts (per README).
- **Pinned corpus.** A versioned set of `.mt` inputs (all of `std/`, `examples/`, and the
  compiler test fixtures) is the conformance corpus. New language features do not enter the
  corpus until the freeze is intentionally bumped to `spec/v1.x`.
- **Oracle.** The Ruby compiler at `spec/v1` is the oracle. Every `mtc` phase is validated by
  comparing against the oracle's output for that phase (§9), not by hand-judgement.
- **Freeze mechanics (resolves Q4).** Because `projects/mtc`, the Ruby compiler, and the corpus
  all live in one repo, the freeze is a **git tag** (`spec/v1`) — not a vendored snapshot, which
  would duplicate and rot. The `mtc-diff` harness records the tag's commit SHA and runs the
  oracle from a cached `git worktree` checkout (e.g. `tmp/oracle/<sha>`), so it always invokes the
  *tagged* Ruby compiler regardless of the working branch. Bumping the freeze is a new tag
  (`spec/v1.1`) plus a corpus update and a one-line SHA change in the harness.

This converts "is the port correct?" from a subjective question into an automated check.

---

## 4. Architecture Overview

Same staged pipeline as the Ruby compiler, but every boundary is a **typed, index-based,
serializable artifact**.

```
Source (.mt)
  → Lexer        bytes → Token pool            (Token = kind enum + span + IdentId)
  → Parser       tokens → AST (index pools)     recursive descent + Pratt precedence
       (CST)     lossless tokens + trivia       (formatter / LSP only)
  → ModuleGraph  resolve imports, topo levels,  content-hash cache  (port of ModuleLoader)
  → Semantic     Binder → Checker (+ CFG dataflow, const-eval, generics, interfaces)
                 → Analysis (per-module, cacheable)
  → Lowering     Analysis → flat C-oriented IR (index pools)  (+ async normalization)
  → Backend      IR → C   [default]            (WASM/LLVM/native later, same IR interface)
                 C → cc → binary
```

Stage-for-stage map to the Ruby reference (`lib/milk_tea/core/`):

| Ruby reference | `mtc` module |
|---|---|
| `lexer.rb`, `token*.rb`, `keywords.rb` | `compiler/lexer/` |
| `parser*.rb`, `ast.rb` | `compiler/parser/` |
| `cst*.rb` | `compiler/cst/` |
| `module_loader*.rb`, `module_binder.rb`, `module_*` | `compiler/driver/` |
| `semantic_analyzer.rb`, `semantic/`, `binding_types.rb` | `compiler/sema/` |
| `cfg*.rb` | `compiler/sema/cfg/` |
| `compile_time*.rb` | `compiler/sema/const_eval/` |
| `types/` | `compiler/types/` |
| `lowering*.rb`, `ir.rb` | `compiler/lowering/` |
| `c_backend*.rb` | `compiler/codegen/c/` |
| `pretty_printer/` | `compiler/debug/` |

### Integration via JSON IR boundaries

Each phase boundary is a **stable, versioned JSON IR** that both compilers can write and read.
This is the bootstrap's integration seam (§7) and its per-stage verifier (§9):

| Boundary | JSON artifact | Emitted by | Ingested by (Ruby resume point) |
|---|---|---|---|
| post-lex | token stream | `mtc lex --json` | parser (`--from-tokens`) |
| post-parse | AST (node-id keyed) | `mtc parse --json` | sema (`--from-ast`) |
| post-sema | annotated AST (AST + per-node `TypeId`, bindings, const values) | `mtc check --json` | lowering (`--from-analysis`) |
| post-lower | flat IR | `mtc lower --json` | C backend (`--from-ir`) |

- The **schema is owned by the Ruby compiler at `spec/v1`**: Ruby gains a `--json` emitter (the
  golden reference) and a `--from-<stage>` ingester (resume point) at each boundary. `mtc` must
  produce JSON that matches Ruby's emitter for the same input after canonicalization (§9).
- Node identity travels as **stable ids**, not object identity. The Ruby AST already carries
  `node_ids`; sema side-tables (e.g. `resolved_expr_types`, currently keyed by `object_id`) are
  re-keyed to node ids for JSON. This is the index-handle model (§5.1, §6), which makes every
  boundary serialize naturally.
- The **post-sema boundary serializes the annotated AST** — the subset lowering actually reads
  (per the `lowering.rb` contract) — not the full in-memory `Analysis` object graph. This keeps the
  hardest boundary tractable.

---

## 5. Design Principles

1. **Index handles, not pointers.** AST and IR nodes live in typed pools (`Vec[Node]`) and are
   referenced by `u32` handles; child lists are index ranges. Access is safe, bounds-checked
   `vec[i]` / `get(vec, i)` — **no `unsafe`**. This is the key upgrade over the prior
   arena-pointer model: it is cache-friendly, idiomatic-safe Milk Tea, and trivially
   serializable (which gives caching, IDE persistence, and fixpoint diffing for free).
2. **Interned atoms.** Identifiers, operators, builtin names, and type names become integer
   ids (`IdentId`) via a `StringInterner` right after lexing. Zero string comparisons in
   parser/sema/lowering.
3. **Interned types.** Type objects get canonical `TypeId` integers from a `TypeRegistry`.
   Type equality is integer comparison; zero structural `==` in the checker.
4. **Diagnostics are data, not exceptions.** A `Vec[Diagnostic]` sink lives in the session.
   Recoverable errors append; only truly unreachable invariants call `fatal()`. Fallible
   operations return `Result` / `Option` and use `?`.
5. **Arena/pool per phase.** Pools and interners are owned by the session; per-phase scratch is
   freed wholesale at phase end. No per-node refcounting.
6. **AST vs CST split (CST consumers deferred — resolves Q3).** The lexer can retain trivia from
   P1 (mirroring the Ruby `lex` vs `lex_with_trivia` split), so a lossless CST view is available
   early and cheaply. But the CST *consumers* — formatter and LSP — are decoupled from the compile
   pipeline and the fixpoint, which never touch the CST; they are deferred to a post-fixpoint
   tooling phase (P10). P2's parser does not depend on the CST.
7. **Backend behind an interface.** Lowering targets a backend-agnostic IR. The C backend is
   the only v1 implementation; the boundary keeps WASM/LLVM/native open.
8. **Module-granular incremental; no on-disk `Analysis` (resolves Q2).** Within a run, per-module
   `Analysis` is cached in memory and the module graph is checked in topologically-sorted levels
   (a direct port of `ModuleLoader`). Across runs, only **generated C + compiled artifacts** are
   persisted, keyed by content hash — a port of `build_cache.rb`, which itself never serializes
   `Analysis`. On-disk `Analysis` serialization is therefore *not* built in v1; if it is ever
   needed for sub-build incrementality, use a text/JSON form first (debuggable, like
   `modules.json`) and a binary form only if profiling demands it. This *incremental cache* is
   distinct from the JSON IR emitted at phase boundaries (§4): those serializers are core and built
   per stage for the handoff and oracle, but they are not used as a persistent build cache in v1.

---

## 6. Internal Data Model

The "modern" core is data-oriented. Concretely:

```
Session
  interner:   StringInterner          # str <-> IdentId
  types:      TypeRegistry            # canonical TypeId interning
  diagnostics: Vec[Diagnostic]        # accumulate; no exceptions
  pools:      per-phase node pools (Token, AstNode, IrNode, ...)

Handle types (all u32 indices into pools)
  IdentId, TypeId, AstId, IrId, NodeRange { start: u32, len: u32 }

Token        { kind: TokenKind, span: Span, ident: IdentId }
AstNode      { kind: AstKind, ... payload by kind ..., children: NodeRange }
Type (in registry)  Primitive | Pointer | Ref | Span | Array | Struct | Variant
                    | Generic | Function | Nullable | ...   -> deduped to TypeId
Analysis     per-module: resolved types (AstId -> TypeId), bindings, const values,
             implemented interfaces, exported surface   (serializable, cacheable)
IrNode       flat, C-oriented: Function, LocalDecl, If, Switch/Goto/Label, While, For,
             Return, Call, Member, Index/CheckedIndex/NullableIndex, Binary/Unary,
             Sizeof/Alignof/Offsetof, Reinterpret, ...   (mirrors `ir.rb`)
```

Enum members use disambiguating prefixes to dodge C/MT keyword and type-name collisions
(carried over from the prior attempt): `tk_` (TokenKind), `op_`/`uop_` (operators),
`pk_` (PrimitiveKind), `gk_` (generic kinds), `bi_` (builtin names).

---

## 7. Bootstrap via Progressive JSON Handoff

The port replaces the Ruby pipeline **front-to-back**, one stage at a time. At each milestone the
front stages are `mtc`, the back stages are Ruby, and the two halves meet at a JSON IR boundary
(§4):

```
M1 (after P1)  .mt → [mtc Lexer] → tokens.json → [Ruby parse→sema→lower→C→cc] → binary
M2 (after P2)  .mt → [mtc Lexer→Parser] → ast.json → [Ruby sema→lower→C→cc] → binary
M3 (after P4)  .mt → [mtc …→Sema] → analysis.json → [Ruby lower→C→cc] → binary
M4 (after P5)  .mt → [mtc …→Lowering] → ir.json → [Ruby C backend→cc] → binary
M5 (after P6)  .mt → [mtc …→C backend] → C → cc → binary           (Ruby leaves the pipeline)
```

- Each milestone is shippable and runs on the **whole corpus** immediately, because Ruby finishes
  the job. A stage is "done" only at 100% language coverage with green per-boundary and handoff
  behavioral parity (§9).
- At **M5** `mtc` owns every stage and Ruby leaves the *pipeline* (it stays as the co-existing
  oracle). Only then does the **self-hosting fixpoint** apply:

```
Stage1   mtc  --built by Ruby @ spec/v1-->  mtc.c --cc-->  stage1
Stage2   stage1  --rebuilds mtc-->          mtc.c --cc-->  stage2
Fixpoint  ⇔  C(stage1, mtc) ≡ C(stage2, mtc)   (reproducible)
```

- Reaching the fixpoint proves `mtc` can compile itself and is internally consistent.
- Under the co-existence goal, **Ruby is not retired** and **no generated-C seed is committed**;
  the seed remains a documented future option should the goal ever change to full replacement.

---

## 8. Pain-Point Mitigations (carried forward)

The prior audit catalogued where Ruby idioms resisted translation. Each is pre-solved by the
data model above:

| Prior pain point | Ruby idiom | This design |
|---|---|---|
| String atoms (~150) | `name == "ptr"` | `IdentId` integer compare; builtin/type names interned once |
| Type equality (~40) | structural `==` | `TypeId` integer compare via registry |
| C string concat (~100) | `+`/interpolation | `String` builder + `str_buffer[N]`; emit into a `CWriter` sink |
| Identifier sanitization | regex | explicit byte-wise sanitizer over `IdentId` lookups |
| `.is_a?` introspection (~200) | runtime class checks | `match` on `kind` enums of variant nodes |
| Compound-key `==` (~10) | struct `==` as map key | `(IdentId, TypeId, ...)` integer tuples / `hash`+`equal` hooks |
| Memoization / lazy init (~30) | `||=` | explicit `Option` cache fields filled on first use |
| Heterogeneous containers (~20) | hashes of mixed types | typed variants / records |
| Exceptions (~250 `raise`) | control-flow via raise | `Result`/`Option` + `?`; `fatal()` only for unreachable invariants |
| `nil` (ubiquitous) | nilable everything | `T?` / `Option[T]`, `let ... else:` guards |
| Mutual recursion (~5) | free functions | module-level functions (no forward-decl issue) |

---

## 9. Differential Testing Strategy

`mtc-diff` is built **before** porting begins and grows with the port. For the stage under
development it runs these checks over the whole pinned corpus:

1. **JSON-boundary parity (primary).** Compare `mtc`'s JSON IR at the stage boundary to the Ruby
   oracle's JSON for the same input, after schema canonicalization (sorted object keys, normalized
   node-id numbering, no source paths). This isolates the stage's correctness exactly.
2. **Handoff behavioral parity.** Build each corpus program two ways — all-Ruby, and
   `mtc`-front-half + Ruby-back-half via the JSON handoff (§7) — and assert identical program
   behavior (exit code + stdout). This validates integration end-to-end at every milestone.
3. **Diagnostic parity.** Negative fixtures: assert `mtc` reports the same error set
   (code/line/column) as the oracle, at whatever stage first rejects the program.
4. **Normalized-C parity (from M5 / P6).** Once `mtc` owns codegen, additionally compare emitted C
   per the normalization pipeline below.
5. **CI gate.** A corpus program is "ported" for a stage only when its checks pass. Every harness
   invocation of an `mtc` binary runs under the safety limits below.

### C normalization pipeline (resolves Q1)

Cosmetic C differences must not cause false negatives, while structural differences must. The
harness normalizes both compilers' output identically, in this order:

1. **Drop `#line`.** Invoke both compilers with `emit_line_directives: false`
   (`CBackend.generate_c(..., emit_line_directives: false)` — already used for cached C in
   `build.rb`). This removes all absolute, temp-dir-dependent `#line N "path"` lines outright, so
   no path normalization is needed.
2. **Canonical-renumber compiler-generated names.** All compiler temporaries share the `__mt_`
   prefix (`c_backend/statements.rb` `compiler_generated_local_name?`), including counter-based
   names such as `__mt_checked_index_ptr_<n>`, and string-literal globals are `mt_str_lit_<i>`
   (indexed by collection order, `runtime_helpers.rb`). Rewrite each family (`__mt_*`,
   `mt_str_lit_*`) to a canonical numbering assigned in first-appearance order, so any drift in
   counter values or collection order between the two implementations is absorbed.
3. **Sort `#include` directives.** Header order is semantically irrelevant for the system/runtime
   headers emitted here; sort the leading `#include` block so feature-gated append order cannot
   diverge.
4. **Compare top-level declarations as a keyed set, not by text order.** Synthetic decls (generic
   instantiations, `Task`/`proc`/`dyn`/`span`/`SoA`, helpers) are emitted as `uniq { linkage_name }`
   sets and aggregates are topologically sorted; the *set* and the *linkage names* are
   deterministic, but emission *order* tracks monomorphization discovery order. Split normalized C
   into top-level units (typedef / struct / union / enum / function decl / function def /
   constant), key each by linkage name + signature, and compare the resulting multisets. C permits
   free top-level ordering given forward declarations, so set comparison is sound.
5. **Whitespace canonicalization.** Trailing-space trim and a single trailing newline (matches
   `CBackend#emit`'s `rstrip + "\n"`).

**Behavioral parity is the tiebreaker.** When normalized C still differs, handoff behavioral parity
(check 2 above) is the ground truth: if both binaries behave identically on the corpus program, the
difference is cosmetic and the top-level-set comparison (normalization rule 4) decides pass/fail.

### Testing safeguards (the compiler under test is a C binary)

`mtc` compiles to C and runs as a native binary, so a bug in any stage can hang or allocate
unboundedly (arena/pool growth can reach GBs in seconds). Every harness invocation of an `mtc`
binary is sandboxed:

- **Wall-clock timeout.** `timeout --signal=KILL <T> mtc …` (default a few seconds per corpus file;
  tunable per fixture). A timeout is a test failure attributed to that file + stage.
- **Address-space cap.** Bound resident growth with `prlimit --as=<bytes>` (or a
  `systemd-run --user --scope -p MemoryMax=<bytes> -p MemorySwapMax=0` cgroup, which OOM-kills
  cleanly). Default a few hundred MB for normal builds; raised for sanitizer builds.
- **Sanitizer matrix (dev/CI).** Build the `mtc` C with `-fsanitize=address,undefined` so
  out-of-bounds access, UB, and leaks surface at the source instead of as a vague OOM. ASan/UBSan
  runs use a higher memory cap and a longer timeout.
- **Crash classification.** Record the exit signal (SIGKILL = timeout/OOM, SIGSEGV, SIGABRT =
  sanitizer/assert), the offending corpus file + stage, and (where cheap) a minimized input.

These limits apply to `mtc` only; the Ruby oracle runs unsandboxed.

---

## 10. Phased Plan

Whole-language target, staged by pipeline, integrated via the JSON handoff (§7). Each stage is
completed to **100% language coverage** before the next begins; it emits its JSON IR and hands off
to Ruby for the remaining stages. Unless noted, each phase's *Verify* means the §9 checks
(JSON-boundary parity + handoff behavioral parity + diagnostic parity) green over the **whole**
corpus, with every `mtc` invocation run under the §9 safety limits.

- **P0 — Foundation + boundaries.** `projects/mtc` package; `Session` (interner, type registry,
  diagnostics, pools); `Span`/handle types. Ruby-side: add `--json` emitters and `--from-<stage>`
  ingesters at each boundary (§4) at `spec/v1`. `mtc-diff` harness with the §9 safety limits, JSON
  canonicalization, and SHA-pinned oracle (§3).
  *Verify:* harness round-trips a trivial fixture through every Ruby resume point under limits.
- **P1 — Lexer (full).** Full token set, indentation (indent/dedent), line-continuation,
  string/heredoc/format/char literals, trivia capture for CST.
  *Verify:* token-stream parity over the whole corpus.
- **P2 — Parser + AST (full grammar).** Full declaration/statement/expression grammar,
  Pratt precedence, error recovery. (P1 trivia is retained for a later CST; no formatter/LSP yet
  — see §5.6.)
  *Verify:* AST parity (+ recovery fixtures) over the corpus.
- **P3 — Types + Registry + Binder.** `TypeId` interning; name resolution and scopes;
  type expression resolution.
  *Verify:* resolved-type snapshots vs oracle.
- **P4 — Checker (full sema).** Expression/statement/call checking; CFG dataflow
  (definite-assignment, nullability flow, reachability, termination); const-eval; generics
  monomorphization; interface conformance; attributes/reflection.
  *Verify:* `Analysis` snapshots + full diagnostic parity (positive and negative fixtures).
- **P5 — Lowering + IR (full).** AST+Analysis → flat IR; async normalization; events; procs;
  loops; format strings; foreign/cstr boundaries.
  *Verify:* IR parity over the corpus.
- **P6 — C backend (full).** Feature-gated runtime helpers, aggregate topological sorting,
  checked/nullable index helpers, reinterpret, string literals, function bodies.
  *Verify:* normalized-C parity + behavioral parity over the corpus.
- **P7 — Driver / module graph / CLI parity.** Import resolution, platform variants, prelude,
  module-graph topo levels, content-hash cache; `mtc check/build/run/lower/emit-c/lex/parse`.
  *Verify:* end-to-end build+run parity on multi-module programs.
- **P8 — Self-hosting fixpoint.** Build `mtc` with `mtc`; assert stage1 ≡ stage2 (§7).
  *Verify:* reproducible C fixpoint in CI.
- **P9 — Dogfood & performance.** Run `mtc` as a real program; profile pools/interners;
  tune module-graph parallelism. (No query engine; keep it module-granular.)
- **P10 — Tooling (post-fixpoint).** CST struct + formatter + LSP, built on the P1 trivia; off the
  compile/fixpoint critical path (§5.6).

---

## 11. Risks & Mitigations

- **Whole-language port is large; the fixpoint is late (M5).** Mitigated by the JSON handoff (§7):
  each completed stage ships as a runnable milestone (M1–M5) that compiles the whole corpus via
  Ruby's back-half, so value is continuous and every stage is independently verified (§9) long
  before self-hosting.
- **Spec drift during the port.** Mitigated by the `spec/v1` freeze (§3); the oracle and corpus
  only move on an intentional version bump.
- **Reflection / attributes / compile-time surface is intricate.** Highest-risk slice of P4;
  budget a spike to validate `TypeId`-based reflection handles before committing the design.
- **Cosmetic C differences inflate diff noise.** Mitigated by explicit normalization in
  `mtc-diff` (§9), with behavioral parity as the tiebreaker.

---

## 12. Resolved Design Decisions

The review questions are resolved as follows, grounded in the Ruby compiler's actual behavior:

1. **C-diff normalization (was Q1).** Resolved in §9: emit with `#line` off, canonical-renumber
   `__mt_*` and `mt_str_lit_*` names, sort includes, compare top-level decls as a keyed multiset,
   with behavioral parity as the tiebreaker.
2. **`Analysis` serialization (was Q2).** Two distinct concerns: (a) *incremental caching* — none
   on disk in v1 (mirror `build_cache.rb`: C + artifacts by content hash only); (b) *boundary
   serialization* — JSON IR at each phase boundary is a **core mechanism** for the handoff and
   oracle (§4, §7), built per stage. The post-sema boundary serializes the *annotated AST* (the
   subset lowering reads), not the full `Analysis` graph.
3. **CST timing (was Q3).** Resolved in §5.6 and §10: trivia capture lands in P1; the CST struct
   plus its formatter/LSP consumers are deferred to the P10 tooling phase. The compile pipeline
   never depends on the CST.
4. **Spec-freeze mechanics (was Q4).** Resolved in §3: a git tag (`spec/v1`) pins spec + compiler
   + corpus in-repo; the harness runs the oracle from a SHA-pinned `git worktree`. No vendoring.
5. **Integration model (new).** The bootstrap is a **progressive front-to-back JSON-IR handoff**
   (§7): each stage is completed to 100% coverage, emits JSON IR, and Ruby finishes compilation;
   the Ruby back-half shrinks each milestone until `mtc` owns codegen (M5), after which the
   self-hosting fixpoint applies.
6. **Testing safeguards (new).** Because the compiler under test is a C binary, every `mtc` harness
   invocation runs under a wall-clock timeout and an address-space cap, with an ASan/UBSan build
   matrix (§9). Timeouts/OOMs are classified failures, not flakes.

### Remaining (lower-stakes, settle empirically)

- Exact keying of top-level C units for set comparison (linkage name vs full signature) — tune
  when P6 lands by measuring false positives/negatives on the corpus.
- Whether canonical temp renumbering is per-function or per-translation-unit — decide during P6;
  per-function is the likely default since `__mt_*` names are function-local.
