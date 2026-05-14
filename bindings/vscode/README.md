# Milk Tea VS Code Extension

Language support, LSP, and DAP integration for Milk Tea (`.mt`) files.

## Development

```bash
npm install
npm run compile
npm run watch
```

`npm run compile` type-checks the extension and emits a bundled `dist/extension.js` for packaging.

## Settings

- `milkTea.lsp.dependencyResolution`: `auto` (default), `live`, `locked`, or `frozen`.
- `auto` uses `package.lock` when it is current and falls back to live manifests otherwise.
- `locked` always resolves semantic editor features from `package.lock`.
- `frozen` requires a current `package.lock` and reports a lockfile diagnostic when it is missing or stale.

## Package And Install

Build a VSIX package:

```bash
npm run vsix:build
```

Install the built extension into VS Code (uses `code --install-extension`):

```bash
npm run vscode:install
```

Uninstall the extension from VS Code (skips cleanly when it is already absent):

```bash
npm run vscode:uninstall
```

Rebuild and reinstall in one step:

```bash
npm run vscode:reinstall
```

## Notes

- The install script expects a VSIX named `<package-name>-<package-version>.vsix` in this folder.
- The uninstall target is `milk-tea-lang.milk-tea-lang`.
- VSIX packaging uses the bundled `dist/extension.js` output and skips `node_modules`.
- This is intentional: an externalized `vscode-languageclient` packaging experiment reduced `dist/extension.js`, but regressed the VSIX to 214 files / 165 JavaScript files / 307.53 KB and brought back `vsce`'s bundling warning.
