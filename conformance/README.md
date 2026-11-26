# Conformance cases

This tree is a small, **spec-derived** executable conformance suite. Cases are
derived from `docs/language-manual.md` and `README.md`, not recorded from the
compiler.

Rules:

- Each `*.mt` case starts with `# Spec: <manual or README section>`.
- The sibling `*.json` is the checked-in expectation. There is **no record or
  update mode** in `tools/conformance.rb`; changing an expectation is a reviewed
  language/spec decision.
- Run cases compare exact stdout, exit status, and optional stderr substrings.
- Check cases compare the exact number of `error[...]` diagnostics, plus their
  code and message substring; `line`/`column` are checked when present.
- `strict: true` runs/builds with `--strict-types`; strict warnings never
  silently become expected output.
- The suite deliberately grows with each semantic or build change; it is not a
  replacement for the broader `test/mt` suite.

Run directly or through the gate:

```sh
ruby tools/conformance.rb --self build/stage2/mtc
tools/gates.sh --areas conformance --run
```
