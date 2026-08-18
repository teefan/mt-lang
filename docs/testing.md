# Milk Tea Testing Guide

This guide documents the in-language testing surface: the `assert`/`expect`/`expect_eq`/`expect_ne` intrinsics, the `@[test]` attribute, and the `mtc test` runner. The assertion intrinsics are part of the built-in callable surface (see `language-manual.md` §7); there is no standard-library testing module to import.

## 1. Assertions

Four abort-based assertion intrinsics are available in every module, in both tests and ordinary code:

```mt
assert(condition, message?)            # runtime check
expect(condition, message?)            # always-on test assertion
expect_eq(actual, expected, message?)  # compares with the language `==`
expect_ne(actual, expected, message?)  # compares with `!=`
```

Rules:

- `condition` must be `bool`. `expect_eq`/`expect_ne` compare with the language `==`/`!=` operators, so they work for primitives, `str`, structs, variants, and arrays.
- `message` (when given) must be `str` or `cstr`; a `f"..."` format string flows straight in. When omitted, the compiler synthesizes a message carrying the source location.
- On failure the program aborts through the same path as `fatal`. The message is only evaluated on the failing path, so a `f"..."` message costs nothing while the assertion holds.
- `assert` defaults to always-on. `expect` is the test-flavored form and is always on.
- A literal-false `assert(false, ...)` or `expect(false, ...)` is treated as terminating control flow (like `static_assert(false, ...)`), so it satisfies contexts that require guaranteed exit, such as the `else:` block of a `let ... else:` guard.

## 2. Tests

Tests are ordinary functions annotated with `@[test]`. They take no parameters and return `void`; a failing assertion aborts the test.

```mt
function square(x: int) -> int:
    return x * x

@[test]
function test_square() -> void:
    expect_eq(square(3), 9)
    expect(square(4) > 0, "square must be positive")
```

Rules:

- A test file must not define `main`; `mtc test` synthesizes the entry point.
- A function annotated with `@[test] @[expect_fatal]` is a death test: it must abort (via `fatal`, a failed assertion, or a failed safety check) to pass.

## 3. Running Tests

```sh
mtc test PATH            # run @[test] functions in one file
mtc test DIR             # recursively run every test file under a directory
```

`mtc test` builds one runner binary per test file and runs each test in its own process, so an aborting assertion is isolated to its own test and cannot suppress the results of its siblings. Passing tests print `ok   - name`; failures print `FAIL - name: message`. The run is sandboxed with a wall-clock timeout (default 30s) and an address-space memory cap (default 1024 MB).

Options:

- `--timeout SECONDS` — per-test wall-clock timeout
- `--mem MB` — per-test address-space memory cap
- `--jobs N` — build and run N files in parallel (output stays in file order)
- `-n SUBSTRING` — run only tests whose name contains SUBSTRING
- `--format tap|junit` — machine-readable results for CI
- `--sanitize` — build with AddressSanitizer/UBSan; any sanitizer error fails the run
- `--profile debug|release`, `--platform linux|windows|wasm`, `--cc COMPILER` — build controls, same as `mtc build`

A file containing `# expect-error: <text>` is a compile-fail fixture: `mtc test` requires the compiler to reject it with a diagnostic containing that text, instead of running it.

## 4. Example

```mt
# tests/vec_test.mt
import std.vec as vec

@[test]
function test_vec_push_and_len() -> void:
    var values = vec.Vec[int].create()
    defer: values.release()
    values.push(1)
    values.push(2)
    expect_eq(values.len(), 2)

@[test]
@[expect_fatal]
function test_vec_oob_aborts() -> void:
    var values = vec.Vec[int].create()
    defer: values.release()
    values.push(1)
    values.at(5)
```

```sh
mtc test tests
```

See the `mtc test --help` text for the current full option list.
