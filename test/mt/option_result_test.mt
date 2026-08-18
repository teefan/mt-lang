# In-language tests for std Option/Result (migrated from
# test/std/std_option_result_test.rb, run by `mtc test`).


@[test]
function test_option_some_is_some() -> void:
    expect(Option[int].some(value = 40).is_some())


@[test]
function test_option_none_is_none() -> void:
    expect(Option[int].none.is_none())


@[test]
function test_option_unwrap_else_some() -> void:
    let seeded: Option[int] = Option[int].some(value = 40)
    let value = seeded else:
        expect(false, "expected some")
        return

    expect_eq(value, 40)


@[test]
function test_option_match() -> void:
    let seeded: Option[int] = Option[int].some(value = 7)
    var score = 0
    match seeded:
        Option.none:
            score = -1
        Option.some as payload:
            score = payload.value

    expect_eq(score, 7)


@[test]
function test_result_unwrap_else_success() -> void:
    let ok_value: Result[int, int] = Result[int, int].success(value = 2)
    let value = ok_value else as error:
        expect_eq(error, -999)
        return

    expect_eq(value, 2)


@[test]
function test_result_match() -> void:
    let err_value: Result[int, int] = Result[int, int].failure(error = 3)
    var got = 0
    match err_value:
        Result.failure as payload:
            got = payload.error
        Result.success as payload:
            got = payload.value

    expect_eq(got, 3)
