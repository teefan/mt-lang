# Milk Tea Programming Language

Syntax highlighting, IntelliSense, and debugging for the [Milk Tea](https://teefan.github.io/mt-lang/) programming language.

## Features

- **Syntax highlighting** for `.mt` files with embedded GLSL, JSON, JSONC, and SQL heredocs
- **Language server** — diagnostics, hover, completion, go-to-definition, semantic tokens, document symbols, formatting
- **Debugger** — launch and attach via lldb-dap with breakpoints, stepping, variable inspection, and LLDB command hooks
- **Formatter** — format-on-save with configurable mode (tidy, preserve, safe/canonical)

## Getting Started

Install the extension, then open any `.mt` file. The language server starts automatically.

Requires the `mtc` compiler on your `$PATH`:

```bash
gem install mt-lang
```

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `milkTea.lsp.enabled` | `true` | Enable the Milk Tea language server |
| `milkTea.lsp.serverPath` | `"mtc"` | Path to the mtc binary |
| `milkTea.lsp.extraArgs` | `[]` | Extra arguments passed to `mtc lsp` |
| `milkTea.lsp.logLevel` | `"info"` | LSP log verbosity: `off`, `error`, `warn`, `info`, `debug`, `trace` |
| `milkTea.lsp.traceServer` | `"off"` | Trace JSON-RPC communication: `off`, `messages`, `verbose` |
| `milkTea.lsp.dependencyResolution` | `"auto"` | Import resolution mode: `auto` (lockfile when current), `live`, `locked`, `frozen` |
| `milkTea.lsp.platform` | `"auto"` | Active platform for module resolution: `auto`, `linux`, `windows`, `wasm` |
| `milkTea.lsp.retry.enabled` | `true` | Retry LSP startup on connection failure |
| `milkTea.lsp.retry.maxAttempts` | `3` | Max startup attempts |
| `milkTea.lsp.retry.delaySeconds` | `10` | Seconds between retry attempts |
| `milkTea.dap.enabled` | `true` | Enable the Milk Tea debug adapter |
| `milkTea.dap.serverPath` | `"mtc"` | Path to the mtc binary |
| `milkTea.dap.extraArgs` | `[]` | Extra arguments passed to `mtc dap` |
| `milkTea.dap.logLevel` | `"info"` | DAP log verbosity: `off`, `error`, `warn`, `info`, `debug`, `trace` |
| `milkTea.dap.retry.enabled` | `true` | Retry DAP launch on connection failure |
| `milkTea.dap.retry.maxAttempts` | `3` | Max launch attempts |
| `milkTea.dap.retry.delaySeconds` | `10` | Seconds between retry attempts |
| `milkTea.format.mode` | `"tidy"` | Formatter mode: `tidy`, `preserve`, `safe`, `canonical` |

## Debugging

Create a `launch.json` configuration. The extension provides snippets for common setups:

```jsonc
{
    "type": "milk-tea",
    "request": "launch",
    "name": "Debug Milk Tea Program",
    "backend": "lldb-dap",
    "program": "${file}",
    "args": [],
    "stopOnEntry": false
}
```

Requires `lldb-dap` (the LLDB debug adapter) on your `$PATH` for the `lldb-dap` backend.

For attaching to a running process:

```jsonc
{
    "type": "milk-tea",
    "request": "attach",
    "name": "Attach to Process",
    "backend": "lldb-dap",
    "pid": 12345
}
```

## Commands

- **Milk Tea: Restart LSP** — restart the language server
- **Milk Tea: View LSP Logs** — open the LSP output channel
- **Milk Tea: View DAP Logs** — open the DAP output channel
- **Milk Tea: Restart DAP (Stop Active Sessions)** — stop all active debug sessions

## Development

```bash
npm install
npm run compile       # type-check and bundle
npm run watch         # watch mode
npm run vsix:build    # package as .vsix
npm run vscode:install   # install into VS Code
```
