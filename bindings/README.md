# Binding metadata

- `raw/<name>.json` — the host-era raw-bindgen option table: `bindgen_defines`,
  `module_imports`, tracked header paths/prefixes, type/parameter/field
  overrides and declaration filters.  Paths use a `$ROOT/` prefix.
- `nullable/<name>.json` — the `?` annotations captured from the checked-in
  raw module.  `mtc bindgen` only emits them when given `--nullable-policy`;
  regenerating without this file silently drops nullability.
- `imported/<name>.binding.json` — the high-level wrapper policy, consumed by
  `mtc imported-bindings`.

`tracy` is marked `"custom": true`: its raw module is hand-written, not
generated from `TracyC.h`.

## Rebind

```sh
tools/rebind_binding.rb <name> --check   # diff against std/c/<name>.mt
tools/rebind_binding.rb <name> --write   # update std/c/<name>.mt
tools/rebind_binding.rb --all --check    # every table; tracy is skipped
```

The default compiler is `build/stage2/mtc`; pass `--self tmp/mtc-dev` while
iterating.  The tool expands `$ROOT`, writes a temporary options JSON, applies
`bindings/nullable/<name>.json` when present, and invokes `mtc bindgen
--options-json`.

The current baseline (`--all --check`) is 30/33 identical, `tracy` custom, and
three known diffs: `curl`/`sqlite3` follow this host's system headers, while
`libuv` predates the checked-out header.  Regenerate each with its next header
bump and review the diff; do not treat those three as generator regressions.

## Upgrade a vendored library

1. Pin the new commit/tag in `config/upstream_versions.yml` (config wins over
   the source table).
2. Remove the old checkout and re-bootstrap.  `source_complete` checks only
   sentinels, so an existing directory is never updated in place:
   ```sh
   rm -rf third_party/<name>-upstream
   vendor/bootstrap/linux-x86_64/mtc toolchain bootstrap
   mtc toolchain doctor
   ```
   Run this from the repo checkout, not through the installed compiler's
   `third_party` symlink.  Also remove the matching `tmp/vendored-*` archive
   or prefix (`tmp/vendored-raylib-opengl43`, `tmp/vendored-glfw*`,
   `tmp/vendored-sdl3*`, …): `prepare_vendored_*` reuses an existing archive,
   so a source upgrade is otherwise silently ignored.
3. Rebind the raw module(s), then the imported wrapper:
   ```sh
   tools/rebind_binding.rb <name> --write
   mtc imported-bindings <name>
   mtc imported-bindings --all --check
   ```
4. Review `build.mt`'s `prepare_vendored_*` recipe (source lists, CMake
   options, defines) and the `collect_binding_flags` include/link mapping.
5. Gate:
   ```sh
   tools/gates.sh --areas bindings --run
   tools/gates.sh --areas examples --run
   tools/gates.sh --areas release --run
   ```
   Then build and run the library's examples (and `mtc run .` in a real
   project) before committing the pin.
