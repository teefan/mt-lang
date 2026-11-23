# Self-Host DAP Architecture

Status: **complete against the host.**  The process backend and the lldb-dap
bridge (the VS Code extension's default) are implemented and audited per
request: `tools/dap_smoke.rb` reports **zero differing rows** across the
process sessions and the lldb sessions (the embedded fake adapter and a real
`/usr/bin/lldb-dap`), with one documented self-better row — the debug-map frame
name maps on the self where the host loses its map on a program-cache hit.
The VS Code F5 launch ordering was fixed in session 71 (see §9/§10); a real
async-order probe proves launch → breakpoint → frame/locals → evaluate.  The
extension's argv order is fixed (`dap` first, then `--backend`/`--adapter-path`).
Last updated: 2026-11-13 (session 71 — the configurationDone/launch ordering fix).
9 modules, ~4,540 lines plus the shared `mtc/debug_map.mt` (829) — 26 commands
dispatched.

## 0. Design Principles

1. **Single-binary delivery.** The DAP is a subcommand (`mtc dap`), not a
   separate executable.  It lives in `projects/mtc/` and bootstraps through the
   existing 3-stage pipeline.

2. **One single-threaded event loop.**  A libuv loop multiplexes the client's
   fd 0, the debuggee's stdout/stderr and the adapter's stdout (poll handles)
   plus a 100 ms wake-up timer; poll callbacks only append bytes to framers,
   and requests are dispatched and children drained between loop turns.  There
   are no threads beyond the ones `std.process` starts for children.

3. **Separate-module architecture.** Following the LSP's pattern, each DAP
   concern lives in its own module.  The bridge policy (`lldb_policy.mt`,
   ~2.3k lines) is the one large module — its state machine threads a single
   `Backend` state through the handshake, and splitting it would mean moving
   shared context through more types.

4. **Two backends.** The "process" backend builds and runs Milk Tea programs
   directly via `std.process` (breakpoints registered but unverified); the
   "lldb-dap" backend drives the adapter as a child process, forwarding the
   command surface and rewriting frames/variables through the debug map.

5. **Source-only.** All DAP code is source-only `.mt` files.  No new vendored
   libraries beyond what already ships with the compiler.

---

## 1. Entry Point — `mtc dap`

```
mtc dap [--stdio] [--backend process|lldb-dap] [--adapter-path PATH]
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
  lsp/                ← existing (42 modules)
  debug_map.mt        ← the host-compatible <binary>.mtdbg.json writer/loader
  dap/                ← 9 modules, ~4,540 lines
    protocol.mt       ← Content-Length framer over raw fd reads + writer
    server.mt         ← the libuv loop, poll handles, dispatch draining
    session.mt        ← launch state, breakpoints, debug-map context, temp dirs
    handlers.mt       ← 26-command dispatch (process branches + lldb routing)
    process_backend.mt ← child process I/O polling + output events
    wire.mt           ← write_response, write_event, write_error (+command forms)
    utilities.mt      ← launch resolution (build-on-launch) + helpers
    lldb_backend.mt   ← adapter transport: spawn, framing, pending tables
    lldb_policy.mt    ← bridge policy: handshake, events, rewrites, sync
```

### 2.1 Module dependencies

```
  main.mt
    └── dap/server.mt
        ├── dap/protocol.mt          (fd framer + JSON)
        ├── dap/session.mt           (state + breakpoints + debug map)
        ├── dap/handlers.mt          (request dispatch)
        │   ├── dap/process_backend.mt (child process I/O)
        │   ├── dap/utilities.mt       (launch resolution)
        │   └── dap/lldb_policy.mt     (bridge policy)
        │       └── dap/lldb_backend.mt (adapter transport)
        │           └── dap/protocol.mt
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

## 5. Handler Surface (Process Backend Behavior)

With `lldb-dap` active every command below forwards to the adapter instead
(§9) — the table describes what the process backend does, which is also the
behavior the smoke compares for the `--backend=process` session.

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

**15 full implementations, 8 error responses, 2 no-ops** (all of them equal to
the host's process-backend answers on `dap_smoke`).

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

## 8. Comparison: Ruby DAP vs Self-Host DAP

| Aspect | Ruby DAP | Self-Host DAP |
|--------|----------|---------------|
| Lines | ~2,170 (12 files + tooling/debug_map) | ~5,370 (9 `dap/` modules + `mtc/debug_map.mt`) |
| Threads | Multi-threaded (reader + runtime + adapter bridge) | One libuv loop (poll handles + 100 ms timer) |
| Dispatch | 7 mixin modules | if/else chain (`dispatchers`, `dispatch_lldb`) |
| JSON | `JSON.parse` / `JSON.dump` | `std.json.parse` / rendering |
| Transport | Stdio Content-Length | Same, over raw fd reads (`std.process.read_fd`) |
| Backends | "process" + "lldb-dap" | "process" + "lldb-dap" |
| Child process | Background thread `Open3.popen3` | `std.process` pipes, drained between loop turns |
| Breakpoints | Verified via lldb-dap, synced at configurationDone (+ changed events) | Same |
| Variable inspection | debug-map renames via lldb-dap | Same (token-scanner expression rewriting) |
| Reverse requests | `runInTerminal` etc. with a 15 s client timeout | Same, answered through the client-response table |
| Deliberate difference | — | the binary cache carries the debug-map sidecar, so frame names still map on cached builds (the host skips the map on a program-cache hit; smoke row `lldb-real frame0 name`: self `add`, host `main_add`) |

---

## 9. The lldb-dap Bridge (landed)

The original feasibility question (three concurrent I/O streams without
threads) is answered by the libuv loop: `server.mt` polls fd 0 and the
adapter's stdout (`uv_poll_init/start`, `std/libuv.mt`), with a 100 ms timer
for deadlines and child draining.  `lldb_backend.mt` owns the transport — the
adapter child, its stdin framing, the adapter→client pending table (5 s) and
the client→adapter reverse table (15 s) — and `lldb_policy.mt` owns the
policy: deferred client `initialize` with merged capabilities, suppressed
adapter `initialized`, launch/attach forwarding, `configurationDone` gated on
the adapter's `initialized` event / the start request answering (the host's
`backend_configuration_pending?`, released when either arrives), breakpoint
sync with the host's `breakpoint changed` events, event rewriting (SIGSTOP →
pause, continued dedup), the debug-map frame/variable/expression rewriters and
pause diagnostics.  `--adapter-path` is honored (`.rb` under ruby), and the
extension's default `lldb-dap` needs no configuration.

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

**Landed (session 34, 2026-10-04): the unified event loop + start on
`configurationDone`.**  The blocking stdio reader became a byte-buffered
`Framer` over raw-fd reads (`std.process.read_fd`; `protocol.mt`) driven by a
libuv poll handle on fd 0 with a 100 ms wake-up timer; client messages are
dispatched and the child drained between loop turns (`server.mt`).  The
debuggee now starts at `configurationDone` (the host's
`maybe_start_or_stop_on_entry`): `continue` starts it after an entry stop,
`pause`/`continue` SIGSTOP/SIGCONT a running program, and `terminate`/`disconnect`
SIGTERM it and let the exit produce the events.  The terminal events are now
`terminated` then `exited` with the real exit code (the host's order; the old
self order was `exited` then `terminated`).  `dap_smoke` is row-for-row equal
on the process backend — including the `events` row — and a stopOnEntry →
continue probe matches the host's stream; valgrind on the loop reads 0 errors.

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
| 2 | **No lldb-dap backend** (the extension's default) — **landed** (session 34, 2026-10-04) | `lldb_backend.mt` spawns the adapter and tracks pending requests (adapter seq → client seq, 5 s deadlines; the reverse table 15 s), and `lldb_policy.mt` drives the handshake — the client initialize response is deferred until the adapter's, capabilities are merged (static set + adapter's, `supportsSetVariable` follows setExpression, `exceptionBreakpointFilters` overridden when non-empty), the adapter's `initialized` is suppressed, launch/attach forward (client-only keys stripped, `program` replaced, `stopOnEntry` forced for launch), `configurationDone` syncs the stored breakpoints first, terminate falls back to disconnect, and unknown commands forward. `tools/dap_smoke.rb` drives both servers against an embedded fake adapter (`runInTerminal` reverse request included) and every row matches |
| 3 | **No debug map** — **landed** (session 34, 2026-10-04) | `projects/mtc/src/mtc/debug_map.mt` ports the host's writer/loader (`version / functions[] (name, cName, params, locals, sourcePath, line) / binaryPath / programSourcePath`, paths relative to the sidecar; `line: 0` is treated as synthetic and omitted like the host), `build.mt` writes `<output>.mtdbg.json` on the success branch, and `debug_map_test.mt` locks the model + round trip. The sidecar is semantically equal to the host's on the smoke fixture. The bridge loads it at launch (or via the `modules` fallback) and rewrites stackTrace frame names + the frame map, scope variables references, Locals variable names (`__mt_*` dropped) and evaluate/setVariable/setExpression/dataBreakpointInfo expressions through the host's token scanner |
| 4 | **Pause diagnostics / `modules`-driven map loading** — **landed** (session 34, 2026-10-04) | On a pause-requested stop the bridge issues the 8-level `stackTrace` and emits the host's console `output` summary (informative-frame selection and frame formatting ported from `pause_diagnostics.rb`); the SIGSTOP-exception stop is rewritten to `reason: "pause"`. The `modules` fallback loads a sidecar from the adapter's module list when a stackTrace arrives without one |
| 5 | **Real lldb-dap end-to-end / VS Code** — **landed** (session 34, 2026-10-04; F5 ordering fixed session 71, 2026-11-13) | the smoke's real section builds the `.mt` source with each server (so each side's own map is exercised) and drives breakpoint → `stopped(breakpoint)` → `stackTrace` (`frame0 name` = `add`, source `main.mt`) → scopes/variables (`a,b,total`) → evaluate → next → continue → `exited`/`terminated`. Every row matches except `lldb-real frame0 name` (self `add`, host `main_add` — the host's program-cache hit skips its map; documented self-better difference). Session 71 removed the `configurationDone` deferral on the launch response: an async-order probe (launch, then `configurationDone` without waiting, matching VS Code) gets launch success → entry stop → breakpoint stop → frame `main` → locals `x=3` → evaluate `3` from the real `lldb-dap`. A desktop F5 click-through is an optional manual smoke, not a known gap |

Verification: `ruby tools/dap_smoke.rb [--self-bin PATH]` must show zero
differing rows except the documented one, and a real VS Code session
(`bindings/vscode`, `backend: lldb-dap`) must stop on a breakpoint and show
locals — the same end-to-end check `docs/lsp-design.md` requires for
user-visible LSP changes.  The session-71 async-order probe
(`ruby tools/dap_async_probe.rb`) is the automated stand-in for the F5
click-through.  The extension's descriptor factory now emits
`mtc dap --backend=… [--adapter-path=…] …extraArgs` (the old `unshift` put the
flag before the subcommand and both CLIs rejected it).
