# In-language tests for std Option/Result (migrated from
# test/std/std_option_result_test.rb, run by `mtc test`).

import std.testing as t

@[test]
function test_option_some_is_some() -> t.Check:
    return t.expect_some[int](Option[int].some(value = 40))


@[test]
function test_option_none_is_none() -> t.Check:
    return t.expect_none[int](Option[int].none)


@[test]
function test_option_unwrap_else_some() -> t.Check:
    let seeded: Option[int] = Option[int].some(value = 40)
    let value = seeded else:
        return t.fail("expected some")

    return t.expect_equal_int(value, 40)


@[test]
function test_option_match() -> t.Check:
    let seeded: Option[int] = Option[int].some(value = 7)
    var score = 0
    match seeded:
        Option.none:
            score = -1
        Option.some as payload:
            score = payload.value

    return t.expect_equal_int(score, 7)


@[test]
function test_result_unwrap_else_success() -> t.Check:
    let ok_value: Result[int, int] = Result[int, int].success(value = 2)
    let value = ok_value else as error:
        return t.expect_equal_int(error, -999)

    return t.expect_equal_int(value, 2)


@[test]
function test_result_match() -> t.Check:
    let err_value: Result[int, int] = Result[int, int].failure(error = 3)
    var got = 0
    match err_value:
        Result.failure as payload:
            got = payload.error
        Result.success as payload:
            got = payload.value

    return t.expect_equal_int(got, 3)
