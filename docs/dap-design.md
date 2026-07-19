# Self-Host DAP Architecture

Status: **Phase 1 implementation — functional process backend (25 handlers).**
Last updated: 2026-07-19.
7 modules, ~1,050 lines, 25 of 25 DAP handlers dispatched with 15 full
implementations.
Phase 2 (lldb-dap bridge) assessed as not feasible without multi-threaded I/O.

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
  lsp/              ← existing (35 modules)
  dap/              ← new (7 modules, ~1,050 lines)
    protocol.mt     ← DAP Content-Length framing, read/write
    server.mt       ← message loop, child I/O polling, exit detection
    session.mt      ← launch state, breakpoints, config tracking
    handlers.mt     ← 25-command dispatch, 15 handlers + 8 error + 2 no-op
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
| Lines | ~2,800 (10 files) | ~1,050 (7 modules) |
| Threads | Multi-threaded (reader + runtime + lldb bridge) | Single-threaded |
| Dispatch | 7 mixin modules | if/else chain |
| JSON | `JSON.parse` / `JSON.dump` | `std.json.parse` / raw-string rendering |
| Transport | Stdio Content-Length | Same (`read_char()` loop) |
| Backends | "process" + "lldb-dap" | "process" only |
| Handlers | 25 of 25 | 25 dispatched (15 full + 8 errors + 2 no-ops) |
| Child process | Background thread `Open3.popen3` | Non-blocking `read_stdout(0)` polling |
| Breakpoints | Verified via lldb-dap | Unverified (registered only) |
| Variable inspection | Via lldb-dap | Empty / unsupported |
| Signal control | `Process.kill("STOP"/"CONT")` | `child.kill(SIGSTOP/SIGCONT)` |

---

## 9. Phase 2 — lldb-dap Bridge (Assessed — Not Feasible)

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

Until one of these is available, the lldb-dap bridge is architecturally
incompatible with the self-host's I/O model.  The process backend covers the
core DAP use case (run, view output, terminate).
