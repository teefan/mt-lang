# Milk Tea Build Guide

This guide documents package manifests, local library dependencies, executable builds, and the current wasm workflow.

## 1. Packages And Entry Points

Milk Tea builds either a single source file or a package directory.

- A source build compiles one `.mt` file directly.
- A package build reads `package.toml` from the target directory.

Minimal package example:

```toml
[package]
name = "game_engine"
version = "0.1.0"

[profile]
default = "debug"

[platform]
default = "wasm"

[build]
entry = "src/main.mt"
preload = "assets"
html_template = "web/shell.html"
```

Relevant build keys:

- `package.kind`: optional package kind. The default is `application`. Use `library` for reusable source packages.
- `package.source_root`: optional module root for the package. The default is the package root. Use `src` when your package modules live under `src/...`.
- `build.entry`: entry source file, relative to the package root.
- `build.output`: optional explicit output path.
- `build.preload`: optional file or directory to bundle into a wasm build.
- `build.html_template`: optional HTML shell template for wasm builds.
- `profile.default`: default profile when the CLI does not receive `--profile`.
- `platform.default`: default platform when the CLI does not receive `--platform`.

Application packages default to `build.entry = "src/main.mt"` when that file exists. Library packages do not have an executable entry point.

## 2. Library Packages, Version Requirements, And Dependency Commands

Milk Tea packages can now depend on local reusable source packages.

Library package example:

```toml
[package]
name = "tetris.pieces"
version = "0.1.0"
kind = "library"
source_root = "src"
```

Application package with local dependencies:

```toml
[package]
name = "tetris"
version = "0.1.0"

[build]
entry = "src/main.mt"

[dependencies]
"tetris.pieces" = { path = "packages/tetris_pieces", version = "0.1.0" }
"tetris.rules" = { path = "packages/tetris_rules", version = "0.1.0" }
```

Application package with a pinned git dependency:

```toml
[package]
name = "tetris"
version = "0.1.0"

[dependencies]
"teefan.ui" = { git = "https://example.invalid/teefan/ui.git", rev = "deadbeef", subdir = "packages/ui" }
```

Application package with an exact registry dependency:

```toml
[package]
name = "tetris"
version = "0.1.0"

[dependencies]
"teefan.ui" = "1.2.3"
```

Application package with a ranged registry dependency:

```toml
[package]
name = "tetris"
version = "0.1.0"

[dependencies]
"teefan.ui" = "^1.2.3"
```

Dependency paths are resolved relative to the depending package root.

Supported version requirement forms:

- exact: `1.2.3`
- lower bound: `>=1.2.3`
- upper bound: `<2.0.0`
- compatible release: `^1.2.3`
- patch-compatible release: `~1.2.3`
- conjunctions: `>=1.2.3, <2.0.0`

For local `path` dependencies, `version = "..."` is optional. When present, the depending manifest records the expected local package version and resolution fails if the target package's `package.version` does not satisfy that requirement.

Imported modules keep normal Milk Tea syntax:

```milk-tea
import tetris.pieces.defs as pieces
import tetris.rules.scoring as scoring
```

Current scope:

- local `path` dependencies, optional versioned `path` dependencies, pinned git dependencies (`git`, `rev`, optional `subdir`), and exact or ranged registry dependencies are supported in dependency-management flows
- registry requirement solving is phase 1: the solver chooses one resolved version per package name across the entire graph, so incompatible ranges that require multiple versions of the same package still fail
- dependency source roots are resolved recursively
- packages can import their own modules, `std`, and declared direct dependencies only
- transitive dependency packages are loaded for dependent packages, but they are not directly importable from the root application unless declared there too
- package dependency cycles are rejected during graph construction
- deterministic `package.lock` generation is supported for graphs that satisfy that one-package-name-per-graph rule
- `deps tree`, `deps lock`, `deps add`, `deps remove`, `deps update`, and `deps fetch` are explicit dependency-management commands; commands that need git or registry sources may materialize them into the shared source cache while reading manifests
- build, check, run, and live LSP dependency resolution stay fetch-free; git or registry manifests are meant to flow through `deps lock` plus `--locked` or `--frozen`, while live direct resolution continues to reject cache-backed dependencies
- local registry publish and fetch flows now exist, and an optional upstream filesystem registry mirror is supported through `$MILK_TEA_PACKAGE_REGISTRY_UPSTREAM`; HTTP registry transport and update flows are still not implemented

Inspect the current local package graph with:

```sh
mtc deps tree path/to/package
```

When run inside a package directory, `mtc deps tree` defaults to the current directory.

When pinned git or exact registry dependencies are present, `mtc deps tree` may materialize them into the shared source cache so it can read their manifests.

Add or update a dependency in `package.toml` and refresh `package.lock` with:

```sh
mtc deps add path/to/package teefan.ui@^1.2.3
mtc deps add path/to/package tetris.rules --path packages/tetris_rules --version 0.1.0
mtc deps add path/to/package teefan.ui --git https://example.invalid/teefan/ui.git --rev deadbeef --subdir packages/ui
```

Remove a dependency and refresh `package.lock` with:

```sh
mtc deps remove path/to/package teefan.ui
```

Re-resolve the current manifest and refresh `package.lock` with:

```sh
mtc deps update path/to/package
```

`deps update` keeps the manifest requirements unchanged and picks the newest available versions that still satisfy them under the current phase-1 solver.

Publish a versioned package into the local registry store with:

```sh
mtc deps publish path/to/package
mtc deps publish path/to/package --upstream
```

Publishing rules:

- the package must declare `package.version`
- publishing is immutable; an existing `name + version` cannot be overwritten
- the local registry root is `$MILK_TEA_PACKAGE_REGISTRY` when set, otherwise `$XDG_DATA_HOME/milk_tea/registry` or `~/.local/share/milk_tea/registry`
- `--upstream` publishes into `$MILK_TEA_PACKAGE_REGISTRY_UPSTREAM` instead, when configured
- upstream transport currently means mirroring against another filesystem registry root, not an HTTP registry server

Materialize any cache-backed sources referenced by the current `package.lock` with:

```sh
mtc deps fetch path/to/package
```

Current `deps fetch` scope:

- it reads `package.lock` explicitly instead of fetching during `check`, `build`, `run`, or LSP requests
- it is currently meaningful only for cache-backed sources recorded in `package.lock`
- git sources can be materialized into the shared source cache
- registry lock entries are materialized from the local registry store into the shared source cache, and may first be mirrored from `$MILK_TEA_PACKAGE_REGISTRY_UPSTREAM` when that exact version is missing locally
- path-only lockfiles report that there are no cache-backed sources to materialize

Write the current resolved local package graph to `package.lock` with:

```sh
mtc deps lock path/to/package
```

When run inside a package directory, `mtc deps lock` also defaults to the current directory.

Verify that the checked-in lockfile is current with:

```sh
mtc deps lock path/to/package --check
```

`--check` exits with status `0` when `package.lock` is current, and `1` when it is missing or out of date.

For pinned git or registry dependencies, `mtc deps lock` and `mtc deps lock --check` may materialize cache-backed package sources while recomputing the expected graph. Registry dependencies may also mirror missing versions from `$MILK_TEA_PACKAGE_REGISTRY_UPSTREAM` into the local registry first.

The current lockfile records:

- the schema version
- the root package name
- each resolved package's name, kind, version when present, manifest path, source root, source kind, source identity fields (`source_path` for path dependencies, `git_url` and `git_rev` plus optional `git_subdir` for git dependencies, `registry_package` and `registry_version` for registry dependencies), and direct dependency names

The current lockfile is generated deterministically from local `path` dependencies, pinned git dependencies, and solved registry dependencies. It is safe to regenerate; cache-backed dependency-management commands may also refresh the shared source cache while resolving manifests.

You can opt into locked dependency resolution for the current compiler path with:

```sh
mtc lint path/to/file.mt --locked
mtc check path/to/file.mt --locked
mtc build path/to/package --locked
mtc run path/to/package --locked
```

You can make those commands strict with `--frozen`, which implies `--locked` and fails when `package.lock` is missing or stale:

```sh
mtc lint path/to/file.mt --frozen
mtc check path/to/file.mt --frozen
mtc build path/to/package --frozen
mtc run path/to/package --frozen
```

Current locked-resolution scope:

- it uses `package.lock` for dependency graph resolution and direct dependency checks
- `--frozen` requires a current `package.lock` before compilation starts
- `lint` uses the locked graph for sema-backed lint rules and fix-mode semantic assistance
- the VS Code LSP supports `milkTea.lsp.dependencyResolution = auto|live|locked|frozen`, with `auto` using the lockfile when it is current and `frozen` surfacing stale-lock diagnostics in the editor
- it still reads the root package manifest for build settings such as `build.entry`, output configuration, preload assets, and HTML templates
- it currently applies to path dependencies and cache-backed git or registry lock entries

Planned registry and source-cache model:

- dependency resolution should stay split in two phases: first resolve a dependency spec to a local package root, then build the package graph from that local source tree
- the current code now already follows that shape internally: `PackageSourceResolver` resolves a dependency into a local source plus lockfile metadata, and `PackageGraph` only consumes the resolved local package tree
- cache-backed dependencies should resolve into an immutable source cache keyed by the exact resolved source identity, such as package name plus exact version or git URL plus commit hash
- the local registry store is now one concrete source of those identities; an optional upstream filesystem registry can mirror into it today, and HTTP registries can plug into the same model later without changing locked compiler behavior
- the current cache root model is `$XDG_CACHE_HOME/milk_tea/package_sources` when `XDG_CACHE_HOME` is set, otherwise `~/.cache/milk_tea/package_sources`; path dependencies bypass that shared cache
- cache-backed identities now also map to a deterministic materialized package root under that cache; git package roots append the configured `git_subdir`, while local path dependencies still bypass cache materialization entirely
- locked loading now expects cache-backed entries to be materialized already; if the cached `package.toml` is missing, loading fails fast instead of silently constructing unusable package roots
- `package.lock` should record that exact resolved source identity so `--locked` and `--frozen` can rebuild the graph from cached sources without re-solving or re-fetching
- compiler and LSP analysis should keep operating on local source roots only; fetch, update, and cache-population behavior should stay in explicit tooling commands instead of being hidden inside `check`, `build`, or editor requests

## 3. Build Commands

Build a source file:

```sh
mtc build path/to/app.mt
```

Build a package:

```sh
mtc build path/to/package
```

Run a source file or package:

```sh
mtc run path/to/package
```

Common options:

- `--profile debug|release`
- `--platform linux|windows|wasm`
- `--cc COMPILER`
- `-o OUTPUT`
- `--keep-c PATH`

The wasm platform also accepts the aliases `web`, `html5`, and `browser`.

## 4. Output Paths

Default package output paths are:

```text
build/bin/<platform>/<profile>/<package-name>
```

Platform-specific extensions are added automatically:

- Linux: no extension
- Windows: `.exe`
- wasm: `.html`

For direct source builds, the default output is the source path without `.mt`, except wasm builds, which default to a sibling `.html` file.

For wasm outputs:

- if the explicit output path has no extension, Milk Tea appends `.html`
- if the explicit output path has an extension, it must be `.html`

When targeting wasm, Milk Tea emits an Emscripten bundle next to the HTML entry point. The normal outputs are:

- `<name>.html`
- `<name>.js`
- `<name>.wasm`
- `<name>.data` when `build.preload` is used

Depending on Emscripten flags and debug settings, extra side files such as worker scripts, symbol files, and source maps may also be generated.

`mtc build --clean` removes the wasm HTML entry point and its sidecar bundle files.

## 5. Compiler Selection

Native builds use `--cc`, then `$CC`, then `cc`.

Wasm builds use `--cc` when you pass it explicitly. Otherwise Milk Tea switches to `$EMCC`, falling back to `emcc`.

That means these two commands are equivalent when `EMCC` is configured:

```sh
mtc build path/to/package --platform wasm
mtc build path/to/package --platform wasm --cc "$EMCC"
```

## 6. Preloading Files For wasm

Use `build.preload` to bundle a file or directory into the Emscripten virtual filesystem.

```toml
[build]
entry = "src/main.mt"
preload = "assets"
```

The configured path is resolved relative to the package root and must already exist.

Milk Tea mounts the preloaded path at `/<basename>`. For example:

- `preload = "assets"` becomes `/assets`
- runtime code can load `assets/tetris_tiles.png`

If you need multiple runtime assets, put them under a single directory and preload that directory.

## 7. Custom HTML Templates

Use `build.html_template` to provide a package-owned HTML shell for wasm output.

```toml
[build]
entry = "src/main.mt"
html_template = "web/shell.html"
```

The template path is resolved relative to the package root and must point to an existing file.

The template must contain each placeholder exactly once:

```html
{{{ MILK_TEA_CANVAS }}}
{{{ MILK_TEA_OUTPUT }}}
{{{ MILK_TEA_BOOTSTRAP }}}
{{{ SCRIPT }}}
```

Placeholder contract:

- `{{{ MILK_TEA_CANVAS }}}`: where the app canvas is inserted.
- `{{{ MILK_TEA_OUTPUT }}}`: where stdout and stderr output is rendered.
- `{{{ MILK_TEA_BOOTSTRAP }}}`: Milk Tea bootstrap code that wires `Module.canvas`, `print`, and `printErr`.
- `{{{ SCRIPT }}}`: the Emscripten loader script placeholder.

`{{{ SCRIPT }}}` is not a Milk Tea placeholder. It is required by Emscripten and must remain in the template.

If `build.html_template` is omitted, Milk Tea uses the default template in `lib/milk_tea/tooling/templates/wasm_shell.html`.

## 8. Running wasm Targets

`mtc run` behaves differently for wasm targets than for native binaries.

```sh
mtc run path/to/package
```

For wasm targets, Milk Tea:

- builds the HTML bundle
- starts a local preview server rooted at the build output directory
- opens the generated HTML in the default browser
- keeps the server in the foreground until you press `Ctrl-C`

The preview server sends the cross-origin isolation headers required by the current raylib and Web Audio worker setup.

## 9. Generated JavaScript

The `<name>.js` file in a wasm build is generated by Emscripten from the emitted C program and the final linker flags. It is not handwritten Milk Tea runtime code.

Milk Tea controls the HTML shell and the Emscripten invocation, but the JavaScript loader itself comes from Emscripten.
