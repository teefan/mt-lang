# Package Manager Roadmap

This document defines the next implementation steps for Milk Tea package management after the current exact-version, path, pinned-git, lockfile, and source-cache model.

## Goals

- support real version requirements for registry packages, including exact, exact-or-higher, and bounded ranges
- keep locked and frozen builds deterministic
- add first-class `deps add`, `deps remove`, and `deps update` workflows
- preserve the current direct-dependency import boundary model
- leave build, check, run, and LSP requests fetch-free

## Current Constraints

The current implementation is intentionally simple:

- manifests support only local `path`, pinned `git` + `rev`, and exact registry versions
- `PackageGraph` rejects duplicate package names anywhere in the graph
- `package.lock` records dependency edges by package name only
- `ModuleLoader` resolves imports by scanning a flat list of `source_root` directories
- graph-aware import checks match dependencies by package name only

Those choices make the current model predictable, but they also mean a real multi-version dependency solver cannot fit on top of the current graph and loader unchanged.

## Core Design Decision

Milk Tea should move to a two-layer dependency model:

1. source selection
2. version solving

Source selection decides how a dependency can be satisfied:

- local `path` dependencies are fixed local packages
- pinned git dependencies are fixed source identities
- registry dependencies are solver-managed candidates

Version solving should apply only to registry dependencies. Path and pinned git sources should enter the solve as already-selected package instances that contribute additional dependency requirements from their manifests.

## Recommended Solver

Milk Tea should implement a PubGrub-style solver rather than a naive DFS backtracker.

Reasons:

- deterministic selection order is easy to enforce
- conflict explanations are much better than plain backtracking failures
- range support naturally grows from exact-version support
- future registry transports can reuse the same incompatibility model

The initial candidate ordering should stay simple and deterministic:

- prefer the highest available registry version that satisfies the current requirement set
- break ties by source priority only when different source kinds are ever allowed to compete for the same package name

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

For the current filesystem registry, the first implementation can read this metadata directly from published package roots. A future HTTP registry can provide the same information through an index without changing solver behavior.

## The Duplicate Package Name Rule

The current rule is too strict for real range solving:

- it blocks transitive duplicate versions entirely
- it forces the entire graph to collapse to one resolved version per package name
- it makes range support equivalent to global version unification only

That rule should be changed, but not removed blindly.

### What should remain true

Milk Tea should keep this rule:

- one package instance cannot declare two direct dependencies that expose the same package namespace

That restriction should stay because Milk Tea imports are written against package namespaces such as `import teefan.ui.layout`, not dependency aliases. Two direct dependencies with the same namespace would make import resolution ambiguous.

### What should change

Milk Tea should drop this rule:

- one package name per whole graph

Transitive duplicates must be allowed if different importer package instances resolve to different compatible versions.

## Required Graph And Loader Refactor

Supporting transitive duplicate versions requires more than a solver.

### Package graph changes

`PackageGraph` should move from package-name uniqueness to package-instance identity.

Recommended node identity fields:

- package namespace
- resolved version when present
- resolved source identity
- stable instance id for lockfiles and diagnostics

Edges should target specific package instances, not just package names.

### Lockfile changes

`package.lock` will need a schema upgrade.

`schema_version = 2` should record:

- a stable package instance id for every resolved package
- source identity fields
- resolved version
- dependency edges by instance id, not by package name

Name-only dependency arrays are not sufficient once the graph can contain more than one instance of the same package namespace.

### Module loader changes

`ModuleLoader` must stop resolving imports by scanning a flat list of every `source_root`.

Instead, import resolution should work like this:

1. find the importer package instance
2. if the import is inside the importer's own namespace, resolve against the importer's source root
3. otherwise find the unique direct dependency edge whose package namespace matches the import
4. resolve only inside that dependency instance's source root
5. keep `std` resolution separate from package-instance resolution

This is the critical change that makes transitive duplicate versions safe.

Without it, two resolved versions of the same package namespace would collide in the current flat root search.

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

## Recommended Delivery Plan

### Phase 1: Real requirements with global unification

This phase is the fastest shippable improvement.

- add `PackageVersion` and `PackageVersionReq`
- allow registry requirement syntax beyond exact versions
- implement a real solver
- keep the current global duplicate-package-name rule for now
- add `deps add`, `deps remove`, and `deps update`
- keep the current lockfile shape if one resolved version per package name is still enforced

This delivers exact, exact-or-higher, caret, tilde, and bounded ranges quickly, as long as the graph can be unified to one version per package namespace.

### Phase 2: Package-instance-aware resolution

This phase lifts the real architectural blocker.

- add package instance ids
- change lockfile edges from names to ids
- remove flat source-root import scanning for package dependencies
- allow transitive duplicate versions
- keep direct duplicate namespaces rejected

### Phase 3: Diagnostics and policy polish

- add solver conflict explanations to CLI errors
- add `deps why` and `deps outdated`
- add selective update policies if needed
- decide whether dependency aliases should ever participate in language import syntax

## Recommended Immediate Next Steps

1. Implement `PackageVersion` and `PackageVersionReq` with tests.
2. Change manifest parsing so registry dependency strings accept requirement syntax instead of exact-only syntax.
3. Introduce a registry metadata provider abstraction for listing available versions and dependency metadata.
4. Add `deps add`, `deps remove`, and `deps update` using the existing single-version-per-name graph.
5. After that lands, start the package-instance refactor before attempting transitive duplicate-version support.

This sequence gives Milk Tea useful range solving and real UX quickly without pretending the current module loader can safely host duplicate package namespaces.
