# Milk Tea VS Code Extension

Language support, LSP, and DAP integration for Milk Tea (`.mt`) files.

## Development

```bash
npm install
npm run compile
```

## Package And Install

Build a VSIX package:

```bash
npm run vsix:build
```

Install the built extension into VS Code (uses `code --install-extension`):

```bash
npm run vscode:install
```

Uninstall the extension from VS Code (uses `code --uninstall-extension`):

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
