# Self-Host DAP Architecture

Status: **Phase 1 implementation — functional process backend (26 commands),
audited against the host per request (§10).**  Phase 2 (lldb-dap bridge) is
**feasible and unstarted** (§9): `std/libuv.mt` exposes `uv_poll_*` and
`std/async` a libuv runtime, so one event loop can multiplex stdin and the
adapter's stdout.  The VS Code extension's default backend is `lldb-dap`, which
is why stepping/evaluate/attach currently answer with the process backend's
errors.
Last updated: 2026-09-27 (§10 audit; §9 feasibility re-assessed).
7 modules, 1,051 lines, 26 commands dispatched (15 implemented, 9 error
stubs, 2 no-ops)
implementations.
Phase 2 (lldb-dap bridge) was assessed as not feasible without multi-threaded
I/O; that assessment is superseded by §9 (libuv poll is available).

## 0. Design Principles

1. **Single-binary delivery.** The DAP is a subcommand (`mtc dap`), not a
   separate executable.  It lives in `projects/mtc/` and bootstraps through the
   existing 3-stage pipeline.

2. **Single-threaded message loop.** The compiler's analysis pipeline is
   single-threaded.  The DAP follows the same pattern as the LSP: one
   synchronous `read → dispatch → respond` loop.  Child process I/O is
   polled between message dispatches (non-blocking reads with short timeouts).

3. **Separate-module architecture.** Following the LSP's successful pattern,
   each DAP concern lives in its own module.  No single file exceeds ~200 lines.

4. **Process backend only (Phase 1).** The "process" backend builds and runs
   Milk Tea programs directly via `std.process.spawn`.  Breakpoints are
   registered but unverified (no debugger attached).  This provides the core
   DAP experience — run, pause, continue, view output, terminate — without
   requiring the lldb-dap subprocess bridge.

5. **Source-only.** All DAP code is source-only `.mt` files.  No new vendored
   libraries beyond what already ships with the compiler.

---

## 1. Entry Point — `mtc dap`

```
mtc dap [--stdio]
```

The `dap` subcommand starts a DAP server over stdio.  It reads DAP messages
from stdin, dispatches to registered handlers, and writes responses and
events to stdout.  Stderr is reserved for logging.

```mt
if cmd == "dap":
    return dap.run(args)
```

---

## 2. Module Structure

```
projects/mtc/src/mtc/
  lsp/              ← existing (37 modules)
  dap/              ← new (7 modules, 1,051 lines)
    protocol.mt     ← DAP Content-Length framing, read/write
    server.mt       ← message loop, child I/O polling, exit detection
    session.mt      ← launch state, breakpoints, config tracking
    handlers.mt     ← 26-command dispatch: 15 implemented, 9 error stubs,
                       2 no-ops (loadedSources/cancel); the audit adds the rest
    process_backend.mt ← child process I/O polling + output events
    wire.mt         ← write_response, write_event, write_error
    utilities.mt    ← path resolution, helper functions
```

### 2.1 Module dependencies

```
  main.mt
    └── dap/server.mt
        ├── dap/protocol.mt          (stdio + JSON)
        ├── dap/session.mt           (state + breakpoints)
        ├── dap/handlers.mt          (request dispatch)
        │   └── dap/process_backend.mt (child process I/O)
        │   └── dap/utilities.mt       (path resolution)
        └── dap/wire.mt              (response/event writing)
```

No circular imports.  Each DAP module depends only on the compiler's existing
public APIs and `std.*` libraries.

---

## 3. DAP Protocol Differences from LSP

| Aspect | LSP | DAP |
|--------|-----|-----|
| Message type field | `"method"` string | `"command"` string |
| Sequence numbers | No `seq` | Every message has `seq` |
| Request matching | By `id` | By `request_seq` |
| Events | `textDocument/publishDiagnostics` etc. | `initialized`, `stopped`, `output`, `terminated`, `exited` |
| Response envelope | `{jsonrpc, id, result}` | `{seq, type:"response", request_seq, success, command, body}` |
| Framing | Content-Length \r\n\r\n | Content-Length \r\n\r\n (same) |
| Error format | `{code, message}` | `{success:false, message}` |

---

## 4. Session Lifecycle

```
Client                Server
  │                      │
  ├─ initialize ────────►│  returns capabilities
  │◄─── initialized event─┤
  │                      │
  ├─ launch ────────────►│  builds .mt → binary, spawns process
  │                      │
  ├─ setBreakpoints ────►│  registers breakpoints
  │                      │
  ├─ configurationDone ─►│  stop on entry or continue
  │◄─── stopped(event) ───┤  (if stopOnEntry)
  │                      │
  ├─ continue ──────────►│  SIGCONT if paused
  │                      │
  ├─ ... I/O ... ◄───────┤  output events (stdout/stderr)
  │                      │
  │◄─── terminated(event)─┤  process exit
  │◄─── exited(event) ───┤  exit code
  │                      │
  ├─ disconnect ────────►│  cleanup, exit server
```

---

## 5. Handler Surface (Phase 1 — Process Backend)

| Handler | Implementation |
|---------|---------------|
| `initialize` | Returns ADAPTER_CAPABILITIES, sends `initialized` event |
| `launch` | Resolves program path, spawns child via `std.process.spawn` |
| `attach` | Error response ("attach requires lldb-dap backend") |
| `setBreakpoints` | Registers in session, marks unverified for process backend |
| `setFunctionBreakpoints` | Registers in session |
| `setExceptionBreakpoints` | Registers in session |
| `configurationDone` | Marks config done, stops on entry or continues |
| `threads` | Returns `[{id:1, name:"main"}]` |
| `stackTrace` | Returns single entry frame `[{id:1, name:"main", ...}]` |
| `scopes` | Returns `[{name:"Locals", variablesReference:1}]` |
| `variables` | Returns empty array for process backend |
| `continue` | SIGCONT + `continued` event |
| `next` | Error response |
| `stepIn` | Error response |
| `stepOut` | Error response |
| `pause` | SIGSTOP + `stopped` event |
| `terminate` | SIGTERM + `terminated` + `exited` events |
| `disconnect` | Cleanup + exit server |
| `evaluate` | Error response |
| `source` | Reads file from disk, returns content |
| `loadedSources` | Returns `{sources:[]}` |
| `cancel` | No-op (single-threaded) |
| `restart` | Error response |
| `setVariable` | Error response |
| `setExpression` | Error response |

**15 full implementations, 8 error responses, 2 no-ops.**

---

## 6. Child Process I/O — `process_backend.mt`

The self-host's `std.process` module provides non-blocking child I/O:

```
std.process.spawn(command)          → ChildProcess{stdin_fd, stdout_fd, stderr_fd, pid}
child.read_stdout(timeout_ms)      → ReadResult{ready, closed, data}
child.read_stderr(timeout_ms)      → ReadResult
child.write_stdin(data)            → write to child
child.kill(signal)                 → SIGSTOP(19) / SIGCONT(18) / SIGTERM(15)
child.wait()                       → ExitStatus
```

The main server loop does:

```
while running:
    msg = protocol.read_message()     # blocks on stdin
    if msg:
        dispatch(msg)
    poll_process_output(process)      # non-blocking (timeout=0)
    if process_exited:
        running = false
```

---

## 7. Bootstrapping Impact

The DAP code lives in `projects/mtc/src/mtc/dap/` and is compiled as part
of the existing `projects/mtc` package.  No changes to `tools/bootstrap.sh`.

---

## 8. Comparison: Ruby DAP vs Self-Host DAP (Phase 1)

| Aspect | Ruby DAP | Self-Host DAP (Phase 1) |
|--------|----------|--------------------------|
| Lines | ~2,169 (12 files) | 1,051 (7 modules) |
| Threads | Multi-threaded (reader + runtime + lldb bridge) | Single-threaded |
| Dispatch | 7 mixin modules | if/else chain |
| JSON | `JSON.parse` / `JSON.dump` | `std.json.parse` / raw-string rendering |
| Transport | Stdio Content-Length | Same (`read_char()` loop) |
| Backends | "process" + "lldb-dap" | "process" only |
| Handlers | 29 methods | 29 dispatched |
| Child process | Background thread `Open3.popen3` | Non-blocking `read_stdout(0)` polling |
| Breakpoints | Verified via lldb-dap | Unverified (registered only) |
| Variable inspection | Via lldb-dap | Empty / unsupported |
| Signal control | `Process.kill("STOP"/"CONT")` | `child.kill(SIGSTOP/SIGCONT)` |
| Adapter capabilities | Merged with lldb-dap's | Static list (identical set for the process backend) |

---

## 9. Phase 2 — lldb-dap Bridge (Re-assessed: feasible)

The lldb-dap backend requires three concurrent I/O operations:
1. Reading client stdin (blocking `read_char()`)
2. Reading lldb-dap stdout responses
3. Reading lldb-dap stdout events (asynchronous)

The Ruby DAP solves this with 3 background threads + Mutex/Queue for
request/response matching.  In the self-host's single-threaded `read_char()`
model, stdin is blocking — while waiting for client input, lldb-dap events
cannot be polled.  While spin-reading lldb-dap responses, client messages
cannot be received.

Two paths would make this feasible:
1. Add async/non-blocking `read_char()` support to `std.stdio` (a stdlib change)
2. Refactor the server loop to use `select`/`poll` on multiple file descriptors
   (requires OS-level syscall bindings not yet available in Milk Tea)

**Update (2026-09-27): both paths now exist.**  `std/libuv.mt` exposes
`uv_poll_init` / `uv_poll_start` / `uv_poll_stop`, and `std/async` ships a libuv
runtime (`runtime_create` / `runtime_poll` / `with_runtime`), so a single
event loop can watch stdin and lldb-dap's stdout at once; `std/process` also has
`read_stdout(timeout_ms)` for timed polling of a spawned child.  The bridge is
therefore implementable without threads: run libuv, poll stdin and the adapter's
stdout on one loop, keep a `pending` map from adapter request seq to client
request, forward adapter events as-is, and answer `initialize` with the merged
capabilities (the host's `lldb_dap_backend.rb` is the 152-line reference).

What the VS Code extension expects: its `backend` setting **defaults to
`lldb-dap`** for both launch and attach, so until this lands the adapter should
say so (it now warns instead of silently running the process backend).

---

## 10. DAP gap audit (2026-09-27)

`tools/dap_smoke.rb` drives both adapters through one session and prints what
each answers; run it after any DAP change (`ruby tools/dap_smoke.rb`,
`--server host|self`, `--json OUT`).

Identical for the process backend (measured): `initialize` (same capability
set), `launch(binary)`, `threads`, `stackTrace` (1 frame), `scopes` (1),
`variables` (0), `setBreakpoints`, `loadedSources`, `cancel`, `disconnect`, and
the same error text for `next` / `stepIn` / `stepOut` / `evaluate` /
`setVariable` / `attach` / `restart` / `dataBreakpointInfo` / `setExpression`.
The event stream matches except that the self emits `exited` before
`terminated` as well (`initialized, process, output, exited, terminated` vs the
host's `initialized, process, output, terminated`) — the extra event is what the
DAP specification expects, so it is kept.

Fixed on 2026-09-27 (found by this audit):

- **Malformed `exited` body.**  `wire.write_event(..., f"{{"exitCode":#{code}}}")`
  emitted `"body":{{"exitCode":0}}`: `{{` is not an f-string escape in Milk Tea
  (both compilers treat it as two literal braces), so every client failed to
  parse that frame.  The body is now built explicitly.
- **No `process` event.**  The host announces the launched process
  (`launch.rb:75`); the adapter now does too.
- **`dataBreakpointInfo` / `setExpression` were not dispatched** ("unsupported
  command"); they now answer the same error text as the host.
- **`--backend` was ignored.**  A requested `lldb-dap` silently ran the process
  backend; it now logs why stepping is unavailable.

Remaining gaps, in the order they affect the VS Code experience:

| # | Gap | Evidence / approach |
| --- | --- | --- |
| 1 | **`launch` on a `.mt` source does not build it** — **landed** (session 34, 2026-10-04) | `utilities.resolve_launch_program` now compiles a `.mt` source with the running compiler (`/proc/self/exe build <abs.mt> -o <tmp>/<stem> --profile debug --no-debug-guards`, the host's `debug: true, debug_guards: false`), in a fresh `milk-tea-dap-*` temp directory remembered by the session and removed on terminate/disconnect; a failed build moves the error into the launch error response (and removes the temp dir). The binary cache carries the sidecar (`build_cache.store`/`materialize` copy `<binary>.mtdbg.json` as `debug-map.json`), so a `[cached]` build still gets its map — the host skips the map on program-cache hits. Also fixed while here: the `process` event's `name` was never appended (empty). `dap_smoke`'s `launch(.mt)` rows are now equal on both servers |
| 2 | **No lldb-dap backend** (the extension's default) | stepping, evaluate, setVariable, attach, restart, breakpoint verification, real variables and pause diagnostics all live behind the host's `lldb_dap_backend.rb`.  Approach: §9 above (libuv poll loop + pending map + event forwarding + merged capabilities) |
| 3 | **No debug map** — **emission landed** (session 34, 2026-10-04) | `projects/mtc/src/mtc/debug_map.mt` ports the host's writer/loader (`version / functions[] (name, cName, params, locals, sourcePath, line) / binaryPath / programSourcePath`, paths relative to the sidecar; `line: 0` is treated as synthetic and omitted like the host), `build.mt` writes `<output>.mtdbg.json` on the success branch, and `debug_map_test.mt` locks the model + round trip. The sidecar is byte-comparable to the host's on the smoke fixture (verified semantically equal). The DAP-side frame/variable/expression rewrites land with #2 |
| 4 | **Pause diagnostics / `modules`-driven map loading** | the host prints a short stack summary on pause (`pause_diagnostics.rb`) and can load a map from the backend's `modules` response; both are lldb-dap-era features (they land with #2) |

Verification for #1..#3: `ruby tools/dap_smoke.rb` must show `launch(.mt)` ok for
both servers, and a real VS Code session (`bindings/vscode`, `backend:
lldb-dap`) must stop on a breakpoint and show locals — the same end-to-end check
`docs/lsp-design.md` requires for user-visible LSP changes.
