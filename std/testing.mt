# Standard library: testing core (T0 prototype)
#
# Minimal, in-language unit-testing surface — see docs/testing.md (§5, T0).
# A test function returns `Check` and propagates the first failure with `?`:
#
#     import std.testing as t
#
#     function test_math() -> t.Check:
#         t.expect_equal_int(2 + 2, 4)?
#         return t.ok()
#
# A hand-written runner (see docs/testing.md §6 for future compiler-driven
# discovery) calls `record` per test and `summarize` at the end:
#
#     function main() -> int:
#         var stats = t.Stats.create()
#         stats = t.record(stats, "math", test_math())
#         return t.summarize(stats)

import std.string as string
import std.fmt as fmt
import std.stdio as stdio

# A test outcome: success carries no meaningful value; failure carries a
# `Failure`. `Result` is used (not a bespoke variant) so `?` propagation works.
public type Check = Result[bool, Failure]

# A failed (or skipped) expectation. `message` is owned and must be released by
# whoever consumes it (the runner does this in `record`). `is_skip` distinguishes
# a skip from a real assertion failure.
public struct Failure:
    message: string.String
    is_skip: bool


# Tally of outcomes for a run. Value type; `record` returns an updated copy.
public struct Stats:
    passed: int
    failed: int
    skipped: int


extending Stats:
    public static function create() -> Stats:
        return Stats(passed = 0, failed = 0, skipped = 0)


# ── Outcome constructors ──────────────────────────────────────────────────

public function ok() -> Check:
    return Result[bool, Failure].success(value = true)


public function fail(message: str) -> Check:
    return Result[bool, Failure].failure(error = Failure(message = string.String.from_str(message), is_skip = false))


public function skip(reason: str) -> Check:
    return Result[bool, Failure].failure(error = Failure(message = string.String.from_str(reason), is_skip = true))


# ── Expectations ──────────────────────────────────────────────────────────

public function expect(condition: bool, message: str) -> Check:
    if condition:
        return ok()

    return fail(message)


public function expect_true(condition: bool) -> Check:
    return expect(condition, "expected true")


public function expect_false(condition: bool) -> Check:
    return expect(not condition, "expected false")


public function expect_equal_int(actual: int, expected: int) -> Check:
    if actual == expected:
        return ok()

    var message = string.String.create()
    message.append("expected ")
    fmt.append_int(ref_of(message), expected)
    message.append(", got ")
    fmt.append_int(ref_of(message), actual)
    return Result[bool, Failure].failure(error = Failure(message = message, is_skip = false))


public function expect_equal_str(actual: str, expected: str) -> Check:
    var actual_string = string.String.from_str(actual)
    var expected_string = string.String.from_str(expected)
    let same = actual_string.equal(expected_string)
    actual_string.release()
    expected_string.release()
    if same:
        return ok()

    var message = string.String.create()
    message.append("expected [")
    message.append(expected)
    message.append("], got [")
    message.append(actual)
    message.append("]")
    return Result[bool, Failure].failure(error = Failure(message = message, is_skip = false))


public function expect_equal_bool(actual: bool, expected: bool) -> Check:
    if actual == expected:
        return ok()

    var message = string.String.create()
    message.append("expected ")
    fmt.append_bool(ref_of(message), expected)
    message.append(", got ")
    fmt.append_bool(ref_of(message), actual)
    return Result[bool, Failure].failure(error = Failure(message = message, is_skip = false))


public function expect_some[T](option: Option[T]) -> Check:
    if option.is_some():
        return ok()

    return fail("expected Option.some, got Option.none")


public function expect_none[T](option: Option[T]) -> Check:
    if option.is_none():
        return ok()

    return fail("expected Option.none, got Option.some")


# ── Runner (hand-written; compiler discovery is a later phase) ─────────────

public function record(stats: Stats, name: str, outcome: Check) -> Stats:
    match outcome:
        Result.success:
            var line = string.String.create()
            line.append("ok   - ")
            line.append(name)
            stdio.print_line(line.as_str())
            line.release()
            return Stats(passed = stats.passed + 1, failed = stats.failed, skipped = stats.skipped)
        Result.failure as payload:
            let failure = payload.error
            var line = string.String.create()
            if failure.is_skip:
                line.append("skip - ")
            else:
                line.append("FAIL - ")

            line.append(name)
            line.append(": ")
            line.append(failure.message.as_str())
            stdio.print_line(line.as_str())
            line.release()

            var owned_message = failure.message
            owned_message.release()

            if failure.is_skip:
                return Stats(passed = stats.passed, failed = stats.failed, skipped = stats.skipped + 1)

            return Stats(passed = stats.passed, failed = stats.failed + 1, skipped = stats.skipped)


public function summarize(stats: Stats) -> int:
    var line = string.String.create()
    line.append("passed=")
    fmt.append_int(ref_of(line), stats.passed)
    line.append(" failed=")
    fmt.append_int(ref_of(line), stats.failed)
    line.append(" skipped=")
    fmt.append_int(ref_of(line), stats.skipped)
    stdio.print_line(line.as_str())
    line.release()

    if stats.failed > 0:
        return 1

    return 0
