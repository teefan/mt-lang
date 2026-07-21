# Agent Instructions

## Quality of Information

- Be direct and honest in a professional tone. Avoid pleasantries, emotional cushioning, or unnecessary acknowledgments. Correct me in the next response if I'm wrong, and explain why. Point out better alternatives for inefficient or flawed ideas. Get straight to the point without being rude. Never apologize for corrections. Prioritize accuracy and efficiency over agreeableness. Challenge wrong assumptions. Focus on information quality, factual accuracy, and directness. Adopt a skeptical, questioning approach. Ask questions and confirm intent if instructions or context are not clear.

## Coding Instructions

Prioritize these instructions in this order: accuracy first, then minimal correct changes, then tone and workflow preferences.

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

**Loop iteration guards** (Ruby compiler only — the self-host does not inject guards): the Ruby CBackend unconditionally injects a per-`while`/`for` counter (`__mt_loop_N`) that calls `mt_fatal` after 50,000,000 iterations. The counter is local to the enclosing function (resets per call). This catches infinite loops in synchronous code; long-running CPS-async resume loops may legitimately reach the limit, which is a pre-existing pattern in `std/net/discovery.mt` (not a compiler bug).

## Tool Usage

- **Reasoner Tool**: Use the Reasoner tool and perform multiple passes when reasoning, planning, or researching, or for tasks that benefit from a step‑by‑step approach.
- **Context7 Tool**: Consult the Context7 tool to stay up‑to‑date with the latest using library features, API recommendations, and best practices.
- **Codebase Memory MCP Tool**: This project is indexed in the codebase-memory-mcp knowledge graph (project `home-teefan-Projects-Ruby-mt-lang`). Prefer MCP graph tools over the `explore` subagent, grep/glob, and file-search for code discovery — they are faster, deduplicated, and structural.

### Codebase Memory Tool Usage

**Priority order**: `search_graph` → `trace_path` → `get_code_snippet` → `query_graph` → `get_architecture`

| Question | Tool call |
|----------|----------|
| Who calls X? | `trace_path(direction="inbound")` |
| What does X call? | `trace_path(direction="outbound")` |
| Full call context | `trace_path(direction="both")` |
| Find by name pattern | `search_graph(name_pattern="...")` |
| Dead code | `search_graph(max_degree=0, exclude_entry_points=true)` |
| Cross-service edges | `query_graph` with Cypher |
| Impact of local changes | `detect_changes()` |
| Risk-classified trace | `trace_path(risk_labels=true)` |
| Text search | `search_code` or Grep |

**Exploration workflow**:
1. `list_projects` — check if project is indexed
2. `get_graph_schema` — understand node/edge types
3. `search_graph(label="Function", name_pattern=".*Pattern.*")` — find code
4. `get_code_snippet(qualified_name="project.path.FuncName")` — read source

**Tracing workflow**:
1. `search_graph(name_pattern=".*FuncName.*")` — discover exact name
2. `trace_path(function_name="FuncName", direction="both", depth=3)` — trace
3. `detect_changes()` — map git diff to affected symbols

**Quality analysis**:
- Dead code: `search_graph(max_degree=0, exclude_entry_points=true)`
- High fan-out: `search_graph(min_degree=10, relationship="CALLS", direction="outbound")`
- High fan-in: `search_graph(min_degree=10, relationship="CALLS", direction="inbound")`

**All 14 MCP tools**: `index_repository`, `index_status`, `list_projects`, `delete_project`, `search_graph`, `search_code`, `trace_path`, `detect_changes`, `query_graph`, `get_graph_schema`, `get_code_snippet`, `get_architecture`, `manage_adr`, `ingest_traces`

**Gotchas**:
1. `search_graph(relationship="HTTP_CALLS")` filters nodes by degree — use `query_graph` with Cypher to see actual edges.
2. `query_graph` has a 200-row cap — use `search_graph` with degree filters for counting.
3. `trace_path` needs exact names — use `search_graph(name_pattern=...)` first.
4. `direction="outbound"` misses cross-service callers — use `direction="both"`.
5. Results default to 10 per page — check `has_more` and use `offset`.
