# Recorded golden fixtures

These files are the regression oracle for the post-retirement compiler.  Each
harness requires `--record FILE` or `--expect FILE`; the live host branches are
gone.

```sh
# record (reviews are the fixture diff)
ruby tools/cli_parity.rb --record tools/golden/cli.json
ruby tools/diag_parity.rb check std examples --record tools/golden/diag.json
ruby tools/lint_parity.rb --record tools/golden/lint.json
ruby tools/format_parity.rb all -j 4 --record tools/golden/format.json

# replay
ruby tools/cli_parity.rb --expect tools/golden/cli.json -q
ruby tools/diag_parity.rb check std examples --expect tools/golden/diag.json -q
ruby tools/lint_parity.rb --expect tools/golden/lint.json -q
ruby tools/format_parity.rb all -j 4 --expect tools/golden/format.json -q
```

`tools/gates.sh --areas oracles` runs the replay set plus the syntax check.

## Digest policy

The diagnostics, lint and formatter fixtures are keyed by the **input digest**
of every file they cover. On replay:

- an unchanged input is re-measured and compared;
- an input whose text changed since recording is **skipped** (its row is stale
  by design), and the run reports it as `changed=N`;
- an input with no row is reported as `unrecorded=N` and not compared.

This keeps a source edit from turning the gate red while still catching
behavior regressions on untouched files. It also means a behavior change is
only reviewed when it shows up against unchanged inputs; a change that only
affects newly-written code is covered by the in-language suite and the live
parity gates until the host is retired.

The CLI fixture is hermetic (its cases materialize their own inputs), so it has
no digest column. Cases that read checked-in sources (for example `std show`)
go stale when those sources change; re-record after such an edit.

## Re-recording

A failed replay prints the differing keys. If the change is intended, re-record
and review the fixture diff in the same commit. Never re-record to silence an
unexplained difference.
