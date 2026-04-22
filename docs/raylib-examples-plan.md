# Raylib Examples Porting Plan

## Goal

Port the upstream raylib examples to pure Milk Tea source, using the ports as both:

- a real-world showcase for the language and toolchain
- a disciplined way to expose remaining compiler, standard-library, and FFI gaps

"Pure Milk Tea" here means:

- example logic is written in `.mt`
- rendering/audio/input still call the real upstream raylib C library through extern modules
- no handwritten C example logic is kept in the finished ports

## Ground Truth

The upstream reference is the raylib examples tree at:

- `https://github.com/raysan5/raylib/tree/master/examples`

The current curated upstream collection is 212 examples across 7 categories:

- `core`: 49
- `shapes`: 40
- `textures`: 32
- `text`: 16
- `models`: 30
- `shaders`: 35
- `audio`: 10

There is also an `others/` directory in the upstream repo. It is not part of the curated 212-example collection and should be treated as a separate later bucket, not as a blocker for the main porting effort.

## Current Repo Facts

- The repo already has a usable `std.c.raylib` raw binding and a working build/run pipeline.
- The repo does not currently ship raw extern modules for `raymath.h`, `rlgl.h`, `raygui.h`, or `rlights.h`.
- Upstream examples assume `resources/...` paths are resolved relative to the example source directory.
- `MilkTea::Run.run` now executes the built binary with `chdir: File.dirname(source_path)`, which is required for example-relative asset loading.

## Non-Negotiable Constraints

1. Do not mix upstream C examples with Milk Tea ports in the same source tree.
2. Do not hand-copy assets ad hoc. Asset sync must be reproducible and pinned to an upstream commit.
3. Do not try to port all 212 examples as a flat batch. Port by dependency tier.
4. Do not let `others/` or `raygui.h` block the curated 212-example milestone.

## Repository Layout

Use three distinct areas:

- `third_party/raylib-upstream/`
  - pinned upstream checkout or vendored snapshot
  - source of truth for example C code, resources, screenshots, helper headers
- `examples/raylib/`
  - Milk Tea ports only
  - mirror upstream category structure
- `docs/raylib-examples-plan.md`
  - this execution plan and milestone rules

Recommended example layout:

```text
examples/raylib/core/core_basic_window.mt
examples/raylib/core/resources/...
examples/raylib/textures/textures_logo_raylib.mt
examples/raylib/textures/resources/...
```

This preserves the upstream relative asset convention exactly. With the current `Run.run` cwd fix, `resources/...` paths stay valid without adding special runtime path logic.

## Asset Download Strategy

Use a pinned upstream commit and sync from that snapshot, not from floating `master` during normal work.

Phase 1 sync target:

- all curated example source files under the upstream `examples/` tree
- all `resources/**` directories under curated categories
- helper headers used by examples when present
- screenshots only if we want visual parity checks later

Recommended sync behavior:

1. Record the upstream commit SHA in a local manifest.
2. Mirror upstream example C sources into `third_party/raylib-upstream/examples/...`.
3. Mirror upstream runtime assets into `examples/raylib/<category>/resources/...`.
4. Optionally mirror screenshots into `third_party/raylib-upstream/examples/...` for visual comparison, but do not treat screenshots as runtime assets.

## Example Inventory Manifest

Create a generated manifest for planning and tracking, for example:

- `example_id`
- `category`
- `upstream_c_path`
- `resource_paths[]`
- `uses_raymath`
- `uses_rlgl`
- `uses_rlights`
- `uses_raygui`
- `uses_shader_files`
- `uses_model_files`
- `uses_audio_files`
- `uses_callbacks`
- `uses_file_drop_or_directory_api`
- `port_status`
- `known_blockers[]`

The upstream `tools/rexm/rexm.c` logic is a good model for asset scanning. It already scans example source for resource file references and handles shader `glsl%i` path expansion.

Current repo command for the first baseline manifest slice:

```text
mtc raylib-manifest third_party/raylib-upstream/examples -o examples/raylib/manifest.json
```

This command is intentionally local-only. It expects a pinned upstream `examples/` snapshot already present on disk and does not hide network fetches or sync behavior inside the manifest step.

## Porting Order

### Wave 1: curated low-friction examples

Start with examples that are mostly direct raylib API usage and either no assets or trivial assets:

- `core`
- `shapes`
- low-complexity `textures`

Purpose:

- prove the Milk Tea source style for game loops, drawing, input, structs, arrays, and simple state machines
- flush out small ergonomics problems without getting buried in heavy assets or helper libraries

Expected issues:

- example organization
- asset-relative run behavior
- raw FFI surface holes in `std.c.raylib`
- small syntax ergonomics around constants, loops, and mutable state

### Wave 2: assets and text-heavy examples

Next port:

- remaining `textures`
- `text`
- basic `audio`

Purpose:

- validate file loading, fonts, images, textures, audio assets, and text manipulation paths

Expected issues:

- string and text convenience gaps
- resource manifest completeness
- lifecycle cleanup patterns
- more frequent need for small helper functions in ordinary Milk Tea modules

### Wave 3: math- and camera-heavy examples

Next port:

- simpler `models`
- camera and transformation-heavy `core`
- examples that currently include `raymath.h`

Purpose:

- decide where Milk Tea should implement vector/matrix helpers itself instead of binding `raymath.h`

Expected issues:

- vector and matrix helper ergonomics
- array indexing and struct mutation in hot loops
- FFI handling of nested arrays, matrices, and pointer-heavy APIs

### Wave 4: shader and advanced rendering examples

Next port:

- `shaders`
- advanced `models`

Purpose:

- validate shader file management, shader location APIs, material maps, render textures, and 3D pipelines

Expected issues:

- GLSL version selection strategy
- shader path conventions
- helper surfaces like `rlights`
- render-texture and postprocessing workflows

### Wave 5: special-case and external-helper examples

Last port bucket:

- `others/`
- any examples depending on `raygui.h`, `rlights.h`, or custom helper headers

Purpose:

- close the long tail after the main curated collection is stable

Expected issues:

- macro-heavy C helper libraries
- header-embedded assets
- examples that are not good fits for pure bindgen-only import

## What To Improve In Milk Tea While Porting

Do not add features speculatively. Only add them when a real example forces the issue.

The likely improvement buckets are:

### 1. Toolchain and project ergonomics

- example sync command or script
- manifest generation for examples and assets
- batch build/run helpers for example directories
- screenshot or smoke-test harness later

### 2. Raw bindings coverage

- fill missing `std.c.raylib` declarations exposed by real examples
- add `std.c.raymath` only if pure Milk Tea replacements are clearly worse
- add `std.c.rlgl` only when an example genuinely requires it

### 3. Ordinary-module helper layers

Prefer ordinary Milk Tea helper modules over binding macro-heavy C headers when practical.

Examples:

- `std/raylib/math.mt` for vector/matrix helpers that can be expressed cleanly in Milk Tea
- `std/raylib/camera.mt` helpers for repeated camera setup/update patterns
- `std/raylib/lights.mt` if `rlights.h` functionality is small enough to rewrite cleanly

### 4. Compiler and language polish

Only accept changes backed by real example pain points such as:

- awkward pointer or array manipulation in real code
- missing FFI expressiveness for callbacks or array-backed structs
- poor readability for common game-loop patterns
- missing compile-time or runtime ergonomics that materially reduce clarity

## Known Likely Blockers

These should be expected, not treated as surprises:

1. `raymath.h` is not a normal ABI-only header. Much of it is inline or macro-style helper logic, so bindgen alone is not the right first answer.
2. `raygui.h` and `rlights.h` are helper libraries, not just passive ABI declarations. They may need separate raw modules, custom wrappers, or direct Milk Tea rewrites.
3. Shader examples often use `TextFormat("resources/shaders/glsl%i/...", GLSL_VERSION)`. Desktop-only testing can standardize on GLSL 330 first, but cross-platform handling will need a deliberate strategy later.
4. Some model and text assets have secondary dependencies such as `.fnt` plus `.png`, or model files plus textures and animation files. Asset sync must resolve those as a set.
5. A few examples depend on APIs like file drops, directory traversal, clipboard, automation, or callbacks. These are valid stress tests and may expose thin spots in both bindings and ergonomics.

## Acceptance Rules Per Example

An example port is not done until all of the following are true:

1. The upstream example C source has been read and the required resources are listed.
2. The Milk Tea port lives under the mirrored category path.
3. The example builds with the normal toolchain.
4. The example runs with assets resolved through the standard relative `resources/...` layout.
5. The example behavior matches the upstream reference closely enough to be recognizably the same example.
6. Any compiler or library change made during the port is covered by focused tests.

## Initial Execution Sequence

### Step 0

- pin an upstream raylib commit
- vendor or clone the upstream examples snapshot under `third_party/raylib-upstream/`

### Step 1

- generate the example inventory manifest
- classify examples by category, resources, helper-header usage, and likely blocker type

### Step 2

- create the Milk Tea example tree under `examples/raylib/`
- sync runtime assets into mirrored category `resources/` folders

### Step 3

- port the first 10 examples from `core`
- keep them intentionally simple
- use them to refine directory layout, run workflow, and missing raw binding declarations

### Step 4

- close `core`
- move to `shapes`
- only then start broad `textures` work

### Step 5

- after each wave, review the compiler and helper-module pain points
- only promote repeated pain into language or toolchain improvements

## Recommended First Concrete Milestone

The correct next milestone is not "all examples". It is:

- sync upstream examples and assets
- generate a manifest
- port `core` first

That milestone is small enough to finish and strong enough to expose the next real compiler issues without getting buried in shader helpers, model formats, or `raygui` integration.
