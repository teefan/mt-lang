# Milk Tea Build Guide

This guide documents package manifests, local library dependencies, executable builds, and the current wasm workflow.

## 1. Packages And Entry Points

Milk Tea builds either a single source file or a package directory.

- A source build compiles one `.mt` file directly.
- A package build reads `package.toml` from the target directory.

Create a new application package scaffold with:

```sh
mtc new my-project
```

This writes `package.toml` and `src/main.mt` into `my-project/`. The scaffold uses an explicit `build.entry = "src/main.mt"`, normalizes the directory basename to snake_case for `package.name`, and generates a headerless entry file. For example, both `mtc new my-project` and `mtc new MyProject` generate `package.name = "my_project"` and `src/main.mt` with just the entry `function main()`.
The generated manifest also writes `package.source_root = "src"` explicitly so imports resolve from `src/` without requiring a `src.` prefix.

Minimal package example:

```toml
[package]
name = "game_engine"
version = "0.1.0"
source_root = "src"

[profile]
default = "debug"

[platform]
default = "wasm"

[build]
entry = "src/main.mt"
assets = "assets"
html_template = "web/shell.html"
```

Relevant build keys:

- `package.kind`: optional package kind. The default is `application`. Use `library` for reusable source packages.
- `package.source_root`: optional module root for the package. When a package contains a `src/` directory, the default is `src`; otherwise the default is the package root.
- Module identity inside a package is inferred relative to `package.source_root`, so `src/main.mt` is module `main` and `src/game/player.mt` is module `game.player`.
- `build.entry`: entry source file, relative to the package root.
- `build.output`: optional explicit output path.
- `build.assets`: optional runtime asset path or array of paths. Each entry may be a file or directory. wasm builds preload each entry into the virtual filesystem; native builds either stage each entry beside the executable or pack them into `assets.mtpack` for bundle/archive outputs.
- `build.html_template`: optional HTML shell template for wasm builds.
- `profile.default`: default profile when the CLI does not receive `--profile`.
- `platform.default`: default platform when the CLI does not receive `--platform`.

Packages default to `build.entry = "src/main.mt"` when that file exists. Library packages do not have an executable entry point.

### 1.1 Platform-specific source file variants

Milk Tea supports platform-specific full-file replacements for ordinary source files.

Canonical filename forms are:

- shared file: `name.mt`
- Linux variant: `name.linux.mt`
- Windows variant: `name.windows.mt`
- wasm variant: `name.wasm.mt`

Resolution is deterministic:

1. choose the active target platform from `--platform`, otherwise `platform.default`, otherwise the host platform
2. when resolving `name.mt`, prefer `name.<platform>.mt`
3. fall back to `name.mt` when the platform-specific file does not exist

This applies to both imports and package entry files. For example, if `build.entry = "src/main.mt"` and the active target is `windows`, Milk Tea first tries `src/main.windows.mt` and falls back to `src/main.mt`.

Imports keep the ordinary logical module name:

```mt
import tetris.rules.scoring as scoring
```

The importer never spells the platform in the import path. `tetris.rules.scoring` may resolve to either `tetris/rules/scoring.mt` or `tetris/rules/scoring.<platform>.mt` depending on the active target.

Only the canonical suffixes `linux`, `windows`, and `wasm` are valid in source filenames. CLI and manifest aliases such as `web` and `browser` still normalize to `wasm`, but source files should use `*.wasm.mt`.

If you directly target a suffixed source file such as `src/main.windows.mt`, that file pins the target platform. Passing a conflicting explicit platform is an error.

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
- exact registry versions behave like fixed source identities in dependency-management and locked flows
- ranged registry dependencies are now solved per dependency instance, so different transitive paths may resolve the same package namespace to different registry versions when required
- dependency source roots are resolved recursively
- packages can import their own modules, `std`, and declared direct dependencies only
- transitive dependency packages are loaded for dependent packages, but they are not directly importable from the root application unless declared there too
- package dependency cycles are rejected during graph construction
- deterministic `package.lock` generation is supported for package-instance-aware graphs, including duplicate registry package namespaces
- `deps tree`, `deps lock`, `deps add`, `deps remove`, `deps update`, and `deps fetch` are explicit dependency-management commands; commands that need git or registry sources may materialize them into the shared source cache while reading manifests
- build, check, run, and live LSP dependency resolution stay fetch-free; git or registry manifests are meant to flow through `deps lock` plus `--locked` or `--frozen`, while live direct resolution continues to reject cache-backed dependencies
- local registry publish and fetch flows now exist, and `$MILK_TEA_PACKAGE_REGISTRY_UPSTREAM` may point either to another filesystem registry root or to a static HTTP mirror of the same published registry layout; `deps lock`, `deps update`, and `deps fetch` may sync missing registry versions from it

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
mtc deps update path/to/package teefan.ui
```

`deps update` keeps the manifest requirements unchanged and picks the newest available versions that still satisfy them under the current instance-aware registry solver.

When you pass one or more package names, `deps update` updates those packages and their currently locked transitive package-instance closure while keeping unrelated locked registry instances pinned to their existing versions.

Named selective updates require a current `package.lock` that still matches the current manifest, because that locked graph defines which transitive packages are allowed to move. If the lockfile is missing or stale, run plain `mtc deps update path/to/package` or `mtc deps lock path/to/package` first.

When `$MILK_TEA_PACKAGE_REGISTRY_UPSTREAM` is configured, `deps update` may also adopt a newer matching registry version from that upstream mirror and sync it into the local registry before materializing the shared source cache.

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
- publishing still requires a filesystem registry root; HTTP upstreams are read-only static mirrors
- the static HTTP mirror contract is the published registry layout plus `packages/<name>/versions.txt` and `packages/<name>/<version>.tar.gz`, so any ordinary static file server can host it

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
- the root package instance id used to identify the root node inside the locked graph
- each resolved package's name, kind, version when present, stable package instance id, manifest path, source root, source kind, source identity fields (`source_path` for path dependencies, `git_url` and `git_rev` plus optional `git_subdir` for git dependencies, `registry_package` and `registry_version` for registry dependencies), direct dependency names for readability, and dependency edges by package instance id

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
- it resolves package imports through the exact locked dependency edge, so `package.lock` can represent transitive duplicate package namespaces safely at analysis time
- `--frozen` requires a current `package.lock` before compilation starts
- `lint` uses the locked graph for sema-backed lint rules and fix-mode semantic assistance
- the VS Code LSP supports `milkTea.lsp.dependencyResolution = auto|live|locked|frozen`, with `auto` using the lockfile when it is current and `frozen` surfacing stale-lock diagnostics in the editor
- it still reads the root package manifest for build settings such as `build.entry`, output configuration, runtime assets, and HTML templates
- it currently applies to path dependencies and cache-backed git or registry lock entries

Current duplicate-version behavior:

- `package.lock`, locked compiler/LSP flows, live local-path package graphs, exact registry identities, and ranged registry dependencies all resolve imports through package instances instead of flat root order, so transitive duplicate package namespaces are safe once the graph is resolved
- direct duplicate dependency namespaces inside a single package manifest are still invalid, because Milk Tea imports target package namespaces rather than dependency aliases

Planned registry and source-cache model:

- dependency resolution should stay split in two phases: first resolve a dependency spec to a local package root, then build the package graph from that local source tree
- the current code now already follows that shape internally: `PackageSourceResolver` resolves a dependency into a local source plus lockfile metadata, and `PackageGraph` only consumes the resolved local package tree
- cache-backed dependencies should resolve into an immutable source cache keyed by the exact resolved source identity, such as package name plus exact version or git URL plus commit hash
- the local registry store is now one concrete source of those identities; an optional upstream filesystem registry or static HTTP mirror can feed into it today without changing locked compiler behavior
- the current cache root model is `$XDG_CACHE_HOME/milk_tea/package_sources` when `XDG_CACHE_HOME` is set, otherwise `~/.cache/milk_tea/package_sources`; path dependencies bypass that shared cache
- cache-backed identities now also map to a deterministic materialized package root under that cache; git package roots append the configured `git_subdir`, while local path dependencies still bypass cache materialization entirely
- locked loading now expects cache-backed entries to be materialized already; if the cached `package.toml` is missing, loading fails fast instead of silently constructing unusable package roots
- `package.lock` should record that exact resolved source identity so `--locked` and `--frozen` can rebuild the graph from cached sources without re-solving or re-fetching
- compiler and LSP analysis should keep operating on local source roots only; fetch, update, and cache-population behavior should stay in explicit tooling commands instead of being hidden inside `check`, `build`, or editor requests

### 2.1 Machine-readable CLI contracts

The CLI now exposes versioned JSON contracts for external tooling and future cross-implementation conformance tests.

Available contract surfaces:

- `mtc semantic-tokens path/to/file.mt` emits a versioned semantic-token JSON payload.
- `mtc diagnostics path/to/file.mt` emits a versioned diagnostics JSON payload.
- `mtc source-index path/to/root --json` emits a versioned source-index JSON payload for deterministic visible `.mt` file discovery.
- `mtc frontend-artifacts path/to/file.mt --compiled-c ... --saved-c ... --debug-map ... --binary-path ... --json` emits a versioned frontend-artifact handoff payload and writes the matching files.
- `mtc build path/to/package --json` emits a versioned build-result JSON payload.
- `mtc run path/to/package --json` emits a versioned run-result JSON payload.

Current contract conventions:

- each payload includes `version = 1` and a `contract` name
- paths are normalized with forward slashes and are relative to the current working directory when the target lives under it
- `mtc source-index --json` intentionally skips hidden files and hidden directories so contract results match the normal directory-based CLI scan surface
- diagnostics and semantic tokens expose explicit UTF-8 byte spans for stable machine checks
- the frontend-artifact contract is file-backed on purpose: compiled C, saved C, and debug-map JSON stay available for an external backend driver or a future self-hosted frontend process
- `mtc run --json` still returns the program exit status as the CLI process status while also including it in the JSON payload

### 2.2 Portable contract runners

The black-box conformance runners under `test/contracts/` now accept env-configured command lines so the same Ruby harness can validate a non-Ruby Milk Tea implementation.

Supported runner env vars:

- `MILK_TEA_CONTRACT_CLI_CMD` overrides the command used by `test/contracts/cli_contract_test.rb`
- `MILK_TEA_CONTRACT_LSP_CMD` overrides the command used by `test/contracts/lsp_contract_test.rb`

When unset, the harnesses keep the current defaults and run the checked-in Ruby scripts:

- CLI default: `ruby bin/mtc`
- LSP default: `ruby bin/mtc-lsp`

Each env var is parsed as a full command line, not just an executable path. This lets an alternate implementation provide either a native binary or a wrapper command.

Examples:

```sh
bundle exec ruby -Itest test/contracts/cli_contract_test.rb
bundle exec ruby -Itest test/contracts/lsp_contract_test.rb
```

```sh
MILK_TEA_CONTRACT_CLI_CMD='./build/mtc' \
MILK_TEA_CONTRACT_LSP_CMD='./build/mtc-lsp' \
bundle exec ruby -Itest test/contracts/cli_contract_test.rb

MILK_TEA_CONTRACT_CLI_CMD='./build/mtc' \
MILK_TEA_CONTRACT_LSP_CMD='./build/mtc-lsp' \
bundle exec ruby -Itest test/contracts/lsp_contract_test.rb
```

That contract layer is now the preferred portability gate for a rewrite: keep the fixtures and expected payloads stable, and swap only the implementation command.

### 2.3 Bootstrap scope for a rewrite

The recommended bootstrap-v1 scope for a non-Ruby compiler extending is:

- compiler frontend and backend parity sufficient to satisfy the existing CLI contracts
- stdio LSP parity sufficient to satisfy the existing LSP contract fixtures
- enough std support for compiler, CLI, and editor tooling code paths that do not require external package fetching

Pure host-side helpers such as `std.path` and `std.uri` are in scope for bootstrap-v1. They replace ad hoc path joining, normalization, and file-URI encoding glue without pulling in network or archive dependencies.

The following surfaces should stay out of bootstrap-v1 unless they are directly required by that contract gate:

- registry HTTP mirroring and package archive extraction
- git-backed dependency materialization
- binding generation and clang-driven bindgen automation

That split is deliberate. The current black-box contract suite is already strong enough to validate compiler and editor behavior, while registry sync, archive tooling, and bindgen still depend on higher-level host libraries that are better added after the core implementation is stable.

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
- `--frontend-command ARG` to use an external frontend command; repeat it once per argv element, for example `--frontend-command ruby --frontend-command bin/mtc --frontend-command frontend-artifacts`
- `-o OUTPUT`
- `--keep-c PATH`
- `--bundle` for native package builds when you want a distributable app directory instead of a bare executable
- `--archive` for native package builds when you also want a `.tar.gz` archive of the bundle; this implies `--bundle`

For bootstrap and host-tool migration, you can also set `MILK_TEA_FRONTEND_CMD` to a full command line such as `ruby bin/mtc frontend-artifacts`. `Build.build` and every current caller layered on top of it will use that external frontend by default unless the CLI receives explicit `--frontend-command` arguments.

The wasm platform also accepts the aliases `web`, `html5`, and `browser`.

For editor tooling, the Milk Tea VS Code extension also accepts `milkTea.lsp.platform = auto|linux|windows|wasm`.

- `auto`: use the open file suffix when present, otherwise the owning package default platform, otherwise the host platform
- `linux|windows|wasm`: force that platform for platform-specific import resolution in the language server

## 4. Output Paths

Default package output paths are:

```text
build/bin/<platform>/<profile>/<package-name>
```

Default native bundle output paths are:

```text
build/dist/<platform>/<profile>/<package-name>/
```

The bundle directory contains the entry executable named after the package plus an `assets.mtpack` file when `build.assets` is configured.

When `--archive` is enabled, Milk Tea also writes a sibling archive file:

```text
build/dist/<platform>/<profile>/<package-name>.tar.gz
```

Platform-specific extensions are added automatically:

- Linux: no extension
- Windows: `.exe`
- wasm: `.html`

For direct source builds, the default output is the source path without `.mt`, except wasm builds, which default to a sibling `.html` file.

When you pass `mtc build --bundle` or `mtc build --archive` for a native package build, `-o OUTPUT` becomes the bundle directory path instead of the executable file path.

For wasm outputs:

- if the explicit output path has no extension, Milk Tea appends `.html`
- if the explicit output path has an extension, it must be `.html`

When targeting wasm, Milk Tea emits an Emscripten bundle next to the HTML entry point. The normal outputs are:

- `<name>.html`
- `<name>.js`
- `<name>.wasm`
- `<name>.data` when `build.assets` is used

When targeting linux or windows with `build.assets`, Milk Tea also stages each configured file or directory next to the output binary using its basename.

When targeting linux or windows with `--bundle`, Milk Tea writes the executable into the bundle directory and packs `build.assets` into `assets.mtpack` beside it.

When targeting linux or windows with `--archive`, Milk Tea also writes a `.tar.gz` archive of that bundle directory beside it.

Depending on Emscripten flags and debug settings, extra side files such as worker scripts, symbol files, and source maps may also be generated.

`mtc build --clean` removes generated output artifacts. For wasm that includes the HTML entry point and sidecar bundle files; for native explicit outputs it also removes staged `build.assets` entries beside the binary.

`mtc build --clean --bundle` removes native bundle output directories. For the default package output it removes `build/dist`.

`mtc build --clean --archive` removes both the native bundle directory and its `.tar.gz` archive output.

## 5. Compiler Selection

Native builds use `--cc`, then `$CC`, then `cc`.

Wasm builds use `--cc` when you pass it explicitly. Otherwise Milk Tea switches to `$EMCC`, falling back to `emcc`.

That means these two commands are equivalent when `EMCC` is configured:

```sh
mtc build path/to/package --platform wasm
mtc build path/to/package --platform wasm --cc "$EMCC"
```

## 6. Runtime Assets

Use `build.assets` to declare one runtime asset path or an array of asset paths.

```toml
[build]
entry = "src/main.mt"
assets = ["assets", "credits.txt"]
```

Each configured path is resolved relative to the package root and must already exist. Array entries must have distinct basenames, because Milk Tea uses that basename as the wasm mount path and the staged native filename.

For wasm targets, Milk Tea passes each path to Emscripten `--preload-file` and mounts it at `/<basename>`. For example:

- `assets = "assets"` becomes `/assets`
- `assets = ["assets", "credits.txt"]` also mounts `/credits.txt`
- runtime code can load `assets/tetris_tiles.png`

For native targets without `--bundle`, Milk Tea copies each configured file or directory next to the final executable using the same basename. For example:

- `assets = "assets"` becomes `<output-dir>/assets`
- `assets = "data/game.db"` becomes `<output-dir>/game.db`
- `assets = ["assets", "credits.txt"]` also stages `<output-dir>/credits.txt`

For native `--bundle` and `--archive` package builds, Milk Tea writes one deterministic `assets.mtpack` file into the bundle root instead of copying raw files there. The pack keeps the same logical paths you would get from each source basename. For example:

- `assets = "assets"` stores `assets/...` entries inside `<bundle-dir>/assets.mtpack`
- `assets = ["assets", "credits.txt"]` also stores `credits.txt` inside the same pack
- `std.asset_pack` is the generic MTAP reader; `std.raylib.packed_assets` wraps it with a single `rl_assets.Error` enum for raylib-facing code, including packed image, texture, wave, sound, and music loading. Apps that support both packed bundle/archive runs and unpacked dev runs can prefer `std.raylib.packed_assets.open_assets_pack_if_present()`, treat `Option.none` as the unpacked case, and fall back to `std.raylib.runtime.enter_assets_directory()` there
- `std.raylib.packed_assets.load_music()` returns `rl_assets.PackedMusic`, which retains the packed source bytes for the lifetime of the raylib music stream; call `music.release()` when done instead of unloading the raw `rl.Music` handle directly

`mtc run` also stages `build.assets` entries beside its temporary native binary before launch.

If you want one asset-loading path to work for both wasm and native builds, resolve assets relative to the executable location on native builds instead of relying on the caller's working directory.

For raylib-based apps, `std.raylib.runtime.enter_assets_directory()` is the standard helper for that pattern: it first tries the executable directory, then falls back to the current working directory.

Using a single top-level asset directory is still the simplest layout, but it is no longer required when a few standalone files need to ship beside it.

Current asset-pack scope:

- the MTAP container and native bundle/archive flow are in place for packaged runtime assets
- `std.raylib.packed_assets` currently supports packed image, texture, wave, sound, and music loading
- packed music uses `rl_assets.PackedMusic` so the underlying bytes remain alive for the full stream lifetime instead of being released immediately after load

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
