# Agent Instructions

## Quality of Information

- Be direct and honest in a professional tone. Avoid pleasantries, emotional cushioning, or unnecessary acknowledgments. Correct me in the next response if I'm wrong, and explain why. Point out better alternatives for inefficient or flawed ideas. Get straight to the point without being rude. Never apologize for corrections. Prioritize accuracy and efficiency over agreeableness. Challenge wrong assumptions. Focus on information quality, factual accuracy, and directness. Adopt a skeptical, questioning approach. Ask questions and confirm intent if instructions or context are not clear.

## Coding Instructions

Prioritize these instructions in this order: accuracy first, then minimal correct changes, then tone and workflow preferences.

### 0. Ruby Coding Conventions

- Do not use `module_function`. Prefer `self.` for class/module method definitions. Everything is public. No `private`/`public` scope.
- Do not use `.send()`. Call methods directly.
- Do not define private methods. Everything is public by default.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior/principal engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## Workspace Instructions

- Read `README.md` first; it is the primary implementation-focused language reference and preferred project entry point.
- You are a programming language compiler design expert.
- We never care about backward compatibilities, all changes and updates should be final, legacy codepath should be removed to avoid maintenance hurdles.
- Ensure the code you change is accurate, clean, high-quality, and well-tested.
- NEVER use hacks, workarounds, temporary solutions to bypass issues. Either explore the core problems and fix them correctly or stop working and confirm with me for clarification. If there is any obvious bugs, fix them, do not try to find ways around the bug.
- The host OS is Arch Linux (Manjaro) and use `pacman` as package manager. Sudo password is stored in the `.env` file.
- Use `gdb`, `strace`, `valgrind` or `lldb` to debug compiled binary files when necessary.

## Self-Host Parity Program

The Ruby host in `lib/` (`ruby -Ilib bin/mtc`) is the reference implementation; `projects/mtc` is the
self-hosted compiler, and matching the host everywhere is the program's goal.

- **Rebuild before measuring**: `ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/stage2/mtc`.
  A stale `build/stage2/mtc` is the classic false result.
- **Gates are tiered — iterate cheap, prove once.**  `tools/gates.sh` picks the set from
  `git diff --name-only` (or `--areas`), prints it, and `--run` executes it in order
  (each gate logs to `tmp/gates/<id>.log`; hard gates stop the run, meters continue).
  - **Tier 1 — per edit / per workstream (minutes)**: rebuild the dev compiler
    (`ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev`, ~105 s), run
    `tmp/mtc-dev test projects/mtc -I . --timeout 120`, and measure **only the class you
    touched** — a focused `ruby tools/lint_parity.rb -q <paths>`, one file's host-vs-self
    lint diff, `tmp/diag_probe.rb`, `ruby tools/sexpr_parity.rb lex|parse -q
    --host-cache tmp/sexpr-host-cache` (the cache reuses the host's outputs per
    file / resolved import-closure digest; the self always runs live).
    Do not run the corpus-wide sweep or the audit as the iteration loop.
  - **Tier 2 — once per commit, on frozen sources, backgrounded**:
    `tools/bootstrap.sh -j 16` (fixed point + 22 files / 0 failed self-tests) and
    `build/stage2/mtc test test/mt -I .` (61/0) are the hard proofs; then the area
    sweeps — linter: `rake parity:scoreboard`, `ruby tools/lint_parity.rb -q`
    (658 files; read its summary, it is not expected to reach 0 yet),
    `ruby tools/unused_import_parity.rb` (635/635), `ruby tools/cli_parity.rb`
    (227 match / 0 differ / 0 pending); LSP: `tools/lsp_parity.rb
    record|compare` (30/30 + the 2 documented request rows and 3 stress rows),
    `tools/lsp_recovery_probe.rb --check`, `tools/lsp_project_audit.rb --workspace DIR`
    (drift ±10 — compare differing *sets*), valgrind on an LSP drive + the Neovim smoke;
    lowering/C backend: `ruby tools/sexpr_parity.rb lower -q -j 4 --mem-mb 8000
    --host-cache tmp/sexpr-host-cache` (~1 min warm vs ~4 min cold; the self
    side is measured live; memory-capped because each compiler-sized closure
    peaks 3.4–3.8 GiB and the seven `main*` artifacts together exhausted a
    31 GiB workstation at `-j 16`) plus the example
    sweeps (`examples/*.mt` 15/15, `examples/sdl3` 34/34, a raylib sample).
  - **Do not replay a baseline a previous session verified at the same commit.**  The
    ledger records the last verified numbers per commit; a new session re-measures only
    the classes its task can move (or nothing, if the tree is unchanged).  Re-measure
    when the tree moved or a number is surprising.
- **Never edit sources while a gate runs**: `bootstrap.sh` compiles the working tree, so an edit
  mid-run silently corrupts the result — check the exit status, not just the tail.
- **Refactoring the self-host (session 75)**: behavior and structure are guarded separately.
  Run `tools/gates.sh --areas refactor --run` (dev build, dev tests, structural guard,
  `test/mt`, CLI parity, scoreboard) and read `docs/refactoring.md`.
  `ruby tools/refactor_guard.rb --check` is the fast invariant check (layering, naming,
  markers); `--check --strict --ratchet` adds new dead exports and code/duplication growth
  against `tools/refactor_baseline.json`.  Refresh the baseline only with a reviewed
  structural change, never to silence a check.
- **Live state**: `docs/self-host-plan.md` is the single source of truth — the session protocol,
  the ranked program, the ledger, and the §0j/§0k session records.  Sync it in the same commit as
  the code change.  Session plans under `~/.commandcode/plans/` are transient working notes,
  never the record.
- `tools/lsp_project_audit.rb --workspace DIR` diffs every LSP request against the host live; its
  per-method counters drift ±10 between runs (the host warms its caches as the audit proceeds), so
  compare *sets of differing keys* when verifying a fix. Fast fixtures: `tmp/probe-ws`, `tmp/probe2`,
  `tmp/probe4` (container statics), `tmp/probe5` (cross-file definition), `tmp/probe6` (member field).

## C Binary Testing Safety

`mtc` built C binary is generated, compiled C code. It can contain memory and concurrency bugs — segfault, double-free, use-after-free, infinite loop/hang, runaway memory, and (once threading lands) data races. ALWAYS run it sandboxed when testing:

- Wrap every invocation with a timeout AND a virtual-memory cap, e.g.:
  `timeout 10 bash -c 'ulimit -v 20000000; <mtc-binary> <args>'`
- Interpret abnormal exits as bugs to investigate, not test noise: `124` = timed out (hang), `137` = SIGKILL/OOM, `139` = SIGSEGV, `134` = SIGABRT/double-free.
- Never loop the binary over many inputs without a per-invocation timeout.
- When a crash/hang is found, debug it with `valgrind` / `gdb` (and `--keep-c` to inspect the generated C).

### Build Cache and Guard Flags

The build cache persists compiled C and binaries across invocations. When iterating on the Ruby compiler or the generated C backend, the cache may serve stale output. Use these flags to avoid false results:

- **`--no-cache`** — always rebuild from source; use when you change `CBackend`, `Lowering`, or any compiler pipeline code. Without it, `[cached]` builds may reuse a previous C/binary that does not reflect your latest changes.
- **`--keep-c`** — save the generated C file to disk for inspection. Combine with `--no-cache` to ensure the saved C matches the actually compiled binary.

**Loop iteration guards**: the CBackend unconditionally injects a per-`while`/`for` counter (`__mt_loop_N`) that calls `mt_fatal` after 50,000,000 iterations. The counter is local to the enclosing function (resets per call). This catches infinite loops in synchronous code; long-running CPS-async resume loops may legitimately reach the limit, which is a pre-existing pattern in `std/net/discovery.mt` (not a compiler bug).

## Tool Usage

- **Reasoner Tool**: Use the Reasoner tool and perform multiple passes when reasoning, planning, or researching, or for tasks that benefit from a step‑by‑step approach.
- **Context7 Tool**: Consult the Context7 tool to stay up‑to‑date with the latest using library features, API recommendations, and best practices.
