# Package Manager Roadmap

This document records the current implementation status and remaining follow-up work for Milk Tea package management.

## Goals

- support real version requirements for registry packages, including exact, exact-or-higher, and bounded ranges
- keep locked and frozen builds deterministic
- add first-class `deps add`, `deps remove`, and `deps update` workflows
- preserve the current direct-dependency import boundary model
- leave build, check, run, and LSP requests fetch-free

## Current Constraints

The current implementation is intentionally simple:

- manifests support local `path`, pinned `git` + `rev`, and exact or ranged registry versions
- live local-path graphs and `package.lock` graphs can both carry duplicate package namespaces as distinct package instances
- exact and ranged registry dependencies now resolve per dependency instance once source selection is explicit
- `package.lock` schema v2 records dependency edges by package instance id while still keeping readable dependency names
- live compiler/LSP package resolution now follows the importer's exact dependency edge when a package graph is available
- live direct resolution remains fetch-free; cache-backed dependencies still flow through `deps lock` plus `--locked` or `--frozen`

Those choices keep the current model predictable while allowing duplicate package namespaces across fixed and ranged registry graphs. The core package-manager architecture is now landed; the remaining work is mostly diagnostics and UX polish.

## Core Design Decision

Milk Tea now uses a two-layer dependency model:

1. source selection
2. version solving

Source selection decides how a dependency can be satisfied:

- local `path` dependencies are fixed local packages
- pinned git dependencies are fixed source identities
- exact registry versions are fixed source identities
- ranged registry dependencies are solver-managed candidates resolved per dependency edge

Version solving applies only to registry dependencies. Path, pinned git, and exact registry sources enter the solve as already-selected package instances that contribute additional dependency requirements from their manifests.

## Current Solver

Milk Tea currently uses a deterministic edge-aware DFS/backtracker for registry requirements.

Current properties:

- it prefers the highest available registry version that satisfies each dependency edge
- it backtracks through transitive descendants when a candidate's own dependency graph fails
- different importer package instances may resolve the same package namespace to different versions when needed
- selective `deps update NAME...` keeps unrelated locked registry instances pinned by dependency edge, not just by package name

This is sufficient for the current package model because direct dependencies stay namespace-unique inside each package manifest. A future PubGrub-style layer would still be worthwhile if conflict explanations become a priority.

## Version Model

Milk Tea needs explicit version and requirement types.

Recommended new core types:

- `PackageVersion`
- `PackageVersionReq`
- `PackageRequirement`

Recommended initial requirement syntax for registry dependencies:

- exact: `1.2.3`
- exact or higher: `>=1.2.3`
- lower and upper bounds: `>=1.2.3, <2.0.0`
- compatible release: `^1.2.3`
- patch/minor drift: `~1.2.3`

The shorthand string form should continue to work:

```toml
[dependencies]
"teefan.ui" = "^1.2.3"
```

The table form should stay equivalent:

```toml
[dependencies]
"teefan.ui" = { version = ">=1.2.3, <2.0.0" }
```

Pinned git and path dependencies should remain exact source selections, not solver ranges.

## Registry Metadata

The solver needs dependency metadata for candidate registry versions before package sources are fetched.

The registry abstraction should expose:

- available versions for a package name
- dependency requirements for each version
- package metadata needed for lockfile rendering and diagnostics

The current implementation can read this metadata from published filesystem registry roots or from a static HTTP mirror that serves `packages/<name>/versions.txt` plus package archives. A richer HTTP registry can still provide the same information through its own index without changing solver behavior.

## The Duplicate Package Name Rule

The old whole-graph uniqueness rule is gone.

The current rule set is:

- one package instance cannot declare two direct dependencies that expose the same package namespace
- transitive duplicate package namespaces are allowed when different importer package instances resolve to different sources or versions

That restriction stays because Milk Tea imports are written against package namespaces such as `import teefan.ui.layout`, not dependency aliases. Two direct dependencies with the same namespace would make import resolution ambiguous.

## Required Graph And Loader Refactor

Supporting transitive duplicate versions required more than a solver.

Part of this refactor is now landed for locked graphs:

- `package.lock` schema v2 records stable package instance ids and dependency edges by instance id
- locked compiler and LSP paths resolve package imports through the importer's exact dependency edge instead of flat source-root order

That refactor is also landed for live local-path graphs:

- `PackageGraph` no longer rejects transitive duplicate package namespaces when they resolve to different package roots or registry versions
- live CLI and LSP analysis paths pass that graph into `ModuleLoader`, so each importer resolves package imports against its own direct dependency edge

The main remaining follow-up is polish around diagnostics and UX, not graph identity or version-selection correctness.

### Package graph changes

`PackageGraph` now carries explicit package-instance identity through fixed-source and solver-produced graphs.

Recommended node identity fields:

- package namespace
- resolved version when present
- resolved source identity
- stable instance id for lockfiles and diagnostics

Edges should target specific package instances, not just package names.

### Lockfile changes

`package.lock` now uses schema version 2 for instance-aware graphs.

The current schema records:

- a stable package instance id for every resolved package
- source identity fields
- resolved version
- dependency edges by instance id, not by package name

Name-only dependency arrays are not sufficient once the graph can contain more than one instance of the same package namespace.

### Module loader changes

Locked `ModuleLoader` paths and live package-graph-backed paths now resolve package imports by exact dependency instance across local-path, exact-registry, and ranged-registry graphs.

The locked resolution rule is:

1. find the importer package instance
2. if the import is inside the importer's own namespace, resolve against the importer's source root
3. otherwise find the unique direct dependency edge whose package namespace matches the import
4. resolve only inside that dependency instance's source root
5. keep `std` resolution separate from package-instance resolution

This is the critical change that makes transitive duplicate versions safe once the graph is resolved.

## Manifest Shape

Milk Tea can keep package namespaces as the logical import surface while still preparing for better manifest UX.

Recommended dependency schema:

```toml
[dependencies]
"teefan.ui" = "^1.2.3"
"teefan.math" = { version = ">=2.1.0, <3.0.0" }
"teefan.render" = { git = "https://example.invalid/render.git", rev = "deadbeef" }
"local.widgets" = { path = "../widgets" }
```

If Milk Tea later wants manifest aliases, the manifest should support an explicit package field:

```toml
[dependencies]
ui = { package = "teefan.ui", version = "^1.2.3" }
```

But aliases alone do not solve direct multi-version imports. That should remain unsupported unless the language itself gains an import alias mechanism tied to dependency identities.

## UX Commands

Milk Tea should add these commands first:

- `mtc deps add NAME@REQ`
- `mtc deps add NAME --git URL --rev REV [--subdir DIR]`
- `mtc deps add NAME --path PATH`
- `mtc deps remove NAME`
- `mtc deps update`
- `mtc deps update NAME...`

Recommended behavior:

- edit `package.toml`
- resolve dependencies immediately
- write `package.lock`
- materialize any newly required cache-backed sources
- fail atomically if solving or fetching fails

Recommended follow-up commands:

- `mtc deps why NAME`
- `mtc deps outdated`

### Add

`deps add` should:

- reject conflicting manifest source selectors
- reject a direct dependency whose package namespace duplicates an existing direct dependency
- update the manifest and lockfile in one operation
- fetch cache-backed sources because this is an explicit dependency-management command

### Remove

`deps remove` should:

- delete the dependency from `package.toml`
- rerun resolution
- rewrite `package.lock`
- leave the shared cache alone unless a future `deps prune` command exists

### Update

`deps update` should change the lockfile within the existing manifest requirements.

That should be separate from changing the requirement itself.

If the user wants to change a requirement, Milk Tea should support either:

- `mtc deps add NAME@NEW_REQ` for an existing dependency
- or a future `mtc deps set NAME@NEW_REQ`

## Delivery Status

### Landed

- `PackageVersion` and `PackageVersionReq` support exact, bounded, caret, tilde, and shorthand requirement syntax
- `deps add`, `deps remove`, `deps lock`, `deps update`, `deps fetch`, and `deps publish` are implemented
- `package.lock` schema v2 records package instance ids and dependency edges by instance id
- locked compiler, CLI, and LSP flows resolve imports through exact dependency instances
- ranged registry dependencies now resolve per dependency edge, allowing transitive duplicate versions when needed
- selective `deps update NAME...` keeps unrelated locked registry instances pinned by dependency edge

### Open Follow-Up

- add better solver conflict explanations to CLI errors
- add `deps why` and `deps outdated`
- decide whether dependency aliases should ever participate in language import syntax
- revisit any remaining module-indexing cleanup if future features need a global lookup across duplicate package instances
